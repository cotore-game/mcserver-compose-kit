#!/usr/bin/env bash
# `tr` is the repository translation helper, and load_messages may take no args.
# shellcheck disable=SC2020,SC2119
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LANGUAGE_FILE="${MCSERVER_KIT_LANGUAGE_FILE:-${HOME}/.config/mcserver-compose-kit/language}"
language=''

# shellcheck source=scripts/i18n.sh
source "${SCRIPT_DIR}/scripts/i18n.sh"

case "${1-}" in
  --ja | ja) language='ja' ;;
  --en | en) language='en' ;;
  *)
    load_messages
    tr lang.unsupported "${1-}" >&2
    printf '\n' >&2
    tr lang.usage >&2
    printf '\n' >&2
    exit 2
    ;;
esac

mkdir -p "$(dirname -- "$LANGUAGE_FILE")"
printf '%s\n' "$language" >"$LANGUAGE_FILE"
chmod 600 "$LANGUAGE_FILE"
export MCSERVER_KIT_LANG="$language"
load_messages "$language"
tr lang.saved
printf '\n'
