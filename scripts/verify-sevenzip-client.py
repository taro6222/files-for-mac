#!/usr/bin/env python3
"""Require the real native SDK/Swift client tests without silently skipping fixtures."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess

TESTS = [
    'sevenZipSDKFramedClientRejectsMalformedReplies', 'sevenZipSDKFragmentedReplyAndClose',
    'sevenZipSDKEOFOnDiagnosticPipeIsNotDiagnosticData',
    'sevenZipSDKTimeoutAndCancellationReapOwnedChild', 'sevenZipSDKValidatesPathsBeforeStaging',
    'sevenZipSDKEncryptedRoundTripAndFailureStaging', 'sevenZipSDKCorruptionAndLinksNeverPublish',
    'sevenZipSDKPublicationConflictAndForeignStagingPreservation', 'sevenZipSDKCancellationBeforePublicationDiscardsStaging',
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--worker', type=Path, required=True)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--library', type=Path)
    parser.add_argument('--bundle-manifest', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    environment = dict(os.environ, FILES_TEST_SEVENZIP_WORKER=str(args.worker.resolve()),
                       FILES_TEST_SEVENZIP_REFERENCE=str(args.reference.resolve()))
    if args.library: environment['FILES_TEST_SEVENZIP_LIBRARY'] = str(args.library.resolve())
    else: environment.pop('FILES_TEST_SEVENZIP_LIBRARY', None)
    timed_out = False
    with (args.output / 'run.log').open('wb') as log:
        process = subprocess.Popen(['swift', 'test', '--skip-build', '--disable-xctest', '--no-parallel', '--filter', 'sevenZipSDK'],
                                   env=environment, stdout=log, stderr=log, start_new_session=True)
        try: process.wait(timeout=120)
        except subprocess.TimeoutExpired:
            timed_out = True
            try: os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            process.wait()
    log_path = args.output / 'run.log'
    text = log_path.read_text(errors='replace') if log_path.stat().st_size <= 8 * 1024 * 1024 else ''
    observed = {name: bool(re.search(r'Test ' + re.escape(name) + r'\(\) passed after', text)) for name in TESTS}
    passed = process.returncode == 0 and not timed_out and all(observed.values()) and 'skipped' not in text.lower()
    repo = Path(__file__).resolve().parent.parent
    sources = ['Sources/FilesCore/SevenZipArchiveProvider.swift', 'Tests/FilesCoreTests/SevenZipArchiveProviderTests.swift']
    result = dict(passed=passed, exitCode=process.returncode, timedOut=timed_out, tests=observed,
                  sourcesSHA256={name: hashlib.sha256((repo / name).read_bytes()).hexdigest() for name in sources},
                  workerManifest=json.loads((args.bundle_manifest or args.worker.parent / 'manifest.json').read_text()),
                  referenceManifest=json.loads((args.reference.parent / 'manifest.json').read_text()),
                  productUIIntegration=False)
    (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(dict(passed=passed, tests=observed), indent=2))
    raise SystemExit(0 if passed else 1)


if __name__ == '__main__': main()
