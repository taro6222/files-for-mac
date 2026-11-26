#!/usr/bin/env python3
"""Exercise the native SDK helper's framed listing boundary with real archives."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import selectors
import shutil
import struct
import subprocess
import tempfile
import time


def frame(value):
    data = json.dumps(value, ensure_ascii=False).encode()
    return struct.pack('!I', len(data)) + data


class Worker:
    def __init__(self, executable):
        self.process = subprocess.Popen([str(executable), str(executable.parent / '7z.so')],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def read(self):
        deadline = time.monotonic() + 10
        def exact(count):
            data = b''
            with selectors.DefaultSelector() as selector:
                selector.register(self.process.stdout, selectors.EVENT_READ)
                while len(data) < count:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0 or not selector.select(remaining): raise RuntimeError('Worker response timeout')
                    part = os.read(self.process.stdout.fileno(), count - len(data))
                    if not part: raise RuntimeError('Truncated worker response')
                    data += part
            return data
        length = struct.unpack('!I', exact(4))[0]
        if not 0 < length <= 8 * 1024 * 1024: raise RuntimeError('Unbounded worker response')
        return json.loads(exact(length))

    def request(self, value):
        self.process.stdin.write(frame(value)); self.process.stdin.flush()
        return self.read()

    def finish(self, expected=0):
        self.process.stdin.close()
        try: status = self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill(); self.process.wait(); raise RuntimeError('Worker did not close')
        trailing = self.process.stdout.read(); diagnostic = self.process.stderr.read()
        self.process.stdout.close(); self.process.stderr.close()
        if status != expected or trailing or diagnostic: raise RuntimeError('Unexpected worker termination/output')


def verify(executable, reference, root):
    checks = {}
    def check(name, condition):
        checks[name] = bool(condition)
        if not condition: raise RuntimeError('Failed check: ' + name)
    password = 'QA-345-한글-🔑'
    fixture = root / 'input'; fixture.mkdir()
    payloads = {'line\nbreak-한글.txt': b'payload', 'emoji-🔑.txt': b'12345', 'folder/child.txt': b'child'}
    for name, payload in payloads.items():
        path = fixture / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(payload)
    (fixture / 'link').symlink_to('emoji-🔑.txt')
    def create(name, encrypted):
        archive = root / name
        arguments = [str(reference), 'a', '-t7z', '-snl', '-y', str(archive), '.']
        if encrypted: arguments += ['-mhe=on', '-p']
        result = subprocess.run(arguments, cwd=fixture, input=((password + '\n') * 2).encode() if encrypted else b'',
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        check(name + 'Created', result.returncode == 0 and password.encode() not in result.stdout + result.stderr)
        return archive
    plain = create('plain.7z', False); encrypted = create('encrypted.7z', True)
    originals = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in [plain, encrypted]}
    def initial(path, **extra): return dict(version=1, operation='list', archivePath=str(path), **extra)
    for label, secret, error in [('missingPassword', None, 'password-required'), ('wrongPassword', 'wrong', 'password-or-corrupt')]:
        worker = Worker(executable)
        response = worker.request(initial(encrypted, password=secret))
        check(label, not response['ok'] and response['error']['code'] == error)
        check(label + 'SecretAbsent', password not in json.dumps(response, ensure_ascii=False))
        worker.finish(1)
    worker = Worker(executable)
    response = worker.request(initial(encrypted, password=password))
    check('correctPassword', response['ok'] and response['headerPasswordRequested'])
    items = {i['path']: i for i in response['items']}
    check('exactUnicodeNewlineNames', set(items) == {*payloads, 'folder', 'link'})
    check('regularFileSizes', all(items[name]['kind'] == 'regularFile' and items[name]['size'] == len(data) for name, data in payloads.items()))
    check('directoryKind', items['folder']['kind'] == 'directory')
    check('symbolicLinkKind', items['link']['kind'] == 'symbolicLink')
    check('encryptedFileProperties', all(items[name]['encrypted'] for name in payloads))
    info = encrypted.stat()
    check('sourceIdentity', response['source'] == dict(device=str(info.st_dev), inode=str(info.st_ino), size=info.st_size))
    token = response['session']
    repeated = worker.request(dict(version=1, operation='list', session=token))
    check('sameSessionList', repeated['items'] == response['items'] and repeated['source'] == response['source'])
    check('close', worker.request(dict(version=1, operation='close', session=token))['closed']); worker.finish()
    worker = Worker(executable)
    limited = worker.request(initial(plain, maxEntries=1))
    check('entryLimit', not limited['ok'] and limited['error']['code'] == 'limit' and bool(limited['session']))
    check('limitRetrySameSession', worker.request(dict(version=1, operation='list', session=limited['session']))['ok'])
    worker.finish()
    worker = Worker(executable); opened = worker.request(initial(plain))
    check('wrongSession', worker.request(dict(version=1, operation='list', session='wrong'))['error']['code'] == 'invalid-request'); worker.finish(1)
    mutable = root / 'mutable.7z'; shutil.copyfile(plain, mutable)
    worker = Worker(executable); opened = worker.request(initial(mutable))
    with mutable.open('ab') as stream: stream.write(b'changed')
    changed = worker.request(dict(version=1, operation='list', session=opened['session']))
    check('sourceMutationRejected', changed['error']['code'] == 'source-changed'); worker.finish()
    replacement = root / 'replacement.7z'; shutil.copyfile(plain, replacement)
    worker = Worker(executable); opened = worker.request(initial(replacement))
    replacement.rename(root / 'held.7z'); replacement.write_bytes(b'not an archive')
    after = worker.request(dict(version=1, operation='list', session=opened['session']))
    check('pathReplacementNeverFollowed', (after['ok'] and after['source'] == opened['source'] and after['items'] == opened['items']) or
          (not after['ok'] and after['error']['code'] == 'source-changed')); worker.finish()
    fifo = root / 'fifo'; os.mkfifo(fifo)
    for name, path in [('fifoRejected', fifo), ('directoryRejected', fixture)]:
        worker = Worker(executable); result = worker.request(initial(path))
        check(name, result['error']['code'] == 'source-open'); worker.finish(1)
    bad_requests = [('booleanVersion', dict(version=True, operation='list', archivePath=str(plain)), 'invalid-request'),
                    ('unknownKey', initial(plain, surprise=1), 'invalid-request'),
                    ('booleanLimit', initial(plain, maxEntries=True), 'invalid-request'),
                    ('unknownOperation', dict(version=1, operation='extract'), 'unsupported-operation'),
                    ('nulPassword', initial(plain, password='a\0b'), 'invalid-request')]
    for name, request, code in bad_requests:
        worker = Worker(executable); check(name, worker.request(request)['error']['code'] == code); worker.finish(1)
    for name, data, code in [('oversizedFrame', struct.pack('!I', 1024 * 1024 + 1), 'frame-limit'),
                             ('zeroFrame', b'\0\0\0\0', 'frame-limit'),
                             ('truncatedFrame', struct.pack('!I', 10) + b'{}', 'truncated-frame'),
                             ('invalidUTF8', struct.pack('!I', 1) + b'\xff', 'invalid-request')]:
        worker = Worker(executable); worker.process.stdin.write(data); worker.process.stdin.flush()
        if name == 'truncatedFrame': worker.process.stdin.close()
        check(name, worker.read()['error']['code'] == code)
        if name == 'truncatedFrame':
            worker.process.stdin = None
            output, diagnostic = worker.process.communicate(timeout=10)
            check(name + 'Closed', worker.process.returncode == 1 and not output and not diagnostic)
        else: worker.finish(1)
    check('originalArchivesPreserved', all(hashlib.sha256(p.read_bytes()).hexdigest() == value for p, value in originals.items()))
    check('inputFilesPreserved', all((fixture / name).read_bytes() == data for name, data in payloads.items()) and (fixture / 'link').is_symlink())
    return checks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--worker', type=Path, required=True)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(); args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='sevenzip-worker-') as directory:
        checks = verify(args.worker.resolve(), args.reference.resolve(), Path(directory))
    manifest = json.loads((args.worker.parent / 'manifest.json').read_text())
    result = dict(passed=True, checks=checks, workerFingerprint=manifest['fingerprint'],
                  architecture=manifest['inputs']['architecture'], productIntegration=False)
    (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    shutil.copyfile(args.worker.parent / 'manifest.json', args.output / 'manifest.json')
    print(json.dumps(result, indent=2))


if __name__ == '__main__': main()
