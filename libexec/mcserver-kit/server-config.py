#!/usr/bin/env python3
"""Manage per-server itzg environment settings and migrate generated Compose files."""

from __future__ import annotations

import json
import os
import re
import shutil
import sys
import tempfile
from datetime import datetime
from pathlib import Path

MANAGED_DEFAULTS = {
    "MOTD": "A Minecraft Server",
    "DIFFICULTY": "easy",
    "MODE": "survival",
    "FORCE_GAMEMODE": "false",
    "HARDCORE": "false",
    "PVP": "true",
    "MAX_PLAYERS": "8",
    "ONLINE_MODE": "true",
    "ALLOW_FLIGHT": "true",
    "ENABLE_COMMAND_BLOCK": "true",
    "SPAWN_PROTECTION": "0",
    "VIEW_DISTANCE": "10",
    "SIMULATION_DISTANCE": "10",
    "PLAYER_IDLE_TIMEOUT": "0",
    "ALLOW_NETHER": "true",
    "SPAWN_ANIMALS": "true",
    "SPAWN_MONSTERS": "true",
    "SPAWN_NPCS": "true",
    "ENABLE_STATUS": "true",
    "HIDE_ONLINE_PLAYERS": "false",
    "MAX_TICK_TIME": "60000",
    "ENABLE_WHITELIST": "false",
    "ENFORCE_WHITELIST": "true",
    "WHITELIST": "",
    "EXISTING_WHITELIST_FILE": "SYNC_FILE_MERGE_LIST",
    "OPS": "",
    "EXISTING_OPS_FILE": "SYNC_FILE_MERGE_LIST",
    "RESOURCE_PACK": "",
    "RESOURCE_PACK_SHA1": "",
    "RESOURCE_PACK_ID": "",
    "RESOURCE_PACK_ENFORCE": "true",
}

PROPERTY_KEYS = {
    "MOTD": "motd",
    "DIFFICULTY": "difficulty",
    "MODE": "gamemode",
    "FORCE_GAMEMODE": "force-gamemode",
    "HARDCORE": "hardcore",
    "PVP": "pvp",
    "MAX_PLAYERS": "max-players",
    "ONLINE_MODE": "online-mode",
    "ALLOW_FLIGHT": "allow-flight",
    "ENABLE_COMMAND_BLOCK": "enable-command-block",
    "SPAWN_PROTECTION": "spawn-protection",
    "VIEW_DISTANCE": "view-distance",
    "SIMULATION_DISTANCE": "simulation-distance",
    "PLAYER_IDLE_TIMEOUT": "player-idle-timeout",
    "ALLOW_NETHER": "allow-nether",
    "SPAWN_ANIMALS": "spawn-animals",
    "SPAWN_MONSTERS": "spawn-monsters",
    "SPAWN_NPCS": "spawn-npcs",
    "ENABLE_STATUS": "enable-status",
    "HIDE_ONLINE_PLAYERS": "hide-online-players",
    "MAX_TICK_TIME": "max-tick-time",
    "ENABLE_WHITELIST": "white-list",
    "ENFORCE_WHITELIST": "enforce-whitelist",
    "RESOURCE_PACK": "resource-pack",
    "RESOURCE_PACK_SHA1": "resource-pack-sha1",
    "RESOURCE_PACK_ID": "resource-pack-id",
    "RESOURCE_PACK_ENFORCE": "require-resource-pack",
}


def decode(value: str) -> str:
    value = value.strip()
    if value.startswith('"') and value.endswith('"'):
        return str(json.loads(value))
    if value.startswith("'") and value.endswith("'"):
        return value[1:-1]
    return value


def read_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.is_file():
        return values
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line)
        if match:
            values[match.group(1)] = decode(match.group(2))
    return values


