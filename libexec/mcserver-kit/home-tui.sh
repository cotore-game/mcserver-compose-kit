#!/usr/bin/env bash
# `tr` is the repository translation helper, and load_messages takes no CLI args.
# shellcheck disable=SC2020,SC2119
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${MCSERVER_KIT_CONFIG:-${HOME}/.config/mcserver-compose-kit/config.yml}"
ROOT_DIR="${MCSERVER_KIT_ROOT:-$(cd -- "${SCRIPT_DIR}/../.." && pwd)}"
CONFIG_VALUE="${SCRIPT_DIR}/config-value.py"
VERSION="$(head -n 1 "${ROOT_DIR}/VERSION" 2>/dev/null || printf unknown)"
TEMP_FILES=()

# shellcheck source=libexec/mcserver-kit/i18n.sh
source "${SCRIPT_DIR}/i18n.sh"
load_messages

if [[ -z "${NEWT_COLORS:-}" ]]; then
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
fi

cleanup() {
  local path
  for path in "${TEMP_FILES[@]}"; do
    [[ -f "$path" ]] && rm -f -- "$path"
  done
}
trap cleanup EXIT

new_temp_file() {
  local variable_name="$1" path
  path="$(mktemp /tmp/mcserver-kit-tui.XXXXXX)"
  TEMP_FILES+=("$path")
  printf -v "$variable_name" '%s' "$path"
}

server_root() {
  local configured
  configured="$(python3 "$CONFIG_VALUE" get "$CONFIG_FILE" paths server_root 2>/dev/null || printf '%s' "\${HOME}/minecraftServer")"
  configured="${configured//\$\{HOME\}/$HOME}"
  if [[ "${configured:0:1}" == '~' && "${configured:1:1}" == / ]]; then
    configured="${HOME}/${configured#\~/}"
  fi
  printf '%s' "$configured"
}

tool_availability() {
  if command -v "$1" >/dev/null 2>&1; then
    tr home.available
  else
    tr home.unavailable
  fi
}

server_status() {
  local directory="$1"
  if (cd "$directory" && docker compose ps --status running --services 2>/dev/null | grep -qx minecraft); then
    tr home.running
  else
    tr home.stopped
  fi
}

logo() {
  local columns=80
  columns="$(tput cols 2>/dev/null || printf 80)"
  if ((columns < 76)); then
    printf '%s\n' 'mcserver-kit' 'Minecraft Server Kit'
  else
    cat <<'LOGO'
 __  __  ____ ____  _____ ______     _______ ____
|  \/  |/ ___/ ___|| ____|  _ \ \   / / ____|  _ \
| |\/| | |   \___ \|  _| | |_) \ \ / /|  _| | |_) |
| |  | | |___ ___) | |___|  _ < \ V / | |___|  _ <
|_|  |_|\____|____/|_____|_| \_\ \_/  |_____|_| \_\
LOGO
  fi
}

