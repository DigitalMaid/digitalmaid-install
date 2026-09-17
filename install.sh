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
#   --hermes              also install the Hermes Agent dashboard plugin (DigitalMaid tab, single sign-on)
#   --hermes-home DIR     Hermes home holding plugins/ and config.yaml (default: ~/.hermes of the user running this)
#   --hermes-docker NAME  Hermes runs in the Docker container NAME on this host (e.g. the Hostinger template):
#                         the plugin then reaches DigitalMaid over the docker bridge; --hermes-home may be
#                         omitted (read from the container's mounts)
#
# Uninstall: the owner can do it from Settings → Uninstall in the app (a flag file that a systemd
# path unit picks up; the app never runs as root), or run PREFIX/bin/digitalmaid-uninstall [--purge].
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
HERMES="no"; HERMES_HOME="${DIGITALMAID_HERMES_HOME:-}"; HERMES_DOCKER=""; INVOKER_HOME="$HOME"
while [ $# -gt 0 ]; do
  case "$1" in
    --demo) DEMO="yes"; shift ;;
    --domain) DOMAIN="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --no-service) SERVICE="no"; shift ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --from-tarball) TARBALL="$2"; shift 2 ;;
    --hermes) HERMES="yes"; shift ;;
    --hermes-home) HERMES_HOME="$2"; HERMES="yes"; shift 2 ;;
    --hermes-docker) HERMES_DOCKER="$2"; HERMES="yes"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
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
# The web app can ask for an uninstall by writing $UNINSTALL_DIR/request.json (owner only,
# password re-entry). A root-owned systemd path unit watches for it; the app never gets root.
UNINSTALL_DIR="$PREFIX/uninstall"
mkdir -p "$PREFIX" "$BIN" "$UNINSTALL_DIR"

bold ""
bold "  DigitalMaid Agentic OS"
printf '  installing to %s' "$PREFIX"
[ "$MODE" = "system" ] && printf ' (runs as user %s)' "$SVC_USER"; printf '\n'
TOTAL=6; [ -n "$DOMAIN" ] && TOTAL=7; [ "$HERMES" = "yes" ] && TOTAL=$((TOTAL+1))
HERMES_HOME_GIVEN="$HERMES_HOME"
HERMES_HOME="${HERMES_HOME:-$INVOKER_HOME/.hermes}"
# The trusted-proxy secret shared with the Hermes plugin lives outside the unit files
# (units are world-readable): the service reads it from this 0600 EnvironmentFile.
HERMES_ENV="$PREFIX/hermes.env"

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
chmod 750 "$UNINSTALL_DIR"

step "5/$TOTAL Background services"
REMOTE=""; [ -n "$DOMAIN" ] && REMOTE=" --allow-remote"
BIND="127.0.0.1"; BRIDGE_GW=""; BRIDGE_NET=""; HERMES_ENV_EXTRA=""; AFTER_DOCKER=""
if [ -n "$HERMES_DOCKER" ]; then
  # Hermes lives in a container: it reaches this host through the docker network's gateway.
  # DigitalMaid binds to that gateway address too (still not the public interface), and the
  # app trusts the SSO handshake from that subnet, not only from loopback.
  have docker || fail "--hermes-docker given but docker is not on PATH"
  docker inspect "$HERMES_DOCKER" >/dev/null 2>&1 || fail "no container named '$HERMES_DOCKER' (docker ps --format '{{.Names}}')"
  BRIDGE_GW="$(docker inspect "$HERMES_DOCKER" --format '{{range .NetworkSettings.Networks}}{{.Gateway}} {{end}}' | awk '{print $1}')"
  BRIDGE_NET="$(docker inspect "$HERMES_DOCKER" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}/{{.IPPrefixLen}} {{end}}' | awk '{print $1}')"
  [ -n "$BRIDGE_GW" ] && [ -n "$BRIDGE_NET" ] || fail "could not read the container's network gateway (docker inspect $HERMES_DOCKER)"
  BIND="$BRIDGE_GW"; REMOTE=" --allow-remote"; AFTER_DOCKER=" docker.service"
  HERMES_ENV_EXTRA="DIGITALMAID_TRUSTED_PROXY_CLIENTS=$BRIDGE_NET"
  if [ -z "$HERMES_HOME_GIVEN" ]; then
    HERMES_HOME="$(docker inspect "$HERMES_DOCKER" --format '{{range .Mounts}}{{if eq .Destination "/opt/data"}}{{.Source}}{{end}}{{end}}')"
    [ -n "$HERMES_HOME" ] || HERMES_HOME="$(docker inspect "$HERMES_DOCKER" --format '{{range .Mounts}}{{if eq .Destination "/root/.hermes"}}{{.Source}}{{end}}{{end}}')"
    [ -n "$HERMES_HOME" ] || fail "could not find the Hermes home mount of $HERMES_DOCKER; pass --hermes-home HOST_DIR"
  fi
  ok "Hermes container $HERMES_DOCKER: gateway $BRIDGE_GW, subnet $BRIDGE_NET, home $HERMES_HOME"
