# Contributing

Thanks for helping improve mcserver-compose-kit. Small fixes are welcome. If a change affects commands, configuration, or generated server files, explain the user-facing effect in the pull request.

## Before you start

- Do not commit `config.yml`, generated `.env` files, Playit secret keys, world data, or other private server files.
- Keep changes focused. Unrelated cleanup is easier to review in a separate pull request.
- Use LF line endings for shell scripts and text files.
- Keep command output plain. Avoid adding decorative emoji to shell output.
- User-facing text belongs in the locale catalogs rather than directly in a shell script.

For a larger behavioral change, opening an issue first is useful, but it is not required for documentation and translation fixes.

## Development setup

Clone the repository inside WSL2:

```bash
git clone https://github.com/cotore-game/mcserver-compose-kit.git
cd mcserver-compose-kit
```

Create a branch from the current development base:

```bash
git switch develop
git pull --ff-only
git switch -c feat/short-description
```

Use a `fix/`, `docs/`, or `refactor/` prefix when it describes the change better. Work is normally collected in `develop`; a release pull request moves it from `develop` to `main`.

You can run the checked-out version without installing it:

```bash
bash mcserver-kit --help
bash mcserver-kit create
```

The local installer can be tested without downloading a release:

```bash
bash install.sh
```

This updates the installed program while preserving an existing user configuration and MCID templates.

## Tests

Run the specification tests:

```bash
bash tests/run-tests.sh
```

Run syntax and locale checks:

```bash
bash -n mcserver-kit home-tui.sh new-minecraft-server.sh setup.sh reset.sh \
  config-tui.sh server-manager.sh server-properties-tui.sh lang.sh \
  install.sh uninstall.sh tests/run-tests.sh
python3 -m py_compile scripts/*.py
python3 scripts/validate-locales.py
```

Run ShellCheck if it is installed:

```bash
shellcheck -x mcserver-kit home-tui.sh new-minecraft-server.sh setup.sh \
  reset.sh config-tui.sh server-manager.sh server-properties-tui.sh \
  lang.sh install.sh uninstall.sh tests/run-tests.sh
```

The ZIP import tests need both `zip` and `unzip`. They are skipped locally when `zip` is unavailable. GitHub Actions installs both packages and runs the complete suite.

## Adding or changing user-facing text

English is the source catalog. When adding a message:

1. Add the key and English value to `locales/en.json`.
2. Add the same key to every other `locales/*.json` file.
3. Call it from shell code with `tr message.key`.
4. Pass substitutions as additional arguments, for example `tr server.not_found "$server_id"`.
5. Run the locale validator and specification tests.

Do not use user input as a translation key. Keep keys stable and describe their purpose, such as `home.select_server`.

Values are passed to Bash `printf`. Preserve placeholders such as `%s` and their order in every translation. Write a literal percent sign as `%%` when needed.

## Adding a language

Locale files use a short language code as the filename. For example, a German catalog would be `locales/de.json`.

1. Copy the English catalog:

   ```bash
   cp locales/en.json locales/de.json
   ```

2. Translate values only. Do not rename, add, or remove keys.

3. Keep these details unchanged where they are part of program behavior:

   - placeholders such as `%s`
   - command names such as `mcserver-kit setup`
   - URLs and file paths
   - JSON escapes such as `\n`

4. Validate the catalog:

   ```bash
   python3 scripts/validate-locales.py
   ```

   The validator checks JSON structure, empty values, missing keys, and extra keys against `locales/en.json`.

5. Preview one command without changing the saved language:

   ```bash
   bash mcserver-kit --lang de --help
   ```

6. Add the language to the interactive selector in `home-tui.sh`. The first value is the language code, the second is the label shown to users:

   ```bash
   de Deutsch OFF
   ```

7. Add a persistent CLI option in `lang.sh` and update `lang.usage` in every catalog. The existing `--en` and `--ja` branches show the expected structure.

8. Add specification coverage for the new language selection and run the full test suite.

9. Update the language section in `README.md` and any translated README you maintain.

A language pull request should include the catalog, selector and CLI wiring, tests, and documentation together. A correction to an existing translation can usually change only the affected catalog and related documentation.

Machine translation is acceptable as a draft, but please review the result in the actual TUI. Short labels, terminal width, and Minecraft terminology matter more than literal wording.

## Pull requests

Before opening a pull request:

- Run the checks relevant to your change.
- Confirm that no secrets or generated server data are staged.
- Update documentation when behavior or commands change.
- Use a clear title, preferably with a Conventional Commits prefix such as `feat:`, `fix:`, `docs:`, or `test:`.
- Summarize what changed and how it was tested.

Pull requests targeting `develop` or `main` are checked by GitHub Actions. The required `test` job must pass before merging into `main`.

## Releases

Releases are created from tags named `v*`. The release workflow runs all checks, builds `mcserver-compose-kit.tar.gz` and its SHA-256 file, and creates a GitHub Release. Release notes are reviewed and edited after the generated draft is created.
