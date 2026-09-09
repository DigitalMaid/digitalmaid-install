#!/usr/bin/env bash
# DigitalMaid Agentic OS — one-command installer.
#
#   curl -fsSL https://raw.githubusercontent.com/DigitalMaid/digitalmaid-install/main/install.sh | bash
#
# On a server, run it as root and give it your server's name to get HTTPS:
#   curl -fsSL .../install.sh | bash -s -- --domain srv123.example.com
#
# Options (append after `bash -s --`):
#   --domain HOST         serve at https://HOST (installs Caddy for automatic HTTPS; needs root, DNS → this box, ports 80/443 open)
#   --demo                seed the fictional "Northwind Ferments" workspace instead of asking for a user
#   --version X.Y.Z       install a specific release (default: latest)
#   --no-service          do not register background services; just print the start command
#   --prefix DIR          install location (default: ~/.digitalmaid, or /opt/digitalmaid as root)
#   --port N              local port for the UI (default: 8765)
#   --from-tarball FILE   install from a local release tarball (offline / testing)
#
# What it does, idempotently: uv → Python 3.12 → the app under PREFIX/app → a workspace under
# PREFIX/workspace → your owner account → background services → health check.
#   As a normal user: everything lives in ~/.digitalmaid; systemd --user (Linux) or launchd (macOS).
#   As root (a VPS): a dedicated `digitalmaid` system user owns /opt/digitalmaid; system services
#   /etc/systemd/system/digitalmaid{,-worker}.service run as that user; with --domain, Caddy
#   terminates HTTPS in front. The app itself never runs as root.
# Re-running upgrades the app and keeps your workspace. Nothing is sent anywhere by this script
# except the downloads named below (uv, the release tarball, Caddy from your distro's apt).
set -euo pipefail

RELEASES_REPO="DigitalMaid/digitalmaid-install"
VERSION="latest"; DEMO="no"; SERVICE="yes"; PORT="8765"; TARBALL=""; DOMAIN=""; PREFIX="${DIGITALMAID_PREFIX:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --demo) DEMO="yes"; shift ;;
    --domain) DOMAIN="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --no-service) SERVICE="no"; shift ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --from-tarball) TARBALL="$2"; shift 2 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
step() { printf '\n\033[38;5;178m==\033[0m \033[1m%s\033[0m\n' "$1"; }
ok()   { printf '   \033[32m✓\033[0m %s\n' "$1"; }
note() { printf '   \033[33m!\033[0m %s\n' "$1"; }
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
case "$DOMAIN" in *[!A-Za-z0-9.-]*) fail "--domain must be a hostname like srv123.example.com" ;; esac

# --- who runs what --------------------------------------------------------------------------
# Root (typical on a VPS): install system-wide under /opt/digitalmaid, owned by a dedicated user.
# Anyone else: install under $HOME.
MODE="user"; SVC_USER="${USER:-$(id -un)}"
if [ "$(id -u)" = "0" ]; then
  [ "$OS" = "Linux" ] || fail "please run as a normal user on macOS"
  MODE="system"; SVC_USER="digitalmaid"
  PREFIX="${PREFIX:-/opt/digitalmaid}"
  if ! id "$SVC_USER" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "/var/lib/$SVC_USER" --shell /usr/sbin/nologin "$SVC_USER" 2>/dev/null \
      || useradd -r -m -d "/var/lib/$SVC_USER" -s /usr/sbin/nologin "$SVC_USER" || fail "could not create the '$SVC_USER' user"
  fi
  # uv, its Pythons and its cache stay inside PREFIX so the service user can run them.
  export UV_INSTALL_DIR="$PREFIX/uv" UV_PYTHON_INSTALL_DIR="$PREFIX/python" UV_CACHE_DIR="$PREFIX/cache" HOME="$PREFIX/home"
  mkdir -p "$HOME"
else
  PREFIX="${PREFIX:-$HOME/.digitalmaid}"
  [ -z "$DOMAIN" ] || fail "--domain needs root (it installs Caddy and opens ports); run: sudo bash -s -- --domain $DOMAIN"
