# MEMORIES — kde-news-curator

## Current Status
v1.9.0 (unreleased, branch `fix/backend-lifetime`): backend lifetime fixed and configurable.
The widget is the sole supervisor of a store install (spawn on load, stop on destruction, idle
reaper as the server-side backstop); `systemd --user` stays the opt-in tarball path with the
reaper disabled. New *Settings → Backend* card: connection mode (loopback port or unix socket),
port, socket path, **Restart backend**, **Stop backend**, endpoint status. `uninstall.sh` now
removes everything an install created, including a widget-started daemon, the 1.8.x autostart
entry, the pidfile and `$XDG_RUNTIME_DIR/knews-curator`.

## Previous Status
v1.7.0: distribution restructure + local CI gate. `build.sh` emits `dist/io.github.infidel.newscurator-<v>.plasmoid`
(deterministic zip, `metadata.json` at archive root, verified installable with
`kpackagetool6 --install`), `dist/news-curator-<v>.tar.gz` (plasmoid + backend + unit + icons +
installer; installed end-to-end from the extracted tarball, health check reported 1.7.0) and
`SHA256SUMS`. Added `LICENSE` (MIT), `contents/icons/` copies of the theme icons, and two
workflows: `ci.yml` (tests on 3.11/3.13, metadata validation, build, package-layout assertions,
checksum verify, artifact upload) and `release.yml` (tag `v*` → test, tag/version crosscheck,
build, `gh release create`). Version is now 1.7.0 in metadata.json and backend config.py. Follow-up: CI logic moved into
`scripts/` (`check-metadata.py`, `verify-package.sh`, `ci-local.sh`) after an inline heredoc in the
workflow resolved `X-Plasma-MainScript` against the package root instead of `contents/` and failed
on the runner; the zip then had to be reordered so `metadata.json` is the first entry, and the
tarball is now built with `--sort=name --owner=0 --group=0 --mtime=@0` so both artifacts are
reproducible (the gate asserts it).

## Previous Status
v1.6.1: the reader's *Text* menu now shows a per-entry icon instead of repeating the group icon in
every row: themes use `color-management` / `brightness-high` / `image-x-generic` / `brightness-low`,
sizes use `format-font-size-less|more` depending on the direction against the current value, line
spacing uses `distribute-vertical-*`, margins use `distribute-horizontal-*`. Icons live in
`Typography.js` next to the values. The list text-size row moved to the top of the *Reading* card and
is now labelled **Text size in the list**; the header chips scale with it too.

## Previous Status
v1.6.0: three follow-ups. The headline list has its own text size pref (`list_scale`, 80–160 %,
zoom buttons in *Settings → Reading*), and its rows got more breathing room: column spacing is
`gridUnit * 0.2` instead of `smallSpacing / 3`, cards pad by `gridUnit * 0.55`, and wrapped title /
summary text uses `lineHeight` 1.15 / 1.2 — `smallSpacing` rounding made the old spacing identical
at any scale. The wide (non-compact) side-by-side layout was deleted: with both panes on
`Layout.fillWidth` the reader became a sliver at the right edge and the list stayed put, so the
reader now replaces the list at every widget width and reuses `maxTextWidth` for line length.

v1.5.1: two follow-ups from live testing. The reader header now carries the feed favicon beside
the feed name. The two checkboxes in *Settings → Reading* draw their own indicator from Breeze
symbolic icons (`checkbox-symbolic` + `checkmark-symbolic`) instead of the desktop-theme checkmark,
which showed no visible change here; the click path and prefs write were already working (the live
daemon logged `POST /api/prefs` 200 and the stored value flipped), so this is a rendering fix only.

