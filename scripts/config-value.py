#!/usr/bin/env python3
"""Read and update scalar values in the kit's simple two-level YAML config."""

from __future__ import annotations

import json
import os
import re
import sys
import tempfile
from pathlib import Path


def find_value(lines: list[str], section: str, key: str) -> tuple[int, str] | None:
    in_section = False
    section_pattern = re.compile(rf"^{re.escape(section)}:\s*(?:#.*)?$")
    key_pattern = re.compile(rf"^  {re.escape(key)}:\s*(.*?)\s*$")
    for index, line in enumerate(lines):
        text = line.rstrip("\n")
        if section_pattern.match(text):
            in_section = True
            continue
        if in_section and text and not text.startswith((" ", "#")):
            break
        if in_section:
            match = key_pattern.match(text)
            if match:
                return index, match.group(1)
    return None


def decode_scalar(value: str) -> str:
    value = re.sub(r"\s+#.*$", "", value).strip()
    if value.startswith('"') and value.endswith('"'):
        return str(json.loads(value))
    if value.startswith("'") and value.endswith("'"):
        return value[1:-1]
    return value


def main() -> int:
    if len(sys.argv) not in (5, 6) or sys.argv[1] not in ("get", "set"):
        print("usage: config-value.py get|set CONFIG SECTION KEY [VALUE]", file=sys.stderr)
        return 2

    operation, config_name, section, key = sys.argv[1:5]
    path = Path(config_name)
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    found = find_value(lines, section, key)
    if found is None:
        print(f"setting not found: {section}.{key}", file=sys.stderr)
        return 1

    index, current = found
    if operation == "get":
        print(decode_scalar(current))
        return 0

    if len(sys.argv) != 6:
        return 2
    value = sys.argv[5]
    lines[index] = f"  {key}: {json.dumps(value, ensure_ascii=False)}\n"
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as file:
            file.writelines(lines)
        os.chmod(temporary_name, 0o600)
        os.replace(temporary_name, path)
    finally:
        if os.path.exists(temporary_name):
            os.unlink(temporary_name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
