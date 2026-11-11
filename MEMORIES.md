# MEMORIES — kde-news-curator

## Current Status
Shipped v1.0.0 + follow-up: Plasma 6 applet `io.github.infidel.newscurator` + stdlib-only Python
daemon `knewsd` (SQLite, JSON on 127.0.0.1:8770). v1.1: discovery, OPML file picker, favicons.
v1.2 (this branch): strict URL validation before follow, bulk address check + follow
(`/api/validate`, `/api/feeds/bulk`), interactive feed deletion in sidebar *and* settings,
OPML save-to-file (`/api/opml/save`) replacing the browser download link, port removed from the
settings UI. Installed and running on the host. Backend 38 unit tests green; every QML component
plus four driver scenarios (validate, bulk, export, delete) verified under the offscreen harness.

## Active State
- Backend committed (`2d4ee45`); plasmoid/scripts/README committed in the follow-up commit.
- Host: code at `/home/infidel/.local/share/knews-curator/app/knewsd`, unit
  `~/.config/systemd/user/knewsd.service`, DB `~/.local/share/knews-curator/curator.db`,
  image cache `~/.cache/knews-curator/images`, applet under
  `~/.local/share/plasma/plasmoids/io.github.infidel.newscurator`.
- Dev loop: `./install.sh` (full reinstall) or `./dev-reload.sh` (applet only + plasmashell
  restart + QML error grep).

## Known Blockers / Facts
- Host immutable (rpm-ostree); Plasma tooling only on host → scripts self re-exec through
  `distrobox-host-exec`. Project path is identical on both sides.
- No `qmllint` on host, no `qml` runtime on host. Container has Qt 6.12 (`/usr/lib/qt6/bin/qmllint`,
  `/usr/lib/qt6/bin/qml`) but no Plasma modules → runtime checks use a stub import tree at
  `/tmp/qh/imports` (`org.kde.kirigami`, `org.kde.plasma.components` wrappers over QtQuick.Controls).
- Plasma 6 applet QML is only reloaded by restarting `plasmashell`
  (`systemctl --user try-restart app-plasmashell@<hash>.service`); `kpackagetool6 --upgrade` alone does nothing.
- Runtime-only QML errors (property names) are invisible to qmllint when the module is missing;
  plasmashell logs them as `error when loading applet "<id>" QList(...)`.
- `PlasmaComponents3.TextField` has no `clearButtonEnabled`. Icon-only buttons use
  `display: AbstractButton.IconOnly` (QtQuick.Controls) — `PlasmaComponents3.AbstractButton.IconOnly`
  is not guaranteed to resolve.
- Properties auto-generate change signals: a `property string view` forbids `signal viewChanged`
  (use `viewRequested`); same for `port` → `portEdited`.
- systemd `ReadWritePaths=` fails namespace setup (exit 226) if the path is missing → prefix
  with `-` and create dirs before start.
- `systemctl enable --now` does not restart an already-running unit → install.sh uses
  `enable` + `restart`.
- Unit hardening `ProtectHome=read-only` blocks OPML exports anywhere in `$HOME`; unit now adds
  `ReadWritePaths=-%h/Downloads -%h/Documents -%h/Desktop` and `api.save_opml` falls back to
  `<data_dir>/exports/knews-curator-<stamp>.opml` with `fallback: true`.
- `PrivateTmp=yes` in the unit means the daemon's `/tmp` is not the host `/tmp` — never use `/tmp`
  paths for cross-process export verification.
- An OPML export written from a *scratch* daemon started by hand sees host `$HOME`, so scratch
  verification of `save_opml` must target paths the harness can read (or `/tmp/qh`).

## Next Steps
1b. Discovery edge cases: YouTube channel pages return 404 to non-JS clients; consider a
   `youtube.com/channel/UC…` → `feeds/videos.xml?channel_id=` special case.
2. Optional: prefetch preview mark-read on scroll end (currently only on open).
3. Ask user whether the accidental `POST /api/mark-all` at 18:32:25 (all 15 LWN items → read)
   should be reverted; no bulk un-read endpoint exists yet.
