#!/usr/bin/env python3
"""One terminal session for shell-driven dialogs, including time between dialogs.

The shell remains the controller. Local socket requests replace short-lived
whiptail processes; curses owns the screen until the controller exits.
"""
from __future__ import annotations

import curses
import json
import os
from pathlib import Path
import select
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unicodedata

KINDS = ("menu", "radiolist", "inputbox", "passwordbox", "yesno", "msgbox", "textbox", "infobox")
FRAMES = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"


def clipped(text: str, width: int) -> str:
    result, used = [], 0
    for char in text:
        if unicodedata.category(char).startswith("C"):
            continue
        size = 0 if unicodedata.combining(char) else (2 if unicodedata.east_asian_width(char) in "WF" else 1)
        if used + size > width:
            break
        result.append(char)
        used += size
    return "".join(result)


def lines(text: str, width: int) -> list[str]:
    result = []
    for paragraph in text.split("\n"):
        if not paragraph:
            result.append("")
            continue
        while paragraph:
            part = clipped(paragraph, width)
            if not part:
                break
            result.append(part)
            paragraph = paragraph[len(part):]
    return result or [""]


def parse_dialog(args: list[str]) -> dict:
    kind = next((kind for kind in KINDS if "--" + kind in args), None)
    if kind is None:
        raise ValueError("Unsupported dialog: " + " ".join(args))
    start = args.index("--" + kind)
    prompt = args[start + 1]
    if kind == "textbox":
        prompt = Path(prompt).read_text(encoding="utf-8", errors="replace")
    remaining = args[start + (5 if kind in ("menu", "radiolist") else 4):]
    items = []
    if kind in ("menu", "radiolist"):
        stride = 3 if kind == "radiolist" else 2
        if len(remaining) % stride:
            raise ValueError("Invalid menu items")
        items = [remaining[i:i + stride] for i in range(0, len(remaining), stride)]
    title = args[args.index("--title") + 1] if "--title" in args else "mcserver-kit"
    selected = next((i for i, item in enumerate(items) if len(item) == 3 and item[2] == "ON"), 0)
    return dict(kind=kind, title=title, prompt=prompt, items=items, selected=selected,
                value=remaining[0] if kind in ("inputbox", "passwordbox") and remaining else "")


def translations(language: str) -> dict:
    root = Path(__file__).resolve().parents[2]
    share = Path(os.environ.get("MCSERVER_KIT_SHARE_DIR", root / "share/mcserver-kit"))
    messages = json.loads((share / "locales/en.json").read_text(encoding="utf-8"))
    if language.replace("-", "").replace("_", "").isalnum():
        path = share / "locales" / (language + ".json")
        if path.is_file():
            messages.update(json.loads(path.read_text(encoding="utf-8")))
    return messages


def startup_language() -> str:
    requested = os.environ.get("MCSERVER_KIT_LANG") or os.environ.get("MCSERVER_KIT_ACTIVE_LANG")
    if not requested:
        path = Path(os.environ.get("MCSERVER_KIT_LANGUAGE_FILE",
                                  str(Path.home() / ".config/mcserver-compose-kit/language")))
        try:
            requested = path.read_text(encoding="utf-8").splitlines()[0]
        except (OSError, IndexError, UnicodeError):
            requested = "en"
    return requested.split("_", 1)[0].split("-", 1)[0]


def client(args: list[str]) -> int:
    with socket.socket(socket.AF_UNIX) as connection:
        connection.connect(os.environ["MCSERVER_KIT_TUI_SOCKET"])
        request = {"args": args, "language": os.environ.get("MCSERVER_KIT_ACTIVE_LANG", "en")}
        connection.sendall(json.dumps(request).encode() + b"\n")
        reply = bytearray()
        while not reply.endswith(b"\n"):
            block = connection.recv(65536)
            if not block:
                raise RuntimeError("TUI session closed")
            reply.extend(block)
    response = json.loads(reply)
    # Match whiptail's output contract for the existing shell redirections.
    sys.stderr.write(response.get("value", ""))
    return response["status"]


