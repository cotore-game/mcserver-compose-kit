#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVER_ID="${1-}"
SERVER_DIR="${2-}"
PROPERTIES_FILE="${SERVER_DIR}/data/server.properties"
PROPERTY_TOOL="${SCRIPT_DIR}/scripts/server-property.py"

# shellcheck source=scripts/i18n.sh
source "${SCRIPT_DIR}/scripts/i18n.sh"
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

property_get() {
  python3 "$PROPERTY_TOOL" get "$PROPERTIES_FILE" "$1" 2>/dev/null || printf '%s' "$2"
}

property_set() {
  python3 "$PROPERTY_TOOL" set "$PROPERTIES_FILE" "$1" "$2"
}

edit_boolean() {
  local key="$1"
  local label="$2"
  local current="$3"
  local selected
  selected="$(whiptail --title "$label" --radiolist "$label" 12 64 2 \
    true "$(tr properties.enabled)" "$([[ "$current" == true ]] && printf ON || printf OFF)" \
    false "$(tr properties.disabled)" "$([[ "$current" == false ]] && printf ON || printf OFF)" \
    3>&1 1>&2 2>&3)" || return
  property_set "$key" "$selected"
}

edit_choice() {
  local key="$1"
  local label="$2"
  local current="$3"
  shift 3
  local items=()
  local value
  for value in "$@"; do
    items+=("$value" "$([[ "$value" == "$current" ]] && printf '(current)' || printf ' ')")
  done
  value="$(whiptail --title "$label" --menu "$label" 16 64 8 "${items[@]}" 3>&1 1>&2 2>&3)" || return
  property_set "$key" "$value"
}

edit_number() {
  local key="$1"
  local label="$2"
  local current="$3"
  local minimum="$4"
  local maximum="$5"
  local value
  while true; do
    value="$(whiptail --title "$label" --inputbox "$label (${minimum}-${maximum})" 10 64 "$current" 3>&1 1>&2 2>&3)" || return
    if [[ "$value" =~ ^[0-9]+$ ]] && ((value >= minimum && value <= maximum)); then
      property_set "$key" "$value"
      return
    fi
    whiptail --msgbox "$(tr properties.number_range "$minimum" "$maximum")" 8 60
  done
}

edit_property() {
  local key="$1"
  local current
  case "$key" in
    difficulty)
      current="$(property_get "$key" easy)"
      edit_choice "$key" "$(tr properties.difficulty)" "$current" peaceful easy normal hard
      ;;
    gamemode)
      current="$(property_get "$key" survival)"
      edit_choice "$key" "$(tr properties.gamemode)" "$current" survival creative adventure spectator
      ;;
    force-gamemode) edit_boolean "$key" "$(tr properties.force_gamemode)" "$(property_get "$key" false)" ;;
    hardcore) edit_boolean "$key" "$(tr properties.hardcore)" "$(property_get "$key" false)" ;;
    pvp) edit_boolean "$key" "$(tr properties.pvp)" "$(property_get "$key" true)" ;;
    allow-nether) edit_boolean "$key" "$(tr properties.allow_nether)" "$(property_get "$key" true)" ;;
    spawn-animals) edit_boolean "$key" "$(tr properties.spawn_animals)" "$(property_get "$key" true)" ;;
    spawn-monsters) edit_boolean "$key" "$(tr properties.spawn_monsters)" "$(property_get "$key" true)" ;;
    spawn-npcs) edit_boolean "$key" "$(tr properties.spawn_npcs)" "$(property_get "$key" true)" ;;
    enable-status) edit_boolean "$key" "$(tr properties.enable_status)" "$(property_get "$key" true)" ;;
    hide-online-players) edit_boolean "$key" "$(tr properties.hide_online_players)" "$(property_get "$key" false)" ;;
    view-distance) edit_number "$key" "$(tr properties.view_distance)" "$(property_get "$key" 10)" 3 32 ;;
    simulation-distance) edit_number "$key" "$(tr properties.simulation_distance)" "$(property_get "$key" 10)" 3 32 ;;
    player-idle-timeout) edit_number "$key" "$(tr properties.idle_timeout)" "$(property_get "$key" 0)" 0 1440 ;;
    max-tick-time) edit_number "$key" "$(tr properties.max_tick_time)" "$(property_get "$key" 60000)" 0 2147483647 ;;
  esac
}

main() {
  local selected
  local items
  command -v whiptail >/dev/null 2>&1 || die "$(tr properties.whiptail_missing)"
  [[ -f "$PROPERTIES_FILE" ]] || die "$(tr properties.file_missing)"
  if (cd "$SERVER_DIR" && docker compose ps --status running --services 2>/dev/null | grep -qx minecraft); then
    die "$(tr properties.stop_first "$SERVER_ID")"
  fi

  while true; do
    items=(
      difficulty "$(tr properties.current "$(tr properties.difficulty)" "$(property_get difficulty easy)")"
      gamemode "$(tr properties.current "$(tr properties.gamemode)" "$(property_get gamemode survival)")"
      force-gamemode "$(tr properties.current "$(tr properties.force_gamemode)" "$(property_get force-gamemode false)")"
      hardcore "$(tr properties.current "$(tr properties.hardcore)" "$(property_get hardcore false)")"
      pvp "$(tr properties.current "$(tr properties.pvp)" "$(property_get pvp true)")"
      view-distance "$(tr properties.current "$(tr properties.view_distance)" "$(property_get view-distance 10)")"
      simulation-distance "$(tr properties.current "$(tr properties.simulation_distance)" "$(property_get simulation-distance 10)")"
      player-idle-timeout "$(tr properties.current "$(tr properties.idle_timeout)" "$(property_get player-idle-timeout 0)")"
      allow-nether "$(tr properties.current "$(tr properties.allow_nether)" "$(property_get allow-nether true)")"
      spawn-animals "$(tr properties.current "$(tr properties.spawn_animals)" "$(property_get spawn-animals true)")"
      spawn-monsters "$(tr properties.current "$(tr properties.spawn_monsters)" "$(property_get spawn-monsters true)")"
      spawn-npcs "$(tr properties.current "$(tr properties.spawn_npcs)" "$(property_get spawn-npcs true)")"
      enable-status "$(tr properties.current "$(tr properties.enable_status)" "$(property_get enable-status true)")"
      hide-online-players "$(tr properties.current "$(tr properties.hide_online_players)" "$(property_get hide-online-players false)")"
      max-tick-time "$(tr properties.current "$(tr properties.max_tick_time)" "$(property_get max-tick-time 60000)")"
      __exit "$(tr properties.exit)"
    )
    selected="$(whiptail --title "${SERVER_ID} server.properties" --menu "$(tr properties.choose)" 24 84 16 "${items[@]}" 3>&1 1>&2 2>&3)" || return
    [[ "$selected" == __exit ]] && return
    edit_property "$selected"
  done
}

main "$@"
