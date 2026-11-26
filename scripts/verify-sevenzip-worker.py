#!/usr/bin/env python3
"""Exercise the native SDK helper's framed listing boundary with real archives."""
import argparse
import array
import socket
import resource
import errno
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
from sevenzip_fixture import empty_files


def frame(value):
    data = json.dumps(value, ensure_ascii=False).encode()
    return struct.pack('!I', len(data)) + data


class Worker:
    def __init__(self, executable, output=False, output_fd=None, library=None, create_output=False, creation_stream=False, descriptor_input=False, input_fd=None, child_fd_limit=None):
        arguments = [str(executable), str(library or executable.parent / '7z.so')]
        self.output = bytearray(); self.reader = None; inherited = ()
        if output:
            read_fd, write_fd = os.pipe(); inherited = (write_fd,)
            arguments += ['--create-stream-fd' if creation_stream else '--output-fd', str(write_fd)]
        elif output_fd is not None:
            inherited = (output_fd,); arguments += ['--create-stream-fd' if creation_stream else ('--create-output-fd' if create_output else '--output-fd'), str(output_fd)]
        self.input_socket = None; child_socket = None
        if descriptor_input:
            self.input_socket, child_socket = socket.socketpair()
            input_fd = child_socket.fileno()
        if input_fd is not None:
            inherited += (input_fd,); arguments += ['--input-fd', str(input_fd)]
        self.process = subprocess.Popen(arguments, pass_fds=inherited,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        preexec_fn=(lambda: resource.setrlimit(resource.RLIMIT_NOFILE, (child_fd_limit, child_fd_limit))) if child_fd_limit else None)
        if child_socket: child_socket.close()
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

    def descriptors(self, specs, descriptors, split=False, password=None, marker=b'F', together=False, trailing=b'', page_size=None, maximum=100):
        request = dict(version=1, operation='list', sourceFDs=specs, splitVolumes=split, password=password, maxEntries=maximum)
        if page_size is not None: request.update(offset=0, pageSize=page_size)
        self.process.stdin.write(frame(request))
        self.process.stdin.flush()
        try:
            groups = [descriptors] if together else [[fd] for fd in descriptors]
            for group in groups:
                self.input_socket.sendmsg([marker], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array('i', group))])
            if trailing: self.input_socket.sendall(trailing)
            self.input_socket.shutdown(socket.SHUT_WR)
        except OSError as error:
            if error.errno not in [errno.EPIPE, errno.ECONNRESET, errno.ENOTCONN]: raise
        finally: self.input_socket.close(); self.input_socket = None
        return self.read()

    def broker_create(self, value, provider, marker=b'F', rights=True):
        calls = []; errors = []
        channel = self.input_socket; channel.settimeout(10)
        def serve():
            try:
                while True:
                    request = b''
                    while len(request) < 5:
                        part = channel.recv(5 - len(request))
                        if not part:
                            if request: raise RuntimeError('Truncated create request')
                            return
                        request += part
                    if request[0] != 0x43: raise RuntimeError('Invalid create request marker')
                    index = struct.unpack('!I', request[1:])[0]; calls.append(index)
                    fd = provider(index)
                    try:
                        if rights: channel.sendmsg([marker], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array('i', [fd]))])
                        else: channel.sendall(marker)
                    finally: os.close(fd)
            except OSError as error:
                if error.errno not in [errno.EPIPE, errno.ECONNRESET, errno.ENOTCONN]: errors.append(str(error))
            except Exception as error: errors.append(str(error))
        thread = threading.Thread(target=serve, daemon=True); thread.start()
        try: response = self.request(value)
        finally:
            thread.join(timeout=10)
            if thread.is_alive():
                self.process.kill(); self.process.wait(); channel.close(); raise RuntimeError('Creation broker did not close')
            channel.close(); self.input_socket = None
        if errors: raise RuntimeError('Creation broker error: ' + '; '.join(errors))
        return response, calls

    def finish(self, expected=0):
        if self.input_socket: self.input_socket.close(); self.input_socket = None
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
    metadata_file = fixture / 'emoji-🔑.txt'
    metadata_file.chmod(0o4751)
    os.utime(metadata_file, ns=(-123456789000000000 + 987654300,) * 2)
    os.utime(fixture / 'folder', ns=(1600000000123456700,) * 2)
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
    for name in ['emoji-🔑.txt', 'folder']:
        info = (fixture / name).stat()
        seconds, nanos = divmod(info.st_mtime_ns, 1_000_000_000)
        check('metadata' + ('File' if name == 'emoji-🔑.txt' else 'Directory'),
              items[name]['metadata'] == dict(permissions=info.st_mode & 0o777, modifiedSeconds=seconds, modifiedNanos=nanos // 100 * 100))
    check('metadataPrivilegeBitsStripped', items['emoji-🔑.txt']['metadata']['permissions'] == 0o751)
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
    # Seekable concatenation retains each part, including repeated list/extract requests.
    split_base = root / 'sdk-split.7z'
    created = subprocess.run([str(reference), 'a', '-t7z', '-mx=0', '-v64k', '-mhe=on', '-p', '-y', str(split_base), stream_source.name],
                             cwd=fixture, input=((password + '\n') * 2).encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    split_parts = sorted(root.glob('sdk-split.7z.*'), key=lambda p: int(p.suffix[1:]))
    check('splitFixtureCreated', created.returncode == 0 and len(split_parts) > 2)
    split_paths = [str(p.resolve()) for p in split_parts]
    split_request = dict(version=1, operation='list', archivePaths=split_paths, password=password)
    worker = Worker(executable, output=True, library=library); opened = worker.request(split_request)
    check('splitSourceTotalAndList', opened['ok'] and opened['source']['size'] == sum(p.stat().st_size for p in split_parts) and len(opened['items']) == 1)
    repeated = worker.request(dict(version=1, operation='list', session=opened['session']))
    check('splitRepeatedListRetainsSession', repeated['ok'] and repeated['session'] == opened['session'] and repeated['items'] == opened['items'])
    extracted = extract(worker, opened, opened['items'][0]); worker.finish()
    check('splitExtractCrossesVolumeBoundaries', extracted['ok'] and worker.output == stream_bytes)
    for label, value in [('Empty', []), ('Boolean', True), ('Element', [1]), ('EmptyPath', ['']), ('NulPath', ['bad\0path']), ('TooMany', ['x'] * 1025)]:
        worker = Worker(executable, library=library)
        response = worker.request(dict(version=1, operation='list', archivePaths=value)); worker.finish(1)
        check('splitRejects' + label, not response['ok'] and response['error']['code'] == 'invalid-request')
    worker = Worker(executable, library=library)
    response = worker.request(dict(split_request, archivePath=str(split_parts[0]))); worker.finish(1)
    check('splitRejectsConflictingPathForms', not response['ok'] and response['error']['code'] == 'invalid-request')
    worker = Worker(executable, library=library); opened = worker.request(split_request)
    held_part = root / 'held-split-part'; split_parts[1].rename(held_part); shutil.copyfile(held_part, split_parts[1])
    response = worker.request(dict(version=1, operation='list', session=opened['session'])); worker.finish()
    check('splitReplacedPartInvalidatesRetainedSession', not response['ok'] and response['error']['code'] == 'source-changed')
    split_parts[1].unlink(); held_part.rename(split_parts[1])
    split_parts[1].rename(held_part); split_parts[1].symlink_to(held_part)
    worker = Worker(executable, library=library); response = worker.request(split_request); worker.finish(1)
    check('splitRejectsSymlinkPart', not response['ok'] and response['error']['code'] == 'source-open')
    split_parts[1].unlink(); held_part.rename(split_parts[1])
    missing_final = root / 'held-final-part'; split_parts[-1].rename(missing_final)
    worker = Worker(executable, library=library)
    response = worker.request(dict(split_request, archivePaths=split_paths[:-1])); worker.finish(1)
    check('splitMissingFinalIdentifiedBeforeDecode', not response['ok'] and response['error']['code'] == 'missing-volume')
    missing_final.rename(split_parts[-1])
    # The first file is a complete archive; equal-sized junk must not be silently accepted as another part.
    tail = root / 'extra-tail'; tail.write_bytes(b'X' * plain.stat().st_size)
    worker = Worker(executable, library=library)
    response = worker.request(dict(version=1, operation='list', archivePaths=[str(plain), str(tail)])); worker.finish(1)
    check('splitRejectsTrailingUnrelatedVolume', not response['ok'] and response['error']['code'] == 'corrupt-data')
    # Invalid advanced creation options are rejected before SDK allocation/output.
    source = (root / 'create-source').resolve(); source.write_bytes(b'keep source')
    stat = source.stat()
    entry = dict(source=str(source), path=source.name, device=str(stat.st_dev), inode=str(stat.st_ino),
                 size=stat.st_size, mode=stat.st_mode, directory=0,
                 modifiedSeconds=stat.st_mtime_ns // 10**9, modifiedNanos=stat.st_mtime_ns % 10**9,
                 changedSeconds=stat.st_ctime_ns // 10**9, changedNanos=stat.st_ctime_ns % 10**9)
    request = dict(version=1, operation='create', items=[entry], level=5, encryptHeader=False)
    invalid = [('DictionaryBoolean', 'dictionarySize', True), ('DictionaryFraction', 'dictionarySize', 65536.5),
               ('DictionaryNotChoice', 'dictionarySize', 131072), ('DictionaryTooLarge', 'dictionarySize', 2147483648),
               ('WordBoolean', 'wordSize', True), ('WordNotChoice', 'wordSize', 33),
               ('WordTooLarge', 'wordSize', 274), ('ThreadsBoolean', 'threads', True),
               ('ThreadsZero', 'threads', 0), ('ThreadsNegative', 'threads', -1), ('ThreadsTooLarge', 'threads', 513)]
    for label, key, value in invalid:
        output = root / ('invalid-create-' + label)
        with output.open('wb') as stream:
            worker = Worker(executable, output_fd=stream.fileno(), library=library, create_output=True)
            reply = worker.request(dict(request, **{key: value})); worker.finish(1)
        check('createRejects' + label, not reply['ok'] and reply['error']['code'] == 'invalid-metadata' and not output.read_bytes())
    check('createInvalidOptionsPreserveSource', source.read_bytes() == b'keep source')
    worker = Worker(executable, output=True, library=library, creation_stream=True)
    response = worker.request(dict(request, level=0)); worker.finish()
    check('createStreamMetadataSuccess', response['ok'] and response.get('closed') is True)
    wire = worker.output; position = 0; image = bytearray(); ended = False; writes = 0
    while position < len(wire):
        if ended or len(wire) - position < 17: raise RuntimeError('Invalid create stream header')
        kind = wire[position]; offset, size = struct.unpack('!QQ', wire[position + 1:position + 17]); position += 17
        if offset > 8000000000 or size > 65536 or kind > 2: raise RuntimeError('Invalid create stream limits')
        if kind == 0:
            if not size or position + size > len(wire): raise RuntimeError('Truncated create stream data')
            if offset + size > len(image): image.extend(b'\0' * (offset + size - len(image)))
            image[offset:offset + size] = wire[position:position + size]; position += size; writes += 1
        elif kind == 1:
            if size: raise RuntimeError('Invalid truncate record')
            if offset < len(image): del image[offset:]
            else: image.extend(b'\0' * (offset - len(image)))
        else:
            if size or offset != len(image): raise RuntimeError('Invalid end record')
            ended = True
    check('createStreamPositionalFramesAndEnd', ended and writes >= 2 and image.startswith(b'7z\xbc\xaf\x27\x1c'))
    streamed = root / 'stream-created.7z'; streamed.write_bytes(image)
    destination = root / 'stream-created-out'
    decoded = subprocess.run([str(reference), 'x', '-y', '-o' + str(destination), str(streamed)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
    check('createStreamIndependentExtraction', decoded.returncode == 0 and (destination / source.name).read_bytes() == source.read_bytes())
    append = root / 'append-output'
    with append.open('ab') as stream:
        worker = Worker(executable, output_fd=stream.fileno(), library=library, create_output=True)
        response = worker.read(); worker.finish(1)
    check('createRejectsAppendDescriptor', response['error']['code'] == 'output-descriptor' and not append.read_bytes())
    regular = root / 'stream-regular-output'
    with regular.open('wb') as stream:
        worker = Worker(executable, output_fd=stream.fileno(), library=library, creation_stream=True)
        response = worker.read(); worker.finish(1)
    check('createStreamRejectsRegularDescriptor', response['error']['code'] == 'output-descriptor' and not regular.read_bytes())
    verify_descriptors(executable, reference, root, library, plain, payloads, check)
    return checks



def verify_descriptors(executable, reference, root, library, plain, payloads, check):
    def initial(path, **extra): return dict(version=1, operation='list', archivePath=str(path), **extra)
    def input_spec(fd):
        value = os.fstat(fd)
        return dict(device=str(value.st_dev & ((1 << 64) - 1)), inode=str(value.st_ino), size=value.st_size, mode=value.st_mode,
                    modifiedSeconds=value.st_mtime_ns // 1_000_000_000, modifiedNanos=value.st_mtime_ns % 1_000_000_000,
                    changedSeconds=value.st_ctime_ns // 1_000_000_000, changedNanos=value.st_ctime_ns % 1_000_000_000)
    large = root / 'large-list.7z'
    empty_files(large, ('entry-' + str(index) + '-' + 'a' * 80 for index in range(35000)))
    validated = subprocess.run([str(reference), 't', str(large)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
    check('pagedFixtureOfficiallyValid', validated.returncode == 0)
    with large.open('rb') as stream:
        worker = Worker(executable, output=True, library=library, descriptor_input=True)
        page = worker.descriptors([input_spec(stream.fileno())], [stream.fileno()], page_size=256, maximum=100000)
        token = page['session']; identity = page['source']; items = []; pages = 0
        while True:
            check('pagedListBoundary', page.get('ok') and page.get('offset') == len(items) and page.get('total') == 35000
                  and page.get('source') == identity and page.get('session') == token and 0 < len(page['items']) <= 256 and len(frame(page)) <= 8388612)
            items.extend(page['items']); pages += 1
            if len(items) == 35000: break
            page = worker.request(dict(version=1, operation='list', session=token, maxEntries=100000, offset=len(items), pageSize=256))
        check('pagedListExceedsLegacyResponse', len(json.dumps(items).encode()) > 8 * 1024 * 1024)
        check('pagedListExactIndicesAndPaths', all(i['index'] == n and i['path'] == 'entry-' + str(n) + '-' + 'a' * 80 for n, i in enumerate(items)))
        extracted = worker.request(dict(version=1, operation='extract', session=token, index=34999, expectedSize=0, maximumBytes=0))
        check('pagedListIndexExtracts', extracted.get('ok') and extracted.get('written') == 0)
        worker.request(dict(version=1, operation='close', session=token)); worker.finish()
    escaped = root / 'escaped-pages.7z'
    empty_files(escaped, (str(index) + '-' + '\x01' * 10000 for index in range(160)))
    validated = subprocess.run([str(reference), 't', str(escaped)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
    check('pagedEscapedFixtureOfficiallyValid', validated.returncode == 0)
    with escaped.open('rb') as stream:
        worker = Worker(executable, library=library, descriptor_input=True)
        page = worker.descriptors([input_spec(stream.fileno())], [stream.fileno()], page_size=256, maximum=1000)
        check('pagedListEncodedByteBudget', page.get('ok') and 0 < len(page['items']) < 160 and len(frame(page)) < 8 * 1024 * 1024)
        items = list(page['items']); token = page['session']
        while len(items) < 160:
            page = worker.request(dict(version=1, operation='list', session=token, offset=len(items), pageSize=256))
            check('pagedListEncodedContinuation', page.get('ok') and page.get('offset') == len(items) and bool(page.get('items')))
            items.extend(page['items'])
        check('pagedListEncodedPathsPreserved', all(i['index'] == n and i['path'] == str(n) + '-' + '\x01' * 10000 for n, i in enumerate(items)))
        worker.request(dict(version=1, operation='close', session=token)); worker.finish()
    empty = root / 'empty-pages.7z'
    empty_files(empty, [])
    with empty.open('rb') as stream:
        worker = Worker(executable, library=library, descriptor_input=True)
        page = worker.descriptors([input_spec(stream.fileno())], [stream.fileno()], page_size=256)
        check('pagedListEmptyArchive', page.get('ok') and page.get('total') == 0 and page.get('offset') == 0 and page.get('items') == [])
        worker.request(dict(version=1, operation='close', session=page['session'])); worker.finish()
    for name, bad in [('booleanOffset', dict(offset=True, pageSize=256)), ('oversizedPage', dict(offset=0, pageSize=257)),
                      ('missingPageSize', dict(offset=0))]:
        with plain.open('rb') as stream:
            worker = Worker(executable, library=library, descriptor_input=True)
            opened = worker.descriptors([input_spec(stream.fileno())], [stream.fileno()], page_size=1)
            response = worker.request(dict(version=1, operation='list', session=opened['session'], **bad))
            check('pagedListRejects-' + name, response.get('error', {}).get('code') == 'invalid-request'); worker.finish(1)
    mutable_page = root / 'mutable-page.7z'; shutil.copyfile(large, mutable_page)
    with mutable_page.open('rb') as stream:
        worker = Worker(executable, library=library, descriptor_input=True)
        opened = worker.descriptors([input_spec(stream.fileno())], [stream.fileno()], page_size=1, maximum=100000)
        with mutable_page.open('ab') as changed: changed.write(b'changed')
        response = worker.request(dict(version=1, operation='list', session=opened['session'], offset=1, pageSize=256))
        check('pagedListSourceChangeRejected', response.get('error', {}).get('code') == 'source-changed'); worker.finish()
    broker_archive = root / 'descriptor-unlinked.7z'; shutil.copyfile(plain, broker_archive)
    with broker_archive.open('rb') as stream:
        broker_archive.unlink()
        worker = Worker(executable, output=True, library=library, descriptor_input=True)
        opened = worker.descriptors([input_spec(stream.fileno())], [stream.fileno()])
        check('descriptorUnlinkedSourceLists', opened.get('ok') and any(i['path'] == 'emoji-🔑.txt' for i in opened['items']))
        entry = next(i for i in opened['items'] if i['path'] == 'emoji-🔑.txt')
        extracted = worker.request(dict(version=1, operation='extract', session=opened['session'], index=entry['index'], expectedSize=entry['size'], maximumBytes=100))
        check('descriptorUnlinkedSourceExtracts', extracted.get('ok'))
        worker.request(dict(version=1, operation='close', session=opened['session'])); worker.finish()
        check('descriptorUnlinkedPayloadMatches', bytes(worker.output) == payloads['emoji-🔑.txt'])
    with plain.open('rb') as stream:
        spec = input_spec(stream.fileno())
        for name, changed, marker, together, trailing, fds, code in [
            ('descriptorBooleanSizeRejected', dict(spec, size=True), b'F', False, b'', [stream.fileno()], 'invalid-metadata'),
            ('descriptorStaleIdentityRejected', dict(spec, inode='0'), b'F', False, b'', [stream.fileno()], 'source-changed'),
            ('descriptorMarkerRejected', spec, b'X', False, b'', [stream.fileno()], 'invalid-metadata'),
            ('descriptorMultipleRightsRejected', spec, b'F', True, b'', [stream.fileno(), stream.fileno()], 'invalid-metadata'),
            ('descriptorTrailingDataRejected', spec, b'F', False, b'X', [stream.fileno()], 'invalid-metadata'),
            ('descriptorMissingRightsRejected', spec, b'F', False, b'', [], 'invalid-metadata'),
        ]:
            worker = Worker(executable, library=library, descriptor_input=True)
            failed = worker.descriptors([changed], fds, marker=marker, together=together, trailing=trailing)
            check(name, failed.get('error', {}).get('code') == code); worker.finish(1)
        worker = Worker(executable, library=library, input_fd=stream.fileno())
        check('descriptorChannelRejectsRegularFile', worker.read().get('error', {}).get('code') == 'input-descriptor'); worker.finish(1)
        worker = Worker(executable, library=library, descriptor_input=True)
        check('descriptorModeRejectsArchivePath', worker.request(initial(plain)).get('error', {}).get('code') == 'invalid-request'); worker.finish(1)
    with plain.open('r+b') as stream:
        worker = Worker(executable, library=library, descriptor_input=True)
        check('descriptorWritableSourceRejected', worker.descriptors([input_spec(stream.fileno())], [stream.fileno()]).get('error', {}).get('code') == 'source-open'); worker.finish(1)
    budget_input = root / 'fd-budget.bin'; budget_bytes = bytes(i % 251 for i in range(6000)); budget_input.write_bytes(budget_bytes)
    subprocess.run([str(reference), 'a', '-t7z', '-mx=0', '-v128b', str(root / 'fd-budget.7z'), str(budget_input)], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    budget_parts = sorted(root.glob('fd-budget.7z.*'))
    check('descriptorBudgetManyParts', 32 < len(budget_parts) <= 64)
    budget_fds = [os.open(path, os.O_RDONLY) for path in budget_parts]
    try:
        worker = Worker(executable, output=True, library=library, descriptor_input=True, child_fd_limit=128)
        opened = worker.descriptors([input_spec(fd) for fd in budget_fds], budget_fds, split=True)
        check('descriptorBudgetListsWithinHardLimit', opened.get('ok') and len(opened['items']) == 1)
        entry = opened['items'][0]
        extracted = worker.request(dict(version=1, operation='extract', session=opened['session'], index=entry['index'], expectedSize=entry['size'], maximumBytes=10000))
        check('descriptorBudgetExtractsWithinHardLimit', extracted.get('ok'))
        worker.request(dict(version=1, operation='close', session=opened['session'])); worker.finish()
        check('descriptorBudgetPayloadMatches', bytes(worker.output) == budget_bytes)
    finally:
        for fd in budget_fds: os.close(fd)
    # Creation has no source paths: the broker may supply an unlinked regular file.
    broker_source = root / 'unlinked-create-source'; broker_bytes = b'private descriptor creation payload'; broker_source.write_bytes(broker_bytes)
    held = os.open(broker_source, os.O_RDONLY)
    try:
        broker_source.unlink(); spec = input_spec(held)
        broker_entry = dict(spec, path='fd-only.bin', directory=0)
        create_request = dict(version=1, operation='create', items=[broker_entry], level=0, encryptHeader=False)
        def original(index):
            if index != 0: raise RuntimeError('Unplanned creation index')
            os.lseek(held, 1, os.SEEK_END)
            return os.dup(held)
        output = root / 'fd-created.7z'
        with output.open('wb') as stream:
            worker = Worker(executable, output_fd=stream.fileno(), library=library, create_output=True, descriptor_input=True)
            response, calls = worker.broker_create(create_request, original); worker.finish()
        check('createDescriptorUnlinkedSource', response.get('closed') and calls and all(index == 0 for index in calls))
        restored = root / 'fd-created-restored'
        subprocess.run([str(reference), 'x', '-y', '-o' + str(restored), str(output)], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        check('createDescriptorOfficialRoundTrip', (restored / 'fd-only.bin').read_bytes() == broker_bytes)
        output = root / 'chunked-created.7z'
        with output.open('wb') as stream:
            worker = Worker(executable, output_fd=stream.fileno(), library=library, create_output=True, descriptor_input=True)
            ready = worker.request(dict(version=1, operation='create-begin', itemCount=2, level=0, encryptHeader=False))
            upload = ready.get('upload')
            check('createUploadBeginsWithoutOutput', ready.get('accepted') == 0 and isinstance(upload, str) and output.stat().st_size == 0)
            for index in range(2):
                accepted = worker.request(dict(version=1, operation='create-items', upload=upload, offset=index,
                                              items=[dict(broker_entry, path='chunk-' + str(index))]))
                check('createUploadAcknowledges' + str(index), accepted.get('upload') == upload and accepted.get('accepted') == index + 1 and output.stat().st_size == 0)
            response, calls = worker.broker_create(dict(version=1, operation='create-commit', upload=upload), lambda index: os.dup(held))
            worker.finish()
        check('createUploadCommitsBrokerOnly', response.get('closed') and set(calls) == {0, 1})
        restored = root / 'chunked-restored'
        subprocess.run([str(reference), 'x', '-y', '-o' + str(restored), str(output)], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        check('createUploadOfficialRoundTrip', all((restored / ('chunk-' + str(index))).read_bytes() == broker_bytes for index in range(2)))
        for name, bad in [
            ('earlyCommit', dict(operation='create-commit')),
            ('wrongOffset', dict(operation='create-items', offset=1, items=[broker_entry])),
            ('wrongUpload', dict(operation='create-items', upload='foreign', offset=0, items=[broker_entry])),
            ('emptyChunk', dict(operation='create-items', offset=0, items=[])),
            ('oversizedChunk', dict(operation='create-items', offset=0, items=[broker_entry] * 257)),
            ('extraItem', dict(operation='create-items', offset=0, items=[broker_entry] * 3)),
        ]:
            output = root / ('upload-' + name + '.7z')
            with output.open('wb') as stream:
                worker = Worker(executable, output_fd=stream.fileno(), library=library, create_output=True, descriptor_input=True)
                ready = worker.request(dict(version=1, operation='create-begin', itemCount=2))
                response = worker.request(dict(version=1, upload=ready['upload'], **bad)) if 'upload' not in bad else worker.request(dict(version=1, **bad))
                worker.finish(1)
            check('createUploadRejects-' + name, response.get('error', {}).get('code') == 'invalid-request' and output.stat().st_size == 0)
        for name, request_value, provider, marker, rights, code in [
            ('createDescriptorLegacyPathRejected', dict(create_request, items=[dict(broker_entry, source='/must-not-open')]), original, b'F', True, 'invalid-metadata'),
            ('createDescriptorMarkerRejected', create_request, original, b'X', True, 'invalid-metadata'),
            ('createDescriptorRightsRequired', create_request, original, b'F', False, 'invalid-metadata'),
            ('createDescriptorForeignIdentityRejected', create_request, lambda index: os.open(plain, os.O_RDONLY), b'F', True, 'source-changed'),
            ('createDescriptorWritableRejected', create_request, lambda index: os.open(plain, os.O_RDWR), b'F', True, 'invalid-metadata'),
        ]:
            output = root / (name + '.7z')
            with output.open('wb') as stream:
                worker = Worker(executable, output_fd=stream.fileno(), library=library, create_output=True, descriptor_input=True)
                response, calls = worker.broker_create(request_value, provider, marker=marker, rights=rights); worker.finish(1)
            check(name, response.get('error', {}).get('code') == code)
    finally: os.close(held)


def verify_brokered(executable, reference, root, library):
    checks = {}
    def check(name, condition):
        checks[name] = bool(condition)
        if not condition: raise RuntimeError('Failed check: ' + name)
    fixture = root / 'input'; fixture.mkdir()
    payloads = {'emoji-🔑.txt': b'12345'}
    (fixture / 'emoji-🔑.txt').write_bytes(payloads['emoji-🔑.txt'])
    plain = root / 'plain.7z'
    created = subprocess.run([str(reference), 'a', '-t7z', str(plain), '.'], cwd=fixture,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
    check('brokerFixtureCreated', created.returncode == 0)
    # A product helper must refuse the old arbitrary path-opening mode outside its sandbox.
    worker = Worker(executable, library=library)
    response = worker.request(dict(version=1, operation='list', archivePath=str(plain)))
    check('sandboxRejectsUnbrokeredArchivePath', response.get('error', {}).get('code') == 'source-open')
    worker.finish(1)
    verify_descriptors(executable, reference, root, library, plain, payloads, check)
    return checks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--worker', type=Path, required=True)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--library', type=Path)
    parser.add_argument('--bundle-manifest', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--broker-only', action='store_true', help='Exercise packaged sandbox mode; the full legacy SDK suite remains separate')
    args = parser.parse_args(); args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='sevenzip-worker-') as directory:
        checks = (verify_brokered if args.broker_only else verify)(args.worker.resolve(), args.reference.resolve(), Path(directory), args.library)
    manifest_path = args.bundle_manifest or args.worker.parent / 'manifest.json'
    manifest = json.loads(manifest_path.read_text())
    native = manifest['builds'][platform.machine()] if args.bundle_manifest else manifest
    library = args.library or args.worker.parent / '7z.so'
    result = dict(passed=True, checks=checks, workerFingerprint=native['fingerprint'],
                  workerSHA256=hashlib.sha256(args.worker.read_bytes()).hexdigest(),
                  librarySHA256=hashlib.sha256(library.read_bytes()).hexdigest(),
                  architecture=native['inputs']['architecture'], productIntegration=False, brokerOnly=args.broker_only)
    (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    shutil.copyfile(manifest_path, args.output / 'manifest.json')
    print(json.dumps(result, indent=2))


if __name__ == '__main__': main()
