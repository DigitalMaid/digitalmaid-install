#!/usr/bin/env bash
# DigitalMaid Agentic OS — one-command installer.
#
#   curl -fsSL https://raw.githubusercontent.com/DigitalMaid/digitalmaid-install/main/install.sh | bash
#
# Options (append after `bash -s --`):
#   --demo                seed the fictional "Northwind Ferments" workspace instead of asking for a user
#   --version X.Y.Z       install a specific release (default: latest)
#   --no-service          do not register background services; just print the start commands
#   --prefix DIR          install location (default: ~/.digitalmaid)
#   --port N              local port for the UI (default: 8765)
#   --from-tarball FILE   install from a local release tarball (offline / testing)
#
# What it does, idempotently: installs uv if missing → Python 3.12 → the app under PREFIX/app →
# a workspace under PREFIX/workspace → your owner user → background services (systemd --user on
# Linux, launchd on macOS) for the web UI and the automation worker → opens the URL.
# Re-running upgrades the app and keeps your workspace. Nothing is ever sent anywhere by this script
# except the downloads named below.
set -euo pipefail

RELEASES_REPO="DigitalMaid/digitalmaid-install"
PREFIX="${DIGITALMAID_PREFIX:-$HOME/.digitalmaid}"
VERSION="latest"
DEMO="no"
SERVICE="yes"
PORT="8765"
TARBALL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --demo) DEMO="yes"; shift ;;
    --version) VERSION="$2"; shift 2 ;;
    --no-service) SERVICE="no"; shift ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --from-tarball) TARBALL="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
step() { printf '\n\033[38;5;208m==\033[0m \033[1m%s\033[0m\n' "$1"; }
ok()   { printf '   \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '\n\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# When piped through `bash`, stdin is the script; talk to the user through the terminal instead.
if [ -t 0 ]; then TTY_IN="/dev/stdin"; else TTY_IN="/dev/tty"; fi
ask() { # ask VAR "prompt" [silent]
  local __var="$1" __prompt="$2" __silent="${3:-}" __value
  if [ "$__silent" = "silent" ]; then
    printf '%s' "$__prompt" >/dev/tty; IFS= read -r -s __value <"$TTY_IN"; printf '\n' >/dev/tty
  else
    printf '%s' "$__prompt" >/dev/tty; IFS= read -r __value <"$TTY_IN"
  fi
  printf -v "$__var" '%s' "$__value"
}

OS="$(uname -s)"
case "$OS" in Linux|Darwin) ;; *) fail "unsupported OS: $OS (Linux and macOS are supported; on Windows use WSL2)" ;; esac
[ "$(id -u)" != "0" ] || fail "please run as a normal user, not root — the app runs as you"

APP="$PREFIX/app"; VENV="$PREFIX/venv"; ROOT="$PREFIX/workspace"; BIN="$PREFIX/bin"
mkdir -p "$PREFIX" "$BIN"

bold ""
bold "  DigitalMaid Agentic OS"
printf '  installing to %s\n' "$PREFIX"

step "1/6 uv (Python manager)"
if ! have uv && [ ! -x "$HOME/.local/bin/uv" ]; then
  have curl || fail "curl is required"
  curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh >/dev/null
fi
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
have uv || fail "uv did not install; see https://docs.astral.sh/uv/"
ok "uv $(uv --version | awk '{print $2}')"

step "2/6 Python 3.12"
PY="$(uv python find '>=3.12' 2>/dev/null || true)"
if [ -z "$PY" ]; then uv python install 3.12 >/dev/null; PY="$(uv python find '>=3.12')"; fi
ok "$("$PY" -c 'import sys; print("python " + ".".join(map(str, sys.version_info[:3])))')"

step "3/6 Application"
if [ -n "$TARBALL" ]; then
  [ -f "$TARBALL" ] || fail "tarball not found: $TARBALL"
  SRC="$TARBALL"
else
  have curl || fail "curl is required"
  if [ "$VERSION" = "latest" ]; then
    URL="https://github.com/$RELEASES_REPO/releases/latest/download/digitalmaid.tar.gz"
  else
    URL="https://github.com/$RELEASES_REPO/releases/download/v$VERSION/digitalmaid.tar.gz"
  fi
  SRC="$(mktemp -t digitalmaid.XXXXXX.tar.gz)"
  curl -fsSL "$URL" -o "$SRC" || fail "could not download $URL"
