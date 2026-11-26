#!/usr/bin/env python3
"""Exercise real unmounted-image recovery and preservation of unknown volume data."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import time
import uuid
import spotlight_volume_fixture as fixture

parser = argparse.ArgumentParser()
parser.add_argument('--state', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--verify-foreign-data', action='store_true')
args = parser.parse_args()
state_path = args.state.resolve()
state = json.loads(state_path.read_text())
if args.output.exists():
    raise SystemExit('Refusing to overwrite an existing cleanup verification report')
if state.get('fixtureKind') != 'isolated-apfs-volume' or state.get('cleaned'):
    raise SystemExit('Prepare a fresh owned Spotlight volume first')

def save(value):
    pending = state_path.with_suffix('.pending.json')
    pending.write_text(json.dumps(value, indent=2) + '\n'); pending.replace(state_path)

evidence = {'statePath': str(state_path), 'volumeUUID': state.get('volumeUUID'), 'passed': False}
started = time.monotonic()
try:
    fixture.validate_resource(state, state_path)
    fixture.mounted_volume(state)
    fixture.validate_source_only(state)
    probe = None
    if args.verify_foreign_data:
        probe = Path(state['mountPoint']) / ('.cleanup-preservation-' + uuid.uuid4().hex + '.txt')
        payload = ('Synthetic cleanup preservation probe ' + uuid.uuid4().hex).encode()
        with probe.open('xb') as stream: stream.write(payload)
        probe_inode = fixture.identity(probe, stat.S_IFREG)[1]
        evidence['probeSHA256'] = hashlib.sha256(payload).hexdigest()
    fixture.command(['/usr/sbin/diskutil', 'unmount', state['mountPoint']])
    evidence['imageAttachedWithUnmountedVolume'] = fixture.image_mapping(state) is not None and not os.path.ismount(state['mountPoint'])
    if not evidence['imageAttachedWithUnmountedVolume']:
        raise RuntimeError('The kernel did not leave the expected detached-filesystem state')
    if probe is None:
        fixture.cleanup(state, state_path, save)
    else:
        try:
            fixture.cleanup(state, state_path, save)
        except RuntimeError as error:
            evidence['cleanupRejection'] = str(error)
        else:
            raise RuntimeError('Cleanup did not preserve unexpected data')
        fixture.validate_resource(state, state_path)
        device, info = fixture.mounted_volume(state)
        evidence['foreignDataPreservedReadOnly'] = (info.get('WritableVolume') is False and probe.read_bytes() == payload
                                                   and Path(state['image']).exists() and not state.get('cleaned'))
        if not evidence['foreignDataPreservedReadOnly']:
            raise RuntimeError('Unknown data was not preserved on a read-only mounted image')
        # Remove only the exact synthetic file created above, after verifying the same volume again.
        # Other unknown data is never removed; normal cleanup will still reject it.
        fixture.command(['/usr/bin/hdiutil', 'detach', device])
        if fixture.image_mapping(state):
            raise RuntimeError('Image remains attached; verification resources retained')
        fixture.attach(state, save)
        fixture.validate_resource(state, state_path)
        fixture.mounted_volume(state)
        if fixture.identity(probe, stat.S_IFREG)[1] != probe_inode or probe.read_bytes() != payload:
            raise RuntimeError('Synthetic probe identity changed; resources retained')
        probe.unlink()
        fixture.cleanup(state, state_path, save)
    evidence.update(cleaned=state.get('cleaned', False), readOnlyCleanupInspection=state.get('readOnlyCleanupInspection'),
                    detachAttempts=state.get('detachAttempts', []))
    evidence['passed'] = evidence['cleaned'] and evidence['readOnlyCleanupInspection'] == 'passed'
except Exception as error:
    evidence['error'] = str(error)
finally:
    evidence['elapsedSeconds'] = time.monotonic() - started
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('x') as stream: stream.write(json.dumps(evidence, indent=2) + '\n')
print(json.dumps(evidence, indent=2))
raise SystemExit(0 if evidence['passed'] else 1)
