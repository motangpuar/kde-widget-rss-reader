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
```

## Layout
```
backend/knewsd/{config,db,feeds,readability,fetch,api,__main__}.py
backend/tests/
plasmoid/io.github.infidel.newscurator/  # KPackage root (metadata.json + contents/)
systemd/knewsd.service
install.sh  uninstall.sh
```

## Rules
- Backend must stay stdlib-only (host is an immutable OS; no pip installs).
- QML: Plasma 6 imports only (`org.kde.plasma.components` 3.0, `org.kde.kirigami`).
- Mutating API calls require header `X-Knews-Client: plasma` (CSRF guard, no CORS).
- Never write into host system dirs; everything under `~/.local/share/knews-curator`.
