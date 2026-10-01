"""Persistent terminal session regressions; no Docker or user server changes."""
import curses
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "libexec/mcserver-kit/tui-session.py"
spec = importlib.util.spec_from_file_location("tui_session", TOOL)
ui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ui)


class DialogTests(unittest.TestCase):
    def test_menu_and_radio(self):
        menu = ui.parse_dialog(["--title", "Test", "--menu", "Choose", "20", "70", "10", "a", "Alpha", "b", "Beta"])
        self.assertEqual(menu["items"], [["a", "Alpha"], ["b", "Beta"]])
        radio = ui.parse_dialog(["--radiolist", "Choose", "12", "70", "2", "en", "English", "OFF", "ja", "日本語", "ON"])
        self.assertEqual(radio["selected"], 1)

    def test_input_and_unsupported_options(self):
        self.assertEqual(ui.parse_dialog(["--inputbox", "Value", "10", "70", "日本語"])["value"], "日本語")
        with self.assertRaises(ValueError):
            ui.parse_dialog(["--unsupported"])
        with self.assertRaises(ValueError):
            ui.parse_dialog(["--menu", "Choose", "20", "70", "10", "missing label"])

    def test_display_width_and_blank_lines(self):
        self.assertEqual(ui.clipped("日本abc", 5), "日本a")
        self.assertEqual(ui.display_width("日本abc"), 7)
        self.assertEqual(ui.lines("a\n\nb", 10), ["a", "", "b"])
        self.assertEqual(ui.clipped("\x1btest", 20), "test")

    def test_japanese_backspace_and_cursor(self):
        session = object.__new__(ui.Session)
        session.dialog = {"kind": "inputbox"}
        session.value = "日本語"
        session.cursor = 3
        session.focus = 0
        session.key(curses.KEY_BACKSPACE)
        session.key("文")
        self.assertEqual(session.value, "日本文")
        session.key(curses.KEY_LEFT)
        session.key("新")
        self.assertEqual(session.value, "日本新文")

    def test_cancel_does_not_confirm(self):
        session = object.__new__(ui.Session)
        session.dialog = {"kind": "yesno"}
        session.focus = 0
        session.reply = Mock()
        session.key("\t")
        session.key("\n")
        session.reply.assert_called_once_with(1)

    def test_loading_discards_keys(self):
        session = object.__new__(ui.Session)
        session.dialog = None
        session.reply = Mock()
        session.key("\n")
        session.reply.assert_not_called()

    def test_idle_menu_is_not_redrawn_but_loading_animates(self):
        class Process:
            returncode = 0

            def __init__(self):
                self.polls = 0

            def poll(self):
                self.polls += 1
                return None if self.polls <= 4 else 0

        for dialog, expected_draws in (({"kind": "menu"}, 1), (None, 4)):
            session = object.__new__(ui.Session)
            session.connection = None
            session.listener = object()
            session.suspended = False
            session.process = Process()
            session.dialog = dialog
            session.frame = 0
            session.draw = Mock()
            session.reply = Mock()
            session.key = Mock()
            session.screen = Mock()
            session.screen.getmaxyx.return_value = (24, 80)
            session.screen.get_wch.side_effect = curses.error
            with patch.object(ui.select, "select", return_value=([], [], [])):
                self.assertEqual(session.run(), 0)
            self.assertEqual(session.draw.call_count, expected_draws)
            self.assertEqual(session.screen.timeout.call_count, 4)

    def test_initial_loading_uses_selected_language(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "language"
            path.write_text("ja\n")
            with patch.dict(os.environ, {"MCSERVER_KIT_LANGUAGE_FILE": str(path)}, clear=True):
                self.assertEqual(ui.startup_language(), "ja")
                os.environ["MCSERVER_KIT_LANG"] = "en_US"
                self.assertEqual(ui.startup_language(), "en")

    def test_menu_columns_and_buttons_recenter_on_resize(self):
        class Screen:
            def __init__(self, width):
                self.width = width
                self.calls = []

            def getmaxyx(self):
                return 30, self.width

            def erase(self):
                self.calls = []

            def box(self):
                pass

            def refresh(self):
                pass

            def addstr(self, row, column, value, attr):
                self.calls.append((row, column, value, attr))

        session = object.__new__(ui.Session)
        session.screen = Screen(100)
        session.messages = {"tui.session.ok": "< OK >", "tui.session.cancel": "< Cancel >",
                            "tui.session.hint": "Use arrows", "tui.session.small": "Too small"}
        session.dialog = {"kind": "menu", "prompt": "Choose", "items":
                          [["start", "起動"], ["open-server", "サーバーを開く"]]}
        session.title = "Servers"
        session.index = session.scroll = session.focus = 0
        with patch.object(ui.curses, "has_colors", return_value=False):
            session.draw()
            first = [call for call in session.screen.calls
                     if call[2].startswith(("start ", "open-server "))]
            self.assertEqual(len(first), 2)
            self.assertEqual(first[0][1], first[1][1])
            self.assertEqual(
                ui.display_width(first[0][2].split("起動")[0]),
                ui.display_width(first[1][2].split("サーバーを開く")[0]),
            )
            self.assertGreater(first[0][1], 4)
            buttons = [call for call in session.screen.calls
                       if call[2] in ("< OK >", "< Cancel >")]
            self.assertEqual(len(buttons), 2)
            self.assertLess(buttons[0][1], 50)
            self.assertGreater(buttons[1][1], 50)
            old_column = first[0][1]
            session.screen.width = 120
            session.draw()
            resized = [call for call in session.screen.calls if call[2].startswith("start ")]
            self.assertEqual(resized[0][1], old_column + 10)

    def test_scrollbar_tracks_selection_and_hides_when_all_items_fit(self):
        class Screen:
            def __init__(self):
                self.height = 16
                self.width = 60
                self.calls = []

            def getmaxyx(self):
                return self.height, self.width

            def erase(self):
                self.calls = []

            def box(self):
                pass

            def refresh(self):
                pass

            def addstr(self, row, column, value, attr):
                self.calls.append((row, column, value, attr))

        session = object.__new__(ui.Session)
        session.screen = Screen()
        session.messages = {"tui.session.ok": "OK", "tui.session.cancel": "Cancel",
                            "tui.session.hint": "Arrows", "tui.session.small": "Small"}
        session.dialog = {"kind": "menu", "prompt": "Choose", "items":
                          [[str(index), "Item"] for index in range(20)]}
        session.title = "Servers"
        session.index = session.scroll = session.focus = 0
        with patch.object(ui.curses, "has_colors", return_value=False):
            session.draw()
            first = [row for row, column, value, _ in session.screen.calls
                     if column == 57 and value == "█"]
            self.assertTrue(first)
            session.index = 19
            session.draw()
            last = [row for row, column, value, _ in session.screen.calls
                    if column == 57 and value == "█"]
            self.assertGreater(min(last), min(first))
            session.screen.height = 45
            session.draw()
            self.assertFalse([value for _, column, value, _ in session.screen.calls
                              if column == 57 and value in ("█", "│")])

        session.screen.height = 16
        session.dialog = {"kind": "textbox", "prompt": "\n".join(str(i) for i in range(20))}
        session.scroll = 10
        with patch.object(ui.curses, "has_colors", return_value=False):
            session.draw()
        self.assertTrue([value for _, column, value, _ in session.screen.calls
                         if column == 57 and value == "█"])


class TerminalTests(unittest.TestCase):
    def run_terminal(self, body, interact, expected_status=0, expected_clears=1):
        with tempfile.TemporaryDirectory() as temp:
            workspace = Path(temp)
            script = workspace / "controller.sh"
            script.write_text(
                'set -eu\nsource "' + str(ROOT / "libexec/mcserver-kit/i18n.sh") + '"\nload_messages\n' + body,
                encoding="utf-8",
            )
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 100, 0, 0))
            environment = dict(os.environ, TERM="xterm-256color", MCSERVER_KIT_LANG="en",
                               MCSERVER_KIT_ACTIVE_LANG="en", TEST_UI_DIR=temp,
                               PYTHONDONTWRITEBYTECODE="1")
            process = subprocess.Popen([sys.executable, str(TOOL), "run", "bash", str(script)],
                                       stdin=slave, stdout=slave, stderr=slave, env=environment)
            os.close(slave)
            output = bytearray()

            def receive(marker=None, duration=5):
                deadline = time.monotonic() + duration
                while time.monotonic() < deadline:
                    if select.select([master], [], [], 0.05)[0]:
                        try:
                            chunk = os.read(master, 65536)
                        except OSError:
                            break
                        if not chunk:
                            break
                        output.extend(chunk)
                    if marker is not None and marker in output:
                        return
                if marker is not None:
                    self.assertIn(marker, output, output.decode(errors="replace"))

            try:
                interact(master, workspace, output, receive)
                receive(duration=0.5)
                process.wait(timeout=5)
                receive(duration=0.2)
                self.assertEqual(process.returncode, expected_status, output.decode(errors="replace"))
                self.assertEqual(output.count(b"\x1b[?1049h"), 1, "enter alternate screen once")
                self.assertEqual(output.count(b"\x1b[?1049l"), 1, "leave only at final exit")
                self.assertEqual(output.count(b"\x1b[2J"), expected_clears,
                                 "redraw fully only after handing the terminal to external output")
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                os.close(master)

    def test_menu_wait_result_and_cancel_keep_screen(self):
        body = """
choice="$(whiptail --title FIRST --menu Choose 20 70 2 one First two Second 3>&1 1>&2 2>&3)"
printf '%s' "$choice" >"$TEST_UI_DIR/choice"
sleep 0.7
whiptail --title RESULT --msgbox Finished 10 70
if whiptail --title CANCEL --yesno Confirm 10 70; then exit 7; fi
"""
        def interact(master, workspace, output, receive):
            receive(b"FIRST")
            os.write(master, b"\r")
            receive(b"Loading")
            self.assertNotIn(b"\x1b[?1049l", output)
            receive(b"RESULT")
            self.assertEqual((workspace / "choice").read_text(), "one")
            self.assertNotIn(b"\x1b[?1049l", output)
            os.write(master, b"\r")
            receive(b"CANCEL")
            os.write(master, b"\t\r")
        self.run_terminal(body, interact)

    def test_unicode_input_and_line_mode_handoff(self):
        body = """
value="$(whiptail --title INPUT --inputbox Value 10 70 3>&1 1>&2 2>&3)"
printf '%s' "$value" >"$TEST_UI_DIR/value"
tui_terminal_suspend
printf '\nRAW_INPUT_READY\n'
read -r raw
printf '%s' "$raw" >"$TEST_UI_DIR/raw"
tui_terminal_resume
whiptail --title RETURNED --msgbox Finished 10 70
"""
        def interact(master, workspace, output, receive):
            receive(b"INPUT")
            os.write(master, "日本語".encode() + b"\x7f" + "文".encode() + b"\r")
            receive(b"RAW_INPUT_READY")
            self.assertEqual((workspace / "value").read_text(), "日本文")
            self.assertNotIn(b"\x1b[?1049l", output)
            os.write(master, b"hello\n")
            receive(b"RETURNED")
            self.assertEqual((workspace / "raw").read_text(), "hello")
            os.write(master, b"\r")
        self.run_terminal(body, interact, expected_clears=2)

    def test_external_clear_before_resume_rebuilds_frame(self):
        body = """
whiptail --title BEFORE --msgbox Ready 10 70
tui_terminal_suspend
clear
printf 'LOG_SCREEN_READY\\n'
read -r _
clear
tui_terminal_resume
whiptail --title AFTER --msgbox Restored 10 70
"""
        def interact(master, workspace, output, receive):
            receive(b"BEFORE")
            os.write(master, b"\r")
            receive(b"LOG_SCREEN_READY")
            os.write(master, b"\r")
            receive(b"AFTER")
            self.assertNotIn(b"\x1b[?1049l", output)
            os.write(master, b"\r")
        # Initial curses screen, two external clear calls, and one curses
        # invalidation when ownership returns to the TUI.
        self.run_terminal(body, interact, expected_clears=4)

    def test_slow_home_list_and_server_return(self):
        body = """
mkdir -p "$TEST_UI_DIR/servers/demo" "$TEST_UI_DIR/bin" "$TEST_UI_DIR/cache"
printf 'services: {}\\n' >"$TEST_UI_DIR/servers/demo/compose.yaml"
printf 'paths:\\n  server_root: "%s/servers"\\n' "$TEST_UI_DIR" >"$TEST_UI_DIR/config.yml"
printf '%s\\nv1.1.3\\n' "$(date +%s)" >"$TEST_UI_DIR/cache/update-check"
printf '#!/bin/sh\\nprintf x >> "$TEST_UI_DIR/docker-count"\\nsleep 0.2\\necho "[]"\\n' >"$TEST_UI_DIR/bin/docker"
chmod +x "$TEST_UI_DIR/bin/docker"
export PATH="$TEST_UI_DIR/bin:$PATH"
export MCSERVER_KIT_CONFIG="$TEST_UI_DIR/config.yml"
export MCSERVER_KIT_UPDATE_CACHE_DIR="$TEST_UI_DIR/cache"
exec bash """ + str(ROOT / "libexec/mcserver-kit/home-tui.sh") + """
"""
        def interact(master, workspace, output, receive):
            receive(b"Choose what you want", duration=8)
            self.assertEqual((workspace / "docker-count").read_text(), "x")
            os.write(master, b"\r")  # Home -> server list
            receive(b"Select a server", duration=8)
            self.assertEqual((workspace / "docker-count").read_text(), "x")
            os.write(master, b"\r")  # List -> demo
            receive(b"Current status", duration=8)
            before = len(output)
            os.write(master, b"\x1b")  # Cancel -> list, slow state retrieval
            receive(duration=0.6)
            self.assertNotIn(b"\x1b[?1049l", output)
            self.assertIn(b"Loading", output[before:])
            receive(duration=1)
            os.write(master, b"\x1b")  # Cancel -> home
            receive(duration=2)
            os.write(master, b"\x1b")  # Exit home
        self.run_terminal(body, interact)

    def test_password_hidden_and_failure_restores_terminal(self):
        body = """
value="$(whiptail --title SECRET --passwordbox Password 10 70 3>&1 1>&2 2>&3)"
printf '%s' "$value" >"$TEST_UI_DIR/secret"
whiptail --title FAILED --msgbox "Command failed" 10 70
exit 7
"""
        def interact(master, workspace, output, receive):
            receive(b"SECRET")
            os.write(master, b"not-for-display\r")
            receive(b"FAILED")
            self.assertEqual((workspace / "secret").read_text(), "not-for-display")
            self.assertNotIn(b"not-for-display", output)
            os.write(master, b"\r")
        self.run_terminal(body, interact, expected_status=7)


if __name__ == "__main__":
    unittest.main()
