"""Version cutovers for Minecraft settings moved out of server.properties."""

import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
LIBEXEC = ROOT / "libexec/mcserver-kit"


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, LIBEXEC / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


config = load("server_config_version_test", "server-config.py")
settings = load("versioned_settings_test", "versioned_settings.py")


class VersionedSettingsTests(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory()
        self.addCleanup(self.workspace.cleanup)
        self.server = Path(self.workspace.name) / "demo"
        self.server.mkdir()
        self.properties = self.server / "data/server.properties"
        self.environment = self.server / "server.env"

    def initialize(self, version, **answers):
        config.write_env(self.server / ".env", {"MC_VERSION": version})
        values = {"PVP": "false", "ENABLE_COMMAND_BLOCK": "false",
                  "ALLOW_NETHER": "false", "SPAWN_MONSTERS": "false",
                  "SPAWN_ANIMALS": "true", "SPAWN_NPCS": "true"}
        values.update(answers)
        config.initialize_properties(
            self.server, "".join(f"{key}={json.dumps(value)}\n" for key, value in values.items())
        )
        return config.parse_import_properties(self.properties), config.read_env(self.environment)

    def test_version_boundaries(self):
        self.assertEqual(settings.mode("1.21.1", "SPAWN_ANIMALS"), "property")
        self.assertEqual(settings.mode("1.21.2", "SPAWN_ANIMALS"), "removed")
        self.assertEqual(settings.mode("1.21.8", "PVP"), "property")
        self.assertEqual(settings.mode("1.21.9", "PVP"), "camel")
        self.assertEqual(settings.mode("1.21.10", "PVP"), "camel")
        self.assertEqual(settings.mode("1.21.11", "PVP"), "namespaced")
        self.assertEqual(settings.mode("26.3", "PVP"), "namespaced")
        self.assertEqual(settings.mode("LATEST", "PVP"), "unknown")

    def test_latest_resolves_to_a_concrete_release(self):
        payload = io.BytesIO(b'{"latest":{"release":"26.3"}}')
        with patch.object(settings, "urlopen", return_value=payload):
            self.assertEqual(settings.latest_release(), "26.3")
        payload = io.BytesIO(b'{"latest":{"release":"snapshot-x"}}')
        with patch.object(settings, "urlopen", return_value=payload):
            with self.assertRaisesRegex(ValueError, "Cannot route settings"):
                settings.latest_release()

    def test_old_version_retains_properties(self):
        properties, environment = self.initialize("1.21.1")
        self.assertEqual(properties["pvp"], "false")
        self.assertEqual(properties["spawn-animals"], "true")
        self.assertNotIn("RCON_CMDS_STARTUP", environment)

    def test_camel_game_rules_and_older_removed_keys(self):
        properties, environment = self.initialize("1.21.9")
        for key in ("pvp", "enable-command-block", "allow-nether", "spawn-monsters",
                    "spawn-animals", "spawn-npcs"):
            self.assertNotIn(key, properties)
        commands = environment["RCON_CMDS_STARTUP"]
        self.assertIn("gamerule pvp false", commands)
        self.assertIn("gamerule commandBlocksEnabled false", commands)
        self.assertIn("gamerule allowEnteringNetherUsingPortals false", commands)
        self.assertIn("gamerule spawnMonsters false", commands)

    def test_26_3_namespaced_game_rules(self):
        properties, environment = self.initialize("26.3")
        self.assertNotIn("pvp", properties)
        self.assertNotIn("enable-command-block", properties)
        self.assertIn("gamerule minecraft:pvp false", environment["RCON_CMDS_STARTUP"])
        self.assertIn("gamerule minecraft:command_blocks_work false", environment["RCON_CMDS_STARTUP"])
        self.assertIn("gamerule minecraft:allow_entering_nether_using_portals false",
                      environment["RCON_CMDS_STARTUP"])
        self.assertIn("gamerule minecraft:spawn_monsters false", environment["RCON_CMDS_STARTUP"])
        self.assertEqual(settings.get(self.server, "PVP", "true", config), "false")

    def test_edit_preserves_unrelated_startup_commands(self):
        self.initialize("26.3")
        env = config.read_env(self.environment)
        env["RCON_CMDS_STARTUP"] = "say hello\n" + env["RCON_CMDS_STARTUP"]
        config.write_env(self.environment, env)
        settings.set_rule(self.server, "PVP", "true", config)
        commands = config.read_env(self.environment)["RCON_CMDS_STARTUP"]
        self.assertEqual(commands.count("minecraft:pvp"), 1)
        self.assertIn("say hello", commands)
        self.assertEqual(settings.get(self.server, "PVP", "false", config), "true")

    def test_existing_removed_keys_are_backed_up_and_migrated(self):
        self.initialize("26.3")
        config.set_property_key(self.properties, "pvp", "false")
        config.set_property_key(self.properties, "spawn-animals", "true")
        self.assertTrue(settings.sync(self.server, config))
        self.assertFalse(settings.sync(self.server, config))
        self.assertNotIn("pvp", config.parse_import_properties(self.properties))
        self.assertNotIn("spawn-animals", config.parse_import_properties(self.properties))
        backups = config.list_properties_backups(self.server)
        self.assertEqual(len(backups), 1)
        self.assertIn("pvp=false", backups[0].read_text())

    def test_import_converts_old_property_without_losing_other_commands(self):
        self.initialize("26.3")
        settings.set_rule(self.server, "PVP", "true", config)
        source = Path(self.workspace.name) / "server.properties"
        source.write_text(
            "motd=Imported\nenable-rcon=true\nrcon.password=import-test\npvp=false\n",
            encoding="utf-8"
        )
        backup = config.import_properties(self.server, source)
        self.assertTrue(backup.is_file())
        self.assertNotIn("pvp", config.parse_import_properties(self.properties))
        self.assertEqual(settings.get(self.server, "PVP", "true", config), "false")
        self.assertIn("gamerule minecraft:spawn_monsters false",
                      config.read_env(self.environment)["RCON_CMDS_STARTUP"])

    def test_import_without_rcon_rejects_before_changing_current_settings(self):
        self.initialize("26.3")
        config.set_property_key(self.properties, "enable-rcon", "false")
        source = Path(self.workspace.name) / "server.properties"
        source.write_text("motd=Other\npvp=false\n", encoding="utf-8")
        before = self.properties.read_bytes(), self.environment.read_bytes()
        with self.assertRaisesRegex(ValueError, "enable-rcon=true"):
            config.import_properties(self.server, source)
        self.assertEqual(before, (self.properties.read_bytes(), self.environment.read_bytes()))
        self.assertFalse((self.server / "backups").exists())

    def test_import_without_rcon_keeps_existing_enabled_rcon(self):
        self.initialize("26.3")
        old_password = config.parse_import_properties(self.properties)["rcon.password"]
        source = Path(self.workspace.name) / "server.properties"
        source.write_text("motd=Other\npvp=false\n", encoding="utf-8")
        config.import_properties(self.server, source)
        properties = config.parse_import_properties(self.properties)
        self.assertEqual(properties["enable-rcon"], "true")
        self.assertEqual(properties["rcon.password"], old_password)
        self.assertNotIn("pvp", properties)
        self.assertEqual(settings.get(self.server, "PVP", "true", config), "false")

    def test_backup_and_restore_include_managed_game_rules(self):
        self.initialize("26.3")
        backup = config.create_properties_backup(self.server)
        sidecar = backup.with_suffix(".properties.rules.json")
        self.assertEqual(json.loads(sidecar.read_text())["PVP"], "false")
        self.assertEqual(sidecar.stat().st_mode & 0o777, 0o600)
        settings.set_rule(self.server, "PVP", "true", config)
        self.assertEqual(settings.get(self.server, "PVP", "false", config), "true")
        config.restore_properties_backup(self.server, backup.name)
        self.assertEqual(settings.get(self.server, "PVP", "true", config), "false")

    def test_removed_animal_control_fails_without_mutation(self):
        config.write_env(self.server / ".env", {"MC_VERSION": "26.3"})
        with self.assertRaisesRegex(ValueError, "no vanilla equivalent"):
            config.initialize_properties(self.server, 'SPAWN_ANIMALS="false"\n')
        self.assertFalse(self.properties.exists())
        self.assertFalse(self.environment.exists())

    def test_rcon_disabled_refuses_game_rule_change(self):
        self.initialize("26.3")
        config.set_property_key(self.properties, "enable-rcon", "false")
        before = self.environment.read_bytes()
        with self.assertRaisesRegex(ValueError, "Enable RCON"):
            settings.set_rule(self.server, "PVP", "true", config)
        self.assertEqual(self.environment.read_bytes(), before)

    @unittest.skipUnless(shutil.which("docker"), "Docker Compose is unavailable")
    def test_compose_passes_all_startup_commands_as_lines(self):
        self.initialize("26.3")
        (self.server / "compose.yaml").write_text(
            "services:\n  minecraft:\n    image: itzg/minecraft-server:java25\n"
            "    env_file:\n      - server.env\n", encoding="utf-8"
        )
        result = subprocess.run(
            ["docker", "compose", "config", "--format", "json"], cwd=self.server,
            text=True, capture_output=True
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(result.stdout)["services"]["minecraft"]["environment"]["RCON_CMDS_STARTUP"]
        self.assertEqual(len(value.splitlines()), 4)
        self.assertIn("gamerule minecraft:command_blocks_work false", value.splitlines())


if __name__ == "__main__":
    unittest.main()
