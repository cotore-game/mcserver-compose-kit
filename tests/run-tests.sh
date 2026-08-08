#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../new-minecraft-server.sh
# The computed repository path is intentional.
# shellcheck disable=SC1091
source "${REPO_ROOT}/new-minecraft-server.sh"

tests_run=0
tests_skipped=0
TEST_TEMP_DIR=''

cleanup() {
  if [[ -n "$TEST_TEMP_DIR" ]]; then
    rm -rf -- "$TEST_TEMP_DIR"
  fi
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  local description="$3"

  tests_run=$((tests_run + 1))
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL: %s\n  expected: %q\n  actual:   %q\n' \
      "$description" "$expected" "$actual" >&2
    return 1
  fi
}

assert_fails() {
  local description="$1"
  shift

  tests_run=$((tests_run + 1))
  if "$@" >/dev/null 2>&1; then
    printf 'FAIL: %s（失敗するはずの処理が成功しました）\n' "$description" >&2
    return 1
  fi
}

test_version_resolution() {
  assert_equal 'itzg/minecraft-server:java17' "$(resolve_minecraft_image '1.18' auto)" '1.18 uses Java 17'
  assert_equal 'itzg/minecraft-server:java17' "$(resolve_minecraft_image '1.20.4' auto)" '1.20.4 uses Java 17'
  assert_equal 'itzg/minecraft-server:java21' "$(resolve_minecraft_image '1.20.5' auto)" '1.20.5 uses Java 21'
  assert_equal 'itzg/minecraft-server:java21' "$(resolve_minecraft_image '1.21' auto)" '1.21 uses Java 21'
  assert_equal 'itzg/minecraft-server:java21' "$(resolve_minecraft_image '1.21.10' auto)" '1.21.10 uses Java 21'
  assert_equal 'itzg/minecraft-server:java25' "$(resolve_minecraft_image '26.2' auto)" '26.2 uses Java 25'
  assert_equal 'itzg/minecraft-server:java25' "$(resolve_minecraft_image 'LATEST' auto)" 'LATEST uses Java 25'
  assert_equal 'itzg/minecraft-server:java-custom' "$(resolve_minecraft_image '1.21' java-custom)" 'configured image tag overrides auto detection'
  # The single-quoted script is intentional so the child shell expands $1.
  # shellcheck disable=SC2016
  assert_fails 'unknown versions are rejected in auto mode' \
    bash -c 'source "$1"; resolve_minecraft_image "1.17.1" auto' _ "${REPO_ROOT}/new-minecraft-server.sh"
}

test_locales() {
  local english_help
  local japanese_help
  local language_file="${TEST_TEMP_DIR}/language-preference"

  python3 "${REPO_ROOT}/scripts/validate-locales.py" "${REPO_ROOT}/locales" >/dev/null
  tests_run=$((tests_run + 1))

  english_help="$(bash "${REPO_ROOT}/mcserver-kit" --lang en --help)"
  japanese_help="$(bash "${REPO_ROOT}/mcserver-kit" --lang ja --help)"
  assert_equal 'present' "$(grep -q 'Create a new server interactively' <<<"$english_help" && printf present)" 'English help is loaded from the locale catalog'
  assert_equal 'present' "$(grep -q '対話形式で新しいサーバーを作成' <<<"$japanese_help" && printf present)" 'Japanese help is loaded from the locale catalog'
  assert_equal 'present' "$(grep -q '管理対象サーバーと状態' <<<"$japanese_help" && printf present)" 'server management help is translated'

  english_help="$(LANG=ja_JP.UTF-8 MCSERVER_KIT_LANGUAGE_FILE="$language_file" bash "${REPO_ROOT}/mcserver-kit" --help)"
  assert_equal 'present' "$(grep -q 'Create a new server interactively' <<<"$english_help" && printf present)" 'English is the default regardless of LANG'

  MCSERVER_KIT_LANGUAGE_FILE="$language_file" bash "${REPO_ROOT}/mcserver-kit" lang --ja >/dev/null
  japanese_help="$(MCSERVER_KIT_LANGUAGE_FILE="$language_file" bash "${REPO_ROOT}/mcserver-kit" --help)"
  assert_equal 'ja' "$(cat "$language_file")" 'the language command persists Japanese'
  assert_equal 'present' "$(grep -q '対話形式で新しいサーバーを作成' <<<"$japanese_help" && printf present)" 'the persisted language is used by later commands'

  MCSERVER_KIT_LANGUAGE_FILE="$language_file" bash "${REPO_ROOT}/mcserver-kit" lang --en >/dev/null
  assert_equal 'en' "$(cat "$language_file")" 'the language command persists English'
}

