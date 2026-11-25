import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
import spotlight_volume_fixture as fixture


class SpotlightVolumeOwnershipTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='spotlight-ownership-')
        self.parent = Path(self.temporary.name).resolve()
        self.base = self.parent / 'volume.owned'; self.base.mkdir()
        self.mount = self.base / 'Volume'; self.mount.mkdir()
        self.root = self.mount / 'Fixture'; self.root.mkdir()
        self.reference = Path(__file__).resolve().parents[2] / fixture.SOURCE
        self.source = self.root / fixture.SOURCE; self.source.parent.mkdir(parents=True)
        shutil.copyfile(self.reference, self.source)
        self.state_path = self.parent / 'state.json'
        self.image = self.base / 'source.dmg'; self.image.write_bytes(b'owned image fixture')
        self.state = {'id': 'ownership-test', 'sourceSHA256': hashlib.sha256(self.source.read_bytes()).hexdigest(),
                      'resourceDirectory': str(self.base), 'resourceIdentity': fixture.identity(self.base, stat.S_IFDIR),
                      'image': str(self.image), 'imageIdentity': fixture.identity(self.image, stat.S_IFREG),
                      'mountPoint': str(self.mount), 'fixtureRoot': str(self.root),
                      'inode': self.root.stat().st_ino, 'sourcePublished': True}
        self.marker = {'id': self.state['id'], 'sourceSHA256': self.state['sourceSHA256']}
        (self.base / fixture.MARKER).write_text(json.dumps(self.marker))
        (self.root / fixture.FIXTURE_MARKER).write_text(json.dumps(self.marker))

    def tearDown(self):
        self.temporary.cleanup()

    def test_accepts_exact_owned_source_tree(self):
        fixture.validate_resource(self.state, self.state_path)
        fixture.validate_source_only(self.state)

    def test_foreign_resource_data_blocks_cleanup_before_device_commands(self):
        foreign = self.base / 'user-note.txt'; foreign.write_text('must remain')
        with patch.object(fixture, 'command', side_effect=AssertionError('Device command must not run')):
            with self.assertRaisesRegex(RuntimeError, 'Unrecognized resource'):
                fixture.cleanup(self.state, self.state_path, lambda _: None)
        self.assertEqual(foreign.read_text(), 'must remain')
        self.assertTrue(self.image.exists())

    def test_replaced_backing_image_is_not_adopted(self):
        self.image.rename(self.parent / 'original-image')
        self.image.write_bytes(b'owned image fixture')
        with self.assertRaisesRegex(RuntimeError, 'image identity'):
            fixture.validate_resource(self.state, self.state_path)
        self.assertTrue((self.parent / 'original-image').exists())

    def test_changed_resource_marker_is_rejected(self):
        (self.base / fixture.MARKER).write_text(json.dumps({'id': 'different'}))
        with self.assertRaisesRegex(RuntimeError, 'marker changed'):
            fixture.validate_resource(self.state, self.state_path)

    def test_unknown_volume_and_discarded_payloads_are_preserved(self):
        for name in ['user-note.txt', '.Trashes/501/user-note.txt', '.TemporaryItems/note.txt']:
            with self.subTest(name=name):
                foreign = self.mount / name; foreign.parent.mkdir(parents=True, exist_ok=True)
                foreign.write_text('unique user bytes')
                with self.assertRaises(RuntimeError): fixture.validate_source_only(self.state)
                self.assertEqual(foreign.read_text(), 'unique user bytes')
                foreign.unlink()

    def test_changed_source_and_unknown_fixture_file_are_rejected(self):
        original = self.source.read_bytes()
        self.source.write_bytes(b'different source')
        with self.assertRaisesRegex(RuntimeError, 'bytes changed'): fixture.validate_source_only(self.state)
        self.source.write_bytes(original)
        extra = self.root / 'extra.txt'; extra.write_text('must remain')
        with self.assertRaisesRegex(RuntimeError, 'unrecognized'): fixture.validate_source_only(self.state)
        self.assertEqual(extra.read_text(), 'must remain')

    def test_only_an_unpublished_public_source_prefix_is_allowed(self):
        self.state['sourcePublished'] = False
        self.source.write_bytes(self.reference.read_bytes()[:32])
        fixture.validate_source_only(self.state)
        self.source.write_bytes(b'not the public source')
        with self.assertRaisesRegex(RuntimeError, 'bytes changed'): fixture.validate_source_only(self.state)

    def test_fixture_symlink_is_never_followed_for_cleanup(self):
        self.source.unlink(); self.source.symlink_to(self.reference)
        with self.assertRaisesRegex(RuntimeError, 'unrecognized'): fixture.validate_source_only(self.state)
        self.assertTrue(self.reference.exists())

    def test_changed_resource_paths_cannot_point_at_another_image(self):
        foreign = self.parent / 'foreign.dmg'; foreign.write_bytes(b'other image')
        self.state['image'] = str(foreign)
        with self.assertRaisesRegex(RuntimeError, 'paths changed'):
            fixture.validate_resource(self.state, self.state_path)
        self.assertEqual(foreign.read_bytes(), b'other image')

    def test_special_entries_and_fake_index_metadata_are_preserved(self):
        special = self.root / 'unexpected-pipe'; os.mkfifo(special)
        with self.assertRaisesRegex(RuntimeError, 'unrecognized'):
            fixture.validate_source_only(self.state)
        self.assertTrue(stat.S_ISFIFO(special.lstat().st_mode)); special.unlink()
        metadata = self.mount / '.Spotlight-V100'; metadata.write_text('foreign bytes')
        with self.assertRaisesRegex(RuntimeError, 'type changed'):
            fixture.validate_source_only(self.state)
        self.assertEqual(metadata.read_text(), 'foreign bytes')


if __name__ == '__main__':
    unittest.main()