fi
SYSTEMD_DIR="${DIGITALMAID_SYSTEMD_DIR:-/etc/systemd/system}"   # overridable for tests
CADDYFILE="${DIGITALMAID_CADDYFILE:-/etc/caddy/Caddyfile}"

APP="$PREFIX/app"; VENV="$PREFIX/venv"; ROOT="$PREFIX/workspace"; BIN="$PREFIX/bin"
mkdir -p "$PREFIX" "$BIN"

bold ""
bold "  DigitalMaid Agentic OS"
printf '  installing to %s' "$PREFIX"
[ "$MODE" = "system" ] && printf ' (runs as user %s)' "$SVC_USER"; printf '\n'
TOTAL=6; [ -n "$DOMAIN" ] && TOTAL=7

step "1/$TOTAL uv (Python manager)"
UV="$(command -v uv 2>/dev/null || true)"
[ -n "$UV" ] || [ ! -x "${UV_INSTALL_DIR:-$HOME/.local/bin}/uv" ] || UV="${UV_INSTALL_DIR:-$HOME/.local/bin}/uv"
[ -n "$UV" ] || [ ! -x "$HOME/.local/bin/uv" ] || UV="$HOME/.local/bin/uv"
if [ -z "$UV" ]; then
  have curl || fail "curl is required"
  curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh >/dev/null
  UV="${UV_INSTALL_DIR:-$HOME/.local/bin}/uv"
fi
[ -x "$UV" ] || fail "uv did not install; see https://docs.astral.sh/uv/"
ok "uv $("$UV" --version | awk '{print $2}')"

step "2/$TOTAL Python 3.12"
PY="$("$UV" python find '>=3.12' 2>/dev/null || true)"
if [ -z "$PY" ]; then "$UV" python install 3.12 >/dev/null; PY="$("$UV" python find '>=3.12')"; fi
ok "$("$PY" -c 'import sys; print("python " + ".".join(map(str, sys.version_info[:3])))')"

step "3/$TOTAL Application"
if [ -n "$TARBALL" ]; then
  [ -f "$TARBALL" ] || fail "tarball not found: $TARBALL"
  SRC="$TARBALL"
else
  have curl || fail "curl is required"
  RAW="https://raw.githubusercontent.com/$RELEASES_REPO/main/releases"
  if [ "$VERSION" = "latest" ]; then
    VERSION="$(curl -fsSL "$RAW/LATEST" | tr -d '[:space:]')" || fail "could not read the latest version"
  fi
  URL="$RAW/v$VERSION/digitalmaid-$VERSION.tar.gz"
  SRC="$(mktemp -t digitalmaid.XXXXXX.tar.gz)"
  curl -fsSL "$URL" -o "$SRC" || fail "could not download $URL"
  # Integrity: compare against the SHA256SUMS published next to the tarball.
  SUMS="$(curl -fsSL "$RAW/v$VERSION/SHA256SUMS" 2>/dev/null || true)"
  if [ -n "$SUMS" ]; then
    WANT="$(printf '%s\n' "$SUMS" | awk -v f="digitalmaid-$VERSION.tar.gz" '$2==f{print $1}')"
    if have sha256sum; then GOT="$(sha256sum "$SRC" | awk '{print $1}')"; else GOT="$(shasum -a 256 "$SRC" | awk '{print $1}')"; fi
    [ -z "$WANT" ] || [ "$WANT" = "$GOT" ] || fail "checksum mismatch for digitalmaid-$VERSION.tar.gz"
  fi
