#!/usr/bin/env bash
# `tr` is the repository translation helper, and load_messages takes no CLI args.
# shellcheck disable=SC2020,SC2119
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${MCSERVER_KIT_CONFIG:-${HOME}/.config/mcserver-compose-kit/config.yml}"
CONFIG_VALUE="${SCRIPT_DIR}/scripts/config-value.py"

# shellcheck source=scripts/i18n.sh
source "${SCRIPT_DIR}/scripts/i18n.sh"
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
    (
      cd "$directory"
      docker compose ps --status running --services 2>/dev/null | grep -qx minecraft && printf '%s\n' "$(tr server.running)" || printf '%s\n' "$(tr server.stopped)"
    )
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
      compose_in "$directory" ps
      ;;
    logs)
      if [[ "${1-}" == '--no-follow' ]]; then
        compose_in "$directory" logs minecraft
      else
        compose_in "$directory" logs --follow minecraft
      fi
      ;;
    down)
      printf '%s\n' "$(tr server.down "$id")"
      compose_in "$directory" down
      ;;
    properties)
      exec "${SCRIPT_DIR}/server-properties-tui.sh" "$id" "$directory"
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