test_installer_version_selection() {
  local installer_output

  installer_output="$(MCSERVER_KIT_INSTALLER_SKIP_MAIN=true bash -c '
    source "$1"
    VERSION=latest
    parse_arguments --version 0.2.0
    printf "%s\n" "$VERSION"
    release_download_base
  ' _ "${REPO_ROOT}/install.sh")"
  assert_equal $'v0.2.0\nhttps://github.com/cotore-game/mcserver-compose-kit/releases/download/v0.2.0' \
    "$installer_output" 'installer accepts a pinned release version'

  # The child shell intentionally expands $1.
  # shellcheck disable=SC2016
  assert_fails 'installer rejects invalid release versions' \
    env MCSERVER_KIT_INSTALLER_SKIP_MAIN=true bash -c \
      'source "$1"; parse_arguments --version latest-main' _ "${REPO_ROOT}/install.sh"

  installer_output="$(bash -s -- --help <"${REPO_ROOT}/install.sh")"
  assert_equal 'present' "$(grep -q -- '--version VERSION' <<<"$installer_output" && printf present)" \
    'installer can run from a pipe without BASH_SOURCE errors'
}

test_setup_gate() {
  local temp_dir="$1"
  local config_file="${temp_dir}/setup-gate/config.yml"
  local template_dir="${temp_dir}/setup-gate/templates"

  mkdir -p "$template_dir"
  cat >"$config_file" <<'CONFIG'
setup:
  completed: false
CONFIG
  assert_fails 'server creation is blocked until setup completes' \
    env MCSERVER_KIT_CONFIG="$config_file" \
      MCSERVER_KIT_MCID_TEMPLATE_DIR="$template_dir" \
      bash "${REPO_ROOT}/new-minecraft-server.sh"
}

test_input_normalization() {
  assert_equal '8G' "$(normalize_memory '8')" 'plain memory values mean GiB'
  assert_equal '8192M' "$(normalize_memory '8192m')" 'memory suffix is normalized'
  assert_fails 'invalid memory values are rejected' normalize_memory 'eight'
  assert_equal '/mnt/c/Maps/a.zip' "$(windows_to_wsl_path 'C:\Maps\a.zip')" 'Windows paths are converted to WSL paths'
  assert_equal '/mnt/d/My Maps/world' "$(windows_to_wsl_path '"D:\My Maps\world"')" 'quoted Windows paths preserve spaces'
}

test_world_discovery() {
  local temp_dir="$1"
  local direct_world="${temp_dir}/direct-world"
  local distribution="${temp_dir}/distribution"
  local nested_world="${distribution}/map-folder"
  local ambiguous="${temp_dir}/ambiguous"

  mkdir -p "${direct_world}" "${nested_world}/data" "${nested_world}/resourcepacks"
  : >"${direct_world}/level.dat"
  : >"${nested_world}/level.dat"
  : >"${distribution}/readme.txt"

  assert_equal "$direct_world" "$(resolve_world_source "$direct_world")" 'a direct world root is detected'
  assert_equal "$nested_world" "$(resolve_world_source "$distribution")" 'a world nested under a distribution folder is detected'

  mkdir -p "${ambiguous}/one" "${ambiguous}/two"
  : >"${ambiguous}/one/level.dat"
  : >"${ambiguous}/two/level.dat"
  assert_fails 'multiple world roots require an explicit selection' resolve_world_source "$ambiguous"
}

test_saved_version_detection() {
  local temp_dir="$1"
  local world_root="${temp_dir}/versioned-world"
  local archive="${temp_dir}/versioned-world.zip"

  if ! command -v python3 >/dev/null 2>&1; then
    tests_skipped=$((tests_skipped + 2))
    printf 'SKIP: saved version detection（python3 is not installed）\n'
    return
  fi

  mkdir -p "$world_root"
  python3 - "$world_root" "$archive" <<'PYTHON'
import gzip
import struct
import sys
import zipfile
from pathlib import Path

world_root = Path(sys.argv[1])
archive_path = Path(sys.argv[2])

def nbt_string(value: str) -> bytes:
    encoded = value.encode("utf-8")
    return struct.pack(">H", len(encoded)) + encoded

nbt = b"".join([
    b"\x0a\x00\x00",                  # unnamed root compound
    b"\x0a" + nbt_string("Data"),     # Data compound
    b"\x0a" + nbt_string("Version"),  # Version compound
    b"\x08" + nbt_string("Name") + nbt_string("1.21.4"),
    b"\x00\x00\x00",                 # end Version, Data, root
])

level_dat = world_root / "level.dat"
level_dat.write_bytes(gzip.compress(nbt))
with zipfile.ZipFile(archive_path, "w") as archive:
    archive.write(level_dat, "distribution/map-folder/level.dat")
    archive.writestr("distribution/readme.txt", "read me")
PYTHON

  assert_equal '1.21.4' "$(detect_world_version "$world_root")" 'Version.Name is read from a world folder'
  assert_equal '1.21.4' "$(detect_world_version "$archive")" 'Version.Name is read from a nested ZIP world'
}