v1.5.0: eight UI complaints fixed in one pass. Content typography was removed from the settings
sheet (the reader menu is now the only surface). The bulk-move machinery (row checkboxes, drag
handles, `DropArea` headers, "N selected" toolbar) is gone: a feed moves via a per-row folder
`Menu`. The scope menu is left-aligned under its button, every row carries an icon, folders are
submenus, and the button icon reflects the current scope. The feed sidebar and its toggle were
deleted outright — at the widget's 437 px width `compactUi` is always true, so the "Show feeds"
button could never reveal anything. The reader's appearance button moved to the end of the toolbar
(`Text`, `preferences-desktop-font`) and its five groups carry icons. The scope menu is now built
on every open and destroyed as a whole, because Qt's `addMenu()` wrapper rows are indestructible.

v1.4.1: the six follow-ups. Bulk feed moves (`POST /api/feeds/move` + `db.move_feeds`) were driven
from *Settings → Feeds* by ticking rows and pressing **Move** or by dragging a handle onto a folder
header (both rejected in 1.5.0). The list pane's scope title became the filter button itself
(`TextBesideIcon`) instead of an unlabelled icon next to a static label. Reader typography gained a
`format-text` toolbar menu with Theme / Font / Size / Line spacing / Margins submenus sharing
`Typography.js` with the settings dropdowns. `lineHeightPercent` is applied *and* scales block
spacing.

v1.4.0: fixed five widget defects reported against 1.3.0 — the header feed toggle was pinned
open by a width clause, serif/content preferences appeared dead because `font.family` received a
CSS-style fallback list, the reader star never repainted after a toggle, there was no way to pick a
folder or single feed from the list pane, and mark-all committed on a double click instead of a
dialog. Content typography (theme, font, size, spacing, margins) is now five dropdowns backed by
`font_family` and `reader_padding` prefs.

Shipped v1.0.0 + follow-up: Plasma 6 applet `io.github.infidel.newscurator` + stdlib-only Python
daemon `knewsd` (SQLite, JSON on 127.0.0.1:8770). v1.1: discovery, OPML file picker, favicons.
v1.2 (this branch): strict URL validation before follow, bulk address check + follow
(`/api/validate`, `/api/feeds/bulk`), interactive feed deletion in sidebar *and* settings,
OPML save-to-file (`/api/opml/save`) replacing the browser download link, port removed from the
settings UI. Settings rebuilt as sectioned cards (Reading / Feeds / Add feeds / Backend last) with
folder-grouped subscription management (inline title+URL+folder edit, pause, delete, per-folder add)
and URL retargeting guarded by a live probe. Installed and running on the host. Backend 41 unit tests green; every QML component
plus four driver scenarios (validate, bulk, export, delete) verified under the offscreen harness.

## Active State
- Backend committed (`2d4ee45`); plasmoid/scripts/README committed in the follow-up commit.
- Host: code at `/home/infidel/.local/share/knews-curator/app/knewsd`, unit
  `~/.config/systemd/user/knewsd.service`, DB `~/.local/share/knews-curator/curator.db`,
  image cache `~/.cache/knews-curator/images`, applet under
  `~/.local/share/plasma/plasmoids/io.github.infidel.newscurator`.
- Dev loop: `./install.sh` (full reinstall) or `./dev-reload.sh` (applet only + plasmashell
  restart + QML error grep). Verified after 1.5.0: installed QML md5s match the repo and
  plasmashell logs no `error when loading applet`.
- v1.5.0 files touched: `ArticleList.qml` (scope helpers + JS menu), `SettingsSheet.qml`
  (folder `Menu`, Reading card), `ReaderView.qml` (toolbar order, iconed groups), `main.qml`
  (sidebar wiring removed), `FeedSidebar.qml` **deleted**.

## Known Blockers / Facts
- `AbstractButton.toggle()` does **not** emit `toggled` (that signal is user-interaction only), so
  an offscreen harness must call the handler's state setter directly or set `checked` — toggling a
  checkbox programmatically proves nothing about `onToggled`.
- Give repeated delegates an `objectName` when the harness has to find one specific kind: the item
  tree also contains internal child items, so `text === ""` / `width < 40` predicates match dozens
  of unrelated nodes (40 matches for 9 feed rows).
