"""Resource/provenance guards; actual Mach-O/signature checks run on native bundle fixtures."""
import io
import json
from pathlib import Path
import plistlib
import os
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
import sevenzip_bundle as bundle


class SevenZipBundleGuards(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.app = Path(self.temporary.name) / 'Files macOS.app'
        for name in bundle.FILES:
            path = self.app / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(b'fixture')
        main = self.app / 'Contents/MacOS/FilesMac'; main.parent.mkdir(); main.write_bytes(b'fixture')
        (self.app / 'Contents/Frameworks').mkdir()
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'FilesArchiveSDKVersion': bundle.reference.VERSION}))
        root = self.app / bundle.RESOURCE
        with tarfile.open(root / bundle.ARCHIVE_NAME, 'w:xz') as archive:
            for name in bundle.NOTICES:
                data = b'fixture'; info = tarfile.TarInfo('DOC/' + name); info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
        source_hash = bundle.digest(root / bundle.ARCHIVE_NAME)
        self.source_patch = patch.object(bundle.reference, 'SOURCE_SHA256', source_hash)
        self.source_patch.start(); self.addCleanup(self.source_patch.stop)
        self.code_patch = patch.object(bundle, 'check_code')
        self.code_patch.start(); self.addCleanup(self.code_patch.stop)
        self.manifest = dict(version=1, SDKVersion=bundle.reference.VERSION, SDKSourceSHA256=source_hash,
                             architectures=['arm64'], builds={'arm64': {'inputs': dict(architecture='arm64', SDKSourceSHA256=source_hash,
                                minimumOS='14.0', helperSourcesSHA256={name: bundle.digest(root / 'Sources/Tools/SevenZipWorker' / name)
                                    for name in ['ArchiveSDK.h', 'ArchiveSDK.cpp', 'main.mm']},
                                buildRecipeSHA256=bundle.digest(root / 'Sources/scripts/build-sevenzip-worker.py'))}},
                             filesSHA256={name: bundle.digest(self.app / name) for name in bundle.FILES})
        self.save()

    def save(self):
        (self.app / bundle.RESOURCE / 'manifest.json').write_text(json.dumps(self.manifest))

    def test_complete_resource_provenance(self):
        self.assertEqual(bundle.verify(self.app, signatures=False), self.manifest)

    def test_changed_bytes_and_oversized_manifest_rejected(self):
        path = self.app / bundle.CODE[0]; path.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'bytes changed'): bundle.verify(self.app, signatures=False)
        (self.app / bundle.RESOURCE / 'manifest.json').write_bytes(b' ' * (1024 * 1024 + 1))
        with self.assertRaisesRegex(ValueError, 'size limit'): bundle.read_manifest(self.app)

    def test_symlink_and_foreign_directory_preserved(self):
        path = self.app / bundle.RESOURCE / 'Sources/scripts'
        held = Path(self.temporary.name) / 'held'; path.rename(held); path.symlink_to(held, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'Symlink'): bundle.verify(self.app, signatures=False)
        self.assertEqual((held / 'build-sevenzip-worker.py').read_bytes(), b'fixture')

    def test_extra_files_empty_directories_and_code_rejected(self):
        root = self.app / bundle.RESOURCE; extra = root / 'foreign'; extra.write_bytes(b'keep')
        with self.assertRaisesRegex(ValueError, 'resource contents'): bundle.verify(self.app, signatures=False)
        self.assertEqual(extra.read_bytes(), b'keep'); extra.unlink(); extra.mkdir()
        with self.assertRaisesRegex(ValueError, 'resource directories'): bundle.verify(self.app, signatures=False)
        extra.rmdir(); code = self.app / 'Contents/Helpers/extra'; code.write_bytes(b'keep')
        with self.assertRaisesRegex(ValueError, 'code directory'): bundle.verify(self.app, signatures=False)
        self.assertEqual(code.read_bytes(), b'keep')

    def test_manifest_cannot_add_paths_or_boolean_version(self):
        self.manifest['filesSHA256']['../escape'] = '0' * 64; self.save()
        with self.assertRaisesRegex(ValueError, 'file manifest'): bundle.verify(self.app, signatures=False)
        del self.manifest['filesSHA256']['../escape']; self.manifest['version'] = True; self.save()
        with self.assertRaisesRegex(ValueError, 'provenance'): bundle.verify(self.app, signatures=False)

    def test_resealed_archive_notice_and_helper_changes_rejected(self):
        for relative, expected in [(bundle.ARCHIVE_NAME, 'source archive'), ('License.txt', 'notice differs'),
                                   ('Sources/Tools/SevenZipWorker/main.mm', 'helper source')]:
            path = self.app / bundle.RESOURCE / relative; original = path.read_bytes(); path.write_bytes(b'changed')
            key = bundle.RESOURCE + '/' + relative; self.manifest['filesSHA256'][key] = bundle.digest(path); self.save()
            with self.assertRaisesRegex(ValueError, expected): bundle.verify(self.app, signatures=False)
            path.write_bytes(original); self.manifest['filesSHA256'][key] = bundle.digest(path); self.save()

    def test_signing_refresh_changes_only_code_hashes(self):
        before = dict(self.manifest['filesSHA256']); path = self.app / bundle.CODE[0]; path.write_bytes(b'signed-code')
        bundle.refresh(self.app)
        updated = bundle.read_manifest(self.app)['filesSHA256']
        self.assertEqual(updated[bundle.CODE[0]], bundle.digest(path))
        for name in set(bundle.FILES) - set(bundle.CODE): self.assertEqual(updated[name], before[name])
        (self.app / bundle.RESOURCE / 'BUILD.md').write_bytes(b'foreign')
        with self.assertRaisesRegex(ValueError, 'bytes changed'): bundle.refresh(self.app)

    def test_existing_app_and_image_outputs_preserved(self):
        repo = Path(__file__).resolve().parents[2]
        before = bundle.digest(self.app / bundle.CODE[0])
        result = subprocess.run(['/bin/bash', str(repo / 'scripts/build-app.sh')],
                                env=dict(os.environ, FILES_APP_OUTPUT=str(self.app)), capture_output=True)
        self.assertEqual(result.returncode, 73)
        self.assertEqual(bundle.digest(self.app / bundle.CODE[0]), before)
        output = Path(self.temporary.name) / 'images'; output.mkdir()
        image = output / 'Files-macOS-preview.dmg'; image.write_bytes(b'preserve old image')
        result = subprocess.run(['/bin/bash', str(repo / 'scripts/build-dmg.sh'), '--preview'],
                                env=dict(os.environ, FILES_DMG_OUTPUT_DIR=str(output)), capture_output=True)
        self.assertEqual(result.returncode, 73)
        self.assertEqual(image.read_bytes(), b'preserve old image')


if __name__ == '__main__': unittest.main()