test_nested_zip_import() {
  local temp_dir="$1"
  local archive_source="${temp_dir}/archive-source"
  local world_root="${archive_source}/a/map-folder"
  local archive="${temp_dir}/a.zip"
  local destination="${temp_dir}/copied-world"

  if ! command -v zip >/dev/null 2>&1; then
    tests_skipped=$((tests_skipped + 1))
    printf 'SKIP: nested ZIP import（zip command is not installed）\n'
    return
  fi

  mkdir -p "${world_root}/data" "${world_root}/resourcepacks"
  : >"${archive_source}/a/readme.txt"
  : >"${world_root}/level.dat"

  (cd "$archive_source" && zip -qr "$archive" a)
  copy_world "$archive" "$destination"

  assert_equal 'present' "$([[ -f "${destination}/level.dat" ]] && printf present)" 'a nested world is extracted from a ZIP'
  assert_equal 'present' "$([[ -d "${destination}/data" ]] && printf present)" 'the world data directory is preserved'
  assert_equal 'absent' "$([[ ! -f "${destination}/readme.txt" ]] && printf absent)" 'distribution files outside the world root are excluded'
}

test_creation_flow() {
  local temp_dir="$1"
  local world_root="${temp_dir}/integration-world"
  local server_root="${temp_dir}/servers"
  local config_file="${temp_dir}/config.yml"
  local output_log="${temp_dir}/creation.log"
  local target="${server_root}/spec-server"

  if ! docker compose version >/dev/null 2>&1; then
    tests_skipped=$((tests_skipped + 4))
    printf 'SKIP: creation flow（docker compose is not installed）\n'
    return
  fi

  mkdir -p "$world_root"
  : >"${world_root}/level.dat"
  cat >"$config_file" <<CONFIG
setup:
  completed: true
owner:
  minecraft_id: "TestOwner"
minecraft:
  accept_eula: true
paths:
  server_root: "$server_root"
defaults:
  minecraft_version: "1.21"
  java_memory: "2G"
  start_after_creation: false
access:
  whitelist_enabled: false
  ops_enabled: false
playit:
  enabled: false
docker:
  java_image_tag: "auto"
ui:
  windows_dialogs: false
CONFIG

  printf '%s\n' \
    'spec-server' '' "$world_root" '' '' '' '' '' '' '' |
  MCSERVER_KIT_CONFIG="$config_file" \
      bash "${REPO_ROOT}/new-minecraft-server.sh" >"$output_log" 2>&1

  assert_equal 'present' "$([[ -f "${target}/compose.yaml" ]] && printf present)" 'the creation flow writes compose.yaml'
  assert_equal 'present' "$([[ -f "${target}/.env" ]] && printf present)" 'the creation flow writes .env'
  assert_equal 'present' "$([[ -f "${target}/data/world/level.dat" ]] && printf present)" 'the creation flow copies the world'
  assert_equal 'present' "$(grep -q '\[5/5\].*Docker Compose設定を検証' "$output_log" && printf present)" 'the creation flow reports Compose validation progress'
}