- A Menu is not instantiated until the first `popup()`, so its items are invisible to the harness;
  once created it is reachable through `Item.resources` (it is not an Item, so `contentItem
  .children` misses it). A harness that must reach a JS-created popup should expose it as a
  `property var` (here `list.scopeMenu`) instead.
- **`Menu.addMenu(sub)` generates a C++-owned wrapper row that cannot be `destroy()`ed**
  (`Invalid attempt to destroy() an indestructible object`), and `takeItem()` hands that same row
  back. Do not build a menu to be cleared row by row: create the whole `Menu` with
  `Qt.createQmlObject` under a `property var`, and destroy that one JS-owned object on the next
  open — the wrapper rows die with it. Verified by opening the scope menu four times: `count`
  stayed 8 and the bold state followed `selectedFeedId`.
- `Menu.addItem()` can return a row that is `null` immediately afterwards (`itemAt(count - 1)` right
  after `addMenu`); never store those in an array for later removal.
- Popup menus are not in `contentItem.children` (they are `Item.resources`), and a `Menu` is not an
  Item, so it has no `mapToItem` — use `menu.contentItem.mapToItem(null, 0, 0)`.
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
  (use `viewRequested`); same for `port` → `portEdited`, and `property var prefs` forbids
  `signal prefsChanged` (SettingsSheet emits `subscribedChanged`/`prefsPatched` instead). The error
  only appears at runtime: `Duplicate signal name: invalid override of property change signal`.
- `font.family` takes **one** family name. A CSS-style list (`"Noto Serif, Georgia, serif"`) is
  passed through literally, resolves to nothing and silently renders the default sans face — that
  is why the old "Serif body text" checkbox looked dead.
- Mutating a `property var` object in place (`article.starred = 1`) never notifies bindings; publish
  a fresh copy (`Object.assign({}, article, {...})` style loop) so ReaderView repaints the star.
- `PlasmaComponents3.MenuItem` with `checkable: true` destroys its own `checked` binding on click;
  use `icon.name: selected ? "checkmark" : ""` for menu state instead.
- The `/tmp/qh/imports` stub tree needs one wrapper per used type; `ComboBox`, `Menu`, `MenuItem`
  and `MenuSeparator` were added for the 1.4.0 harnesses.
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
1. Ask the user to confirm in the live widget: the left-aligned scope menu with folder submenus and
   the scope icon changing per view, the `Text` button at the end of the reader toolbar with its
   five iconed groups, and the per-feed folder menu in *Settings → Feeds*. Popups cannot be
   exercised from the offscreen harness.
2. Discovery edge case: YouTube channel pages return 404 to non-JS clients; consider
   `youtube.com/channel/UC…` → `feeds/videos.xml?channel_id=`.
3. Optional: prefetch preview mark-read on scroll end (currently only on open).
4. Consider capping stored `content` HTML per item and pruning old rows (DB growth).
5. Live prefs hold `font_family: Cantarell`, `font_scale: 80`, `line_height: 140`. If the reader
   reads too small, that is a stored preference, not a rendering bug — change it from the reader
   menu.

## Chronological History

- 2026-11-12 socket default follow-ups (1.9.0): `activePort` starts at 0 in socket mode so the
  widget no longer fires a request at the unused 8770 before the endpoint line, `channelPort`
  separates the widget's HTTP channel from the configured port (Settings still edits the latter),
  and a daemon we may not stop (systemd unit / foreign) is now **adopted** (`BOOTSTRAP_ALREADY`)
  instead of being started next to on a second endpoint.
- 2026-11-12 socket is the default transport (1.9.0): `main.xml` default choice is now `socket`,
  and two bootstrap bugs surfaced with it — `${2:?}` rejected the widget's `--socket ''` (empty is
  the per-session default, so `${2?}`), and a plain start (no `--restart`) did not follow the
  published endpoint, so switching modes left the old daemon holding the `flock`. New
  `test-bootstrap.sh` section "widget default socket (empty --socket)" proves both: empty argument,
  old port daemon stopped, socket path used, exactly one daemon.
