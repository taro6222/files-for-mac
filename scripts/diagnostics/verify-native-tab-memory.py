#!/usr/bin/env python3
"""Measure owned standalone AppKit processes; this is not the product soak gate."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import time


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_case(binary, output, tabs, cycles):
    output.mkdir()
    observations = []
    with (output / 'app.log').open('wb') as log:
        with subprocess.Popen([str(binary)], env=dict(os.environ, PROBE_OUTPUT=str(output),
                              PROBE_TABS='1' if tabs else '0', PROBE_CYCLES=str(cycles)), stdout=log, stderr=subprocess.STDOUT) as app:
            checkpoints = sorted(set((5, 40, cycles)))
            deadline = time.monotonic() + max(120, cycles * .2 + 120)
            try:
                while app.poll() is None and time.monotonic() < deadline:
                    report = output / 'report.json'
                    current = json.loads(report.read_text()) if report.exists() else {}
                    cycle = current.get('cycle')
                    if current.get('state') == 'waiting' and cycle not in [v['cycle'] for v in observations]:
                        if cycle not in checkpoints:
                            raise RuntimeError(f'Unexpected checkpoint: {current}')
                        heap = output / f'heap-{cycle}.txt'
                        with heap.open('wb') as stream:
                            subprocess.run(['heap', '-s', str(app.pid)], stdout=stream,
                                           stderr=subprocess.STDOUT, timeout=20, check=True)
                        counts = {}
                        for cls in ('NSKeyValueDependencyContext', 'NSKeyValueDependency',
                                    'NSWindow', 'NSKVONotifying_NSWindow', 'NSWindowTab', 'NSTextField'):
                            match = re.search(r'^\s*(\d+)\s+\d+\s+[\d.]+\s+' + re.escape(cls) + r'\s',
                                              heap.read_text(), re.M)
                            counts[cls] = int(match[1]) if match else None
                        if counts.get(current['primaryClass']) != 1:
                            raise RuntimeError(f'Expected exactly one primary window: {counts}')
                        observation = {'cycle': cycle, 'counts': counts, 'heapSHA256': sha(heap),
                                       'releasedSecondaryWindows': current['releasedSecondaryWindows']}
                        observations.append(observation)
                        print(output.name, observation, flush=True)
                        (output / f'continue-{cycle}').touch()
                    time.sleep(.05)
                app.wait(timeout=5)
            finally:
                if app.poll() is None:
                    app.terminate()
                    try:
                        app.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        app.kill()
                        app.wait(timeout=5)
            final = json.loads((output / 'report.json').read_text())
            if app.returncode != 0 or final['state'] != 'completed' or [v['cycle'] for v in observations] != checkpoints:
                raise RuntimeError(f'Probe incomplete: {app.returncode}, {final}, {observations}')
    return {'exitCode': app.returncode, 'report': final, 'observations': observations}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--repetitions', type=int, default=3, choices=range(1, 6))
    parser.add_argument('--cycles', type=int, choices=(40, 400), default=400)
    args = parser.parse_args()
    binary, output = args.binary.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    cases = {}
    for repeat in range(1, args.repetitions + 1):
        for tabs in (False, True):
            name = f'{repeat}-' + ('tabs' if tabs else 'windows')
            cases[name] = run_case(binary, output / name, tabs, args.cycles)
    result = {'architecture': platform.machine(), 'os': platform.platform(), 'binarySHA256': sha(binary),
              'probeSourceSHA256': sha(Path(__file__).with_name('NativeTabMemoryProbe.swift')),
              'harnessSHA256': sha(Path(__file__)), 'cases': cases, 'productChanged': False,
              'stabilityGatePassed': False,
              'limits': ['Short standalone AppKit diagnostic; no Files application code is linked.',
                         'Missing runtime classes are null, not zero or a stability pass.',
                         'Counts do not establish physical-footprint stability, all product growth causes, or OS defect ownership.',
                         'Different SDK/runtime combinations are not a controlled OS-only comparison.',
                         'A completed diagnostic can show growth; growth does not turn this runner into a product acceptance gate.']}
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print('Completed native AppKit diagnostics; product stability gate remains separate.', flush=True)


if __name__ == '__main__':
    main()
