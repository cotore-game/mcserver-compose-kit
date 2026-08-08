#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY='cotore-game/mcserver-compose-kit'
VERSION="${MCSERVER_KIT_VERSION:-latest}"
INSTALL_DIR="${MCSERVER_KIT_INSTALL_DIR:-${HOME}/.local/share/mcserver-compose-kit}"
CONFIG_DIR="${MCSERVER_KIT_CONFIG_DIR:-${HOME}/.config/mcserver-compose-kit}"
BIN_DIR="${MCSERVER_KIT_BIN_DIR:-${HOME}/.local/bin}"
SHELL_RC="${MCSERVER_KIT_SHELL_RC:-${HOME}/.bashrc}"
LANGUAGE_FILE="${MCSERVER_KIT_LANGUAGE_FILE:-${CONFIG_DIR}/language}"
PATH_BLOCK_START='# >>> mcserver-kit PATH >>>'
PATH_BLOCK_END='# <<< mcserver-kit PATH <<<'
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
          printf '%s\n' '--version requires a version.' >&2
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
        printf 'Unknown option: %s\n' "$1" >&2
        usage >&2
        return 2
        ;;
    esac
  done

  if [[ "$VERSION" != 'latest' ]]; then
    [[ "$VERSION" == v* ]] || VERSION="v${VERSION}"
    [[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || {
      printf 'Invalid version: %s\n' "$VERSION" >&2
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
    # read intentionally receives the caller's variable name.
    # shellcheck disable=SC2229
    IFS= read -r -p "$prompt" "$variable_name" </dev/tty
  else
    printf 'Cannot open a terminal for interactive input. Run this again from a regular WSL terminal.\n' >&2
    return 1
  fi
}

register_bin_path() {
  mkdir -p "$(dirname -- "$SHELL_RC")"
  touch "$SHELL_RC"
  if grep -Fxq "$PATH_BLOCK_START" "$SHELL_RC"; then
    return
  fi

  {
    printf '\n%s\n' "$PATH_BLOCK_START"
    printf 'case ":%sPATH:" in\n' '$'
    printf '  *:%q:*) ;;\n' "$BIN_DIR"
    printf '  *) export PATH=%q:"%sPATH" ;;\n' "$BIN_DIR" '$'
    printf 'esac\n%s\n' "$PATH_BLOCK_END"
  } >>"$SHELL_RC"
}

download_release() {
  local download_base
  local archive_url
  local checksum_url

  download_base="$(release_download_base)"
  archive_url="${download_base}/mcserver-compose-kit.tar.gz"
  checksum_url="${archive_url}.sha256"

  command -v curl >/dev/null 2>&1 || {
    printf 'curl is required. Run: sudo apt install curl\n' >&2
    exit 1
  }

  TEMP_DIR="$(mktemp -d)"
  printf '[1/3] Downloading release %s.\n' "$VERSION" >&2
  curl --fail --location --show-error --progress-bar \
    "$archive_url" --output "${TEMP_DIR}/mcserver-compose-kit.tar.gz" >&2
  curl --fail --location --silent --show-error \
    "$checksum_url" --output "${TEMP_DIR}/mcserver-compose-kit.tar.gz.sha256"

  printf '[2/3] Verifying SHA-256.\n' >&2
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
    printf 'Missing packages: %s\n' "${missing_packages[*]}"
    read_from_terminal 'Install them with sudo apt? [Y/n]: ' answer
    case "${answer:-y}" in
      y | Y | yes | YES)
        sudo apt-get update
        sudo apt-get install --yes "${missing_packages[@]}"
        ;;
      *)
        printf 'Install the required packages, then run the installer again.\n' >&2
        exit 1
        ;;
    esac
  fi

  command -v docker >/dev/null 2>&1 || {
    printf 'docker is unavailable in WSL. Check Docker Desktop WSL Integration.\n' >&2
    exit 1
  }
  docker compose version >/dev/null 2>&1 || {
    printf 'docker compose is unavailable in WSL. Check Docker Desktop integration.\n' >&2
    exit 1
  }
}

