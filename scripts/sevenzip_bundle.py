#!/usr/bin/env python3
"""Install and verify the pinned private SDK code, notices, and corresponding sources."""
import argparse
import hashlib
import json
import plistlib
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import sevenzip_reference as reference

RESOURCE = 'Contents/Resources/ThirdParty/7zip'
CODE = ['Contents/Helpers/SevenZipWorker', 'Contents/Helpers/7z.so']
NOTICES = ['License.txt', 'copying.txt', 'unRarLicense.txt', 'readme.txt']
SOURCE_FILES = ['Tools/SevenZipWorker/ArchiveSDK.h', 'Tools/SevenZipWorker/ArchiveSDK.cpp',
                'Tools/SevenZipWorker/main.mm', 'scripts/build-sevenzip-worker.py', 'scripts/sevenzip_reference.py']
ARCHIVE_NAME = '7z2606-src.tar.xz'
RESOURCE_FILES = [*NOTICES, ARCHIVE_NAME, 'BUILD.md', 'Sources/LICENSE.txt', *['Sources/' + name for name in SOURCE_FILES]]
FILES = CODE + [RESOURCE + '/' + name for name in RESOURCE_FILES]


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for data in iter(lambda: stream.read(65536), b''): result.update(data)
    return result.hexdigest()


def regular(app, relative):
    path = app
    if app.is_symlink() or not app.is_dir(): raise ValueError('App must be a real directory')
    for part in Path(relative).parts:
        if part in ['.', '..'] or Path(relative).is_absolute(): raise ValueError('Invalid bundle path')
        path = path / part
        if path.is_symlink(): raise ValueError('Symlink in SDK bundle path')
    if not path.is_file(): raise ValueError('Missing regular SDK bundle file: ' + relative)
    return path


def architectures(path):
    result = subprocess.check_output(['lipo', '-archs', str(path)], text=True).strip().split()
    if not result or len(set(result)) != len(result) or not set(result) <= {'arm64', 'x86_64'}:
        raise ValueError('Unexpected Mach-O architectures')
    return sorted(result)


def check_code(app, expected, signatures):
    if architectures(regular(app, 'Contents/MacOS/FilesMac')) != expected:
        raise ValueError('App and SDK architectures differ')
    for name in CODE:
        path = regular(app, name)
        if architectures(path) != expected: raise ValueError('SDK architecture mismatch')
        for architecture in expected:
            metadata = subprocess.check_output(['xcrun', 'vtool', '-arch', architecture, '-show-build', str(path)], text=True)
            values = dict(line.split() for line in metadata.splitlines() if len(line.split()) == 2)
            if values.get('platform') != 'MACOS' or values.get('minos') != '14.0':
                raise ValueError('SDK must target macOS 14.0')
            dependencies = subprocess.check_output(['otool', '-arch', architecture, '-L', str(path)], text=True)
            for line in dependencies.splitlines()[1:]:
                dependency = line.strip().split(' (', 1)[0]
                if dependency == '@rpath/7z.so' and name == CODE[1]: continue
                if not dependency.startswith(('/usr/lib/', '/System/Library/')):
                    raise ValueError('Non-system SDK dependency')
        if signatures:
            subprocess.run(['codesign', '--verify', '--all-architectures', '--strict', str(path)], check=True)
            if name == CODE[0]:
                for architecture in expected:
                    entitlements = plistlib.loads(subprocess.check_output(['codesign', '-d', '--arch', architecture, '--entitlements', ':-', str(path)], stderr=subprocess.DEVNULL))
                    if entitlements != {'com.apple.security.app-sandbox': True} or type(entitlements['com.apple.security.app-sandbox']) is not bool:
                        raise ValueError('Worker must have only the App Sandbox entitlement')
    if signatures: subprocess.run(['codesign', '--verify', '--all-architectures', '--strict', str(app)], check=True)


def read_manifest(app):
    path = regular(app, RESOURCE + '/manifest.json')
    if path.stat().st_size > 1024 * 1024: raise ValueError('SDK manifest size limit exceeded')
    return json.loads(path.read_text())


