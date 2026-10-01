"""Exercise generic TUI decisions without a terminal or a running server."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
SHARE = ROOT / "share/mcserver-kit"
spec = importlib.util.spec_from_file_location("properties_tui", ROOT / "libexec/mcserver-kit/properties-tui.py")
tui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tui)


class EditorTests(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory()
        self.addCleanup(self.workspace.cleanup)
        self.root = Path(self.workspace.name)
        self.server = self.root / "demo"
        (self.server / "data").mkdir(parents=True)
        self.properties = self.server / "data/server.properties"
        self.properties.write_text("# keep\nmotd=Hello\nmod.example=value\n", encoding="utf-8")
        self.editor = tui.Editor("demo", self.server, SHARE, "en")
        self.editor.dialog = Mock()

    def test_catalog_keys_and_translations(self):
        for language in ("en", "ja"):
            messages = tui.load_messages(SHARE, language)
            for key, metadata in self.editor.catalog.items():
                tui.config.validate_property_key(key)
                self.assertIn(metadata["description"], messages)

    def test_missing_translation_falls_back_to_english(self):
        (self.root / "locales").mkdir()
        english = {"a": "English A", "b": "English B"}
        (self.root / "locales/en.json").write_text(json.dumps(english))
        (self.root / "locales/xx.json").write_text('{"a": "Translated"}')
        self.assertEqual(tui.load_messages(self.root, "xx"), {"a": "Translated", "b": "English B"})
        self.assertEqual(tui.load_messages(self.root, "../xx"), english)

    def test_lists_unknown_keys_and_cancel_does_not_write(self):
        before = self.properties.read_bytes()
        self.editor.dialog.return_value = None
        self.assertFalse(self.editor.run())
        self.assertIn("mod.example", self.editor.dialog.call_args.args)
        self.assertEqual(before, self.properties.read_bytes())
        self.assertFalse((self.server / "backups").exists())

    def test_edit_uses_original_key(self):
        self.editor.dialog.side_effect = ["edit", "日本語 text"]
        self.editor.mutate = Mock()
        self.editor.edit("mod.example", "value")
        self.editor.mutate.assert_called_once_with("set", "mod.example", "日本語 text")

    def test_cancel_and_unchanged_value_do_not_save(self):
        for responses in ([None], ["edit", None], ["edit", "value"]):
            self.editor.dialog.side_effect = responses
            self.editor.mutate = Mock()
            self.editor.edit("mod.example", "value")
            self.editor.mutate.assert_not_called()

    def test_remove_requires_confirmation(self):
        for confirmation in (None, ""):
            self.editor.dialog.side_effect = ["remove", confirmation]
            self.editor.mutate = Mock()
            self.editor.edit("mod.example", "value")
            if confirmation is None:
                self.editor.mutate.assert_not_called()
            else:
                self.editor.mutate.assert_called_once_with("remove", "mod.example")

    def test_add_custom_key_and_empty_value(self):
        self.editor.dialog.side_effect = ["@custom", "mod.new", ""]
        self.editor.mutate = Mock()
        self.editor.add(self.editor.values())
        self.editor.mutate.assert_called_once_with("set", "mod.new", "")

    def test_add_existing_key_does_not_overwrite(self):
        self.editor.dialog.side_effect = ["@custom", "motd", ""]
        self.editor.mutate = Mock()
        self.editor.add(self.editor.values())
        self.editor.mutate.assert_not_called()

    def test_secret_not_in_dialog_arguments(self):
        self.editor.dialog.side_effect = ["edit", "new-secret", ""]
        self.editor.mutate = Mock()
        self.editor.edit("rcon.password", "existing-secret")
        for call in self.editor.dialog.call_args_list:
            self.assertNotIn("existing-secret", str(call))
        self.assertEqual(self.editor.dialog.call_args_list[1].args[0], "passwordbox")
        self.editor.mutate.assert_called_once_with("set", "rcon.password", "new-secret")

    def test_cli_error_is_visible_and_not_success(self):
        with patch.object(tui.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "Docker unavailable")):
            self.assertFalse(self.editor.mutate("set", "motd", "test"))
        self.editor.dialog.assert_called_once_with("msgbox", "Docker unavailable")
        self.assertFalse(self.editor.changed)

    def test_whiptail_selection_and_cancel_status(self):
        editor = tui.Editor("demo", self.server, SHARE, "en")
        with patch.object(tui.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "motd")) as run:
            self.assertEqual(editor.dialog("menu", "Choose", "motd", "Message"), "motd")
            self.assertIn("--output-fd", run.call_args.args[0])
        with patch.object(tui.subprocess, "run", return_value=subprocess.CompletedProcess([], 255, "")):
            self.assertIsNone(editor.dialog("menu", "Choose"))

    def test_session_selection_uses_persistent_renderer(self):
        editor = tui.Editor("demo", self.server, SHARE, "ja")
        result = subprocess.CompletedProcess([], 0, "", "motd")
        with patch.dict(os.environ, {"MCSERVER_KIT_TUI_SOCKET": "/tmp/test-socket"}):
            with patch.object(tui.subprocess, "run", return_value=result) as run:
                self.assertEqual(editor.dialog("menu", "Choose", "motd", "Message"), "motd")
        command = run.call_args.args[0]
        self.assertEqual(command[1:3], [str(tui.HERE / "tui-session.py"), "client"])
        self.assertNotIn("--output-fd", command)

    def test_actual_cli_backup_and_running_refusal(self):
        (self.server / "compose.yaml").write_text("services: {}\n")
        (self.server / "server.env").write_text("OVERRIDE_SERVER_PROPERTIES=false\n")
        config_path = self.root / "config.yml"
        config_path.write_text(f"paths:\n  server_root: {self.root}\n")
        fake_bin = self.root / "bin"
        fake_bin.mkdir()
        docker = fake_bin / "docker"
        docker.write_text('#!/bin/sh\nif [ "$TUI_TEST_RUNNING" = yes ]; then echo minecraft; fi\nexit 0\n')
        docker.chmod(0o755)
        environment = {"MCSERVER_KIT_CONFIG": str(config_path), "MCSERVER_KIT_LANG": "en",
                       "PATH": f"{fake_bin}:{os.environ['PATH']}", "TUI_TEST_RUNNING": "no"}
        before = self.properties.read_bytes()
        with patch.dict(os.environ, environment):
            self.assertTrue(self.editor.mutate("set", "mod.example", "changed"))
            backups = list((self.server / "backups/server-properties").glob("*.properties"))
            self.assertEqual(len(backups), 1)
            self.assertEqual(backups[0].read_bytes(), before)
            self.assertIn("# keep", self.properties.read_text())
            os.environ["TUI_TEST_RUNNING"] = "yes"
            saved = self.properties.read_bytes()
            self.assertFalse(self.editor.mutate("remove", "mod.example"))
            self.assertEqual(self.properties.read_bytes(), saved)
            self.assertEqual(len(list((self.server / "backups/server-properties").glob("*"))), 1)
            restore = subprocess.run(
                [str(tui.HERE / "server-manager.sh"), "server", "demo",
                 "properties", "restore", backups[0].name],
                capture_output=True, text=True, check=False,
            )
            self.assertNotEqual(restore.returncode, 0)
            self.assertEqual(self.properties.read_bytes(), saved)
            self.assertEqual(len(list((self.server / "backups/server-properties").glob("*"))), 1)

    def test_shell_menu_opens_editor_and_returns_after_save(self):
        (self.server / "compose.yaml").write_text("services: {}\n")
        (self.server / "server.env").write_text("OVERRIDE_SERVER_PROPERTIES=false\n")
        config_path = self.root / "config.yml"
        config_path.write_text(f"paths:\n  server_root: {self.root}\n")
        fake_bin = self.root / "bin"
        fake_bin.mkdir()
        docker = fake_bin / "docker"
        docker.write_text("#!/bin/sh\nexit 0\n")
        docker.chmod(0o755)
        queue = self.root / "dialogs.json"
        queue.write_text(json.dumps([
            ["menu", "__all", 0], ["menu", "mod.example", 0],
            ["menu", "edit", 0], ["inputbox", "new value", 0],
            ["menu", "", 1], ["menu", "__exit", 0],
            ["yesno", "", 1], ["msgbox", "", 0],
        ]))
        whiptail = fake_bin / "whiptail"
        whiptail.write_text("""#!/usr/bin/env python3
