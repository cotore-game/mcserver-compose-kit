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
  bash -s -- --version v1.0.0
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

インストールされているツールのバージョンは次で確認できます。

```bash
mcserver-kit --version
```

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
mcserver-kit server <server-id> properties
```

`stop`と`shutdown`はコンテナを削除せず停止します。`down`はコンテナとネットワークを削除します。いずれもサーバーの`data/`は削除しません。

## Minecraft設定を編集する

ホーム画面から「サーバー設定」を開くか、次を実行します。

```bash
mcserver-kit server <server-id> properties
```

MOTD、難易度、ゲームモード、最大人数、オンラインモード、ホワイトリスト、OP、飛行、コマンドブロック、PvP、描画・シミュレーション距離、スポーン保護、ネザー、Mob/NPC生成、リソースパックなどを編集できます。

ツールが管理する設定の正本は各サーバーの`server.env`です。Docker Composeが値を`itzg/minecraft-server`へ渡し、コンテナ起動時に`server.properties`へ反映します。

古い形式のサーバーを初めて開く場合は、移行前に確認画面を表示します。元のComposeは`compose.yaml.mcserver-kit.bak`として保存します。

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

更新はインストーラーをもう一度実行します。既存のユーザー設定は保持されます。

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