test_local_installation() {
  local temp_dir="$1"
  local install_dir="${temp_dir}/install/share"
  local config_dir="${temp_dir}/install/config"
  local bin_dir="${temp_dir}/install/bin"
  local fake_bin="${temp_dir}/install/fake-bin"
  local install_log="${temp_dir}/install/install.log"
  local shell_rc="${temp_dir}/install/bashrc"
  local installed_help

  mkdir -p "$fake_bin"
  ln -s /usr/bin/true "${fake_bin}/unzip"

  PATH="${fake_bin}:$PATH" \
    MCSERVER_KIT_INSTALL_DIR="$install_dir" \
    MCSERVER_KIT_CONFIG_DIR="$config_dir" \
    MCSERVER_KIT_BIN_DIR="$bin_dir" \
    MCSERVER_KIT_SHELL_RC="$shell_rc" \
    bash "${REPO_ROOT}/install.sh" >"$install_log"

  assert_equal 'present' "$([[ -x "${bin_dir}/mcserver-kit" ]] && printf present)" 'the installer creates the launcher'
  installed_help="$("${bin_dir}/mcserver-kit" --help)"
  assert_equal 'present' "$(grep -q 'mcserver-kit setup' <<<"$installed_help" && printf present)" 'the installed launcher exposes subcommand help'
  assert_equal 'present' "$([[ -f "${config_dir}/config.yml" ]] && printf present)" 'the installer creates the initial config'
  assert_equal 'present' "$([[ -f "${install_dir}/scripts/windows-dialog.ps1" ]] && printf present)" 'the installer includes the Windows dialog helper'
  assert_equal 'present' "$([[ -x "${install_dir}/lang.sh" ]] && printf present)" 'the installer includes the language command'
  assert_equal 'present' "$([[ -x "${install_dir}/server-manager.sh" ]] && printf present)" 'the installer includes the server manager'
  assert_equal 'present' "$([[ -x "${install_dir}/server-properties-tui.sh" ]] && printf present)" 'the installer includes the properties TUI'
  assert_equal 'present' "$([[ -x "${install_dir}/scripts/server-property.py" ]] && printf present)" 'the installer includes the property editor'
  assert_equal 'en' "$(cat "${config_dir}/language")" 'the installer defaults to English'
  assert_equal '1' "$(grep -Fxc '# >>> mcserver-kit PATH >>>' "$shell_rc")" 'the installer registers one managed PATH block'
  assert_equal 'present' "$(grep -q 'mcserver-kit setup' "$install_log" && printf present)" 'the installer instructs the user to run setup'
  assert_equal 'absent' "$(! grep -q '初回セットアップを開始' "$install_log" && printf absent)" 'the installer does not start setup automatically'

  printf '\n# preserve-on-update\n' >>"${config_dir}/config.yml"
  PATH="${fake_bin}:$PATH" \
    MCSERVER_KIT_INSTALL_DIR="$install_dir" \
    MCSERVER_KIT_CONFIG_DIR="$config_dir" \
    MCSERVER_KIT_BIN_DIR="$bin_dir" \
    MCSERVER_KIT_SHELL_RC="$shell_rc" \
    bash "${REPO_ROOT}/install.sh" >>"$install_log"
  assert_equal 'present' "$(grep -q 'preserve-on-update' "${config_dir}/config.yml" && printf present)" 'updating preserves config.yml'
  assert_equal '1' "$(grep -Fxc '# >>> mcserver-kit PATH >>>' "$shell_rc")" 'updating does not duplicate the PATH block'

  "${bin_dir}/mcserver-kit" uninstall >>"$install_log"
  assert_equal 'absent' "$([[ ! -d "$install_dir" ]] && printf absent)" 'the uninstaller removes installed program files'
  assert_equal 'present' "$([[ -f "${config_dir}/config.yml" ]] && printf present)" 'the uninstaller preserves config by default'
  assert_equal 'absent' "$(! grep -q 'mcserver-kit PATH' "$shell_rc" && printf absent)" 'the uninstaller removes its managed PATH block'
}

