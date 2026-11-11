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
- **Source icons** — cached favicons next to each feed in the sidebar and next to the source name
  in the article list.
- **Formats** — RSS 2.0, RSS 1.0/RDF, Atom, JSON Feed; OPML import (file picker or paste) / export.
- **State** — unread counts, folders, stars, mark-all-read, background refresh with
  ETag/Last-Modified conditional requests.

## Requirements

- Plasma 6 (developed against 6.7), `kpackagetool6`
- `python3` >= 3.11 on the host (stdlib only — no pip, works on rpm-ostree)
- systemd user session (for the backend unit)

## Install

```bash
./install.sh          # backend + systemd unit + applet + icons
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
| Mark all read | double-click the read icon (5 s confirmation window) |
| Settings | gear icon: theme, text size, serif, refresh interval, port, feed removal, OPML |
| Re-extract | refresh icon in the reader toolbar (re-fetches the original page) |

Reader themes: `auto` (follows Plasma colours), `light`, `sepia`, `dark`.

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
2. **Paste** — gear icon → paste into the text box → *Import pasted OPML* (fallback for exports
   that live on another machine).
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
  contents/ui/FeedSidebar.qml             feed/folder tree with unread counts
  contents/ui/ArticleList.qml             list, filters, search, infinite scroll
  contents/ui/ReaderView.qml              block renderer + typography controls
  contents/ui/AddFeedSheet.qml            add-feed overlay
  contents/ui/SettingsSheet.qml           preferences, feed management, OPML
  contents/ui/Api.js                      HTTP client, formatting helpers
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
GET  /api/health              {"ok": true, "version": "1.0.0"}
GET  /api/state               feeds, folders, counts, prefs
GET  /api/items?view=&feed=&folder=&q=&limit=&offset=
GET  /api/item?id=&read=1     article detail with blocks
GET  /api/thumb?id=           cached thumbnail bytes
GET  /api/discover?url=       feed discovery: {ok, direct, candidates[{url,title,icon,entries,existing}]}
GET  /api/refresh/status      background refresh progress
GET  /api/opml                OPML export
POST /api/feeds               {"url": "...", "folder": "..."}
POST /api/feeds/delete        {"id": 1}
POST /api/feeds/update        {"id": 1, "folder": "...", "enabled": 1}
POST /api/item                {"id": 1, "read": 1} / {"id": 1, "starred": 1}
POST /api/mark-all            {} or {"feed": 1} or {"folder": "Tech"}
POST /api/refresh             {} or {"feed": 1}
POST /api/prefs               {"reader_theme": "sepia", ...}
POST /api/opml                {"opml": "<opml>...</opml>"}
POST /api/extract             {"id": 1} — force re-extraction
```

## Development

```bash
python3 -m unittest discover -s backend/tests -t backend -v   # 32 tests
/usr/lib/qt6/bin/qmllint -I /usr/lib64/qt6/qml plasmoid/io.github.infidel.newscurator/contents/ui/*.qml
./dev-reload.sh        # push plasmoid to host, restart plasmashell, print QML errors
```

`dev-reload.sh` restarts `plasmashell`, which is the only reliable way to reload applet QML
in Plasma 6.

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

## Notes and limits

- Extraction is heuristic. Paywalled or JS-only pages fall back to the feed's own summary
  content and the reader says so ("Partial extraction"); the browser button is always there.
- Mark-all-read has no bulk undo — it asks for a second click within 5 seconds.
- The applet keeps the last 300 items per feed (`max_items_per_feed`).
- Port changes in Settings take effect after restarting the unit:
  `systemctl --user restart knewsd`.

## License

MIT.
