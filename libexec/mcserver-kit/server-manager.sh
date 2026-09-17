#!/usr/bin/env bash
# `tr` is the repository translation helper, and load_messages takes no CLI args.
# shellcheck disable=SC2020,SC2119
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${MCSERVER_KIT_CONFIG:-${HOME}/.config/mcserver-compose-kit/config.yml}"
CONFIG_VALUE="${SCRIPT_DIR}/config-value.py"
CONFIG_TOOL="${SCRIPT_DIR}/server-config.py"
WINDOWS_DIALOG="${SCRIPT_DIR}/windows-dialog.ps1"

# shellcheck source=libexec/mcserver-kit/i18n.sh
source "${SCRIPT_DIR}/i18n.sh"
load_messages

die() {
  printf '%s: %s\n' "$(tr common.error)" "$*" >&2
  exit 1
}

expand_path() {
  local value="$1"
  # This is a literal input prefix, not shell tilde expansion.
  # shellcheck disable=SC2088
  local tilde_prefix='~/'
  value="${value//\$\{HOME\}/$HOME}"
  if [[ "${value:0:2}" == "$tilde_prefix" ]]; then
    value="${HOME}/${value#\~/}"
  fi
  printf '%s' "$value"
}

server_root() {
  local configured
  [[ -f "$CONFIG_FILE" ]] || die "$(tr server.config_missing)"
  configured="$(python3 "$CONFIG_VALUE" get "$CONFIG_FILE" paths server_root 2>/dev/null)" ||
    die "$(tr server.root_missing)"
  expand_path "$configured"
}

validate_server_id() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "$(tr server.invalid_id "$1")"
}

resolve_server_dir() {
  local id="$1"
  local root
  validate_server_id "$id"
  root="$(server_root)"
  [[ -d "${root}/${id}" ]] || die "$(tr server.not_found "$id")"
  [[ -f "${root}/${id}/compose.yaml" ]] || die "$(tr server.compose_missing "$id")"
  printf '%s' "${root}/${id}"
}

