# DigitalMaid Agentic OS — installer

One command installs DigitalMaid Agentic OS on Linux or macOS, creates your workspace and account, and starts it in the background at login.

```bash
curl -fsSL https://raw.githubusercontent.com/DigitalMaid/digitalmaid-install/main/install.sh | bash
```

Then open **http://127.0.0.1:8765** and sign in with the account you just created.

**On a server (VPS)**, run it as root and give it the server's name — you get HTTPS and a public URL in the same paste:

```bash
curl -fsSL https://raw.githubusercontent.com/DigitalMaid/digitalmaid-install/main/install.sh | bash -s -- --domain srv123.example.com
```

It creates a `digitalmaid` system user, installs to `/opt/digitalmaid`, registers system services that run as that user (never root), installs Caddy for automatic HTTPS, and ends with `✓ https://srv123.example.com is up`. Needs: DNS for that name pointing at the server, ports 80 and 443 open in your provider's firewall. Without `--domain` the app stays on `127.0.0.1` and the installer prints the SSH-tunnel command to reach it.

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

As root the same layout lives under `/opt/digitalmaid` (owned by the `digitalmaid` user) with system units in `/etc/systemd/system/`, and `digitalmaid` / `digitalmaid-uninstall` are on the PATH.

Requirements: Linux or macOS, `curl`. Python and `uv` are installed for you if missing. Windows: use WSL2.

## Options

```
--domain HOST     serve at https://HOST via Caddy (root only)
--demo            seed the fictional "Northwind Ferments" workspace
--version 0.2.0   install a specific release (default: latest)
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
digitalmaid-uninstall --purge                      # server install (as root): also removes the user and the Caddy site
```

## Live AI agents (optional)

Everything works without any API key. To let the built-in agent roles run automations with a model, put your key in `~/.digitalmaid/env` (`DIGITALMAID_LLM_API_KEY=...`, `chmod 600`) and enable the `EnvironmentFile` line in `~/.config/systemd/user/digitalmaid-worker.service`, then `systemctl --user restart digitalmaid-worker`. Details in `~/.digitalmaid/app/docs/LIVE-AGENT.md`.

## Security notes

- The UI binds to `127.0.0.1` only; `--domain` puts Caddy (HTTPS) in front of it and the app runs as an unprivileged user with `ProtectSystem=strict`.
- Passwords are stored as salted scrypt hashes; the installer never writes a password anywhere.
- The install script downloads exactly two things: `uv` from astral.sh (if missing) and the release tarball from this repository. The SHA-256 is verified against `SHA256SUMS` before anything is installed.

## Releases

Release tarballs live in `releases/v<version>/` in this repository (`digitalmaid-<version>.tar.gz` + `SHA256SUMS`); `releases/LATEST` names the current version. The installer verifies the checksum before installing.
