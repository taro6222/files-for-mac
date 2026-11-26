#!/usr/bin/env python3
"""Observe a build's current descendant tree without restarting or timing it out."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import time


def save_json(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def process_snapshot():
    result = subprocess.run(
        ['/bin/ps', '-axo', 'pid=,ppid=,pgid=,etime=,pcpu=,rss=,stat=,comm='],
        capture_output=True, text=True, timeout=5, check=True, env=dict(os.environ, LC_ALL='C'))
    processes = []
    for line in result.stdout.splitlines():
        fields = line.split(None, 7)
        if len(fields) == 8:
            processes.append(dict(pid=int(fields[0]), parentPID=int(fields[1]), group=int(fields[2]),
                              elapsed=fields[3], cpuPercent=float(fields[4]), rssKiB=int(fields[5]),
                              state=fields[6], executable=fields[7]))
    return processes


def group_processes(group):
    return [p for p in process_snapshot() if p['group'] == group]


def descendant_processes(root):
    processes = process_snapshot()
    owned = {root}
    while True:
        expanded = owned | {p['pid'] for p in processes if p['parentPID'] in owned}
        if expanded == owned:
            return [p for p in processes if p['pid'] in owned]
        owned = expanded


def signal_group(group, signum):
    try:
        os.killpg(group, signum)
    except ProcessLookupError:
        return
    except PermissionError:
        # Darwin can return EPERM for a group containing only terminal remnants.
        # Never treat permission denial as completion while a live member remains.
        if any(not p['state'].startswith('Z') for p in group_processes(group)):
            raise


def collect(output, group, index, cancelled, track_observer):
    folder = output / f'observation-{index:02d}'
    folder.mkdir()
    observation = dict(processGroup=group, processTreeRoot=group, selection='current-parent-chain', processes=[], samples=[])
    try:
        owned = descendant_processes(group)
        observation['processes'] = owned
        # Prefer active compiler children to the idle package-manager parent.
        selected = sorted(owned, key=lambda p: (p['pid'] == group, -p['cpuPercent']))[:4]
        for entry in selected:
            if cancelled():
                break
            current = descendant_processes(group)
            if not any(p['pid'] == entry['pid'] and p['executable'] == entry['executable'] for p in current):
                continue
            sample_file = folder / f"sample-{entry['pid']}.txt"
            record = dict(pid=entry['pid'], executable=entry['executable'], file=sample_file.name)
            with (folder / f"sample-{entry['pid']}.log").open('wb') as log:
                try:
                    with subprocess.Popen(['/usr/bin/sample', str(entry['pid']), '1', '-file', str(sample_file)],
                                          stdout=log, stderr=subprocess.STDOUT) as observer:
                        record['observerPID'] = observer.pid
                        track_observer(observer)
                        try:
                            record['returnCode'] = observer.wait(timeout=8)
                        finally:
                            if observer.poll() is None:
                                observer.kill()
                            observer.wait()
                            track_observer(None)
                except (OSError, subprocess.TimeoutExpired) as error:
                    # Only the observer is bounded. The compiler keeps running.
                    record['error'] = type(error).__name__
            observation['samples'].append(record)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        observation['error'] = str(error)
    save_json(folder / 'processes.json', observation)
    return observation


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--diagnostic-after', type=float, default=120)
    parser.add_argument('--interval', type=float, default=240)
    parser.add_argument('--max-observations', type=int, default=4)
    parser.add_argument('--termination-grace', type=float, default=5)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command or not all(math.isfinite(v) and v > 0 for v in
                              [args.diagnostic_after, args.interval, args.termination_grace]) or not 1 <= args.max_observations <= 8:
        parser.error('A command, positive finite intervals, and 1...8 observations are required')
    args.output.mkdir(parents=True, exist_ok=False)
    started = time.monotonic()
    process = subprocess.Popen(command, start_new_session=True)
    requested_signal = None
    cancellation_started = None
    observations = []
    active_observer = None
    group_killed = False

    def track_observer(observer):
        nonlocal active_observer
        active_observer = observer
        if observer is not None and requested_signal is not None and observer.poll() is None:
            observer.kill()

    def forward(signum, _frame):
        nonlocal requested_signal, cancellation_started
        if requested_signal is None:
            requested_signal = signum
            cancellation_started = time.monotonic()
            signal_group(process.pid, signum)
            if active_observer is not None and active_observer.poll() is None:
                active_observer.kill()

    previous = {s: signal.signal(s, forward) for s in [signal.SIGTERM, signal.SIGINT]}
    next_observation = started + args.diagnostic_after
    try:
        while process.poll() is None:
            now = time.monotonic()
            if cancellation_started is not None:
                if now - cancellation_started >= args.termination_grace:
                    signal_group(process.pid, signal.SIGKILL)
                    group_killed = True
                    process.wait()
                    break
            elif now >= next_observation and len(observations) < args.max_observations:
                print(f'Collecting owned build processes after {now - started:.1f}s; build continues.', flush=True)
                try:
                    observations.append(collect(args.output, process.pid, len(observations) + 1,
                                                lambda: requested_signal is not None, track_observer))
                except (OSError, ValueError, subprocess.SubprocessError) as error:
                    observations.append(dict(error=str(error)))
                next_observation = time.monotonic() + args.interval
            time.sleep(0.1)
    finally:
        # Cancellation/observer failures must not leave a private compiler group behind.
        if not group_killed and (requested_signal is not None or process.poll() is None):
            signal_group(process.pid, signal.SIGKILL)
        process.wait()
        for signum, handler in previous.items():
            signal.signal(signum, handler)
        result = dict(command=command, processPID=process.pid, returnCode=process.returncode,
                      receivedSignal=requested_signal, elapsedSeconds=time.monotonic() - started,
                      observations=observations, restarted=False,
                      sourceSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
        save_json(args.output / 'result.json', result)
    return 128 + requested_signal if requested_signal is not None else (process.returncode if process.returncode >= 0 else 128 - process.returncode)


if __name__ == '__main__':
    raise SystemExit(main())