list_servers() {
  local root
  local directory
  local found=false
  root="$(server_root)"
  printf '%-28s %s\n' "$(tr server.list_id)" "$(tr server.list_status)"
  if [[ ! -d "$root" ]]; then
    return
  fi
  shopt -s nullglob
  for directory in "$root"/*; do
    [[ -d "$directory" && -f "${directory}/compose.yaml" ]] || continue
    found=true
    printf '%-28s ' "$(basename "$directory")"
    server_state "$directory"
  done
  shopt -u nullglob
  [[ "$found" == true ]] || printf '%s\n' "$(tr server.none)"
}

compose_in() {
  local directory="$1"
  shift
  (
    cd "$directory"
    docker compose "$@"
  )
}

# Compose emits either a JSON array or one object per line, depending on version.
# Keep these machine-readable values separate from the translated menu labels.
container_state() {
  local directory="$1" listing
  if ! listing="$(compose_in "$directory" ps -a --format json 2>/dev/null)"; then
    printf 'unavailable\n'
    return
  fi
  printf '%s\n' "$listing" | python3 -c '
import json
import sys

data = sys.stdin.read().strip()
if not data:
    print("absent")
    sys.exit()
try:
    containers = json.loads(data) if data.startswith("[") else [json.loads(line) for line in data.splitlines()]
except (ValueError, TypeError):
    print("unavailable")
    sys.exit()
minecraft = [c for c in containers if c.get("Service") == "minecraft"]
if any(c.get("State", "").lower() == "running" for c in minecraft):
    print("running")
elif containers:
    print("stopped")
else:
    print("absent")
'
}

server_state() {
  local state
  state="$(container_state "$1")"
  tr "server.state_${state}"
  printf '\n'
}

require_stopped() {
  local directory="$1" running
  running="$(compose_in "$directory" ps --status running --services)" || die "$(tr server.status_failed)"
  [[ -z "$running" ]] || die "$(tr server.stop_before_import)"
}

choose_properties_file() {
  local enabled dialog_path encoded selected
  enabled="$(python3 "$CONFIG_VALUE" get "$CONFIG_FILE" ui windows_dialogs 2>/dev/null || printf true)"
  if [[ "$enabled" == true ]] && command -v wslpath >/dev/null 2>&1 &&
    [[ -x /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe && -f "$WINDOWS_DIALOG" ]]; then
    dialog_path="$(wslpath -w "$WINDOWS_DIALOG")"
    encoded="$(/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe \
      -NoProfile -ExecutionPolicy Bypass -File "$dialog_path" -Mode SelectProperties 2>/dev/null)" || return 1
    encoded="${encoded//$'\r'/}"
    selected="$(printf '%s' "$encoded" | base64 --decode)" || return 1
    wslpath -u "$selected"
    return
  fi
  [[ -t 0 ]] || die "$(tr server.import_usage)"
  read -r -p "$(tr server.import_path_prompt)" selected
  [[ -n "$selected" ]] || return 1
  printf '%s' "$selected"
}

import_properties() {
  local directory="$1" source="${2-}" backup
  require_stopped "$directory"
  if [[ -z "$source" ]]; then
    source="$(choose_properties_file)" || return 0
  fi
  [[ -f "$source" ]] || die "$(tr server.import_source_missing "$source")"
  python3 "$CONFIG_TOOL" validate-properties "$source" || die "$(tr server.import_failed)"
  python3 "$CONFIG_TOOL" migrate "$directory" || die "$(tr server.import_failed)"
  backup="$(python3 "$CONFIG_TOOL" import-properties "$directory" "$source")" || die "$(tr server.import_failed)"
  compose_in "$directory" config --quiet || die "$(tr properties.compose_invalid)"
  [[ -z "$backup" ]] || printf '%s\n' "$(tr server.import_backup "$backup")"
  printf '%s\n' "$(tr server.import_done "${directory}/server.env")"
}

open_folder() {
  local directory="$1" part="${2:-data}" target windows_path output status
  case "$part" in
    data) target="${directory}/data" ;;
    server) target="$directory" ;;
    *) die "$(tr server.open_usage)" ;;
  esac
  [[ -d "$target" ]] || die "$(tr server.open_missing "$target")"
  if ! command -v wslpath >/dev/null 2>&1 || ! command -v explorer.exe >/dev/null 2>&1; then
    die "$(tr server.explorer_unavailable)"
  fi
  windows_path="$(wslpath -w "$target")" || die "$(tr server.explorer_unavailable)"
  # Explorer can return 1 after handing the folder to an existing window.
  # Only accept that status when it supplied no error diagnostics.
  if output="$(explorer.exe "$windows_path" 2>&1)"; then
    return 0
  else
    status=$?
  fi
  [[ "$status" == 1 && -z "$output" ]] && return 0
  [[ -z "$output" ]] || printf '%s\n' "$output" >&2
  die "$(tr server.explorer_unavailable)"
}

manage_server() {
  local id="${1-}"
  local action="${2-}"
  local directory
  [[ -n "$id" && -n "$action" ]] || die "$(tr server.usage)"
  directory="$(resolve_server_dir "$id")"
  shift 2

  case "$action" in
    start)
      printf '%s\n' "$(tr server.validating "$id")"
      compose_in "$directory" config --quiet
      printf '%s\n' "$(tr server.starting "$id")"
      compose_in "$directory" up -d
      compose_in "$directory" ps
      ;;
    stop | shutdown)
      printf '%s\n' "$(tr server.stopping "$id")"
      compose_in "$directory" stop
      ;;
    restart)
      printf '%s\n' "$(tr server.restarting "$id")"
      compose_in "$directory" restart
      compose_in "$directory" ps
      ;;
    status)
      if [[ "$(container_state "$directory")" == absent ]]; then
        tr server.no_containers
      else
        compose_in "$directory" ps -a
      fi
      ;;
    logs)
      if [[ "$(container_state "$directory")" == absent ]]; then
        tr server.no_containers_logs
        return
      fi
      if [[ "${1-}" == '--no-follow' ]]; then
        local log_file result=0
        log_file="$(mktemp /tmp/mcserver-kit-logs.XXXXXX)"
        compose_in "$directory" logs minecraft >"$log_file" || result=$?
        if [[ -s "$log_file" ]]; then
          cat -- "$log_file"
        elif ((result == 0)); then
          tr server.no_logs
        fi
        rm -f -- "$log_file"
        if ((result != 0)); then
          return "$result"
        fi
      else
        compose_in "$directory" logs --follow minecraft
      fi
      ;;
    state)
      if [[ "${1-}" == '--raw' ]]; then
        container_state "$directory"
      else
        server_state "$directory"
      fi
      ;;
    down)
      printf '%s\n' "$(tr server.down "$id")"
      compose_in "$directory" down
      ;;
    properties)
      exec "${SCRIPT_DIR}/server-properties-tui.sh" "$id" "$directory"
      ;;
    import-properties)
      [[ $# -le 1 ]] || die "$(tr server.import_usage)"
      import_properties "$directory" "${1-}"
      ;;
    open)
      [[ $# -le 1 ]] || die "$(tr server.open_usage)"
      open_folder "$directory" "${1:-data}"
      ;;
    *)
      die "$(tr server.unknown_action "$action")"
      ;;
  esac
}

main() {
  case "${1-}" in
    list) list_servers ;;
    server)
      shift
      manage_server "$@"
      ;;
    *) die "$(tr server.manager_usage)" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
