#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${MCSERVER_KIT_CONFIG:-${HOME}/.config/mcserver-compose-kit/config.yml}"
CONFIG_VALUE="${SCRIPT_DIR}/scripts/config-value.py"

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

expand_path() {
  local value="$1"
  local tilde_prefix='~/'
  value="${value//\$\{HOME\}/$HOME}"
  if [[ "${value:0:2}" == "$tilde_prefix" ]]; then
    value="${HOME}/${value#\~/}"
  fi
  printf '%s' "$value"
}

server_root() {
  local configured
  [[ -f "$CONFIG_FILE" ]] || die "Configuration not found. Run mcserver-kit setup first."
  configured="$(python3 "$CONFIG_VALUE" get "$CONFIG_FILE" paths server_root 2>/dev/null)" ||
    die "paths.server_root is missing from the configuration."
  expand_path "$configured"
}

validate_server_id() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "Invalid server ID: $1"
}

resolve_server_dir() {
  local id="$1"
  local root
  validate_server_id "$id"
  root="$(server_root)"
  [[ -d "${root}/${id}" ]] || die "Server not found: ${id}"
  [[ -f "${root}/${id}/compose.yaml" ]] || die "compose.yaml not found for server: ${id}"
  printf '%s' "${root}/${id}"
}

list_servers() {
  local root
  local directory
  local found=false
  root="$(server_root)"
  printf '%-28s %s\n' 'SERVER ID' 'STATUS'
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
      docker compose ps --status running --services 2>/dev/null | grep -qx minecraft && printf 'running\n' || printf 'stopped\n'
    )
  done
  shopt -u nullglob
  [[ "$found" == true ]] || printf '%s\n' '(no servers)'
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
  [[ -n "$id" && -n "$action" ]] || die "Usage: mcserver-kit server SERVER_ID start|stop|restart|status|logs|down|properties"
  directory="$(resolve_server_dir "$id")"
  shift 2

  case "$action" in
    start)
      printf 'Validating Docker Compose configuration for %s...\n' "$id"
      compose_in "$directory" config --quiet
      printf 'Starting %s...\n' "$id"
      compose_in "$directory" up -d
      compose_in "$directory" ps
      ;;
    stop | shutdown)
      printf 'Stopping %s...\n' "$id"
      compose_in "$directory" stop
      ;;
    restart)
      printf 'Restarting %s...\n' "$id"
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
      printf 'Removing containers and networks for %s. World data is preserved.\n' "$id"
      compose_in "$directory" down
      ;;
    properties)
      exec "${SCRIPT_DIR}/server-properties-tui.sh" "$id" "$directory"
      ;;
    *)
      die "Unknown server action: ${action}"
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
    *) die "Usage: server-manager.sh list | server SERVER_ID ACTION" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
