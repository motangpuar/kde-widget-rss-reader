#!/usr/bin/env bash
# Exercise the in-widget backend bootstrap (plasmoid/.../contents/backend/bootstrap.sh) in a
# throwaway HOME and on a throwaway port, so a store-only install cannot regress silently.
#
#   ./scripts/test-bootstrap.sh
#
# Covers the three real-world paths:
#   1. fresh install  — copies the bundled zipapp, writes the autostart entry, starts the daemon
#   2. repeat run     — no-op when the same version already answers /api/health
#   3. widget upgrade — package ships a newer backend, the old daemon is replaced
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PKG="$ROOT/plasmoid/io.github.infidel.newscurator/contents/backend"
PORT=${TEST_PORT:-8789}
HOME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/knews-bootstrap.XXXXXX")
PIDFILE="$HOME_DIR/.cache/knews-curator/knewsd.pid"
PYZ="$PKG/knewsd.pyz"
BACKUP="$PYZ.orig"

cleanup() {
    [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true
    [ -f "$BACKUP" ] && mv -f "$BACKUP" "$PYZ"
    rm -rf "$HOME_DIR"
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

health_version() {
    python3 - "http://127.0.0.1:$PORT/api/health" <<'PROBE'
import json
import sys
import urllib.request

try:
    with urllib.request.urlopen(sys.argv[1], timeout=2) as response:
        print(json.load(response).get("version", ""))
except Exception:
    print("")
PROBE
}

bootstrap() { HOME="$HOME_DIR" sh "$PKG/bootstrap.sh" --port "$PORT" 2>&1; }

[ -f "$PYZ" ] || fail "$PYZ missing — run ./build.sh first"
command -v python3 >/dev/null || fail "python3 missing"

printf '== fresh install\n'
out=$(bootstrap) || fail "bootstrap failed: $out"
grep -q BOOTSTRAP_STARTED <<<"$out" || fail "expected BOOTSTRAP_STARTED, got: $out"
[ -f "$HOME_DIR/.local/share/knews-curator/app/knewsd.pyz" ] || fail "zipapp not installed"
[ -f "$HOME_DIR/.config/autostart/knewsd.desktop" ] || fail "autostart entry not written"
grep -q "knewsd.pyz" "$HOME_DIR/.config/autostart/knewsd.desktop" || fail "autostart entry is wrong"
version=$(health_version)
[ -n "$version" ] || fail "no backend answering on port $PORT"
printf '  backend %s started, autostart entry written\n' "$version"

printf '== repeat run\n'
out=$(bootstrap) || fail "second bootstrap failed: $out"
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
out=$(bootstrap) || fail "upgrade bootstrap failed: $out"
grep -q "restarting" <<<"$out" || fail "expected a restart, got: $out"
new_version=$(health_version)
[ "$new_version" != "$version" ] || fail "version did not change ($new_version)"
printf '  %s -> %s after restart\n' "$version" "$new_version"

printf '== stop\n'
out=$(HOME="$HOME_DIR" sh "$PKG/bootstrap.sh" --stop) || fail "--stop failed: $out"
grep -q BOOTSTRAP_STOPPED <<<"$out" || fail "expected BOOTSTRAP_STOPPED, got: $out"
[ -f "$HOME_DIR/.config/autostart/knewsd.desktop" ] && fail "autostart entry survived --stop"
[ -n "$(health_version)" ] && fail "backend still answers after --stop"
printf '  stopped and autostart entry removed\n'

printf '== result\nbootstrap ok\n'
