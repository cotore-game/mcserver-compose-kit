#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="${MCSERVER_KIT_INSTALL_DIR:-${HOME}/.local/share/mcserver-compose-kit}"
CONFIG_DIR="${MCSERVER_KIT_CONFIG_DIR:-${HOME}/.config/mcserver-compose-kit}"
BIN_PATH="${MCSERVER_KIT_BIN_DIR:-${HOME}/.local/bin}/mcserver-kit"
UNINSTALL_BIN_PATH="${MCSERVER_KIT_BIN_DIR:-${HOME}/.local/bin}/mcserver-kit-uninstall"

rm -rf -- "$INSTALL_DIR"
rm -f -- "$BIN_PATH"
rm -f -- "$UNINSTALL_BIN_PATH"

if [[ "${1-}" == '--purge' ]]; then
  rm -rf -- "$CONFIG_DIR"
  printf '本体、設定、MCIDテンプレートを削除しました。\n'
else
  printf '本体を削除しました。設定とMCIDテンプレートは次に残しています:\n  %s\n' "$CONFIG_DIR"
  printf 'すべて削除する場合: %s --purge\n' "$0"
fi
