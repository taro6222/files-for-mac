#!/usr/bin/env python3
"""Exercise the private native ZIP/7z edit API; does not enable product editing or publish originals."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import shutil
import struct
import subprocess
import tarfile
import tempfile
import zipfile
import ctypes
import hmac
import stat
import sevenzip_reference as reference


def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def unicode_aes_zip(path, password):
    """Independent single-entry WinZip AE-2 fixture using Apple's AES block primitive."""
    salt = bytes(range(16)); material = hashlib.pbkdf2_hmac('sha1', password.encode(), salt, 1000, 66)
    crypto = ctypes.CDLL('/usr/lib/system/libcommonCrypto.dylib')
    encrypt = crypto.CCCrypt
    encrypt.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_size_t,
                        ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
    encrypt.restype = ctypes.c_int32
    plain = b'unicode encrypted payload'; encrypted = bytearray()
    for index in range(0, len(plain), 16):
        counter = (index // 16 + 1).to_bytes(16, 'little'); output = ctypes.create_string_buffer(16); moved = ctypes.c_size_t()
        assert encrypt(0, 0, 2, material[:32], 32, None, counter, 16, output, 16, ctypes.byref(moved)) == 0 and moved.value == 16
        encrypted.extend(a ^ b for a, b in zip(plain[index:index + 16], output.raw))
    payload = salt + material[64:] + encrypted + hmac.new(material[32:64], encrypted, 'sha1').digest()[:10]
    name = 'unicode-old.txt'.encode(); extra = struct.pack('<HHH2sBH', 0x9901, 7, 2, b'AE', 3, 0)
    date = (40 << 9) | (1 << 5) | 1; flags = 0x801
    local = struct.pack('<IHHHHHIIIHH', 0x04034b50, 51, flags, 99, 0, date, 0, len(payload), len(plain), len(name), len(extra)) + name + extra + payload
    central = struct.pack('<IHHHHHHIIIHHHHHII', 0x02014b50, (3 << 8) | 63, 51, flags, 99, 0, date, 0, len(payload), len(plain), len(name), len(extra), 0, 0, 0, (stat.S_IFREG | 0o640) << 16, 0) + name + extra
    path.write_bytes(local + central + struct.pack('<IHHHHIIH', 0x06054b50, 0, 0, 1, 1, len(central), len(local), 0))
    return plain


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path, required=True)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--app', type=Path, help='Bind tested adapter sources to the verified packaged helper manifest')
    args = parser.parse_args(); args.library = args.library.resolve(); args.reference = args.reference.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    repo = Path(__file__).resolve().parent.parent
    if args.app:
        import sevenzip_bundle as bundle
        manifest = bundle.verify(args.app)
        if args.library != (args.app / bundle.CODE[1]).resolve(): raise RuntimeError('Unexpected packaged SDK library')
        inputs = manifest['builds'][platform.machine()]['inputs']['helperSourcesSHA256']
        for name in ['ArchiveSDK.cpp', 'ArchiveSDK.h']:
            if digest(repo / 'Tools/SevenZipWorker' / name) != inputs[name]: raise RuntimeError('Adapter differs from packaged helper sources')
    archive = repo / 'build/sevenzip-source' / reference.VERSION / 'source.tar.xz'
    if archive.is_symlink() or digest(archive) != reference.SOURCE_SHA256: raise RuntimeError('Pinned source archive unavailable or changed')
    source = args.output / 'sdk'; source.mkdir()
    with tarfile.open(archive) as package:
        for member in package.getmembers():
            path = PurePosixPath(member.name)
            if path.is_absolute() or '..' in path.parts or member.issym() or member.islnk(): raise RuntimeError('Unsafe SDK member')
            target = source.joinpath(*path.parts)
            if member.isdir(): target.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                with target.open('xb') as output: output.write(package.extractfile(member).read())
    arch = platform.machine(); suffix = 'arm64' if arch == 'arm64' else 'x64'
    flags = ['-arch', arch, '-mmacosx-version-min=14.0']
    executable = args.output / 'ArchiveEditProbe'
    with (args.output / 'build.log').open('wb') as log:
        subprocess.run(['make', '-f', f'../../cmpl_mac_{suffix}.mak', '-j2', 'MY_ARCH=' + ' '.join(flags)],
                       cwd=source / 'CPP/7zip/UI/Client7z', stdout=log, stderr=log, check=True, timeout=120)
        common = sorted((source / f'CPP/7zip/UI/Client7z/b/m_{suffix}').glob('*.o'))
        common = [p for p in common if p.name != 'Client7z.o']
        if len(common) != 19: raise RuntimeError('Unexpected support objects')
        adapter = args.output / 'adapter.o'; probe = args.output / 'probe.o'
        includes = ['-I', str(source), '-I', str(repo / 'Tools/SevenZipWorker')]
        for file, obj, extra in [(repo / 'Tools/SevenZipWorker/ArchiveSDK.cpp', adapter, []),
                                 (repo / 'Tools/SevenZipEditProbe/main.mm', probe, ['-fobjc-arc'])]:
            subprocess.run(['clang++', '-std=c++11', '-Wall', '-Wextra', '-Werror', *flags, *includes, *extra, '-c', str(file), '-o', str(obj)],
                           check=True, stdout=log, stderr=log, timeout=60)
        subprocess.run(['clang++', *flags, str(adapter), str(probe), *map(str, common), '-framework', 'Foundation', '-framework', 'CoreFoundation', '-ldl', '-lpthread', '-o', str(executable)],
                       check=True, stdout=log, stderr=log, timeout=30)
    checks = {}
    def check(name, condition):
        checks[name] = bool(condition)
        (args.output / 'checks-so-far.json').write_text(json.dumps(checks, indent=2) + '\n')
        if not condition: raise RuntimeError('Failed check: ' + name)
    def invoke(archive, request, output, extra=(), mutate=None, source_writable=False, nonempty=False):
        source_fd = os.open(archive, os.O_RDWR if source_writable else os.O_RDONLY)
        output_fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        if nonempty: os.write(output_fd, b'foreign')
        data = json.dumps(dict(request, pause=mutate is not None)).encode()
        process = None
        try:
            process = subprocess.Popen([str(executable.resolve()), str(args.library), str(source_fd), str(output_fd)],
                                       pass_fds=(source_fd, output_fd, *extra), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if mutate:
                process.stdin.write(struct.pack('!I', len(data)) + data); process.stdin.flush()
                import selectors
                with selectors.DefaultSelector() as selector:
                    selector.register(process.stdout, selectors.EVENT_READ)
                    if not selector.select(10): raise RuntimeError('Probe ready timeout')
                if json.loads(process.stdout.readline()) != {'ready': True}: raise RuntimeError('Probe did not open')
                mutate(); process.stdin.write(b'g'); process.stdin.flush(); process.stdin.close(); process.stdin = None
                stdout, stderr = process.communicate(timeout=20)
            else: stdout, stderr = process.communicate(struct.pack('!I', len(data)) + data, timeout=20)
            if stderr: raise RuntimeError('Unexpected native diagnostics')
            result = json.loads(stdout)
            if result.get('localeRestored') is not True: raise RuntimeError('Native API changed caller locale')
            if process.returncode != (1 if result['error'] else 0): raise RuntimeError('Probe exit mismatch')
            return result
        finally:
            if process is not None and process.poll() is None: process.kill(); process.wait()
            os.close(source_fd); os.close(output_fd)
    def inspect(archive, fmt, password=None):
        target = args.output / ('inspect-' + str(inspect.counter)); inspect.counter += 1
        result = invoke(archive, dict(format=fmt, password=password, inspect=True, items=[]), target)
        if result['error']: raise RuntimeError('Unable to inspect fixture: ' + str(result))
        return result['items']
    inspect.counter = 0
    fixtures = args.output / 'fixtures'; fixtures.mkdir()
    (fixtures / 'folder').mkdir(); (fixtures / 'folder/keep.txt').write_bytes(b'keep exact payload')
    (fixtures / 'folder/delete.txt').write_bytes(b'delete payload')
    (fixtures / 'root.txt').write_bytes(b'root payload')
    (fixtures / 'empty').mkdir()
    added = args.output / 'new-input'; added.write_bytes(b'added payload')
    for fmt, extension in [(1, 'zip'), (7, '7z')]:
        password = 'Edit-370-ASCII' if fmt == 1 else 'Edit-370-한글-🔑'
        for encrypted in [False, True]:
            label = extension + ('-encrypted' if encrypted else '-plain')
            archive = args.output / (label + '.' + extension)
            command = [str(args.reference), 'a', '-t' + extension, '-y', str(archive.resolve()), '.']
            if encrypted: command += ['-p', '-mhe=on' if fmt == 7 else '-mem=AES256']
            subprocess.run(command, cwd=fixtures, input=((password + '\n') * 2).encode() if encrypted else b'',
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True, timeout=20)
            secret = password if encrypted else None
            before = archive.read_bytes(); entries = inspect(archive, fmt, secret)
            by_name = {e['path']: e for e in entries}
            retained = []
            for item in entries:
                if item['path'] == 'folder/delete.txt': continue
                path = item['path']; renamed = 'renamed' + path[len('folder'):] if path == 'folder' or path.startswith('folder/') else ('root-renamed.txt' if path == 'root.txt' else None)
                retained.append(dict(old=item['index'], **({'path': renamed} if renamed else {})))
            output = args.output / ('edited-' + label + '.' + extension)
            fd = os.open(added, os.O_RDONLY)
            try:
                plan = retained + [dict(directory=True, path='new-folder'), dict(fd=fd, path='new-folder/한글\nadded.txt')]
                response = invoke(archive, dict(format=fmt, password=secret, encrypt=encrypted, items=plan), output, extra=(fd,))
            finally: os.close(fd)
            check(label + '-edit-success', response['error'] == 0)
            check(label + '-source-unchanged', archive.read_bytes() == before)
            after = inspect(output, fmt, secret); names = {e['path'] for e in after}
            check(label + '-desired-paths', names == {'renamed', 'renamed/keep.txt', 'root-renamed.txt', 'empty', 'new-folder', 'new-folder/한글\nadded.txt'})
            restored = args.output / ('restored-' + label)
            command = [str(args.reference), 'x', '-y', '-o' + str(restored), str(output)]
            subprocess.run(command, input=((password + '\n') * 2).encode() if encrypted else b'', check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
            check(label + '-official-payloads', (restored / 'renamed/keep.txt').read_bytes() == b'keep exact payload' and (restored / 'root-renamed.txt').read_bytes() == b'root payload' and (restored / 'new-folder/한글\nadded.txt').read_bytes() == b'added payload')
            check(label + '-retained-metadata', all(next(e for e in after if e['path'] == desired)[key] == by_name[original][key] for original, desired in [('folder/keep.txt','renamed/keep.txt'), ('root.txt','root-renamed.txt')] for key in ['size','encrypted','permissions','modifiedSeconds','modifiedNanos']))
            for bad_name, bad_plan in [('duplicate-index', [dict(old=0),dict(old=0)]), ('traversal',[dict(old=0,path='../escape')]),
                                       ('absolute',[dict(old=0,path='/escape')]), ('drive',[dict(old=0,path='C:/escape')]),
                                       ('tilde',[dict(old=0,path='~/escape')]), ('backslash',[dict(old=0,path='a\\b')]),
                                       ('duplicate-name',[dict(old=0,path='same'),dict(old=1,path='same')]),
                                       ('unicode-collision',[dict(old=0,path='é'),dict(old=1,path='e\u0301')]),
                                       ('file-parent',[dict(old=by_name['root.txt']['index'],path='x'),dict(old=by_name['folder/keep.txt']['index'],path='x/child')])]:
                target = args.output / (label + '-' + bad_name)
                response = invoke(archive, dict(format=fmt,password=secret,encrypt=encrypted,items=bad_plan), target)
                check(label + '-' + bad_name, response['error'] == 6 and target.stat().st_size == 0 and archive.read_bytes() == before)
            if encrypted:
                target = args.output / (label + '-wrong-password')
                response = invoke(archive, dict(format=fmt,password='incorrect',items=[dict(old=by_name['root.txt']['index'])]), target)
                check(label + '-wrong-password', response['error'] in [3,4] and target.stat().st_size == 0 and archive.read_bytes() == before)
            empty_output = args.output / (label + '-delete-all.' + extension)
            response = invoke(archive, dict(format=fmt,password=secret,items=[]), empty_output)
            check(label + '-delete-all', response['error'] == 0 and inspect(empty_output,fmt,secret) == [] and archive.read_bytes() == before)
            target = args.output / (label + '-nonempty')
            response = invoke(archive, dict(format=fmt,password=secret,items=[]), target, nonempty=True)
            check(label + '-nonempty-output-preserved', response['error'] == 6 and target.read_bytes() == b'foreign')
    # Unicode AES ZIP reading/metadata edits must not inherit the SDK ZIP writer's
    # non-ASCII creation restriction. New encrypted payloads still need a product bridge.
    password = '한글-é-🔑-370'; archive = args.output / 'unicode-aes.zip'
    payload = unicode_aes_zip(archive, password); before = archive.read_bytes()
    subprocess.run([str(args.reference), 't', str(archive)], input=(password + '\n').encode(),
                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True, timeout=20)
    entries = inspect(archive, 1, password)
    target = args.output / 'unicode-renamed.zip'
    response = invoke(archive, dict(format=1,password=password,items=[dict(old=entries[0]['index'],path='한글-renamed.txt'),dict(directory=True,path='new-directory')]), target)
    check('unicode-zip-metadata-edit', response['error'] == 0 and archive.read_bytes() == before)
    restored = args.output / 'unicode-restored'
    subprocess.run([str(args.reference), 'x', '-y', '-o' + str(restored), str(target)], input=(password + '\n').encode(),
                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True, timeout=20)
    check('unicode-zip-official-payload', (restored / '한글-renamed.txt').read_bytes() == payload)
    check('unicode-zip-encryption-preserved', next(e for e in inspect(target,1,password) if e['path']=='한글-renamed.txt')['encrypted'])
    fd = os.open(added,os.O_RDONLY)
    try:
        target = args.output / 'unicode-zip-addition-unsupported'
        response = invoke(archive,dict(format=1,password=password,encrypt=True,items=[dict(old=0),dict(fd=fd,path='new')]),target,extra=(fd,))
        check('unicode-zip-new-encrypted-data-rejected-before-output',response['error']==11 and target.stat().st_size==0 and archive.read_bytes()==before)
    finally:os.close(fd)
    # Failure races use a source snapshot taken before the pause, not a mock decoder.
    archive = args.output / 'zip-plain.zip'; original = archive.read_bytes(); index = next(e['index'] for e in inspect(archive,1) if e['path']=='root.txt')
    target = args.output / 'changed-source'
    response = invoke(archive,dict(format=1,items=[dict(old=index)]),target,mutate=lambda:archive.write_bytes(original+b'foreign'))
    check('source-change-before-edit',response['error']==9 and target.stat().st_size==0 and archive.read_bytes()==original+b'foreign')
    archive.write_bytes(original)
    fd = os.open(added,os.O_RDONLY)
    try:
        before = added.read_bytes(); target = args.output/'changed-addition'
        response = invoke(archive,dict(format=1,items=[dict(old=index),dict(fd=fd,path='new')]),target,extra=(fd,),mutate=lambda:added.write_bytes(before+b'foreign'))
        check('addition-change-before-edit',response['error']==9 and target.stat().st_size==0 and archive.read_bytes()==original and added.read_bytes()==before+b'foreign')
    finally:os.close(fd)
    target=args.output/'writable-source';response=invoke(archive,dict(format=1,items=[]),target,source_writable=True)
    check('writable-archive-descriptor-rejected',response['error']!=0 and target.stat().st_size==0 and archive.read_bytes()==original)
    fd=os.open(added,os.O_RDWR)
    try:
        target=args.output/'writable-addition';response=invoke(archive,dict(format=1,items=[dict(fd=fd,path='new')]),target,extra=(fd,))
        check('writable-addition-descriptor-rejected',response['error']==9 and target.stat().st_size==0 and archive.read_bytes()==original)
    finally:os.close(fd)
    target=args.output/'limit';response=invoke(archive,dict(format=1,maximum=1,items=[dict(old=index)]),target)
    check('declared-data-limit-before-output',response['error']==7 and target.stat().st_size==0 and archive.read_bytes()==original)
    for label, request, expected in [
        ('source-snapshot-mismatch',dict(format=1,sourceSizeDelta=1,items=[]),9),
        ('unsupported-format',dict(format=99,items=[]),6),
        ('invalid-retained-index',dict(format=1,items=[dict(old=4294967295)]),6),
    ]:
        target=args.output/label;response=invoke(archive,request,target)
        check(label,response['error']==expected and target.stat().st_size==0 and archive.read_bytes()==original)
    source7z=args.output/'7z-plain.7z';before=source7z.read_bytes();target=args.output/'read-only-session'
    response=invoke(source7z,dict(format=7,readOnlySession=True,items=[]),target)
    check('read-session-does-not-grant-editing',response['error']==6 and target.stat().st_size==0 and source7z.read_bytes()==before)
    fd=os.open(added,os.O_RDONLY);foreign=os.open(archive,os.O_RDONLY)
    try:
        target=args.output/'foreign-addition';response=invoke(archive,dict(format=1,items=[dict(fd=fd,returnFD=foreign,path='new')]),target,extra=(fd,foreign))
        check('foreign-addition-identity-rejected',response['error']==9 and target.stat().st_size==0 and archive.read_bytes()==original)
    finally:os.close(fd);os.close(foreign)
    archive=args.output/'corrupt.zip'
    with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_STORED) as z:z.writestr('data',b'CRC protected payload')
    raw=bytearray(archive.read_bytes());raw[34]^=1;archive.write_bytes(raw);before=archive.read_bytes()
    target=args.output/'corrupt-output';response=invoke(archive,dict(format=1,items=[dict(old=0)]),target)
    check('retained-data-crc-failure-before-output',response['error']==12 and target.stat().st_size==0 and archive.read_bytes()==before)
    archive=args.output/'link-and-comment.zip'
    with zipfile.ZipFile(archive,'w') as z:
        link=zipfile.ZipInfo('link');link.create_system=3;link.external_attr=(stat.S_IFLNK|0o777)<<16;link.comment=b'entry note';z.comment=b'archive note';z.writestr(link,b'../outside')
    before=archive.read_bytes();target=args.output/'renamed-link.zip'
    response=invoke(archive,dict(format=1,items=[dict(old=0,path='renamed-link')]),target)
    check('opaque-link-edit',response['error']==0 and archive.read_bytes()==before and inspect(target,1)[0]['kind']==2)
    with zipfile.ZipFile(target) as z:
        check('link-target-and-comments-preserved',z.read('renamed-link')==b'../outside' and z.getinfo('renamed-link').comment==b'entry note' and z.comment==b'archive note')
    report = dict(passed=True, checks=checks, architecture=arch, librarySHA256=digest(args.library), probeSHA256=digest(executable),
                  sourcesSHA256={str(p.relative_to(repo)):digest(p) for p in [repo/'Tools/SevenZipWorker/ArchiveSDK.cpp',repo/'Tools/SevenZipWorker/ArchiveSDK.h',repo/'Tools/SevenZipEditProbe/main.mm',Path(__file__).resolve()]},
                  productIPCExercised=False, atomicPublicationImplemented=False, editingCapabilityEnabled=False, localGUIStarted=False,
                  unicodeZIPEncryptedAdditionsSupported=False)
    report['packagedSourcesBound'] = bool(args.app)
    (args.output / 'result.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(dict(passed=True, checks=len(checks)),indent=2))

if __name__ == '__main__': main()
