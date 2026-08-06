#!/usr/bin/env python3
"""Validate locale catalogs against the English source catalog."""

from __future__ import annotations

import json
import sys
from pathlib import Path


def load_catalog(path: Path) -> dict[str, str]:
    with path.open(encoding="utf-8") as file:
        catalog = json.load(file)
    if not isinstance(catalog, dict) or not all(
        isinstance(key, str) and isinstance(value, str)
        for key, value in catalog.items()
    ):
        raise ValueError(f"{path}: catalog must contain string keys and values")
    empty_keys = sorted(key for key, value in catalog.items() if not value)
    if empty_keys:
        raise ValueError(f"{path}: empty translations: {', '.join(empty_keys)}")
    return catalog


def main() -> int:
    locale_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("locales")
    source_path = locale_dir / "en.json"
    source = load_catalog(source_path)
    failed = False

    for path in sorted(locale_dir.glob("*.json")):
        catalog = load_catalog(path)
        missing = sorted(source.keys() - catalog.keys())
        extra = sorted(catalog.keys() - source.keys())
        if missing or extra:
            failed = True
            if missing:
                print(f"{path}: missing keys: {', '.join(missing)}", file=sys.stderr)
            if extra:
                print(f"{path}: extra keys: {', '.join(extra)}", file=sys.stderr)

    if failed:
        return 1
    print(f"PASS: {len(list(locale_dir.glob('*.json')))} locale catalogs")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
