#!/usr/bin/env bash
# Build the release artifacts into dist/:
#   io.github.infidel.newscurator-<version>.plasmoid   widget package (KDE Store upload)
#   news-curator-<version>.tar.gz                      widget + backend + installer
#   SHA256SUMS                                         checksums for both
#
# The version lives in the plasmoid metadata; the backend has its own copy for /api/health and
# the two must never disagree, so the build fails instead of shipping a mismatched pair.
set -euo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PLASMOID_ID="io.github.infidel.newscurator"
PKG_DIR="$PROJECT_DIR/plasmoid/$PLASMOID_ID"
DIST="$PROJECT_DIR/dist"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
[ -f "$PKG_DIR/metadata.json" ] || die "$PKG_DIR/metadata.json not found"
command -v python3 >/dev/null 2>&1 || die "python3 not found"
command -v tar >/dev/null 2>&1 || die "tar not found"

VERSION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["KPlugin"]["Version"])' \
    "$PKG_DIR/metadata.json")
BACKEND_VERSION=$(python3 - "$PROJECT_DIR/backend/knewsd/config.py" <<'PY'
import re, sys
print(re.search(r'^VERSION = "([^"]+)"', open(sys.argv[1]).read(), re.M).group(1))
PY
)
[ -n "$VERSION" ] || die "no KPlugin.Version in metadata.json"
[ "$VERSION" = "$BACKEND_VERSION" ] \
    || die "version mismatch: metadata.json $VERSION vs backend $BACKEND_VERSION"

printf 'Building News Curator %s\n' "$VERSION"
rm -rf "$DIST"
mkdir -p "$DIST"

# ------------------------------------------------------------------ bundled backend (zipapp)
# A single-file, stdlib-only zipapp is what lets a store install work without any script:
# the widget unpacks nothing, it just runs `python3 knewsd.pyz`. It is generated here and
# dropped into the package (contents/backend is gitignored) so `kpackagetool6 --install`
# on the source tree and the packaged zip contain the same thing.
python3 - "$PROJECT_DIR/backend/knewsd" "$PKG_DIR/contents/backend/knewsd.pyz" <<'PYZ'
"""Deterministic zipapp: sorted entries, fixed timestamps, fixed mode.

`python3 -m zipapp` stores each member's mtime, so two builds a second apart hash differently.
The archive layout is the zipapp one: a shebang line, then a normal zip with __main__.py first.
"""
import pathlib
import stat
import sys
import zipfile

source = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2])
target.parent.mkdir(parents=True, exist_ok=True)

stamp = (1980, 1, 1, 0, 0, 0)
members = [("__main__.py", '"""Zipapp entry point: same CLI as `python3 -m knewsd`."""\n'
                           "import sys\n\nfrom knewsd.__main__ import main\n\n"
                           'if __name__ == "__main__":\n    sys.exit(main())\n')]
members += sorted(
    (f"knewsd/{path.name}", path.read_text()) for path in source.glob("*.py")
)

with target.open("wb") as handle:
    handle.write(b"#!/usr/bin/env python3\n")
    with zipfile.ZipFile(handle, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, text in members:
            info = zipfile.ZipInfo(name, date_time=stamp)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (stat.S_IFREG | 0o644) << 16
            archive.writestr(info, text)
target.chmod(0o755)
PYZ
cp "$PKG_DIR/contents/backend/knewsd.pyz" "$DIST/knewsd.pyz"
printf '  backend  knewsd.pyz (%s)\n' "$(du -h "$DIST/knewsd.pyz" | cut -f1)"

# ---------------------------------------------------------------- widget package (.plasmoid)
# A KPackage archive is a zip with metadata.json at its root, which is exactly the layout
# KDE Store expects. Entries are written in sorted order with a fixed timestamp so repeated
# builds of the same tree are byte-identical.
python3 - "$PKG_DIR" "$DIST/$PLASMOID_ID-$VERSION.plasmoid" <<'PY'
import os, sys, zipfile

src, out = sys.argv[1], sys.argv[2]
files = []
for root, dirs, names in os.walk(src):
    dirs.sort()
    for name in sorted(names):
        if name.endswith((".qmlc", ".jsc")) or "__pycache__" in root:
            continue
        full = os.path.join(root, name)
        files.append((os.path.relpath(full, src), full))
# metadata.json must be the first entry: KPackage and store.kde.org look for it there, and some
# unpackers only sniff the head of the archive.
files.sort(key=lambda item: (item[0] != "metadata.json", item[0]))

with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
    for rel, full in files:
        info = zipfile.ZipInfo(rel, date_time=(1980, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = (0o644 & 0xFFFF) << 16
        with open(full, "rb") as fh:
            zf.writestr(info, fh.read())
print(f"  widget   {os.path.basename(out)} ({len(files)} files)")
PY

# --------------------------------------------------------------------- full release tarball
STAGE="$DIST/stage"
ROOT="$STAGE/news-curator-$VERSION"
mkdir -p "$ROOT"
for item in plasmoid backend systemd icons install.sh uninstall.sh dev-reload.sh build.sh \
            README.md LICENSE; do
    [ -e "$PROJECT_DIR/$item" ] || die "missing $item"
    cp -r "$PROJECT_DIR/$item" "$ROOT/"
done
find "$ROOT" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$ROOT" -name '*.pyc' -delete 2>/dev/null || true
# Sorted names, zeroed ownership and a fixed mtime keep the members identical; gzip -n keeps the
# stream identical too. Without -n the gzip header stores the compression time and two builds a
# minute apart hash differently (tar's -c does not imply gzip -n on older GNU tar).
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 \
    -cf - -C "$STAGE" "news-curator-$VERSION" | gzip -9 -n \
    > "$DIST/news-curator-$VERSION.tar.gz"
rm -rf "$STAGE"
printf '  bundle   news-curator-%s.tar.gz\n' "$VERSION"

# --------------------------------------------------------------------------- checksums
(cd "$DIST" && sha256sum ./*.plasmoid ./*.tar.gz > SHA256SUMS)
printf '\nArtifacts in %s:\n' "$DIST"
ls -l "$DIST"
