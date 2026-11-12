#!/usr/bin/env bash
# Exercise the in-widget backend bootstrap (plasmoid/.../contents/backend/bootstrap.sh) in a
# throwaway HOME and on throwaway endpoints, so a store-only install cannot regress silently.
#
#   ./scripts/test-bootstrap.sh
#
# Covers the lifetime contract the widget relies on:
#   1. fresh install — copies the bundled zipapp, starts the daemon, writes no autostart entry
#   2. repeat run    — no-op when the same version already answers /api/health
#   3. widget upgrade — package ships a newer backend, the old daemon is replaced
#   4. --restart     — same version, still a clean restart
#   5. socket mode   — unix socket endpoint plus the published loopback port
#   6. idle reaper   — a client-less daemon exits by itself
#   7. --stop        — daemon gone, endpoint file gone, foreign daemons untouched
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PKG="$ROOT/plasmoid/io.github.infidel.newscurator/contents/backend"
PORT=${TEST_PORT:-8789}
HOME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/knews-bootstrap.XXXXXX")
PYZ="$PKG/knewsd.pyz"
BACKUP="$PYZ.orig"

export HOME="$HOME_DIR"
export XDG_DATA_HOME="$HOME_DIR/.local/share"
export XDG_CACHE_HOME="$HOME_DIR/.cache"
export XDG_CONFIG_HOME="$HOME_DIR/.config"
export XDG_RUNTIME_DIR="$HOME_DIR/run"
mkdir -p "$XDG_RUNTIME_DIR"

APP="$XDG_DATA_HOME/knews-curator/app/knewsd.pyz"
ENDPOINT="$XDG_RUNTIME_DIR/knews-curator/endpoint.json"
SOCK="$XDG_RUNTIME_DIR/knews-curator/knewsd.sock"
LOG="$XDG_CACHE_HOME/knews-curator/knewsd.log"