def verify(app, signatures=True, changed_code=False):
    manifest = read_manifest(app)
    info = plistlib.loads(regular(app, 'Contents/Info.plist').read_bytes())
    if info.get('FilesArchiveSDKVersion') != reference.VERSION: raise ValueError('Missing SDK version in app metadata')
    if type(manifest.get('version')) is not int or manifest['version'] != 1 or manifest.get('SDKVersion') != reference.VERSION or manifest.get('SDKSourceSHA256') != reference.SOURCE_SHA256:
        raise ValueError('Unexpected SDK provenance')
    if set(manifest.get('filesSHA256', {})) != set(FILES): raise ValueError('Unexpected SDK file manifest')
    expected = manifest.get('architectures')
    if expected not in [['arm64'], ['x86_64'], ['arm64', 'x86_64']]: raise ValueError('Unexpected SDK slices')
    for name in FILES:
        path = regular(app, name)
        if not (changed_code and name in CODE) and digest(path) != manifest['filesSHA256'][name]:
            raise ValueError('SDK bundle bytes changed: ' + name)
    root = app / RESOURCE
    observed = set(); directories = set()
    for path in root.rglob('*'):
        if path.is_symlink() or not (path.is_dir() or path.is_file()): raise ValueError('Unexpected SDK resource entry')
        if path.is_file(): observed.add(str(path.relative_to(root)))
        else: directories.add(str(path.relative_to(root)))
    if observed != set(RESOURCE_FILES + ['manifest.json']): raise ValueError('Unexpected SDK resource contents')
    expected_directories = {str(parent) for name in RESOURCE_FILES for parent in Path(name).parents if str(parent) != '.'}
    if directories != expected_directories: raise ValueError('Unexpected SDK resource directories')
    if {p.name for p in (app / 'Contents/Resources/ThirdParty').iterdir()} != {'7zip'}:
        raise ValueError('Unexpected third-party directory contents')
    for directory, expected_files in [('Contents/Helpers', {'SevenZipWorker', '7z.so'}), ('Contents/Frameworks', set())]:
        path = app / directory
        if path.is_symlink() or set(p.name for p in path.iterdir()) != expected_files:
            raise ValueError('Unexpected SDK code directory contents')
    source = regular(app, RESOURCE + '/' + ARCHIVE_NAME)
    if digest(source) != reference.SOURCE_SHA256: raise ValueError('SDK source archive changed')
    with tarfile.open(source) as package:
        for name in NOTICES:
            member = package.getmember('DOC/' + name)
            if not member.isfile() or package.extractfile(member).read() != (root / name).read_bytes():
                raise ValueError('SDK notice differs from the pinned source')
    builds = manifest.get('builds', {})
    if set(builds) != set(expected): raise ValueError('Missing SDK build provenance')
    for architecture, build in builds.items():
        inputs = build['inputs']
        if inputs['architecture'] != architecture or inputs['SDKSourceSHA256'] != reference.SOURCE_SHA256 or inputs['minimumOS'] != '14.0':
            raise ValueError('SDK build inputs changed')
        for name, expected_hash in inputs['helperSourcesSHA256'].items():
            if name not in ['ArchiveSDK.h', 'ArchiveSDK.cpp', 'main.mm'] or digest(root / 'Sources/Tools/SevenZipWorker' / name) != expected_hash:
                raise ValueError('Corresponding helper source changed')
        if set(inputs['helperSourcesSHA256']) != {'ArchiveSDK.h', 'ArchiveSDK.cpp', 'main.mm'} or digest(root / 'Sources/scripts/build-sevenzip-worker.py') != inputs['buildRecipeSHA256']:
            raise ValueError('Missing corresponding build recipe')
    check_code(app, expected, signatures)
    return manifest


