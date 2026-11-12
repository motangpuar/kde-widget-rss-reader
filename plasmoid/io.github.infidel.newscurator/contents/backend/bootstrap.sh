#!/bin/sh
# Attach the News Curator widget to a backend process — the widget is the supervisor.
#
# Shipped at contents/backend/bootstrap.sh next to knewsd.pyz, so the applet needs no install
# script, no systemd unit and no git checkout.
#
#   sh bootstrap.sh --port 8770              ensure the backend runs on that loopback port
#   sh bootstrap.sh --socket /run/.../sock   ensure it runs on a unix socket (loopback stays too)
#   sh bootstrap.sh ... --restart            stop whatever we started, then start it again
#   sh bootstrap.sh ... --stop               stop it (the widget calls this when it is removed)
#
# Lifetime model (deliberate, see README): the daemon exits on its own after N minutes without
# a request (--idle-exit, default 900, 0 disables), so a widget that disappears without calling
# --stop (plasmashell crash, package removed by kpackagetool6) still cannot leave an orphan.
# There is no XDG autostart entry any more; a stale one from 1.8.x is removed on sight.
#
# Exit codes: 0 ok (running, started or stopped), 2 python3 missing, 3 packaged backend missing.
set -eu

MODE=port
PORT=8770
SOCKET=""
STOP=0
RESTART=0
IDLE=${KNEWS_IDLE_EXIT:-900}

while [ $# -gt 0 ]; do
    case "$1" in
        --port) MODE=port; PORT=${2:?--port needs a value}; SOCKET=""; shift 2 ;;
        # Empty is valid here: it means the per-session default socket path (RUNTIME/knewsd.sock).
        --socket) MODE=socket; SOCKET=${2?--socket needs a value}; shift 2 ;;
        --idle-exit) IDLE=${2:?--idle-exit needs a value}; shift 2 ;;
        --restart) RESTART=1; shift ;;
        --stop) STOP=1; shift ;;
        *) printf 'bootstrap: unknown argument %s\n' "$1" >&2; exit 64 ;;
    esac
done

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
SRC="$HERE/knewsd.pyz"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}/knews-curator"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/knews-curator"
RUNTIME="${XDG_RUNTIME_DIR:-$CACHE}/knews-curator"
APP_DIR="$DATA/app"
APP="$APP_DIR/knewsd.pyz"
LOG="$CACHE/knewsd.log"
LEGACY_PIDFILE="$CACHE/knewsd.pid"
ENDPOINT_FILE="$RUNTIME/endpoint.json"
LEGACY_AUTOSTART="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/knewsd.desktop"

if ! command -v python3 >/dev/null 2>&1; then
    printf 'bootstrap: python3 not found\n' >&2
    printf 'BOOTSTRAP_NO_PYTHON\n'
    exit 2
fi

mkdir -p "$APP_DIR" "$CACHE" "$DATA" "$RUNTIME"

# An empty --socket means "the per-session default", so QML never has to know the path.
if [ "$MODE" = socket ] && [ -z "$SOCKET" ]; then
    SOCKET="$RUNTIME/knewsd.sock"
fi

# ------------------------------------------------ client helpers (no curl, no socat)
# Every helper runs inside the daemon's own client mode, so it speaks both transports.
bin() {
    if [ -x "$APP" ]; then printf '%s\n' "$APP"; else printf '%s\n' "$SRC"; fi
}

probe_at() {  # kind value
    if [ "$1" = socket ]; then
        python3 "$(bin)" --probe --socket "$2"
    else
        python3 "$(bin)" --probe --port "$2"
    fi
}

shutdown_at() {  # kind value
    if [ "$1" = socket ]; then
        python3 "$(bin)" --shutdown --socket "$2"
    else
        python3 "$(bin)" --shutdown --port "$2"
    fi
}

current_kind() { printf '%s\n' "$MODE"; }
current_value() {
    if [ "$MODE" = socket ]; then printf '%s\n' "$SOCKET"; else printf '%s\n' "$PORT"; fi
}