4. Consider capping stored `content` HTML per item and pruning old rows (DB growth).

## Chronological History
- 2026-11-11: v1.2 — `fetch.probe` (strict, no discovery) + `/api/validate` (GET single, POST many,
  4-way `ThreadPoolExecutor`), `/api/feeds/bulk`, `/api/opml/save` with read-only fallback,
  AddFeedSheet validate gate, SettingsSheet bulk-URL section + Save-OPML `FileDialog`,
  sidebar hover delete with 4 s confirm, port row removed (main.qml no longer passes `port`).
  Live: `~/Downloads` export 1835 B/10 feeds, blocked folder → `exports/` fallback `fallback:true`.
- 2026-11-11: v1.1 — feed discovery (`/api/discover` + `fetch.discover`), feed favicons
  (`feeds.icon` column + `store_feed_icon`, sidebar + list widget), OPML `FileDialog` import;
  AddFeedSheet rewritten as a follow dialog. 32 tests, 6 harness screens clean.
- 2026-11-11: notice banner in main.qml for import results (top-right, 9 s), README corrections
  around `/api/opml` JSON body.
- 2026-11-11: backend (feeds/readability/fetch/db/api) + 24 tests; commit `2d4ee45`.
- 2026-11-11: QML UI (main, FeedSidebar, ArticleList, ReaderView, AddFeedSheet, SettingsSheet),
  Api.js, icons, systemd unit, install/uninstall/dev-reload scripts, README.
- 2026-11-11: fixed QML runtime errors found via plasmashell journal: `clearButtonEnabled`,
  `PlasmaComponents3.AbstractButton.IconOnly`, duplicate `viewChanged`/`portChanged` signals,
  stale `onDeleteFeedRequested` on FeedSidebar, missing `blockData` plumbing (Loader).
- 2026-11-11: fixed unit `ReadWritePaths` (dirs missing → 226/NAMESPACE) and
  `enable --now` not restarting; added `KNEWS_ACCESS_LOG` request logging.
- 2026-11-11: offscreen harness (`/tmp/qh`) validated ReaderView blocks, ArticleList,
  FeedSidebar, SettingsSheet, AddFeedSheet against live Ars Technica article data.
- 2026-11-11: harness lesson — ids are *not* reachable through a root object property
  (`sheet.urlsArea` throws `TypeError`); use the bare id, or add a real property.
- 2026-11-11: v1.1 — feed discovery (`/api/discover` + `fetch.discover`), feed favicons
  (`feeds.icon` column + `store_feed_icon`, sidebar + list widget), OPML `FileDialog` import;
  AddFeedSheet rewritten as a follow dialog. 32 tests, 6 harness screens clean.
- 2026-11-11: notice banner in main.qml for import results (top-right, 9 s), README corrections
  around `/api/opml` JSON body.
- 2026-11-11: backend (feeds/readability/fetch/db/api) + 24 tests; commit `2d4ee45`.
- 2026-11-11: QML UI (main, FeedSidebar, ArticleList, ReaderView, AddFeedSheet, SettingsSheet),
  Api.js, icons, systemd unit, install/uninstall/dev-reload scripts, README.
- 2026-11-11: fixed QML runtime errors found via plasmashell journal: `clearButtonEnabled`,
  `PlasmaComponents3.AbstractButton.IconOnly`, duplicate `viewChanged`/`portChanged` signals,
  stale `onDeleteFeedRequested` on FeedSidebar, missing `blockData` plumbing (Loader).
- 2026-11-11: fixed unit `ReadWritePaths` (dirs missing → 226/NAMESPACE) and
  `enable --now` not restarting; added `KNEWS_ACCESS_LOG` request logging.
- 2026-11-11: offscreen harness (`/tmp/qh`) validated ReaderView blocks, ArticleList,
  FeedSidebar, SettingsSheet, AddFeedSheet against live Ars Technica article data.
