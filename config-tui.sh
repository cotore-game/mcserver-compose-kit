#!/usr/bin/env bash
# `tr` is the repository translation helper, and load_messages takes no CLI args.
# shellcheck disable=SC2020,SC2119
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${MCSERVER_KIT_CONFIG:-${HOME}/.config/mcserver-compose-kit/config.yml}"
TEMPLATE_DIR="${MCSERVER_KIT_MCID_TEMPLATE_DIR:-${HOME}/.config/mcserver-compose-kit/mcid-templates}"
CONFIG_VALUE="${SCRIPT_DIR}/scripts/config-value.py"

# Keep whiptail readable on terminals whose default newt theme uses a bright
# magenta selection. Users can override this with MCSERVER_KIT_TUI_COLORS or
# an existing NEWT_COLORS value.
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

# shellcheck source=scripts/i18n.sh
source "${SCRIPT_DIR}/scripts/i18n.sh"
load_messages

command -v whiptail >/dev/null 2>&1 || {
  tr tui.missing >&2
  exit 1
}
[[ -f "$CONFIG_FILE" ]] || {
  tr tui.no_config >&2
  exit 1
}
mkdir -p "$TEMPLATE_DIR"

dialog_menu() {
  local title="$1"
  local text="$2"
  shift 2
  whiptail --title "$title" --menu "$text" 20 78 12 "$@" 3>&1 1>&2 2>&3
}

edit_owner() {
  local current
  local value
  current="$(python3 "$CONFIG_VALUE" get "$CONFIG_FILE" owner minecraft_id)"
  while true; do
    value="$(whiptail --title "$(tr tui.owner_title)" --inputbox "$(tr tui.owner_prompt)" 10 60 "$current" 3>&1 1>&2 2>&3)" || return
    if [[ "$value" =~ ^[A-Za-z0-9_]{3,16}$ ]]; then
      python3 "$CONFIG_VALUE" set "$CONFIG_FILE" owner minecraft_id "$value"
      whiptail --msgbox "$(tr tui.owner_saved "$value")" 8 60
      return
    fi
    whiptail --msgbox "$(tr input.mcid_rules)" 8 60
  done
}

template_references() {
  local name="$1"
  local whitelist
  local ops
  whitelist="$(python3 "$CONFIG_VALUE" get "$CONFIG_FILE" access whitelist_template 2>/dev/null || true)"
  ops="$(python3 "$CONFIG_VALUE" get "$CONFIG_FILE" access ops_template 2>/dev/null || true)"
  [[ "$name" == "$whitelist" || "$name" == "$ops" ]]
}

create_template() {
  local name
  while true; do
    name="$(whiptail --title "$(tr tui.template_create)" --inputbox "$(tr tui.template_name)" 10 60 3>&1 1>&2 2>&3)" || return
    if [[ ! "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then
      whiptail --msgbox "$(tr tui.template_name_invalid)" 8 60
      continue
    fi
    if [[ -e "${TEMPLATE_DIR}/${name}.txt" ]]; then
      whiptail --msgbox "$(tr tui.template_exists)" 8 60
      continue
    fi
    : >"${TEMPLATE_DIR}/${name}.txt"
    chmod 600 "${TEMPLATE_DIR}/${name}.txt"
    return
  done
}

add_mcid() {
  local path="$1"
  local value
  while true; do
    value="$(whiptail --title "$(tr tui.mcid_add)" --inputbox "$(tr tui.mcid_prompt)" 10 60 3>&1 1>&2 2>&3)" || return
    if [[ ! "$value" =~ ^[A-Za-z0-9_]{3,16}$ ]]; then
      whiptail --msgbox "$(tr input.mcid_rules)" 8 60
      continue
    fi
    if awk -v value="$value" 'tolower($0) == tolower(value) { found=1 } END { exit !found }' "$path"; then
      whiptail --msgbox "$(tr tui.mcid_exists)" 8 60
      return
    fi
    printf '%s\n' "$value" >>"$path"
    return
  done
}

remove_mcid() {
  local path="$1"
  local selected
  local temporary
  local index
  local items=()
  local lines=()
  mapfile -t lines <"$path"
  [[ "${#lines[@]}" -gt 0 ]] || {
    whiptail --msgbox "$(tr tui.template_empty)" 8 60
    return
  }
  for index in "${!lines[@]}"; do
    items+=("$((index + 1))" "${lines[$index]}")
  done
  selected="$(dialog_menu "$(tr tui.mcid_remove)" "$(tr tui.select_mcid)" "${items[@]}")" || return
  temporary="$(mktemp "${path}.XXXXXX")"
  awk -v remove="$selected" 'NR != remove' "$path" >"$temporary"
  chmod 600 "$temporary"
  mv -f -- "$temporary" "$path"
}

delete_template() {
  local name="$1"
  local path="$2"
  if template_references "$name"; then
    whiptail --msgbox "$(tr tui.template_referenced)" 9 70
    return
  fi
  if whiptail --yesno "$(tr tui.template_delete_confirm "$name")" 9 70; then
    rm -f -- "$path"
  fi
}

manage_template() {
  local name="$1"
  local path="${TEMPLATE_DIR}/${name}.txt"
  local action
  while [[ -f "$path" ]]; do
    action="$(dialog_menu "$name" "$(tr tui.choose_action)" \
      view "$(tr tui.view)" \
      add "$(tr tui.mcid_add)" \
      remove "$(tr tui.mcid_remove)" \
      delete "$(tr tui.delete)" \
      back "$(tr tui.back)")" || return
    case "$action" in
      view) whiptail --title "$name" --textbox "$path" 20 70 ;;
      add) add_mcid "$path" ;;
      remove) remove_mcid "$path" ;;
      delete) delete_template "$name" "$path" ;;
      back) return ;;
    esac
  done
}

manage_templates() {
  local choice
  local file
  local name
  local items=()
  while true; do
    items=()
    shopt -s nullglob
    for file in "${TEMPLATE_DIR}"/*.txt; do
      name="$(basename "$file" .txt)"
      items+=("$name" "$(tr tui.template_entry)")
    done
    shopt -u nullglob
    items+=(__create "$(tr tui.template_create)" __back "$(tr tui.back)")
    choice="$(dialog_menu "$(tr tui.templates_title)" "$(tr tui.select_template)" "${items[@]}")" || return
    case "$choice" in
      __create) create_template ;;
      __back) return ;;
      *) manage_template "$choice" ;;
    esac
  done
}

main_menu() {
  local choice
  while true; do
    choice="$(dialog_menu "Minecraft Server Kit" "$(tr tui.main_prompt)" \
      owner "$(tr tui.owner_menu)" \
      templates "$(tr tui.templates_menu)" \
      exit "$(tr tui.exit)")" || return
    case "$choice" in
      owner) edit_owner ;;
      templates) manage_templates ;;
      exit) return ;;
    esac
  done
}

case "${1-}" in
  templates) manage_templates ;;
  '') main_menu ;;
  *) exit 2 ;;
esac