fi
SERVE_CMD="$VENV/bin/digitalmaid serve --root $ROOT --scope $SCOPE --host $BIND --port $PORT$REMOTE"
WORKER_CMD="$VENV/bin/digitalmaid worker --loop --root $ROOT --scope $SCOPE"
# One-click uninstall from the app: a path unit fires the oneshot when the app has written the
# request file. In system mode the oneshot runs as root (no User=), the only place root is used.
write_uninstall_units() { # dir wanted-by
  cat > "$1/digitalmaid-uninstall.path" <<EOF
[Unit]
Description=DigitalMaid Agentic OS (watch for an uninstall request from the app)
[Path]
PathExists=$UNINSTALL_DIR/request.json
Unit=digitalmaid-uninstall.service
[Install]
WantedBy=$2
EOF
  cat > "$1/digitalmaid-uninstall.service" <<EOF
[Unit]
Description=DigitalMaid Agentic OS (uninstall requested from the app)
[Service]
Type=oneshot
ExecStart=$BIN/digitalmaid-uninstall --from-request $UNINSTALL_DIR/request.json
EOF
}
cat > "$BIN/digitalmaid-start" <<EOF
#!/usr/bin/env bash
# Start the DigitalMaid UI and worker in the foreground (Ctrl+C stops both).
set -e
export DIGITALMAID_INSTALL_MODE=$MODE
if [ -f "$HERMES_ENV" ]; then set -a; . "$HERMES_ENV"; set +a; fi
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
After=network.target${AFTER_DOCKER}
[Service]
User=$SVC_USER
Group=$SVC_USER
Environment=DIGITALMAID_UNINSTALL_DIR=$UNINSTALL_DIR
Environment=DIGITALMAID_INSTALL_MODE=system
# Hermes dashboard plugin (--hermes): DIGITALMAID_TRUSTED_PROXY_SECRET=... lives in this 0600 file.
EnvironmentFile=-$HERMES_ENV
ExecStart=$SERVE_CMD
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$ROOT $UNINSTALL_DIR
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
ReadWritePaths=$ROOT $UNINSTALL_DIR
# To let live AI agents run: put DIGITALMAID_LLM_API_KEY=... in $PREFIX/env (chown root, chmod 600) and uncomment:
# EnvironmentFile=-$PREFIX/env
[Install]
WantedBy=multi-user.target
EOF
  write_uninstall_units "$SYSTEMD_DIR" multi-user.target
  systemctl daemon-reload
  systemctl enable --now digitalmaid.service digitalmaid-worker.service >/dev/null 2>&1 || true
  systemctl restart digitalmaid.service digitalmaid-worker.service >/dev/null 2>&1 || true
  systemctl enable --now digitalmaid-uninstall.path >/dev/null 2>&1 || true
  STARTED="yes"; STATUS_HINT="systemctl status digitalmaid digitalmaid-worker"
  ok "system services: digitalmaid, digitalmaid-worker (run as $SVC_USER, start at boot)"
  ok "uninstall watcher: digitalmaid-uninstall.path (Settings → Uninstall in the app)"
