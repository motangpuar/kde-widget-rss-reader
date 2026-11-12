# News Curator — KDE Plasma 6 applet

Feed reader and news curator for the Plasma desktop: Inoreader-style feed management,
a built-in reader view (Instapaper / Firefox Reader flavour), and a local-only backend.

Everything runs on the machine. No accounts, no cloud, no telemetry.

## What you get

- **Plasma 6 applet** (`io.github.infidel.newscurator`) — three panes: feeds, article list, reader.
- **Local daemon** (`knewsd`) — stdlib-only Python, SQLite, JSON over `127.0.0.1:8770`.
- **Reader view** — server-side extraction into structured blocks (paragraphs with inline
  bold/italic/links, headings, lists, quotes, code, images) rendered by QML; not HTML in a
  WebView, so it stays fast, theme-consistent and offline-readable.
- **Offline images** — remote images are cached under `~/.cache/knews-curator/images` and
  served as `file://` URIs.
- **Feed discovery** — type a site address (`lwn.net`, `arstechnica.com`, a channel URL) and the
  applet searches the page for feeds, like Inoreader's follow box.
- **Source icons** — cached favicons in the scope menu, on the scope button when a single feed is
  selected, and next to the source name in the article list.
- **Formats** — RSS 2.0, RSS 1.0/RDF, Atom, JSON Feed; OPML import/export.
- **Bulk follow** — paste a list of addresses, validate them all in parallel, then follow only the
  ones that actually serve a feed.
- **Guarded adds** — the follow dialog validates a URL before offering *Follow*, so a typo or a
  dead feed never lands in your list.
- **Feed removal** — *Settings → Feeds*, trash icon on the row (second click confirms).
- **State** — unread counts, folders, stars, mark-all-read, background refresh with
  ETag/Last-Modified conditional requests.

## Requirements

- Plasma 6 (developed against 6.7), `kpackagetool6`
- `python3` >= 3.11 on the host (stdlib only — no pip, works on rpm-ostree)
- systemd user session (for the backend unit)

## Install

### From a release (recommended)

```bash
# full install: widget + backend + systemd unit   (see Releases for the current version)
curl -LO https://github.com/motangpuar/kde-widget-rss-reader/releases/latest/download/news-curator-1.7.0.tar.gz
tar -xzf news-curator-1.7.0.tar.gz && cd news-curator-1.7.0 && ./install.sh
```

The widget alone can also be installed without the daemon (it will then report *Backend
offline*, which is expected until the backend exists):

```bash
kpackagetool6 --type Plasma/Applet --install io.github.infidel.newscurator-1.7.0.plasmoid
```

That is exactly the file published to store.kde.org; the store build has no `install.sh` and
therefore no backend, so the tarball stays the supported path.

### From a git checkout

```bash
./install.sh          # backend + systemd unit + applet + icons
./build.sh            # dist/: .plasmoid for the store, tarball, SHA256SUMS
```

Then right-click the desktop or panel → **Add Widgets** → **News Curator**.

`install.sh` copies the backend to `~/.local/share/knews-curator/app`, installs
`~/.config/systemd/user/knewsd.service`, enables and starts it, installs the applet with
`kpackagetool6`, and verifies `http://127.0.0.1:8770/api/health`.

Inside a distrobox container the script re-executes itself through `distrobox-host-exec`,
because Plasma tooling lives in the host session.

Uninstall (keeps your feeds and read state):

```bash
./uninstall.sh          # add --purge to delete the database and image cache
```

## Using it

| Action | Where |
|---|---|
| Add feed | `+` in the header: type an address, **Find feeds**, pick a result, **Follow** |
| Feed folders | type a folder name in the follow dialog |
| Read an article | click a row — opens the built-in reader |
| Open in browser | `internet-services` icon, list row, or reader toolbar |
| Star | star icon on a row or in the reader toolbar |
| Browse by folder or source | the title button in the list header opens the scope menu, left-aligned under the button: smart views, one submenu per folder (folder itself + its feeds), then ungrouped feeds. Every entry has an icon and the button shows the current one |
| Move a feed into a folder | *Settings → Feeds* → folder icon on the row → pick a folder (or **No folder**) |
| Text appearance while reading | `Text` button at the end of the reader toolbar: theme, font, size, line spacing, margins — every row shows the icon that describes it |
| Text size in the list | *Settings → Reading* → first row: **Text size in the list**, zoom buttons, 80–160 % |
| Source of the article you are reading | the reader header shows the feed favicon next to the feed name |
| Mark all read | read icon in the header → confirmation dialog → **Mark read** |
| Undo mark-all | the notice banner keeps an *Undo* button for 9 seconds |
| Delete a feed | *Settings → Feeds* → trash icon on the row → click again to confirm |
| Manage feeds | gear icon → *Feeds*: grouped by folder, per-row edit / pause / delete |
| Settings | gear icon: reading behaviour, headline size, feed management (folder picker, edit, pause, delete), bulk add, OPML, backend status |
| Re-extract | refresh icon in the reader toolbar (re-fetches the original page) |

