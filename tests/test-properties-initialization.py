"""Creation settings remain authoritative across property import/UI entry points."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location(
    "server_config", Path(__file__).resolve().parents[1] / "libexec/mcserver-kit/server-config.py"
)
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)


class InitializationTests(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory()
        self.addCleanup(self.workspace.cleanup)
        self.server = Path(self.workspace.name) / "server"
        self.properties = self.server / "data/server.properties"
        self.environment = self.server / "server.env"
        self.answers = {
            "MOTD": r" 日本語 §a World\path",
            "MODE": "adventure",
            "ENABLE_WHITELIST": "false",
            "WHITELIST": "Alice",
            "OPS": "Owner",
        }

    def initialize(self):
        config.initialize_properties(
            self.server,
            "".join(f"{key}={json.dumps(value)}\n" for key, value in self.answers.items()),
        )

    def test_initial_values_and_separate_membership(self):
        self.initialize()
        values = config.parse_import_properties(self.properties)
        self.assertEqual(values["motd"], self.answers["MOTD"])
        self.assertEqual(values["gamemode"], "adventure")
        self.assertEqual(values["white-list"], "false")
        self.assertEqual(values["level-name"], "world")
        self.assertEqual(values["server-port"], "25565")
        env = config.read_env(self.environment)
        self.assertEqual(env["WHITELIST"], "Alice")
        self.assertEqual(env["OPS"], "Owner")
        self.assertEqual(env["OVERRIDE_SERVER_PROPERTIES"], "false")
        self.assertNotIn("MOTD", env)
        self.assertEqual(env["ENABLE_RCON"], "true")
        self.assertEqual(env["RCON_PASSWORD"], values["rcon.password"])
        self.assertEqual(len(values["rcon.password"]), 48)
        self.assertFalse((self.server / "backups").exists())

    def test_refuses_reinitialization(self):
        self.initialize()
        previous = self.properties.read_bytes(), self.environment.read_bytes()
        with self.assertRaises(ValueError):
            self.initialize()
        self.assertEqual(previous, (self.properties.read_bytes(), self.environment.read_bytes()))

    def test_invalid_value_does_not_create_settings(self):
        self.answers["MOTD"] = "invalid\nvalue"
        with self.assertRaises(ValueError):
            self.initialize()
        self.assertFalse(self.properties.exists())
        self.assertFalse(self.environment.exists())

    def test_import_preserves_source_and_membership(self):
        self.initialize()
        source = Path(self.workspace.name) / "server.properties"
        source.write_text("motd=Imported\nlevel-name=DistributedWorld\nmod.setting=yes\n", encoding="utf-8")
        backup = config.import_properties(self.server, source)
        self.assertTrue(backup.is_file())
        env = config.read_env(self.environment)
        self.assertEqual(env["WHITELIST"], "Alice")
        self.assertEqual(env["OPS"], "Owner")
        self.assertNotIn("MOTD", env)
        self.assertEqual(env["ENABLE_RCON"], "false")
        values = config.parse_import_properties(self.properties)
        self.assertEqual(values["motd"], "Imported")
        self.assertEqual(values["level-name"], "world")
        self.assertEqual(values["mod.setting"], "yes")

    def test_rcon_client_settings_follow_edits_and_restore(self):
        self.initialize()
        original = config.parse_import_properties(self.properties)["rcon.password"]
        backup = config.create_properties_backup(self.server)
        config.set_property_key(self.properties, "rcon.password", "changed-secret")
        self.assertEqual(config.read_env(self.environment)["RCON_PASSWORD"], "changed-secret")
        config.restore_properties_backup(self.server, backup.name)
        self.assertEqual(config.read_env(self.environment)["RCON_PASSWORD"], original)
        config.remove_property_key(self.properties, "enable-rcon")
        self.assertEqual(config.read_env(self.environment)["ENABLE_RCON"], "false")


if __name__ == "__main__":
    unittest.main()