- 2026-11-12 startup blink fixed (`main.qml`): the pane blanked 2-3x on load because
  `loadItems(true)` cleared `items` before the payload and four separate triggers (initial load,
  endpoint report, retry poll, pollRefresh) each fired a full reload. Now: same-view reloads swap
  rows without clearing, `itemQuery()`/`shownQuery` distinguish navigation from refresh,
  `inflightQuery` collapses duplicate requests, `itemRequestId` drops stale answers after a view
  switch, `loadState` is single-flight, the retry poll stops on first success, and
  `onBackendPortChanged` reloads only while not `backendUp`. `qmllint` clean (import warnings only).
- 2026-11-12 no init system in the default path (same branch): `install.sh` installed and enabled
  a systemd unit even for a store-style install, so a systemd-less desktop had a broken documented
  path and a unit that outlived GUI removal. Default is now applet + icons only and the widget
  supervises its own daemon; `--systemd` is the opt-in that adds the unit plus a port handover.
  `simulate-install.sh` now proves the negative (no unit, no autostart, no daemon after install),
  then drives `bootstrap.sh` start/stop exactly like the widget does; `dev-reload.sh` falls back
  to `plasmashell --replace` and a log file when there is no systemd or journald.
- 2026-11-12 backend lifetime rework (1.9.0, branch `fix/backend-lifetime`): the 1.8.0 widget
  started a daemon *and* wrote an autostart entry, so `kpackagetool6 --remove` left a process
  answering on 8770 and `uninstall.sh` never stopped it. Replaced that model with the
  LSP-style client-supervised worker: widget spawns on load, `Component.onDestruction` stops it,
  and the daemon reaps itself after `KNEWS_IDLE_EXIT` (900 s) so orphaning is impossible even if
  the client dies; the systemd unit keeps `KNEWS_IDLE_EXIT=0` because there the OS owns the
  lifetime. Single instance is proven by `flock` in `$XDG_RUNTIME_DIR/knews-curator/` plus an
  `/api/health` identity check (`ok`/`version`/`pid`), not by a bound port. Added unix-socket
  transport (`--socket`, port 0, endpoint.json publishes both channels) after establishing that
  QML `XMLHttpRequest` cannot speak HTTP over `AF_UNIX`, so the widget always keeps a loopback
  port; *Settings → Backend* now exposes connection mode, port, socket path, restart and stop.
  `uninstall.sh` shuts a store-installed daemon down over its endpoint, removes the legacy
  autostart entry, pidfile and runtime dir. Two failures found on the way: `--socket ''` was
  rejected by `${2:?}`, and `ProtectSystem=strict` made `/run/user/1000` read-only for the unit —
  `bind` aborted startup with `[Errno 30]`, fixed with `ReadWritePaths=-%t/knews-curator` plus a
  cache-dir fallback in `config.runtime_dir()` and a ci-local assertion on both. 53 backend tests,
  `test-bootstrap.sh`, `ci-local.sh` and `simulate-install.sh` green; live host reinstalled and
  serving 1.9.0.
- 2026-11-12 release 1.8.0: self-contained package merged. Store `.plasmoid` (15 files, 60 KB)
  carries `contents/backend/knewsd.pyz` + `bootstrap.sh`; widget starts its own daemon through
  `plasma5support`, autostart entry keeps it alive across logins, `--stop` undoes it. Verified live
  with the systemd unit stopped+disabled (widget daemon served the real 30-feed DB) and again by
  installing the built package as a store user would. `install.sh` now hands the port back from a
  widget-managed daemon (pidfile) so its unit can bind the new version; `simulate-install.sh` probes
  health with `curl` instead of nested-quoted python and asserts the exact version string.
  CI caught what the local gate could not: `check-metadata.py` demanded `knewsd.pyz`, which is a
  gitignored build product, so both workflows failed in a fresh checkout. The zipapp is now checked
  only when present, `--require-backend` guards the post-build call, and ci-local runs it right
  after `./build.sh`; tag v1.8.0 was moved to the amended commit because nothing had been published.