elif [ "$SERVICE" = "yes" ] && [ "$OS" = "Linux" ] && have systemctl && systemctl --user show-environment >/dev/null 2>&1; then
  UNITS="$HOME/.config/systemd/user"; mkdir -p "$UNITS"
  cat > "$UNITS/digitalmaid.service" <<EOF
[Unit]
Description=DigitalMaid Agentic OS (web UI)
After=network.target${AFTER_DOCKER}
[Service]
Environment=DIGITALMAID_UNINSTALL_DIR=$UNINSTALL_DIR
Environment=DIGITALMAID_INSTALL_MODE=user
# Hermes dashboard plugin (--hermes): DIGITALMAID_TRUSTED_PROXY_SECRET=... lives in this 0600 file.
EnvironmentFile=-$HERMES_ENV
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
  write_uninstall_units "$UNITS" default.target
  systemctl --user daemon-reload
  systemctl --user enable --now digitalmaid-uninstall.path >/dev/null 2>&1 || true
  loginctl enable-linger "$SVC_USER" >/dev/null 2>&1 || true
  STARTED="yes"; STATUS_HINT="systemctl --user status digitalmaid digitalmaid-worker"
  ok "systemd user services: digitalmaid, digitalmaid-worker (start at login)"
  ok "uninstall watcher: digitalmaid-uninstall.path (Settings → Uninstall in the app)"
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
    reverse_proxy $BIND:$PORT
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

