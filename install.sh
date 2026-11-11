#!/usr/bin/env bash
# Install the News Curator backend, systemd user unit, icon, and Plasma applet.
set -euo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PLASMOID_ID="io.github.infidel.newscurator"
PLASMOID_SRC="$PROJECT_DIR/plasmoid/$PLASMOID_ID"
APP_DIR="$HOME/.local/share/knews-curator/app"
UNIT_DIR="$HOME/.config/systemd/user"
ICON_DIR="$HOME/.local/share/icons/hicolor/scalable/apps"
PORT=${KNEWS_PORT:-8770}

# Plasma tooling lives in the host session, not in a distrobox container.
if ! command -v kpackagetool6 >/dev/null 2>&1 && command -v distrobox-host-exec >/dev/null 2>&1; then
    exec distrobox-host-exec bash "$PROJECT_DIR/install.sh" "$@"
fi

log() { printf '  %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

printf 'Installing News Curator\n'

command -v python3 >/dev/null 2>&1 || die "python3 not found"
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' \
    || die "python3 >= 3.11 required (found $(python3 -V 2>&1))"
log "python: $(python3 -V 2>&1) at $(command -v python3)"

printf 'Backend\n'
mkdir -p "$APP_DIR" "$HOME/.cache/knews-curator/images"
rm -rf "$APP_DIR/knewsd"
cp -r "$PROJECT_DIR/backend/knewsd" "$APP_DIR/knewsd"
find "$APP_DIR/knewsd" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
log "code: $APP_DIR/knewsd"

mkdir -p "$UNIT_DIR"
install -m 644 "$PROJECT_DIR/systemd/knewsd.service" "$UNIT_DIR/knewsd.service"
sed -i "s/--port [0-9]*/--port $PORT/" "$UNIT_DIR/knewsd.service"
log "unit: $UNIT_DIR/knewsd.service"

systemctl --user daemon-reload
systemctl --user enable knewsd.service
systemctl --user restart knewsd.service
log "service: $(systemctl --user is-active knewsd.service 2>/dev/null || echo unknown)"

printf 'Plasma applet\n'
if ! command -v kpackagetool6 >/dev/null 2>&1; then
    die "kpackagetool6 not found — install the Plasma 6 development tooling"
fi
if kpackagetool6 --type Plasma/Applet --upgrade "$PLASMOID_SRC" >/dev/null 2>&1; then
    log "upgraded $PLASMOID_ID"
else
    kpackagetool6 --type Plasma/Applet --install "$PLASMOID_SRC" >/dev/null
    log "installed $PLASMOID_ID"
fi

printf 'Icons\n'
install -Dm644 "$PROJECT_DIR/icons/newscurator.svg" "$ICON_DIR/newscurator.svg"
install -Dm644 "$PROJECT_DIR/icons/newscurator-symbolic.svg" "$ICON_DIR/newscurator-symbolic.svg"
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true
fi
log "theme icons: newscurator, newscurator-symbolic"

printf 'Health check\n'
if python3 - "$PORT" <<'PY'
import json, sys, time, urllib.request

port = sys.argv[1]
url = f"http://127.0.0.1:{port}/api/health"
deadline = time.time() + 20
last = None
while time.time() < deadline:
    try:
        with urllib.request.urlopen(url, timeout=2) as response:
            payload = json.loads(response.read())
        print("  ok:", json.dumps({k: payload[k] for k in ("ok", "version") if k in payload}))
        sys.exit(0)
    except Exception as error:  # noqa: BLE001
        last = error
        time.sleep(0.5)
print(f"  backend did not answer on {url}: {last}", file=sys.stderr)
sys.exit(1)
PY
then
    :
else
    die "backend health check failed — run: journalctl --user -u knewsd -n 50"
fi

cat <<EOF

Done.
  API      http://127.0.0.1:$PORT/api/health
  Data     ~/.local/share/knews-curator/curator.db
  Logs     journalctl --user -u knewsd -f

Add the widget: right-click panel or desktop -> Add Widgets -> "News Curator".
EOF
