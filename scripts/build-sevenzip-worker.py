#!/usr/bin/env python3
"""Build the pinned SDK and framed helper into a source-fingerprinted immutable directory."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import platform
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
import uuid
import sevenzip_reference as reference

def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--architecture', choices=['arm64', 'x86_64'], default=platform.machine())
    parser.add_argument('--archive', type=Path)
    args = parser.parse_args()
    if args.architecture not in ['arm64', 'x86_64']: parser.error('Unsupported worker architecture')
    repo = Path(__file__).resolve().parent.parent
    files = [repo / 'Tools/SevenZipWorker' / name for name in ['ArchiveSDK.h', 'ArchiveSDK.cpp', 'main.mm']]
    compiler = subprocess.check_output(['clang++', '--version'], text=True).strip()
    sdk = subprocess.check_output(['xcrun', '--show-sdk-version'], text=True).strip()
    inputs = {'SDKVersion': reference.VERSION, 'SDKSourceSHA256': reference.SOURCE_SHA256, 'architecture': args.architecture,
              'minimumOS': '14.0', 'compiler': compiler, 'AppleSDK': sdk,
              'buildRecipeSHA256': digest(Path(__file__)),
              'helperSourcesSHA256': {p.name: digest(p) for p in files}}
    fingerprint = hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()
    output = repo / 'build/sevenzip-worker' / args.architecture / fingerprint
    if output.exists() or output.is_symlink():
        manifest_path = output / 'manifest.json'
        if output.is_symlink() or manifest_path.is_symlink(): raise RuntimeError('Worker cache changed')
        manifest = json.loads(manifest_path.read_text())
        if manifest['inputs'] != inputs: raise RuntimeError('Worker provenance changed')
        for name, expected in manifest['filesSHA256'].items():
            path = output / name
            if path.is_symlink() or not path.is_file() or digest(path) != expected:
                raise RuntimeError('Worker cache bytes changed; refusing to overwrite executed paths')
        print(output / 'SevenZipWorker'); return
    archive = args.archive or repo / 'build/sevenzip-source' / reference.VERSION / 'source.tar.xz'
    if not archive.exists():
        archive.parent.mkdir(parents=True, exist_ok=True)
        with urllib.request.urlopen(reference.SOURCE_URL, timeout=60) as response:
            if not response.url.startswith('https://'): raise RuntimeError('Non-HTTPS source redirect')
            data = response.read(2 * 1024 * 1024 + 1)
        if len(data) > 2 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != reference.SOURCE_SHA256:
            raise RuntimeError('SDK source download hash mismatch')
        with archive.open('xb') as stream: stream.write(data)
    if archive.is_symlink() or digest(archive) != reference.SOURCE_SHA256: raise RuntimeError('SDK source hash mismatch')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.worker-build-', dir=output.parent) as temporary:
        staging = Path(temporary); source = staging / 'source'; source.mkdir()
        with tarfile.open(archive) as package:
            members = package.getmembers()
            if sum(m.size for m in members) > 64 * 1024 * 1024: raise RuntimeError('SDK source size limit exceeded')
            for member in members:
                name = PurePosixPath(member.name)
                if name.is_absolute() or '..' in name.parts or not (member.isfile() or member.isdir()):
                    raise RuntimeError('Unexpected SDK source entry')
                path = source / name
                if member.isdir(): path.mkdir(parents=True, exist_ok=True)
                else:
                    path.parent.mkdir(parents=True, exist_ok=True)
                    with path.open('xb') as stream: stream.write(package.extractfile(member).read())
        suffix = 'arm64' if args.architecture == 'arm64' else 'x64'
        flags = ['-arch', args.architecture, '-mmacosx-version-min=14.0']
        build_log = output.parent / (fingerprint + '-' + uuid.uuid4().hex + '.build.log')
        with build_log.open('xb') as log:
            for target in ['Bundles/Format7zF', 'UI/Client7z']:
                subprocess.run(['make', '-f', f'../../cmpl_mac_{suffix}.mak', '-j2', 'MY_ARCH=' + ' '.join(flags)],
                               cwd=source / 'CPP/7zip' / target, stdout=log, stderr=log, check=True, timeout=240)
            common = sorted((source / f'CPP/7zip/UI/Client7z/b/m_{suffix}').glob('*.o'))
            common = [p for p in common if p.name != 'Client7z.o']
            if len(common) != 19: raise RuntimeError('Unexpected SDK support object set')
            subprocess.run(['clang++', '-std=c++11', '-Wall', '-Wextra', '-Werror', *flags, '-I', str(source), '-c', str(files[1]), '-o', str(staging / 'adapter.o')], stdout=log, stderr=log, check=True, timeout=60)
            subprocess.run(['clang++', '-std=c++11', '-fobjc-arc', '-Wall', '-Wextra', '-Werror', *flags, '-c', str(files[2]), '-o', str(staging / 'main.o')], stdout=log, stderr=log, check=True, timeout=60)
            subprocess.run(['clang++', *flags, str(staging / 'main.o'), str(staging / 'adapter.o'), *map(str, common), '-framework', 'Foundation', '-ldl', '-lpthread', '-o', str(staging / 'SevenZipWorker')], stdout=log, stderr=log, check=True, timeout=60)
        shutil.copyfile(source / f'CPP/7zip/Bundles/Format7zF/b/m_{suffix}/7z.so', staging / '7z.so')
        shutil.copyfile(source / 'DOC/License.txt', staging / 'License.txt')
        shutil.copyfile(build_log, staging / 'build.log')
        shutil.rmtree(source); (staging / 'main.o').unlink(); (staging / 'adapter.o').unlink()
        manifest = {'fingerprint': fingerprint, 'inputs': inputs,
                    'filesSHA256': {name: digest(staging / name) for name in ['SevenZipWorker', '7z.so', 'License.txt', 'build.log']}}
        (staging / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        if output.exists(): raise RuntimeError('Worker destination appeared during build')
        staging.rename(output)
    print(output / 'SevenZipWorker')

if __name__ == '__main__': main()