test_setup_command() {
  local temp_dir="$1"
  local config_file="${temp_dir}/setup/config.yml"
  local template_dir="${temp_dir}/setup/templates"
  local setup_log="${temp_dir}/setup/setup.log"

  mkdir -p "$(dirname -- "$setup_log")"
  printf '%s\n' \
    'TestOwner' \
    'y' \
    'y' \
    'PlayerTwo' \
    '' \
    'y' \
    '' \
    'y' \
    'playit-secret-for-test' \
    '' \
    '' \
    'y' \
    'y' \
    '' |
    MCSERVER_KIT_CONFIG="$config_file" \
      MCSERVER_KIT_MCID_TEMPLATE_DIR="$template_dir" \
      bash "${REPO_ROOT}/mcserver-kit" setup >"$setup_log" 2>&1

  assert_equal 'present' "$(grep -q 'minecraft_id: "TestOwner"' "$config_file" && printf present)" 'setup writes the Owner MCID'
  assert_equal 'present' "$(grep -q 'completed: true' "$config_file" && printf present)" 'setup marks the initial configuration complete'
  assert_equal 'present' "$(grep -q 'secret_key: "playit-secret-for-test"' "$config_file" && printf present)" 'setup writes the Playit secret'
  assert_equal 'present' "$(grep -q '^PlayerTwo$' "${template_dir}/default.txt" && printf present)" 'setup creates the default whitelist template'
  assert_equal '600' "$(stat -c '%a' "$config_file")" 'setup restricts config.yml permissions'
  assert_equal 'absent' "$(! grep -q 'playit-secret-for-test' "$setup_log" && printf absent)" 'setup does not print the Playit secret'
  assert_equal 'absent' "$(! grep -q 'EULAHave' "$setup_log" && printf absent)" 'setup separates the EULA URL from its prompt'
  assert_equal 'absent' "$(! grep -q 'finish.MCID' "$setup_log" && printf absent)" 'setup separates MCID instructions from the prompt'
  assert_equal '10' "$(tail -c 1 "$setup_log" | od -An -tu1 | tr -d ' ')" 'setup output ends with a newline'
}

test_reset_command() {
  local temp_dir="$1"
  local config_dir="${temp_dir}/reset/config"
  local config_file="${config_dir}/config.yml"
  local template_dir="${config_dir}/mcid-templates"
  local language_file="${config_dir}/language"
  local server_dir="${temp_dir}/reset/servers/keep-me"

  mkdir -p "$template_dir" "$server_dir"
  : >"$config_file"
  printf 'ja\n' >"$language_file"
  : >"${template_dir}/default.txt"
  : >"${server_dir}/level.dat"

    MCSERVER_KIT_CONFIG="$config_file" \
    MCSERVER_KIT_MCID_TEMPLATE_DIR="$template_dir" \
    MCSERVER_KIT_LANGUAGE_FILE="$language_file" \
    bash "${REPO_ROOT}/mcserver-kit" --lang en reset --yes >/dev/null

  assert_equal 'absent' "$([[ ! -f "$config_file" ]] && printf absent)" 'reset removes config.yml'
  assert_equal 'absent' "$([[ ! -d "$template_dir" ]] && printf absent)" 'reset removes MCID templates'
  assert_equal 'absent' "$([[ ! -f "$language_file" ]] && printf absent)" 'reset removes the persistent language preference'
  assert_equal 'present' "$([[ -f "${server_dir}/level.dat" ]] && printf present)" 'reset preserves created servers and worlds'
}

test_config_value_editor() {
  local temp_dir="$1"
  local config_file="${temp_dir}/config-editor/config.yml"
  mkdir -p "$(dirname -- "$config_file")"
  cat >"$config_file" <<'CONFIG'
owner:
  minecraft_id: "BeforeOwner"
access:
  whitelist_template: "default"
CONFIG
  chmod 600 "$config_file"

  assert_equal 'BeforeOwner' "$(python3 "${REPO_ROOT}/scripts/config-value.py" get "$config_file" owner minecraft_id)" 'config editor reads scalar values'
  python3 "${REPO_ROOT}/scripts/config-value.py" set "$config_file" owner minecraft_id 'AfterOwner'
  assert_equal 'AfterOwner' "$(python3 "${REPO_ROOT}/scripts/config-value.py" get "$config_file" owner minecraft_id)" 'config editor updates scalar values'
  assert_equal 'default' "$(python3 "${REPO_ROOT}/scripts/config-value.py" get "$config_file" access whitelist_template)" 'config editor preserves unrelated settings'
  assert_equal '600' "$(stat -c '%a' "$config_file")" 'config editor preserves restricted permissions'
}

