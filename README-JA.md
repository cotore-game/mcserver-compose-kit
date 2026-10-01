# mcserver-compose-kit

日本語 | [English](README.md)

`mcserver-compose-kit`は、WSL2上でMinecraft Java Editionサーバーを作成・管理するツールです。配布マップなどの既存ワールドを取り込む用途を中心にしていますが、ワールドを指定せずに新規サーバーを作ることもできます。

サーバーごとに独立したDocker Compose構成を作成します。`mcserver-kit`で対話式ホーム画面を開くほか、サブコマンドを直接実行することもできます。

## 主な機能

- フォルダまたはZIPからワールドを取り込み
- ZIP内に余分な階層があっても`level.dat`を基準にワールドを検出
- 保存されたMinecraftバージョンを検出し、対応するJavaイメージを提案
- サーバーごとに`compose.yaml`、`.env`、`server.env`、`data/`を作成
- 起動、停止、再起動、状態確認、ログ表示、Minecraft設定を一元管理
- GitHub Releasesでツール本体の更新を確認し、確認後にインストール
- ホワイトリストとOPでMCIDテンプレートを再利用
- Playitとサーバーリソースパックに対応
- 利用可能な場合はWindowsのファイル選択画面と、日本語を入力しやすいMOTD編集画面を使用
- JSONカタログによる英語・日本語表示

## 必要な環境

- WindowsとWSL2
- 対象ディストリビューションでWSL Integrationを有効にしたDocker Desktop
- Docker Compose v2
- Bash

インストーラーは`python3`、`unzip`、`whiptail`を確認します。Ubuntuで不足している場合は、確認後に`apt`で導入できます。

インストール前にWSLのターミナルからDockerを確認してください。

```bash
docker version
docker compose version
```

## インストール

最新リリースをインストールします。

```bash
curl -fsSL https://raw.githubusercontent.com/cotore-game/mcserver-compose-kit/main/install.sh | bash
```

バージョンを固定する場合：

```bash
curl -fsSL https://raw.githubusercontent.com/cotore-game/mcserver-compose-kit/main/install.sh | \
  bash -s -- --version v1.2.0
```

インストーラーはリリースの圧縮ファイルを取得し、SHA-256を検証して`~/.local/share/mcserver-compose-kit`へ配置します。また、`~/.local/bin`用のPATH設定を管理ブロックとして`~/.bashrc`へ追加します。

現在開いているシェルには自動反映しません。新しいターミナルを開くか、インストーラーが表示した`source`コマンドを実行してください。

同じインストールコマンドを再実行すると本体を更新します。既存の設定とMCIDテンプレートは上書きしません。

## 初回設定

初期言語は英語です。日本語で設定する場合は、先に次を実行します。

```bash
mcserver-kit lang --ja
```

続けて初回設定を行います。

```bash
mcserver-kit setup
```

主な設定項目：

- OwnerのMinecraft ID
- Minecraft EULAへの同意
- ホワイトリストとOPの初期設定
- Owner以外のMCID
- Playit設定
- バージョンを検出できない場合のMinecraftバージョン
- Javaメモリ
- 作成後すぐ起動するか
- Windowsの入力画面を使うか
- サーバー作成先

EULAへ同意し、setupを最後まで完了するまではサーバーを作成できません。

## ホーム画面を開く

```bash
mcserver-kit
```

ホーム画面から、サーバー作成・管理、全体設定、MCIDテンプレート、言語、動作環境診断、ヘルプへ進めます。矢印キーで選択し、Enterで決定します。

メニュー間では同じ端末画面を維持します。Dockerの状態取得や次の画面の読み込み中も枠を残して点字スピナーを表示し、進捗率やプログレスバーは表示しません。Tabで決定・キャンセルを切り替え、Escで前のメニューへ戻ります（ホームでは終了）。処理結果は閉じるまで表示され、矢印キーやPage Up/Downでスクロールできます。

