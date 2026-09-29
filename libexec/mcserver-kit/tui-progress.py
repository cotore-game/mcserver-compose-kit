#!/usr/bin/env python3
"""Keep a single progress dialog open while a non-interactive command runs.

Only the waiting screen uses curses. Menus and result dialogs remain whiptail.
"""
from __future__ import annotations

import argparse
import curses
import os
from pathlib import Path
import signal
import subprocess
import sys
import unicodedata

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


def stop_command(process):
    # Include grandchildren, not just the shell launching Docker or curl.
    if process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            process.wait()
            return
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()


def execute(screen, command, output, title, message):
    window = None
    size = None
    if screen is not None:
        curses.curs_set(0)
        screen.timeout(100)

    def draw(frame):
        nonlocal window, size
        if screen is None:
            return
        current = screen.getmaxyx()
        if current != size:
            size = current
            rows, columns = size
            screen.erase()
            screen.noutrefresh()
            if rows < 4 or columns < 12:
                window = None
            else:
                height, width = min(8, rows), min(72, columns)
                window = curses.newwin(height, width, (rows - height) // 2, (columns - width) // 2)
                window.box()
                window.addstr(0, 2, clipped(" " + title + " ", width - 4))
        if window is not None:
            height, width = window.getmaxyx()
            row = min(3, height - 2)
            window.move(row, 2)
            window.addstr(clipped(message.replace("{spinner}", frame), width - 4))
            window.noutrefresh()
        curses.doupdate()

    draw(FRAMES[0])  # Show the dialog before launching a potentially slow command.
    with subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=output,
                          stderr=subprocess.STDOUT, start_new_session=True) as process:
        try:
            frame = 0
            while process.poll() is None:
                if screen is None:
                    try:
                        process.wait(timeout=0.1)
                    except subprocess.TimeoutExpired:
                        pass
                else:
                    draw(FRAMES[frame % len(FRAMES)])
                    screen.getch()  # Consume keys; they must not dismiss the next result.
                frame += 1
            if screen is not None:
                curses.flushinp()
            return process.returncode if process.returncode >= 0 else 128 - process.returncode
        finally:
            stop_command(process)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--title", required=True)
    parser.add_argument("--message", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a command is required after --")

    def interrupted(signum, _frame):
        raise InterruptedError(signum)

    previous = signal.signal(signal.SIGTERM, interrupted)
    try:
        with Path(args.output).open("w", encoding="utf-8") as output:
            try:
                if sys.stdin.isatty() and sys.stdout.isatty():
                    return curses.wrapper(execute, command, output, args.title, args.message)
                # CI and redirected invocations have no interactive display.
                return execute(None, command, output, args.title, args.message)
            except KeyboardInterrupt:
                print("Command interrupted (SIGINT).", file=output)
                return 130
            except InterruptedError:
                print("Command interrupted (SIGTERM).", file=output)
                return 143
            except (OSError, curses.error) as error:
                print(f"Could not complete command: {error}", file=output)
                return 1
    finally:
        signal.signal(signal.SIGTERM, previous)


if __name__ == "__main__":
    raise SystemExit(main())
