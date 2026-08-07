#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY='cotore-game/mcserver-compose-kit'
VERSION="${MCSERVER_KIT_VERSION:-latest}"
INSTALL_DIR="${MCSERVER_KIT_INSTALL_DIR:-${HOME}/.local/share/mcserver-compose-kit}"
CONFIG_DIR="${MCSERVER_KIT_CONFIG_DIR:-${HOME}/.config/mcserver-compose-kit}"
BIN_DIR="${MCSERVER_KIT_BIN_DIR:-${HOME}/.local/bin}"
SCRIPT_PATH="${BASH_SOURCE[0]-}"
if [[ -n "$SCRIPT_PATH" ]] && ! SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" 2>/dev/null && pwd)"; then
  SCRIPT_DIR=''
fi
SCRIPT_DIR="${SCRIPT_DIR:-}"
TEMP_DIR=''

cleanup() {
  if [[ -n "$TEMP_DIR" ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'USAGE'
Usage: install.sh [--version VERSION]

Options:
  --version VERSION  Install a release such as v0.2.0 (default: latest)
  -h, --help         Show this help
USAGE
}

parse_arguments() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --version)
        [[ "$#" -ge 2 ]] || {
          printf '%s\n' '--versionにはバージョンが必要です。' >&2
          return 2
        }
        VERSION="$2"
        shift 2
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        printf '不明なオプション: %s\n' "$1" >&2
        usage >&2
        return 2
        ;;
    esac
  done

  if [[ "$VERSION" != 'latest' ]]; then
    [[ "$VERSION" == v* ]] || VERSION="v${VERSION}"
    [[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || {
      printf '無効なバージョン: %s\n' "$VERSION" >&2
      return 2
    }
  fi
}

release_download_base() {
  if [[ "$VERSION" == 'latest' ]]; then
    printf 'https://github.com/%s/releases/latest/download' "$REPOSITORY"
  else
    printf 'https://github.com/%s/releases/download/%s' "$REPOSITORY" "$VERSION"
  fi
}

read_from_terminal() {
  local prompt="$1"
  local variable_name="$2"

  if [[ -r /dev/tty ]]; then
    IFS= read -r -p "$prompt" "$variable_name" </dev/tty
  else
    printf '対話入力用の端末を開けません。通常のWSLターミナルから再実行してください。\n' >&2
    return 1
  fi
}

download_release() {
  local download_base
  local archive_url
  local checksum_url

  download_base="$(release_download_base)"
  archive_url="${download_base}/mcserver-compose-kit.tar.gz"
  checksum_url="${archive_url}.sha256"

  command -v curl >/dev/null 2>&1 || {
    printf 'curlが必要です。次を実行してください: sudo apt install curl\n' >&2
    exit 1
  }

  TEMP_DIR="$(mktemp -d)"
  printf '[1/3] リリース %s をダウンロードしています。\n' "$VERSION" >&2
  curl --fail --location --show-error --progress-bar \
    "$archive_url" --output "${TEMP_DIR}/mcserver-compose-kit.tar.gz" >&2
  curl --fail --location --silent --show-error \
    "$checksum_url" --output "${TEMP_DIR}/mcserver-compose-kit.tar.gz.sha256"

  printf '[2/3] SHA-256を検証しています。\n' >&2
  (
    cd "$TEMP_DIR"
    sha256sum --check mcserver-compose-kit.tar.gz.sha256
    tar -xzf mcserver-compose-kit.tar.gz
  ) >&2
  printf '%s' "${TEMP_DIR}/mcserver-compose-kit"
}

ensure_dependencies() {
  local missing_packages=()

  command -v python3 >/dev/null 2>&1 || missing_packages+=(python3)
  command -v unzip >/dev/null 2>&1 || missing_packages+=(unzip)
  command -v whiptail >/dev/null 2>&1 || missing_packages+=(whiptail)

  if [[ "${#missing_packages[@]}" -gt 0 ]]; then
    printf '不足しているパッケージ: %s\n' "${missing_packages[*]}"
    read_from_terminal 'sudo aptでインストールしますか？ [Y/n]: ' answer
    case "${answer:-y}" in
      y | Y | yes | YES)
        sudo apt-get update
        sudo apt-get install --yes "${missing_packages[@]}"
        ;;
      *)
        printf '依存パッケージを導入してから再実行してください。\n' >&2
        exit 1
        ;;
    esac
  fi

  command -v docker >/dev/null 2>&1 || {
    printf 'WSLからdockerを実行できません。Docker DesktopのWSL Integrationを確認してください。\n' >&2
    exit 1
  }
  docker compose version >/dev/null 2>&1 || {
    printf 'WSLからdocker composeを実行できません。Docker Desktopの連携を確認してください。\n' >&2
    exit 1
  }
}

