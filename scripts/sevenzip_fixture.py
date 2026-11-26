"""Test-only empty-file 7z fixture writer, per pinned SDK DOC/7zFormat.txt.

No product dependency. Official 7zz must validate each generated fixture.
"""
import struct
import zlib


def uint64(value):
    for extra in range(8):
        if value < (1 << (7 + 7 * extra)):
            prefix = ((0xff << (8 - extra)) & 0xff) | (value >> (8 * extra))
            return bytes([prefix]) + value.to_bytes(8, 'little')[:extra]
    return b'\xff' + value.to_bytes(8, 'little')


def empty_files(path, names):
    names = list(names)
    bits = b'\xff' * ((len(names) + 7) // 8)
    header = bytearray(b'\x01\x05' + uint64(len(names)))
    if names:
        for tag in [0x0e, 0x0f]: header += bytes([tag]) + uint64(len(bits)) + bits
        encoded = b'\x00' + b''.join((name + '\x00').encode('utf-16le') for name in names)
        header += b'\x11' + uint64(len(encoded)) + encoded
    header += b'\x00\x00'
    start = struct.pack('<QQI', 0, len(header), zlib.crc32(header))
    path.write_bytes(b"7z\xbc\xaf'\x1c\x00\x04" + struct.pack('<I', zlib.crc32(start)) + start + header)