- 2026-11-12 branch `feature/self-contained-package`: store install without any script. `build.sh`
  now emits a deterministic zipapp (`knewsd.pyz`) into the package, `contents/backend/bootstrap.sh`
  self-installs it (`~/.local/share/knews-curator/app/`, XDG autostart, health-first so it is
  idempotent, version-aware restart, `--stop`), and `BackendLauncher.qml` runs it via
  `plasma5support` `engine: "executable"`. Verified live on the host with the systemd unit
  stopped+disabled: the applet started its own daemon on 8770 against the real 30-feed DB, wrote
  the autostart entry, then the machine was restored to the systemd unit. Gate extended:
  `scripts/test-bootstrap.sh` (start/rerun/upgrade/stop), `verify-package.sh` and
  `check-metadata.py` assert the bundled backend, ci-local runs both. Zipapp had to be built by
  hand: `python3 -m zipapp` stores member mtimes, so the gate failed reproducibility until the
  archive was written with fixed timestamps and sorted entries.

- 2026-11-12 v1.7.0 (cont.): `scripts/simulate-install.sh` serves `dist/` on 127.0.0.1:8790 under
  the `/releases/download/<tag>/<asset>` shape and runs the README commands for real. It caught the
  gzip header mtime: `tar --mtime=@0` fixes member mtimes but `-czf` still stores the compression
  time, so the tarball hash changed between minute-apart builds; the pipeline is now
  `tar -cf - | gzip -9 -n` and `ci-local.sh` sleeps 2 s between the two builds so the check cannot
  pass by accident again. Fresh `git clone` of origin/main also passes the gate (no reliance on
  untracked files).

- 2026-11-12 v1.7.0 (cont.): CI failure was `X-Plasma-MainScript points at a missing file:
  ui/main.qml` — inline checks ran too far from the scripts they validated. Now every CI check is a
  script that `./scripts/ci-local.sh` also runs (plus reproducibility, plus a heredoc guard on the
  workflow files). Local gate caught two more real bugs immediately: zip entry order and tarball
  non-determinism.

- 2026-11-12 v1.7.0: packaging. KPackage archives are zips with `metadata.json` at the root and
  `kpackagetool6 --install file.plasmoid` unpacks them, so the store artifact and the CI check use
  the same shape. Version lives in two files (metadata + backend) and `build.sh` refuses to build
  when they diverge — that is the drift that bit v1.6.0/v1.6.1 (metadata said 1.6.0 while the
  shipped code was 1.6.1).

- 2026-11-12 v1.6.1: semantic menu icons (`icon` field on the THEMES/SPACING/MARGINS tables,
  `Typography.sizeIcon()`), list size row promoted to the top of the Reading card, chips follow
  `textScale`. Verified every icon name exists in Breeze at 22 px on the host; `zoom-in` /
  `view-sort-ascending` / `zoom-fit-best` were standing in for sizes, spacing and margins.

- 2026-11-12 v1.6.0: `list_scale` pref (config default + `PREF_DEFAULTS` gate), headline-size stepper
  in the Reading card, list spacing/line-height pass, wide two-pane layout removed. `dev-reload.sh`
  now finds `plasma-plasmashell.service` (Fedora 44) as well as `app-plasmashell@*`.
  Note: desktop widget geometry via `evaluateScript` is unreliable here — one resize landed
  (517 → 757 px) and later writes were ignored, so the widget size may need a manual drag.

- 2026-11-10 v1.5.1: reader header favicon; `ToggleBox` in the settings sheet draw `checkbox-symbolic`
  plus a `checkmark-symbolic` overlay so the state change is visible. Diagnosed with the daemon
  access log (POSTs present, value flipping) rather than pixels — full-frame screenshot diffs were
  useless here, the widget repaints ~2–7% of its pixels per second on its own.

