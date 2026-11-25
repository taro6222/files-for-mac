#!/usr/bin/env python3
"""Hold only an owned Spotlight fixture open, observe real EBUSY, then verify safe cleanup retry."""
import argparse
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import time
import spotlight_volume_fixture as fixture

parser = argparse.ArgumentParser()
parser.add_argument('--state', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
state_path = args.state.resolve()
state = json.loads(state_path.read_text())
if args.output.exists():
    raise SystemExit('Refusing to overwrite an existing cleanup verification report')
if state.get('fixtureKind') != 'isolated-apfs-volume' or state.get('cleaned'):
    raise SystemExit('Prepare a fresh owned Spotlight volume first')
fixture.validate_resource(state, state_path)
fixture.mounted_volume(state)
fixture.validate_source_only(state)

def save(value):
    pending = state_path.with_suffix('.pending.json')
    pending.write_text(json.dumps(value, indent=2) + '\n'); pending.replace(state_path)

original_command = fixture.command
started = time.monotonic()
evidence = {'statePath': str(state_path), 'volumeUUID': state['volumeUUID'], 'detachCommands': [], 'busyExitCodes': []}
holder = None
try:
    code = ('import mmap,time; f=open("Fixture/Sources/FilesCore/LocalSearch.swift","rb"); '
            'mapping=mmap.mmap(f.fileno(),0,access=mmap.ACCESS_READ); '
            'print("ready",flush=True); time.sleep(120)')
    holder = subprocess.Popen([sys.executable, '-c', code], cwd=state['mountPoint'],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    evidence['holderPID'] = holder.pid
    with selectors.DefaultSelector() as selector:
        selector.register(holder.stdout, selectors.EVENT_READ)
        if not selector.select(timeout=10) or holder.stdout.readline().strip() != 'ready' or holder.poll() is not None:
            raise RuntimeError('The owned fixture holder did not become ready')

    def observe(arguments, *values, **options):
        detaching = arguments[:2] == ['/usr/bin/hdiutil', 'detach']
        if detaching:
            if '-force' in arguments:
                raise RuntimeError('Forced detach is forbidden')
            evidence['detachCommands'].append(arguments)
        try:
            return original_command(arguments, *values, **options)
        except fixture.CommandFailure as error:
            if detaching and error.returncode == 16:
                evidence['busyExitCodes'].append(error.returncode)
                if holder.poll() is None:
                    holder.terminate(); holder.wait(timeout=10)
            raise

    fixture.command = observe
    fixture.cleanup(state, state_path, save)
    evidence.update(cleaned=state.get('cleaned', False), readOnlyCleanupInspection=state.get('readOnlyCleanupInspection'))
    evidence['passed'] = bool(evidence['busyExitCodes']) and evidence['cleaned'] and evidence['readOnlyCleanupInspection'] == 'passed'
    if not evidence['passed']:
        raise RuntimeError('Cleanup finished, but this kernel did not expose a real busy retry')
except Exception as error:
    evidence['passed'] = False; evidence['error'] = str(error)
finally:
    fixture.command = original_command
    if holder is not None:
        if holder.poll() is None:
            holder.terminate()
            try: holder.wait(timeout=10)
            except subprocess.TimeoutExpired:
                holder.kill(); holder.wait(timeout=10)
        evidence['holderExitCode'] = holder.returncode
        if holder.stdout: holder.stdout.close()
    evidence['elapsedSeconds'] = time.monotonic() - started
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('x') as report:
        report.write(json.dumps(evidence, indent=2) + '\n')
print(json.dumps(evidence, indent=2))
raise SystemExit(0 if evidence['passed'] else 1)