def write_env(path: Path, values: dict[str, str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    contents = "".join(
        f"{key}={json.dumps(value, ensure_ascii=False)}\n" for key, value in values.items()
    )
    atomic_write(path, contents, 0o600)


def read_properties(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.is_file():
        return values
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith(("#", "!")) or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value
    return values


def set_property(path: Path, env_key: str, value: str) -> None:
    property_key = PROPERTY_KEYS[env_key]
    if "\n" in value or "\r" in value:
        raise ValueError("Property values cannot contain newlines")
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    replacement = f"{property_key}={value}\n"
    indices = [
        index for index, line in enumerate(lines)
        if line.partition("=")[0].strip() == property_key
    ]
    if indices:
        lines[indices[-1]] = replacement
    else:
        if lines and not lines[-1].endswith("\n"):
            lines[-1] += "\n"
        lines.append(replacement)
    atomic_write(path, "".join(lines))


def validate_properties_source(source: Path) -> None:
    if not source.is_file():
        raise ValueError(f"Not a file: {source}")
    if source.name != "server.properties":
        raise ValueError("Select a file named server.properties")
    if not parse_import_properties(source):
        raise ValueError("The selected file has no property entries")


def unescape_import_property(value: str, number: int) -> str:
    """Decode Java Properties escapes before passing values to itzg."""
    result: list[str] = []
    index = 0
    escapes = {"t": "\t", "r": "\r", "n": "\n", "f": "\f"}
    while index < len(value):
        char = value[index]
        if char != "\\":
            result.append(char)
        else:
            index += 1
            if index == len(value):
                raise ValueError(f"Line {number}: trailing property escape")
            char = value[index]
            if char == "u":
                digits = value[index + 1:index + 5]
                if not re.fullmatch(r"[0-9a-fA-F]{4}", digits):
                    raise ValueError(f"Line {number}: malformed Unicode escape")
                result.append(chr(int(digits, 16)))
                index += 4
            else:
                # Java Properties removes the slash for non-special escapes too.
                result.append(escapes.get(char, char))
        index += 1
    try:
        decoded = "".join(result).encode("utf-16", "surrogatepass").decode("utf-16")
    except UnicodeError as error:
        raise ValueError(f"Line {number}: malformed Unicode escape") from error
    if any(ord(char) < 32 for char in decoded):
        raise ValueError(f"Line {number}: control characters cannot be imported")
    return decoded


def parse_import_properties(source: Path) -> dict[str, str]:
    """Parse Java Properties syntax without silently dropping server settings."""
    values: dict[str, str] = {}
    pending: str | None = None
    start = 0
    for number, raw in enumerate(source.read_text(encoding="utf-8-sig").splitlines(), 1):
        if pending is None:
            line = raw.lstrip(" \t\f")
            if not line or line.startswith(("#", "!")):
                continue
            start = number
        else:
            line = pending + raw.lstrip(" \t\f")
        if (len(line) - len(line.rstrip("\\"))) % 2:
            pending = line[:-1]
            continue
        pending = None
        separator = 0
        while separator < len(line):
            if line[separator] == "\\":
                separator += 2
            elif line[separator] in "=: \t\f":
                break
            else:
                separator += 1
        key = unescape_import_property(line[:separator], start)
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", key):
            raise ValueError(f"Line {start}: unsupported property key: {key}")
        remainder = line[separator:].lstrip(" \t\f")
        if remainder.startswith(("=", ":")):
            remainder = remainder[1:]
        values[key] = unescape_import_property(remainder.lstrip(" \t\f"), start)
    if pending is not None:
        raise ValueError(f"Line {start}: unfinished property continuation")
    if values.get("server-port", "25565") != "25565":
        raise ValueError("server-port must be 25565 for this server layout")
    return values


def import_properties(server_dir: Path, source: Path) -> Path | None:
    validate_properties_source(source)
    imported = parse_import_properties(source)
    env_path = server_dir / "server.env"
    values = read_env(env_path)
    for env_key, property_key in PROPERTY_KEYS.items():
        if property_key in imported:
            values[env_key] = imported[property_key]
    # create-server.sh stores the selected save at data/world; Compose sets LEVEL=world.
    known = set(PROPERTY_KEYS.values()) | {"level-name", "server-port"}
    extras = [f"{key}={value}" for key, value in imported.items() if key not in known]
    values["CUSTOM_SERVER_PROPERTIES"] = "\n".join(extras)
    values["OVERRIDE_SERVER_PROPERTIES"] = "true"

    destination = server_dir / "data" / "server.properties"
    destination.parent.mkdir(parents=True, exist_ok=True)
    if source.resolve() == destination.resolve():
        raise ValueError("The source is already this server's server.properties")
    backup = None
    if destination.exists():
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        backup = destination.with_name(f"server.properties.mcserver-kit.{stamp}.bak")
        suffix = 1
        while backup.exists():
            backup = destination.with_name(f"server.properties.mcserver-kit.{stamp}.{suffix}.bak")
            suffix += 1
        shutil.copy2(destination, backup)

    descriptor, temporary_name = tempfile.mkstemp(prefix="server.properties.", dir=destination.parent)
    try:
        with os.fdopen(descriptor, "wb") as output, source.open("rb") as input_file:
            shutil.copyfileobj(input_file, output)
        os.chmod(temporary_name, 0o644)
        write_env(env_path, values)
        os.replace(temporary_name, destination)
    finally:
        if os.path.exists(temporary_name):
            os.unlink(temporary_name)

    return backup


def compose_environment(path: Path, dotenv: dict[str, str]) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.is_file():
        return values
    in_minecraft = False
    for line in path.read_text(encoding="utf-8").splitlines():
        if line == "  minecraft:":
            in_minecraft = True
            continue
        if in_minecraft and re.match(r"^  [A-Za-z0-9_-]+:", line):
            break
        if not in_minecraft:
            continue
        match = re.match(r"^      ([A-Z][A-Z0-9_]*):\s*(.*?)\s*$", line)
        if not match:
            continue
        value = decode(match.group(2))
        variable = re.fullmatch(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", value)
        values[match.group(1)] = dotenv.get(variable.group(1), "") if variable else value
    return values


def atomic_write(path: Path, contents: str, mode: int | None = None) -> None:
    descriptor, temporary_name = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as file:
            file.write(contents)
        os.chmod(temporary_name, mode if mode is not None else path.stat().st_mode & 0o777)
        os.replace(temporary_name, path)
    finally:
        if os.path.exists(temporary_name):
            os.unlink(temporary_name)


def migrate_compose(path: Path) -> None:
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    managed = set(MANAGED_DEFAULTS)
    output: list[str] = []
    in_minecraft = False
    env_file_found = False
    inserted = False
    for line in lines:
        if line == "  minecraft:\n":
            in_minecraft = True
            output.append(line)
            continue
        if in_minecraft and re.match(r"^  [A-Za-z0-9_-]+:", line):
            if not inserted and not env_file_found:
                output.extend(["    env_file:\n", "      - server.env\n"])
            in_minecraft = False
        if in_minecraft and line == "    env_file:\n":
            env_file_found = True
        if in_minecraft and re.match(r"^      - ['\"]?server\.env['\"]?\s*$", line.rstrip("\n")):
            inserted = True
        match = re.match(r"^      ([A-Z][A-Z0-9_]*):", line) if in_minecraft else None
        if match and match.group(1) in managed:
            continue
        output.append(line)
    if in_minecraft and not inserted and not env_file_found:
        output.extend(["    env_file:\n", "      - server.env\n"])
    elif env_file_found and not inserted:
        # Generated files place env_file before the next four-space service key.
        for index, line in enumerate(output):
            if line == "    env_file:\n":
                output.insert(index + 1, "      - server.env\n")
                break
    atomic_write(path, "".join(output))


def migrate(server_dir: Path) -> None:
    compose = server_dir / "compose.yaml"
    target = server_dir / "server.env"
    dotenv = read_env(server_dir / ".env")
    existing = read_env(target)
    compose_values = compose_environment(compose, dotenv)
    properties = read_properties(server_dir / "data" / "server.properties")
    backup = server_dir / "compose.yaml.mcserver-kit.bak"
    if not target.exists() and not backup.exists():
        shutil.copy2(compose, backup)
    values: dict[str, str] = dict(existing)
    for env_key, default in MANAGED_DEFAULTS.items():
        property_key = PROPERTY_KEYS.get(env_key, "")
        values[env_key] = existing.get(
            env_key,
            compose_values.get(env_key, properties.get(property_key, default)),
        )
    values["MOTD"] = existing.get("MOTD", dotenv.get("MC_MOTD", values["MOTD"]))
    values["WHITELIST"] = existing.get("WHITELIST", dotenv.get("MC_WHITELIST", values["WHITELIST"]))
    values["OPS"] = existing.get("OPS", dotenv.get("MC_OPS", values["OPS"]))
    if "ENABLE_WHITELIST" not in existing and "ENABLE_WHITELIST" not in compose_values:
        if values["WHITELIST"] or "WHITELIST" in compose_values:
            values["ENABLE_WHITELIST"] = "true"
    write_env(target, values)
    migrate_compose(compose)


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: server-config.py get|set|migrate|property-get|property-set|import-properties TARGET [KEY] [VALUE]", file=sys.stderr)
        return 2
    operation = sys.argv[1]
    target = Path(sys.argv[2])
    if operation == "migrate" and len(sys.argv) == 3:
        migrate(target)
        return 0
    if operation == "validate-properties" and len(sys.argv) == 3:
        try:
            validate_properties_source(target)
        except (OSError, ValueError, UnicodeError) as error:
            print(f"Invalid server.properties: {error}", file=sys.stderr)
            return 1
        return 0
    if operation == "import-properties" and len(sys.argv) == 4:
        try:
            backup = import_properties(target, Path(sys.argv[3]))
        except (OSError, ValueError, UnicodeError) as error:
            print(f"Import failed: {error}", file=sys.stderr)
            return 1
        if backup:
            print(backup)
        return 0
    if operation == "property-get" and len(sys.argv) in (4, 5):
        key = PROPERTY_KEYS.get(sys.argv[3])
        if key is None:
            return 2
        default = sys.argv[4] if len(sys.argv) == 5 else ""
        print(read_properties(target).get(key, default))
        return 0
    if operation == "property-set" and len(sys.argv) == 5:
        if sys.argv[3] not in PROPERTY_KEYS:
            return 2
        try:
            set_property(target, sys.argv[3], sys.argv[4])
        except (OSError, ValueError, UnicodeError) as error:
            print(f"Could not edit server.properties: {error}", file=sys.stderr)
            return 1
        return 0
    if operation == "get" and len(sys.argv) in (4, 5):
        values = read_env(target)
        default = sys.argv[4] if len(sys.argv) == 5 else ""
        print(values.get(sys.argv[3], default))
        return 0
    if operation == "set" and len(sys.argv) == 5:
        values = read_env(target)
        values[sys.argv[3]] = sys.argv[4]
        write_env(target, values)
        return 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