if [ "$HERMES" = "yes" ]; then
  step "$((TOTAL-1))/$TOTAL Hermes dashboard plugin"
  PLUGIN_SRC="$APP/hermes-plugin/digitalmaid"
  [ -d "$PLUGIN_SRC" ] || fail "this release has no hermes-plugin/ folder (needs digitalmaid >= 0.3.0)"
  [ -d "$HERMES_HOME" ] || fail "Hermes home not found: $HERMES_HOME (pass --hermes-home DIR; Hermes keeps plugins/ and config.yaml there)"
  # One shared secret (>= 32 chars): the app trusts loopback requests that carry it.
  SECRET_FILE="$PREFIX/hermes-secret"
  if [ ! -s "$SECRET_FILE" ] || [ "$(wc -c < "$SECRET_FILE")" -lt 32 ]; then
    if have openssl; then SECRET="$(openssl rand -hex 32)"; else SECRET="$("$VENV/bin/python" -c 'import secrets; print(secrets.token_hex(32))')"; fi
    (umask 077; printf '%s\n' "$SECRET" > "$SECRET_FILE")
    unset SECRET
  fi
  chmod 600 "$SECRET_FILE"
  (umask 077; { printf 'DIGITALMAID_TRUSTED_PROXY_SECRET=%s\n' "$(cat "$SECRET_FILE")"; [ -z "$HERMES_ENV_EXTRA" ] || printf '%s\n' "$HERMES_ENV_EXTRA"; } > "$HERMES_ENV")
  chmod 600 "$HERMES_ENV"
  [ "$MODE" != "system" ] || chown "$SVC_USER:$SVC_USER" "$SECRET_FILE" "$HERMES_ENV"
  # The plugin package goes where Hermes discovers user plugins; its own copy of the secret
  # is readable by the Hermes process only (Hermes may run as a different user).
  PLUGIN_DEST="$HERMES_HOME/plugins/digitalmaid"
  mkdir -p "$HERMES_HOME/plugins"
  rm -rf "$PLUGIN_DEST.new"; cp -R "$PLUGIN_SRC" "$PLUGIN_DEST.new"
  rm -rf "$PLUGIN_DEST"; mv "$PLUGIN_DEST.new" "$PLUGIN_DEST"
  (umask 077; cat "$SECRET_FILE" > "$PLUGIN_DEST/secret")
  chmod 600 "$PLUGIN_DEST/secret"
  UPSTREAM_HOST="127.0.0.1"; [ -z "$BRIDGE_GW" ] || UPSTREAM_HOST="$BRIDGE_GW"
  # Inside the container the plugin's secret_file is the container path of the same file.
  SECRET_IN_HERMES="$PLUGIN_DEST/secret"
  if [ -n "$HERMES_DOCKER" ]; then
    CONTAINER_HOME="$(docker inspect "$HERMES_DOCKER" --format "{{range .Mounts}}{{if eq .Source \"$HERMES_HOME\"}}{{.Destination}}{{end}}{{end}}")"
    [ -z "$CONTAINER_HOME" ] || SECRET_IN_HERMES="$CONTAINER_HOME/plugins/digitalmaid/secret"
  fi
  printf '{"upstream": "http://%s:%s", "secret_file": "%s"}\n' "$UPSTREAM_HOST" "$PORT" "$SECRET_IN_HERMES" > "$PLUGIN_DEST/dashboard/config.json"
  HERMES_OWNER="$(stat -c '%u:%g' "$HERMES_HOME" 2>/dev/null || stat -f '%u:%g' "$HERMES_HOME")"
  [ "$(id -u)" != "0" ] || chown -R "$HERMES_OWNER" "$PLUGIN_DEST"
  printf '%s\n' "$HERMES_HOME" > "$PREFIX/hermes-home"
  ok "plugin copied to $PLUGIN_DEST (secret: $PLUGIN_DEST/secret, mode 600)"
  # Hermes only imports a user plugin's backend when it is listed under plugins.enabled.
  # Edit the YAML as text so the owner's comments survive; back the file up first.
  HCFG="$HERMES_HOME/config.yaml"
  if [ -f "$HCFG" ]; then cp -p "$HCFG" "$HCFG.before-digitalmaid"; fi
  "$VENV/bin/python" - "$HCFG" <<'PYEOF'
import re, sys
from pathlib import Path
path = Path(sys.argv[1]); name = "digitalmaid"
text = path.read_text(encoding="utf-8") if path.is_file() else ""
lines = text.splitlines()

def block_end(start):
    """Index just past the last line that belongs to the top-level key at lines[start]."""
    i = start + 1
    while i < len(lines) and (not lines[i].strip() or lines[i][0] in " \t" or lines[i].lstrip().startswith("#")):
        i += 1
    return i

top = next((i for i, l in enumerate(lines) if re.match(r"^plugins\s*:\s*(#.*)?$", l)), None)
if top is None:
    if lines and lines[-1].strip():
        lines.append("")
    lines += ["plugins:", f"  enabled: [{name}]"]
else:
    end = block_end(top)
    en = next((i for i in range(top + 1, end) if re.match(r"^\s+enabled\s*:", lines[i])), None)
    if en is None:
        lines.insert(top + 1, f"  enabled: [{name}]")
    else:
        m = re.match(r"^(\s+)enabled\s*:\s*(.*?)\s*$", lines[en])
        indent, rest = m.group(1), m.group(2)
        if rest.startswith("["):                      # flow list: enabled: [a, b]
            inner = rest[1:rest.rfind("]")]
            items = [x.strip().strip("'\"") for x in inner.split(",") if x.strip()]
            if name not in items:
                items.append(name)
                lines[en] = f"{indent}enabled: [{', '.join(items)}]"
        elif rest in ("", "~", "null"):               # block list: "- a" lines follow
            last = None; item_indent = None
            for j in range(en + 1, end):
                mm = re.match(r"^(\s+)-\s*(.*?)\s*$", lines[j])
                if mm and len(mm.group(1)) >= len(indent):
                    last, item_indent = j, mm.group(1)
                elif lines[j].strip() and not lines[j].lstrip().startswith("#"):
                    break
            items = [re.match(r"^\s+-\s*(.*?)\s*$", lines[k]).group(1).strip("'\"")
                     for k in range(en + 1, (last if last is not None else en) + 1)
                     if re.match(r"^\s+-", lines[k])]
            if name not in items:
                if last is None:
                    lines[en] = f"{indent}enabled: [{name}]"
                else:
                    lines.insert(last + 1, f"{item_indent}- {name}")
        else:
            sys.exit(f"could not understand the plugins.enabled line in {path}: {lines[en]!r}; add '{name}' to plugins.enabled by hand")
    if any(re.match(r"^\s+disabled\s*:.*\b" + name + r"\b", lines[i]) for i in range(top + 1, block_end(top))):
        print(f"   ! {name} is also listed under plugins.disabled in {path}; remove it there")
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PYEOF
  [ "$(id -u)" != "0" ] || chown "$HERMES_OWNER" "$HCFG"
  ok "enabled in $HCFG (plugins.enabled)$([ -f "$HCFG.before-digitalmaid" ] && printf ' — backup: %s.before-digitalmaid' "$HCFG")"
  ok "Hermes plugin installed at $PLUGIN_DEST — restart the Hermes dashboard to see the DigitalMaid tab"
  # The app must re-read its EnvironmentFile; Hermes itself is never restarted by this script.
  if [ "$STARTED" = "yes" ] && [ "$MODE" = "system" ] && have systemctl; then systemctl restart digitalmaid.service >/dev/null 2>&1 || true
  elif [ "$STARTED" = "yes" ] && [ "$OS" = "Linux" ] && have systemctl; then systemctl --user restart digitalmaid.service >/dev/null 2>&1 || true; fi
fi

step "$TOTAL/$TOTAL Health check"
LOCAL="http://$BIND:$PORT"; URL="$LOCAL"; [ -n "$DOMAIN" ] && URL="https://$DOMAIN"
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
#   --from-request FILE   honour a request the app wrote (Settings → Uninstall); "purge" comes from the file
set -e
# This script deletes its own directory: run from a temporary copy (guarded against recursion).
if [ -z "\${DIGITALMAID_UNINSTALL_RELAUNCHED:-}" ]; then
  T="\$(mktemp -t digitalmaid-uninstall.XXXXXX)"; cp "\$0" "\$T"; chmod 700 "\$T"
  DIGITALMAID_UNINSTALL_RELAUNCHED=1 exec bash "\$T" "\$@"
fi
trap 'rm -f "\$0"' EXIT
PURGE=0; REQUEST=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --purge) PURGE=1; shift ;;
    --from-request) REQUEST="\$2"; shift 2 ;;
    -h|--help) sed -n '2,3p' "\$0"; exit 0 ;;
    *) echo "unknown argument: \$1" >&2; exit 2 ;;
  esac
