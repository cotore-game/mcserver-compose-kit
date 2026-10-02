"""Version-dependent Minecraft settings kept outside server.properties when needed."""

from __future__ import annotations

import json
import os
import re
import sys
import tempfile
from urllib.request import urlopen
from pathlib import Path


MOVED_RULES = {
    "PVP": ("pvp", "pvp", "minecraft:pvp"),
    "ENABLE_COMMAND_BLOCK": (
        "enable-command-block", "commandBlocksEnabled", "minecraft:command_blocks_work"
    ),
    "ALLOW_NETHER": (
        "allow-nether", "allowEnteringNetherUsingPortals",
        "minecraft:allow_entering_nether_using_portals"
    ),
    "SPAWN_MONSTERS": ("spawn-monsters", "spawnMonsters", "minecraft:spawn_monsters"),
}
REMOVED_PROPERTIES = {"SPAWN_ANIMALS": "spawn-animals", "SPAWN_NPCS": "spawn-npcs"}


def version_tuple(version: str) -> tuple[int, int, int] | None:
    match = re.fullmatch(r"(\d+)\.(\d+)(?:\.(\d+))?", version)
    if not match:
        return None
    return int(match[1]), int(match[2]), int(match[3] or 0)


def latest_release() -> str:
    manifest = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"
    with urlopen(manifest, timeout=10) as response:
        version = json.load(response)["latest"]["release"]
    if not isinstance(version, str) or version_tuple(version) is None:
        raise ValueError(f"Cannot route settings for the latest Minecraft release: {version}")
    return version


def mode(version: str, key: str) -> str:
    number = version_tuple(version)
    if key not in MOVED_RULES and key not in REMOVED_PROPERTIES:
        return "ordinary"
    if not version:
        # Existing installations without MC_VERSION keep their legacy behavior.
        return "property"
    if number is None:
        return "unknown"
    if key in REMOVED_PROPERTIES:
        return "removed" if number >= (1, 21, 2) else "property"
    if number >= (1, 21, 11):
        return "namespaced"
    if number >= (1, 21, 9):
        return "camel"
    return "property"


def rule_name(key: str, version: str) -> str:
    selected = mode(version, key)
    if selected == "namespaced":
        return MOVED_RULES[key][2]
    if selected == "camel":
        return MOVED_RULES[key][1]
    raise ValueError(f"{key} is not a game rule in Minecraft {version}")


def startup_values(commands: str) -> dict[str, str]:
    values = {}
    for line in commands.splitlines():
        match = re.fullmatch(r"/?gamerule\s+(\S+)\s+(true|false)\s*", line.strip(), re.I)
        if not match:
            continue
        for key, names in MOVED_RULES.items():
            if match[1] in names[1:]:
                values[key] = match[2].lower()
    return values


def update_startup(commands: str, changes: dict[str, str | None], version: str) -> str:
    lines = []
    affected = {name for key in changes for name in MOVED_RULES[key][1:]}
    for line in commands.splitlines():
        match = re.fullmatch(r"/?gamerule\s+(\S+)\s+(true|false)\s*", line.strip(), re.I)
        if not match or match[1] not in affected:
            lines.append(line)
    for key, value in changes.items():
        if value is not None:
            if value not in ("true", "false"):
                raise ValueError(f"{key} must be true or false")
            lines.append(f"gamerule {rule_name(key, version)} {value}")
    return "\n".join(lines)


def server_version(server_dir: Path, config) -> str:
    return config.read_env(server_dir / ".env").get("MC_VERSION", "")


def prepare_initial(version: str, properties: dict[str, str], environment: dict[str, str]) -> None:
    if version and version_tuple(version) is None:
        raise ValueError(f"Use an exact numeric Minecraft version for version-dependent settings: {version}")
    changes: dict[str, str] = {}
    for key, names in MOVED_RULES.items():
        selected = mode(version, key)
        if selected in ("camel", "namespaced") and names[0] in properties:
            changes[key] = properties.pop(names[0]).lower()
    for key, property_key in REMOVED_PROPERTIES.items():
        if mode(version, key) == "removed" and property_key in properties:
            value = properties.pop(property_key).lower()
            if value != "true":
                raise ValueError(f"{property_key} was removed in Minecraft 1.21.2; no vanilla equivalent exists")
    if changes:
        if properties.get("enable-rcon", "false").lower() != "true":
            raise ValueError("Game rules need enable-rcon=true for startup application")
        if not properties.get("rcon.password"):
            raise ValueError("Game rules need a non-empty rcon.password for startup application")
        environment["RCON_CMDS_STARTUP"] = update_startup(
            environment.get("RCON_CMDS_STARTUP", ""), changes, version
        )


