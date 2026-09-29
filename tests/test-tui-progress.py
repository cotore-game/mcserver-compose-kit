"""Progress-only hotfix tests using real pseudo-terminals, without Docker."""
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "libexec/mcserver-kit/tui-progress.py"
spec = importlib.util.spec_from_file_location("tui_progress", TOOL)
progress = importlib.util.module_from_spec(spec)
spec.loader.exec_module(progress)


class ProgressTests(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory()
        self.addCleanup(self.workspace.cleanup)
        self.root = Path(self.workspace.name)
        self.output = self.root / "output"

    def arguments(self, code):
        return [sys.executable, str(TOOL), "--output", str(self.output),
                "--title", "Test", "--message", "{spinner} Processing...",
                "--", sys.executable, "-c", code]

    def test_character_width_and_controls(self):
        self.assertEqual(progress.clipped("日本abc", 5), "日本a")
        self.assertEqual(progress.clipped("\x1btext\n", 20), "text")

    def test_output_and_error_share_file_and_preserve_status(self):
        result = subprocess.run(self.arguments(
            "import sys; print('stdout'); print('stderr', file=sys.stderr); sys.exit(7)"
        ), capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 7)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(result.stderr, b"")
        self.assertIn("stdout", self.output.read_text())
        self.assertIn("stderr", self.output.read_text())

    def test_empty_success_does_not_invent_logs(self):
        result = subprocess.run(self.arguments("pass"), capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.output.read_bytes(), b"")

    def test_missing_command_is_reported(self):
        args = self.arguments("pass")
        args[args.index("--") + 1:] = [str(self.root / "not-a-command")]
        result = subprocess.run(args, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Could not complete command", self.output.read_text())

    def test_signal_exit_is_not_reported_as_success(self):
        result = subprocess.run(self.arguments(
            "import os, signal; os.kill(os.getpid(), signal.SIGTERM)"
        ), capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 143)

    def test_command_is_executed_once(self):
        counter = self.root / "counter"
        code = f"from pathlib import Path; p=Path({str(counter)!r}); p.write_text(p.read_text()+'x' if p.exists() else 'x')"
        subprocess.run(self.arguments(code), check=True, capture_output=True, timeout=5)
        self.assertEqual(counter.read_text(), "x")

    def test_terminal_stays_open_until_command_finishes(self):
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 28, 94, 0, 0))
        process = subprocess.Popen(
            self.arguments("import time; print('PRIVATE-COMMAND-OUTPUT', flush=True); time.sleep(0.9)"),
            stdin=slave, stdout=slave, stderr=slave,
            env=dict(os.environ, TERM="xterm-256color"),
        )
        os.close(slave)
        received = bytearray()

        def receive(duration):
            deadline = time.monotonic() + duration
            while time.monotonic() < deadline:
                if select.select([master], [], [], 0.05)[0]:
                    try:
                        received.extend(os.read(master, 65536))
                    except OSError:
                        break

        try:
            deadline = time.monotonic() + 5
            while b"Processing" not in received and time.monotonic() < deadline:
                receive(0.05)
            self.assertIn(b"Processing", received)
            receive(0.3)
            self.assertIsNone(process.poll())
            self.assertNotIn(b"\x1b[?1049l", received, "must not return to shell between spinner frames")
            self.assertNotIn(b"PRIVATE-COMMAND-OUTPUT", received, "logs belong to the later result dialog")
            self.assertEqual(received.count(b"\x1b[2J"), 1, "must not clear the screen for each frame")
            self.assertGreaterEqual(sum(frame.encode() in received for frame in progress.FRAMES), 2)
            receive(1)
            process.wait(timeout=3)
            receive(0.1)
            self.assertEqual(process.returncode, 0)
            self.assertEqual(received.count(b"\x1b[?1049h"), 1)
            self.assertEqual(received.count(b"\x1b[?1049l"), 1)
            self.assertIn("PRIVATE-COMMAND-OUTPUT", self.output.read_text())
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
            os.close(master)

    def test_termination_stops_command_group(self):
        marker = self.root / "finished"
        ready = self.root / "ready"
        child_pid = self.root / "child-pid"
        code = (
            "import os, time; from pathlib import Path; "
            f"Path({str(child_pid)!r}).write_text(str(os.getpid())); "
            f"Path({str(ready)!r}).touch(); time.sleep(3); Path({str(marker)!r}).touch()"
        )
        process = subprocess.Popen(self.arguments(code), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 5
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(ready.exists())
            process.send_signal(signal.SIGTERM)
            process.communicate(timeout=5)
            self.assertEqual(process.returncode, 143)
            self.assertFalse(marker.exists())
            with self.assertRaises(ProcessLookupError):
                os.kill(int(child_pid.read_text()), 0)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()



    def test_home_keeps_result_dialog_and_error_title(self):
        server = self.root / "servers/demo"
        server.mkdir(parents=True)
        (server / "compose.yaml").write_text("services: {}\n")
        config = self.root / "config.yml"
        config.write_text(f"paths:\n  server_root: {self.root / 'servers'}\n")
        fake_bin = self.root / "bin"
        fake_bin.mkdir()
        queue = self.root / "queue.json"
        events = self.root / "events.jsonl"
        whiptail = fake_bin / "whiptail"
        whiptail.write_text("""#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
queue = pathlib.Path(os.environ["TEST_QUEUE"])
events = pathlib.Path(os.environ["TEST_EVENTS"])
if "--menu" in args:
    items = json.loads(queue.read_text())
    sys.stderr.write(items.pop(0))
    queue.write_text(json.dumps(items))
elif "--textbox" in args:
    path = pathlib.Path(args[args.index("--textbox") + 1])
    title = args[args.index("--title") + 1]
    with events.open("a") as file:
        file.write(json.dumps({"title": title, "text": path.read_text()}) + "\\n")
elif "--infobox" in args:
    raise SystemExit("Unexpected old infobox loop")
""")
        whiptail.chmod(0o755)
        docker = fake_bin / "docker"
        docker.write_text("""#!/bin/sh
case "$*" in
  'compose ps -a --format json') echo '[]' ;;
  'compose config --quiet') exit 0 ;;
  'compose up -d') echo command-output; echo command-diagnostic >&2; exit "$TEST_COMMAND_STATUS" ;;
esac
""")
        docker.chmod(0o755)
        cache = self.root / "cache"
        cache.mkdir()
        version = (ROOT / "VERSION").read_text().strip()
        (cache / "update-check").write_text(f"{int(time.time())}\nv{version}\n")
        for status in (0, 7):
            with self.subTest(status=status):
                queue.write_text(json.dumps(["servers", "demo", "start", "back", "__back", "exit"]))
                events.write_text("")
                result = subprocess.run(
                    ["bash", str(ROOT / "mcserver-kit"), "home"],
                    capture_output=True, text=True, timeout=40,
                    env=dict(os.environ, PATH=f"{fake_bin}:{os.environ['PATH']}",
                             MCSERVER_KIT_LANG="en", MCSERVER_KIT_TUI_TEST="true",
                             MCSERVER_KIT_CONFIG=str(config), MCSERVER_KIT_UPDATE_CACHE_DIR=str(cache),
                             TEST_QUEUE=str(queue), TEST_EVENTS=str(events),
                             TEST_COMMAND_STATUS=str(status)),
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                records = [json.loads(line) for line in events.read_text().splitlines()]
                self.assertEqual(len(records), 1)
                self.assertIn("command-output", records[0]["text"])
                self.assertIn("command-diagnostic", records[0]["text"])
                self.assertEqual(records[0]["title"] == "Error", status != 0)
                self.assertEqual(json.loads(queue.read_text()), [])

if __name__ == "__main__":
    unittest.main()
