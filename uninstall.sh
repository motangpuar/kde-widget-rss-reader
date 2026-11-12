#!/usr/bin/env bash
# Remove the News Curator applet and backend. Data is kept unless --purge is given.
set -euo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PLASMOID_ID="io.github.infidel.newscurator"
UNIT_DIR="$HOME/.config/systemd/user"
APP_DIR="$HOME/.local/share/knews-curator"
ICON_DIR="$HOME/.local/share/icons/hicolor/scalable/apps"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-$HOME/.cache}/knews-curator"
ENDPOINT="$RUNTIME_DIR/endpoint.json"
LEGACY_AUTOSTART="$HOME/.config/autostart/knewsd.desktop"
LEGACY_PIDFILE="$HOME/.cache/knews-curator/knewsd.pid"
PURGE=0

for arg in "$@"; do
    case "$arg" in
        --purge) PURGE=1 ;;
        *) printf 'usage: %s [--purge]\n' "$0" >&2; exit 2 ;;
    esac
done

if ! command -v kpackagetool6 >/dev/null 2>&1 && command -v distrobox-host-exec >/dev/null 2>&1; then
    exec distrobox-host-exec bash "$PROJECT_DIR/uninstall.sh" "$@"
fi

log() { printf '  %s\n' "$*"; }

# A store install has no unit: the widget spawns the daemon and owns its lifetime. Removing
# the package through kpackagetool6 cannot run code, so a daemon started that way is stopped
# here (and, as a backstop, reaps itself after KNEWS_IDLE_EXIT seconds without a request).
stop_widget_backend() {
    local pyz="$APP_DIR/app/knewsd.pyz"
    [ -x "$pyz" ] || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    if [ -f "$ENDPOINT" ]; then
        local sock port
        sock=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("socket",""))' "$ENDPOINT" 2>/dev/null || true)
        port=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("port",""))' "$ENDPOINT" 2>/dev/null || true)
        if [ -n "$sock" ]; then
            python3 "$pyz" --shutdown --socket "$sock" >/dev/null 2>&1 || true
        elif [ -n "$port" ]; then
            python3 "$pyz" --shutdown --port "$port" >/dev/null 2>&1 || true
        fi
        for _ in $(seq 1 24); do
            [ -f "$ENDPOINT" ] || break
            sleep 0.25
        done
    fi
    [ -f "$LEGACY_PIDFILE" ] && kill "$(cat "$LEGACY_PIDFILE")" 2>/dev/null || true
    command -v pkill >/dev/null 2>&1 && pkill -f "$pyz" 2>/dev/null || true
    rm -f "$LEGACY_PIDFILE" "$ENDPOINT"
}

printf 'Removing News Curator\n'
# Only the opt-in --systemd install creates a unit; every path must work without systemd.
if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now knewsd.service >/dev/null 2>&1 || true
fi
if [ -f "$UNIT_DIR/knewsd.service" ]; then
    rm -f "$UNIT_DIR/knewsd.service"
    command -v systemctl >/dev/null 2>&1 && systemctl --user daemon-reload >/dev/null 2>&1 || true
    log "systemd unit removed"
fi

stop_widget_backend
log "widget-managed daemon stopped"

if [ -f "$LEGACY_AUTOSTART" ] && grep -q 'knews-curator' "$LEGACY_AUTOSTART" 2>/dev/null; then
    rm -f "$LEGACY_AUTOSTART"
    log "legacy autostart entry removed"
fi

if command -v kpackagetool6 >/dev/null 2>&1; then
    kpackagetool6 --type Plasma/Applet --remove "$PLASMOID_ID" >/dev/null 2>&1 || true
    log "applet removed"
fi

rm -f "$ICON_DIR/newscurator.svg" "$ICON_DIR/newscurator-symbolic.svg"
rm -rf "$APP_DIR/app"
rm -f "$RUNTIME_DIR/knewsd.lock" "$RUNTIME_DIR/knewsd.sock"
rmdir "$RUNTIME_DIR" 2>/dev/null || true
log "code removed"

if [ "$PURGE" = "1" ]; then
    rm -rf "$APP_DIR" "$HOME/.cache/knews-curator" "$RUNTIME_DIR"
    log "data purged"
else
    log "data kept in $APP_DIR (use --purge to delete)"
fi
