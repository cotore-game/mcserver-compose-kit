# mcserver-tool-kit

WSL2とDocker Desktopを使い、Minecraft Javaの配布ワールドから独立したサーバー構成を作る対話式ツールです。

サーバーごとに`compose.yaml`、`.env`、`data/world`を生成し、確認後にそのまま起動することもできます。

## 簡単インストール

Docker Desktop、WSL2、Docker DesktopのWSL Integrationが設定済みであることを前提とします。

```bash
curl -fsSL https://raw.githubusercontent.com/cotore-game/mcserver-compose-kit/main/install.sh | bash
```

バージョンを固定する場合は、`bash -s --`以降へ指定します。

```bash
curl -fsSL https://raw.githubusercontent.com/cotore-game/mcserver-compose-kit/main/install.sh | \
  bash -s -- --version v0.2.0
```

`MCSERVER_KIT_VERSION=v0.2.0`環境変数でも指定できます。省略時は最新Releaseを使用します。

インストーラーは最新のGitHub Releaseを取得してSHA-256を検証します。不足している`python3`や`unzip`は、確認後に`sudo apt`で導入できます。インストール後は次で起動します。

```bash
mcserver-kit
```

主なサブコマンド：

```bash
mcserver-kit                 # 新しいサーバーを作成
mcserver-kit setup           # 初回設定・再設定
mcserver-kit uninstall       # 設定を残してアンインストール
mcserver-kit uninstall --purge
mcserver-kit --help
```

### Language / 言語

By default, the language is selected from`LANG`（`ja*`は日本語、それ以外は英語）. You can override it for a command:

デフォルトでは`LANG`から言語を選択します（`ja*`は日本語、それ以外は英語）。コマンド単位でも指定できます。

```bash
mcserver-kit --lang en --help
mcserver-kit --lang ja setup
```

Translations are stored in`locales/*.json`. To add a language, copy`locales/en.json`, translate the values without changing the keys, and submit a pull request.

翻訳は`locales/*.json`にあります。言語を追加する場合は`locales/en.json`を複製し、キーを変えずに値を翻訳してPRを作成してください。

```bash
python3 scripts/validate-locales.py
```

CI verifies JSON syntax, empty translations, and key parity with the English catalog.

保存先は次のとおりです。

- 本体: `~/.local/share/mcserver-compose-kit`
- 設定とMCIDテンプレート: `~/.config/mcserver-compose-kit`
- 起動コマンド: `~/.local/bin/mcserver-kit`

同じインストールコマンドを再実行すると、本体だけを更新して設定を保持します。設定をやり直す場合：

```bash
mcserver-kit setup
```

アンインストール時は通常、設定を残します。

```bash
mcserver-kit uninstall
```

設定とMCIDテンプレートも含めて削除する場合：

```bash
mcserver-kit uninstall --purge
```

## Windows入力ダイアログ

WSLからWindows PowerShellを呼び、ExplorerによるZIP／フォルダ選択と、Windows IMEを使えるMOTD入力画面を表示します。追加のWindowsアプリは不要です。

Windowsダイアログを利用できない場合やキャンセルした場合は、従来のターミナル入力へ戻ります。無効にする場合は`config.yml`へ次を設定します。

```yaml
ui:
  windows_dialogs: false
```

## 主な機能

- フォルダまたはZIP形式の配布ワールドを取り込み
- Minecraftバージョンに合わせたJavaイメージの自動選択
- 数字だけでも指定できるJavaメモリ設定
- MCIDテンプレートをホワイトリストとOPの両方で再利用
- オーナーMCIDを`${OWNER}`としてテンプレートへ展開
- リソースパックURL、SHA-1、任意のUUIDを設定
- Playitエージェントを同じComposeへ追加
- 秘密情報を`config.yml`へ分離
- 既存フォルダを上書きしない

## 必要な環境

- WSL2上のLinux
- Docker DesktopのWSL Integration
- Docker Compose v2
- Bash
- ZIPを直接取り込む場合のみ`unzip`

確認：

```bash
docker version
docker compose version
```

## セットアップ

リポジトリを取得し、スクリプトへ実行権限を付けます。

```bash
git clone <repository-url> mcserver-tool-kit
cd mcserver-tool-kit
chmod +x new-minecraft-server.sh
```

公開用の設定例を、実設定へコピーします。

```bash
cp config.example.yml config.yml
chmod 600 config.yml
```

`config.yml`はGit管理から除外されています。

## config.yml

```yaml
owner:
  minecraft_id: "c0tt0n_rain"

minecraft:
  # https://aka.ms/MinecraftEULA を確認し、同意する場合だけtrue
  accept_eula: true

paths:
  server_root: "${HOME}/minecraftServer"

defaults:
  minecraft_version: "26.2"
  java_memory: "8G"
  timezone: "Asia/Tokyo"
  max_players: 8
  online_mode: true
  enable_command_block: true
  allow_flight: true
  spawn_protection: 0
  host_port: 25565

access:
  whitelist_enabled: true
  whitelist_template: "default"
  ops_enabled: true
  ops_template: "owner"

playit:
  enabled: true
  secret_key: "ここにPlayitのSECRET_KEY"
  image: "ghcr.io/playit-cloud/playit-agent:0.17"

docker:
  java_image_tag: "auto"

resource_pack:
  enforce: true
```

### 秘密情報

`playit.secret_key`を含む`config.yml`は、GitHubへコミットしないでください。公開するのは空欄の`config.example.yml`だけです。

