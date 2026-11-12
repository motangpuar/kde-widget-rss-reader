#!/usr/bin/env bash
# Local CI gate: run everything the GitHub workflows run, before pushing.
#
#   ./scripts/ci-local.sh                # full gate (tests included)
#   ./scripts/ci-local.sh --skip-tests   # packaging only (used by the CI package job)
#   ./scripts/ci-local.sh --allow-dirty  # keep a pre-existing dist/ instead of rebuilding
#
# Rules this gate exists to enforce:
#   - workflow YAML only *calls* scripts; CI logic lives in scripts/ so it can run here
#   - workflow files contain no inline heredocs (that is the bug class that reached CI once)
set -euo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$PROJECT_DIR"

SKIP_TESTS=0
for arg in "$@"; do
    case "$arg" in
        --skip-tests) SKIP_TESTS=1 ;;
        *) printf 'usage: %s [--skip-tests]\n' "$0" >&2; exit 2 ;;
    esac
done

step() { printf '\n== %s\n' "$*"; }

step "shell syntax"
SHELL_SCRIPTS=("build.sh" "install.sh" "uninstall.sh" "dev-reload.sh" \
               "scripts/verify-package.sh" "scripts/simulate-install.sh" \
               "scripts/test-bootstrap.sh")
for script in "${SHELL_SCRIPTS[@]}"; do
    [ -f "$script" ] || { printf 'error: missing %s\n' "$script" >&2; exit 1; }
    bash -n "$script"
    printf '  %s\n' "$script"
done

step "workflow hygiene"
WORKFLOWS=(.github/workflows/*.yml)
[ -e "${WORKFLOWS[0]}" ] || { printf 'error: no workflows found\n' >&2; exit 1; }
for wf in "${WORKFLOWS[@]}"; do
    grep -qE '^on:' "$wf" || { printf 'error: %s has no on: trigger\n' "$wf" >&2; exit 1; }
    grep -qE '^jobs:' "$wf" || { printf 'error: %s has no jobs:\n' "$wf" >&2; exit 1; }
    if grep -qE "<<-?'?[A-Z]+'?" "$wf"; then
        printf 'error: %s embeds a shell heredoc; move that logic into scripts/\n' "$wf" >&2
        exit 1
    fi
    if grep -qP '^\t' "$wf"; then
        printf 'error: %s uses tabs for indentation\n' "$wf" >&2
        exit 1
    fi
    printf '  %s\n' "$wf"
done

step "systemd unit"
grep -q '^Environment=KNEWS_IDLE_EXIT=0$' systemd/knewsd.service \
    || { echo "error: the unit must own the lifetime, so the idle reaper is off" >&2; exit 1; }
grep -q '^ReadWritePaths=-%t/knews-curator$' systemd/knewsd.service \
    || { echo "error: the unit needs a writable runtime dir for socket/lock/endpoint" >&2; exit 1; }
systemd-analyze verify systemd/knewsd.service 2>/dev/null || true
printf '  lifetime owned by the unit, runtime dir writable, idle reaper off\n'

step "qml root handlers"
# qmllint does not flag a handler that is declared twice on the root object, and that is a hard
# runtime error ("Property value set multiple times") that only shows up on a fresh widget load.
python3 - <<'PY'
import pathlib
import re
import sys

bad = 0
for path in sorted(pathlib.Path("plasmoid").rglob("*.qml")):
    seen = {}
    for number, line in enumerate(path.read_text().splitlines(), 1):
        match = re.match(r"^    (on[A-Z]\w*|Component\.on\w+):", line)
        if not match:
            continue
        name = match.group(1)
        if name in seen:
            print(f"error: {path}:{number}: duplicate root handler {name} "
                  f"(first at line {seen[name]})", file=sys.stderr)
            bad = 1
        else:
            seen[name] = number
sys.exit(bad)
PY
printf '  no duplicate root handlers\n'

step "default transport"
python3 - <<'PY'
import pathlib, re, sys
cfg = pathlib.Path("plasmoid/io.github.infidel.newscurator/contents/config/main.xml").read_text()
block = re.search(r'<entry name="connection".*?</entry>', cfg, re.S)
if not block or "<default>socket</default>" not in block.group(0):
    sys.exit("connection default is not socket")
boot = pathlib.Path(
    "plasmoid/io.github.infidel.newscurator/contents/backend/bootstrap.sh").read_text()
line = [l for l in boot.splitlines() if "--socket)" in l]
if not line or "${2?--socket" not in line[0]:
    sys.exit("--socket must accept an empty value (the per-session default path)")
print("  socket is the default transport; empty --socket accepted")
PY

step "metadata"
python3 scripts/check-metadata.py

if [ "$SKIP_TESTS" -eq 0 ]; then
    step "backend tests"
    python3 -m unittest discover -s backend/tests -t . -q
fi

if [ "$SKIP_TESTS" -eq 0 ]; then
    step "backend bootstrap"
    ./scripts/test-bootstrap.sh | tail -3
fi

step "build"
./build.sh

step "bundled backend"
python3 scripts/check-metadata.py --require-backend

step "package contents"
bash scripts/verify-package.sh

step "reproducible build"
hash_dist() { sha256sum dist/*.plasmoid dist/*.tar.gz | awk '{print $1}' | tr '\n' ' '; }
FIRST=$(hash_dist)
sleep 2   # a same-second rebuild hides gzip mtimes; keep the two builds far enough apart
./build.sh >/dev/null
SECOND=$(hash_dist)
[ "$FIRST" = "$SECOND" ] || {
    printf 'error: build is not reproducible\n  %s\n  %s\n' "$FIRST" "$SECOND" >&2
    exit 1
}
printf '  %s\n' "$FIRST"

step "result"
printf 'local CI gate passed (%s)\n' "$(python3 -c 'import json;print(json.load(open("plasmoid/io.github.infidel.newscurator/metadata.json"))["KPlugin"]["Version"])')"