done
if [ -n "\$REQUEST" ]; then
  [ -f "\$REQUEST" ] || { echo "request file not found: \$REQUEST" >&2; exit 1; }
  # Read "purge" while the venv still exists; anything unreadable means: keep the data.
  P="\$("$VENV/bin/python" -c 'import json,sys; print("1" if json.load(open(sys.argv[1])).get("purge") is True else "0")' "\$REQUEST" 2>/dev/null || echo 0)"
  [ "\$P" = 1 ] && PURGE=1
  echo "uninstall requested from the app: \$(cat "\$REQUEST" 2>/dev/null || true)"
fi
if [ "$MODE" = system ]; then
  [ "\$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
  systemctl disable --now digitalmaid.service digitalmaid-worker.service 2>/dev/null || true
  # The watcher goes away too; the oneshot it may have started is this very process, so it is only disabled, never stopped.
  systemctl disable --now digitalmaid-uninstall.path 2>/dev/null || true
  systemctl disable digitalmaid-uninstall.service 2>/dev/null || true
  rm -f "$SYSTEMD_DIR/digitalmaid.service" "$SYSTEMD_DIR/digitalmaid-worker.service" "$SYSTEMD_DIR/digitalmaid-uninstall.path" "$SYSTEMD_DIR/digitalmaid-uninstall.service"
  systemctl daemon-reload 2>/dev/null || true
  if [ -f "$CADDYFILE" ] && grep -q '# digitalmaid:begin' "$CADDYFILE"; then
    T="\$(mktemp)"; awk '/# digitalmaid:begin/{skip=1} !skip{print} /# digitalmaid:end/{skip=0}' "$CADDYFILE" > "\$T"; mv "\$T" "$CADDYFILE"
    [ -f "$CADDYFILE.before-digitalmaid" ] && mv "$CADDYFILE.before-digitalmaid" "$CADDYFILE"
    systemctl reload caddy 2>/dev/null || true
  fi
  rm -f /usr/local/bin/digitalmaid /usr/local/bin/digitalmaid-uninstall
elif command -v systemctl >/dev/null 2>&1; then
  systemctl --user disable --now digitalmaid.service digitalmaid-worker.service digitalmaid-uninstall.path 2>/dev/null || true
  systemctl --user disable digitalmaid-uninstall.service 2>/dev/null || true
  rm -f "$HOME/.config/systemd/user/digitalmaid.service" "$HOME/.config/systemd/user/digitalmaid-worker.service" "$HOME/.config/systemd/user/digitalmaid-uninstall.path" "$HOME/.config/systemd/user/digitalmaid-uninstall.service"
  systemctl --user daemon-reload 2>/dev/null || true
fi
if [ "\$(uname -s)" = Darwin ]; then for l in com.digitalmaid.serve com.digitalmaid.worker; do launchctl bootout "gui/\$(id -u)/\$l" 2>/dev/null || true; rm -f "$HOME/Library/LaunchAgents/\$l.plist"; done; fi
if [ -f "$PREFIX/hermes-home" ]; then
  HH="\$(cat "$PREFIX/hermes-home")"
  if [ -d "\$HH/plugins/digitalmaid" ]; then rm -rf "\$HH/plugins/digitalmaid"; echo "Hermes plugin removed from \$HH/plugins (remove 'digitalmaid' from plugins.enabled in \$HH/config.yaml and restart the Hermes dashboard)"; fi
fi
rm -rf "$APP" "$VENV" "$BIN" "$UNINSTALL_DIR" "$PREFIX/uv" "$PREFIX/python" "$PREFIX/cache" "$PREFIX/home" "$PREFIX/scope" "$PREFIX/hermes-secret" "$PREFIX/hermes.env" "$PREFIX/hermes-home"
if [ "\$PURGE" = 1 ]; then
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
printf '  Uninstall: Settings → Uninstall in the app (owner), or %s  (add --purge to delete your data too)\n' "$( [ "$MODE" = system ] && echo digitalmaid-uninstall || echo "$BIN/digitalmaid-uninstall")"
printf '  Docs:      %s/docs/  (INSTALL.md, OPERATIONS.md, LIVE-AGENT.md for AI keys)\n' "$APP"
if [ "$HERMES" = "yes" ]; then printf '  Hermes:    restart the Hermes dashboard, then open its DigitalMaid tab (plugin: %s)\n' "$HERMES_HOME/plugins/digitalmaid"; fi
if [ "$STARTED" = "yes" ] && [ "$MODE" = "user" ] && [ -t 1 ]; then
  if [ "$OS" = "Darwin" ]; then open "$URL" 2>/dev/null || true; elif have xdg-open; then xdg-open "$URL" >/dev/null 2>&1 || true; fi
fi