dashboard_text() {
  local root="$1"
  local total=0 running=0 directory
  if [[ -d "$root" ]]; then
    shopt -s nullglob
    for directory in "$root"/*; do
      [[ -d "$directory" && -f "${directory}/compose.yaml" ]] || continue
      total=$((total + 1))
      if (cd "$directory" && docker compose ps --status running --services 2>/dev/null | grep -qx minecraft); then
        running=$((running + 1))
      fi
    done
    shopt -u nullglob
  fi
  logo
  printf '\n%s\n%s\n%s\n' "$(tr home.version "$VERSION")" "$(tr home.summary "$total" "$running")" "$(tr home.choose)"
}

pause_for_enter() {
  printf '\n%s' "$(tr home.press_enter)"
  read -r _ || true
}

run_and_show() {
  local title="$1"
  shift
  local output
  new_temp_file output
  if "$@" >"$output" 2>&1; then
    whiptail --title "$title" --textbox "$output" 22 84
  else
    whiptail --title "$(tr common.error)" --textbox "$output" 22 84
  fi
}

server_action_menu() {
  local id="$1" directory="$2" choice
  while true; do
    choice="$(whiptail --title "$id" --menu "$(tr home.server_status "$(server_status "$directory")")" 21 78 11 \
      start "$(tr home.start)" \
      stop "$(tr home.stop)" \
      restart "$(tr home.restart)" \
      status "$(tr home.status)" \
      logs "$(tr home.logs)" \
      properties "$(tr home.properties)" \
      down "$(tr home.down)" \
      back "$(tr tui.back)" \
      3>&1 1>&2 2>&3)" || return
    case "$choice" in
      start | stop | restart | status)
        run_and_show "$id" "${SCRIPT_DIR}/server-manager.sh" server "$id" "$choice"
        ;;
      logs)
        clear
        "${SCRIPT_DIR}/server-manager.sh" server "$id" logs || true
        pause_for_enter
        ;;
      properties)
        "${SCRIPT_DIR}/server-manager.sh" server "$id" properties || true
        ;;
      down)
        if whiptail --yesno "$(tr home.down_confirm "$id")" 10 72; then
          run_and_show "$id" "${SCRIPT_DIR}/server-manager.sh" server "$id" down
        fi
        ;;
      back) return ;;
    esac
  done
}

servers_menu() {
  local root directory id selected
  local items=()
  root="$(server_root)"
  while true; do
    items=()
    if [[ -d "$root" ]]; then
      shopt -s nullglob
      for directory in "$root"/*; do
        [[ -d "$directory" && -f "${directory}/compose.yaml" ]] || continue
        id="$(basename "$directory")"
        items+=("$id" "$(server_status "$directory")")
      done
      shopt -u nullglob
    fi
    items+=(__back "$(tr tui.back)")
    selected="$(whiptail --title "$(tr home.servers)" --menu "$(tr home.select_server)" 23 82 15 "${items[@]}" 3>&1 1>&2 2>&3)" || return
    [[ "$selected" == __back ]] && return
    server_action_menu "$selected" "${root}/${selected}"
  done
}

language_menu() {
  local current selected
  current="${MCSERVER_KIT_ACTIVE_LANG:-en}"
  selected="$(whiptail --title "$(tr home.language)" --radiolist "$(tr home.language_choose)" 13 66 2 \
    en English "$([[ "$current" == en ]] && printf ON || printf OFF)" \
    ja '日本語' "$([[ "$current" == ja ]] && printf ON || printf OFF)" \
    3>&1 1>&2 2>&3)" || return
  "${SCRIPT_DIR}/lang.sh" "--${selected}" >/dev/null
  I18N_MESSAGES=()
  load_messages "$selected"
}

diagnostics() {
  local output root server_count=0
  new_temp_file output
  root="$(server_root)"
  if [[ -d "$root" ]]; then
    server_count="$(find "$root" -mindepth 2 -maxdepth 2 -type f -name compose.yaml -printf . 2>/dev/null | wc -c)"
  fi
  {
    printf '%s\n' "$(tr home.diagnostics_title)" '--------------------------------'
    printf '%-24s %s\n' Docker "$(tool_availability docker)"
    printf '%-24s %s\n' 'Docker Compose' "$(docker compose version --short 2>/dev/null || tr home.unavailable)"
    printf '%-24s %s\n' Python "$(python3 --version 2>&1 || tr home.unavailable)"
    printf '%-24s %s\n' whiptail "$(tool_availability whiptail)"
    printf '%-24s %s\n' "$(tr home.configuration)" "$CONFIG_FILE"
    printf '%-24s %s\n' "$(tr home.server_root)" "$root"
    printf '%-24s %s\n' "$(tr home.server_count)" "$server_count"
  } >"$output"
  whiptail --title "$(tr home.diagnostics)" --textbox "$output" 22 90
}

main() {
  local root choice
  command -v whiptail >/dev/null 2>&1 || {
    tr tui.missing >&2
    exit 1
  }
  [[ "${MCSERVER_KIT_TUI_TEST:-false}" == true || (-t 0 && -t 1) ]] || {
    printf '%s\n' "$(tr home.tty_required)" >&2
    exit 2
  }
  root="$(server_root)"
  while true; do
    choice="$(whiptail --backtitle "mcserver-kit ${VERSION}" --title 'Minecraft Server Kit' --menu "$(dashboard_text "$root")" 27 94 9 \
      servers "$(tr home.servers)" \
      create "$(tr home.create)" \
      config "$(tr home.config)" \
      templates "$(tr home.templates)" \
      language "$(tr home.language)" \
      diagnostics "$(tr home.diagnostics)" \
      help "$(tr home.help)" \
      exit "$(tr home.exit)" \
      3>&1 1>&2 2>&3)" || return
    case "$choice" in
      servers) servers_menu ;;
      create)
        clear
        "${SCRIPT_DIR}/create-server.sh" || true
        pause_for_enter
        ;;
      config) "${SCRIPT_DIR}/config-tui.sh" || true ;;
      templates) "${SCRIPT_DIR}/config-tui.sh" templates || true ;;
      language) language_menu ;;
      diagnostics) diagnostics ;;
      help) run_and_show "$(tr home.help)" "${ROOT_DIR}/mcserver-kit" --help ;;
      exit) return ;;
    esac
  done
}

main "$@"
