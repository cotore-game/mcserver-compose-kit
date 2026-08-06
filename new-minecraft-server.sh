#!/usr/bin/env bash
set -Eeuo pipefail

# Minecraft Java 配布ワールド用 Docker Compose ジェネレーター
# 実設定は config.yml、公開可能な見本は config.example.yml に分離します。

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${MCSERVER_KIT_CONFIG:-${SCRIPT_DIR}/config.yml}"
CONFIG_EXAMPLE="${SCRIPT_DIR}/config.example.yml"
MCID_TEMPLATE_DIR="${MCSERVER_KIT_MCID_TEMPLATE_DIR:-${SCRIPT_DIR}/mcid-templates}"
VERSION_DETECTOR="${SCRIPT_DIR}/scripts/detect-world-version.py"
WINDOWS_DIALOG="${SCRIPT_DIR}/scripts/windows-dialog.ps1"

die() {
  printf 'エラー: %s\n' "$*" >&2
  exit 1
}

log_step() {
  printf '\n[%s] %s\n' "$1" "$2" >&2
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

prompt() {
  local message="$1"
  local default_value="${2-}"
  local answer

  if [[ -n "$default_value" ]]; then
    read -r -p "${message} [${default_value}]: " answer
    printf '%s' "${answer:-$default_value}"
  else
    read -r -p "${message}: " answer
    printf '%s' "$answer"
  fi
}

windows_dialog_available() {
  [[ "${windows_dialogs_enabled:-true}" == 'true' ]] || return 1
  command -v wslpath >/dev/null 2>&1 || return 1
  [[ -x /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe ]] || return 1
  [[ -f "$WINDOWS_DIALOG" ]]
}

run_windows_dialog() {
  local mode="$1"
  local default_value="${2-}"
  local dialog_path
  local encoded

  dialog_path="$(wslpath -w "$WINDOWS_DIALOG")"
  encoded="$(/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe \
    -NoProfile -ExecutionPolicy Bypass -File "$dialog_path" \
    -Mode "$mode" -DefaultValue "$default_value" 2>/dev/null)" || return 1
  encoded="${encoded//$'\r'/}"
  printf '%s' "$encoded" | base64 --decode
}

prompt_server_name() {
  local default_value="$1"
  local result

  if windows_dialog_available && result="$(run_windows_dialog InputMotd "$default_value")"; then
    printf '%s' "$result"
    return
  fi
  prompt '表示名/MOTD' "$default_value"
}

prompt_bool() {
  local message="$1"
  local default_value="$2"
  local hint
  local answer

  if is_true "$default_value"; then
    hint='Y/n'
  else
    hint='y/N'
  fi

  while true; do
    read -r -p "${message} [${hint}]: " answer
    answer="${answer:-$default_value}"

    case "${answer,,}" in
      y | yes | true | on | 1)
        printf 'true'
        return
        ;;
      n | no | false | off | 0)
        printf 'false'
        return
        ;;
      *)
        printf '入力エラー: y または n を入力してください。\n' >&2
        ;;
    esac
  done
}

is_true() {
  case "${1,,}" in
    y | yes | true | on | 1)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# このツールが生成する単純な2階層YAMLを読むための最小パーサーです。