import json, os, pathlib, sys
queue = pathlib.Path(os.environ["TUI_TEST_QUEUE"])
items = json.loads(queue.read_text())
kind, value, status = items.pop(0)
assert "--" + kind in sys.argv, (kind, sys.argv)
queue.write_text(json.dumps(items))
stream = sys.stdout if "--output-fd" in sys.argv else sys.stderr
stream.write(value)
sys.exit(status)
""")
        whiptail.chmod(0o755)
        environment = dict(os.environ, MCSERVER_KIT_CONFIG=str(config_path),
                           MCSERVER_KIT_LANG="en", TUI_TEST_QUEUE=str(queue),
                           PATH=f"{fake_bin}:{os.environ['PATH']}")
        result = subprocess.run(
            ["bash", str(ROOT / "libexec/mcserver-kit/server-properties-tui.sh"),
             "demo", str(self.server)], env=environment,
            capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(queue.read_text()), [])
        self.assertEqual(self.editor.values()["mod.example"], "new value")
        self.assertEqual(len(list((self.server / "backups/server-properties").glob("*"))), 1)

    def test_common_setting_uses_guarded_backup_path(self):
        (self.server / "compose.yaml").write_text("services: {}\n")
        (self.server / "server.env").write_text("OVERRIDE_SERVER_PROPERTIES=false\n")
        config_path = self.root / "config.yml"
        config_path.write_text(f"paths:\n  server_root: {self.root}\n")
        fake_bin = self.root / "bin"
        fake_bin.mkdir()
        docker = fake_bin / "docker"
        docker.write_text("#!/bin/sh\nexit 0\n")
        docker.chmod(0o755)
        queue = self.root / "dialogs.json"
        queue.write_text(json.dumps([
            ["menu", "MOTD", 0], ["inputbox", "Updated", 0],
            ["menu", "__exit", 0], ["yesno", "", 1], ["msgbox", "", 0],
        ]))
        whiptail = fake_bin / "whiptail"
        whiptail.write_text("""#!/usr/bin/env python3
