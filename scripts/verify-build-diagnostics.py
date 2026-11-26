#!/usr/bin/env python3
"""Exercise build observation, exit propagation, and cancellation with short headless fixtures."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def terminal(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    state = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'stat='], capture_output=True, text=True, timeout=3)
    return not state.stdout.strip() or state.stdout.lstrip().startswith('Z')


def verify(output):
    monitor = Path(__file__).with_name('build-with-diagnostics.py')
    checks = {}

    def check(name, condition):
        checks[name] = bool(condition)
        if not condition:
            raise RuntimeError('Failed: ' + name)

    for name, code, expected, observe in [
        ('success', 'print("compiler output preserved", flush=True)', 0, False),
        ('failure', 'import sys; sys.exit(23)', 23, False),
        ('observation', 'import time; print("one build", flush=True); time.sleep(2)', 0, True),
    ]:
        folder = output / name
        command = [sys.executable, str(monitor), '--output', str(folder)]
        if observe:
            command += ['--diagnostic-after', '.05', '--max-observations', '1']
        command += ['--', sys.executable, '-c', code]
        result = subprocess.run(command, capture_output=True, text=True, timeout=12)
        report = json.loads((folder / 'result.json').read_text())
        (folder / 'stdout.log').write_text(result.stdout)
        (folder / 'stderr.log').write_text(result.stderr)
        check(name + 'ExitPropagated', result.returncode == expected and report['returnCode'] == expected)
        check(name + 'NoRestart', report['restarted'] is False and terminal(report['processPID']))
        if name == 'success':
            check('CompilerOutputPreserved', 'compiler output preserved' in result.stdout)
        if observe:
            observations = report['observations']
            check('ObservationDidNotStopBuild', len(observations) == 1 and report['elapsedSeconds'] >= 2)
            samples = observations[0]['samples']
            check('ActualOwnedProcessSample', samples and all(s.get('returnCode') == 0 for s in samples))
            check('SampleToolsReaped', all(terminal(s['observerPID']) for s in samples))

    folder = output / 'cancellation'
    root_marker = output / 'fixture-parent.pid'
    child_marker = output / 'fixture-child.pid'
    child_code = 'import os,signal,time; from pathlib import Path; signal.signal(signal.SIGTERM,signal.SIG_IGN); Path(' + repr(str(child_marker)) + ').write_text(str(os.getpid())); time.sleep(30)'
    code = 'import os,signal,subprocess,sys,time; from pathlib import Path; signal.signal(signal.SIGTERM,signal.SIG_IGN); Path(' + repr(str(root_marker)) + ').write_text(str(os.getpid())); subprocess.Popen([sys.executable,"-c",' + repr(child_code) + ']); time.sleep(30)'
    command = [sys.executable, str(monitor), '--output', str(folder), '--diagnostic-after', '.05',
               '--termination-grace', '.25', '--max-observations', '1', '--', sys.executable, '-c', code]
    process = None
    with (output / 'cancellation.log').open('wb') as log:
        try:
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if root_marker.exists() and child_marker.exists() and list(folder.glob('observation-*/*.log')):
                    break
                if process.poll() is not None:
                    raise RuntimeError('Monitor exited before cancellation fixture was ready')
                time.sleep(.01)
            check('CancellationFixtureReady', root_marker.exists() and child_marker.exists() and list(folder.glob('observation-*/*.log')))
            process.send_signal(signal.SIGTERM)
            process.wait(timeout=5)
            report = json.loads((folder / 'result.json').read_text())
            check('CancellationPropagated', process.returncode == 143 and report['receivedSignal'] == signal.SIGTERM)
            check('CancelledBuildReaped', terminal(int(root_marker.read_text())))
            child_pid = int(child_marker.read_text())
            deadline = time.monotonic() + 2
            while not terminal(child_pid) and time.monotonic() < deadline:
                time.sleep(.01)
            check('CancelledBuildChildTerminated', terminal(child_pid))
            samples = [s for o in report['observations'] for s in o.get('samples', [])]
            check('CancelledObserversReaped', samples and all(terminal(s['observerPID']) for s in samples))
        finally:
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait()
            if root_marker.exists():
                pid = int(root_marker.read_text())
                try:
                    child_in_group = child_marker.exists() and not terminal(int(child_marker.read_text())) and os.getpgid(int(child_marker.read_text())) == pid
                    if (not terminal(pid) and os.getpgid(pid) == pid) or child_in_group:
                        os.killpg(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
    return checks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    checks = verify(args.output)
    result = dict(passed=all(checks.values()), checks=checks, productBuildVerified=False, localGUIStarted=False)
    (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