test_server_management() {
  local temp_dir="$1"
  local root="${temp_dir}/server-management/servers"
  local config_file="${temp_dir}/server-management/config.yml"
  local fake_bin="${temp_dir}/server-management/bin"
  local docker_log="${temp_dir}/server-management/docker.log"
  local output

  mkdir -p "${root}/alpha/data" "$fake_bin"
  : >"${root}/alpha/compose.yaml"
  cat >"$config_file" <<CONFIG
paths:
  server_root: "$root"
CONFIG
  cat >"${fake_bin}/docker" <<'DOCKER'
#!/usr/bin/env bash
printf '%s|%s\n' "$PWD" "$*" >>"$MCSERVER_KIT_TEST_DOCKER_LOG"
if [[ "$*" == 'compose ps --status running --services' ]]; then
  printf 'minecraft\n'
fi
DOCKER
  chmod +x "${fake_bin}/docker"

  output="$(PATH="${fake_bin}:$PATH" MCSERVER_KIT_LANG=en MCSERVER_KIT_CONFIG="$config_file" \
    MCSERVER_KIT_TEST_DOCKER_LOG="$docker_log" bash "${REPO_ROOT}/mcserver-kit" list)"
  assert_equal 'present' "$(grep -q 'alpha.*running' <<<"$output" && printf present)" 'list shows managed servers and their status'

  PATH="${fake_bin}:$PATH" MCSERVER_KIT_LANG=en MCSERVER_KIT_CONFIG="$config_file" \
    MCSERVER_KIT_TEST_DOCKER_LOG="$docker_log" bash "${REPO_ROOT}/mcserver-kit" server alpha start >/dev/null
  assert_equal 'present' "$(grep -qF "${root}/alpha|compose config --quiet" "$docker_log" && printf present)" 'start validates compose in the selected server directory'
  assert_equal 'present' "$(grep -qF "${root}/alpha|compose up -d" "$docker_log" && printf present)" 'start launches the selected server'

  PATH="${fake_bin}:$PATH" MCSERVER_KIT_LANG=en MCSERVER_KIT_CONFIG="$config_file" \
    MCSERVER_KIT_TEST_DOCKER_LOG="$docker_log" bash "${REPO_ROOT}/mcserver-kit" server alpha shutdown >/dev/null
  assert_equal 'present' "$(grep -qF "${root}/alpha|compose stop" "$docker_log" && printf present)" 'shutdown stops the selected server without deleting its data'

  assert_fails 'server IDs cannot traverse outside the configured root' \
    env PATH="${fake_bin}:$PATH" MCSERVER_KIT_LANG=en MCSERVER_KIT_CONFIG="$config_file" \
      MCSERVER_KIT_TEST_DOCKER_LOG="$docker_log" bash "${REPO_ROOT}/mcserver-kit" server ../alpha status
}

test_server_property_editor() {
  local temp_dir="$1"
  local properties="${temp_dir}/property-editor/server.properties"
  mkdir -p "$(dirname -- "$properties")"
  cat >"$properties" <<'PROPERTIES'
#Minecraft server properties
difficulty=easy
pvp=true
view-distance=10
PROPERTIES
  chmod 600 "$properties"

  assert_equal 'easy' "$(python3 "${REPO_ROOT}/scripts/server-property.py" get "$properties" difficulty)" 'property editor reads an existing value'
  python3 "${REPO_ROOT}/scripts/server-property.py" set "$properties" difficulty hard
  assert_equal 'hard' "$(python3 "${REPO_ROOT}/scripts/server-property.py" get "$properties" difficulty)" 'property editor replaces an existing value'
  python3 "${REPO_ROOT}/scripts/server-property.py" set "$properties" simulation-distance 8
  assert_equal '8' "$(python3 "${REPO_ROOT}/scripts/server-property.py" get "$properties" simulation-distance)" 'property editor appends a missing value'
  assert_equal 'present' "$(grep -q '^#Minecraft server properties$' "$properties" && printf present)" 'property editor preserves comments'
  assert_equal '600' "$(stat -c '%a' "$properties")" 'property editor preserves file permissions'
  assert_fails 'property values cannot contain newlines' \
    python3 "${REPO_ROOT}/scripts/server-property.py" set "$properties" motd $'bad\nvalue'
}

main() {
  TEST_TEMP_DIR="$(mktemp -d)"
  trap cleanup EXIT

  test_version_resolution
  test_locales
  test_installer_version_selection
  test_setup_gate "$TEST_TEMP_DIR"
  test_input_normalization
  test_world_discovery "$TEST_TEMP_DIR"
  test_saved_version_detection "$TEST_TEMP_DIR"
  test_nested_zip_import "$TEST_TEMP_DIR"
  test_creation_flow "$TEST_TEMP_DIR"
  test_local_installation "$TEST_TEMP_DIR"
  test_setup_command "$TEST_TEMP_DIR"
  test_reset_command "$TEST_TEMP_DIR"
  test_config_value_editor "$TEST_TEMP_DIR"
  test_server_management "$TEST_TEMP_DIR"
  test_server_property_editor "$TEST_TEMP_DIR"

  printf 'PASS: %d specification tests, %d skipped\n' "$tests_run" "$tests_skipped"
}

main "$@"
