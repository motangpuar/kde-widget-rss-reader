#!/usr/bin/env bash
# Simulate a user installing News Curator from a GitHub release, without publishing one.
#
# Serves the locally built artifacts on a throwaway HTTP server laid out exactly like the
# release download path (/releases/download/<tag>/<asset>) and then runs the README commands
# against it with the real `curl`, the real `tar` and the real `./install.sh`.
#
#   ./scripts/simulate-install.sh                 # build, download, verify, install
#   ./scripts/simulate-install.sh --skip-install  # download + checksum + extract only
#   ./scripts/simulate-install.sh --tag v1.7.1    # assert a different tag/version pair
#
# Only the host part of the URL differs from the published one, which is what
# `.../releases/latest/download/...` can be checked against before a release exists.
set -euo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PLASMOID_ID="io.github.infidel.newscurator"
PORT=${SIM_PORT:-8790}

SKIP_INSTALL=0
TAG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --skip-install) SKIP_INSTALL=1 ;;
        --tag) shift; TAG=${1:?--tag needs a value} ;;
        *) printf 'usage: %s [--skip-install] [--tag vX.Y.Z]\n' "$0" >&2; exit 2 ;;
    esac
    shift
done

VERSION=$(python3 "$PROJECT_DIR/scripts/check-metadata.py" --print-version)
TAG=${TAG:-v$VERSION}
[ "$TAG" = "v$VERSION" ] || { echo "error: tag $TAG != metadata version v$VERSION" >&2; exit 1; }

WORK=$(mktemp -d /tmp/knews-sim.XXXXXX)
WWW="$WORK/www/releases/download/$TAG"
DL="$WORK/download"
mkdir -p "$WWW" "$DL"
SERVER_PID=""
cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

step() { printf '\n== %s\n' "$*"; }

step "build artifacts"
"$PROJECT_DIR/scripts/ci-local.sh" --skip-tests >/dev/null
printf '  %s\n' "$(cd "$PROJECT_DIR/dist" && sha256sum ./*.plasmoid ./*.tar.gz)"

ASSETS=("$PLASMOID_ID-$VERSION.plasmoid" "news-curator-$VERSION.tar.gz" "SHA256SUMS")
for asset in "${ASSETS[@]}"; do
    cp "$PROJECT_DIR/dist/$asset" "$WWW/"
done

step "serve release assets like github does"
(cd "$WORK/www" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
SERVER_PID=$!
BASE="http://127.0.0.1:$PORT/releases/download/$TAG"
for _ in $(seq 1 40); do
    curl -fsS -o /dev/null "$BASE/SHA256SUMS" 2>/dev/null && break
    sleep 0.25
done
curl -fsS -o /dev/null "$BASE/SHA256SUMS" || { echo "error: mirror did not start" >&2; exit 1; }
printf '  %s/<asset>\n' "$BASE"

step "download with curl (the README command, different host only)"
cd "$DL"
curl -fsSLO "$BASE/news-curator-$VERSION.tar.gz"
curl -fsSLO "$BASE/$PLASMOID_ID-$VERSION.plasmoid"
curl -fsSLO "$BASE/SHA256SUMS"
ls -l | sed 's/^/  /'
# SHA256SUMS is generated with ./ prefixes, so verify it in place.
sha256sum -c SHA256SUMS | sed 's/^/  /'

step "extract and install (the README command)"
tar -xzf "news-curator-$VERSION.tar.gz"
[ -d "news-curator-$VERSION" ] || { echo "error: tarball root is wrong" >&2; exit 1; }
printf '  unpacked news-curator-%s/\n' "$VERSION"

# The widget alone, into a scratch package root: proves the store artifact installs on a
# machine that has no backend and no checkout.
if command -v kpackagetool6 >/dev/null 2>&1 || command -v distrobox-host-exec >/dev/null 2>&1; then
    distrobox-host-exec bash -lc "
        rm -rf /tmp/knews-sim-xdg && mkdir -p /tmp/knews-sim-xdg
        XDG_DATA_HOME=/tmp/knews-sim-xdg kpackagetool6 --type Plasma/Applet --install '$DL/$PLASMOID_ID-$VERSION.plasmoid' >/dev/null
        test -f /tmp/knews-sim-xdg/plasma/plasmoids/$PLASMOID_ID/metadata.json
        grep -q '\"Version\": \"$VERSION\"' /tmp/knews-sim-xdg/plasma/plasmoids/$PLASMOID_ID/metadata.json
        echo '  widget-only install ok (scratch XDG_DATA_HOME)'
    " || { echo "error: widget-only install failed" >&2; exit 1; }
fi

if [ "$SKIP_INSTALL" -eq 1 ]; then
    step "result"
    printf 'download + checksums + extraction verified for %s (install skipped)\n' "$TAG"
    exit 0
fi

step "full install"
cd "news-curator-$VERSION"
./install.sh | sed 's/^/  /'

step "verify the installed machine"
if command -v distrobox-host-exec >/dev/null 2>&1 && ! command -v kpackagetool6 >/dev/null 2>&1; then
    RUN() { distrobox-host-exec bash -lc "$1"; }
else
    RUN() { bash -lc "$1"; }
fi
SERVICE=$(RUN "systemctl --user is-active knewsd.service")
HEALTH=$(RUN "curl -fsS http://127.0.0.1:8770/api/health")
INSTALLED_QML=$(RUN "md5sum \$HOME/.local/share/plasma/plasmoids/$PLASMOID_ID/contents/ui/main.qml" \
    | cut -d' ' -f1)
EXPECTED_QML=$(md5sum "$DL/news-curator-$VERSION/plasmoid/$PLASMOID_ID/contents/ui/main.qml" \
    | cut -d' ' -f1)
printf '  service: %s\n  health:  %s\n' "$SERVICE" "$HEALTH"
printf '  installed qml: %s\n  expected  qml: %s\n' "$INSTALLED_QML" "$EXPECTED_QML"
[ "$SERVICE" = active ] || { echo "error: knewsd is not active" >&2; exit 1; }
[ "$INSTALLED_QML" = "$EXPECTED_QML" ] \
    || { echo "error: installed applet differs from the release contents" >&2; exit 1; }
grep -q "\"version\": \"$VERSION\"" <<<"$HEALTH" \
    || { echo "error: backend reports a different version" >&2; exit 1; }

step "result"
printf 'GitHub-style install of %s verified end to end\n' "$TAG"