main() {
  local source_dir
  local needs_setup=false
  local setup_answer

  parse_arguments "$@"
  ensure_dependencies

  if [[ -n "$SCRIPT_DIR" && -f "${SCRIPT_DIR}/new-minecraft-server.sh" ]]; then
    source_dir="$SCRIPT_DIR"
  else
    source_dir="$(download_release)"
  fi

  printf '[3/3] %s へインストールしています。\n' "$INSTALL_DIR"
  mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "${CONFIG_DIR}/mcid-templates" "$BIN_DIR"
  install -m 755 "${source_dir}/new-minecraft-server.sh" "${INSTALL_DIR}/new-minecraft-server.sh"
  install -m 755 "${source_dir}/mcserver-kit" "${INSTALL_DIR}/mcserver-kit"
  install -m 755 "${source_dir}/setup.sh" "${INSTALL_DIR}/setup.sh"
  install -m 755 "${source_dir}/reset.sh" "${INSTALL_DIR}/reset.sh"
  install -m 755 "${source_dir}/config-tui.sh" "${INSTALL_DIR}/config-tui.sh"
  install -m 755 "${source_dir}/uninstall.sh" "${INSTALL_DIR}/uninstall.sh"
  install -m 644 "${source_dir}/config.example.yml" "${INSTALL_DIR}/config.example.yml"
  install -m 644 "${source_dir}/compose-example.yaml" "${INSTALL_DIR}/compose-example.yaml"
  install -m 644 "${source_dir}/README.md" "${INSTALL_DIR}/README.md"
  install -m 644 "${source_dir}/LICENSE" "${INSTALL_DIR}/LICENSE"
  mkdir -p "${INSTALL_DIR}/scripts"
  install -m 755 "${source_dir}/scripts/detect-world-version.py" "${INSTALL_DIR}/scripts/detect-world-version.py"
  install -m 755 "${source_dir}/scripts/config-value.py" "${INSTALL_DIR}/scripts/config-value.py"
  install -m 644 "${source_dir}/scripts/i18n.sh" "${INSTALL_DIR}/scripts/i18n.sh"
  install -m 644 "${source_dir}/scripts/windows-dialog.ps1" "${INSTALL_DIR}/scripts/windows-dialog.ps1"
  mkdir -p "${INSTALL_DIR}/locales"
  cp -a "${source_dir}/locales/." "${INSTALL_DIR}/locales/"

  if [[ ! -f "${CONFIG_DIR}/config.yml" ]]; then
    install -m 600 "${source_dir}/config.example.yml" "${CONFIG_DIR}/config.yml"
    needs_setup=true
  fi
  if ! find "${CONFIG_DIR}/mcid-templates" -maxdepth 1 -type f -name '*.txt' -print -quit | grep -q .; then
    cp -a "${source_dir}/mcid-templates/." "${CONFIG_DIR}/mcid-templates/"
  fi

  cat >"${BIN_DIR}/mcserver-kit" <<LAUNCHER
#!/usr/bin/env bash
export MCSERVER_KIT_INSTALL_DIR="\${MCSERVER_KIT_INSTALL_DIR:-${INSTALL_DIR}}"
export MCSERVER_KIT_CONFIG_DIR="\${MCSERVER_KIT_CONFIG_DIR:-${CONFIG_DIR}}"
export MCSERVER_KIT_BIN_DIR="\${MCSERVER_KIT_BIN_DIR:-${BIN_DIR}}"
export MCSERVER_KIT_CONFIG="\${MCSERVER_KIT_CONFIG:-${CONFIG_DIR}/config.yml}"
export MCSERVER_KIT_MCID_TEMPLATE_DIR="\${MCSERVER_KIT_MCID_TEMPLATE_DIR:-${CONFIG_DIR}/mcid-templates}"
exec "${INSTALL_DIR}/mcserver-kit" "\$@"
LAUNCHER
  chmod 755 "${BIN_DIR}/mcserver-kit"

  printf '\nインストールが完了しました。\n'
  printf '設定ファイル: %s\n' "${CONFIG_DIR}/config.yml"
  printf '起動コマンド: mcserver-kit\n'
  if [[ ":$PATH:" != *":${BIN_DIR}:"* ]]; then
    printf '\n%s がPATHにありません。次をシェル設定へ追加してください:\n' "$BIN_DIR"
    printf '%s\n' "  export PATH=\"\$HOME/.local/bin:\$PATH\""
  fi
  printf '\n初回起動前に、設定ファイルのEULA同意とMinecraft IDを編集してください。\n'

  if [[ "$needs_setup" == 'true' && "${MCSERVER_KIT_SKIP_SETUP:-false}" != 'true' ]]; then
    read_from_terminal '初回セットアップを開始しますか？ [Y/n]: ' setup_answer || setup_answer=''
    case "${setup_answer:-y}" in
      y | Y | yes | YES)
        if [[ -r /dev/tty ]]; then
          MCSERVER_KIT_CONFIG="${CONFIG_DIR}/config.yml" \
            MCSERVER_KIT_MCID_TEMPLATE_DIR="${CONFIG_DIR}/mcid-templates" \
            "${INSTALL_DIR}/setup.sh" </dev/tty
        else
          printf '後から mcserver-kit setup で設定してください。\n'
        fi
        ;;
      *)
        printf '後から mcserver-kit setup で設定できます。\n'
        ;;
    esac
  fi
}

if [[ "${MCSERVER_KIT_INSTALLER_SKIP_MAIN:-false}" != 'true' ]]; then
  main "$@"
fi
