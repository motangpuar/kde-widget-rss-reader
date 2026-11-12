#!/usr/bin/env bash
# Assert that dist/ contains a store-uploadable plasmoid archive and a complete tarball.
# Same checks CI runs, so packaging regressions fail locally first.
set -euo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PLASMOID_ID="io.github.infidel.newscurator"
DIST="$PROJECT_DIR/dist"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

VERSION=$(python3 "$PROJECT_DIR/scripts/check-metadata.py" --print-version)
PLASMOID="$DIST/$PLASMOID_ID-$VERSION.plasmoid"
TARBALL="$DIST/news-curator-$VERSION.tar.gz"

[ -f "$PLASMOID" ] || die "missing $PLASMOID (run ./build.sh)"
[ -f "$TARBALL" ] || die "missing $TARBALL (run ./build.sh)"
[ -f "$DIST/SHA256SUMS" ] || die "missing $DIST/SHA256SUMS (run ./build.sh)"

python3 - "$PLASMOID" <<'PY'
import sys, zipfile

name = sys.argv[1]
with zipfile.ZipFile(name) as zf:
    names = zf.namelist()
    bad = zf.testzip()
assert bad is None, f"corrupt entry: {bad}"
assert names[0] == "metadata.json", f"metadata.json must be the first entry, got {names[:3]}"
assert "contents/ui/main.qml" in names, "contents/ui/main.qml missing"
# A store install has no installer script, so the daemon must travel inside the package.
for required in ("contents/backend/bootstrap.sh", "contents/backend/knewsd.pyz"):
    assert required in names, f"{required} missing"
assert any(n.startswith("contents/config/") for n in names), "contents/config/ missing"
junk = [n for n in names if n.endswith((".qmlc", ".pyc")) or "__pycache__" in n]
assert not junk, f"build artifacts inside the package: {junk}"
print(f"  plasmoid ok: {len(names)} files, metadata.json at root")
PY

TAR_LISTING=$(tar -tzf "$TARBALL")
ROOT_DIR="news-curator-$VERSION"

need_file() {  # exact entry, tar keeps the on-disk name (LICENSE, not license)
    grep -qxF "$1" <<<"$TAR_LISTING" || die "tarball is missing $1"
}

need_dir() {   # directories are listed with a trailing slash
    grep -qF "$1/" <<<"$TAR_LISTING" || die "tarball is missing $1/"
}

need_file "$ROOT_DIR/install.sh"
need_file "$ROOT_DIR/uninstall.sh"
need_file "$ROOT_DIR/LICENSE"
need_file "$ROOT_DIR/README.md"
need_file "$ROOT_DIR/backend/knewsd/__main__.py"
need_file "$ROOT_DIR/plasmoid/$PLASMOID_ID/contents/backend/bootstrap.sh"
need_file "$ROOT_DIR/plasmoid/$PLASMOID_ID/contents/backend/knewsd.pyz"
need_file "$ROOT_DIR/systemd/knewsd.service"
need_file "$ROOT_DIR/plasmoid/$PLASMOID_ID/metadata.json"
need_dir "$ROOT_DIR/plasmoid/$PLASMOID_ID/contents/ui"
if grep -qE "(__pycache__|\.pyc$|\.plasmoid$|\.qmlc$)" <<<"$TAR_LISTING"; then
    die "tarball contains build artifacts"
fi
printf '  tarball ok: %s/ (%s entries)\n' "$ROOT_DIR" "$(wc -l <<<"$TAR_LISTING")"

(cd "$DIST" && sha256sum -c SHA256SUMS >/dev/null) || die "checksum mismatch"
printf '  checksums ok\n'
