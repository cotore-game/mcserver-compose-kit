#!/usr/bin/env python3
"""Read and atomically update Minecraft server.properties values."""

from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path


def parse_line(line: str) -> tuple[str, str] | None:
    stripped = line.strip()
    if not stripped or stripped.startswith(("#", "!")) or "=" not in line:
        return None
    key, value = line.rstrip("\r\n").split("=", 1)
    return key.strip(), value


def read_lines(path: Path) -> list[str]:
    return path.read_text(encoding="utf-8").splitlines(keepends=True)


def get_value(path: Path, target: str) -> str | None:
    for line in read_lines(path):
        parsed = parse_line(line)
        if parsed is not None and parsed[0] == target:
            return parsed[1]
    return None


def set_value(path: Path, target: str, value: str) -> None:
    if any(character in value for character in "\r\n"):
        raise ValueError("property values cannot contain newlines")
    lines = read_lines(path)
    replacement = f"{target}={value}\n"
    replaced = False
    for index, line in enumerate(lines):
        parsed = parse_line(line)
        if parsed is not None and parsed[0] == target:
            lines[index] = replacement
            replaced = True
            break
    if not replaced:
        if lines and not lines[-1].endswith(("\n", "\r")):
            lines[-1] += "\n"
        lines.append(replacement)

    descriptor, temporary_name = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as file:
            file.writelines(lines)
        os.chmod(temporary_name, path.stat().st_mode & 0o777)
        os.replace(temporary_name, path)
    finally:
        if os.path.exists(temporary_name):
            os.unlink(temporary_name)


def main() -> int:
    if len(sys.argv) not in (4, 5) or sys.argv[1] not in ("get", "set"):
        print("usage: server-property.py get|set FILE KEY [VALUE]", file=sys.stderr)
        return 2

    operation = sys.argv[1]
    path = Path(sys.argv[2])
    key = sys.argv[3]
    if not path.is_file():
        print(f"properties file not found: {path}", file=sys.stderr)
        return 1

    if operation == "get":
        value = get_value(path, key)
        if value is None:
            return 1
        print(value)
        return 0

    if len(sys.argv) != 5:
        return 2
    set_value(path, key, sys.argv[4])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