probe() { probe_at "$(current_kind)" "$(current_value)"; }

# Where the daemon is actually listening, as "kind<TAB>value". It can differ from the requested
# settings right after the user changes the port or the connection mode.
published_endpoint() {
    [ -f "$ENDPOINT_FILE" ] || return 1
    python3 - "$ENDPOINT_FILE" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(1)
if data.get("socket"):
    print("socket\t%s" % data["socket"])
elif int(data.get("port") or 0) > 0:
    print("port\t%s" % data["port"])
else:
    raise SystemExit(1)
PY
}

json_field() {
    printf '%s' "$1" | python3 -c 'import json,sys;print(json.load(sys.stdin).get(sys.argv[1], ""))' "$2"
}

remove_legacy_autostart() {
    [ -f "$LEGACY_AUTOSTART" ] || return 0
    if grep -q 'knews-curator' "$LEGACY_AUTOSTART" 2>/dev/null; then
        rm -f "$LEGACY_AUTOSTART"
        printf 'bootstrap: removed legacy autostart entry %s\n' "$LEGACY_AUTOSTART"
    fi
}

# Stop the daemon we own: clean API shutdown first, then the pid it published.
stop_daemon() {
    # Follow the published endpoint first, so a settings change cannot leave the previous daemon
    # (old port, other transport) running next to the new one.
    KIND=$(current_kind)
    VALUE=$(current_value)
    if PUBLISHED=$(published_endpoint); then
        KIND=${PUBLISHED%%	*}
        VALUE=${PUBLISHED#*	}
        if [ "$KIND" != "$(current_kind)" ] || [ "$VALUE" != "$(current_value)" ]; then
            printf 'bootstrap: stopping the daemon published at %s %s\n' "$KIND" "$VALUE"
        fi
    fi
    if HEALTH=$(probe_at "$KIND" "$VALUE" 2>/dev/null); then
        PID=$(json_field "$HEALTH" pid)
        # Never stop a process we did not start: a systemd unit owns its own lifetime.
        OURS=0
        if [ -n "$PID" ] && [ -r "/proc/$PID/cmdline" ]; then
            case "$(tr '\0' ' ' < "/proc/$PID/cmdline")" in
                *"$APP"*) OURS=1 ;;
            esac
        fi
        if [ "$OURS" -eq 0 ]; then
            printf 'bootstrap: backend %s is not ours, leaving it alone\n' "${PID:-?}" >&2
            return 0
        fi
        shutdown_at "$KIND" "$VALUE" >/dev/null 2>&1 || true
        i=0
        while [ "$i" -lt 24 ]; do
            probe_at "$KIND" "$VALUE" >/dev/null 2>&1 || break
            i=$((i + 1))
            sleep 0.25
        done
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            kill "$PID" 2>/dev/null || true
        fi
    fi
    # Pre-1.8 leftovers and any detached copy of our own zipapp.
    [ -f "$LEGACY_PIDFILE" ] && kill "$(cat "$LEGACY_PIDFILE")" 2>/dev/null || true
    rm -f "$LEGACY_PIDFILE" "$ENDPOINT_FILE"
    pkill -f "$APP" 2>/dev/null || true
}

if [ "$STOP" -eq 1 ]; then
    remove_legacy_autostart
    stop_daemon
    printf 'BOOTSTRAP_STOPPED\n'
    exit 0
fi

remove_legacy_autostart

[ -f "$SRC" ] || { printf 'bootstrap: packaged backend missing at %s\n' "$SRC" >&2; exit 3; }

# Keep the installed copy in step with the package, so upgrading the widget upgrades the backend.
if ! cmp -s "$SRC" "$APP" 2>/dev/null; then
    cp -f "$SRC" "$APP.tmp$$"
    chmod +x "$APP.tmp$$"
    mv -f "$APP.tmp$$" "$APP"
    printf 'bootstrap: installed backend %s -> %s\n' "$SRC" "$APP"
fi

WANT=$(python3 "$APP" --version 2>/dev/null | awk '{print $2}')

