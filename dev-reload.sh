#!/usr/bin/env bash
# Dev loop: push the plasmoid to the host, restart plasmashell, show QML errors.
set -euo pipefail
PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PLASMOID_ID="io.github.infidel.newscurator"

if ! command -v kpackagetool6 >/dev/null 2>&1 && command -v distrobox-host-exec >/dev/null 2>&1; then
    exec distrobox-host-exec bash "$PROJECT_DIR/dev-reload.sh" "$@"
fi

kpackagetool6 --type Plasma/Applet --upgrade "$PROJECT_DIR/plasmoid/$PLASMOID_ID" >/dev/null 2>&1 \
    || kpackagetool6 --type Plasma/Applet --install "$PROJECT_DIR/plasmoid/$PLASMOID_ID" >/dev/null
PLASMA_UNIT=$(systemctl --user list-units --type=service --no-legend 'app-plasmashell@*.service' \
    | awk '{print $1}' | head -1)
[ -n "$PLASMA_UNIT" ] || { echo "plasmashell unit not found" >&2; exit 1; }
START=$(date "+%Y-%m-%d %H:%M:%S")
systemctl --user try-restart "$PLASMA_UNIT"
sleep 8
journalctl --user -u "$PLASMA_UNIT" --since "$START" --no-pager \
    | grep -iE "newscurator" | grep -viE "KPackageStructure|overridden" | tail -40 \
    || echo "no newscurator messages"