main() {
  local source_dir

  parse_arguments "$@"
  ensure_dependencies

  if [[ -n "$SCRIPT_DIR" && -f "${SCRIPT_DIR}/new-minecraft-server.sh" ]]; then
    source_dir="$SCRIPT_DIR"
  else
    source_dir="$(download_release)"
  fi

  printf '[3/3] Installing to %s.\n' "$INSTALL_DIR"
  mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "${CONFIG_DIR}/mcid-templates" "$BIN_DIR"
  install -m 755 "${source_dir}/new-minecraft-server.sh" "${INSTALL_DIR}/new-minecraft-server.sh"
  install -m 755 "${source_dir}/mcserver-kit" "${INSTALL_DIR}/mcserver-kit"
  install -m 755 "${source_dir}/setup.sh" "${INSTALL_DIR}/setup.sh"
  install -m 755 "${source_dir}/reset.sh" "${INSTALL_DIR}/reset.sh"
  install -m 755 "${source_dir}/config-tui.sh" "${INSTALL_DIR}/config-tui.sh"
  install -m 755 "${source_dir}/server-manager.sh" "${INSTALL_DIR}/server-manager.sh"
  install -m 755 "${source_dir}/server-properties-tui.sh" "${INSTALL_DIR}/server-properties-tui.sh"
  install -m 755 "${source_dir}/lang.sh" "${INSTALL_DIR}/lang.sh"
  install -m 755 "${source_dir}/uninstall.sh" "${INSTALL_DIR}/uninstall.sh"
  install -m 644 "${source_dir}/config.example.yml" "${INSTALL_DIR}/config.example.yml"
  install -m 644 "${source_dir}/compose-example.yaml" "${INSTALL_DIR}/compose-example.yaml"
  install -m 644 "${source_dir}/README.md" "${INSTALL_DIR}/README.md"
  install -m 644 "${source_dir}/LICENSE" "${INSTALL_DIR}/LICENSE"
  mkdir -p "${INSTALL_DIR}/scripts"
  install -m 755 "${source_dir}/scripts/detect-world-version.py" "${INSTALL_DIR}/scripts/detect-world-version.py"
  install -m 755 "${source_dir}/scripts/config-value.py" "${INSTALL_DIR}/scripts/config-value.py"
  install -m 755 "${source_dir}/scripts/server-config.py" "${INSTALL_DIR}/scripts/server-config.py"
  rm -f -- "${INSTALL_DIR}/scripts/server-property.py"
  install -m 644 "${source_dir}/scripts/i18n.sh" "${INSTALL_DIR}/scripts/i18n.sh"
  install -m 644 "${source_dir}/scripts/windows-dialog.ps1" "${INSTALL_DIR}/scripts/windows-dialog.ps1"
  mkdir -p "${INSTALL_DIR}/locales"
  cp -a "${source_dir}/locales/." "${INSTALL_DIR}/locales/"

  if [[ ! -f "${CONFIG_DIR}/config.yml" ]]; then
    install -m 600 "${source_dir}/config.example.yml" "${CONFIG_DIR}/config.yml"
  fi
  if [[ ! -f "$LANGUAGE_FILE" ]]; then
    printf 'en\n' >"$LANGUAGE_FILE"
    chmod 600 "$LANGUAGE_FILE"
  fi
  if ! find "${CONFIG_DIR}/mcid-templates" -maxdepth 1 -type f -name '*.txt' -print -quit | grep -q .; then
    cp -a "${source_dir}/mcid-templates/." "${CONFIG_DIR}/mcid-templates/"
  fi

  cat >"${BIN_DIR}/mcserver-kit" <<LAUNCHER
#!/usr/bin/env bash
export MCSERVER_KIT_INSTALL_DIR="\${MCSERVER_KIT_INSTALL_DIR:-${INSTALL_DIR}}"
export MCSERVER_KIT_CONFIG_DIR="\${MCSERVER_KIT_CONFIG_DIR:-${CONFIG_DIR}}"
export MCSERVER_KIT_BIN_DIR="\${MCSERVER_KIT_BIN_DIR:-${BIN_DIR}}"
export MCSERVER_KIT_SHELL_RC="\${MCSERVER_KIT_SHELL_RC:-${SHELL_RC}}"
export MCSERVER_KIT_LANGUAGE_FILE="\${MCSERVER_KIT_LANGUAGE_FILE:-${LANGUAGE_FILE}}"
export MCSERVER_KIT_CONFIG="\${MCSERVER_KIT_CONFIG:-${CONFIG_DIR}/config.yml}"
export MCSERVER_KIT_MCID_TEMPLATE_DIR="\${MCSERVER_KIT_MCID_TEMPLATE_DIR:-${CONFIG_DIR}/mcid-templates}"
exec "${INSTALL_DIR}/mcserver-kit" "\$@"
LAUNCHER
  chmod 755 "${BIN_DIR}/mcserver-kit"
  register_bin_path

  printf '\nInstallation complete.\n'
  printf 'Configuration: %s\n' "${CONFIG_DIR}/config.yml"
  printf 'PATH configuration: %s\n' "$SHELL_RC"
  if [[ ":$PATH:" != *":${BIN_DIR}:"* ]]; then
    printf '\nTo update PATH in the current terminal, run:\n'
    printf '  source %q\n' "$SHELL_RC"
  fi
  printf '\nBefore creating a server, run the initial setup:\n'
  printf '  mcserver-kit setup\n'
  printf 'Before updating PATH, use:\n'
  printf '  %q setup\n' "${BIN_DIR}/mcserver-kit"
  printf '\nTo use Japanese / 日本語に変更する場合:\n'
  printf '  mcserver-kit lang --ja\n'
}

if [[ "${MCSERVER_KIT_INSTALLER_SKIP_MAIN:-false}" != 'true' ]]; then
  main "$@"
fi
