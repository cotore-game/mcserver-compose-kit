#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="${MCSERVER_KIT_INSTALL_DIR:-${HOME}/.local/share/mcserver-compose-kit}"
CONFIG_DIR="${MCSERVER_KIT_CONFIG_DIR:-${HOME}/.config/mcserver-compose-kit}"
BIN_PATH="${MCSERVER_KIT_BIN_DIR:-${HOME}/.local/bin}/mcserver-kit"
UNINSTALL_BIN_PATH="${MCSERVER_KIT_BIN_DIR:-${HOME}/.local/bin}/mcserver-kit-uninstall"
SHELL_RC="${MCSERVER_KIT_SHELL_RC:-${HOME}/.bashrc}"
PATH_BLOCK_START='# >>> mcserver-kit PATH >>>'
PATH_BLOCK_END='# <<< mcserver-kit PATH <<<'

unregister_bin_path() {
  local temporary

  [[ -f "$SHELL_RC" ]] || return
  grep -Fxq "$PATH_BLOCK_START" "$SHELL_RC" || return
  temporary="$(mktemp "${SHELL_RC}.XXXXXX")"
  awk -v start="$PATH_BLOCK_START" -v end="$PATH_BLOCK_END" '
    $0 == start { removing=1; next }
    removing && $0 == end { removing=0; next }
    !removing { print }
  ' "$SHELL_RC" >"$temporary"
  chmod --reference="$SHELL_RC" "$temporary"
  mv -f -- "$temporary" "$SHELL_RC"
}

rm -rf -- "$INSTALL_DIR"
rm -f -- "$BIN_PATH"
rm -f -- "$UNINSTALL_BIN_PATH"
unregister_bin_path

if [[ "${1-}" == '--purge' ]]; then
  rm -rf -- "$CONFIG_DIR"
  printf '本体、設定、MCIDテンプレートを削除しました。\n'
else
  printf '本体を削除しました。設定とMCIDテンプレートは次に残しています:\n  %s\n' "$CONFIG_DIR"
  printf '設定も削除する場合は、アンインストール前に uninstall --purge を使用してください。\n'
fi

printf 'PATH設定を %s から削除しました。新しいターミナルから反映されます。\n' "$SHELL_RC"
printf '現在のターミナルに残ったコマンドキャッシュは次で消去できます:\n'
printf '  hash -r\n'
