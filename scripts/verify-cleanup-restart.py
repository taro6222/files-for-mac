#!/usr/bin/env python3
"""Terminate a dedicated FilesMac at an actual cleanup checkpoint, then inspect in a fresh process."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('--binary', type=Path, required=True)
parser.add_argument('--language', choices=['ko', 'en'], default='ko')
parser.add_argument('--theme', choices=['light', 'dark'], default='light')
args = parser.parse_args()
binary = args.binary.resolve(strict=True)
root = Path(tempfile.mkdtemp(prefix='files-cleanup-restart.')).resolve()
token = uuid.uuid4().hex
(root / '.files-cleanup-restart-qa.json').write_text(json.dumps({'id': token}))
print(f'Cleanup restart verification results: {root}', flush=True)
environment = dict(os.environ, FILES_CLEANUP_RESTART_QA_OUTPUT=str(root), FILES_CLEANUP_RESTART_QA_ID=token,
                   FILES_PROMISE_QA_THEME=args.theme, FILES_CLEANUP_RESTART_QA_PHASE='interrupt')
arguments = [str(binary), '-AppleLanguages', f'({args.language})', '-AppleLocale', args.language]
checkpoint = root / 'checkpoint.json'
with (root / 'interrupt.log').open('wb') as log:
    app = subprocess.Popen(arguments, env=environment, stdout=log, stderr=subprocess.STDOUT)
    try:
        deadline = time.monotonic() + 45
        while not checkpoint.exists():
            if app.poll() is not None:
                raise RuntimeError(f'Preparation terminated before checkpoint: {app.returncode}')
            if time.monotonic() > deadline:
                raise TimeoutError('No live cleanup checkpoint; do not restart the interrupted job')
            time.sleep(.1)
        state = json.loads(checkpoint.read_text())
        if state['id'] != token or state['preparePID'] != app.pid or app.poll() is not None:
            raise RuntimeError('Checkpoint does not identify the live QA child')
        journals = list((root / 'operations').glob('promise-cleanup-*.json'))
        if len(journals) != 1 or json.loads(journals[0].read_text())['state'] != 'verified':
            raise RuntimeError('Expected last journal state before the OS move location was recorded')
        journal_sha = hashlib.sha256(journals[0].read_bytes()).hexdigest()
        app.kill()
        status = app.wait(timeout=10)
        if status != -signal.SIGKILL:
            raise RuntimeError(f'Expected verified SIGKILL, got {status}')
        interruption = {'preparePID': app.pid, 'exitCode': status, 'checkpoint': state,
                        'journalSHA256BeforeKill': journal_sha}
        (root / 'interruption.json').write_text(json.dumps(interruption, indent=2) + '\n')
    finally:
        if app.poll() is None:
            app.kill(); app.wait(timeout=10)
with (root / 'inspect.log').open('wb') as log:
    subprocess.run(arguments, env=dict(environment, FILES_CLEANUP_RESTART_QA_PHASE='inspect'),
                   stdout=log, stderr=subprocess.STDOUT, timeout=45, check=True)
result = json.loads((root / 'report.json').read_text())
expected = {'freshFilesMacProcess', 'restartReadsLastVerifiedCheckpoint',
            'restartShowsNamesWithoutInventingLocation',
            'restartLeavesUnrecordedTrashLocationUnknown', 'restartPreservesReceivedPayload',
            'restartPreservesPublishedCopy', 'restartDoesNotRecreateOriginalDirectory',
            'restartHistoryReadsInterruptedJournal', 'restartHistoryDoesNotInventMovedLocation',
            'restartHistoryExplainsInterruptedState', 'restartHistoryControlsFitMinimumWindow',
            'restartHistoryCaptureWritten', 'restartDoesNotRewriteInterruptedJournal', 'restartFixtureReturnedFromTrash'}
if set(result['checks']) != expected or not all(value is True for value in result['checks'].values()):
    raise RuntimeError(f'Cleanup restart checks failed: {result}')
if result['preparePID'] != app.pid or result['inspectPID'] == app.pid:
    raise RuntimeError('The restart did not use distinct FilesMac processes')
if not result['language'].startswith(args.language) or result['theme'] != args.theme:
    raise RuntimeError('Reported language/theme differs from request')
if hashlib.sha256(journals[0].read_bytes()).hexdigest() != journal_sha:
    raise RuntimeError('Interrupted journal was modified')
print(f'{len(expected)} checks passed after verified SIGKILL and a fresh FilesMac process; fixture returned from Trash')
