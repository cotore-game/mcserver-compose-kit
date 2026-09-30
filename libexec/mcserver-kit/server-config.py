#!/usr/bin/env python3
"""Manage container settings and Minecraft server.properties files."""

from __future__ import annotations

import json
import os
import re
import secrets
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


def parse_env(contents: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in contents.splitlines():
        match = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line)
        if match:
            values[match.group(1)] = decode(match.group(2))
    return values


def read_env(path: Path) -> dict[str, str]:
    return parse_env(path.read_text(encoding="utf-8")) if path.is_file() else {}


def initialize_properties(server_dir: Path, contents: str) -> None:
    """Split creation answers into Minecraft properties and container settings."""
    properties = server_dir / "data" / "server.properties"
    environment = server_dir / "server.env"
    if properties.exists() or environment.exists():
        raise ValueError("Refusing to overwrite existing server settings")
    values = parse_env(contents)
    entries = {
        PROPERTY_KEYS[key]: value for key, value in values.items() if key in PROPERTY_KEYS
    }
    entries.update({
        "level-name": "world", "server-port": "25565",
        "enable-rcon": "true", "rcon.port": "25575",
        "rcon.password": secrets.token_hex(24),
    })
    rendered = "#Minecraft server properties\n" + "".join(
        f"{key}={escape_property_value(value)}\n" for key, value in entries.items()
    )
    retained = {key: value for key, value in values.items() if key not in PROPERTY_KEYS}
    retained["OVERRIDE_SERVER_PROPERTIES"] = "false"
    retained.update(rcon_environment(entries))
    properties.parent.mkdir(parents=True, exist_ok=True)
    atomic_write(properties, rendered, 0o644)
    write_env(environment, retained)


def rcon_environment(properties: dict[str, str]) -> dict[str, str]:
    """Derived client settings: Minecraft properties remain authoritative."""
    return {
        "ENABLE_RCON": properties.get("enable-rcon", "false"),
        "RCON_PORT": properties.get("rcon.port", "25575"),
        "RCON_PASSWORD": properties.get("rcon.password", ""),
    }


def sync_rcon_environment(properties_path: Path) -> None:
    environment = properties_path.parent.parent / "server.env"
    values = read_env(environment)
    if values.get("OVERRIDE_SERVER_PROPERTIES", "true").lower() == "false":
        values.update(rcon_environment(parse_import_properties(properties_path)))
        write_env(environment, values)


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


def validate_property_key(key: str) -> None:
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", key):
        raise ValueError(f"Unsupported property key: {key}")


def property_line_key(line: str) -> str | None:
    stripped = line.lstrip(" \t\f")
    if not stripped or stripped.startswith(("#", "!")):
        return None
    separator = 0
    while separator < len(stripped):
        if stripped[separator] == "\\":
            separator += 2
        elif stripped[separator] in "=: \t\f\r\n":
            break
        else:
            separator += 1
    try:
        return unescape_import_property(stripped[:separator], 0)
    except ValueError:
        return None


def property_spans(lines: list[str]) -> list[tuple[int, int, str]]:
    spans: list[tuple[int, int, str]] = []
    index = 0
    while index < len(lines):
        start = index
        logical = lines[index].rstrip("\r\n")
        while (len(logical) - len(logical.rstrip("\\"))) % 2 and index + 1 < len(lines):
            logical = logical[:-1] + lines[index + 1].lstrip(" \t\f").rstrip("\r\n")
            index += 1
        key = property_line_key(logical)
        if key is not None:
            spans.append((start, index + 1, key))
        index += 1
    return spans


def escape_property_value(value: str) -> str:
    if "\n" in value or "\r" in value:
        raise ValueError("Property values cannot contain newlines")
    value = value.replace("\\", "\\\\").replace("\t", "\\t").replace("\f", "\\f")
    if value.startswith(" "):
        value = "\\" + value
    return value


