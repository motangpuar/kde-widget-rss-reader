# MEMORIES — kde-news-curator

## Current Status
Greenfield. Target: Plasma 6 widget (Inoreader-like 3-pane) + local Python feed daemon
with readability extraction (Instapaper-style reader) and open-in-browser.

## Active State
- Repo initialized empty (git), no code yet.
- Container: qt6-declarative installed (qmllint available).
- Host: Fedora Kinoite 44 / Plasma 6.7.3 / python3 3.14 / kpackagetool6 / QML at /usr/lib64/qt6/qml.

## Known Blockers / Facts
- Host is immutable (rpm-ostree) and runs the widget, but code lives in container dir
  `/home/infidel/distrobox/archfox/Projects/kde-news-curator` which is the SAME path visible
  on host `$HOME/Projects/kde-news-curator` → install with `distrobox-host-exec`.
- `distrobox-host-exec` reachable; systemd --user operational (state "degraded").
- Qt rich-text in QML does not load remote images reliably → reader uses structured blocks
  (`paragraph runs`/`image`/`list`/`quote`/`code`) + local cached image files, not HTML.
- QML XHR has no CORS; browser CSRF blocked by custom header `X-Knews-Client: plasma`
  required on mutating calls + no Access-Control-Allow-* headers.

## Next Steps
1. backend: config/db → feeds parser → readability → http api + unittest coverage.
2. plasmoid: metadata, config, 3-pane UI, reader view, add-feed/OPML.
3. install.sh/uninstall.sh + systemd unit; qmllint + live daemon smoke test.
4. Add widget to desktop via plasmashell evaluateScript; check journal for QML errors.

## Chronological History
- 2026-11-11: repo created; env mapped; qt6-declarative added to container for qmllint.
