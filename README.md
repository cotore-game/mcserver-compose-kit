# mcserver-compose-kit

[日本語](README-JA.md) | English

`mcserver-compose-kit` creates and manages Minecraft Java Edition servers from WSL2. It is aimed at downloaded adventure maps and other prebuilt worlds, but it also works without an imported world.

The toolkit creates an independent Docker Compose project for each server. Run `mcserver-kit` to open the terminal dashboard, or use its subcommands directly from scripts.

## What it does

- Imports a world from a folder or ZIP archive
- Finds `level.dat` inside common nested archive layouts
- Detects the saved Minecraft version and suggests a matching Java image
- Creates a separate `compose.yaml`, `.env`, `server.env`, and `data/` directory for each server
- Manages start, stop, restart, status, logs, and server settings
- Reuses MCID templates for the whitelist and operator list
- Supports Playit and server resource packs
- Uses Windows file dialogs and a Windows IME-friendly MOTD editor when available
- Provides English and Japanese messages through JSON locale catalogs

## Requirements

- Windows with WSL2
- Docker Desktop with WSL Integration enabled for your distribution
- Docker Compose v2
- Bash

The installer checks for `python3`, `unzip`, and `whiptail`. On Ubuntu, it can install missing packages with `apt` after asking for confirmation.

Check Docker from your WSL terminal before installing:

```bash
docker version
docker compose version
```

## Install

Install the latest release:

```bash
curl -fsSL https://raw.githubusercontent.com/cotore-game/mcserver-compose-kit/main/install.sh | bash
```

Install a specific release:

```bash
curl -fsSL https://raw.githubusercontent.com/cotore-game/mcserver-compose-kit/main/install.sh | \
  bash -s -- --version v1.0.0
```

The installer downloads the release archive, verifies its SHA-256 checksum, and installs the program under `~/.local/share/mcserver-compose-kit`. It also adds a managed PATH block for `~/.local/bin` to `~/.bashrc`.

The current shell is not reloaded automatically. Open a new terminal, or run the `source` command printed by the installer.

Re-running the installer updates the program files. It does not overwrite an existing configuration or MCID templates.

## First setup

The default language is English. To use Japanese, set it before setup:

```bash
mcserver-kit lang --ja
```

Then run:

```bash
mcserver-kit setup
```

Setup asks for:

- Owner Minecraft ID
- Minecraft EULA acceptance
- Whitelist and operator defaults
- Additional MCIDs
- Playit settings
- Fallback Minecraft version and Java memory
- Whether to start a server after creation by default
- Whether to use Windows dialogs
- Server destination directory

The EULA must be accepted and setup must finish before a server can be created.

## Open the dashboard

```bash
mcserver-kit
```

The dashboard includes server creation and management, global settings, MCID templates, language selection, diagnostics, and help. Use the arrow keys to select an item and Enter to open it.

Check the installed toolkit version with:

```bash
mcserver-kit --version
```

Running `mcserver-kit` without arguments in a non-interactive environment prints help instead of opening the dashboard.

## Create a server

Choose **Create server** from the dashboard, or run:

```bash
mcserver-kit create
```

You can select a world folder or ZIP archive. If an archive contains an extra top-level folder, the toolkit searches below it for the directory containing `level.dat`.

The version stored in `level.dat` becomes the default at the version prompt. If it cannot be detected, the configured fallback version is used. You can always type a different value.

Examples of accepted versions:

```text
26.2
1.21
1.21.2
LATEST
```

With `docker.java_image_tag: "auto"`, the Java image is selected as follows:

| Minecraft version | Image tag |
| --- | --- |
| `26.x` or `LATEST` | `java25` |
| `1.20.5` and later 1.x releases | `java21` |
| `1.18` through `1.20.4` | `java17` |

Older releases require an explicit Docker image tag in the configuration.

Java memory accepts values such as `8`, `8G`, and `8192M`. A number without a unit is treated as GiB.

By default, servers are created in:

```text
~/minecraftServer/<server-id>/
├── compose.yaml
├── .env
├── server.env
├── README.txt
└── data/
    └── world/
```

The creation process shows its current step. Before starting a server it validates the generated Compose configuration with `docker compose config --quiet`.

## Manage servers

List managed servers:

```bash
mcserver-kit list
```

Use the dashboard, or run a command directly:

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

`stop` and `shutdown` stop the container without removing it. `down` removes the container and network. These commands do not delete the server's `data/` directory.

## Edit Minecraft settings

Open **Server settings** from the dashboard, or run:

```bash
mcserver-kit server <server-id> properties
```

The editor covers MOTD, difficulty, game mode, player limit, online mode, whitelist, operators, flight, command blocks, PvP, view and simulation distance, spawn protection, Nether and entity spawning, and resource packs.

`server.env` is the source of truth for settings managed by the toolkit. Docker Compose passes these values to `itzg/minecraft-server`, which applies them to `server.properties` when the container starts.

When an older server is opened for the first time, the editor asks before migrating it. The original Compose file is saved as `compose.yaml.mcserver-kit.bak`.

## MCID templates

Templates are plain text files stored in:

```text
~/.config/mcserver-compose-kit/mcid-templates/
```

Write one Minecraft ID per line. Blank lines and text after `#` are ignored. `${OWNER}` expands to the Owner ID from the main configuration.

```text
${OWNER}
ExamplePlayer
AnotherPlayer
```

Manage templates from the dashboard or run:

```bash
mcserver-kit templates
```

## Windows dialogs

When enabled, the toolkit calls Windows PowerShell from WSL to open Explorer-based folder and ZIP selection dialogs. MOTD text can also be entered in a Windows dialog, avoiding common terminal IME editing problems.

If the Windows dialog is unavailable or cancelled, input falls back to the terminal. Disable it in the global settings screen or set:

```yaml
ui:
  windows_dialogs: false
```

## Configuration and secrets

User configuration is stored at:

```text
~/.config/mcserver-compose-kit/config.yml
```

Use `mcserver-kit config` for common settings. The file can also be edited directly.

The configuration may contain a Playit secret key. Do not commit it. Generated server `.env` and `server.env` files may also contain private values.

## Language

Set a persistent language:

```bash
mcserver-kit lang --en
mcserver-kit lang --ja
```

Override the language for one command:

```bash
mcserver-kit --lang ja --help
```

See [CONTRIBUTING.md](CONTRIBUTING.md#adding-a-language) to add or update a translation.

English is the fallback catalog. If a selected language has not translated a newly added key yet, that message is shown in English instead of exposing the internal key name.

## Reset, update, and uninstall

Delete configuration and MCID templates while keeping installed program files and created servers:

```bash
mcserver-kit reset
```

Update by running the installer again. Existing user configuration is kept.

Remove the program but keep user configuration:

```bash
mcserver-kit uninstall
```

Remove the program and user configuration:

```bash
mcserver-kit uninstall --purge
```

After uninstalling, open a new terminal. In the current Bash session, `hash -r` clears a cached command path if needed.

## Limitations

- Servers that use the same host port cannot run at the same time.
- Do not run multiple Playit agents with the same secret key at the same time.
- Mod-loader-specific maps are not currently configured by the vanilla template.
- Deleting a server's `data/` directory deletes its world and progress.

## Contributing

Bug reports, documentation fixes, and translations are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

## License

See [LICENSE](LICENSE).