fi
rm -rf "$APP.new"; mkdir -p "$APP.new"
tar -xzf "$SRC" -C "$APP.new" --strip-components=1
[ -f "$APP.new/pyproject.toml" ] || fail "the archive does not look like a DigitalMaid release"
NEWVER="$(sed -n 's/^version = "\(.*\)"/\1/p' "$APP.new/pyproject.toml")"
if [ -d "$APP" ]; then OLDVER="$(sed -n 's/^version = "\(.*\)"/\1/p' "$APP/pyproject.toml" 2>/dev/null || echo '?')"; else OLDVER=""; fi
rm -rf "$APP.old"; [ -d "$APP" ] && mv "$APP" "$APP.old"; mv "$APP.new" "$APP"; rm -rf "$APP.old"
[ -x "$VENV/bin/python" ] || uv venv --quiet --python "$PY" "$VENV" >/dev/null 2>&1
uv pip install --python "$VENV/bin/python" --quiet "$APP"
ln -sf "$VENV/bin/digitalmaid" "$BIN/digitalmaid"
if [ -n "$OLDVER" ] && [ "$OLDVER" != "$NEWVER" ]; then ok "upgraded $OLDVER → $NEWVER"; else ok "digitalmaid $NEWVER"; fi

step "4/6 Workspace"
mkdir -p "$ROOT"
"$BIN/digitalmaid" migrate --root "$ROOT" >/dev/null 2>&1 || true
SCOPE="personal"
USERS="$("$BIN/digitalmaid" user list --root "$ROOT" 2>/dev/null | "$VENV/bin/python" -c 'import json,sys
try: print(len(json.load(sys.stdin)))
except Exception: print(0)')"
if [ "${USERS:-0}" = "0" ]; then
  if [ "$DEMO" = "yes" ]; then
    SCOPE="demo"
    "$BIN/digitalmaid" demo --root "$ROOT"
    ok "demo workspace seeded (the password above is shown once — copy it)"
  else
    printf '   Create your account (stored only on this machine).\n'
    USERNAME=""
    while [ -z "$USERNAME" ]; do ask USERNAME "   username: "; done
    while :; do
      ask P1 "   password (min 10 chars): " silent
      [ "${#P1}" -ge 10 ] || { printf '   too short\n' >/dev/tty; continue; }
      ask P2 "   repeat password: " silent
      [ "$P1" = "$P2" ] && break
      printf '   passwords differ, try again\n' >/dev/tty
    done
    printf '%s' "$P1" | "$BIN/digitalmaid" user create --root "$ROOT" --username "$USERNAME" --scope "$SCOPE" --role owner --password-stdin >/dev/null
    unset P1 P2
    ok "owner '$USERNAME' created in scope '$SCOPE'"
  fi
else
  # Existing workspace: keep its scope.
  SCOPE="$([ -f "$PREFIX/scope" ] && cat "$PREFIX/scope" || echo personal)"
  ok "existing workspace kept ($ROOT)"
fi
printf '%s\n' "$SCOPE" > "$PREFIX/scope"

step "5/6 Background services"
SERVE_CMD="$VENV/bin/digitalmaid serve --root $ROOT --scope $SCOPE --host 127.0.0.1 --port $PORT"
WORKER_CMD="$VENV/bin/digitalmaid worker --loop --root $ROOT --scope $SCOPE"
cat > "$BIN/digitalmaid-start" <<EOF
#!/usr/bin/env bash
# Start the DigitalMaid UI and worker in the foreground (Ctrl+C stops both).
set -e
trap 'kill 0' EXIT
$WORKER_CMD &
exec $SERVE_CMD
EOF
chmod +x "$BIN/digitalmaid-start"
STARTED="no"
if [ "$SERVICE" = "yes" ] && [ "$OS" = "Linux" ] && have systemctl && systemctl --user show-environment >/dev/null 2>&1; then
  UNITS="$HOME/.config/systemd/user"; mkdir -p "$UNITS"
  cat > "$UNITS/digitalmaid.service" <<EOF
[Unit]
Description=DigitalMaid Agentic OS (web UI)
After=network.target
[Service]
ExecStart=$SERVE_CMD
Restart=on-failure
RestartSec=3
[Install]
WantedBy=default.target
EOF
  cat > "$UNITS/digitalmaid-worker.service" <<EOF