def set_property_key(path: Path, property_key: str, value: str) -> None:
    validate_property_key(property_key)
    if property_key == "server-port" and value != "25565":
        raise ValueError("server-port must be 25565 for this server layout")
    if property_key == "level-name" and value != "world":
        raise ValueError("level-name must be world for this server layout")
    if "\n" in value or "\r" in value:
        raise ValueError("Property values cannot contain newlines")
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    replacement = f"{property_key}={escape_property_value(value)}\n"
    spans = [span for span in property_spans(lines) if span[2] == property_key]
    if spans:
        start, end, _ = spans[-1]
        lines[start:end] = [replacement]
    else:
        if lines and not lines[-1].endswith("\n"):
            lines[-1] += "\n"
        lines.append(replacement)
    atomic_write(path, "".join(lines))
    if path.name == "server.properties":
        sync_rcon_environment(path)


def remove_property_key(path: Path, property_key: str) -> bool:
    validate_property_key(property_key)
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    spans = [span for span in property_spans(lines) if span[2] == property_key]
    if not spans:
        return False
    for start, end, _ in reversed(spans):
        del lines[start:end]
    atomic_write(path, "".join(lines))
    if path.name == "server.properties":
        sync_rcon_environment(path)
    return True


def backup_directory(server_dir: Path) -> Path:
    return server_dir / "backups" / "server-properties"


def create_properties_backup(server_dir: Path, reason: str = "manual") -> Path:
    source = server_dir / "data" / "server.properties"
    if not source.is_file():
        raise ValueError("server.properties does not exist")
    destination_dir = backup_directory(server_dir)
    destination_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    destination = destination_dir / f"{stamp}-{reason}.properties"
    shutil.copy2(source, destination)
    destination.chmod(0o600)
    return destination


def list_properties_backups(server_dir: Path) -> list[Path]:
    directory = backup_directory(server_dir)
    if not directory.is_dir():
        return []
    return sorted(directory.glob("*.properties"), reverse=True)


def resolve_properties_backup(server_dir: Path, backup_id: str) -> Path:
    if Path(backup_id).name != backup_id or not re.fullmatch(r"[A-Za-z0-9_.-]+", backup_id):
        raise ValueError("Invalid backup ID")
    candidate = backup_directory(server_dir) / backup_id
    if not candidate.is_file() or candidate.is_symlink():
        raise ValueError(f"Backup not found: {backup_id}")
    return candidate


def restore_properties_backup(server_dir: Path, backup_id: str) -> Path:
    source = resolve_properties_backup(server_dir, backup_id)
    validate_properties_source(source, require_name=False)
    previous = create_properties_backup(server_dir, "before-restore")
    destination = server_dir / "data" / "server.properties"
    descriptor, temporary_name = tempfile.mkstemp(prefix="server.properties.", dir=destination.parent)
    try:
        with os.fdopen(descriptor, "wb") as output, source.open("rb") as input_file:
            shutil.copyfileobj(input_file, output)
        os.chmod(temporary_name, 0o644)
        os.replace(temporary_name, destination)
        sync_rcon_environment(destination)
    finally:
        if os.path.exists(temporary_name):
            os.unlink(temporary_name)
    return previous


def validate_properties_source(source: Path, require_name: bool = True) -> None:
    if not source.is_file():
        raise ValueError(f"Not a file: {source}")
    if require_name and source.name != "server.properties":
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
    destination = server_dir / "data" / "server.properties"
    destination.parent.mkdir(parents=True, exist_ok=True)
    if source.resolve() == destination.resolve():
        raise ValueError("The source is already this server's server.properties")

    if values.get("OVERRIDE_SERVER_PROPERTIES", "true").lower() == "false":
        backup = create_properties_backup(server_dir, "before-import") if destination.exists() else None
        descriptor, temporary_name = tempfile.mkstemp(prefix="server.properties.", dir=destination.parent)
        try:
            with os.fdopen(descriptor, "wb") as output, source.open("rb") as input_file:
                shutil.copyfileobj(input_file, output)
            # The managed world is always mounted at data/world.
            set_property_key(Path(temporary_name), "level-name", "world")
            set_property_key(Path(temporary_name), "server-port", "25565")
            os.chmod(temporary_name, 0o644)
            os.replace(temporary_name, destination)
            sync_rcon_environment(destination)
        finally:
            if os.path.exists(temporary_name):
                os.unlink(temporary_name)
        return backup

    for env_key, property_key in PROPERTY_KEYS.items():
        if property_key in imported:
            values[env_key] = imported[property_key]
    # create-server.sh stores the selected save at data/world; Compose sets LEVEL=world.
    known = set(PROPERTY_KEYS.values()) | {"level-name", "server-port"}
    extras = [f"{key}={value}" for key, value in imported.items() if key not in known]
    values["CUSTOM_SERVER_PROPERTIES"] = "\n".join(extras)
    values["OVERRIDE_SERVER_PROPERTIES"] = "true"

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