誤操作を防ぐため、次を確認できます。

```bash
git check-ignore -v config.yml
git status --short
```

## MCIDテンプレート

ホワイトリストとOPは、同じ`mcid-templates`ディレクトリを参照します。

```text
mcid-templates/
├─ owner.txt
├─ Group1.txt
└─ Group2.txt
```

1行に1つMCIDを書きます。空行と`#`以降は無視されます。

```text
# config.ymlのオーナー
${OWNER}

# 固定メンバー
ExamplePlayer
AnotherPlayer
```

`owner.txt`をOP用に、`Group1.txt`をホワイトリスト用に使う、といった設定ができます。

## 使用方法

```bash
./new-minecraft-server.sh
```

入力する内容：

1. サーバーID
2. 表示名／MOTD
3. Minecraftバージョン
4. Javaメモリ
5. 配布ワールドのルートフォルダまたはZIP
6. ホワイトリストの有無とMCIDテンプレート
7. OP自動付与の有無とMCIDテンプレート
8. リソースパック配信情報
9. Playitを使うか

作成先は、既定で次の場所です。

```text
~/minecraftServer/<server-id>
```

## 配布ワールドの指定

指定するのは、直下に`level.dat`があるワールドのルートフォルダです。

```text
Picking Over It/
├─ level.dat
├─ dimensions/
├─ datapacks/
├─ data/
└─ config/
```

サーバーの保存先になる`data`ディレクトリそのものを指定するわけではありません。上記フォルダ全体が、生成先の`data/world`へコピーされます。

Windowsのダウンロードフォルダは、WSLから次のように指定できます。

```text
/mnt/c/Users/<Windowsユーザー名>/Downloads/<配布フォルダ>/<ワールド名>
```

## 入力書式

### Minecraftバージョン

ワールドのフォルダまたはZIPを選ぶと、`level.dat`に保存されたMinecraftバージョンを検出し、入力時のデフォルト値にします。Enterを押せば検出結果を採用できます。

検出できなかった場合は、`config.yml`の`defaults.minecraft_version`を候補にします。配布ページで別のバージョンが指定されている場合は、そちらを手動入力してください。

```text
26.2
1.21.2
LATEST
```

`docker.java_image_tag: "auto"`の場合、現在は次のようにJavaイメージを選びます。

| Minecraft | Dockerイメージタグ |
|---|---|
| `26.x` / `LATEST` | `java25` |
| `1.21` / `1.21.x` / `1.20.5`以降 | `java21` |
| `1.18`～`1.20` / `1.18.x`～`1.20.4` | `java17` |

それより古いバージョンは自動判定せず停止します。必要なJavaタグを`config.yml`へ明示してください。

### Javaメモリ

```text
8       → 8G
8G      → 8G
8192M   → 8192M
```

### 表示名／MOTD

Minecraftのマルチプレイ一覧で、サーバーアドレスの下に表示される説明文です。ワールド名やフォルダ名には影響しません。

### リソースパック

サーバーから配信する場合、次が必要です。

- HTTPSの直接ダウンロードURL
- ZIPのSHA-1
- 任意のResource Pack ID（UUID）

MCPacksなどのMinecraft向け配信サービスを利用できます。

## 生成物

```text
~/minecraftServer/<server-id>/
├─ compose.yaml
├─ .env
├─ README.txt
└─ data/
   └─ world/
```

- `compose.yaml`：Dockerの起動設定
- `.env`：そのサーバー用設定とPlayit秘密鍵。権限`600`
- `README.txt`：起動・停止手順
- `data/`：ワールド、プレイヤー情報、進行状況

## 作成後

作成中は、ワールドのコピー、設定生成、Compose検証などの現在の処理を段階表示します。

最後に、Docker Composeでそのまま起動するか確認します。起動を選んだ場合は、次の処理まで自動で行います。

```bash
docker compose config --quiet
docker compose up -d
docker compose ps
```

初回起動ではDockerイメージの取得に時間がかかることがあります。開始前にその旨を表示し、Docker Composeの進捗をそのまま表示します。

手動で起動する場合：

構成確認：

```bash
cd ~/minecraftServer/<server-id>
docker compose config --quiet
```

起動：

```bash
docker compose up -d
docker compose logs -f minecraft
```

停止：

```bash
docker compose down
```

## 注意事項

- サーバーは自動起動しません。
- 作成先が既に存在する場合は上書きせず停止します。
- 同じホストポートを使うサーバーは同時起動できません。
- 同じPlayitエージェント秘密鍵を使うサーバーも同時起動しないでください。
- MODローダー必須の配布マップは、現在のVANILLA用テンプレートの対象外です。
- `data/`を削除するとワールドと進行状況を失います。

## GitHub公開前の確認

```bash
bash -n new-minecraft-server.sh
bash tests/run-tests.sh
git check-ignore -v config.yml
git status --short
```

`config.yml`や`.env`がステージ対象に含まれていないことを確認してください。

## テスト

仕様テストは、Javaイメージの選択、`level.dat`からの保存バージョン検出、メモリとWindowsパスの正規化、入れ子になったワールドの検出、ZIPからのワールド取り込みを確認します。

```bash
bash tests/run-tests.sh
```

ZIPのテストには`zip`と`unzip`が必要です。`zip`がないローカル環境ではZIPテストだけをスキップします。GitHub Actionsでは必要なコマンドを導入し、次を自動実行します。

- Bash構文チェック
- Python構文チェック
- ShellCheck
- 仕様テスト