新規作成と追尾ログは、同じ端末セッション内で従来の行単位の画面を使います。表示された案内に従ってメニューへ戻ってください。常駐描画にはUbuntuのPythonに含まれる標準ライブラリのcursesを使用し、pipパッケージの追加は不要です。

インストールされているツールのバージョンは次で確認できます。

```bash
mcserver-kit --version
```

ホーム画面では、GitHubに新しいReleaseがあるか24時間に1回まで自動確認します。オフラインや確認失敗時でもホーム画面の起動は妨げません。

パイプやCIなどの非対話環境で引数なし実行した場合は、ホーム画面ではなくヘルプを表示します。

## サーバーを作成する

ホーム画面の「サーバーを作成」を選ぶか、次を実行します。

```bash
mcserver-kit create
```

ワールドのフォルダまたはZIPを選択できます。ZIPを展開した直下にもう1つフォルダがあるような構成でも、その下から`level.dat`を持つワールドを探します。

`level.dat`に保存されたMinecraftバージョンを検出できた場合は、バージョン入力の初期値になります。検出できなければ、全体設定の既定値を使用します。必要なら別の値を手入力できます。

入力例：

```text
26.2
1.21
1.21.2
LATEST
```

`docker.java_image_tag: "auto"`では次のようにJavaイメージを選びます。

| Minecraftバージョン | イメージタグ |
| --- | --- |
| `26.x`または`LATEST` | `java25` |
| `1.20.5`以降の1.x | `java21` |
| `1.18`から`1.20.4` | `java17` |

それより古いバージョンは、設定ファイルでDockerイメージタグを明示してください。

Javaメモリには`8`、`8G`、`8192M`などを入力できます。単位のない数値はGiBとして扱います。

既定の生成先：

```text
~/minecraftServer/<server-id>/
├── compose.yaml
├── .env
├── server.env
├── README.txt
└── data/
    └── world/
```

作成中は現在の処理を表示します。起動前には`docker compose config --quiet`で生成したCompose構成を検証します。

## サーバーを管理する

管理対象の一覧：

```bash
mcserver-kit list
```

ホーム画面を使わず、サーバーIDを指定して直接操作することもできます。

```bash
mcserver-kit server <server-id> start
mcserver-kit server <server-id> stop
mcserver-kit server <server-id> shutdown
mcserver-kit server <server-id> restart
mcserver-kit server <server-id> status
mcserver-kit server <server-id> logs
mcserver-kit server <server-id> logs --no-follow
mcserver-kit server <server-id> down
mcserver-kit server <server-id> delete
mcserver-kit server <server-id> properties
mcserver-kit server <server-id> import-properties /path/to/server.properties
mcserver-kit server <server-id> open data
mcserver-kit server <server-id> open server
```

`stop`と`shutdown`はコンテナを削除せず停止します。`down`はコンテナとネットワークを削除します。いずれもサーバーの`data/`は削除しません。

`delete`は、ワールドデータ、設定、シークレット、バックアップを含む管理対象サーバーフォルダ全体を完全に削除します。対象の絶対パスを表示して続行確認を行い、二段階目として正確なサーバーIDの入力を要求します。先にコンテナとネットワークを削除し、`docker compose down`が失敗した場合はサーバーフォルダを削除しません。

## Minecraft設定を編集する

ホーム画面から「サーバー設定」を開くか、次を実行します。

```bash
mcserver-kit server <server-id> properties
```

MOTD、難易度、ゲームモード、最大人数、オンラインモード、ホワイトリスト、OP、飛行、コマンドブロック、PvP、描画・シミュレーション距離、スポーン保護、ネザー、Mob/NPC生成、リソースパックなどを編集できます。

新規サーバーは初回起動前の作成時点から`data/server.properties`を正本として使います。`server.env`にはホワイトリスト・OPのメンバー管理設定を残し、`OVERRIDE_SERVER_PROPERTIES=false`でitzgによるプロパティ上書きを止めます。バージョン・メモリ等のコンテナ設定は`.env`とComposeで管理します。既存サーバーは明示的に移行するまで従来の設定方式を維持します。

