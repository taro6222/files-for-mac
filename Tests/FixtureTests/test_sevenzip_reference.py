import hashlib
import io
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
import sevenzip_reference as reference

class SevenZipReferenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='sevenzip-reference-')
        self.root = Path(self.temporary.name)
        self.contents = {'7zz': b'non-executable test fixture', 'License.txt': b'license fixture', 'readme.txt': b'readme fixture'}

    def tearDown(self): self.temporary.cleanup()

    def archive(self, bad=None):
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode='w:xz') as archive:
            for name, content in self.contents.items():
                info = tarfile.TarInfo(name); info.size = len(content)
                if name == '7zz' and bad == 'link': info.type = tarfile.SYMTYPE; info.linkname = '/foreign/file'
                archive.addfile(info, io.BytesIO(content) if info.isfile() else None)
            if bad == 'duplicate':
                info = tarfile.TarInfo('7zz'); info.size = 1; archive.addfile(info, io.BytesIO(b'x'))
            info = tarfile.TarInfo('../outside.txt'); info.size = 7; archive.addfile(info, io.BytesIO(b'foreign'))
        return data.getvalue()

    def pins(self, data):
        return patch.multiple(reference,
            ASSETS={'arm64': ('fixture.tar.xz', reference.digest(data), reference.digest(self.contents['7zz']))},
            NOTICE_HASHES={k: reference.digest(v) for k, v in self.contents.items() if k != '7zz'})

    def test_hash_mismatch_stops_before_archive_processing(self):
        with self.assertRaisesRegex(ValueError, 'archive hash mismatch'): reference.unpack(b'untrusted bytes', 'arm64')

    def test_exact_members_are_verified_without_extracting_other_paths(self):
        data = self.archive()
        with self.pins(data): self.assertEqual(reference.unpack(data, 'arm64'), self.contents)
        self.assertFalse((self.root / 'outside.txt').exists())

    def test_links_and_duplicate_executable_members_are_rejected(self):
        for bad in ['link', 'duplicate']:
            with self.subTest(bad=bad):
                data = self.archive(bad)
                with self.pins(data):
                    with self.assertRaisesRegex(ValueError, 'member type, size, or duplicate'): reference.unpack(data, 'arm64')

    def test_cached_executable_is_reused_and_never_repaired_in_place(self):
        data = self.archive(); source = self.root / 'source.tar.xz'; source.write_bytes(data)
        output = self.root / 'reference'
        with self.pins(data), patch.object(reference.urllib.request, 'urlopen', side_effect=AssertionError('Network must not run')):
            binary = reference.acquire(output, 'arm64', source)
            original_inode = binary.stat().st_ino
            self.assertEqual(reference.acquire(output, 'arm64'), binary)
            self.assertEqual(binary.stat().st_ino, original_inode)
            binary.write_bytes(b'changed executable')
            with self.assertRaisesRegex(ValueError, 'refusing to overwrite'): reference.acquire(output, 'arm64')
            self.assertEqual(binary.read_bytes(), b'changed executable')

    def test_unknown_destination_and_symlink_are_preserved(self):
        output = self.root / 'reference'; output.mkdir(); foreign = output / 'user-file'; foreign.write_bytes(b'preserved')
        with self.assertRaisesRegex(ValueError, 'not an exact pinned'): reference.acquire(output, 'arm64')
        link = self.root / 'link'; link.symlink_to(output, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'not an exact pinned'): reference.acquire(link, 'arm64')
        self.assertEqual(foreign.read_bytes(), b'preserved')

if __name__ == '__main__': unittest.main()
