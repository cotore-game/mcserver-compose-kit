#!/usr/bin/env bash
# `tr` is the repository translation helper; literal ${HOME} is stored in config.
# shellcheck disable=SC2016,SC2020,SC2119
set -Eeuo pipefail

CONFIG_FILE="${MCSERVER_KIT_CONFIG:-${HOME}/.config/mcserver-compose-kit/config.yml}"
TEMPLATE_DIR="${MCSERVER_KIT_MCID_TEMPLATE_DIR:-${HOME}/.config/mcserver-compose-kit/mcid-templates}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/i18n.sh
source "${SCRIPT_DIR}/scripts/i18n.sh"
load_messages

prompt() {
  local message="$1"
  local default_value="${2-}"
  local answer

  if [[ -n "$default_value" ]]; then
    read -r -p "${message} [${default_value}]: " answer
    printf '%s' "${answer:-$default_value}"
  else
    read -r -p "${message}: " answer
    printf '%s' "$answer"
  fi
}

prompt_bool() {
  local message="$1"
  local default_value="$2"
  local answer
  local hint='y/N'

  [[ "$default_value" == 'true' ]] && hint='Y/n'
  while true; do
    read -r -p "${message} [${hint}]: " answer
    answer="${answer:-$default_value}"
    case "${answer,,}" in
      y | yes | true | 1)
        printf true
        return
        ;;
      n | no | false | 0)
        printf false
        return
        ;;
      *) tr input.yes_no >&2 ;;
    esac
  done
}

validate_mcid() {
  [[ "$1" =~ ^[A-Za-z0-9_]{3,16}$ ]]
}

yaml_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

read_mcid_list() {
  local message="$1"
  local line
  local result=''

  printf '%s\n' "$message" >&2
  tr input.one_per_line >&2
  printf '\n' >&2
  while true; do
    read -r -p "$(tr input.mcid): " line
    [[ -n "$line" ]] || break
    if ! validate_mcid "$line"; then
      tr input.mcid_rules >&2
      continue
    fi
    result+="${line}"$'\n'
  done
  printf '%s' "$result"
}

main() {
  local owner_mcid
  local accept_eula
  local whitelist_enabled
  local whitelist_ids=''
  local ops_enabled
  local additional_ops=''
  local playit_enabled
  local playit_secret=''
  local default_version
  local default_memory
  local start_after_creation
  local windows_dialogs
  local server_root

  printf '%s\n' "$(tr setup.title)" '--------------------------------'

  while true; do
    owner_mcid="$(prompt "$(tr setup.owner)")"
    validate_mcid "$owner_mcid" && break
    tr input.mcid_rules >&2
  done

  tr setup.eula_url
  printf '\n'
  accept_eula="$(prompt_bool "$(tr setup.eula_accept)" false)"
  whitelist_enabled="$(prompt_bool "$(tr setup.whitelist_enable)" true)"
  if [[ "$whitelist_enabled" == 'true' ]]; then
    whitelist_ids="$(read_mcid_list "$(tr setup.whitelist_ids)")"
  fi

  ops_enabled="$(prompt_bool "$(tr setup.ops_enable)" true)"
  if [[ "$ops_enabled" == 'true' ]]; then
    additional_ops="$(read_mcid_list "$(tr setup.ops_ids)")"
  fi

  playit_enabled="$(prompt_bool "$(tr setup.playit_enable)" false)"
  if [[ "$playit_enabled" == 'true' ]]; then
    read -r -s -p "$(tr setup.playit_secret)" playit_secret
    printf '\n'
    [[ -n "$playit_secret" ]] || {
      tr setup.playit_required >&2
      exit 1
    }
  fi

  default_version="$(prompt "$(tr setup.default_version)" '26.2')"
  default_memory="$(prompt "$(tr setup.memory)" '8G')"
  start_after_creation="$(prompt_bool "$(tr setup.auto_start)" false)"
  windows_dialogs="$(prompt_bool "$(tr setup.windows_dialogs)" true)"
  server_root="$(prompt "$(tr setup.server_root)" '${HOME}/minecraftServer')"

  mkdir -p "$TEMPLATE_DIR" "$(dirname -- "$CONFIG_FILE")"
  {
    printf '%s\n' "\${OWNER}"
    printf '%s' "$additional_ops"
  } >"${TEMPLATE_DIR}/owner.txt"
  {
    printf '%s\n' "\${OWNER}"
    printf '%s' "$whitelist_ids"
  } >"${TEMPLATE_DIR}/default.txt"

  cat >"$CONFIG_FILE" <<CONFIG
setup:
  completed: true

owner:
  minecraft_id: $(yaml_quote "$owner_mcid")

minecraft:
  accept_eula: ${accept_eula}

paths:
  server_root: $(yaml_quote "$server_root")

defaults:
  minecraft_version: $(yaml_quote "$default_version")
  java_memory: $(yaml_quote "$default_memory")
  start_after_creation: ${start_after_creation}
  timezone: "Asia/Tokyo"
  max_players: 8
  online_mode: true
  enable_command_block: true
  allow_flight: true
  spawn_protection: 0
  host_port: 25565

access:
  whitelist_enabled: ${whitelist_enabled}
  whitelist_template: "default"
  ops_enabled: ${ops_enabled}
  ops_template: "owner"

playit:
  enabled: ${playit_enabled}
  secret_key: $(yaml_quote "$playit_secret")
  image: "ghcr.io/playit-cloud/playit-agent:0.17"

docker:
  java_image_tag: "auto"

resource_pack:
  enforce: true

ui:
  windows_dialogs: ${windows_dialogs}
CONFIG

  chmod 600 "$CONFIG_FILE"
  chmod 600 "${TEMPLATE_DIR}/owner.txt" "${TEMPLATE_DIR}/default.txt"

  tr setup.saved
  printf '  %s\n' "$CONFIG_FILE"
  tr setup.templates "$TEMPLATE_DIR"
  if [[ "$accept_eula" != 'true' ]]; then
    tr setup.eula_not_accepted
  fi
  printf '\n'
}

main "$@"
