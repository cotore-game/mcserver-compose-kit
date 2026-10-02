#!/usr/bin/env bash

I18N_ROOT="${MCSERVER_KIT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"
I18N_SHARE_DIR="${MCSERVER_KIT_SHARE_DIR:-${I18N_ROOT}/share/mcserver-kit}"
I18N_LOCALE_DIR="${I18N_SHARE_DIR}/locales"
declare -A I18N_MESSAGES=()

set_default_tui_colors() {
  [[ -n "${NEWT_COLORS:-}" ]] && return 0
  export NEWT_COLORS="${MCSERVER_KIT_TUI_COLORS:-
root=white,black
window=white,black
border=lightgray,black
title=lightcyan,black
textbox=white,black
listbox=white,black
actlistbox=white,blue
actsellistbox=white,blue
button=black,lightgray
actbutton=white,blue
compactbutton=white,black
entry=white,black
label=white,black
checkbox=white,black
actcheckbox=white,blue
}"
}

# A home session owns the terminal. Dialog subprocesses exchange only data,
# so OK/Cancel never restores the shell while the next screen is being loaded.
if [[ -n "${MCSERVER_KIT_TUI_SOCKET:-}" ]]; then
  whiptail() {
    python3 "${I18N_ROOT}/libexec/mcserver-kit/tui-session.py" client "$@"
  }
fi

tui_terminal_suspend() {
  [[ -z "${MCSERVER_KIT_TUI_SOCKET:-}" ]] ||
    python3 "${I18N_ROOT}/libexec/mcserver-kit/tui-session.py" client --suspend
}

tui_terminal_resume() {
  [[ -z "${MCSERVER_KIT_TUI_SOCKET:-}" ]] ||
    python3 "${I18N_ROOT}/libexec/mcserver-kit/tui-session.py" client --resume
}

detect_language() {
  local requested="${MCSERVER_KIT_LANG:-}"
  local language_file="${MCSERVER_KIT_LANGUAGE_FILE:-${HOME}/.config/mcserver-compose-kit/language}"

  if [[ -n "$requested" ]]; then
    printf '%s' "${requested%%[_-]*}"
    return
  fi

  if [[ -f "$language_file" ]]; then
    requested="$(head -n 1 "$language_file")"
    if [[ "$requested" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]]; then
      printf '%s' "${requested%%[_-]*}"
      return
    fi
  fi

  printf 'en'
}

load_messages() {
  local language="${1:-$(detect_language)}"
  local catalog="${I18N_LOCALE_DIR}/${language}.json"
  local english_catalog="${I18N_LOCALE_DIR}/en.json"
  local key

  [[ -f "$catalog" ]] || catalog="$english_catalog"
  load_catalog "$english_catalog"
  if [[ "$catalog" != "$english_catalog" ]]; then
    load_catalog "$catalog"
  fi
  MCSERVER_KIT_ACTIVE_LANG="$(basename "$catalog" .json)"
  export MCSERVER_KIT_ACTIVE_LANG
}

load_catalog() {
  local catalog="$1"
  local key value
  # NUL-delimited pairs preserve translated newlines without a decoder process
  # for every message. Bash arrays cannot store NUL bytes in values.
  while IFS= read -r -d '' key && IFS= read -r -d '' value; do
    I18N_MESSAGES["$key"]="$value"
  done < <(python3 - "$catalog" <<'PYTHON'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as file:
    messages = json.load(file)
for key, value in messages.items():
    sys.stdout.buffer.write(key.encode("utf-8") + b"\0" + value.encode("utf-8") + b"\0")
PYTHON
  )
}

tr() {
  local key="$1"
  shift
  local message="${I18N_MESSAGES[$key]:-$key}"
  # Catalogs are trusted repository files and may contain printf placeholders.
  # shellcheck disable=SC2059
  printf "$message" "$@"
}
