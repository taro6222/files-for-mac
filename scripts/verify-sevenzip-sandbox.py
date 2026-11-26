#!/usr/bin/env python3
"""Require the packaged profile and exercise its OS authority with a bounded, test-only native process."""
import argparse
import array
import errno
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import socket
import subprocess
import uuid
import sevenzip_bundle as bundle


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    manifest = bundle.verify(args.app)
    repo = Path(__file__).resolve().parent.parent
    worker = args.app / bundle.CODE[0]
    profile = plistlib.loads(subprocess.check_output(['codesign', '-d', '--entitlements', ':-', str(worker)], stderr=subprocess.DEVNULL))
    assert profile == {'com.apple.security.app-sandbox': True}
    probe = args.output / 'AuthorityProbe.app'
    executable = probe / 'Contents/MacOS/AuthorityProbe'
    executable.parent.mkdir(parents=True)
    identifier = 'org.taro6222.files-for-mac.authority-probe.' + uuid.uuid4().hex
    (probe / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': identifier, 'CFBundleExecutable': 'AuthorityProbe',
                                                            'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'LSBackgroundOnly': True}))
    entitlements = args.output / 'profile.plist'; entitlements.write_bytes(plistlib.dumps(profile))
    library = probe / 'Contents/Frameworks/7z.so'; library.parent.mkdir()
    shutil.copyfile(args.app / bundle.CODE[1], library)
    source = repo / 'Tools/SevenZipSandboxProbe/main.c'
    subprocess.run(['clang', '-Wall', '-Wextra', '-Werror', str(source), '-o', str(executable)], check=True, timeout=20)
    subprocess.run(['codesign', '--force', '--timestamp=none', '--sign', '-', '--entitlements', str(entitlements), str(probe)], check=True, timeout=10)
    fixtures = args.output / 'fixtures'; fixtures.mkdir()
    selected = fixtures / 'source.txt'; selected.write_bytes(b'source'); selected.chmod(0o440)
    os.utime(selected, ns=(1_600_000_000_000_000_000,) * 2)
    before = selected.stat()
    outside = fixtures / 'outside.txt'; outside.write_bytes(b'private')
    output = fixtures / 'output.txt'
    source_fd = os.open(selected, os.O_RDONLY)
    directory_fd = os.open(fixtures, os.O_SEARCH | os.O_DIRECTORY)
    directory_mode = os.fstat(directory_fd).st_mode
    output_fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    parent, child = socket.socketpair(); listener = socket.socket()
    listener.bind(('127.0.0.1', 0)); listener.listen(1)
    process = None
    try:
        command = [str(executable.resolve()), str(child.fileno()), str(output_fd), str(selected.resolve()), str(outside.resolve()),
                   str(library.resolve()), str(listener.getsockname()[1])]
        process = subprocess.Popen(command, pass_fds=(child.fileno(), output_fd), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        child.close()
        parent.sendmsg([b'F'], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array('i', [source_fd, directory_fd]))])
        stdout, stderr = process.communicate(timeout=5)
        if process.returncode or stderr: raise RuntimeError('Authority probe failed: ' + stderr.decode(errors='replace'))
        raw = json.loads(stdout)
        (args.output / 'probe.json').write_text(json.dumps(raw, indent=2) + '\n')
        parent.settimeout(1); reply = parent.recv(5)
        checks = {}
        for name, rc, error in [('pathReadDenied', 'pathOpen', 'pathErrno'), ('sourceChmodDenied', 'chmod', 'chmodErrno'),
                                ('sourceTimestampDenied', 'timestamp', 'timestampErrno'), ('directoryChmodDenied', 'directoryChmod', 'directoryErrno'),
                                ('unselectedRelativeReadDenied', 'relativeOpen', 'relativeErrno'), ('outsideWriteDenied', 'outsideWrite', 'outsideErrno'),
                                ('networkClientDenied', 'connect', 'connectErrno'), ('networkServerDenied', 'bind', 'bindErrno')]:
            checks[name] = raw[rc] == -1 and raw[error] == errno.EPERM
        checks['brokeredReadAllowed'] = raw['readBytes'] == 6 and raw['inputMatched']
        checks['inheritedWriteAllowed'] = raw['writeBytes'] == 6 and output.read_bytes() == b'output'
        checks['privateChannelAllowed'] = raw['sent'] == 5 and reply == b'reply'
        checks['bundledLibraryAllowed'] = raw['libraryLoaded']
        after = selected.stat()
        checks['selectedSourcePreserved'] = selected.read_bytes() == b'source' and before.st_mode == after.st_mode and before.st_mtime_ns == after.st_mtime_ns
        checks['unselectedFilePreserved'] = outside.read_bytes() == b'private'
        checks['sourceDirectoryPreserved'] = fixtures.stat().st_mode == directory_mode
        result = dict(passed=all(checks.values()), checks=checks, profile=profile, probeIdentifier=identifier,
                      productProfileVerified=True, productProbeBinary=False, processReaped=process.returncode is not None,
                      sourceSHA256=hashlib.sha256(source.read_bytes()).hexdigest(), bundleManifest=manifest, localGUIStarted=False)
        (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(dict(passed=result['passed'], checks=checks), indent=2))
        if not result['passed']: raise SystemExit(1)
    finally:
        if process is not None and process.poll() is None:
            process.kill(); process.wait()
        for descriptor in [source_fd, directory_fd, output_fd]: os.close(descriptor)
        parent.close(); child.close(); listener.close()


if __name__ == '__main__': main()
