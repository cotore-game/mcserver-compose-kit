#!/usr/bin/env python3
"""Read the saved Minecraft version from a world's level.dat."""

from __future__ import annotations

import gzip
import io
import re
import struct
import sys
import zipfile
from pathlib import Path
from typing import Any, BinaryIO


class NbtError(Exception):
    pass


class NbtReader:
    def __init__(self, stream: BinaryIO) -> None:
        self.stream = stream

    def read_exact(self, size: int) -> bytes:
        data = self.stream.read(size)
        if len(data) != size:
            raise NbtError("unexpected end of NBT data")
        return data

    def unpack(self, fmt: str) -> Any:
        return struct.unpack(">" + fmt, self.read_exact(struct.calcsize(">" + fmt)))[0]

    def read_string(self) -> str:
        length = self.unpack("H")
        return self.read_exact(length).decode("utf-8")

    def read_length(self) -> int:
        length = self.unpack("i")
        if length < 0 or length > 10_000_000:
            raise NbtError(f"invalid NBT collection length: {length}")
        return length

    def read_payload(self, tag_type: int) -> Any:
        if tag_type == 1:
            return self.unpack("b")
        if tag_type == 2:
            return self.unpack("h")
        if tag_type == 3:
            return self.unpack("i")
        if tag_type == 4:
            return self.unpack("q")
        if tag_type == 5:
            return self.unpack("f")
        if tag_type == 6:
            return self.unpack("d")
        if tag_type == 7:
            return self.read_exact(self.read_length())
        if tag_type == 8:
            return self.read_string()
        if tag_type == 9:
            item_type = self.unpack("B")
            return [self.read_payload(item_type) for _ in range(self.read_length())]
        if tag_type == 10:
            result: dict[str, Any] = {}
            while True:
                child_type = self.unpack("B")
                if child_type == 0:
                    return result
                child_name = self.read_string()
                result[child_name] = self.read_payload(child_type)
        if tag_type == 11:
            return [self.unpack("i") for _ in range(self.read_length())]
        if tag_type == 12:
            return [self.unpack("q") for _ in range(self.read_length())]
        raise NbtError(f"unsupported NBT tag type: {tag_type}")

    def read_root(self) -> dict[str, Any]:
        tag_type = self.unpack("B")
        if tag_type != 10:
            raise NbtError("NBT root is not a compound")
        self.read_string()
        root = self.read_payload(tag_type)
        if not isinstance(root, dict):
            raise NbtError("invalid NBT root")
        return root


def find_level_dat(source: Path) -> bytes:
    if source.is_file() and source.name == "level.dat":
        return source.read_bytes()

    if source.is_dir():
        level_dat = source / "level.dat"
        if not level_dat.is_file():
            raise NbtError(f"level.dat was not found directly under {source}")
        return level_dat.read_bytes()

    if source.is_file() and source.suffix.lower() == ".zip":
        with zipfile.ZipFile(source) as archive:
            candidates = [
                info for info in archive.infolist()
                if not info.is_dir() and Path(info.filename).name == "level.dat"
            ]
            if len(candidates) != 1:
                raise NbtError(
                    f"expected one level.dat in ZIP, found {len(candidates)}"
                )
            return archive.read(candidates[0])

    raise NbtError(f"unsupported world source: {source}")


def detect_version(source: Path) -> str:
    compressed = find_level_dat(source)
    try:
        nbt_data = gzip.decompress(compressed)
    except (gzip.BadGzipFile, EOFError) as error:
        raise NbtError("level.dat is not valid gzip data") from error

    root = NbtReader(io.BytesIO(nbt_data)).read_root()
    data = root.get("Data", root)
    if not isinstance(data, dict):
        raise NbtError("Data compound was not found")

    version = data.get("Version")
    name = version.get("Name") if isinstance(version, dict) else None
    if not isinstance(name, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", name):
        raise NbtError("Version.Name was not found or is not a release version")
    return name


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} WORLD_OR_ZIP", file=sys.stderr)
        return 2

    try:
        print(detect_version(Path(sys.argv[1])))
    except (NbtError, OSError, zipfile.BadZipFile) as error:
        print(f"version detection failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