fi
rm -rf "$APP.new"; mkdir -p "$APP.new"
tar -xzf "$SRC" -C "$APP.new" --strip-components=1
[ -f "$APP.new/pyproject.toml" ] || fail "the archive does not look like a DigitalMaid release"
NEWVER="$(sed -n 's/^version = "\(.*\)"/\1/p' "$APP.new/pyproject.toml")"
if [ -d "$APP" ]; then OLDVER="$(sed -n 's/^version = "\(.*\)"/\1/p' "$APP/pyproject.toml" 2>/dev/null || echo '?')"; else OLDVER=""; fi
rm -rf "$APP.old"; [ -d "$APP" ] && mv "$APP" "$APP.old"; mv "$APP.new" "$APP"; rm -rf "$APP.old"
[ -x "$VENV/bin/python" ] || "$UV" venv --quiet --python "$PY" "$VENV" >/dev/null 2>&1
"$UV" pip install --python "$VENV/bin/python" --quiet "$APP"
ln -sf "$VENV/bin/digitalmaid" "$BIN/digitalmaid"
if [ -n "$OLDVER" ] && [ "$OLDVER" != "$NEWVER" ]; then ok "upgraded $OLDVER → $NEWVER"; else ok "digitalmaid $NEWVER"; fi

step "4/$TOTAL Workspace"
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
  SCOPE="$([ -f "$PREFIX/scope" ] && cat "$PREFIX/scope" || echo personal)"
  ok "existing workspace kept ($ROOT)"
fi
printf '%s\n' "$SCOPE" > "$PREFIX/scope"
if [ "$MODE" = "system" ]; then chown -R "$SVC_USER:$SVC_USER" "$PREFIX"; chmod 750 "$PREFIX"; fi

step "5/$TOTAL Background services"
REMOTE=""; [ -n "$DOMAIN" ] && REMOTE=" --allow-remote"
SERVE_CMD="$VENV/bin/digitalmaid serve --root $ROOT --scope $SCOPE --host 127.0.0.1 --port $PORT$REMOTE"
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
STARTED="no"; STATUS_HINT="$BIN/digitalmaid-start"
if [ "$SERVICE" = "yes" ] && [ "$MODE" = "system" ] && have systemctl; then
  mkdir -p "$SYSTEMD_DIR"
  cat > "$SYSTEMD_DIR/digitalmaid.service" <<EOF
[Unit]
Description=DigitalMaid Agentic OS (web UI)
After=network.target
[Service]
User=$SVC_USER
Group=$SVC_USER
ExecStart=$SERVE_CMD
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$ROOT
[Install]
WantedBy=multi-user.target
EOF
  cat > "$SYSTEMD_DIR/digitalmaid-worker.service" <<EOF
[Unit]
Description=DigitalMaid Agentic OS (automation worker)
After=digitalmaid.service
[Service]
User=$SVC_USER
Group=$SVC_USER
ExecStart=$WORKER_CMD
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$ROOT
# To let live AI agents run: put DIGITALMAID_LLM_API_KEY=... in $PREFIX/env (chown root, chmod 600) and uncomment:
# EnvironmentFile=-$PREFIX/env
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now digitalmaid.service digitalmaid-worker.service >/dev/null 2>&1 || true
  systemctl restart digitalmaid.service digitalmaid-worker.service >/dev/null 2>&1 || true
  STARTED="yes"; STATUS_HINT="systemctl status digitalmaid digitalmaid-worker"
  ok "system services: digitalmaid, digitalmaid-worker (run as $SVC_USER, start at boot)"
elif [ "$SERVICE" = "yes" ] && [ "$OS" = "Linux" ] && have systemctl && systemctl --user show-environment >/dev/null 2>&1; then
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
  loginctl enable-linger "$SVC_USER" >/dev/null 2>&1 || true
  STARTED="yes"; STATUS_HINT="systemctl --user status digitalmaid digitalmaid-worker"
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
  STARTED="yes"; STATUS_HINT="tail $PREFIX/logs/*.log"
  ok "launchd agents: com.digitalmaid.serve, com.digitalmaid.worker (start at login)"
else
  if [ "$SERVICE" = "yes" ] && [ "$OS" = "Linux" ]; then
    note "no systemd user session here (e.g. after 'su'); log in as $SVC_USER directly and re-run, or start by hand:"
  fi
  ok "no service registered; start with: $BIN/digitalmaid-start"
fi

