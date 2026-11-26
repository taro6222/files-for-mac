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

    def test_busy_detach_revalidates_ownership_and_current_device(self):
        busy = fixture.CommandFailure(['hdiutil'], 16, b'Resource busy')
        with patch.object(fixture, 'mounted_volume', side_effect=[('/dev/disk2', {}), ('/dev/disk9', {})]), \
             patch.object(fixture, 'image_mapping', side_effect=[{'attached': True}, None]), \
             patch.object(fixture, 'command', side_effect=[busy, 'detached']) as command, \
             patch.object(fixture.time, 'sleep'):
            fixture.detach(self.state, self.state_path)
        self.assertEqual([call.args[0] for call in command.call_args_list],
                         [['/usr/bin/hdiutil', 'detach', '/dev/disk2'], ['/usr/bin/hdiutil', 'detach', '/dev/disk9']])
        self.assertTrue(self.image.exists())

    def test_busy_detach_refuses_new_data_before_retry(self):
        unknown = self.mount / 'new-user-file.txt'
        def busy(*_, **__):
            unknown.write_text('must remain')
            raise fixture.CommandFailure(['hdiutil'], 16, b'Resource busy')
        with patch.object(fixture, 'mounted_volume', return_value=('/dev/disk2', {})), \
             patch.object(fixture, 'image_mapping', return_value={'attached': True}), \
             patch.object(fixture, 'command', side_effect=busy) as command, patch.object(fixture.time, 'sleep'):
            with self.assertRaisesRegex(RuntimeError, 'Unrecognized data'):
                fixture.detach(self.state, self.state_path)
        self.assertEqual(command.call_count, 1)
        self.assertEqual(unknown.read_text(), 'must remain')
        self.assertTrue(self.image.exists())

    def test_persistent_busy_detach_is_bounded_and_preserves_image(self):
        with patch.object(fixture, 'mounted_volume', return_value=('/dev/disk2', {})), \
             patch.object(fixture, 'image_mapping', return_value={'attached': True}), \
             patch.object(fixture, 'command', side_effect=fixture.CommandFailure(['hdiutil'], 16, b'busy')) as command, \
             patch.object(fixture.time, 'sleep'):
            with self.assertRaises(fixture.CommandFailure): fixture.detach(self.state, self.state_path)
        self.assertEqual(command.call_count, 5)
        self.assertTrue(self.image.exists())

    def test_other_detach_failures_are_not_retried(self):
        with patch.object(fixture, 'mounted_volume', return_value=('/dev/disk2', {})), \
             patch.object(fixture, 'command', side_effect=fixture.CommandFailure(['hdiutil'], 1, b'permission')) as command:
            with self.assertRaises(fixture.CommandFailure): fixture.detach(self.state, self.state_path)
        self.assertEqual(command.call_count, 1)
        self.assertTrue(self.image.exists())

    def unmounted_layout(self):
        self.root.rename(self.parent / 'saved-source')
        self.state.update(volumeUUID='owned-uuid', imageDevice='/dev/disk99')
        mapping = {'system-entities': [
            {'dev-entry': '/dev/disk2', 'content-hint': 'GUID_partition_scheme'},
            {'dev-entry': '/dev/disk2s1'}, {'dev-entry': '/dev/disk3'}, {'dev-entry': '/dev/disk3s1'}]}
        info = {'FilesystemType': 'apfs', 'VolumeUUID': 'owned-uuid', 'APFSContainerReference': 'disk3',
                'DeviceIdentifier': 'disk3s1', 'MountPoint': ''}
        containers = {'Containers': [{'ContainerReference': 'disk3',
                      'PhysicalStores': [{'DeviceIdentifier': 'disk2s1'}],
                      'Volumes': [{'DeviceIdentifier': 'disk3s1', 'APFSVolumeUUID': 'owned-uuid'}]}]}
        return mapping, info, containers

    def inspect_unmounted(self, mapping, info, containers):
        def command(arguments, **kwargs):
            if arguments == ['/usr/sbin/diskutil', 'info', '-plist', 'owned-uuid']: return info
            if arguments == ['/usr/sbin/diskutil', 'apfs', 'list', '-plist', 'disk3']: return containers
            self.fail('Unexpected device command: ' + str(arguments))
        with patch.object(fixture, 'image_mapping', return_value=mapping), \
             patch.object(fixture.os.path, 'ismount', return_value=False), \
             patch.object(fixture, 'command', side_effect=command):
            return fixture.unmounted_image_device(self.state)

    def test_unmounted_owned_volume_uses_verified_current_image_device(self):
        self.assertEqual(self.inspect_unmounted(*self.unmounted_layout()), '/dev/disk2')
        self.assertEqual(self.state['imageDevice'], '/dev/disk99')
        self.assertTrue(self.image.exists())

    def test_unmounted_uuid_and_container_membership_changes_are_rejected(self):
        mapping, info, containers = self.unmounted_layout()
        info['VolumeUUID'] = 'another-uuid'
        with self.assertRaisesRegex(RuntimeError, 'UUID changed'): self.inspect_unmounted(mapping, info, containers)
        info['VolumeUUID'] = 'owned-uuid'
        containers['Containers'][0]['Volumes'][0]['DeviceIdentifier'] = 'disk8s1'
        with self.assertRaisesRegex(RuntimeError, 'exactly one owned'): self.inspect_unmounted(mapping, info, containers)
        self.assertTrue(self.image.exists())

    def test_unmounted_volume_on_foreign_physical_store_is_rejected(self):
        mapping, info, containers = self.unmounted_layout()
        containers['Containers'][0]['PhysicalStores'][0]['DeviceIdentifier'] = 'disk8s1'
        with self.assertRaisesRegex(RuntimeError, 'another image'): self.inspect_unmounted(mapping, info, containers)
        self.assertTrue(self.image.exists())

    def test_additional_unmounted_apfs_volume_and_partition_are_not_adopted(self):
        mapping, info, containers = self.unmounted_layout()
        volumes = containers['Containers'][0]['Volumes']
        volumes.append({'DeviceIdentifier': 'disk3s2', 'APFSVolumeUUID': 'user-volume'})
        with self.assertRaisesRegex(RuntimeError, 'exactly one owned'): self.inspect_unmounted(mapping, info, containers)
        volumes.pop(); mapping['system-entities'].append({'dev-entry': '/dev/disk2s2'})
        with self.assertRaisesRegex(RuntimeError, 'Unrecognized image'): self.inspect_unmounted(mapping, info, containers)
        self.assertTrue(self.image.exists())

    def test_foreign_mount_or_remounted_volume_blocks_unmounted_recovery(self):
        mapping, info, containers = self.unmounted_layout()
        mapping['system-entities'][-1]['mount-point'] = str(self.parent / 'foreign-mount')
        with self.assertRaisesRegex(RuntimeError, 'state changed'): self.inspect_unmounted(mapping, info, containers)
        mapping['system-entities'][-1].pop('mount-point'); info['MountPoint'] = str(self.parent / 'elsewhere')
        with self.assertRaisesRegex(RuntimeError, 'mounted elsewhere'): self.inspect_unmounted(mapping, info, containers)
        self.assertTrue(self.image.exists())

    def test_unmounted_host_data_and_mountpoint_symlink_are_preserved(self):
        layout = self.unmounted_layout()
        foreign = self.mount / 'user-file.txt'; foreign.write_text('must remain')
        with self.assertRaisesRegex(RuntimeError, 'contains data'): self.inspect_unmounted(*layout)
        self.assertEqual(foreign.read_text(), 'must remain')
        foreign.unlink(); self.mount.rmdir()
        self.mount.symlink_to(self.parent / 'saved-source', target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, 'type changed'): self.inspect_unmounted(*layout)
        self.assertTrue(self.image.exists())

    def test_unmounted_volume_without_recorded_uuid_is_not_adopted(self):
        layout = self.unmounted_layout(); self.state.pop('volumeUUID')
        with self.assertRaisesRegex(RuntimeError, 'lacks an owned UUID'): self.inspect_unmounted(*layout)
        self.assertTrue(self.image.exists())

    def test_mounted_volume_with_an_extra_mount_is_rejected(self):
        mapping, info, containers = self.unmounted_layout()
        mapping['system-entities'][-1]['mount-point'] = str(self.mount)
        mapping['system-entities'].append({'dev-entry': '/dev/disk3s2', 'mount-point': str(self.parent / 'other')})
        with patch.object(fixture, 'image_mapping', return_value=mapping), \
             patch.object(fixture.os.path, 'ismount', return_value=True), \
             patch.object(fixture, 'command', side_effect=AssertionError('Must reject before disk commands')):
            with self.assertRaisesRegex(RuntimeError, 'does not match'): fixture.mounted_volume(self.state)
        self.assertTrue(self.image.exists())

    def test_busy_detach_recovers_when_only_the_filesystem_unmounts(self):
        busy = fixture.CommandFailure(['hdiutil'], 16, b'Resource busy')
        with patch.object(fixture, 'mounted_volume', side_effect=[('/dev/disk2', {}), fixture.ImageVolumeUnmounted()]), \
             patch.object(fixture, 'unmounted_image_device', return_value='/dev/disk9'), \
             patch.object(fixture, 'image_mapping', side_effect=[{'attached': True}, None]), \
             patch.object(fixture, 'command', side_effect=[busy, 'detached']) as command, \
             patch.object(fixture.time, 'sleep'):
            fixture.detach(self.state, self.state_path)
        self.assertEqual([call.args[0] for call in command.call_args_list],
                         [['/usr/bin/hdiutil', 'detach', '/dev/disk2'], ['/usr/bin/hdiutil', 'detach', '/dev/disk9']])
        self.assertEqual([event['volumeMounted'] for event in self.state['detachAttempts']], [True, False])
        self.assertEqual([event['exitCode'] for event in self.state['detachAttempts']], [16, 0])
        self.assertTrue(self.image.exists())


if __name__ == '__main__':
    unittest.main()