既存サーバーは、`data/server.properties`を正本とする方式へ移行できます。先にサーバーを停止し、次を実行します。

```bash
mcserver-kit server <サーバーID> properties migrate
```

移行時は`server.env`、`CUSTOM_SERVER_PROPERTIES`、Compose、既存ファイルの実効値を引き継ぎます。変更前のファイルは`backups/source-migrations/`へ保存し、itzgによるプロパティ上書きを無効化します。ホワイトリストとOPのメンバー管理はプロパティと分離して保持します。移行後は、MinecraftやMODの元のキー名で全項目をCLI操作できます。

```bash
mcserver-kit server <サーバーID> properties list
mcserver-kit server <サーバーID> properties get motd
mcserver-kit server <サーバーID> properties set motd "My server"
mcserver-kit server <サーバーID> properties add mod.custom-key value
mcserver-kit server <サーバーID> properties remove mod.custom-key
mcserver-kit server <サーバーID> properties backup
mcserver-kit server <サーバーID> properties backups
mcserver-kit server <サーバーID> properties restore <バックアップID>
mcserver-kit server <サーバーID> properties import /path/to/server.properties
```

変更を伴うコマンドはサーバーの停止を要求し、変更前にスナップショットを作成します。バックアップは`backups/server-properties/`へ保存します。復元時にも、置換される現在のファイルを先にバックアップします。

新規作成・移行済みのサーバーでは、インポートは`data/server.properties`を置換し、正本の管理方式を維持します。ワールド配置とポートの制約として`level-name=world`、`server-port=25565`を保持します。

`mcserver-kit server <サーバーID> properties`から「server.propertiesの全キー」を選ぶと、Minecraft本来のキー名でファイル内の全項目を閲覧・編集・削除できます。「キーを追加」には説明付き候補と、MOD設定などの手入力を用意しています。キャンセルで前のメニューに戻ります。よく使う設定と全キー編集のどちらも、プロパティ変更時はCLIと同じ停止確認と自動バックアップを通します。削除したキーは、次の起動時にMinecraftが既定値で再生成する場合があります。

旧サーバーの設定画面を開くと、`data/server.properties`を直接正本にする一段階の移行を確認します。先にサーバーを停止してください。移行前のCompose・環境設定・プロパティはバックアップします。移行後は「server.propertiesをバックアップ」「server.propertiesを復元」を利用でき、復元時も現在のファイルを退避してから置換します。

説明カタログは現在、主要25項目の英日対応です。全バージョンの全項目を網羅した一覧ではありませんが、未登録キーも編集できます。値は文字列で入力し、バージョンごとの型・範囲の検証はまだ行いません。パスワードは伏せ字で表示します。旧サーバーの設定画面では、全キー編集の前に移行を確認します。

新規作成時はランダムなRCONパスワードも生成します。`server.env`の`ENABLE_RCON`・`RCON_PORT`・`RCON_PASSWORD`は、プロパティから生成するitzg側クライアント用の値です。RCONの変更にはプロパティ操作コマンドを使ってください。編集・インポート・復元時にこれらの値も更新します。変更した環境変数は`docker compose up -d`でコンテナを再作成して反映します。外部エディターによるRCON設定変更と`docker compose restart`だけでは、このクライアント設定は更新されません。

配布された`server.properties`を使う場合は、サーバーを停止して「サーバー設定 → server.propertiesをインポート」を選ぶか、`mcserver-kit server <server-id> import-properties /path/to/server.properties`を実行します。Windowsダイアログを有効にしているWSL環境ではファイル選択画面を開けます。旧サーバーはインポート前に直接`data/server.properties`正本へ移行し、以前の設定とファイルをバックアップします。配布ファイルは未知のキーも含めて正本となり、`\:`などJava Propertiesのエスケープも扱えます。`level-name=world`と`data/world`の配置を維持し、ポートが異なる場合や書式が不正な場合は移行・インポート前にエラーにします。