if [ -n "$DOMAIN" ]; then
  step "6/$TOTAL HTTPS (Caddy) for $DOMAIN"
  if ! have caddy; then
    have apt-get || fail "automatic Caddy install needs apt (Debian/Ubuntu); install Caddy yourself and re-run"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y -qq caddy >/dev/null 2>&1 || fail "could not install Caddy; see https://caddyserver.com/docs/install"
  fi
  ok "caddy $(caddy version 2>/dev/null | awk '{print $1}')"
  mkdir -p "$(dirname "$CADDYFILE")"
  # Keep whatever else the Caddyfile serves; replace only our marked block.
  if [ -f "$CADDYFILE" ] && ! grep -q '# digitalmaid:begin' "$CADDYFILE"; then
    cp "$CADDYFILE" "$CADDYFILE.before-digitalmaid"
    # The stock Caddyfile serves a placeholder site on :80, which would take the port from us.
    if grep -qE '^\s*:80\s*\{' "$CADDYFILE"; then : > "$CADDYFILE"; fi
  fi
  TMP="$(mktemp)"
  awk '/# digitalmaid:begin/{skip=1} !skip{print} /# digitalmaid:end/{skip=0}' "$CADDYFILE" 2>/dev/null > "$TMP" || true
  cat >> "$TMP" <<EOF
# digitalmaid:begin (managed by the DigitalMaid installer)
$DOMAIN {
    reverse_proxy 127.0.0.1:$PORT
    header Strict-Transport-Security "max-age=31536000"
}
# digitalmaid:end
EOF
  mv "$TMP" "$CADDYFILE"; chmod 644 "$CADDYFILE"
  if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow 80/tcp >/dev/null 2>&1 || true; ufw allow 443/tcp >/dev/null 2>&1 || true
    ok "ufw: ports 80 and 443 opened"
  fi
  systemctl enable caddy >/dev/null 2>&1 || true
  systemctl reload caddy >/dev/null 2>&1 || systemctl restart caddy >/dev/null 2>&1 || fail "caddy did not start: journalctl -u caddy -n 30"
  ok "https://$DOMAIN → 127.0.0.1:$PORT"
fi

step "$TOTAL/$TOTAL Health check"
LOCAL="http://127.0.0.1:$PORT"; URL="$LOCAL"; [ -n "$DOMAIN" ] && URL="https://$DOMAIN"
HEALTHY="no"
if [ "$STARTED" = "yes" ]; then
  for _ in $(seq 1 40); do curl -fsS "$LOCAL/api/healthz" >/dev/null 2>&1 && { HEALTHY="yes"; break; }; sleep 0.5; done
  if [ "$HEALTHY" = "yes" ]; then ok "app is up on $LOCAL"; else note "app not answering yet; check: $STATUS_HINT"; fi
  if [ -n "$DOMAIN" ]; then
    TLS="no"
    for _ in $(seq 1 60); do curl -fsS "$URL/api/healthz" >/dev/null 2>&1 && { TLS="yes"; break; }; sleep 1; done
    if [ "$TLS" = "yes" ]; then ok "$URL is up (certificate issued)"; else note "$URL not reachable yet — DNS must point at this server and ports 80/443 must be open (Hostinger: VPS → Firewall). Caddy keeps retrying; see: journalctl -u caddy -n 30"; fi
  fi
else
  note "not running — start it with: $BIN/digitalmaid-start"
fi
if [ "$MODE" = "user" ]; then
  case ":$PATH:" in *":$BIN:"*) ;; *)
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
      [ -f "$rc" ] && ! grep -q 'digitalmaid/bin' "$rc" && printf '\n# DigitalMaid\nexport PATH="%s:$PATH"\n' "$BIN" >> "$rc"
    done ;;
  esac
else
  ln -sf "$BIN/digitalmaid" /usr/local/bin/digitalmaid 2>/dev/null || true
fi

