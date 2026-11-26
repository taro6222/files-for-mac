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

    detached_marker = output.resolve() / 'detached-child.pid'
    observation_release = output.resolve() / 'observation-release'
    detached_release = output.resolve() / 'detached-observation-release'
    def held_fixture(release, message=''):
        # Keep the subject alive until sampling has completed, not an assumed
        # machine-specific launch delay. The fixture still has a finite lifetime.
        return ('import time; from pathlib import Path; start=time.monotonic(); '
                + 'print(' + repr(message) + ',flush=True); '
                + 'release=Path(' + repr(str(release)) + '); '
                + '\nwhile (not release.exists() or time.monotonic()-start<2) and time.monotonic()-start<8: time.sleep(.01)'
                + '\nassert release.exists(), "observer did not finish"')
    child_code = held_fixture(detached_release)
    detached_code = 'import subprocess,sys,time; from pathlib import Path; time.sleep(.2); child=subprocess.Popen([sys.executable,"-c",' + repr(child_code) + '],start_new_session=True); Path(' + repr(str(detached_marker)) + ').write_text(str(child.pid)); sys.exit(child.wait())'
    # This adapter only gates the real collector on fixture readiness. It does not
    # change collection, sampling, process ownership, results, or CLI deadlines.
    # The deliberate child launch delay makes an ungated 50ms observation too early.
    ready_observer = output.resolve() / 'ready-observer.py'
    ready_observer.write_text("""import importlib.util, time
from pathlib import Path
spec = importlib.util.spec_from_file_location('build_monitor', """ + repr(str(monitor.resolve())) + """)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
original = module.collect
marker = Path(""" + repr(str(detached_marker)) + """)
def collect(*args, **kwargs):
 deadline = time.monotonic() + 5
 while not marker.is_file():
  if time.monotonic() >= deadline: raise RuntimeError('fixture child never became ready')
  time.sleep(.01)
 return original(*args, **kwargs)
module.collect = collect
module.main()
""")

    for name, code, expected, observe in [
        ('success', 'print("compiler output preserved", flush=True)', 0, False),
        ('failure', 'import sys; sys.exit(23)', 23, False),
        ('observation', held_fixture(observation_release, 'one build'), 0, True),
        ('detached-observation', detached_code, 0, True),
    ]:
        folder = output / name
        command = [sys.executable, str(ready_observer if name == 'detached-observation' else monitor), '--output', str(folder)]
        if observe:
            command += ['--diagnostic-after', '.05', '--max-observations', '1']
        command += ['--', sys.executable, '-c', code]
        unrelated = None
        unrelated_was_live = False
        try:
            if name == 'detached-observation':
                unrelated = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'],
                                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if observe:
                release = detached_release if name == 'detached-observation' else observation_release
                started = time.monotonic()
                with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as live:
                    try:
                        while live.poll() is None and not (folder / 'observation-01/processes.json').is_file():
                            if time.monotonic() - started >= 10: raise subprocess.TimeoutExpired(command, 10)
                            time.sleep(.01)
                        release.write_text('sampling completed')
                        stdout, stderr = live.communicate(timeout=max(.1, 12 - (time.monotonic() - started)))
                        result = subprocess.CompletedProcess(command, live.returncode, stdout, stderr)
                    except BaseException:
                        live.kill(); live.wait(); raise
            else:
                result = subprocess.run(command, capture_output=True, text=True, timeout=12)
            unrelated_was_live = unrelated is not None and unrelated.poll() is None
        finally:
            if unrelated is not None:
                unrelated.terminate(); unrelated.wait(timeout=3)
        report = json.loads((folder / 'result.json').read_text())
        (folder / 'stdout.log').write_text(result.stdout)
        (folder / 'stderr.log').write_text(result.stderr)
        check(name + 'ExitPropagated', result.returncode == expected and report['returnCode'] == expected)
        check(name + 'NoRestart', report['restarted'] is False and terminal(report['processPID']))
        if name == 'success':
            check('CompilerOutputPreserved', 'compiler output preserved' in result.stdout)
        if observe:
            observations = report['observations']
            prefix = 'Detached' if name == 'detached-observation' else ''
            check(prefix + 'ObservationDidNotStopBuild', len(observations) == 1 and report['elapsedSeconds'] >= 2)
            samples = observations[0]['samples']
            check(prefix + 'SubjectReleasedAfterSampling', release.is_file() and report['returnCode'] == 0)
            check(prefix + 'ActualOwnedProcessSample', samples and all(s.get('returnCode') == 0 for s in samples))
            check(prefix + 'SampleToolsReaped', all(terminal(s['observerPID']) for s in samples))
            if prefix:
                child = int(detached_marker.read_text())
                selected = next((p for p in observations[0]['processes'] if p['pid'] == child), None)
                check('DifferentGroupChildCollected', selected is not None and selected['group'] != report['processPID'] and selected['parentPID'] == report['processPID'])
                check('DifferentGroupChildSampled', any(s['pid'] == child and s.get('returnCode') == 0 for s in samples))
                check('DetachedChildEnded', terminal(child))
                check('UnrelatedProcessExcluded', unrelated_was_live and all(p['pid'] != unrelated.pid for p in observations[0]['processes'])
                      and all(s['pid'] != unrelated.pid for s in samples))

    folder = output / 'cancellation'
    root_marker = output / 'fixture-parent.pid'
    child_marker = output / 'fixture-child.pid'
    child_code = 'import os,signal,time; from pathlib import Path; signal.signal(signal.SIGTERM,signal.SIG_IGN); Path(' + repr(str(child_marker)) + ').write_text(str(os.getpid())); time.sleep(30)'
    code = 'import os,signal,subprocess,sys,time; from pathlib import Path; signal.signal(signal.SIGTERM,signal.SIG_IGN); Path(' + repr(str(root_marker)) + ').write_text(str(os.getpid())); subprocess.Popen([sys.executable,"-c",' + repr(child_code) + ']); time.sleep(30)'
    command = [sys.executable, str(monitor), '--output', str(folder), '--diagnostic-after', '.05',
               '--termination-grace', '.25', '--max-observations', '1', '--', sys.executable, '-c', code]
    # Reproduce macOS's EPERM for a redundant SIGKILL after the group has died.
    # The first call still kills the real private fixture group.
    fault = output / 'late-signal-fixture'
    fault.mkdir()
    deliveries = output.resolve() / 'group-kill-deliveries.jsonl'
    (fault / 'sitecustomize.py').write_text('''import errno,json,os,signal
from pathlib import Path
original = os.killpg
kill_count = 0
def killpg(group, sig):
 global kill_count
 if sig == signal.SIGKILL:
  kill_count += 1
  with Path(''' + repr(str(deliveries)) + ''').open('a') as log:
   log.write(json.dumps(dict(caller=os.getpid(),group=group,count=kill_count))+'\\n')
  if kill_count > 1:
   raise PermissionError(errno.EPERM, 'fixture: group already terminated')
 return original(group, sig)
os.killpg = killpg
''')
    process = None
    with (output / 'cancellation.log').open('wb') as log:
        try:
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                                       env=dict(os.environ, PYTHONPATH=str(fault.resolve())))
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
            calls = [json.loads(line) for line in deliveries.read_text().splitlines()]
            check('NoRedundantGroupKill', len(calls) == 1 and calls[0]['group'] == report['processPID'])
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
    normal = output / 'normal-cancellation'
    marker = output.resolve() / 'normal-fixture.pid'
    (fault / 'sitecustomize.py').write_text('''import errno,os,signal
original = os.killpg
def killpg(group, sig):
 if sig == signal.SIGKILL:
  raise PermissionError(errno.EPERM, 'fixture: terminal group')
 return original(group, sig)
os.killpg = killpg
''')
    code = 'import os,time; from pathlib import Path; Path(' + repr(str(marker)) + ').write_text(str(os.getpid())); time.sleep(30)'
    command = [sys.executable, str(monitor), '--output', str(normal), '--', sys.executable, '-c', code]
    with (output / 'normal-cancellation.log').open('wb') as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                                   env=dict(os.environ, PYTHONPATH=str(fault.resolve())))
        try:
            deadline = time.monotonic() + 5
            while not marker.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(.01)
            check('NormalCancellationReady', marker.exists())
            process.send_signal(signal.SIGTERM)
            process.wait(timeout=5)
            report = json.loads((normal / 'result.json').read_text())
            check('TerminalGroupPermissionPreservesReport', process.returncode == 143 and report['receivedSignal'] == signal.SIGTERM)
            check('NormalCancelledBuildReaped', terminal(int(marker.read_text())))
        finally:
            if process.poll() is None:
                process.kill(); process.wait()
            if marker.exists():
                pid = int(marker.read_text())
                try:
                    if not terminal(pid) and os.getpgid(pid) == pid:
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
