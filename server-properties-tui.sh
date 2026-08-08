#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVER_ID="${1-}"
SERVER_DIR="${2-}"
PROPERTIES_FILE="${SERVER_DIR}/data/server.properties"
PROPERTY_TOOL="${SCRIPT_DIR}/scripts/server-property.py"

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
  printf 'Error: %s\n' "$*" >&2
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
    true 'Enabled' "$([[ "$current" == true ]] && printf ON || printf OFF)" \
    false 'Disabled' "$([[ "$current" == false ]] && printf ON || printf OFF)" \
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
    whiptail --msgbox "Enter a number from ${minimum} to ${maximum}." 8 60
  done
}

edit_property() {
  local key="$1"
  local current
  case "$key" in
    difficulty)
      current="$(property_get "$key" easy)"
      edit_choice "$key" 'Difficulty' "$current" peaceful easy normal hard
      ;;
    gamemode)
      current="$(property_get "$key" survival)"
      edit_choice "$key" 'Game mode' "$current" survival creative adventure spectator
      ;;
    force-gamemode) edit_boolean "$key" 'Force game mode' "$(property_get "$key" false)" ;;
    hardcore) edit_boolean "$key" 'Hardcore' "$(property_get "$key" false)" ;;
    pvp) edit_boolean "$key" 'PvP' "$(property_get "$key" true)" ;;
    allow-nether) edit_boolean "$key" 'Allow Nether' "$(property_get "$key" true)" ;;
    spawn-animals) edit_boolean "$key" 'Spawn animals' "$(property_get "$key" true)" ;;
    spawn-monsters) edit_boolean "$key" 'Spawn monsters' "$(property_get "$key" true)" ;;
    spawn-npcs) edit_boolean "$key" 'Spawn NPCs' "$(property_get "$key" true)" ;;
    enable-status) edit_boolean "$key" 'Show server status' "$(property_get "$key" true)" ;;
    hide-online-players) edit_boolean "$key" 'Hide online players' "$(property_get "$key" false)" ;;
    view-distance) edit_number "$key" 'View distance' "$(property_get "$key" 10)" 3 32 ;;
    simulation-distance) edit_number "$key" 'Simulation distance' "$(property_get "$key" 10)" 3 32 ;;
    player-idle-timeout) edit_number "$key" 'Idle timeout (minutes)' "$(property_get "$key" 0)" 0 1440 ;;
    max-tick-time) edit_number "$key" 'Maximum tick time (ms)' "$(property_get "$key" 60000)" 0 2147483647 ;;
  esac
}

main() {
  local selected
  local items
  command -v whiptail >/dev/null 2>&1 || die 'whiptail is required.'
  [[ -f "$PROPERTIES_FILE" ]] || die 'server.properties does not exist yet. Start the server once, then stop it before editing.'
  if (cd "$SERVER_DIR" && docker compose ps --status running --services 2>/dev/null | grep -qx minecraft); then
    die "Stop ${SERVER_ID} before editing server.properties."
  fi

  while true; do
    items=(
      difficulty "Difficulty: $(property_get difficulty easy)"
      gamemode "Game mode: $(property_get gamemode survival)"
      force-gamemode "Force game mode: $(property_get force-gamemode false)"
      hardcore "Hardcore: $(property_get hardcore false)"
      pvp "PvP: $(property_get pvp true)"
      view-distance "View distance: $(property_get view-distance 10)"
      simulation-distance "Simulation distance: $(property_get simulation-distance 10)"
      player-idle-timeout "Idle timeout: $(property_get player-idle-timeout 0)"
      allow-nether "Allow Nether: $(property_get allow-nether true)"
      spawn-animals "Spawn animals: $(property_get spawn-animals true)"
      spawn-monsters "Spawn monsters: $(property_get spawn-monsters true)"
      spawn-npcs "Spawn NPCs: $(property_get spawn-npcs true)"
      enable-status "Show server status: $(property_get enable-status true)"
      hide-online-players "Hide online players: $(property_get hide-online-players false)"
      max-tick-time "Maximum tick time: $(property_get max-tick-time 60000)"
      __exit 'Save and exit'
    )
    selected="$(whiptail --title "${SERVER_ID} server.properties" --menu 'Choose a setting to edit' 24 84 16 "${items[@]}" 3>&1 1>&2 2>&3)" || return
    [[ "$selected" == __exit ]] && return
    edit_property "$selected"
  done
}

main "$@"