def migrate_compose_to_properties(path: Path) -> None:
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    property_variables = set(PROPERTY_KEYS) | {
        "CUSTOM_SERVER_PROPERTIES",
        "OVERRIDE_SERVER_PROPERTIES",
        "LEVEL",
    }
    output: list[str] = []
    in_minecraft = False
    for line in lines:
        if line == "  minecraft:\n":
            in_minecraft = True
            output.append(line)
            continue
        if in_minecraft and re.match(r"^  [A-Za-z0-9_-]+:", line):
            in_minecraft = False
        match = re.match(r"^      ([A-Z][A-Z0-9_]*):", line) if in_minecraft else None
        if match and match.group(1) in property_variables:
            continue
        output.append(line)
    atomic_write(path, "".join(output))


def migration_backup_directory(server_dir: Path) -> Path:
    root = server_dir / "backups" / "source-migrations"
    root.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    destination = root / stamp
    destination.mkdir(mode=0o700)
    return destination


def migrate_to_properties(server_dir: Path) -> Path:
    compose = server_dir / "compose.yaml"
    properties_path = server_dir / "data" / "server.properties"
    env_path = server_dir / "server.env"
    if not compose.is_file():
        raise ValueError("compose.yaml does not exist")

    backup = migration_backup_directory(server_dir)
    for source in (compose, env_path, properties_path):
        if source.is_file():
            shutil.copy2(source, backup / source.name)

    dotenv = read_env(server_dir / ".env")
    compose_values = compose_environment(compose, dotenv)
    env_values = read_env(env_path)
    if properties_path.is_file():
        # Parse before changing anything so malformed files fail transactionally.
        parse_import_properties(properties_path)

    custom = env_values.get("CUSTOM_SERVER_PROPERTIES", "")
    custom_values: list[tuple[str, str]] = []
    for number, line in enumerate(custom.splitlines(), 1):
        if not line.strip():
            continue
        if "=" not in line:
            raise ValueError(f"Invalid CUSTOM_SERVER_PROPERTIES line {number}")
        key, value = line.split("=", 1)
        validate_property_key(key.strip())
        custom_values.append((key.strip(), value))

    retained = {
        key: value
        for key, value in env_values.items()
        if key not in PROPERTY_KEYS and key != "CUSTOM_SERVER_PROPERTIES"
    }
    for key in ("WHITELIST", "EXISTING_WHITELIST_FILE", "OPS", "EXISTING_OPS_FILE"):
        if key in compose_values and key not in retained:
            retained[key] = compose_values[key]
    retained["OVERRIDE_SERVER_PROPERTIES"] = "false"

    properties_path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix="server.properties.", dir=properties_path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as output:
            if properties_path.is_file():
                with properties_path.open("rb") as input_file:
                    shutil.copyfileobj(input_file, output)
            else:
                output.write(b"#Minecraft server properties\n")
        for key, value in custom_values:
            set_property_key(temporary, key, value)
        for env_key, property_key in PROPERTY_KEYS.items():
            value = env_values.get(env_key, compose_values.get(env_key))
            if env_key == "MOTD":
                value = env_values.get(env_key, dotenv.get("MC_MOTD", value))
            if value is not None:
                set_property_key(temporary, property_key, value)
        # mcserver-kit stores imported worlds at data/world.
        set_property_key(temporary, "level-name", "world")
        set_property_key(temporary, "server-port", "25565")
        temporary.chmod(0o644)

        try:
            write_env(env_path, retained)
            migrate_compose_to_properties(compose)
            os.replace(temporary, properties_path)
        except Exception:
            for original in (compose, env_path):
                saved = backup / original.name
                if saved.is_file():
                    shutil.copy2(saved, original)
                elif original.exists():
                    original.unlink()
            raise
    finally:
        if temporary.exists():
            temporary.unlink()
    return backup