report_endpoint() {
    printf 'BOOTSTRAP_ENDPOINT %s\n' \
        "$(printf '%s' "$1" | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin),separators=(",",":")))')"
}

# --restart means "nothing of mine survives this": the endpoint may have moved (new port or
# connection mode), and the single-instance lock would otherwise refuse to start the new daemon.
# The systemd unit is untouched here — stop_daemon refuses daemons that are not our zipapp.
if [ "$RESTART" -eq 1 ]; then
    stop_daemon
elif ! probe >/dev/null 2>&1; then
    # Nothing answers on the requested endpoint. If our daemon is published somewhere else the
    # endpoint moved (the user switched port or transport), and the single-instance lock would
    # make the new daemon refuse to start — follow the published endpoint and stop that one.
    if PUBLISHED=$(published_endpoint); then
        KIND=${PUBLISHED%%	*}
        VALUE=${PUBLISHED#*	}
        if [ "$KIND" != "$(current_kind)" ] || [ "$VALUE" != "$(current_value)" ]; then
            printf 'bootstrap: endpoint moved to %s %s, stopping the previous daemon\n' \
                "$(current_kind)" "$(current_value)"
            stop_daemon
            # A daemon we may not stop (systemd unit, foreign listener) still holds the published
            # endpoint. Attach to it instead of starting a second backend next to it.
            if HEALTH=$(probe_at "$KIND" "$VALUE" 2>/dev/null); then
                printf 'bootstrap: attaching to the daemon that owns %s %s\n' "$KIND" "$VALUE"
                report_endpoint "$HEALTH"
                printf 'BOOTSTRAP_ALREADY\n'
                exit 0
            fi
        fi
    fi
fi

if HEALTH=$(probe 2>/dev/null); then
    RUNNING=$(json_field "$HEALTH" version)
    PID=$(json_field "$HEALTH" pid)
    # Only restart a process that is demonstrably our installed zipapp; a systemd unit or a
    # foreign listener keeps the endpoint and we simply attach to it.
    OURS=0
    if [ -n "$PID" ] && [ -r "/proc/$PID/cmdline" ]; then
        case "$(tr '\0' ' ' < "/proc/$PID/cmdline")" in
            *"$APP"*) OURS=1 ;;
        esac
    fi
    if [ "$OURS" -eq 1 ] && { [ "$RESTART" -eq 1 ] || [ "${RUNNING:-?}" != "${WANT:-?}" ]; }; then
        printf 'bootstrap: running backend is %s, package has %s — restarting\n' \
            "${RUNNING:-?}" "${WANT:-?}"
        stop_daemon
    else
        report_endpoint "$HEALTH"
        printf 'BOOTSTRAP_ALREADY\n'
        exit 0
    fi
fi

if [ "$MODE" = socket ]; then
    printf 'bootstrap: starting backend on unix socket %s (loopback port auto)\n' "$SOCKET"
    printf '=== %s start socket=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$SOCKET" >> "$LOG"
    PYTHONDONTWRITEBYTECODE=1 setsid python3 "$APP" --socket "$SOCKET" --idle-exit "$IDLE" \
        >> "$LOG" 2>&1 < /dev/null &
else
    printf 'bootstrap: starting backend on port %s\n' "$PORT"
    printf '=== %s start port=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$PORT" >> "$LOG"
    PYTHONDONTWRITEBYTECODE=1 setsid python3 "$APP" --port "$PORT" --idle-exit "$IDLE" \
        >> "$LOG" 2>&1 < /dev/null &
fi

i=0
while [ "$i" -lt 60 ]; do
    if HEALTH=$(probe 2>/dev/null); then
        if [ "$(json_field "$HEALTH" version)" = "${WANT:-?}" ]; then
            report_endpoint "$HEALTH"
            printf 'BOOTSTRAP_STARTED %s\n' "$(json_field "$HEALTH" pid)"
            exit 0
        fi
    fi
    i=$((i + 1))
    sleep 0.25
done

printf 'bootstrap: backend did not answer, see %s\n' "$LOG" >&2
printf 'BOOTSTRAP_FAILED\n'
exit 1