def sync(server_dir: Path, config) -> bool:
    """Move obsolete keys to startup rules, preserving a properties backup."""
    version = server_version(server_dir, config)
    properties_path = server_dir / "data/server.properties"
    environment_path = server_dir / "server.env"
    properties = config.parse_import_properties(properties_path)
    changes = {}
    remove = []
    for key, names in MOVED_RULES.items():
        if mode(version, key) in ("camel", "namespaced") and names[0] in properties:
            changes[key] = properties[names[0]].lower()
            remove.append(names[0])
    for key, property_key in REMOVED_PROPERTIES.items():
        if mode(version, key) == "removed" and property_key in properties:
            if properties[property_key].lower() != "true":
                raise ValueError(f"{property_key} was removed in Minecraft 1.21.2; no vanilla equivalent exists")
            remove.append(property_key)
    if not remove:
        return False
    if changes and properties.get("enable-rcon", "false").lower() != "true":
        raise ValueError("Game rules need enable-rcon=true; enable RCON before migrating obsolete keys")
    if changes and not properties.get("rcon.password"):
        raise ValueError("Game rules need a non-empty rcon.password before migrating obsolete keys")
    environment = config.read_env(environment_path)
    if changes:
        environment["RCON_CMDS_STARTUP"] = update_startup(
            environment.get("RCON_CMDS_STARTUP", ""), changes, version
        )
    descriptor, temporary_name = tempfile.mkstemp(prefix="server.properties.", dir=properties_path.parent)
    os.close(descriptor)
    temporary = Path(temporary_name)
    previous_env = environment_path.read_bytes() if environment_path.is_file() else None
    try:
        temporary.write_bytes(properties_path.read_bytes())
        for key in remove:
            config.remove_property_key(temporary, key)
        config.create_properties_backup(server_dir, "before-version-sync")
        config.write_env(environment_path, environment)
        os.chmod(temporary, 0o644)
        os.replace(temporary, properties_path)
    except Exception:
        if previous_env is not None:
            config.atomic_write(environment_path, previous_env.decode("utf-8"), 0o600)
        raise
    finally:
        temporary.unlink(missing_ok=True)
    return True


def get(server_dir: Path, key: str, default: str, config) -> str:
    version = server_version(server_dir, config)
    selected = mode(version, key)
    if selected == "removed":
        raise ValueError(f"{REMOVED_PROPERTIES[key]} was removed in Minecraft 1.21.2")
    if selected == "unknown":
        raise ValueError(f"Cannot route {key}: use an exact Minecraft version, not {version or 'an empty version'}")
    properties = config.parse_import_properties(server_dir / "data/server.properties")
    property_key = (MOVED_RULES.get(key) or (REMOVED_PROPERTIES.get(key),))[0]
    if selected == "property":
        return properties.get(property_key, default)
    environment = config.read_env(server_dir / "server.env")
    return startup_values(environment.get("RCON_CMDS_STARTUP", "")).get(
        key, properties.get(property_key, default)
    )


def set_rule(server_dir: Path, key: str, value: str, config) -> None:
    version = server_version(server_dir, config)
    selected = mode(version, key)
    if selected not in ("camel", "namespaced"):
        raise ValueError(f"{key} is not a game rule in Minecraft {version}")
    if value.lower() not in ("true", "false"):
        raise ValueError(f"{key} must be true or false")
    properties = config.parse_import_properties(server_dir / "data/server.properties")
    if properties.get("enable-rcon", "false").lower() != "true":
        raise ValueError("Enable RCON in server.properties before editing game rules")
    if not properties.get("rcon.password"):
        raise ValueError("Set rcon.password in server.properties before editing game rules")
    sync(server_dir, config)
    path = server_dir / "server.env"
    values = config.read_env(path)
    values["RCON_CMDS_STARTUP"] = update_startup(
        values.get("RCON_CMDS_STARTUP", ""), {key: value.lower()}, version
    )
    config.write_env(path, values)


def remove_rule(server_dir: Path, key: str, config) -> bool:
    version = server_version(server_dir, config)
    if mode(version, key) not in ("camel", "namespaced"):
        raise ValueError(f"{key} is not a game rule in Minecraft {version}")
    sync(server_dir, config)
    path = server_dir / "server.env"
    values = config.read_env(path)
    current = startup_values(values.get("RCON_CMDS_STARTUP", ""))
    if key not in current:
        return False
    values["RCON_CMDS_STARTUP"] = update_startup(
        values.get("RCON_CMDS_STARTUP", ""), {key: None}, version
    )
    config.write_env(path, values)
    return True


def main() -> int:
    import importlib.util

    if len(sys.argv) < 3:
        print("usage: versioned_settings.py OPERATION SERVER_DIR [KEY [VALUE]]", file=sys.stderr)
        return 2
    spec = importlib.util.spec_from_file_location(
        "server_config_for_versioned_settings", Path(__file__).with_name("server-config.py")
    )
    config = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(config)
    operation, server_dir = sys.argv[1], Path(sys.argv[2])
    try:
        if operation == "latest" and len(sys.argv) == 3:
            print(latest_release())
        elif operation == "classify" and len(sys.argv) == 4:
            print(mode(server_version(server_dir, config), sys.argv[3]))
        elif operation == "sync" and len(sys.argv) == 3:
            if sync(server_dir, config):
                print("Obsolete server.properties keys were migrated to version-specific startup game rules. A backup was saved.")
        elif operation == "get" and len(sys.argv) in (4, 5):
            print(get(server_dir, sys.argv[3], sys.argv[4] if len(sys.argv) == 5 else "", config))
        elif operation == "set" and len(sys.argv) == 5:
            set_rule(server_dir, sys.argv[3], sys.argv[4], config)
        elif operation == "remove" and len(sys.argv) == 4:
            return 0 if remove_rule(server_dir, sys.argv[3], config) else 3
        else:
            return 2
    except (OSError, ValueError, UnicodeError, KeyError, TypeError) as error:
        print(f"Versioned setting failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
