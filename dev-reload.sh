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
START=$(date "+%Y-%m-%d %H:%M:%S")
# Restart plasmashell through systemd when the session has it, otherwise replace the process the
# way any non-systemd session does; the widget must not care which one runs here.
PLASMA_UNIT=""
if command -v systemctl >/dev/null 2>&1; then
    PLASMA_UNIT=$(systemctl --user list-units --type=service --no-legend --all \
        'plasma-plasmashell.service' 'app-plasmashell@*.service' 2>/dev/null \
        | awk '$3 == "active" {print $1}' | head -1)
fi
[ -n "$PLASMA_UNIT" ] || PLASMA_UNIT=""
if [ -n "$PLASMA_UNIT" ]; then
    systemctl --user try-restart "$PLASMA_UNIT"
else
    command -v plasmashell >/dev/null 2>&1 || { echo "neither a plasmashell unit nor plasmashell found" >&2; exit 1; }
    plasmashell --replace >/dev/null 2>&1 &
fi
sleep 8
if [ -n "$PLASMA_UNIT" ] && command -v journalctl >/dev/null 2>&1; then
    journalctl --user -u "$PLASMA_UNIT" --since "$START" --no-pager \
        | grep -iE "newscurator" | grep -viE "KPackageStructure|overridden" | tail -40 \
        || echo "no newscurator messages"
else
    grep -iE "newscurator" "${XDG_CACHE_HOME:-$HOME/.cache}/plasmashell.log" 2>/dev/null | tail -40 \
        || echo "no newscurator messages (no journald and no plasmashell.log)"
fi
