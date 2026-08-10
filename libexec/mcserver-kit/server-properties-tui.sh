#!/usr/bin/env bash
# `tr` is the repository translation helper, and load_messages takes no CLI args.
# shellcheck disable=SC2020,SC2119
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVER_ID="${1-}"
SERVER_DIR="${2-}"
SERVER_ENV="${SERVER_DIR}/server.env"
CONFIG_TOOL="${SCRIPT_DIR}/server-config.py"
changed=false

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

die() {
  printf '%s: %s\n' "$(tr common.error)" "$*" >&2
  exit 1
}

setting_get() {
  python3 "$CONFIG_TOOL" get "$SERVER_ENV" "$1" "$2"
}

setting_set() {
  python3 "$CONFIG_TOOL" set "$SERVER_ENV" "$1" "$2"
  changed=true
}

edit_boolean() {
  local key="$1" label="$2" current="$3" selected
  selected="$(whiptail --title "$label" --radiolist "$label" 12 64 2 \
    true "$(tr properties.enabled)" "$([[ "${current,,}" == true ]] && printf ON || printf OFF)" \
    false "$(tr properties.disabled)" "$([[ "${current,,}" == false ]] && printf ON || printf OFF)" \
    3>&1 1>&2 2>&3)" || return
  setting_set "$key" "$selected"
}

edit_choice() {
  local key="$1" label="$2" current="$3" value
  shift 3
  local items=()
  for value in "$@"; do
    items+=("$value" "$([[ "$value" == "$current" ]] && tr properties.selected || printf ' ')")
  done
  value="$(whiptail --title "$label" --menu "$label" 17 72 9 "${items[@]}" 3>&1 1>&2 2>&3)" || return
  setting_set "$key" "$value"
}

edit_number() {
  local key="$1" label="$2" current="$3" minimum="$4" maximum="$5" value
  while true; do
    value="$(whiptail --title "$label" --inputbox "$label (${minimum}-${maximum})" 10 68 "$current" 3>&1 1>&2 2>&3)" || return
    if [[ "$value" =~ ^[0-9]+$ ]] && ((value >= minimum && value <= maximum)); then
      setting_set "$key" "$value"
      return
    fi
    whiptail --msgbox "$(tr properties.number_range "$minimum" "$maximum")" 8 64
  done
}

edit_text() {
  local key="$1" label="$2" current="$3" value
  value="$(whiptail --title "$label" --inputbox "$label" 11 76 "$current" 3>&1 1>&2 2>&3)" || return
  setting_set "$key" "$value"
}