Reader themes: `auto` (follows Plasma colours), `light`, `sepia`, `dark`.

Typography lives in the reader only: the `Text` button at the end of the toolbar opens a menu of
five submenus (theme, font, size, line spacing, margins), each carrying its own icon and a
checkmark on the active value. There is no typography in the settings sheet, so the two can no
longer disagree. Every entry maps to a stored preference: theme (`reader_theme`), font
(`font_family` + `serif`), text size (`font_scale`, 80–160 %), line spacing (`line_height`) and
side margins (`reader_padding`, 60–180 %). The font list is filtered against `Qt.fontFamilies()`,
so a family that is not installed never appears; `Typography.js` holds the tables.

### Following a site

Click `+` in the header and type any of these:

| You type | What happens |
|---|---|
| `lwn.net` | page scan → `https://lwn.net/headlines/rss` |
| `https://arstechnica.com` | page scan → `https://arstechnica.com/feed/` |
| `https://…/rss.xml` | recognised directly, no scan |
| `example.substack.com` | page scan → `/feed` |

Every candidate shows its title, URL, feed count and favicon; feeds you already follow are marked
*Already followed*. Discovery takes a second or two per site; the result list is cached nowhere, so
run it again if you typed the wrong address.

Sites that build their feeds with JavaScript (some YouTube channel pages, Reddit user pages) are
rejected with "could not reach …" — paste the feed URL directly for those.

### Bringing feeds over from another reader

1. **Import a file** — gear icon → *Import OPML file…* → pick the `.opml`/`.xml` export from
   Feedly, Inoreader, FreshRSS, Newsboat, … Nested OPML folders become feed folders;
   `xmlUrl`/`xmlurl`, `title`/`text` are both accepted.
2. **Bulk add addresses** — gear icon → *Add several feeds* → paste one address per line →
   *Check addresses* → *Follow checked feeds* (folder optional). All addresses are probed in
   parallel; rows show the resolved title and item count, dead ones show the HTTP error, and
   feeds you already follow are marked so they are skipped.
3. **Import from disk over the API** (scripted, no copy-paste):

```bash
python3 - <<'EOF'
import json, urllib.request
opml = open("feeds.opml", encoding="utf-8").read()
req = urllib.request.Request(
    "http://127.0.0.1:8770/api/opml",
    data=json.dumps({"opml": opml}).encode(),
    headers={"X-Knews-Client": "plasma", "Content-Type": "application/json"})
res = json.load(urllib.request.urlopen(req))
print("imported", len([e for e in res["imported"] if "error" not in e]), "feeds")
for entry in res["imported"]:
    if "error" in entry:
        print("FAILED", entry["url"], entry["error"])
EOF
```

Feeds are fetched immediately; failures are reported per URL and can be retried from Settings.

### Managing subscriptions in Settings

The *Feeds* section groups every subscription under its folder (ungrouped feeds last) and gives
each row four actions:

| Action | Effect |
|---|---|
| pencil | inline editor for title, folder and address |
| pause / play | stop or resume background fetching (`enabled` in the DB) |
| trash (×2) | delete the feed and its items, second click confirms |
| folder `+` | open the follow dialog with that folder prefilled |

Changing the address is guarded: the new URL is fetched and parsed first, and it is rejected with
*that address is already followed* if another subscription already points at it, so a mistyped
address can never empty a working feed. A successful change clears the stored ETag and re-fetches
immediately.

### Taking feeds out

Gear icon → *Save OPML file…* writes a full OPML 2.0 export wherever the file dialog points
(`~/Downloads` by default). If the chosen folder is not writable by the systemd unit, the export
falls back to `~/.local/share/knews-curator/exports/` and the status line says so. Scripted export:

```bash
curl -sS -H "X-Knews-Client: plasma" -X POST http://127.0.0.1:8770/api/opml/save \
     -d '{"path": "~/Downloads/news-curator.opml"}'
# {"ok": true, "path": "...", "feeds": 10, "bytes": 1835, "fallback": false}
```

