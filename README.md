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
| `~/.digitalmaid/uninstall` | where the app drops an uninstall request (Settings → Uninstall); watched by `digitalmaid-uninstall.path` |
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
--hermes          also install the Hermes Agent dashboard plugin (DigitalMaid tab)
--hermes-home DIR Hermes home with plugins/ and config.yaml (default: ~/.hermes)
```

## Inside Hermes

If [Hermes Agent](https://hermes-agent.nousresearch.com/docs) runs on the same machine, DigitalMaid can be a tab
in its dashboard (after *Skills*), signed in automatically as the workspace owner:

```bash
curl -fsSL https://raw.githubusercontent.com/DigitalMaid/digitalmaid-install/main/install.sh | bash -s -- --hermes
```

Use `sudo bash -s -- --hermes` on a server install, and `--hermes-home DIR` if Hermes's home is not
`~/.hermes`. The step (after the services) does five things: creates a shared secret in
`PREFIX/hermes-secret` (0600) and `PREFIX/hermes.env` (read by `digitalmaid.service` through
`EnvironmentFile=`, never written into the unit), copies the plugin shipped with the release
(`app/hermes-plugin/digitalmaid`) to `HERMES_HOME/plugins/digitalmaid` with its own 0600 copy of the secret
and a `dashboard/config.json` pointing at your port, adds `digitalmaid` to `plugins.enabled` in
`HERMES_HOME/config.yaml` (text edit, comments kept, backup `config.yaml.before-digitalmaid`), and prints
*restart the Hermes dashboard to see the DigitalMaid tab*. It never restarts Hermes. Re-running keeps the
secret. The app's Settings → *Hermes integration* shows the same command and whether the trusted proxy is
configured.

Trade-off (owner decision): one login instead of two — inside the tab everyone who can open your Hermes
dashboard acts as the DigitalMaid owner, so the per-user audit trail collapses to one name there. Leave
`--hermes` out and use DigitalMaid accounts if that matters. Details: `app/docs/HERMES-INTEGRATION.md` §6
and `app/hermes-plugin/README.md`.

## Upgrade

Re-run the same install command. The app is replaced, your workspace is kept and migrated.

## Uninstall

**From the app** (0.3.0+, owners): Settings → *Uninstall DigitalMaid* → *Uninstall…*. Re-enter your password
and type `UNINSTALL`; your workspace is kept unless you tick *Also erase my data, backups and account*. The
app never runs as root — it writes one request file under `PREFIX/uninstall/` and a systemd path unit
(`digitalmaid-uninstall.path`, registered by this installer) runs `digitalmaid-uninstall --from-request`.
On macOS (launchd) there is no watcher, so the button is hidden; use the command line.

**From the shell:**

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
