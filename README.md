# DigitalMaid Agentic OS — installer

One command installs DigitalMaid Agentic OS on Linux or macOS, creates your workspace and account, and starts it in the background at login.

```bash
curl -fsSL https://raw.githubusercontent.com/DigitalMaid/digitalmaid-install/main/install.sh | bash
```

Then open **http://127.0.0.1:8765** and sign in with the account you just created.

Try it with fictional demo data instead of your own account:

```bash
curl -fsSL https://raw.githubusercontent.com/DigitalMaid/digitalmaid-install/main/install.sh | bash -s -- --demo
```

## What gets installed

| Where | What |
|---|---|
| `~/.digitalmaid/app` | the application (a Python package, no Node, no build step) |
| `~/.digitalmaid/venv` | its private Python environment (managed by `uv`) |
| `~/.digitalmaid/workspace` | **your data** — SQLite database, files, definitions |
| `~/.digitalmaid/bin` | `digitalmaid`, `digitalmaid-start`, `digitalmaid-uninstall` |
| systemd `--user` (Linux) / launchd (macOS) | `digitalmaid` (web UI) and `digitalmaid-worker` (automations), started at login |

Requirements: Linux or macOS, `curl`. Python and `uv` are installed for you if missing. Windows: use WSL2.

## Options

```
--demo            seed the fictional "Northwind Ferments" workspace
--version 0.1.0   install a specific release (default: latest)
--port 8765       local port for the UI
--prefix DIR      install somewhere other than ~/.digitalmaid
--no-service      don't register background services; use digitalmaid-start
```

## Upgrade

Re-run the same install command. The app is replaced, your workspace is kept and migrated.

## Uninstall

```bash
~/.digitalmaid/bin/digitalmaid-uninstall           # keeps your workspace
~/.digitalmaid/bin/digitalmaid-uninstall --purge   # removes everything
```

## Live AI agents (optional)

Everything works without any API key. To let the built-in agent roles run automations with a model, put your key in `~/.digitalmaid/env` (`DIGITALMAID_LLM_API_KEY=...`, `chmod 600`) and enable the `EnvironmentFile` line in `~/.config/systemd/user/digitalmaid-worker.service`, then `systemctl --user restart digitalmaid-worker`. Details in `~/.digitalmaid/app/docs/LIVE-AGENT.md`.

## Security notes

- The UI binds to `127.0.0.1` only. For a team server, see `docs/INSTALL.md` inside the app (HTTPS reverse proxy required).
- Passwords are stored as salted scrypt hashes; the installer never writes a password anywhere.
- The install script downloads exactly two things: `uv` from astral.sh (if missing) and the release tarball from this repository's Releases page. Verify with `SHA256SUMS` attached to each release.

## Releases

Each release ships `digitalmaid-<version>.tar.gz`, `digitalmaid.tar.gz` (same file, stable name for `latest`) and `SHA256SUMS`.
