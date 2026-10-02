#!/usr/bin/env python3
"""Generic property editor; mutations share the guarded public CLI."""
from __future__ import annotations

import importlib.util
import json
import os
import unicodedata
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("server_config", HERE / "server-config.py")
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)


def load_messages(share: Path, language: str) -> dict[str, str]:
    messages = json.loads((share / "locales/en.json").read_text(encoding="utf-8"))
    if language.replace("-", "").replace("_", "").isalnum():
        translated = share / "locales" / f"{language}.json"
        if translated.is_file():
            messages.update(json.loads(translated.read_text(encoding="utf-8")))
    return messages


class Editor:
    def __init__(self, server_id: str, server_dir: Path, share: Path, language: str):
        self.server_id = server_id
        self.server_dir = server_dir
        self.messages = load_messages(share, language)
        self.catalog = json.loads((share / "properties.json").read_text(encoding="utf-8"))
        self.changed = False

    def text(self, key: str) -> str:
        return self.messages[f"properties.editor.{key}"]

    def description(self, key: str) -> str:
        message = self.catalog.get(key, {}).get("description")
        return self.messages.get(message, self.text("unknown"))

    def is_secret(self, key: str) -> bool:
        return self.catalog.get(key, {}).get("secret", False) or any(
            word in key.lower() for word in ("password", "secret", "token")
        )

    def preview(self, key: str, value: str, width: int = 24) -> str:
        if not value:
            return '""'
        if self.is_secret(key):
            return "********"
        visible = "".join(char if not unicodedata.category(char).startswith("C") else "·"
                          for char in value)
        cells = [0 if unicodedata.combining(char) else (
            2 if unicodedata.east_asian_width(char) in "WF" else 1) for char in visible]
        budget = width - 1 if sum(cells) > width else width
        result = ""
        used = 0
        for char, size in zip(visible, cells):
            if used + size > budget:
                return result + "…"
            result += char
            used += size
        return result

    def dialog(self, kind: str, prompt: str, *args: str) -> str | None:
        dimensions = ["22", "90", "14"] if kind == "menu" else ["14", "90"]
        session = os.environ.get("MCSERVER_KIT_TUI_SOCKET")
        command = ([sys.executable, str(HERE / "tui-session.py"), "client"]
                   if session else ["whiptail", "--output-fd", "1"])
        result = subprocess.run(
            [*command, "--title", self.server_id, f"--{kind}", prompt, *dimensions, *args],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE if session else None,
            text=True, check=False,
        )
        if result.returncode in (1, 255):
            return None
        if result.returncode != 0:
            raise RuntimeError(f"whiptail exited with status {result.returncode}")
        return result.stderr if session else result.stdout

    def values(self) -> dict[str, str]:
        return config.parse_import_properties(self.server_dir / "data/server.properties")

    def mutate(self, operation: str, key: str, *args: str) -> bool:
        result = subprocess.run(
            [str(HERE / "server-manager.sh"), "server", self.server_id,
             "properties", operation, key, *args],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False,
        )
        if result.returncode:
            self.dialog("msgbox", result.stdout or self.text("failed"))
            return False
        self.changed = True
        return True

    def edit(self, key: str, current: str | None) -> None:
        prompt = f"{key}\n{self.description(key)}"
        secret = self.is_secret(key)
        if current is not None:
            shown = "********" if secret else current
            action = self.dialog("menu", f"{prompt}\n\n{shown}",
                                 "edit", self.text("edit"), "remove", self.text("remove"))
            if action is None:
                return
            if action == "remove":
                if self.dialog("yesno", f"{key}\n\n{self.text('remove_confirm')}") is not None:
                    self.mutate("remove", key)
                return
        # Never put existing secrets in dialog arguments or prefill them.
        kind = "passwordbox" if secret else "inputbox"
        initial = () if secret else (current or "",)
        value = self.dialog(kind, prompt, *initial)
        if value is None or (current is not None and value == current):
            return
        if secret and self.dialog("yesno", self.text("secret_confirm")) is None:
            return
        self.mutate("set", key, value)

    def add(self, values: dict[str, str]) -> None:
        items = ["@custom", self.text("custom")]
        for key in sorted(key for key in self.catalog.keys() - values.keys()
                          if not self.catalog[key].get("legacy", False)):
            items.extend((key, self.description(key)))
        key = self.dialog("menu", self.text("add_hint"), *items)
        if key is None:
            return
        if key == "@custom":
            key = self.dialog("inputbox", self.text("key"))
            if key is None:
                return
        try:
            config.validate_property_key(key)
        except ValueError as error:
            self.dialog("msgbox", str(error))
            return
        if key in values:
            self.dialog("msgbox", self.text("exists"))
            return
        self.edit(key, None)

    def run(self) -> bool:
        while True:
            values = self.values()
            items = ["@add", self.text("add")]
            for key in sorted(values):
                items.extend((key, f"{self.preview(key, values[key])} · {self.description(key)}"))
            selected = self.dialog("menu", self.text("hint"), *items)
            if selected is None:
                return self.changed
            if selected == "@add":
                self.add(values)
            else:
                self.edit(selected, values[selected])


def main() -> int:
    editor = None
    try:
        share = Path(os.environ.get("MCSERVER_KIT_SHARE_DIR", HERE.parents[1] / "share/mcserver-kit"))
        editor = Editor(sys.argv[1], Path(sys.argv[2]), share,
                        os.environ.get("MCSERVER_KIT_ACTIVE_LANG", "en"))
        return 10 if editor.run() else 0
    except (OSError, ValueError, RuntimeError) as error:
        if editor is not None:
            editor.dialog("msgbox", str(error))
        else:
            subprocess.run(["whiptail", "--title", sys.argv[1],
                            "--msgbox", str(error), "14", "90"], check=False)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
