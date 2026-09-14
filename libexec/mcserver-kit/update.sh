#!/usr/bin/env bash
# `tr` is the repository translation helper, not the Unix character translator.
# shellcheck disable=SC2020
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${MCSERVER_KIT_ROOT:-$(cd -- "${SCRIPT_DIR}/../.." && pwd)}"
REPOSITORY='cotore-game/mcserver-compose-kit'
LATEST_URL="${MCSERVER_KIT_RELEASES_LATEST_URL:-https://github.com/${REPOSITORY}/releases/latest}"
CACHE_DIR="${MCSERVER_KIT_UPDATE_CACHE_DIR:-${HOME}/.cache/mcserver-compose-kit}"
CACHE_FILE="${CACHE_DIR}/update-check"
CACHE_TTL="${MCSERVER_KIT_UPDATE_CACHE_TTL:-86400}"
CURRENT_VERSION="${MCSERVER_KIT_CURRENT_VERSION:-$(head -n 1 "${ROOT_DIR}/VERSION" 2>/dev/null || printf unknown)}"

# shellcheck source=libexec/mcserver-kit/i18n.sh
source "${SCRIPT_DIR}/i18n.sh"
load_messages

usage() {
  tr update.usage
}

valid_tag() {
  [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]
}

normalized_current_tag() {
  if [[ "$CURRENT_VERSION" == v* ]]; then
    printf '%s' "$CURRENT_VERSION"
  else
    printf 'v%s' "$CURRENT_VERSION"
  fi
}

read_cached_tag() {
  local checked_at tag now
  [[ -f "$CACHE_FILE" ]] || return 1
  IFS= read -r checked_at <"$CACHE_FILE" || return 1
  IFS= read -r tag < <(sed -n '2p' "$CACHE_FILE") || return 1
  [[ "$checked_at" =~ ^[0-9]+$ ]] || return 1
  valid_tag "$tag" || return 1
  now="$(date +%s)"
  ((now >= checked_at)) || return 1
  ((now - checked_at < CACHE_TTL)) || return 1
  printf '%s' "$tag"
}

write_cache() {
  local tag="$1" temporary
  mkdir -p "$CACHE_DIR"
  chmod 700 "$CACHE_DIR" 2>/dev/null || true
  temporary="$(mktemp "${CACHE_DIR}/.update-check.XXXXXX")"
  printf '%s\n%s\n' "$(date +%s)" "$tag" >"$temporary"
  chmod 600 "$temporary"
  mv -f -- "$temporary" "$CACHE_FILE"
}

fetch_latest_tag() {
  local effective_url tag
  command -v curl >/dev/null 2>&1 || return 1
  effective_url="$(curl --fail --silent --show-error --location \
    --connect-timeout 2 --max-time 4 --output /dev/null \
    --write-out '%{url_effective}' "$LATEST_URL")" || return 1
  effective_url="${effective_url%/}"
  tag="${effective_url##*/}"
  valid_tag "$tag" || return 1
  write_cache "$tag"
  printf '%s' "$tag"
}

latest_tag() {
  local use_cache="$1" tag
  if [[ "$use_cache" == true ]] && tag="$(read_cached_tag)"; then
    printf '%s' "$tag"
    return
  fi
  fetch_latest_tag
}

update_available() {
  local current latest newest
  current="$(normalized_current_tag)"
  latest="$1"
  [[ "$current" != "$latest" ]] || return 1
  newest="$(printf '%s\n%s\n' "$current" "$latest" | sort -V | tail -n 1)"
  [[ "$newest" == "$latest" ]]
}

check_for_update() {
  local use_cache="$1" quiet="$2" latest current
  current="$(normalized_current_tag)"
  if ! latest="$(latest_tag "$use_cache")"; then
    if [[ "$quiet" == true ]]; then
      return 0
    fi
    tr update.check_failed >&2
    return 1
  fi
  if update_available "$latest"; then
    if [[ "$quiet" == true ]]; then
      printf '%s\n' "$latest"
    else
      tr update.available "$current" "$latest"
    fi
  elif [[ "$quiet" == false ]]; then
    tr update.up_to_date "$current"
  fi
}

install_update() {
  local assume_yes="$1" latest current answer=''
  current="$(normalized_current_tag)"
  if ! latest="$(latest_tag false)"; then
    tr update.check_failed >&2
    return 1
  fi
  if ! update_available "$latest"; then
    tr update.up_to_date "$current"
    return
  fi
  tr update.available "$current" "$latest"
  if [[ "$assume_yes" != true ]]; then
    if [[ ! -r /dev/tty ]]; then
      tr update.tty_required >&2
      return 1
    fi
    IFS= read -r -p "$(tr update.confirm "$current" "$latest")" answer </dev/tty
    case "${answer:-y}" in
      y | Y | yes | YES) ;;
      *) tr update.cancelled; return ;;
    esac
  fi
  MCSERVER_KIT_FORCE_RELEASE_DOWNLOAD=true \
    bash "${ROOT_DIR}/install.sh" --version "$latest"
}

main() {
  case "${1-}" in
    check)
      shift
      case "${1-}" in
        '') check_for_update false false ;;
        --cached) check_for_update true false ;;
        --quiet) check_for_update false true ;;
        *) usage >&2; return 2 ;;
      esac
      ;;
    --cached-quiet)
      check_for_update true true
      ;;
    '')
      install_update false
      ;;
    --yes)
      install_update true
      ;;
    -h | --help)
      usage
      ;;
    *)
      usage >&2
      return 2
      ;;
  esac
}

main "$@"