edit_mcid_list() {
  local key="$1" label="$2" current value normalized entry
  local entries=()
  current="$(setting_get "$key" '')"
  while true; do
    value="$(whiptail --title "$label" --inputbox "$(tr properties.mcid_list_hint)" 11 76 "$current" 3>&1 1>&2 2>&3)" || return
    normalized=''
    IFS=',' read -ra entries <<<"$value"
    for entry in "${entries[@]}"; do
      entry="${entry#"${entry%%[![:space:]]*}"}"
      entry="${entry%"${entry##*[![:space:]]}"}"
      [[ -z "$entry" ]] && continue
      if [[ ! "$entry" =~ ^[A-Za-z0-9_]{3,16}$ ]]; then
        whiptail --msgbox "$(tr properties.mcid_list_invalid "$entry")" 8 68
        normalized='!invalid!'
        break
      fi
      [[ -z "$normalized" ]] || normalized+=','
      normalized+="$entry"
    done
    [[ "$normalized" == '!invalid!' ]] && continue
    setting_set "$key" "$normalized"
    return
  done
}

edit_url() {
  local current value
  current="$(setting_get RESOURCE_PACK '')"
  while true; do
    value="$(whiptail --title "$(tr properties.resource_pack_url)" --inputbox "$(tr properties.resource_pack_url_hint)" 11 76 "$current" 3>&1 1>&2 2>&3)" || return
    if [[ -z "$value" || "$value" =~ ^https:// ]]; then
      setting_set RESOURCE_PACK "$value"
      return
    fi
    whiptail --msgbox "$(tr properties.resource_pack_url_invalid)" 8 68
  done
}

edit_uuid() {
  local current value
  current="$(setting_get RESOURCE_PACK_ID '')"
  while true; do
    value="$(whiptail --title "$(tr properties.resource_pack_id)" --inputbox "$(tr properties.resource_pack_id_hint)" 11 76 "$current" 3>&1 1>&2 2>&3)" || return
    if [[ -z "$value" || "$value" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
      setting_set RESOURCE_PACK_ID "${value,,}"
      return
    fi
    whiptail --msgbox "$(tr properties.resource_pack_id_invalid)" 8 68
  done
}

edit_sha1() {
  local current value
  current="$(setting_get RESOURCE_PACK_SHA1 '')"
  while true; do
    value="$(whiptail --title "$(tr properties.resource_pack_sha1)" --inputbox "$(tr properties.resource_pack_sha1_hint)" 11 76 "$current" 3>&1 1>&2 2>&3)" || return
    if [[ -z "$value" || "$value" =~ ^[0-9a-fA-F]{40}$ ]]; then
      setting_set RESOURCE_PACK_SHA1 "${value,,}"
      return
    fi
    whiptail --msgbox "$(tr properties.resource_pack_sha1_invalid)" 8 64
  done
}

edit_property() {
  local key="$1"
  case "$key" in
    MOTD) edit_text "$key" "$(tr properties.motd)" "$(setting_get "$key" 'A Minecraft Server')" ;;
    DIFFICULTY) edit_choice "$key" "$(tr properties.difficulty)" "$(setting_get "$key" easy)" peaceful easy normal hard ;;
    MODE) edit_choice "$key" "$(tr properties.gamemode)" "$(setting_get "$key" survival)" survival creative adventure spectator ;;
    FORCE_GAMEMODE) edit_boolean "$key" "$(tr properties.force_gamemode)" "$(setting_get "$key" false)" ;;
    HARDCORE) edit_boolean "$key" "$(tr properties.hardcore)" "$(setting_get "$key" false)" ;;
    PVP) edit_boolean "$key" "$(tr properties.pvp)" "$(setting_get "$key" true)" ;;
    MAX_PLAYERS) edit_number "$key" "$(tr properties.max_players)" "$(setting_get "$key" 8)" 1 1000 ;;
    ONLINE_MODE) edit_boolean "$key" "$(tr properties.online_mode)" "$(setting_get "$key" true)" ;;
    ALLOW_FLIGHT) edit_boolean "$key" "$(tr properties.allow_flight)" "$(setting_get "$key" true)" ;;
    ENABLE_COMMAND_BLOCK) edit_boolean "$key" "$(tr properties.command_block)" "$(setting_get "$key" true)" ;;
    SPAWN_PROTECTION) edit_number "$key" "$(tr properties.spawn_protection)" "$(setting_get "$key" 0)" 0 128 ;;
    VIEW_DISTANCE) edit_number "$key" "$(tr properties.view_distance)" "$(setting_get "$key" 10)" 3 32 ;;
    SIMULATION_DISTANCE) edit_number "$key" "$(tr properties.simulation_distance)" "$(setting_get "$key" 10)" 3 32 ;;
    PLAYER_IDLE_TIMEOUT) edit_number "$key" "$(tr properties.idle_timeout)" "$(setting_get "$key" 0)" 0 1440 ;;
    ALLOW_NETHER) edit_boolean "$key" "$(tr properties.allow_nether)" "$(setting_get "$key" true)" ;;
    SPAWN_ANIMALS) edit_boolean "$key" "$(tr properties.spawn_animals)" "$(setting_get "$key" true)" ;;
    SPAWN_MONSTERS) edit_boolean "$key" "$(tr properties.spawn_monsters)" "$(setting_get "$key" true)" ;;
    SPAWN_NPCS) edit_boolean "$key" "$(tr properties.spawn_npcs)" "$(setting_get "$key" true)" ;;
    ENABLE_STATUS) edit_boolean "$key" "$(tr properties.enable_status)" "$(setting_get "$key" true)" ;;
    HIDE_ONLINE_PLAYERS) edit_boolean "$key" "$(tr properties.hide_online_players)" "$(setting_get "$key" false)" ;;
    MAX_TICK_TIME) edit_number "$key" "$(tr properties.max_tick_time)" "$(setting_get "$key" 60000)" 0 2147483647 ;;
    ENABLE_WHITELIST) edit_boolean "$key" "$(tr properties.whitelist_enable)" "$(setting_get "$key" false)" ;;
    WHITELIST) edit_mcid_list "$key" "$(tr properties.whitelist_members)" ;;
    EXISTING_WHITELIST_FILE) edit_choice "$key" "$(tr properties.whitelist_mode)" "$(setting_get "$key" SYNC_FILE_MERGE_LIST)" SKIP MERGE SYNCHRONIZE SYNC_FILE_MERGE_LIST ;;
    OPS) edit_mcid_list "$key" "$(tr properties.ops_members)" ;;
    EXISTING_OPS_FILE) edit_choice "$key" "$(tr properties.ops_mode)" "$(setting_get "$key" SYNC_FILE_MERGE_LIST)" SKIP MERGE SYNCHRONIZE SYNC_FILE_MERGE_LIST ;;
    RESOURCE_PACK) edit_url ;;
    RESOURCE_PACK_SHA1) edit_sha1 ;;
    RESOURCE_PACK_ID) edit_uuid ;;
    RESOURCE_PACK_ENFORCE) edit_boolean "$key" "$(tr properties.resource_pack_enforce)" "$(setting_get "$key" true)" ;;
  esac
}

