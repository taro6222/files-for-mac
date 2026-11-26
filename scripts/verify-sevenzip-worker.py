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
import threading
import platform


def frame(value):
    data = json.dumps(value, ensure_ascii=False).encode()
    return struct.pack('!I', len(data)) + data


class Worker:
    def __init__(self, executable, output=False, output_fd=None, library=None):
        arguments = [str(executable), str(library or executable.parent / '7z.so')]
        self.output = bytearray(); self.reader = None; inherited = ()
        if output:
            read_fd, write_fd = os.pipe(); inherited = (write_fd,)
            arguments += ['--output-fd', str(write_fd)]
        elif output_fd is not None:
            inherited = (output_fd,); arguments += ['--output-fd', str(output_fd)]
        self.process = subprocess.Popen(arguments, pass_fds=inherited,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if output:
            os.close(write_fd)
            def drain():
                with os.fdopen(read_fd, 'rb', buffering=0) as stream:
                    while True:
                        data = stream.read(65536)
                        if not data: break
                        self.output.extend(data)
                        if len(self.output) > 2 * 1024 * 1024: break
            self.reader = threading.Thread(target=drain, daemon=True); self.reader.start()

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
        if self.reader:
            self.reader.join(timeout=10)
            if self.reader.is_alive(): raise RuntimeError('Output stream did not close')
        if status != expected or trailing or diagnostic: raise RuntimeError('Unexpected worker termination/output')


def verify(executable, reference, root, library=None):
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
        worker = Worker(executable, library=library)
        response = worker.request(initial(encrypted, password=secret))
        check(label, not response['ok'] and response['error']['code'] == error)
        check(label + 'SecretAbsent', password not in json.dumps(response, ensure_ascii=False))
        worker.finish(1)
    worker = Worker(executable, library=library)
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
    worker = Worker(executable, library=library)
    limited = worker.request(initial(plain, maxEntries=1))
    check('entryLimit', not limited['ok'] and limited['error']['code'] == 'limit' and bool(limited['session']))
    check('limitRetrySameSession', worker.request(dict(version=1, operation='list', session=limited['session']))['ok'])
    worker.finish()
    worker = Worker(executable, library=library); opened = worker.request(initial(plain))
    check('wrongSession', worker.request(dict(version=1, operation='list', session='wrong'))['error']['code'] == 'invalid-request'); worker.finish(1)
    mutable = root / 'mutable.7z'; shutil.copyfile(plain, mutable)
    worker = Worker(executable, library=library); opened = worker.request(initial(mutable))
    with mutable.open('ab') as stream: stream.write(b'changed')
    changed = worker.request(dict(version=1, operation='list', session=opened['session']))
    check('sourceMutationRejected', changed['error']['code'] == 'source-changed'); worker.finish()
    replacement = root / 'replacement.7z'; shutil.copyfile(plain, replacement)
    worker = Worker(executable, library=library); opened = worker.request(initial(replacement))
    replacement.rename(root / 'held.7z'); replacement.write_bytes(b'not an archive')
    after = worker.request(dict(version=1, operation='list', session=opened['session']))
    check('pathReplacementNeverFollowed', (after['ok'] and after['source'] == opened['source'] and after['items'] == opened['items']) or
          (not after['ok'] and after['error']['code'] == 'source-changed')); worker.finish()
    fifo = root / 'fifo'; os.mkfifo(fifo)
    for name, path in [('fifoRejected', fifo), ('directoryRejected', fixture)]:
        worker = Worker(executable, library=library); result = worker.request(initial(path))
        check(name, result['error']['code'] == 'source-open'); worker.finish(1)
    bad_requests = [('booleanVersion', dict(version=True, operation='list', archivePath=str(plain)), 'invalid-request'),
                    ('unknownKey', initial(plain, surprise=1), 'invalid-request'),
                    ('booleanLimit', initial(plain, maxEntries=True), 'invalid-request'),
                    ('unknownOperation', dict(version=1, operation='extract'), 'unsupported-operation'),
                    ('nulPassword', initial(plain, password='a\0b'), 'invalid-request')]
    for name, request, code in bad_requests:
        worker = Worker(executable, library=library); check(name, worker.request(request)['error']['code'] == code); worker.finish(1)
    for name, data, code in [('oversizedFrame', struct.pack('!I', 1024 * 1024 + 1), 'frame-limit'),
                             ('zeroFrame', b'\0\0\0\0', 'frame-limit'),
                             ('truncatedFrame', struct.pack('!I', 10) + b'{}', 'truncated-frame'),
                             ('invalidUTF8', struct.pack('!I', 1) + b'\xff', 'invalid-request')]:
        worker = Worker(executable, library=library); worker.process.stdin.write(data); worker.process.stdin.flush()
        if name == 'truncatedFrame': worker.process.stdin.close()
        check(name, worker.read()['error']['code'] == code)
        if name == 'truncatedFrame':
            worker.process.stdin = None
            output, diagnostic = worker.process.communicate(timeout=10)
            check(name + 'Closed', worker.process.returncode == 1 and not output and not diagnostic)
        else: worker.finish(1)
    check('originalArchivesPreserved', all(hashlib.sha256(p.read_bytes()).hexdigest() == value for p, value in originals.items()))
    check('inputFilesPreserved', all((fixture / name).read_bytes() == data for name, data in payloads.items()) and (fixture / 'link').is_symlink())
    def extract(worker, opened, item, **extra):
        request = dict(version=1, operation='extract', session=opened['session'], index=item['index'],
                       expectedSize=item['size'], maximumBytes=8000000000)
        request.update(extra); return worker.request(request)
    worker = Worker(executable, output=True, library=library); opened = worker.request(initial(encrypted, password=password))
    listed = {i['path']: i for i in opened['items']}; expected = b''
    for name, data in payloads.items():
        result = extract(worker, opened, listed[name]); expected += data
        check('extract-' + str(listed[name]['index']), result['ok'] and result['written'] == len(data))
    for name in ['link', 'folder']:
        result = extract(worker, opened, listed[name])
        check('extractReject-' + name, not result['ok'] and result['error']['code'] == 'unsupported-item' and result['written'] == 0)
    selected = listed[next(iter(payloads))]
    check('extractSizeMismatch', extract(worker, opened, selected, expectedSize=selected['size'] + 1)['error']['code'] == 'invalid-metadata')
    check('extractByteLimit', extract(worker, opened, selected, maximumBytes=0)['error']['code'] == 'limit')
    check('extractInvalidIndex', extract(worker, opened, selected, index=4294967295)['error']['code'] == 'invalid-metadata')
    check('listAfterExtractSameSource', worker.request(dict(version=1, operation='list', session=opened['session']))['source'] == opened['source'])
    check('extractBooleanIndex', extract(worker, opened, selected, index=True)['error']['code'] == 'invalid-request')
    worker.finish(1); check('extractExactBytesNoRejectedOutput', worker.output == expected)
    worker = Worker(executable, library=library); opened = worker.request(initial(plain))
    check('extractRequiresOutputPipe', extract(worker, opened, opened['items'][-1])['error']['code'] == 'output-descriptor'); worker.finish(1)
    # A non-header-encrypted archive can list without credentials; extraction must request them.
    data_archive = root / 'data-encrypted.7z'
    result = subprocess.run([str(reference), 'a', '-t7z', '-mhe=off', '-p', '-y', str(data_archive), 'emoji-🔑.txt'],
                            cwd=fixture, input=((password + '\n') * 2).encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    check('dataEncryptedFixture', result.returncode == 0)
    for name, secret, error in [('extractMissingPassword', None, 'password-required'), ('extractWrongPassword', 'wrong', 'password-or-corrupt')]:
        worker = Worker(executable, output=True, library=library); opened = worker.request(initial(data_archive, password=secret))
        check(name + 'List', opened['ok'])
        result = extract(worker, opened, opened['items'][0]); check(name, not result['ok'] and result['error']['code'] == error); worker.finish()
    # Output exceeds pipe capacity; a concurrent reader proves streaming without stdout mixing.
    stream_source = fixture / 'stream.bin'; stream_bytes = bytes(range(256)) * 2048; stream_source.write_bytes(stream_bytes)
    stream_archive = root / 'stream.7z'
    result = subprocess.run([str(reference), 'a', '-t7z', '-mhc=off', '-ms=off', '-y', str(stream_archive), stream_source.name],
                            cwd=fixture, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    check('streamFixture', result.returncode == 0)
    worker = Worker(executable, output=True, library=library); opened = worker.request(initial(stream_archive))
    result = extract(worker, opened, opened['items'][0]); worker.finish()
    check('streamBeyondPipeCapacity', result['ok'] and result['written'] == len(stream_bytes) and worker.output == stream_bytes)
    # A closed consumer pipe is a write failure, never an apparent successful extraction.
    read_fd, write_fd = os.pipe(); os.close(read_fd)
    worker = Worker(executable, output_fd=write_fd, library=library)
    os.close(write_fd)
    opened = worker.request(initial(stream_archive)); result = extract(worker, opened, opened['items'][0]); worker.finish()
    check('closedOutputPipeRejected', not result['ok'] and result['error']['code'] == 'output-write')
    output_path = root / 'not-a-pipe'; output_path.write_bytes(b'preserve')
    with output_path.open('ab') as stream:
        worker = Worker(executable, output_fd=stream.fileno(), library=library)
        check('regularOutputDescriptorRejected', worker.read()['error']['code'] == 'output-descriptor'); worker.finish(1)
    check('regularOutputDescriptorPreserved', output_path.read_bytes() == b'preserve')
    corrupt = bytearray(stream_archive.read_bytes()); corrupt[32] ^= 0x80
    corrupt_archive = root / 'corrupt.7z'; corrupt_archive.write_bytes(corrupt)
    worker = Worker(executable, output=True, library=library); opened = worker.request(initial(corrupt_archive))
    check('corruptFixtureLists', opened['ok'])
    result = extract(worker, opened, opened['items'][0]); worker.finish()
    check('corruptDataNeverSuccess', not result['ok'] and result['error']['code'] == 'corrupt-data')
    # The caller must discard output on any failure, including a source changed after listing.
    changed_archive = root / 'extract-changed.7z'; shutil.copyfile(stream_archive, changed_archive)
    worker = Worker(executable, output=True, library=library); opened = worker.request(initial(changed_archive))
    with changed_archive.open('ab') as stream: stream.write(b'changed')
    result = extract(worker, opened, opened['items'][0]); worker.finish()
    check('extractSourceChangeBeforeOutput', not result['ok'] and result['error']['code'] == 'source-changed' and not worker.output)
    return checks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--worker', type=Path, required=True)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--library', type=Path)
    parser.add_argument('--bundle-manifest', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(); args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='sevenzip-worker-') as directory:
        checks = verify(args.worker.resolve(), args.reference.resolve(), Path(directory), args.library)
    manifest_path = args.bundle_manifest or args.worker.parent / 'manifest.json'
    manifest = json.loads(manifest_path.read_text())
    native = manifest['builds'][platform.machine()] if args.bundle_manifest else manifest
    library = args.library or args.worker.parent / '7z.so'
    result = dict(passed=True, checks=checks, workerFingerprint=native['fingerprint'],
                  workerSHA256=hashlib.sha256(args.worker.read_bytes()).hexdigest(),
                  librarySHA256=hashlib.sha256(library.read_bytes()).hexdigest(),
                  architecture=native['inputs']['architecture'], productIntegration=False)
    (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    shutil.copyfile(manifest_path, args.output / 'manifest.json')
    print(json.dumps(result, indent=2))


if __name__ == '__main__': main()