Single feeds: `+` in the header, or `POST /api/feeds {"url": "...", "folder": "Tech"}`.

```bash
# any site
https://lwn.net/headlines/rss
# Substack / Ghost / WordPress
https://example.substack.com/feed
# YouTube channel (channel_id from the channel page source)
https://www.youtube.com/feeds/videos.xml?channel_id=UCxxxxxxxxxxxxxxxxxxxxxx
# Reddit subreddit, GitHub releases
https://www.reddit.com/r/linux/.rss
https://github.com/kde/plasma-desktop/releases.atom
```

## Architecture

```
plasmoid/io.github.infidel.newscurator/   Plasma applet (QML only)
  contents/ui/main.qml                    PlasmoidItem, state + API orchestration
  contents/ui/ArticleList.qml             list, filters, search, infinite scroll
  contents/ui/ReaderView.qml              block renderer + in-reader typography menu
  contents/ui/AddFeedSheet.qml            add-feed overlay
  contents/ui/SettingsSheet.qml           preferences, feed management, OPML
  contents/ui/Api.js                      HTTP client, formatting helpers
  contents/ui/Typography.js               shared theme/font/size tables (reader + settings)
backend/knewsd/                           Python daemon (stdlib only)
  feeds.py                                RSS/Atom/JSON parsing, OPML
  readability.py                          DOM pruning + block extraction
  fetch.py                                conditional HTTP, image cache, refresh
  db.py                                   SQLite store (WAL)
  api.py                                  HTTP JSON API + background refresh
```

The plasmoid never parses HTML. The daemon converts articles into blocks:

```json
{"type": "paragraph", "runs": [{"text": "Hello ", "b": false, "i": false, "href": ""}]}
{"type": "heading", "level": 2, "text": "..."}
{"type": "list", "ordered": false, "items": [[run...], [run...]]}
{"type": "quote", "runs": [...]}
{"type": "code", "text": "..."}
{"type": "image", "src": "file:///...", "alt": "", "caption": ""}
{"type": "divider"}
```

QML renders those natively, so the reader inherits Plasma colours and fonts, respects
font scaling, and works with the network off once an article is extracted.

## API

Bind to loopback only. All state-changing POSTs must carry `X-Knews-Client: plasma`;
requests with an `Origin` header or a non-loopback `Host` are rejected.

```
GET  /api/health              {"ok": true, "version": "1.2.0"}
GET  /api/state               feeds, folders, counts, prefs
GET  /api/items?view=&feed=&folder=&q=&limit=&offset=
GET  /api/item?id=&read=1     article detail with blocks
GET  /api/thumb?id=           cached thumbnail bytes
GET  /api/discover?url=       feed discovery: {ok, direct, candidates[{url,title,icon,entries,existing}]}
GET  /api/validate?url=       strict single-URL probe: {ok, title, entries, empty, error, existing}
POST /api/validate            {"urls": [...]} → {"results": [{ok, title, entries, error, existing}]}
POST /api/feeds/bulk          {"urls": [...], "folder": ""} → {"ok", "added", "results", "state"}
POST /api/opml/save           {"path": "/abs/or/~/file.opml"} → {ok, path, bytes, feeds, fallback}
GET  /api/refresh/status      background refresh progress
GET  /api/opml                OPML export
POST /api/feeds               {"url": "...", "folder": "..."}
POST /api/feeds/delete        {"id": 1}
POST /api/feeds/update        {"id": 1, "title": "...", "folder": "...", "enabled": 1}
POST /api/feeds/move          {"ids": [1, 2], "folder": "Tech"} → {"ok", "moved", "folder", "state"}
                              (API-only: the applet moves one feed at a time via /api/feeds/update)
POST /api/feeds/update        {"id": 1, "url": "https://..."} — re-probes, then retargets
POST /api/item                {"id": 1, "read": 1} / {"id": 1, "starred": 1}
POST /api/mark-all            {} or {"feed": 1} or {"folder": "Tech"}
POST /api/mark-unread         {} / {"feed": 1} / {"folder": "Tech"} / {"ids": [1, 2]}
POST /api/refresh             {} or {"feed": 1}
POST /api/prefs               {"reader_theme": "sepia", ...}
POST /api/opml                {"opml": "<opml>...</opml>"}
POST /api/extract             {"id": 1} — force re-extraction
```

## Distribution

