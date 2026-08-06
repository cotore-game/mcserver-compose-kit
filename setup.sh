#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="${MCSERVER_KIT_CONFIG:-${HOME}/.config/mcserver-compose-kit/config.yml}"
TEMPLATE_DIR="${MCSERVER_KIT_MCID_TEMPLATE_DIR:-${HOME}/.config/mcserver-compose-kit/mcid-templates}"

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
      *) printf 'yまたはnを入力してください。\n' >&2 ;;
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
  printf '1行に1つ入力し、空Enterで終了します。\n' >&2
  while true; do
    read -r -p 'MCID: ' line
    [[ -n "$line" ]] || break
    if ! validate_mcid "$line"; then
      printf 'MCIDは英数字と_の3～16文字です。\n' >&2
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

  printf '%s\n' \
    'Minecraft Server Kit 初回設定' \
    '--------------------------------'

  while true; do
    owner_mcid="$(prompt 'OwnerのMinecraft ID')"
    validate_mcid "$owner_mcid" && break
    printf 'MCIDは英数字と_の3～16文字です。\n' >&2
  done

  printf 'Minecraft EULA: https://aka.ms/MinecraftEULA\n'
  accept_eula="$(prompt_bool 'EULAを確認し、同意しますか？' false)"
  whitelist_enabled="$(prompt_bool 'ホワイトリストを有効にしますか？' true)"
  if [[ "$whitelist_enabled" == 'true' ]]; then
    whitelist_ids="$(read_mcid_list 'Owner以外にホワイトリストへ追加するMCIDを入力してください。')"
  fi

  ops_enabled="$(prompt_bool 'OwnerへOPを自動付与しますか？' true)"
  if [[ "$ops_enabled" == 'true' ]]; then
    additional_ops="$(read_mcid_list 'Owner以外にOPを付与するMCIDを入力してください。')"
  fi

  playit_enabled="$(prompt_bool 'Playitを利用しますか？' false)"
  if [[ "$playit_enabled" == 'true' ]]; then
    read -r -s -p 'Playit Secret Key（入力内容は表示されません）: ' playit_secret
    printf '\n'
    [[ -n "$playit_secret" ]] || {
      printf 'Playitを有効にする場合はSecret Keyが必要です。\n' >&2
      exit 1
    }
  fi

  default_version="$(prompt '自動検出できない場合のMinecraftバージョン' '26.2')"
  default_memory="$(prompt 'Javaメモリ' '8G')"
  start_after_creation="$(prompt_bool '作成後すぐ起動する設定をデフォルトにしますか？' false)"
  windows_dialogs="$(prompt_bool 'Windowsのファイル選択・MOTD入力画面を使いますか？' true)"
  server_root="$(prompt 'サーバー作成先' "\${HOME}/minecraftServer")"

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

  printf '\n設定を保存しました。\n'
  printf '  %s\n' "$CONFIG_FILE"
  printf 'MCIDテンプレート:\n  %s\n' "$TEMPLATE_DIR"
  if [[ "$accept_eula" != 'true' ]]; then
    printf '\nEULAへ同意していないため、サーバー作成前に再度setupを実行してください。\n'
  fi
}

main "$@"
