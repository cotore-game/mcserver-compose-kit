#!/usr/bin/env bash
# `tr` is the repository translation helper, and load_messages takes no CLI args.
# shellcheck disable=SC2020,SC2119
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${MCSERVER_KIT_CONFIG:-${HOME}/.config/mcserver-compose-kit/config.yml}"
TEMPLATE_DIR="${MCSERVER_KIT_MCID_TEMPLATE_DIR:-${HOME}/.config/mcserver-compose-kit/mcid-templates}"
LANGUAGE_FILE="${MCSERVER_KIT_LANGUAGE_FILE:-${HOME}/.config/mcserver-compose-kit/language}"

# shellcheck source=libexec/mcserver-kit/i18n.sh
source "${SCRIPT_DIR}/i18n.sh"
load_messages

resolve_parent() {
  local path="$1"
  local parent
  parent="$(dirname -- "$path")"
  if [[ -d "$parent" ]]; then
    (cd -- "$parent" && pwd)
  else
    printf '%s' "$parent"
  fi
}

confirm=false
case "${1-}" in
  '') ;;
  --yes | -y) confirm=true ;;
  *)
    tr reset.usage >&2
    exit 2
    ;;
esac

config_parent="$(resolve_parent "$CONFIG_FILE")"
template_parent="$(resolve_parent "$TEMPLATE_DIR")"
for protected_path in '' / "$HOME"; do
  if [[ "$config_parent" == "$protected_path" || "$template_parent" == "$protected_path" ]]; then
    tr reset.unsafe >&2
    exit 1
  fi
done

tr reset.summary "$CONFIG_FILE" "$TEMPLATE_DIR" "$LANGUAGE_FILE"
if [[ "$confirm" != 'true' ]]; then
  read -r -p "$(tr reset.confirm)" answer
  case "${answer,,}" in
    y | yes) ;;
    *)
      tr reset.cancelled
      exit 0
      ;;
  esac
fi

rm -f -- "$CONFIG_FILE"
rm -f -- "$LANGUAGE_FILE"
rm -rf -- "$TEMPLATE_DIR"
tr reset.done