import json, os, pathlib, sys
queue = pathlib.Path(os.environ["TUI_TEST_QUEUE"])
items = json.loads(queue.read_text())
kind, value, status = items.pop(0)
assert "--" + kind in sys.argv, (kind, sys.argv)
queue.write_text(json.dumps(items))
sys.stderr.write(value)
sys.exit(status)
""")
        whiptail.chmod(0o755)
        before = self.properties.read_bytes()
        environment = dict(os.environ, MCSERVER_KIT_CONFIG=str(config_path),
                           MCSERVER_KIT_LANG="en", TUI_TEST_QUEUE=str(queue),
                           PATH=f"{fake_bin}:{os.environ['PATH']}")
        result = subprocess.run(
            ["bash", str(ROOT / "libexec/mcserver-kit/server-properties-tui.sh"),
             "demo", str(self.server)], env=environment,
            capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(queue.read_text()), [])
        self.assertEqual(self.editor.values()["motd"], "Updated")
        backups = list((self.server / "backups/server-properties").glob("*.properties"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), before)


class SettingsWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory()
        self.addCleanup(self.workspace.cleanup)
        self.root = Path(self.workspace.name)
        self.server = self.root / "demo"
        (self.server / "data").mkdir(parents=True)
        self.properties = self.server / "data/server.properties"
        self.properties.write_text("motd=Original\nlevel-name=world\nserver-port=25565\n")
        (self.server / "compose.yaml").write_text(
            "services:\n  minecraft:\n    image: itzg/minecraft-server\n"
            "    env_file:\n      - server.env\n    volumes:\n      - ./data:/data\n"
        )
        self.config_path = self.root / "config.yml"
        self.config_path.write_text(f"paths:\n  server_root: {self.root}\n")
        self.fake_bin = self.root / "bin"
        self.fake_bin.mkdir()
        docker = self.fake_bin / "docker"
        docker.write_text(
            '#!/bin/sh\nif [ "$TUI_TEST_RUNNING" = yes ] && '
            '[ "$*" = "compose ps --status running --services" ]; then echo minecraft; fi\nexit 0\n'
        )
        docker.chmod(0o755)
        whiptail = self.fake_bin / "whiptail"
        whiptail.write_text("""#!/usr/bin/env python3
import json, os, pathlib, sys
queue = pathlib.Path(os.environ["TUI_TEST_QUEUE"])
items = json.loads(queue.read_text())
kind, value, status = items.pop(0)
assert "--" + kind in sys.argv, (kind, sys.argv)
if value == "@last":
    value = sys.argv[-2]
