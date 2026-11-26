"""Owned, source-only APFS image used by the real Spotlight integration fixture."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import tempfile
import time

MARKER = '.files-mac-spotlight-volume.json'
FIXTURE_MARKER = '.files-mac-spotlight-qa.json'
SOURCE = Path('Sources/FilesCore/LocalSearch.swift')


class CommandFailure(RuntimeError):
    def __init__(self, arguments, returncode, stderr):
        self.arguments = arguments
        self.returncode = returncode
        super().__init__(f'{arguments[0]} failed ({returncode}): ' + os.fsdecode(stderr))


class ImageVolumeUnmounted(RuntimeError):
    """The owned image is attached, with no filesystem mounted from it."""


def command(arguments, timeout=60, plist=False):
    result = subprocess.run(arguments, capture_output=True, timeout=timeout)
    if result.returncode:
        raise CommandFailure(arguments, result.returncode, result.stderr)
    return plistlib.loads(result.stdout) if plist else os.fsdecode(result.stdout)


def identity(path, kind):
    info = path.lstat()
    if stat.S_IFMT(info.st_mode) != kind:
        raise RuntimeError('Owned fixture entry type changed: ' + str(path))
    return [info.st_dev, info.st_ino]


def image_mapping(state):
    wanted = Path(state['image']).resolve()
    images = command(['/usr/bin/hdiutil', 'info', '-plist'], plist=True).get('images', [])
    matches = [image for image in images if Path(image.get('image-path', '')).resolve() == wanted]
    if len(matches) > 1:
        raise RuntimeError('Ambiguous image attachment; cleanup refused')
    return matches[0] if matches else None


def validate_resource(state, state_path):
    base = Path(state['resourceDirectory'])
    if base.parent != state_path.parent or not base.name.startswith('volume.') \
            or identity(base, stat.S_IFDIR) != state['resourceIdentity']:
        raise RuntimeError('Fixture resource directory changed; cleanup refused')
    marker = base / MARKER
    if marker.is_symlink() or json.loads(marker.read_text()) != {'id': state['id'], 'sourceSHA256': state['sourceSHA256']}:
        raise RuntimeError('Fixture resource marker changed; cleanup refused')
    if Path(state['image']) != base / 'source.dmg' or Path(state['mountPoint']) != base / 'Volume' \
            or Path(state['fixtureRoot']) != base / 'Volume/Fixture':
        raise RuntimeError('Fixture resource paths changed; cleanup refused')
    if set(p.name for p in base.iterdir()) - {MARKER, 'source.dmg', 'Volume'}:
        raise RuntimeError('Unrecognized resource-directory data; cleanup refused')
    image = Path(state['image'])
    if image.exists() or image.is_symlink():
        current = identity(image, stat.S_IFREG)
        if state.get('imageIdentity') != current:
            raise RuntimeError('Backing image identity changed; cleanup refused')


def image_device(mapping):
    devices = [entry['dev-entry'] for entry in mapping.get('system-entities', [])
               if entry.get('content-hint') == 'GUID_partition_scheme' and
               re.fullmatch(r'/dev/disk[0-9]+', entry.get('dev-entry', ''))]
    if len(devices) != 1:
        raise RuntimeError('Could not identify the image device from its current attachment')
    return devices[0]


def validate_volume_layout(state, mapping, info):
    if info.get('FilesystemType') != 'apfs' or not info.get('VolumeUUID'):
        raise RuntimeError('Expected an APFS volume with a stable UUID')
    if state.get('volumeUUID') and info['VolumeUUID'] != state['volumeUUID']:
        raise RuntimeError('Mounted volume UUID changed; cleanup refused')
    device = image_device(mapping)
    container = info.get('APFSContainerReference', '')
    volume = info.get('DeviceIdentifier', '')
    if not re.fullmatch(r'disk[0-9]+', container) or not re.fullmatch(r'disk[0-9]+s[0-9]+', volume):
        raise RuntimeError('Missing APFS container or volume identity; cleanup refused')
    containers = command(['/usr/sbin/diskutil', 'apfs', 'list', '-plist', container], plist=True).get('Containers', [])
    if len(containers) != 1 or containers[0].get('ContainerReference') != container:
        raise RuntimeError('APFS container identity changed; cleanup refused')
    stores, volumes = containers[0].get('PhysicalStores', []), containers[0].get('Volumes', [])
    if len(stores) != 1 or len(volumes) != 1 or volumes[0].get('APFSVolumeUUID') != info['VolumeUUID'] \
            or volumes[0].get('DeviceIdentifier') != volume:
        raise RuntimeError('Image must contain exactly one owned APFS volume; cleanup refused')
    store = stores[0].get('DeviceIdentifier', '')
    if not re.fullmatch(re.escape(device.removeprefix('/dev/')) + r's[0-9]+', store):
        raise RuntimeError('APFS physical store belongs to another image; cleanup refused')
    expected_devices = {device, '/dev/' + store, '/dev/' + container, '/dev/' + volume}
    actual_devices = [entry.get('dev-entry') for entry in mapping.get('system-entities', [])]
    if len(actual_devices) != 4 or set(actual_devices) != expected_devices:
        raise RuntimeError('Unrecognized image partitions or volumes; cleanup refused')
    return device


def mounted_volume(state):
    mount = Path(state['mountPoint'])
    mapping = image_mapping(state)
    if not mapping:
        raise RuntimeError('Owned image is not attached')
    entries = mapping.get('system-entities', [])
    mounted = [entry for entry in entries if entry.get('mount-point')]
    if not mounted and not os.path.ismount(mount):
        raise ImageVolumeUnmounted('Owned image is attached but its volume is unmounted')
    if len(mounted) != 1 or Path(mounted[0]['mount-point']).resolve() != mount.resolve() or not os.path.ismount(mount):
        raise RuntimeError('Image mount does not match the owned mount point')
    info = command(['/usr/sbin/diskutil', 'info', '-plist', str(mount)], plist=True)
    return validate_volume_layout(state, mapping, info), info


def unmounted_image_device(state):
    mapping = image_mapping(state)
    mount = Path(state['mountPoint'])
    if not mapping or any(entry.get('mount-point') for entry in mapping.get('system-entities', [])) or os.path.ismount(mount):
        raise RuntimeError('Unmounted image state changed; cleanup refused')
    identity(mount, stat.S_IFDIR)
    if any(mount.iterdir()) or not state.get('volumeUUID'):
        raise RuntimeError('Unmounted mount point contains data or lacks an owned UUID; cleanup refused')
    info = command(['/usr/sbin/diskutil', 'info', '-plist', state['volumeUUID']], plist=True)
    if info.get('MountPoint') or info.get('Mounted') is True:
        raise RuntimeError('Owned volume is mounted elsewhere; cleanup refused')
    return validate_volume_layout(state, mapping, info)


def attach(state, save, readonly=False):
    arguments = ['/usr/bin/hdiutil', 'attach', '-mountpoint', state['mountPoint'], '-owners', 'on', '-plist']
    if readonly:
        arguments.append('-readonly')
    arguments.append(state['image'])
    command(arguments, plist=True)
    device, info = mounted_volume(state)
    if readonly and info.get('WritableVolume') is not False:
        raise RuntimeError('Final source-only inspection requires a read-only mount')
    state.update(imageDevice=device, volumeUUID=info['VolumeUUID'], attachedReadOnly=readonly)
    save(state)
    return info


def create(state, state_path, save):
    state_path.parent.mkdir(parents=True, exist_ok=True)
    base = Path(tempfile.mkdtemp(prefix='volume.', dir=state_path.parent))
    mount = base / 'Volume'; mount.mkdir()
    state.update(fixtureKind='isolated-apfs-volume', resourceDirectory=str(base),
                 resourceIdentity=identity(base, stat.S_IFDIR), image=str(base / 'source.dmg'),
                 mountPoint=str(mount), fixtureRoot=str(mount / 'Fixture'))
    (base / MARKER).write_text(json.dumps({'id': state['id'], 'sourceSHA256': state['sourceSHA256']}))
    save(state)
    try:
        state['createVolume'] = command(['/usr/bin/hdiutil', 'create', '-size', '256m', '-fs', 'APFS',
                                         '-volname', 'FilesMac-Spotlight-' + state['id'][:8], state['image']])
    finally:
        image = Path(state['image'])
        if image.exists() and not image.is_symlink():
            state['imageIdentity'] = identity(image, stat.S_IFREG)
        save(state)
    attach(state, save)
    root = Path(state['fixtureRoot']); root.mkdir(mode=0o755)
    state.update(device=root.stat().st_dev, inode=root.stat().st_ino)
    save(state)
    return root


def validate_source_only(state):
    mount = Path(state['mountPoint']); root = Path(state['fixtureRoot'])
    allowed = {'Fixture', '.Spotlight-V100', '.fseventsd', '.Trashes', '.TemporaryItems', '.DocumentRevisions-V100'}
    if set(p.name for p in mount.iterdir()) - allowed:
        raise RuntimeError('Unrecognized data on the fixture volume; cleanup refused')
    for name in ['.Spotlight-V100', '.fseventsd']:
        entry = mount / name
        if entry.exists() or entry.is_symlink():
            identity(entry, stat.S_IFDIR)
    # Trash, temporary and revision data might contain user files, not just index metadata.
    for name in ['.Trashes', '.TemporaryItems', '.DocumentRevisions-V100']:
        directory = mount / name
        if directory.is_symlink():
            raise RuntimeError('Unexpected volume metadata link; cleanup refused')
        if directory.exists() and any(not p.is_dir() or p.is_symlink() for p in directory.rglob('*')):
            raise RuntimeError('Volume contains discarded or temporary user data; cleanup refused')
    published = state.get('sourcePublished', True)
    if not root.exists() and not root.is_symlink() and not published:
        return
    root_identity = identity(root, stat.S_IFDIR)
    if state.get('inode') is not None and root_identity[1] != state['inode']:
        raise RuntimeError('Source fixture directory changed; cleanup refused')
    marker = root / FIXTURE_MARKER
    if marker.exists() or marker.is_symlink():
        if marker.is_symlink() or json.loads(marker.read_text()) != {'id': state['id'], 'sourceSHA256': state['sourceSHA256']}:
            raise RuntimeError('Source fixture ownership marker changed; cleanup refused')
    elif published:
        raise RuntimeError('Published source fixture marker is missing; cleanup refused')
    paths = list(root.rglob('*'))
    files = {p.relative_to(root).as_posix() for p in paths if p.is_file()}
    directories = {p.relative_to(root).as_posix() for p in paths if p.is_dir()}
    expected_files = {SOURCE.as_posix(), FIXTURE_MARKER}
    expected_directories = {'Sources', 'Sources/FilesCore'}
    if any(p.is_symlink() or not (p.is_file() or p.is_dir()) for p in paths) \
            or files - expected_files or directories - expected_directories \
            or (published and (files != expected_files or directories != expected_directories)):
        raise RuntimeError('Source fixture contains unrecognized data; cleanup refused')
    copied = root / SOURCE
    if copied.exists():
        data = copied.read_bytes()
        if hashlib.sha256(data).hexdigest() != state['sourceSHA256']:
            reference = Path(__file__).resolve().parent.parent / SOURCE
            original = reference.read_bytes()
            if published or hashlib.sha256(original).hexdigest() != state['sourceSHA256'] or not original.startswith(data):
                raise RuntimeError('Source fixture bytes changed; cleanup refused')



def detach(state, state_path, save=None):
    # Indexers may briefly retain the just-finished query volume. Never force an unmount.
    for attempt in range(5):
        validate_resource(state, state_path)
        try:
            device, _ = mounted_volume(state)
            validate_source_only(state)
            mounted = True
        except ImageVolumeUnmounted:
            device = unmounted_image_device(state)
            mounted = False
        event = {'attempt': attempt + 1, 'device': device, 'volumeMounted': mounted}
        state.setdefault('detachAttempts', []).append(event)
        if save: save(state)
        try:
            command(['/usr/bin/hdiutil', 'detach', device], timeout=60)
        except CommandFailure as error:
            event['exitCode'] = error.returncode
            if save: save(state)
            if error.returncode != 16 or attempt == 4:
                raise
            remaining = image_mapping(state)
            event['remainingEntities'] = [{key: entry[key] for key in ['dev-entry', 'mount-point', 'content-hint'] if key in entry}
                                          for entry in (remaining or {}).get('system-entities', [])]
            if save: save(state)
            if not remaining:
                return
            time.sleep(1)
            continue
        event['exitCode'] = 0
        if save: save(state)
        if image_mapping(state):
            raise RuntimeError('Image remains attached; resources retained')
        return


def cleanup(state, state_path, save):
    if state.get('cleaned'):
        print('Owned Spotlight volume was already cleaned.')
        return
    validate_resource(state, state_path)
    if image_mapping(state):
        detach(state, state_path, save)
    # Inspect the final immutable filesystem, avoiding a write between inspection and unmount.
    if Path(state['image']).exists():
        attach(state, save, readonly=True)
        try:
            validate_source_only(state)
            state['readOnlyCleanupInspection'] = 'passed'; save(state)
        except Exception:
            # Keep the mounted image and backing file for inspection; never delete unknown data.
            raise
        detach(state, state_path, save)
    validate_resource(state, state_path)
    mount = Path(state['mountPoint'])
    if mount.is_symlink() or (mount.exists() and any(mount.iterdir())):
        raise RuntimeError('Unrecognized data in the unmounted mount point; cleanup refused')
    if image_mapping(state):
        raise RuntimeError('Image reattached during cleanup; resources retained')
    image = Path(state['image'])
    if image.exists():
        image.unlink()
    if mount.exists():
        mount.rmdir()
    base = Path(state['resourceDirectory'])
    (base / MARKER).unlink(); base.rmdir()
    state.update(cleaned=True, volumeDetached=True)
    save(state)
    print('Detached and removed only the verified source-only Spotlight image.')