# 任意のYAML構文をサポートするものではありません。
yaml_get() {
  local path="$1"
  local default_value="${2-}"
  local result

  result="$(
    awk -v target="$path" '
      function ltrim(s) { sub(/^[[:space:]]+/, "", s); return s }
      function rtrim(s) { sub(/[[:space:]]+$/, "", s); return s }
      function trim(s) { return rtrim(ltrim(s)) }
      function unquote(s, first, last) {
        s = trim(s)
        first = substr(s, 1, 1)
        last = substr(s, length(s), 1)
        if ((first == "\"" && last == "\"") || (first == "\047" && last == "\047")) {
          return substr(s, 2, length(s) - 2)
        }
        sub(/[[:space:]]+#.*$/, "", s)
        return trim(s)
      }
      /^[[:space:]]*($|#)/ { next }
      {
        match($0, /^[ ]*/)
        indent = RLENGTH
        if (indent % 2 != 0) {
          next
        }

        level = indent / 2
        line = substr($0, indent + 1)
        colon = index(line, ":")
        if (colon == 0) {
          next
        }

        key = trim(substr(line, 1, colon - 1))
        value = trim(substr(line, colon + 1))
        keys[level] = key
        for (i = level + 1; i < 8; i++) {
          delete keys[i]
        }

        if (value == "") {
          next
        }

        current = keys[0]
        for (i = 1; i <= level; i++) {
          current = current "." keys[i]
        }

        if (current == target) {
          print unquote(value)
          found = 1
          exit
        }
      }
      END {
        if (!found) {
          exit 1
        }
      }
    ' "$CONFIG_FILE" 2>/dev/null
  )" || true

  printf '%s' "${result:-$default_value}"
}

expand_path() {
  local value="$1"
  value="${value//\$\{HOME\}/$HOME}"
  if [[ "${value:0:2}" == "~/" ]]; then
    value="${HOME}/${value#\~/}"
  fi
  printf '%s' "$value"
}

escape_env_value() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

normalize_memory() {
  local value="$1"

  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%sG' "$value"
    return
  fi

  if [[ "$value" =~ ^[0-9]+[GgMm]$ ]]; then
    printf '%s' "${value^^}"
    return
  fi

  return 1
}

windows_to_wsl_path() {
  local value
  local drive

  value="$(trim "$1")"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  value="${value//\\//}"

  if [[ "$value" =~ ^([A-Za-z]):(/.*)?$ ]]; then
    drive="${BASH_REMATCH[1],,}"
    value="/mnt/${drive}${BASH_REMATCH[2]}"
  fi

  expand_path "$value"
}

find_world_roots() {
  local search_root="$1"

  if [[ -f "${search_root}/level.dat" ]]; then
    printf '%s\0' "$search_root"
    return
  fi

  [[ -d "$search_root" ]] || return
  find "$search_root" -mindepth 2 -maxdepth 7 -type f -name level.dat -printf '%h\0' 2>/dev/null
}
resolve_world_source() {
  local input_path="$1" converted parent name candidate
  local candidates=() roots=()
  converted="$(windows_to_wsl_path "$input_path")"
  if [[ -f "$converted" && "${converted,,}" == *.zip ]]; then printf '%s' "$converted"; return; fi
  if [[ -d "$converted" ]]; then
    mapfile -d '' roots < <(find_world_roots "$converted")
  elif [[ ! -e "$converted" ]]; then
    parent="$(dirname -- "$converted")"; name="$(basename -- "$converted")"
    if [[ -d "$parent" && -n "$name" ]]; then
      mapfile -d '' candidates < <(find "$parent" -mindepth 1 -maxdepth 1 \( -type d -o -type f \) -name "${name}*" -print0 2>/dev/null)
      for candidate in "${candidates[@]}"; do
        if [[ -f "$candidate" && "${candidate,,}" == *.zip ]]; then roots+=("$candidate")
        elif [[ -d "$candidate" ]]; then mapfile -d '' -O "${#roots[@]}" roots < <(find_world_roots "$candidate"); fi
      done
    fi
  fi
  if [[ "${#roots[@]}" -eq 1 ]]; then printf '%s' "${roots[0]}"; return; fi
  if [[ "${#roots[@]}" -gt 1 ]]; then
    printf '入力エラー: ワールド候補が複数見つかりました。次のいずれかを直接指定してください:\n' >&2; printf '  %s\n' "${roots[@]}" >&2
  else printf '入力エラー: level.datを含むワールドまたはZIPが見つかりません: %s\n' "$converted" >&2; fi
  return 1
}
prompt_world_source() {
  local answer=''
  local resolved

  while true; do
    if windows_dialog_available; then
      printf 'Windowsの選択画面を開いています。画面の手前に表示されない場合はタスクバーを確認してください。\n' >&2
      answer="$(run_windows_dialog SelectWorld)" || answer=''
    fi
    if [[ -z "$answer" ]]; then
      answer="$(prompt '配布ワールドのフォルダまたはZIP（Windowsパスも可）')"
    fi
    if resolved="$(resolve_world_source "$answer")"; then
      printf 'ワールドを検出しました: %s\n' "$resolved" >&2
      printf '%s' "$resolved"
      return
    fi
  done
}

detect_world_version() {
  local source_path="$1"

  [[ -f "$VERSION_DETECTOR" ]] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  python3 "$VERSION_DETECTOR" "$source_path"
}

resolve_minecraft_image() {
  local version="$1"
  local configured_tag="$2"
  local java_tag

  if [[ "$configured_tag" != "auto" ]]; then
    printf 'itzg/minecraft-server:%s' "$configured_tag"
    return
  fi

  case "$version" in
    LATEST | 26.*)
      java_tag='java25'
      ;;
    1.21 | 1.21.* | 1.20.[5-9] | 1.20.[5-9].*)
      java_tag='java21'
      ;;
    1.18 | 1.18.* | 1.19 | 1.19.* | 1.20 | 1.20.[0-4] | 1.20.[0-4].*)
      java_tag='java17'
      ;;
    *)
      die "Minecraft ${version}のJavaを自動判定できません。config.ymlのdocker.java_image_tagを明示してください"
      ;;
  esac

  printf 'itzg/minecraft-server:%s' "$java_tag"
}