queue.write_text(json.dumps(items))
sys.stderr.write(value)
sys.exit(status)
""")
        whiptail.chmod(0o755)

    def run_menu(self, choices, running="no", expected_status=0):
        queue = self.root / "dialogs.json"
        queue.write_text(json.dumps(choices))
        environment = dict(os.environ, MCSERVER_KIT_CONFIG=str(self.config_path),
                           MCSERVER_KIT_LANG="en", TUI_TEST_QUEUE=str(queue),
                           TUI_TEST_RUNNING=running,
                           PATH=f"{self.fake_bin}:{os.environ['PATH']}")
        result = subprocess.run(
            ["bash", str(ROOT / "libexec/mcserver-kit/server-properties-tui.sh"),
             "demo", str(self.server)], env=environment,
            capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, expected_status, result.stderr)
        self.assertEqual(json.loads(queue.read_text()), [])

    def test_backup_and_restore_from_settings_menu(self):
        (self.server / "server.env").write_text("OVERRIDE_SERVER_PROPERTIES=false\n")
        original = self.properties.read_bytes()
        self.run_menu([
            ["menu", "__backup", 0], ["textbox", "", 0],
            ["menu", "MOTD", 0], ["inputbox", "Updated", 0],
            ["menu", "__restore", 0], ["menu", "@last", 0],
            ["yesno", "", 0], ["textbox", "", 0],
            ["menu", "__exit", 0], ["yesno", "", 1], ["msgbox", "", 0],
        ])
        self.assertEqual(self.properties.read_bytes(), original)
        backups = list((self.server / "backups/server-properties").glob("*.properties"))
        self.assertGreaterEqual(len(backups), 3)
        self.assertTrue(any("before-restore" in path.name for path in backups))

    def test_migrate_existing_server_from_settings_menu(self):
        (self.server / "server.env").write_text(
            'MOTD="Legacy"\nOVERRIDE_SERVER_PROPERTIES="true"\n'
        )
        self.run_menu([
            ["yesno", "", 0], ["textbox", "", 0], ["menu", "__exit", 0],
        ])
        self.assertEqual(tui.config.read_env(self.server / "server.env")["OVERRIDE_SERVER_PROPERTIES"], "false")
        self.assertEqual(tui.config.parse_import_properties(self.properties)["motd"], "Legacy")
        self.assertTrue(list((self.server / "backups/source-migrations").glob("*/server.properties")))
        self.assertNotIn("MOTD", tui.config.read_env(self.server / "server.env"))

    def test_cancel_migration_keeps_legacy_source(self):
        (self.server / "server.env").write_text(
            'MOTD="Legacy"\nOVERRIDE_SERVER_PROPERTIES="true"\n'
        )
        original = self.properties.read_bytes()
        self.run_menu([
            ["yesno", "", 1],
        ])
        self.assertEqual(tui.config.read_env(self.server / "server.env")["OVERRIDE_SERVER_PROPERTIES"], "true")
        self.assertEqual(self.properties.read_bytes(), original)
        self.assertFalse((self.server / "backups/source-migrations").exists())

    def test_server_without_environment_migrates_directly(self):
        self.properties.write_text(
            "motd=Original\nlevel-name=world\nserver-port=25565\n"
            "enable-rcon=true\nrcon.password=legacy-secret\n"
        )
        self.run_menu([
            ["yesno", "", 0], ["textbox", "", 0], ["menu", "__exit", 0],
        ])
        env = tui.config.read_env(self.server / "server.env")
        self.assertEqual(env["OVERRIDE_SERVER_PROPERTIES"], "false")
        self.assertEqual(env["RCON_PASSWORD"], "legacy-secret")
        self.assertNotIn("MOTD", env)
        self.assertEqual(tui.config.parse_import_properties(self.properties)["motd"], "Original")
        self.assertTrue(list((self.server / "backups/source-migrations").glob("*/compose.yaml")))

    def test_invalid_legacy_properties_abort_before_backup(self):
        self.properties.write_text("motd=Invalid\\u12G4\n")
        before = (self.server / "compose.yaml").read_bytes()
        self.run_menu([["yesno", "", 0], ["textbox", "", 0]], expected_status=1)
        self.assertEqual((self.server / "compose.yaml").read_bytes(), before)
        self.assertFalse((self.server / "server.env").exists())
        self.assertFalse((self.server / "backups/source-migrations").exists())

    def test_running_server_cannot_migrate_from_settings_menu(self):
        (self.server / "server.env").write_text('MOTD="Legacy"\n')
        self.run_menu([["yesno", "", 0], ["textbox", "", 0]], running="yes", expected_status=1)
        self.assertNotIn("OVERRIDE_SERVER_PROPERTIES", tui.config.read_env(self.server / "server.env"))
        self.assertFalse((self.server / "backups/source-migrations").exists())

    def test_empty_backups_and_cancel_restore_do_not_change_properties(self):
        (self.server / "server.env").write_text("OVERRIDE_SERVER_PROPERTIES=false\n")
        original = self.properties.read_bytes()
        self.run_menu([
            ["menu", "__restore", 0], ["msgbox", "", 0],
            ["menu", "__backup", 0], ["textbox", "", 0],
            ["menu", "__restore", 0], ["menu", "@last", 0], ["yesno", "", 1],
            ["menu", "__exit", 0],
        ])
        self.assertEqual(self.properties.read_bytes(), original)
        backups = list((self.server / "backups/server-properties").glob("*.properties"))
        self.assertEqual(len(backups), 1)

if __name__ == "__main__":
    unittest.main()
