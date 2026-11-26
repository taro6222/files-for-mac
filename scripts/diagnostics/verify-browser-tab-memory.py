#!/usr/bin/env python3
"""Sample an owned, optimized Files soak process; short runs do not pass the 8-hour gate."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--seconds', type=int, default=180)
    parser.add_argument('--workload', choices=('full', 'tabs', 'windows', 'navigation'), default='full')
    args = parser.parse_args()
    if args.seconds < 120:
        parser.error('At least 120 seconds are needed for the 5/40-cycle samples.')
    binary, output = args.binary.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    spec = importlib.util.spec_from_file_location('native_memory', Path(__file__).with_name('verify-native-tab-memory.py'))
    native = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(native)
    observations = []
    report = {}
    failure = None
    with (output / 'app.log').open('wb') as log:
        with subprocess.Popen([str(binary), '-AppleLanguages', '(en)', '-AppleLocale', 'en'],
                              env=dict(os.environ, FILES_SOAK_DIRECTORY=str(output),
                                       FILES_SOAK_SECONDS=str(args.seconds), FILES_SOAK_WORKLOAD=args.workload),
                              stdout=log, stderr=subprocess.STDOUT) as app:
            deadline = time.monotonic() + args.seconds + 60
            last_cycle, last_progress = -1, time.monotonic()
            sampled_stalls = set()
            try:
                while app.poll() is None:
                    if time.monotonic() > deadline:
                        raise TimeoutError('Owned Files process exceeded its duration plus 60-second cleanup budget')
                    path = output / 'report.json'
                    if path.exists():
                        report = json.loads(path.read_text())
                    cycle = report.get('cycles', -1)
                    if cycle != last_cycle:
                        last_cycle, last_progress = cycle, time.monotonic()
                    elif time.monotonic() - last_progress >= 8 and cycle not in sampled_stalls:
                        sampled_stalls.add(cycle)
                        sample_path = output / f'stalled-cycle-{cycle}.txt'
                        with sample_path.with_suffix('.log').open('wb') as diagnostic:
                            try:
                                subprocess.run(['sample', str(app.pid), '1', '-file', str(sample_path)],
                                               stdout=diagnostic, stderr=subprocess.STDOUT, timeout=5, check=True)
                            except (OSError, subprocess.SubprocessError) as error:
                                diagnostic.write(repr(error).encode())
                    index = len(observations)
                    if index < 2 and report.get('cycles', 0) >= (5, 40)[index]:
                        heap = output / f'heap-{index}.txt'
                        native.collect_heap(app.pid, heap)
                        counts = {}
                        for cls in ('NSKeyValueDependencyContext', 'NSKeyValueDependency', 'BrowserWindow',
                                    'BrowserTabWindow', 'NSWindowTab', 'NSStackView'):
                            match = re.search(r'^\s*(\d+)\s+\d+\s+[\d.]+\s+' + re.escape(cls) + r'\s', heap.read_text(), re.M)
                            counts[cls] = int(match[1]) if match else None
                        observations.append({'cyclesBefore': report['cycles'],
                                             'cyclesAfter': json.loads(path.read_text())['cycles'],
                                             'counts': counts, 'heapSHA256': native.sha(heap)})
                        print(observations[-1], flush=True)
                    time.sleep(.1)
                app.wait(timeout=5)
                report = json.loads((output / 'report.json').read_text())
                if (app.returncode or report.get('state') != 'completed' or len(observations) != 2
                        or report.get('targetSeconds') != args.seconds or report.get('workload') != args.workload
                        or report.get('elapsedSeconds', 0) < args.seconds):
                    raise RuntimeError('Files did not complete its workload and both heap samples')
            except (OSError, ValueError, subprocess.SubprocessError, RuntimeError) as error:
                failure = repr(error)
            finally:
                if app.poll() is None:
                    app.terminate()
                    try:
                        app.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        app.kill(); app.wait(timeout=5)
    result = {'binarySHA256': native.sha(binary), 'harnessSHA256': native.sha(Path(__file__)),
              'architecture': platform.machine(), 'os': platform.platform(), 'durationSeconds': args.seconds,
              'workload': args.workload, 'exitStatus': app.returncode, 'report': report,
              'observations': observations, 'failure': failure, 'stabilityGatePassed': False,
              'limits': ['Short owned-process diagnostic; the latest-source 8-hour gate remains separate.',
                         'Heap sampling spans a reported cycle range rather than pausing the application.',
                         'Missing classes are null; counts alone do not establish physical-memory stability.']}
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    if failure:
        raise SystemExit(failure)
    print('Completed short product diagnostic; long-duration stability remains separate.', flush=True)


if __name__ == '__main__':
    main()