- 2026-11-09 v1.5.0: eight UI fixes. Typography only in the reader; bulk-move (checkbox + drag +
  toolbar) replaced by a per-row folder `Menu`; scope menu left-aligned, iconified, folder
  submenus, scope-aware button icon; sidebar deleted (dead at 437 px); reader appearance button
  moved to the end of the toolbar as `Text`; menu groups iconified. Root-caused the live
  `removeItem` TypeError (`itemAt` returning null right after `addMenu`) and then the follow-up
  `destroy()` failure (wrapper rows are indestructible) → menu is rebuilt from scratch per open.
- 2026-11-12: v1.4.1 — bulk feed moves (`db.move_feeds`, `POST /api/feeds/move`, 400 on a bad id
  list, 404 on unknown ids) wired to checkboxes + a *Move* dropdown in *Settings → Feeds* and to a
  `DropArea` on each folder header; `ArticleList` scope title became the filter button
  (`TextBesideIcon`, no duplicate label); reader gained a `format-text` menu (Theme / Font / Size /
  Line spacing / Margins) built from the new shared `Typography.js`; `lineHeightPercent` now sets
  `Text.lineHeight` *and* scales block spacing.
- 2026-11-11: `POST /api/mark-unread` (`db.mark_unread`, scope: ids → feed → folder → all) plus an
  *Undo* button in the 9 s notice banner, so a mark-all sweep is reversible; the accidental
  LWN sweep was restored on the live DB (15 items → unread 159). Version 1.3.0.
- 2026-11-11: `main.qml` needed `import org.kde.plasma.components as PlasmaComponents3`; without it
  the whole applet failed to load (`PlasmaComponents3 is neither a type nor a namespace`).
- 2026-11-12: v1.4.0 — sidebar toggle visible-latch removed (`|| width > 46gu` pinned it open) and
  the header button now swaps icon/tooltip both ways; new header `view-list-details` menu selects
  smart view / folder / single feed (`sourceSelected(kind, value)` → `selectSmart|selectFolder|selectFeed`);
  mark-all is a `ConfirmSheet` dialog (new component) instead of a 5 s double click; star toggle
  republishes `article`; Settings *Reading* → *Content* with five ComboBoxes (theme, font incl.
  sans/serif, size 80–160 %, spacing, margins) driving `font_family`, `serif`, `font_scale`,
  `line_height`, `reader_padding`; `ReaderView.paddingPercent` scales the side margin
  (harness: pad 60/100/140/180 → side 86/144/202/259 px, column 727/612/497/382 at 900 px wide).
  Harness: 5 combos with correct labels, font list filtered to 8 installed choices, checkbox toggles
  emit `prefChanged`. 44 backend tests green.
- 2026-11-11: settings v2 — inline `component Section` cards, card sized
  `min(window-2*gu, 34gu)` x `min(window-2*gu, 42gu)` with equal edge margins, ScrollView
  `contentWidth: availableWidth` (old `width: sheet.width - 2*gu` overflowed the card),
  feeds grouped by folder with edit/pause/delete/`+`, backend moved to the bottom.
  Backend: `fetch.change_url` (probe → duplicate guard → retarget, clears ETag, refresh),
  `db.update_feed` accepts `url` and maps `IntegrityError` to `ValueError`,
  `/api/feeds/update` now 404s unknown ids and 400s on bad/duplicate URLs.
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
- 2026-11-11: QML `feeds` property already generates `feedsChanged`; a custom signal with that name
  is a duplicate → the settings sheet emits `subscriptionsChanged`.
- 2026-11-11: offscreen models can't view screenshots, so layout is verified numerically
  (`grabToImage` + `section.width/x/height`), e.g. card 394x364 at (18,18) in a 430x400 window.
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