[Unit]
Description=DigitalMaid Agentic OS (automation worker)
After=digitalmaid.service
[Service]
ExecStart=$WORKER_CMD
Restart=on-failure
RestartSec=5
# To let live AI agents run, put DIGITALMAID_LLM_API_KEY=... in $PREFIX/env (chmod 600) and uncomment:
# EnvironmentFile=-$PREFIX/env
[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now digitalmaid.service digitalmaid-worker.service >/dev/null 2>&1 || true
  systemctl --user restart digitalmaid.service digitalmaid-worker.service >/dev/null 2>&1 || true
  loginctl enable-linger "$USER" >/dev/null 2>&1 || true
  STARTED="yes"
  ok "systemd user services: digitalmaid, digitalmaid-worker (start at login)"
elif [ "$SERVICE" = "yes" ] && [ "$OS" = "Darwin" ]; then
  AGENTS="$HOME/Library/LaunchAgents"; mkdir -p "$AGENTS" "$PREFIX/logs"
  plist() { # label, command...
    local label="$1"; shift
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>\n<key>Label</key><string>%s</string>\n<key>ProgramArguments</key><array>\n' "$label"
    for a in "$@"; do printf '<string>%s</string>\n' "$a"; done
    printf '</array>\n<key>RunAtLoad</key><true/>\n<key>KeepAlive</key><true/>\n<key>StandardOutPath</key><string>%s/logs/%s.log</string>\n<key>StandardErrorPath</key><string>%s/logs/%s.log</string>\n</dict></plist>\n' "$PREFIX" "$label" "$PREFIX" "$label"
  }
  # shellcheck disable=SC2086
  plist com.digitalmaid.serve $SERVE_CMD > "$AGENTS/com.digitalmaid.serve.plist"
  # shellcheck disable=SC2086
  plist com.digitalmaid.worker $WORKER_CMD > "$AGENTS/com.digitalmaid.worker.plist"
  for l in com.digitalmaid.serve com.digitalmaid.worker; do
    launchctl bootout "gui/$(id -u)/$l" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$(id -u)" "$AGENTS/$l.plist" >/dev/null 2>&1 || launchctl load "$AGENTS/$l.plist" >/dev/null 2>&1 || true
  done
  STARTED="yes"
  ok "launchd agents: com.digitalmaid.serve, com.digitalmaid.worker (start at login)"
else
  ok "no service registered; start with: $BIN/digitalmaid-start"
fi

step "6/6 Health check"
URL="http://127.0.0.1:$PORT"
if [ "$STARTED" = "yes" ]; then
  for _ in $(seq 1 30); do
    if curl -fsS "$URL/healthz" >/dev/null 2>&1; then break; fi
    sleep 0.5
  done
  if curl -fsS "$URL/healthz" >/dev/null 2>&1; then ok "$URL is up"; else printf '   \033[33m!\033[0m not answering yet; check: systemctl --user status digitalmaid  (or %s/logs on macOS)\n' "$PREFIX"; fi
fi
case ":$PATH:" in *":$BIN:"*) ;; *)
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [ -f "$rc" ] && ! grep -q 'digitalmaid/bin' "$rc" && printf '\n# DigitalMaid\nexport PATH="%s:$PATH"\n' "$BIN" >> "$rc"
  done ;;
esac

printf '\n'
bold "  Done."
printf '  Open:      %s\n' "$URL"
if [ "$DEMO" = "yes" ]; then printf '  Sign in:   demo / the password printed above\n'; fi
printf '  Command:   digitalmaid   (open a new shell, or: %s/digitalmaid)\n' "$BIN"
printf '  Upgrade:   re-run this same install command\n'
printf '  Uninstall: %s/digitalmaid-uninstall\n' "$BIN"
printf '  Docs:      %s/docs/  (INSTALL.md, OPERATIONS.md, LIVE-AGENT.md for AI keys)\n' "$APP"
cat > "$BIN/digitalmaid-uninstall" <<EOF
#!/usr/bin/env bash
# Removes the app and services. Your workspace ($ROOT) is kept unless you pass --purge.
set -e
if command -v systemctl >/dev/null 2>&1; then systemctl --user disable --now digitalmaid.service digitalmaid-worker.service 2>/dev/null || true; rm -f "$HOME/.config/systemd/user/digitalmaid.service" "$HOME/.config/systemd/user/digitalmaid-worker.service"; systemctl --user daemon-reload 2>/dev/null || true; fi
if [ "\$(uname -s)" = Darwin ]; then for l in com.digitalmaid.serve com.digitalmaid.worker; do launchctl bootout "gui/\$(id -u)/\$l" 2>/dev/null || true; rm -f "$HOME/Library/LaunchAgents/\$l.plist"; done; fi
rm -rf "$APP" "$VENV" "$BIN"
[ "\${1:-}" = "--purge" ] && rm -rf "$ROOT" && echo "workspace removed" || echo "workspace kept at $ROOT"
echo "DigitalMaid removed"
EOF
chmod +x "$BIN/digitalmaid-uninstall"
if [ "$STARTED" = "yes" ] && [ -t 1 ]; then
  if [ "$OS" = "Darwin" ]; then open "$URL" 2>/dev/null || true; elif have xdg-open; then xdg-open "$URL" >/dev/null 2>&1 || true; fi
fi