cleanup() {
    pkill -f "$HOME_DIR" 2>/dev/null || true
    [ -f "$BACKUP" ] && mv -f "$BACKUP" "$PYZ"
    rm -rf "$HOME_DIR"
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Health of whatever transport the caller names, printed as one compact JSON line.
probe_port() { python3 "$APP" --probe --port "$1" 2>/dev/null || true; }
probe_sock() { python3 "$APP" --probe --socket "$1" 2>/dev/null || true; }
field() { printf '%s' "$1" | python3 -c 'import json,sys;print(json.load(sys.stdin).get(sys.argv[1],""))' "$2"; }

bootstrap() { sh "$PKG/bootstrap.sh" "$@" 2>&1; }

[ -f "$PYZ" ] || fail "$PYZ missing — run ./build.sh first"
command -v python3 >/dev/null || fail "python3 missing"

printf '== fresh install\n'
# A 1.8.x install left this behind; it must vanish, not be reused.
mkdir -p "$(dirname "$XDG_CONFIG_HOME/autostart/knewsd.desktop")"
printf '[Desktop Entry]\nExec=python3 %s --port %s\n' "$APP" "$PORT" \
    > "$XDG_CONFIG_HOME/autostart/knewsd.desktop"

out=$(bootstrap --port "$PORT") || fail "bootstrap failed: $out"
grep -q BOOTSTRAP_STARTED <<<"$out" || fail "expected BOOTSTRAP_STARTED, got: $out"
grep -q BOOTSTRAP_ENDPOINT <<<"$out" || fail "expected BOOTSTRAP_ENDPOINT, got: $out"
[ -f "$APP" ] || fail "zipapp not installed"
[ -f "$XDG_CONFIG_HOME/autostart/knewsd.desktop" ] && fail "legacy autostart entry survived"
[ -f "$ENDPOINT" ] || fail "endpoint file not published"
version=$(field "$(probe_port "$PORT")" version)
[ -n "$version" ] || fail "backend did not answer on port $PORT"
[ "$(field "$(cat "$ENDPOINT")" port)" = "$PORT" ] || fail "endpoint file port mismatch"
printf '  running %s on port %s, no autostart entry\n' "$version" "$PORT"

printf '== repeat run\n'
out=$(bootstrap --port "$PORT") || fail "second bootstrap failed: $out"
grep -q BOOTSTRAP_ALREADY <<<"$out" || fail "expected BOOTSTRAP_ALREADY, got: $out"
printf '  idempotent\n'

printf '== widget upgrade\n'
# Rewrite the packaged zipapp so it claims a newer version, exactly like a package upgrade.
cp "$PYZ" "$BACKUP"
python3 - "$PYZ" <<'PATCH'
import re
import sys
import zipfile

path = sys.argv[1]
with zipfile.ZipFile(path) as source:
    entries = [(name, source.read(name)) for name in source.namelist()]
with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as target:
    for name, data in entries:
        if name == "knewsd/config.py":
            data = re.sub(rb'VERSION = "[^"]*"', b'VERSION = "9.9.9"', data, count=1)
        target.writestr(name, data)
PATCH
out=$(bootstrap --port "$PORT") || fail "upgrade bootstrap failed: $out"
grep -q "restarting" <<<"$out" || fail "expected a restart, got: $out"
new_version=$(field "$(probe_port "$PORT")" version)
[ "$new_version" = "9.9.9" ] || fail "version did not change ($new_version)"
printf '  %s -> %s after restart\n' "$version" "$new_version"

printf '== explicit restart\n'
out=$(bootstrap --port "$PORT" --restart) || fail "--restart failed: $out"
grep -q BOOTSTRAP_STARTED <<<"$out" || fail "expected BOOTSTRAP_STARTED after --restart, got: $out"
printf '  restarted\n'

printf '== endpoint change from settings\n'
# The user picks another port, then the other transport. --restart has to follow the published
# endpoint: the single-instance lock would otherwise block the new daemon while the old one keeps
# answering, which is exactly how a store install would end up with two backends.
OTHER=$((PORT + 1))
out=$(bootstrap --port "$OTHER" --restart) || fail "moving to port $OTHER failed: $out"
grep -q BOOTSTRAP_STARTED <<<"$out" || fail "expected BOOTSTRAP_STARTED after the move, got: $out"
[ -z "$(probe_port "$PORT")" ] || fail "old port still answers after the move"
[ -n "$(probe_port "$OTHER")" ] || fail "backend did not move to port $OTHER"
[ "$(field "$(cat "$ENDPOINT")" port)" = "$OTHER" ] || fail "endpoint file still points at the old port"
[ "$(pgrep -fc "$APP" || true)" = "1" ] || fail "expected exactly one daemon after the move"
# The widget's --stop carries no endpoint arguments: the published file decides.
out=$(bootstrap --stop) || fail "--stop without endpoint arguments failed: $out"
[ -z "$(probe_port "$OTHER")" ] || fail "--stop without endpoint arguments missed the daemon"
out=$(bootstrap --port "$OTHER" --restart) || fail "restart after the stop failed: $out"
out=$(bootstrap --socket "$SOCK" --restart) || fail "switching to a socket failed: $out"
[ -z "$(probe_port "$OTHER")" ] || fail "old port still answers after switching to a socket"
[ -n "$(probe_sock "$SOCK")" ] || fail "socket does not answer after switching"
[ "$(pgrep -fc "$APP" || true)" = "1" ] || fail "expected exactly one daemon after the transport switch"
out=$(bootstrap --port "$PORT" --restart) || fail "switching back to a port failed: $out"
[ -z "$(probe_sock "$SOCK")" ] || fail "socket still answers after switching back"
printf '  endpoint changes replace the daemon instead of adding one\n'

printf '== widget default socket (empty --socket)\n'
# The widget passes --socket '' when the configured path is the per-session default, and it calls
# plain start (no --restart) on load. A port daemon is still running here, so this exercises both
# the empty-argument path and following the published endpoint to stop the old daemon.
out=$(bootstrap --port "$PORT" --restart) || fail "restart before the default-socket test failed: $out"
out=$(bootstrap --socket '') || fail "empty --socket rejected: $out"
grep -q BOOTSTRAP_STARTED <<<"$out" || fail "empty --socket did not start a daemon: $out"
[ -z "$(probe_port "$PORT")" ] || fail "old port daemon survived the switch to the default socket"
[ -n "$(probe_sock "$SOCK")" ] || fail "empty --socket did not use $SOCK"
[ "$(field "$(cat "$ENDPOINT")" transport)" = "socket" ] || fail "endpoint file is not in socket mode"
[ "$(pgrep -fc "$APP" || true)" = "1" ] || fail "expected exactly one daemon after the default-socket switch"
printf '  empty --socket resolved to %s, previous port daemon stopped\n' "$SOCK"
out=$(bootstrap --stop) || fail "--stop after the default-socket test failed: $out"

printf '== socket mode\n'
out=$(bootstrap --port "$PORT" --stop) || fail "--stop failed: $out"
out=$(bootstrap --socket "$SOCK") || fail "socket bootstrap failed: $out"
grep -q BOOTSTRAP_STARTED <<<"$out" || fail "expected BOOTSTRAP_STARTED, got: $out"
[ -S "$SOCK" ] || fail "unix socket not created"
sock_health=$(probe_sock "$SOCK")
[ "$(field "$sock_health" transport)" = "socket" ] || fail "socket daemon has the wrong transport"
loop_port=$(field "$sock_health" port)
[ "$loop_port" != "0" ] || fail "socket mode published no loopback port"
[ -n "$(probe_port "$loop_port")" ] || fail "widget channel (port $loop_port) does not answer"
printf '  unix socket %s + loopback %s for the widget\n' "$SOCK" "$loop_port"

out=$(bootstrap --socket "$SOCK" --stop) || fail "socket --stop failed: $out"
grep -q BOOTSTRAP_STOPPED <<<"$out" || fail "expected BOOTSTRAP_STOPPED, got: $out"
[ -S "$SOCK" ] && fail "socket file survived --stop"
printf '  stopped over the socket\n'

printf '== idle reaper\n'
out=$(bootstrap --port "$PORT" --idle-exit 2) || fail "idle bootstrap failed: $out"
grep -q BOOTSTRAP_STARTED <<<"$out" || fail "expected BOOTSTRAP_STARTED, got: $out"
# Any probe counts as a request, so wait in silence: that is the orphan scenario.
sleep 7
[ -z "$(probe_port "$PORT")" ] || fail "backend ignored --idle-exit 2"
[ -f "$ENDPOINT" ] && fail "endpoint file survived the idle exit"
printf '  client-less daemon exited and cleaned up\n'

printf '== foreign daemon is left alone\n'
FOREIGN="$HOME_DIR/foreign"
mkdir -p "$FOREIGN"
cp "$APP" "$FOREIGN/knewsd.pyz"
setsid python3 "$FOREIGN/knewsd.pyz" --port "$PORT" --idle-exit 0 >>"$LOG" 2>&1 </dev/null &
for _ in $(seq 1 20); do
    [ -n "$(python3 "$FOREIGN/knewsd.pyz" --probe --port "$PORT" 2>/dev/null || true)" ] && break
    sleep 0.25
done
out=$(bootstrap --port "$PORT" --stop) || fail "--stop failed: $out"
[ -n "$(python3 "$FOREIGN/knewsd.pyz" --probe --port "$PORT" 2>/dev/null || true)" ] \
    || fail "--stop killed a backend it did not start"
# Switching to the socket default must not start a second backend beside it: the foreign daemon
# keeps its endpoint, so the bootstrap attaches to it (this is the systemd-unit case too).
out=$(bootstrap --socket '') || fail "socket start next to a foreign daemon failed: $out"
grep -q BOOTSTRAP_ALREADY <<<"$out" || fail "expected BOOTSTRAP_ALREADY, got: $out"
[ -z "$(probe_sock "$SOCK")" ] || fail "a second backend was started on the socket"
[ "$(pgrep -fc "$APP" || true)" = "0" ] || fail "our backend was started next to the foreign one"
python3 "$FOREIGN/knewsd.pyz" --shutdown --port "$PORT" >/dev/null 2>&1 || true
printf '  foreign backend untouched, socket start attached instead of stacking\n'

printf '== stop\n'
out=$(bootstrap --port "$PORT") || fail "final bootstrap failed: $out"
grep -q BOOTSTRAP_STARTED <<<"$out" || fail "expected BOOTSTRAP_STARTED, got: $out"
out=$(bootstrap --port "$PORT" --stop) || fail "--stop failed: $out"
grep -q BOOTSTRAP_STOPPED <<<"$out" || fail "expected BOOTSTRAP_STOPPED, got: $out"
[ -n "$(probe_port "$PORT")" ] && fail "backend still answers after --stop"
[ -f "$ENDPOINT" ] && fail "endpoint file survived --stop"
printf '  stopped, nothing left behind\n'

printf '== result\nbootstrap ok\n'
