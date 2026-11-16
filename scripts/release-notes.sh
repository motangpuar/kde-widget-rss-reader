#!/usr/bin/env bash
# Print the CHANGELOG.md section for one version, so a GitHub release body carries the real notes
# instead of an auto-generated compare link.
#
#   ./scripts/release-notes.sh 1.10.0   > notes.md
#   ./scripts/release-notes.sh            uses the version in metadata.json
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
CHANGELOG="$ROOT/CHANGELOG.md"

VERSION=${1:-}
if [ -z "$VERSION" ]; then
    VERSION=$(python3 "$ROOT/scripts/check-metadata.py" --print-version)
fi
VERSION=${VERSION#v}

[ -f "$CHANGELOG" ] || { printf 'error: %s is missing\n' "$CHANGELOG" >&2; exit 1; }

python3 - "$CHANGELOG" "$VERSION" <<'PY'
import re
import sys

path, version = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()

pattern = re.compile(r"^##\s+v?%s\s*$" % re.escape(version), re.M)
match = pattern.search(text)
if match is None:
    sys.exit(f"error: CHANGELOG.md has no section for {version}")

start = match.end()
nxt = re.search(r"^##\s+", text[start:], re.M)
body = text[start:start + nxt.start()] if nxt else text[start:]

# Drop the fenced-free noise: leading blank lines and trailing separators.
lines = [line.rstrip() for line in body.strip("\n").splitlines()]
if not any(line.strip() for line in lines):
    sys.exit(f"error: CHANGELOG.md section for {version} is empty")
print("\n".join(lines).strip())
PY