```
plasmoid/io.github.infidel.newscurator/   KPackage root: metadata.json + contents/
backend/knewsd/                           stdlib-only daemon
systemd/knewsd.service                    user unit (port templated by install.sh)
icons/                                    theme icons, installed to hicolor
build.sh                                  produces dist/ artifacts
scripts/ci-local.sh                       runs the whole CI gate locally
scripts/check-metadata.py                 metadata/version validation (CI + local + release)
scripts/verify-package.sh                 asserts the built artifacts are shippable
scripts/simulate-install.sh               plays back the release download + install flow
.github/workflows/ci.yml                  calls the same scripts on every push
.github/workflows/release.yml             publishes a GitHub release for every v* tag
```

All checks live in `scripts/`, and the workflows only call them — so `./scripts/ci-local.sh`
reproduces CI byte for byte (same metadata validation, same packaging assertions, same
reproducibility check) before anything is pushed. Workflow files are additionally linted for
inline shell heredocs, which are the one thing that cannot be tested locally.

`build.sh` reads the version from `metadata.json`, refuses to run when `backend/knewsd/config.py`
disagrees, and writes:

| Artifact | Contents |
|---|---|
| `io.github.infidel.newscurator-<v>.plasmoid` | zip whose root is `metadata.json` + `contents/` — KPackage and store.kde.org accept it as-is |
| `news-curator-<v>.tar.gz` | `news-curator-<v>/` with plasmoid, backend, unit, icons, installer |
| `SHA256SUMS` | checksums of both |

### Releasing

```bash
git tag -a v1.7.0 -m "News Curator 1.7.0"
git push origin main --follow-tags
```

The `Release` workflow runs the tests, fails when the tag and `metadata.json` version disagree,
builds the artifacts, and attaches them to a GitHub release. Upload the `.plasmoid` from that
release to store.kde.org (Plasma 6 → *Plasma Add-Ons* → *Applets*); the tarball is what users
download to get a working backend.

## Development

```bash
./scripts/ci-local.sh                                          # full local CI gate
./scripts/simulate-install.sh                                  # release download + install, for real
python3 -m unittest discover -s backend/tests -t backend -v   # 45 tests
/usr/lib/qt6/bin/qmllint -I /usr/lib64/qt6/qml plasmoid/io.github.infidel.newscurator/contents/ui/*.qml
./dev-reload.sh        # push plasmoid to host, restart plasmashell, print QML errors
```

`dev-reload.sh` restarts `plasmashell`, which is the only reliable way to reload applet QML
in Plasma 6.

`simulate-install.sh` builds the artifacts, serves them on `127.0.0.1:8790` under the same
`/releases/download/<tag>/<asset>` path GitHub uses, then runs the README commands for real:
`curl -LO`, `sha256sum -c`, `tar -xzf`, `./install.sh`, plus a widget-only install into a
scratch `XDG_DATA_HOME`. It ends by comparing the installed applet against the downloaded
tarball, so a broken release is caught before the tag is pushed.

Run the daemon by hand against a scratch database:

```bash
KNEWS_DB=/tmp/scratch.db python3 -m knewsd --port 8899
```

Set `KNEWS_ACCESS_LOG=1` to log every HTTP request to stderr (the systemd unit enables it).
`journalctl --user -u knewsd -f` is the first place to look when the applet says "Backend offline".

## Files

| Path | Purpose |
|---|---|
| `~/.local/share/knews-curator/app/knewsd` | installed daemon code |
| `~/.local/share/knews-curator/curator.db` | SQLite database (feeds, items, prefs) |
| `~/.cache/knews-curator/images` | image cache |
| `~/.config/systemd/user/knewsd.service` | user unit |
| `~/.local/share/plasma/plasmoids/io.github.infidel.newscurator` | installed applet |
| `dist/` | local build output (`build.sh`), not tracked |

## Notes and limits

- Extraction is heuristic. Paywalled or JS-only pages fall back to the feed's own summary
  content and the reader says so ("Partial extraction"); the browser button is always there.
- Mark-all-read asks for confirmation in a dialog, then keeps an *Undo* in the notice banner for
  9 seconds; the undo only restores what that action changed.
- The applet keeps the last 300 items per feed (`max_items_per_feed`).
- The systemd unit runs with `ProtectHome=read-only`; `~/Downloads`, `~/Documents` and
  `~/Desktop` are writable for OPML exports, anything else falls back to the app data folder.
- The port is not exposed in the applet UI (it is an install-time detail, default `8770`).
  To change it, edit `contents/config/main.xml`'s default or `Plasmoid.configuration.port`,
  then restart the unit:
  `systemctl --user restart knewsd`.

## License

MIT — see `LICENSE`.
