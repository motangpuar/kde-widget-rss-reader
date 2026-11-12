# News Curator (kde-news-curator)

Inoreader-like KDE Plasma 6 widget with a local Python backend: feed curation,
built-in Instapaper-style reader, open-in-browser fallback.

## Overview
Pure-QML plasmoid (`plasmoid/io.github.infidel.newscurator`) + stdlib-only Python
daemon (`backend/knewsd`) exposing JSON on `127.0.0.1:8770`. No third-party deps.

## Toolchain
- Dev container: Arch (distrobox `archfox`), `qmllint` at `/usr/lib/qt6/bin/qmllint`.
- Host (widget runtime): Fedora Kinoite/Aurora 44, Plasma 6.7.3, `/usr/bin/python3` 3.14,
  QML modules `/usr/lib64/qt6/qml`, `kpackagetool6`.
- Host access from container: `distrobox-host-exec bash -lc '...'`.

## Commands
```bash
# backend tests (container or host, stdlib only)
python3 -m unittest discover -s backend/tests -t . -v

# QML syntax check
qmllint plasmoid/io.github.infidel.newscurator/contents/ui/*.qml

# run backend standalone
python3 -m knewsd --port 8770        # PYTHONPATH=backend

# install widget to host
./install.sh            # kpackagetool6 -i (host) + systemd --user unit
./uninstall.sh

# release artifacts (dist/: .plasmoid, tarball, SHA256SUMS)
./build.sh              # fails if metadata.json and backend VERSION disagree

# reload applet after QML edits
./dev-reload.sh

# full local CI gate (what the workflows run) — always run before pushing
./scripts/ci-local.sh
# replay the published release download + install (local HTTP mirror, real install)
./scripts/simulate-install.sh
./scripts/ci-local.sh --skip-tests   # packaging only, used by the CI package job
```

CI logic must live in `scripts/`, never inline in a workflow `run:` block: heredocs there
cannot be tested locally and one already broke CI once. `scripts/ci-local.sh` enforces that.

Release flow: bump `KPlugin.Version` in
`plasmoid/io.github.infidel.newscurator/metadata.json` **and** `VERSION` in
`backend/knewsd/config.py`, commit, `git tag -a vX.Y.Z`,
`git push origin main --follow-tags`. `.github/workflows/release.yml` then builds and
attaches the artifacts; `.github/workflows/ci.yml` runs the tests and the packaging
check on every push/PR.

## Layout
```
backend/knewsd/{config,db,feeds,readability,fetch,api,__main__}.py
backend/tests/
plasmoid/io.github.infidel.newscurator/  # KPackage root (metadata.json + contents/)
systemd/knewsd.service
icons/                                  # theme icons installed to hicolor
build.sh  install.sh  uninstall.sh  dev-reload.sh
.github/workflows/{ci,release}.yml
LICENSE
```

## Rules
- Backend must stay stdlib-only (host is an immutable OS; no pip installs).
- QML: Plasma 6 imports only (`org.kde.plasma.components` 3.0, `org.kde.kirigami`).
- Mutating API calls require header `X-Knews-Client: plasma` (CSRF guard, no CORS).
- Never write into host system dirs; everything under `~/.local/share/knews-curator`.
