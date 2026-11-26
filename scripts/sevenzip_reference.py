#!/usr/bin/env python3
"""Acquire an immutable, hash-pinned official 7-Zip reference; never install globally."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import platform
import shutil
import tarfile
import tempfile
import urllib.request

VERSION = '26.06'
ASSETS = {
    'arm64': ('7z2606-mac.tar.xz', 'b6f17920b4240940461dac8ef4009891881ac44d2a5ead625ede2ec8472185dd',
              '56cf8eb2fdc6f9c0ac5d7a3cd238505814ac8ed6b88a7c64a7e3256036252c60'),
    'x86_64': ('7z2606-mac-x64.tar.xz', '3af68b124052da7fc2a246c96b0bea6a68bfee389baa788f4cead1a133445586',
               'd54aa0864244abeef158772fbde3dd9bac2b93a54c564a76c4334c5a8bcaf35a'),
}
NOTICE_HASHES = {'License.txt': '1790374e5352329cedb46ee3808930a88e9ca2f08b82b10fcf5cf605d2c301b1',
                 'readme.txt': '79aa0fedbfb43f32d60858c8f13f42afc025adf19bf3e7ed66a7c55f451eae45'}
SOURCE_URL = 'https://github.com/ip7z/7zip/releases/download/26.06/7z2606-src.tar.xz'
SOURCE_SHA256 = 'a4e374c8f864f51df48c2cfd0e1413ec3b2ea030deae852d6a655402ebb61ac4'

def digest(data):
    return hashlib.sha256(data).hexdigest()

def unpack(data, architecture):
    name, archive_hash, binary_hash = ASSETS[architecture]
    if digest(data) != archive_hash:
        raise ValueError('Official reference archive hash mismatch')
    expected = {'7zz': binary_hash, **NOTICE_HASHES}
    result = {}
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:xz') as archive:
        for member in archive.getmembers():
            if member.name not in expected: continue
            if not member.isfile() or member.name in result or member.size > 4 * 1024 * 1024:
                raise ValueError('Unexpected reference member type, size, or duplicate')
            content = archive.extractfile(member).read()
            if digest(content) != expected[member.name]:
                raise ValueError('Reference member hash mismatch: ' + member.name)
            result[member.name] = content
    if set(result) != set(expected):
        raise ValueError('Reference executable or notices missing')
    return result

def acquire(output, architecture, local_archive=None):
    name, archive_hash, binary_hash = ASSETS[architecture]
    url = f'https://github.com/ip7z/7zip/releases/download/{VERSION}/{name}'
    manifest = {'version': VERSION, 'architecture': architecture, 'archiveURL': url,
                'archiveSHA256': archive_hash, 'sourceURL': SOURCE_URL, 'sourceSHA256': SOURCE_SHA256,
                'filesSHA256': {'7zz': binary_hash, **NOTICE_HASHES}}
    output = output.absolute()
    if output.exists() or output.is_symlink():
        if output.is_symlink() or not output.is_dir() or set(p.name for p in output.iterdir()) != {'7zz', 'License.txt', 'readme.txt', 'manifest.json'}:
            raise ValueError('Reference destination is not an exact pinned installation')
        for filename, expected in manifest['filesSHA256'].items():
            path = output / filename
            if path.is_symlink() or not path.is_file() or digest(path.read_bytes()) != expected:
                raise ValueError('Cached reference changed; refusing to overwrite it')
        path = output / 'manifest.json'
        if path.is_symlink() or json.loads(path.read_text()) != manifest:
            raise ValueError('Cached reference manifest changed')
        return output / '7zz'
    if local_archive:
        data = local_archive.read_bytes()
    else:
        with urllib.request.urlopen(url, timeout=60) as response:
            if not response.url.startswith('https://'):
                raise ValueError('Reference download redirected outside HTTPS')
            data = response.read(2 * 1024 * 1024 + 1)
    if len(data) > 2 * 1024 * 1024: raise ValueError('Reference download exceeds the size bound')
    files = unpack(data, architecture)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix='.sevenzip-reference-', dir=output.parent))
    try:
        for filename, content in files.items(): (temporary / filename).write_bytes(content)
        (temporary / '7zz').chmod(0o755)
        (temporary / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        if output.exists() or output.is_symlink(): raise ValueError('Reference destination appeared during acquisition')
        temporary.rename(output)
    finally:
        if temporary.exists(): shutil.rmtree(temporary)
    return output / '7zz'

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--architecture', choices=ASSETS, default=platform.machine())
    parser.add_argument('--output', type=Path)
    parser.add_argument('--archive', type=Path)
    args = parser.parse_args()
    if args.architecture not in ASSETS: parser.error('Unsupported reference architecture')
    root = Path(__file__).resolve().parent.parent
    output = args.output or root / 'build/sevenzip-reference' / VERSION / args.architecture
    print(acquire(output, args.architecture, args.archive))

if __name__ == '__main__': main()