class Session:
    def __init__(self, screen, listener, process):
        self.screen, self.listener, self.process = screen, listener, process
        self.connection = None
        self.dialog = None
        self.suspended = False
        self.messages = translations(startup_language())
        self.title = "mcserver-kit"
        self.index = self.scroll = self.focus = self.cursor = 0
        self.value = ""
        self.frame = 0
        self.error_status = 0
        self.sigint_handler = signal.getsignal(signal.SIGINT)
        curses.set_escdelay(25)
        self.screen.timeout(100)
        self.screen.keypad(True)
        curses.curs_set(0)
        if curses.has_colors():
            curses.start_color()
            curses.use_default_colors()
            curses.init_pair(1, curses.COLOR_WHITE, curses.COLOR_BLUE)

    def message(self, key):
        return self.messages["tui.session." + key]

    def reply(self, status=0, value=""):
        if self.connection:
            try:
                self.connection.sendall(json.dumps({"status": status, "value": value}).encode() + b"\n")
            except (BrokenPipeError, ConnectionResetError):
                pass
            self.connection.close()
        self.connection = None
        self.dialog = None
        self.focus = 0
        self.error_status = 0

    def accept(self):
        connection, _ = self.listener.accept()
        connection.settimeout(2)
        data = bytearray()
        try:
            while not data.endswith(b"\n"):
                block = connection.recv(65536)
                if not block:
                    raise ValueError("Incomplete dialog request")
                data.extend(block)
                if len(data) > 1024 * 1024:
                    raise ValueError("Dialog request too large")
            request = json.loads(data)
            self.connection = connection
            self.messages = translations(request.get("language", "en"))
            args = request["args"]
            if args == ["--suspend"]:
                # Legacy line-oriented create/log screens keep this alternate
                # screen, but temporarily own terminal input and output.
                self.suspended = True
                signal.signal(signal.SIGINT, signal.SIG_IGN)
                curses.nocbreak()
                curses.echo()
                curses.curs_set(1)
                self.reply()
                return
            if args == ["--resume"]:
                self.suspended = False
                signal.signal(signal.SIGINT, self.sigint_handler)
                curses.noecho()
                curses.cbreak()
                curses.curs_set(0)
                self.screen.touchwin()
                self.reply()
                return
            self.dialog = parse_dialog(args)
            self.title = self.dialog["title"]
            self.index = self.dialog["selected"]
            self.value = self.dialog["value"]
            self.cursor = len(self.value)
            self.scroll = self.focus = 0
            if self.dialog["kind"] == "infobox":
                self.reply()
        except (OSError, ValueError, KeyError, IndexError) as error:
            self.connection = connection
            self.error_status = 2
            self.title = self.messages.get("common.error", "Error")
            self.dialog = dict(kind="msgbox", prompt=str(error), items=[])
            self.scroll = self.focus = 0
        finally:
            if connection.fileno() != -1:
                connection.settimeout(None)

    def put(self, row, column, text, attr=0):
        height, width = self.screen.getmaxyx()
        if 0 <= row < height - 1 and 0 <= column < width - 1:
            try:
                self.screen.addstr(row, column, clipped(text, width - column - 1), attr)
            except curses.error:
                pass

    def draw(self):
        height, width = self.screen.getmaxyx()
        # erase + refresh lets curses diff frames; never clear/reset the terminal.
        self.screen.erase()
        if height < 10 or width < 35:
            self.put(0, 0, self.message("small"))
            self.screen.refresh()
            return
        self.screen.box()
        self.put(1, 3, self.title, curses.A_BOLD)
        if self.dialog is None:
            self.put(height // 2, 4, FRAMES[self.frame % len(FRAMES)] + " " + self.message("loading"))
            self.screen.refresh()
            return
        dialog = self.dialog
        kind = dialog["kind"]
        content = lines(dialog["prompt"], width - 8)
        limit = min(len(content), max(3, height // 3)) if kind in ("menu", "radiolist", "inputbox", "passwordbox") else height - 7
        if kind in ("textbox", "msgbox", "yesno"):
            content = content[self.scroll:]
        for number, text in enumerate(content[:limit]):
            self.put(3 + number, 4, text)
        row = 4 + min(limit, len(content))
        selected_attr = curses.color_pair(1) if curses.has_colors() else curses.A_REVERSE
        if kind in ("menu", "radiolist"):
            visible = max(1, height - row - 4)
            first = max(0, self.index - visible + 1)
            for number, item in enumerate(dialog["items"][first:first + visible]):
                position = first + number
                self.put(row + number, 4, f"{item[0]}  {item[1]}",
                         selected_attr if position == self.index else 0)
        elif kind in ("inputbox", "passwordbox"):
            visible = self.value if kind == "inputbox" else "*" * len(self.value)
            # Keep the insertion point visible for long input, including Japanese.
            prefix = visible[:self.cursor]
            while len(clipped(prefix, width - 12)) < len(prefix):
                prefix = prefix[1:]
            start = self.cursor - len(prefix)
            entry = visible[start:self.cursor] + "│" + visible[self.cursor:]
            self.put(row, 4, "[" + entry + "]", selected_attr if self.focus == 0 else 0)
        self.put(height - 3, 4, self.message("ok"), selected_attr if not self.focus else 0)
        if kind not in ("msgbox", "textbox"):
            self.put(height - 3, width // 2, self.message("cancel"), selected_attr if self.focus else 0)
        self.put(height - 2, 3, self.message("hint"))
        self.screen.refresh()

    def key(self, key):
        if self.dialog is None:
            return  # Do not queue keys pressed during work into the next dialog.
        dialog = self.dialog
        kind = dialog["kind"]
        if key == "\x1b":
            self.reply(1)
        elif key == "\t":
            self.focus = 1 - self.focus if kind not in ("textbox", "msgbox") else 0
        elif key in ("\n", "\r", curses.KEY_ENTER):
            if self.focus:
                self.reply(1)
            else:
                value = self.value if kind in ("inputbox", "passwordbox") else ""
                if kind in ("menu", "radiolist") and dialog["items"]:
                    value = dialog["items"][self.index][0]
                self.reply(self.error_status, value)
        elif kind in ("menu", "radiolist"):
            if key in (curses.KEY_UP, curses.KEY_DOWN):
                self.index = max(0, min(len(dialog["items"]) - 1,
                                       self.index + (1 if key == curses.KEY_DOWN else -1)))
            elif key in (curses.KEY_LEFT, curses.KEY_RIGHT):
                self.focus = 1 - self.focus
        elif kind in ("inputbox", "passwordbox") and not self.focus:
            if key in (curses.KEY_BACKSPACE, "\x7f", "\b"):
                self.value = self.value[:max(0, self.cursor - 1)] + self.value[self.cursor:]
                self.cursor = max(0, self.cursor - 1)
            elif key == curses.KEY_DC:
                self.value = self.value[:self.cursor] + self.value[self.cursor + 1:]
            elif key == curses.KEY_LEFT:
                self.cursor = max(0, self.cursor - 1)
            elif key == curses.KEY_RIGHT:
                self.cursor = min(len(self.value), self.cursor + 1)
            elif key == curses.KEY_HOME:
                self.cursor = 0
            elif key == curses.KEY_END:
                self.cursor = len(self.value)
            elif isinstance(key, str) and key.isprintable():
                self.value = self.value[:self.cursor] + key + self.value[self.cursor:]
                self.cursor += len(key)
        elif key in (curses.KEY_LEFT, curses.KEY_RIGHT) and kind == "yesno":
            self.focus = 1 - self.focus
        elif key in (curses.KEY_DOWN, curses.KEY_NPAGE, curses.KEY_UP, curses.KEY_PPAGE):
            total = len(lines(dialog["prompt"], max(1, self.screen.getmaxyx()[1] - 8)))
            delta = 10 if key in (curses.KEY_NPAGE, curses.KEY_PPAGE) else 1
            self.scroll = max(0, min(total - 1, self.scroll + (delta if key in (curses.KEY_DOWN, curses.KEY_NPAGE) else -delta)))

    def run(self):
        while self.process.poll() is None:
            if self.connection is None and select.select([self.listener], [], [], 0)[0]:
                self.accept()
            if self.suspended:
                time.sleep(0.05)
                continue
            self.frame += 1
            self.draw()
            try:
                self.key(self.screen.get_wch())
            except curses.error:
                pass
        self.reply(1)
        return self.process.returncode


def run_session(command):
    with tempfile.TemporaryDirectory(prefix="mcserver-kit-ui-") as directory:
        endpoint = str(Path(directory) / "session.sock")
        with socket.socket(socket.AF_UNIX) as listener:
            listener.bind(endpoint)
            listener.listen()
            environment = dict(os.environ, MCSERVER_KIT_TUI_SOCKET=endpoint)
            # The screen is initialized before the controller can issue requests.
            def start(screen):
                process = subprocess.Popen(command, env=environment)
                try:
                    return Session(screen, listener, process).run()
                finally:
                    if process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=3)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait()
            previous = signal.getsignal(signal.SIGTERM)
            previous_int = signal.getsignal(signal.SIGINT)
            def terminate(signum, _frame):
                raise SystemExit(128 + signum)
            signal.signal(signal.SIGTERM, terminate)
            try:
                return curses.wrapper(start)
            finally:
                signal.signal(signal.SIGTERM, previous)
                signal.signal(signal.SIGINT, previous_int)


def main():
    if sys.argv[1] == "client":
        return client(sys.argv[2:])
    try:
        return run_session(sys.argv[2:])
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
