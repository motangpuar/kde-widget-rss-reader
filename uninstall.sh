#!/usr/bin/env bash
# Remove the News Curator applet and backend. Data is kept unless --purge is given.
set -euo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PLASMOID_ID="io.github.infidel.newscurator"
UNIT_DIR="$HOME/.config/systemd/user"
APP_DIR="$HOME/.local/share/knews-curator"
ICON_DIR="$HOME/.local/share/icons/hicolor/scalable/apps"
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

printf 'Removing News Curator\n'
systemctl --user disable --now knewsd.service >/dev/null 2>&1 || true
rm -f "$UNIT_DIR/knewsd.service"
systemctl --user daemon-reload || true
log "service removed"

if command -v kpackagetool6 >/dev/null 2>&1; then
    kpackagetool6 --type Plasma/Applet --remove "$PLASMOID_ID" >/dev/null 2>&1 || true
    log "applet removed"
fi

rm -f "$ICON_DIR/newscurator.svg" "$ICON_DIR/newscurator-symbolic.svg"
rm -rf "$APP_DIR/app"
log "code removed"

if [ "$PURGE" = "1" ]; then
    rm -rf "$APP_DIR" "$HOME/.cache/knews-curator"
    log "data purged"
else
    log "data kept in $APP_DIR (use --purge to delete)"
fi