validate_mcid() {
  [[ "$1" =~ ^[A-Za-z0-9_]{3,16}$ ]]
}

load_mcid_template() {
  local template_name="$1"
  local owner_mcid="$2"
  local template_path
  local line
  local ids=()
  local joined

  [[ "$template_name" =~ ^[A-Za-z0-9_-]+$ ]] ||
    die "MCIDテンプレート名が不正です: ${template_name}"

  template_path="${MCID_TEMPLATE_DIR}/${template_name}.txt"
  [[ -f "$template_path" ]] ||
    die "MCIDテンプレートがありません: ${template_path}"

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="${line%%#*}"
    line="$(trim "$line")"
    [[ -z "$line" ]] && continue

    if [[ "$line" == "\${OWNER}" ]]; then
      line="$owner_mcid"
    fi

    validate_mcid "$line" ||
      die "${template_path}に不正なMCIDがあります: ${line}"
    ids+=("$line")
  done <"$template_path"

  [[ "${#ids[@]}" -gt 0 ]] ||
    die "MCIDテンプレートが空です: ${template_path}"

  joined="$(printf '%s\n' "${ids[@]}" | awk '!seen[tolower($0)]++' | paste -sd, -)"
  printf '%s' "$joined"
}

show_mcid_templates() {
  local file

  printf '\n利用できるMCIDテンプレート:\n' >&2
  shopt -s nullglob
  for file in "${MCID_TEMPLATE_DIR}"/*.txt; do
    printf '  - %s\n' "$(basename "$file" .txt)" >&2
  done
  shopt -u nullglob
}

copy_world() {
  local source_path="$1"
  local destination="$2"
  local extracted_root
  local level_files
  local level_file

  if [[ -d "$source_path" ]]; then
    [[ -f "${source_path}/level.dat" ]] ||
      die "指定フォルダ直下にlevel.datがありません: ${source_path}"
    cp -a "$source_path" "$destination"
    return
  fi

  if [[ -f "$source_path" && "${source_path,,}" == *.zip ]]; then
    command -v unzip >/dev/null 2>&1 ||
      die "ZIPの展開にunzipが必要です: sudo apt install unzip"

    extracted_root="$(mktemp -d)"
    unzip -q "$source_path" -d "$extracted_root"
    level_files="$(find "$extracted_root" -type f -name level.dat -print)"

    if [[ "$(printf '%s\n' "$level_files" | sed '/^$/d' | wc -l)" -ne 1 ]]; then
      rm -rf -- "$extracted_root"
      die "ZIP内のワールドを一意に判定できません。展開してlevel.datを含むフォルダを指定してください"
    fi

    level_file="$level_files"
    cp -a "$(dirname "$level_file")" "$destination"
    rm -rf -- "$extracted_root"
    return
  fi

  die "level.datを含むワールドフォルダ、またはZIPを指定してください"
}

main() {
[[ -f "$CONFIG_FILE" ]] || {
  printf '%s\n' \
    "設定ファイルがありません: ${CONFIG_FILE}" \
    "次のコマンドで見本をコピーし、秘密情報を記入してください:" \
    "  cp \"${CONFIG_EXAMPLE}\" \"${SCRIPT_DIR}/config.yml\"" \
    "  chmod 600 \"${SCRIPT_DIR}/config.yml\""
  exit 1
}

[[ -d "$MCID_TEMPLATE_DIR" ]] ||
  die "MCIDテンプレートディレクトリがありません: ${MCID_TEMPLATE_DIR}"

owner_mcid="$(yaml_get 'owner.minecraft_id')"
validate_mcid "$owner_mcid" ||
  die "config.ymlのowner.minecraft_idを設定してください"

accept_eula="$(yaml_get 'minecraft.accept_eula' 'false')"
is_true "$accept_eula" ||
  die "Minecraft EULAを確認し、同意する場合はconfig.ymlのminecraft.accept_eulaをtrueにしてください"

server_root="$(expand_path "$(yaml_get 'paths.server_root' "\${HOME}/minecraftServer")")"
default_version="$(yaml_get 'defaults.minecraft_version' '26.2')"
default_memory="$(yaml_get 'defaults.java_memory' '8G')"
default_start_after_creation="$(yaml_get 'defaults.start_after_creation' 'false')"
timezone="$(yaml_get 'defaults.timezone' 'Asia/Tokyo')"
max_players="$(yaml_get 'defaults.max_players' '8')"
online_mode="$(yaml_get 'defaults.online_mode' 'true')"
enable_command_block="$(yaml_get 'defaults.enable_command_block' 'true')"
allow_flight="$(yaml_get 'defaults.allow_flight' 'true')"
spawn_protection="$(yaml_get 'defaults.spawn_protection' '0')"
host_port="$(yaml_get 'defaults.host_port' '25565')"
default_whitelist_enabled="$(yaml_get 'access.whitelist_enabled' 'true')"
default_whitelist_template="$(yaml_get 'access.whitelist_template' 'default')"
default_ops_enabled="$(yaml_get 'access.ops_enabled' 'true')"
default_ops_template="$(yaml_get 'access.ops_template' 'owner')"
default_playit_enabled="$(yaml_get 'playit.enabled' 'false')"
playit_secret_key="$(yaml_get 'playit.secret_key')"
playit_image="$(yaml_get 'playit.image' 'ghcr.io/playit-cloud/playit-agent:0.17')"
java_image_tag="$(yaml_get 'docker.java_image_tag' 'auto')"
resource_pack_enforce="$(yaml_get 'resource_pack.enforce' 'true')"
windows_dialogs_enabled="$(yaml_get 'ui.windows_dialogs' 'true')"

printf '%s\n' \
  'Minecraft Java 配布ワールド用サーバー作成' \
  '------------------------------------------' \
  "オーナー: ${owner_mcid}" \
  "作成先: ${server_root}/<server-id>" \
  '既存サーバーは変更せず、新しいフォルダを作成します。' \
  ''

while true; do
  server_id="$(prompt 'サーバーID（英小文字・数字・ハイフン）')"
  if [[ ! "$server_id" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    printf '入力エラー: 英小文字・数字・ハイフンだけにしてください。\n' >&2
    continue
  fi
  target="${server_root}/${server_id}"
  if [[ -e "$target" ]]; then
    printf '入力エラー: 作成先が既に存在します: %s\n' "$target" >&2
    continue
  fi
  break
done

server_name="$(prompt_server_name "$server_id")"
world_source="$(prompt_world_source)"

detected_version=""
log_step '確認' 'ワールドに保存されたMinecraftバージョンを調べています。'
if detected_version="$(detect_world_version "$world_source" 2>/dev/null)"; then
  default_version="$detected_version"
  printf '検出したバージョン: %s（Enterで採用）\n' "$detected_version"
else
  printf 'バージョンを自動検出できなかったため、設定値 %s を候補にします。\n' "$default_version"
fi

while true; do
  version="$(prompt 'Minecraftバージョン（例: 26.2 / 1.21.2）' "$default_version")"
  if [[ ! "$version" =~ ^[0-9]+([.][0-9]+){1,2}$ && "$version" != "LATEST" ]]; then
    printf '入力エラー: 26.2、1.21.2、LATESTのように指定してください。\n' >&2
    continue
  fi
  if minecraft_image="$(resolve_minecraft_image "$version" "$java_image_tag")"; then
    break
  fi
done

while true; do
  memory_input="$(prompt 'Javaメモリ（8 / 8G / 8192M）' "$default_memory")"
  if memory="$(normalize_memory "$memory_input")"; then
    break
  fi
  printf '入力エラー: 8、8G、8192Mのように指定してください。\n' >&2
done

show_mcid_templates
whitelist_enabled="$(prompt_bool 'ホワイトリストを有効にしますか？' "$default_whitelist_enabled")"
whitelist_template=""
whitelist_ids=""
if is_true "$whitelist_enabled"; then
  whitelist_template="$(prompt 'ホワイトリスト用MCIDテンプレート' "$default_whitelist_template")"
  whitelist_ids="$(load_mcid_template "$whitelist_template" "$owner_mcid")"
fi

ops_enabled="$(prompt_bool 'OPを自動付与しますか？' "$default_ops_enabled")"
ops_template=""
ops_ids=""
if is_true "$ops_enabled"; then
  ops_template="$(prompt 'OP用MCIDテンプレート' "$default_ops_template")"
  ops_ids="$(load_mcid_template "$ops_template" "$owner_mcid")"
fi

resource_pack_enabled="$(prompt_bool '専用リソースパックをサーバーから配信しますか？' 'false')"
resource_pack_url=""
resource_pack_sha1=""
resource_pack_id=""
if is_true "$resource_pack_enabled"; then
  resource_pack_url="$(prompt 'リソースパックの直接ダウンロードURL')"
  [[ "$resource_pack_url" =~ ^https:// ]] ||
    die "リソースパックURLはhttps://で始まる直接ダウンロードURLにしてください"

  resource_pack_sha1="$(prompt 'リソースパックのSHA-1（40桁）')"
  resource_pack_sha1="${resource_pack_sha1,,}"
  [[ "$resource_pack_sha1" =~ ^[0-9a-f]{40}$ ]] ||
    die "SHA-1は40桁の16進数で指定してください"

  resource_pack_id="$(prompt 'Resource Pack ID（UUID、なければ空Enter）')"
  if [[ -n "$resource_pack_id" ]]; then
    [[ "$resource_pack_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] ||
      die "Resource Pack IDのUUID形式が正しくありません"
  fi
fi

playit_enabled="$(prompt_bool 'Playitを一緒に構成しますか？' "$default_playit_enabled")"
if is_true "$playit_enabled" && [[ -z "$playit_secret_key" ]]; then
  die "Playitが有効ですが、config.ymlのplayit.secret_keyが空です"
fi

start_after_creation="$(prompt_bool '作成後すぐにDocker Composeで起動しますか？' "$default_start_after_creation")"

target="${server_root}/${server_id}"
[[ ! -e "$target" ]] ||
  die "作成先が既に存在します。上書きはしません: ${target}"

log_step '1/5' "作成先を準備しています: ${target}"
mkdir -p "${target}/data"

log_step '2/5' 'ワールドデータを確認・コピーしています。ZIPの場合は展開に時間がかかることがあります。'
copy_world "$world_source" "${target}/data/world"

log_step '3/5' '.envとCompose設定を生成しています。'
{
  printf 'SERVER_ID=%s\n' "$(escape_env_value "$server_id")"
  printf 'MC_VERSION=%s\n' "$(escape_env_value "$version")"
  printf 'MC_MEMORY=%s\n' "$(escape_env_value "$memory")"
  printf 'MC_MOTD=%s\n' "$(escape_env_value "$server_name")"
  if is_true "$whitelist_enabled"; then
    printf 'MC_WHITELIST=%s\n' "$(escape_env_value "$whitelist_ids")"
  fi
  if is_true "$ops_enabled"; then
    printf 'MC_OPS=%s\n' "$(escape_env_value "$ops_ids")"
  fi
  if is_true "$playit_enabled"; then
    printf 'PLAYIT_SECRET_KEY=%s\n' "$(escape_env_value "$playit_secret_key")"
  fi
} >"${target}/.env"
chmod 600 "${target}/.env"

cat >"${target}/compose.yaml" <<COMPOSE
services:
  minecraft:
    image: ${minecraft_image}
    container_name: "minecraft-\${SERVER_ID}"
    restart: unless-stopped
    tty: true
    stdin_open: true

    ports:
      - "127.0.0.1:${host_port}:25565"

    environment:
      EULA: "TRUE"
      TYPE: "VANILLA"
      VERSION: "\${MC_VERSION}"
      MEMORY: "\${MC_MEMORY}"
      TZ: "${timezone}"

      LEVEL: "world"
      ONLINE_MODE: "${online_mode^^}"
COMPOSE

if is_true "$whitelist_enabled"; then
  cat >>"${target}/compose.yaml" <<'COMPOSE'
      WHITELIST: "${MC_WHITELIST}"
      ENFORCE_WHITELIST: "TRUE"
COMPOSE
else
  cat >>"${target}/compose.yaml" <<'COMPOSE'
      ENABLE_WHITELIST: "FALSE"
COMPOSE
fi

if is_true "$ops_enabled"; then
  cat >>"${target}/compose.yaml" <<'COMPOSE'
      OPS: "${MC_OPS}"
COMPOSE
fi

if is_true "$resource_pack_enabled"; then
  {
    printf '      RESOURCE_PACK: %s\n' "$(escape_env_value "$resource_pack_url")"
    printf '      RESOURCE_PACK_SHA1: %s\n' "$(escape_env_value "$resource_pack_sha1")"
    printf '      RESOURCE_PACK_ENFORCE: "%s"\n' "${resource_pack_enforce^^}"
    if [[ -n "$resource_pack_id" ]]; then
      printf '      RESOURCE_PACK_ID: %s\n' "$(escape_env_value "$resource_pack_id")"
    fi
  } >>"${target}/compose.yaml"
fi

cat >>"${target}/compose.yaml" <<COMPOSE
      ENABLE_COMMAND_BLOCK: "${enable_command_block^^}"
      ALLOW_FLIGHT: "${allow_flight^^}"
      SPAWN_PROTECTION: "${spawn_protection}"
      MAX_PLAYERS: "${max_players}"
      MOTD: "\${MC_MOTD}"

    volumes:
      - ./data:/data
COMPOSE

if is_true "$playit_enabled"; then
  cat >>"${target}/compose.yaml" <<COMPOSE

  playit:
    image: ${playit_image}
    container_name: "playit-\${SERVER_ID}"
    restart: unless-stopped
    network_mode: "service:minecraft"

    depends_on:
      minecraft:
        condition: service_healthy

    environment:
      SECRET_KEY: "\${PLAYIT_SECRET_KEY}"
COMPOSE
fi

log_step '4/5' 'サーバー操作用READMEを生成しています。'
cat >"${target}/README.txt" <<EOF
サーバー名: ${server_name}
Minecraft: ${version}
Docker image: ${minecraft_image}
メモリ: ${memory}
ホワイトリスト: $([[ "$whitelist_enabled" == 'true' ]] && printf '%s' "$whitelist_template" || printf '無効')
OP: $([[ "$ops_enabled" == 'true' ]] && printf '%s' "$ops_template" || printf '自動付与なし')
リソースパック配信: $([[ "$resource_pack_enabled" == 'true' ]] && printf 'あり' || printf 'なし')
Playit: $([[ "$playit_enabled" == 'true' ]] && printf 'あり' || printf 'なし')

起動:
  cd ${target}
  docker compose config --quiet
  docker compose up -d

状態確認:
  docker compose ps
  docker compose logs -f minecraft

停止:
  docker compose down

重要:
  data/ がワールドとプレイヤーデータです。削除しないでください。
  同じホストポートを使う別サーバーとは同時起動できません。
EOF

log_step '5/5' 'Docker Compose設定を検証しています。'
(
  cd "$target"
  docker compose config --quiet
) || die "Docker Compose設定の検証に失敗しました: ${target}/compose.yaml"

printf '\n作成しました: %s\n\n' "$target"
if is_true "$start_after_creation"; then
  log_step '起動' 'Dockerイメージの取得とサーバー起動を開始します。初回は数分かかることがあります。'
  (
    cd "$target"
    docker compose up -d
    printf '\n現在のコンテナ状態:\n'
    docker compose ps
  ) || die "サーバーの起動に失敗しました。次でログを確認してください: cd \"${target}\" && docker compose logs"
  printf '\n起動処理が完了しました。Minecraftサーバーの準備完了まではログで確認できます:\n'
  printf '  cd "%s" && docker compose logs -f minecraft\n' "$target"
else
  printf '%s\n' \
    'サーバーはまだ起動していません。起動する場合は次を実行してください:' \
    "  cd \"${target}\"" \
    '  docker compose up -d'
fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
