#!/bin/sh
# Self-install the News Curator backend from inside the widget package.
#
# Shipped at contents/backend/bootstrap.sh next to knewsd.pyz, so the applet can start the
# backend without any manual step: no install script, no systemd unit, no git checkout.
#
#   sh bootstrap.sh --port 8770          ensure it runs (start / restart / no-op)
#   sh bootstrap.sh --stop               stop it and drop the autostart entry
#
# Behaviour is idempotent and safe to run on every widget load:
#   1. copy the bundled zipapp to ~/.local/share/knews-curator/app/knewsd.pyz when it differs
#   2. return immediately when a backend of the same version already answers /api/health
#   3. restart our own zipapp when the package is newer, then wait for the new one
#   4. otherwise start it detached, with an XDG autostart entry so it survives reboots
#
# Exit codes: 0 ok (already running or started), 2 python3 missing, 3 packaged backend missing.
set -eu

PORT=8770
STOP=0
while [ $# -gt 0 ]; do
    case "$1" in
        --port) PORT=${2:?--port needs a value}; shift 2 ;;
        --stop) STOP=1; shift ;;
        *) printf 'bootstrap: unknown argument %s\n' "$1" >&2; exit 64 ;;
    esac
done

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
SRC="$HERE/knewsd.pyz"
APP_DIR="$HOME/.local/share/knews-curator/app"
APP="$APP_DIR/knewsd.pyz"
STATE_DIR="$HOME/.local/share/knews-curator"
CACHE_DIR="$HOME/.cache/knews-curator"
LOG="$CACHE_DIR/knewsd.log"
PIDFILE="$CACHE_DIR/knewsd.pid"
HEALTH="http://127.0.0.1:$PORT/api/health"

[ -f "$SRC" ] || { printf 'bootstrap: packaged backend missing at %s\n' "$SRC" >&2; exit 3; }

if ! command -v python3 >/dev/null 2>&1; then
    printf 'bootstrap: python3 not found\n' >&2
    printf 'BOOTSTRAP_NO_PYTHON\n'
    exit 2
fi

mkdir -p "$APP_DIR" "$CACHE_DIR" "$STATE_DIR"

if [ "$STOP" -eq 1 ]; then
    [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true
    pkill -f "$APP" 2>/dev/null || true
    rm -f "$PIDFILE" "$HOME/.config/autostart/knewsd.desktop"
    printf 'BOOTSTRAP_STOPPED\n'
    exit 0
fi

# Keep the installed copy in step with the package, so upgrading the widget upgrades the backend.
if ! cmp -s "$SRC" "$APP" 2>/dev/null; then
    cp -f "$SRC" "$APP.tmp$$"
    chmod +x "$APP.tmp$$"
    mv -f "$APP.tmp$$" "$APP"
    printf 'bootstrap: installed backend %s -> %s\n' "$SRC" "$APP"
fi

# Autostart entry: the backend then lives on its own after plasmashell restarts or a reboot.
# Rewritten whenever the app path or port changes, so a port change in the widget config sticks.
AUTOSTART="$HOME/.config/autostart/knewsd.desktop"
DESIRED="[Desktop Entry]
Type=Application
Name=News Curator backend
Comment=Feed daemon for the News Curator Plasma widget (started by the widget on first run)
Exec=/bin/sh -c 'command -v python3 >/dev/null && exec python3 \"$APP\" --port $PORT --host 127.0.0.1'
X-GNOME-Autostart-enabled=true
NoDisplay=true
Terminal=false"
if [ ! -f "$AUTOSTART" ] || [ "$(cat "$AUTOSTART")" != "$DESIRED" ]; then
    mkdir -p "$(dirname -- "$AUTOSTART")"
    printf '%s\n' "$DESIRED" > "$AUTOSTART"
    printf 'bootstrap: wrote %s\n' "$AUTOSTART"
fi

# "OK <version>" when something answers, "DOWN" otherwise.
probe() {
    python3 - "$HEALTH" <<'PROBE'
import json
import sys
import urllib.request

try:
    with urllib.request.urlopen(sys.argv[1], timeout=1.5) as response:
        print("OK", json.load(response).get("version", "?"))
except Exception:
    print("DOWN")
PROBE
}

# What the packaged backend claims to be; also proves the zipapp imports cleanly.
WANT=$(python3 "$APP" --version 2>/dev/null | awk '{print $2}')
STATE=$(probe)

if [ "$STATE" = "OK ${WANT:-?}" ]; then
    printf 'BOOTSTRAP_ALREADY\n'
    exit 0
fi

if [ "${STATE#OK }" != "$STATE" ]; then
    # A backend of another version holds the port. Restart it only when it is our own zipapp;
    # a systemd install or a foreign process is left alone and keeps the port.
    printf 'bootstrap: running backend is %s, package has %s — restarting\n' \
        "${STATE#OK }" "${WANT:-?}"
    # Kill only our own installed zipapp: the exact path cannot match an unrelated process.
    [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true
    pkill -f "$APP" 2>/dev/null || true
    sleep 0.6
    STATE=$(probe)
    if [ "${STATE#OK }" != "$STATE" ]; then
        printf 'BOOTSTRAP_ALREADY\n'
        exit 0
    fi
fi

printf 'bootstrap: starting backend on port %s\n' "$PORT"
printf '=== %s start\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG"
PYTHONDONTWRITEBYTECODE=1 setsid python3 "$APP" --port "$PORT" --host 127.0.0.1 \
    >> "$LOG" 2>&1 < /dev/null &
printf '%s\n' "$!" > "$PIDFILE"

i=0
while [ "$i" -lt 40 ]; do
    if [ "$(probe)" = "OK ${WANT:-?}" ]; then
        printf 'BOOTSTRAP_STARTED %s\n' "$(cat "$PIDFILE" 2>/dev/null || echo '?')"
        exit 0
    fi
    i=$((i + 1))
    sleep 0.25
done

printf 'bootstrap: backend did not answer %s, see %s\n' "$HEALTH" "$LOG" >&2
printf 'BOOTSTRAP_FAILED\n'
exit 1