menu_item() {
  printf '%s' "$(tr properties.current "$1" "$2")"
}

finish() {
  [[ "$changed" == true ]] || return
  (cd "$SERVER_DIR" && docker compose config --quiet) || die "$(tr properties.compose_invalid)"
  if whiptail --yesno "$(tr properties.restart_prompt "$SERVER_ID")" 10 72; then
    printf '%s\n' "$(tr properties.applying "$SERVER_ID")"
    (cd "$SERVER_DIR" && docker compose up -d --force-recreate)
  else
    printf '%s\n' "$(tr properties.saved_restart_later)"
  fi
}

main() {
  local selected
  local items
  command -v whiptail >/dev/null 2>&1 || die "$(tr properties.whiptail_missing)"
  [[ -f "${SERVER_DIR}/compose.yaml" ]] || die "$(tr server.compose_missing "$SERVER_ID")"

  if [[ ! -f "$SERVER_ENV" ]]; then
    whiptail --yesno "$(tr properties.migration_prompt)" 11 76 || return
  fi
  python3 "$CONFIG_TOOL" migrate "$SERVER_DIR"
  (cd "$SERVER_DIR" && docker compose config --quiet) || die "$(tr properties.compose_invalid)"

  while true; do
    items=(
      MOTD "$(menu_item "$(tr properties.motd)" "$(setting_get MOTD 'A Minecraft Server')")"
      DIFFICULTY "$(menu_item "$(tr properties.difficulty)" "$(setting_get DIFFICULTY easy)")"
      MODE "$(menu_item "$(tr properties.gamemode)" "$(setting_get MODE survival)")"
      MAX_PLAYERS "$(menu_item "$(tr properties.max_players)" "$(setting_get MAX_PLAYERS 8)")"
      ONLINE_MODE "$(menu_item "$(tr properties.online_mode)" "$(setting_get ONLINE_MODE true)")"
      ENABLE_WHITELIST "$(menu_item "$(tr properties.whitelist_enable)" "$(setting_get ENABLE_WHITELIST false)")"
      WHITELIST "$(menu_item "$(tr properties.whitelist_members)" "$(setting_get WHITELIST '')")"
      EXISTING_WHITELIST_FILE "$(menu_item "$(tr properties.whitelist_mode)" "$(setting_get EXISTING_WHITELIST_FILE SYNC_FILE_MERGE_LIST)")"
      OPS "$(menu_item "$(tr properties.ops_members)" "$(setting_get OPS '')")"
      EXISTING_OPS_FILE "$(menu_item "$(tr properties.ops_mode)" "$(setting_get EXISTING_OPS_FILE SYNC_FILE_MERGE_LIST)")"
      ALLOW_FLIGHT "$(menu_item "$(tr properties.allow_flight)" "$(setting_get ALLOW_FLIGHT true)")"
      ENABLE_COMMAND_BLOCK "$(menu_item "$(tr properties.command_block)" "$(setting_get ENABLE_COMMAND_BLOCK true)")"
      PVP "$(menu_item "$(tr properties.pvp)" "$(setting_get PVP true)")"
      VIEW_DISTANCE "$(menu_item "$(tr properties.view_distance)" "$(setting_get VIEW_DISTANCE 10)")"
      SIMULATION_DISTANCE "$(menu_item "$(tr properties.simulation_distance)" "$(setting_get SIMULATION_DISTANCE 10)")"
      __more "$(tr properties.more_settings)"
      __resource "$(tr properties.resource_pack_settings)"
      __exit "$(tr properties.exit)"
    )
    selected="$(whiptail --title "${SERVER_ID}" --menu "$(tr properties.choose)" 25 94 18 "${items[@]}" 3>&1 1>&2 2>&3)" || break
    case "$selected" in
      __exit) break ;;
      __more)
        selected="$(whiptail --title "${SERVER_ID}" --menu "$(tr properties.more_settings)" 24 90 15 \
          FORCE_GAMEMODE "$(menu_item "$(tr properties.force_gamemode)" "$(setting_get FORCE_GAMEMODE false)")" \
          HARDCORE "$(menu_item "$(tr properties.hardcore)" "$(setting_get HARDCORE false)")" \
          SPAWN_PROTECTION "$(menu_item "$(tr properties.spawn_protection)" "$(setting_get SPAWN_PROTECTION 0)")" \
          PLAYER_IDLE_TIMEOUT "$(menu_item "$(tr properties.idle_timeout)" "$(setting_get PLAYER_IDLE_TIMEOUT 0)")" \
          ALLOW_NETHER "$(menu_item "$(tr properties.allow_nether)" "$(setting_get ALLOW_NETHER true)")" \
          SPAWN_ANIMALS "$(menu_item "$(tr properties.spawn_animals)" "$(setting_get SPAWN_ANIMALS true)")" \
          SPAWN_MONSTERS "$(menu_item "$(tr properties.spawn_monsters)" "$(setting_get SPAWN_MONSTERS true)")" \
          SPAWN_NPCS "$(menu_item "$(tr properties.spawn_npcs)" "$(setting_get SPAWN_NPCS true)")" \
          ENABLE_STATUS "$(menu_item "$(tr properties.enable_status)" "$(setting_get ENABLE_STATUS true)")" \
          HIDE_ONLINE_PLAYERS "$(menu_item "$(tr properties.hide_online_players)" "$(setting_get HIDE_ONLINE_PLAYERS false)")" \
          MAX_TICK_TIME "$(menu_item "$(tr properties.max_tick_time)" "$(setting_get MAX_TICK_TIME 60000)")" \
          3>&1 1>&2 2>&3)" || continue
        edit_property "$selected"
        ;;
      __resource)
        selected="$(whiptail --title "${SERVER_ID}" --menu "$(tr properties.resource_pack_settings)" 18 90 6 \
          RESOURCE_PACK "$(menu_item "$(tr properties.resource_pack_url)" "$(setting_get RESOURCE_PACK '')")" \
          RESOURCE_PACK_SHA1 "$(menu_item "$(tr properties.resource_pack_sha1)" "$(setting_get RESOURCE_PACK_SHA1 '')")" \
          RESOURCE_PACK_ID "$(menu_item "$(tr properties.resource_pack_id)" "$(setting_get RESOURCE_PACK_ID '')")" \
          RESOURCE_PACK_ENFORCE "$(menu_item "$(tr properties.resource_pack_enforce)" "$(setting_get RESOURCE_PACK_ENFORCE true)")" \
          3>&1 1>&2 2>&3)" || continue
        edit_property "$selected"
        ;;
      *) edit_property "$selected" ;;
    esac
  done
  finish
}

main "$@"