def migrate(server_dir: Path) -> None:
    compose = server_dir / "compose.yaml"
    target = server_dir / "server.env"
    dotenv = read_env(server_dir / ".env")
    existing = read_env(target)
    # Legacy UI/import entry points must not recreate property overrides.
    if existing.get("OVERRIDE_SERVER_PROPERTIES", "true").lower() == "false":
        return
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
        print("usage: server-config.py OPERATION TARGET [ARG...]", file=sys.stderr)
        return 2
    operation = sys.argv[1]
    target = Path(sys.argv[2])
    if operation == "initialize-properties" and len(sys.argv) == 3:
        try:
            initialize_properties(target, sys.stdin.read())
        except (OSError, ValueError, UnicodeError) as error:
            print(f"Could not initialize server properties: {error}", file=sys.stderr)
            return 1
        return 0
    if operation == "migrate" and len(sys.argv) == 3:
        migrate(target)
        return 0
    if operation == "migrate-to-properties" and len(sys.argv) == 3:
        try:
            print(migrate_to_properties(target))
        except (OSError, ValueError, UnicodeError) as error:
            print(f"Migration failed: {error}", file=sys.stderr)
            return 1
        return 0
    if operation == "source-mode" and len(sys.argv) == 3:
        override = read_env(target / "server.env").get("OVERRIDE_SERVER_PROPERTIES", "true")
        print("properties" if override.lower() == "false" else "environment")
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
        print(parse_import_properties(target).get(key, default))
        return 0
    if operation == "property-key" and len(sys.argv) == 3:
        key = PROPERTY_KEYS.get(str(target))
        if key is None:
            return 2
        print(key)
        return 0
    if operation == "property-list" and len(sys.argv) == 3:
        try:
            for key, value in parse_import_properties(target).items():
                print(f"{key}={value}")
        except (OSError, ValueError, UnicodeError) as error:
            print(f"Could not read server.properties: {error}", file=sys.stderr)
            return 1
        return 0
    if operation == "property-key-get" and len(sys.argv) in (4, 5):
        try:
            validate_property_key(sys.argv[3])
            default = sys.argv[4] if len(sys.argv) == 5 else ""
            print(parse_import_properties(target).get(sys.argv[3], default))
        except (OSError, ValueError, UnicodeError) as error:
            print(f"Could not read server.properties: {error}", file=sys.stderr)
            return 1
        return 0
    if operation == "property-key-set" and len(sys.argv) == 5:
        try:
            set_property_key(target, sys.argv[3], sys.argv[4])
        except (OSError, ValueError, UnicodeError) as error:
            print(f"Could not edit server.properties: {error}", file=sys.stderr)
            return 1
        return 0
    if operation == "property-key-remove" and len(sys.argv) == 4:
        try:
            return 0 if remove_property_key(target, sys.argv[3]) else 3
        except (OSError, ValueError, UnicodeError) as error:
            print(f"Could not edit server.properties: {error}", file=sys.stderr)
            return 1
    if operation == "property-backup" and len(sys.argv) == 3:
        try:
            print(create_properties_backup(target))
        except (OSError, ValueError) as error:
            print(f"Backup failed: {error}", file=sys.stderr)
            return 1
        return 0
    if operation == "property-backups" and len(sys.argv) == 3:
        for backup in list_properties_backups(target):
            print(backup.name)
        return 0
    if operation == "property-restore" and len(sys.argv) == 4:
        try:
            print(restore_properties_backup(target, sys.argv[3]))
        except (OSError, ValueError, UnicodeError) as error:
            print(f"Restore failed: {error}", file=sys.stderr)
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