# --- uninstaller (written every run so it matches this layout) ------------------------------
cat > "$BIN/digitalmaid-uninstall" <<EOF
#!/usr/bin/env bash
# Removes the app and services. Your workspace ($ROOT) is kept unless you pass --purge.
set -e
if [ "$MODE" = system ]; then
  [ "\$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
  systemctl disable --now digitalmaid.service digitalmaid-worker.service 2>/dev/null || true
  rm -f "$SYSTEMD_DIR/digitalmaid.service" "$SYSTEMD_DIR/digitalmaid-worker.service"; systemctl daemon-reload 2>/dev/null || true
  if [ -f "$CADDYFILE" ] && grep -q '# digitalmaid:begin' "$CADDYFILE"; then
    T="\$(mktemp)"; awk '/# digitalmaid:begin/{skip=1} !skip{print} /# digitalmaid:end/{skip=0}' "$CADDYFILE" > "\$T"; mv "\$T" "$CADDYFILE"
    [ -f "$CADDYFILE.before-digitalmaid" ] && mv "$CADDYFILE.before-digitalmaid" "$CADDYFILE"
    systemctl reload caddy 2>/dev/null || true
  fi
  rm -f /usr/local/bin/digitalmaid
elif command -v systemctl >/dev/null 2>&1; then
  systemctl --user disable --now digitalmaid.service digitalmaid-worker.service 2>/dev/null || true
  rm -f "$HOME/.config/systemd/user/digitalmaid.service" "$HOME/.config/systemd/user/digitalmaid-worker.service"; systemctl --user daemon-reload 2>/dev/null || true
fi
if [ "\$(uname -s)" = Darwin ]; then for l in com.digitalmaid.serve com.digitalmaid.worker; do launchctl bootout "gui/\$(id -u)/\$l" 2>/dev/null || true; rm -f "$HOME/Library/LaunchAgents/\$l.plist"; done; fi
rm -rf "$APP" "$VENV" "$BIN" "$PREFIX/uv" "$PREFIX/python" "$PREFIX/cache" "$PREFIX/home" "$PREFIX/scope"
if [ "\${1:-}" = "--purge" ]; then
  rm -rf "$ROOT" "$PREFIX"; echo "workspace removed"
  [ "$MODE" = system ] && userdel "$SVC_USER" 2>/dev/null && rm -rf "/var/lib/$SVC_USER" && echo "user $SVC_USER removed" || true
else
  echo "workspace kept at $ROOT"
fi
echo "DigitalMaid removed"
EOF
chmod +x "$BIN/digitalmaid-uninstall"
[ "$MODE" = "system" ] && ln -sf "$BIN/digitalmaid-uninstall" /usr/local/bin/digitalmaid-uninstall 2>/dev/null || true

printf '\n'
bold "  Done."
printf '  Open:      %s\n' "$URL"
if [ -n "$DOMAIN" ]; then :; elif [ "$MODE" = "system" ]; then
  printf '             (loopback only — from your computer: ssh -L %s:127.0.0.1:%s root@%s  then open http://localhost:%s;\n' "$PORT" "$PORT" "$(hostname -f 2>/dev/null || hostname)" "$PORT"
  printf '              or re-run with --domain your.server.name for HTTPS)\n'
else
  printf '             (this computer only; for a server run the installer as root with --domain)\n'
fi
if [ "$DEMO" = "yes" ]; then printf '  Sign in:   demo / the password printed above\n'; fi
printf '  Command:   digitalmaid\n'
printf '  Status:    %s\n' "$STATUS_HINT"
printf '  Upgrade:   re-run this same install command\n'
printf '  Uninstall: %s  (add --purge to delete your data too)\n' "$( [ "$MODE" = system ] && echo digitalmaid-uninstall || echo "$BIN/digitalmaid-uninstall")"
printf '  Docs:      %s/docs/  (INSTALL.md, OPERATIONS.md, LIVE-AGENT.md for AI keys)\n' "$APP"
if [ "$STARTED" = "yes" ] && [ "$MODE" = "user" ] && [ -t 1 ]; then
  if [ "$OS" = "Darwin" ]; then open "$URL" 2>/dev/null || true; elif have xdg-open; then xdg-open "$URL" >/dev/null 2>&1 || true; fi
fi
