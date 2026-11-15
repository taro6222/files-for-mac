#!/usr/bin/env python3
"""Create the shared browsing fixture used by Windows and macOS screenshots."""

import argparse
import os
from pathlib import Path


def create(folder):
    folder.mkdir(parents=True, exist_ok=False)
    for name in ("Alpha", "Workshop"):
        (folder / name).mkdir()
    leaf = folder / "Alpha" / "column-note.txt"
    leaf.write_bytes(b"Files reference columns\n")
    os.utime(leaf, (1705320000, 1705320000))
    for name, payload in (
        ("notes.txt", b"Files reference notes\n"),
        ("preview.txt", b"Files reference preview\n"),
        ("readme.md", b"# Files reference fixture\n"),
    ):
        (folder / name).write_bytes(payload)
    for item in folder.iterdir():
        os.utime(item, (1705320000, 1705320000))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folder", type=Path)
    create(parser.parse_args().folder)