ホーム画面からサーバーフォルダ、または永続データの`data/`をWindowsのExplorerで開けます。コマンドでは`mcserver-kit server <server-id> open server`または`open data`です。WSLとExplorerの連携が必要です。

古い形式のサーバーを初めて開く場合は、移行前に確認画面を表示します。元の設定ファイルは`backups/source-migrations/`に保存します。

## MCIDテンプレート

テンプレートは次の場所にあるテキストファイルです。

```text
~/.config/mcserver-compose-kit/mcid-templates/
```

1行に1つMinecraft IDを書きます。空行と`#`以降は無視されます。`${OWNER}`は全体設定にあるOwnerのIDへ置き換わります。

```text
${OWNER}
ExamplePlayer
AnotherPlayer
```

ホーム画面または次のコマンドから管理できます。

```bash
mcserver-kit templates
```

## Windows入力画面

有効な場合は、WSLからWindows PowerShellを呼び出し、Explorer形式のフォルダ・ZIP選択画面を開きます。MOTDもWindows側の画面で入力できるため、ターミナル上の日本語IMEでBackspaceなどが扱いにくい問題を避けられます。

Windows側の画面を利用できない場合やキャンセルした場合は、ターミナル入力へ戻ります。全体設定画面から無効にするか、設定ファイルへ次を記述します。

```yaml
ui:
  windows_dialogs: false
```

## 設定と秘密情報

ユーザー設定は次に保存します。

```text
~/.config/mcserver-compose-kit/config.yml
```

一般的な項目は`mcserver-kit config`から変更できます。ファイルを直接編集することもできます。

設定ファイルにはPlayitのSecret Keyが含まれる場合があります。Gitへコミットしないでください。各サーバーの`.env`と`server.env`にも非公開の値が含まれる可能性があります。

## 言語

表示言語を保存する場合：

```bash
mcserver-kit lang --en
mcserver-kit lang --ja
```

1回のコマンドだけ言語を指定する場合：

```bash
mcserver-kit --lang ja --help
```

翻訳の追加・修正方法は[CONTRIBUTING.md](CONTRIBUTING.md#adding-a-language)を参照してください。

翻訳キーが選択中の言語にまだ追加されていない場合は、そのメッセージだけ英語で表示します。内部のキー名がそのまま表示されることはありません。

## リセット・更新・アンインストール

作成済みサーバーとインストール本体を残し、設定とMCIDテンプレートだけを削除します。

```bash
mcserver-kit reset
```

インストールせず更新の有無だけを確認します。

```bash
mcserver-kit update check
```

もう一度確認し、確認メッセージの後で最新Releaseをインストールします。

```bash
mcserver-kit update
```

ホーム画面の自動確認は24時間キャッシュを使います。明示的なコマンドはその時点のLatest Releaseを取得します。更新時も既存のユーザー設定とMCIDテンプレートは保持されます。

設定を残して本体だけを削除する場合：

```bash
mcserver-kit uninstall
```

本体とユーザー設定を削除する場合：

```bash
mcserver-kit uninstall --purge
```

アンインストール後は新しいターミナルを開いてください。現在のBashに削除済みコマンドの場所が残っている場合は、`hash -r`でキャッシュを消せます。

## 注意事項

- 同じホストポートを使うサーバーは同時に起動できません。
- 同じSecret Keyを使うPlayitエージェントを同時に起動しないでください。
- MODローダーが必要な配布マップは、現在のVANILLA用テンプレートでは設定できません。
- サーバーの`data/`を削除するとワールドと進行状況を失います。

## コントリビュート

不具合報告、ドキュメント修正、翻訳の追加を歓迎します。PRを作る前に[CONTRIBUTING.md](CONTRIBUTING.md)を確認してください。

## ライセンス

[LICENSE](LICENSE)を参照してください。