def refresh(app):
    manifest = verify(app, signatures=False, changed_code=True)
    for name in CODE: manifest['filesSHA256'][name] = digest(regular(app, name))
    (app / RESOURCE / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')


def install(app, source_archive=None):
    repo = Path(__file__).resolve().parent.parent
    expected = architectures(regular(app, 'Contents/MacOS/FilesMac'))
    targets = [app / 'Contents/Helpers', app / 'Contents/Frameworks', app / 'Contents/Resources/ThirdParty']
    if any(path.exists() or path.is_symlink() for path in targets):
        raise ValueError('SDK destination already exists; refusing to overwrite')
    if source_archive is None:
        source_archive = repo / 'build/sevenzip-source' / reference.VERSION / 'source.tar.xz'
        if not source_archive.exists() and not source_archive.is_symlink():
            with urllib.request.urlopen(reference.SOURCE_URL, timeout=60) as response:
                if not response.url.startswith('https://'): raise ValueError('Non-HTTPS source redirect')
                data = response.read(2 * 1024 * 1024 + 1)
            if len(data) > 2 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != reference.SOURCE_SHA256:
                raise ValueError('SDK source download mismatch')
            source_archive.parent.mkdir(parents=True, exist_ok=True)
            with source_archive.open('xb') as stream: stream.write(data)
    if source_archive.is_symlink() or digest(source_archive) != reference.SOURCE_SHA256: raise ValueError('SDK source archive hash mismatch')
    builds = {}; workers = {}
    for architecture in expected:
        command = [sys.executable, str(repo / 'scripts/build-sevenzip-worker.py'), '--architecture', architecture]
        if source_archive: command += ['--archive', str(source_archive)]
        worker = Path(subprocess.check_output(command, text=True).strip())
        workers[architecture] = worker
        builds[architecture] = json.loads((worker.parent / 'manifest.json').read_text())
    if source_archive.is_symlink() or digest(source_archive) != reference.SOURCE_SHA256: raise ValueError('SDK source archive hash mismatch')
    # All dependencies are prepared before publishing any private SDK directory into the new app.
    with tempfile.TemporaryDirectory(prefix='.sevenzip-bundle-', dir=app.parent) as directory:
        stage = Path(directory)
        (stage / 'Contents/Frameworks').mkdir(parents=True)
        for name in FILES: (stage / name).parent.mkdir(parents=True, exist_ok=True)
        for name, component in zip(CODE, ['SevenZipWorker', '7z.so']):
            inputs = [workers[a].parent / component for a in expected]
            if len(inputs) == 1: shutil.copy2(inputs[0], stage / name)
            else: subprocess.run(['lipo', '-create', *map(str, inputs), '-output', str(stage / name)], check=True)
        subprocess.run(['install_name_tool', '-id', '@rpath/7z.so', str(stage / CODE[1])], check=True)
        root = stage / RESOURCE
        shutil.copyfile(source_archive, root / ARCHIVE_NAME)
        with tarfile.open(source_archive) as package:
            for name in NOTICES:
                member = package.getmember('DOC/' + name)
                if not member.isfile(): raise ValueError('Unexpected SDK notice kind')
                (root / name).write_bytes(package.extractfile(member).read())
        for name in SOURCE_FILES: shutil.copyfile(repo / name, root / 'Sources' / name)
        shutil.copyfile(repo / 'LICENSE', root / 'Sources/LICENSE.txt')
        (root / 'BUILD.md').write_text(f'''# 7-Zip {reference.VERSION} private helper sources

The unmodified official source archive is {ARCHIVE_NAME}.
SHA-256: {reference.SOURCE_SHA256}
Upstream: {reference.SOURCE_URL}

License.txt, copying.txt, unRarLicense.txt and readme.txt are copied verbatim from
the archive's DOC directory. Per-file BSD/public-domain notices remain in the
complete archive. The Files helper adapter and build recipe are in Sources;
Sources/LICENSE.txt is their project license. No SDK source patches are applied.

Copy this entire 7zip directory out of the installed app to a writable directory
before rebuilding. Do not modify the installed signed app in place.
With Apple Command Line Tools installed, run from the copied directory:

```sh
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
python3 Sources/scripts/build-sevenzip-worker.py --architecture arm64 --archive "$PWD/{ARCHIVE_NAME}"
python3 Sources/scripts/build-sevenzip-worker.py --architecture x86_64 --archive "$PWD/{ARCHIVE_NAME}"
```

The script builds the official Format7zF bundle and common support objects, then
links the supplied adapter with system Foundation. It prints an immutable output
path containing SevenZipWorker, 7z.so, notices and build/byte provenance. The SDK
is dynamically loaded by explicit path, rather than statically linked into the
app. To test a rebuilt or modified SDK, use a separate writable project checkout
at https://github.com/taro6222/files-for-mac with the supplied helper sources and
build recipe. Packaging, local signing and verification scripts are in scripts/.
Developer ID signing/notarization is separate from a local development rebuild.
The command-line helper embeds its own Info.plist. Product signing grants only
com.apple.security.app-sandbox=true (no inheritance, network, or user-file grants).
The packaged library lives beside the helper in Contents/Helpers so it remains
readable inside that sandbox. The rebuilding output is a diagnostic tool until
the packaging/signing policy is applied; it is not a sandbox acceptance result.
Compiler/SDK versions and per-architecture inputs are recorded in manifest.json;
different toolchains are not claimed to produce byte-identical binaries.
''')
        manifest = dict(version=1, SDKVersion=reference.VERSION, SDKSourceSHA256=reference.SOURCE_SHA256,
                        architectures=expected, builds=builds, filesSHA256={name: digest(stage / name) for name in FILES})
        (root / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        for target in targets:
            if target.exists() or target.is_symlink(): raise ValueError('SDK destination appeared during build')
        for relative in ['Contents/Helpers', 'Contents/Frameworks', 'Contents/Resources/ThirdParty']:
            (stage / relative).rename(app / relative)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['install', 'verify', 'refresh-code-hashes'])
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--source-archive', type=Path)
    parser.add_argument('--skip-signatures', action='store_true')
    args = parser.parse_args()
    if args.operation == 'install': install(args.app.absolute(), args.source_archive)
    elif args.operation == 'refresh-code-hashes': refresh(args.app)
    else: verify(args.app, signatures=not args.skip_signatures)
    print('7z bundle ' + args.operation + ' passed')


if __name__ == '__main__': main()
