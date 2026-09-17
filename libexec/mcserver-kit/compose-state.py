#!/usr/bin/env python3
"""Classify Docker Compose's JSON container listing for the CLI and TUI."""

import json
import sys


def classify(raw: str) -> str:
    raw = raw.strip()
    if not raw:
        return "absent"

    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        try:
            parsed = [json.loads(line) for line in raw.splitlines()]
        except json.JSONDecodeError:
            return "unavailable"

    if isinstance(parsed, dict):
        containers = [parsed]
    elif isinstance(parsed, list) and all(isinstance(item, dict) for item in parsed):
        containers = parsed
    else:
        return "unavailable"

    if any(
        item.get("Service") == "minecraft"
        and str(item.get("State", "")).lower() == "running"
        for item in containers
    ):
        return "running"
    return "stopped" if containers else "absent"


if __name__ == "__main__":
    print(classify(sys.stdin.read()))
