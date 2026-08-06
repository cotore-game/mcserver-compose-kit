#!/usr/bin/env bash

I18N_ROOT="${I18N_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
I18N_LOCALE_DIR="${I18N_ROOT}/locales"
declare -A I18N_MESSAGES=()

detect_language() {
  local requested="${MCSERVER_KIT_LANG:-}"

  if [[ -n "$requested" ]]; then
    printf '%s' "${requested%%[_-]*}"
    return
  fi

  case "${LANG:-}" in
    ja* | JA*) printf 'ja' ;;
    *) printf 'en' ;;
  esac
}

load_messages() {
  local language="${1:-$(detect_language)}"
  local catalog="${I18N_LOCALE_DIR}/${language}.json"
  local key
  local encoded

  [[ -f "$catalog" ]] || catalog="${I18N_LOCALE_DIR}/en.json"
  while IFS=$'\t' read -r key encoded; do
    [[ -n "$key" ]] || continue
    I18N_MESSAGES["$key"]="$(printf '%s' "$encoded" | base64 --decode)"
  done < <(python3 - "$catalog" <<'PYTHON'
import base64
import json
import sys

with open(sys.argv[1], encoding="utf-8") as file:
    messages = json.load(file)
for key, value in messages.items():
    encoded = base64.b64encode(value.encode("utf-8")).decode("ascii")
    print(f"{key}\t{encoded}")
PYTHON
  )
  MCSERVER_KIT_ACTIVE_LANG="$(basename "$catalog" .json)"
  export MCSERVER_KIT_ACTIVE_LANG
}

tr() {
  local key="$1"
  shift
  local message="${I18N_MESSAGES[$key]:-$key}"
  # Catalogs are trusted repository files and may contain printf placeholders.
  # shellcheck disable=SC2059
  printf "$message" "$@"
}
