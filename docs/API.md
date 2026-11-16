# HTTP API

The daemon serves JSON on loopback, or on a unix socket in the default transport. Two clients
exist: the applet (`XMLHttpRequest` over loopback) and command line tools.

## Access rules

| Rule | Detail |
|---|---|
| Bind address | loopback only, or the unix socket at mode 0600 |
| State-changing POST | requires the header `X-Knews-Client: plasma` |
| Cross-origin | a request with an `Origin` header is rejected |
| Host | a non-loopback `Host` header is rejected. A unix-socket peer may omit `Host` |
| Encoding | request and response bodies are JSON, `Content-Type: application/json` |

Discovery of the endpoint, in order: `--socket PATH` / `--port N` arguments, then `KNEWS_SOCKET`,
then the published endpoint file:

```bash
# where is the daemon and which transport does it use
cat "$XDG_RUNTIME_DIR/knews-curator/endpoint.json"
```

## Reading

```
GET  /api/health              {"ok": true, "version": "1.10.0", "pid": 1234, "transport": "socket",
                               "port": 39117, "socket": "/run/user/1000/...", "url": "...",
                               "idle_exit": 900, "started": 1794852065}
GET  /api/state               feeds, folders, counts, prefs, refresh, icons, export_dir, version
GET  /api/items?view=&feed=&folder=&q=&limit=&offset=
GET  /api/item?id=1&read=1    article detail with blocks
GET  /api/thumb?id=1          cached thumbnail bytes
GET  /api/refresh/status      background refresh progress
GET  /api/discover?url=       {ok, direct, candidates[{url, title, icon, entries, existing}]}
GET  /api/validate?url=       {ok, title, entries, empty, error, existing}
GET  /api/opml                OPML export
```

`view` accepts `unread`, `starred` or `all`. `q` searches titles and article text. `limit`
defaults to 60.

`/api/state` returns the icon repair job under `icons`: `{running, done, total, updated,
finished}`.

## Writing

```
POST /api/feeds               {"url": "https://lwn.net/headlines/rss", "folder": "Tech"}
POST /api/feeds/bulk          {"urls": [...], "folder": ""} → {ok, added, results, state}
POST /api/feeds/delete        {"id": 1}
POST /api/feeds/update        {"id": 1, "title": "...", "folder": "...", "enabled": 1}
POST /api/feeds/move          {"ids": [1, 2], "folder": "Tech"} → {ok, moved, folder, state}
                              (API only; the applet moves one feed at a time)
POST /api/validate            {"urls": [...]} → {results: [{ok, title, entries, error, existing}]}
POST /api/item                {"id": 1, "read": 1} or {"id": 1, "starred": 1}
POST /api/mark-all            {} or {"feed": 1} or {"folder": "Tech"}
POST /api/mark-unread         {} or {"feed": 1} or {"folder": "Tech"} or {"ids": [1, 2]}
POST /api/refresh             {} or {"feed": 1}
POST /api/prefs               {"reader_theme": "sepia", "font_scale": 110, ...}
POST /api/opml                {"opml": "<opml>...</opml>"}
POST /api/opml/save           {"path": "/abs/or/~/file.opml"} → {ok, path, bytes, feeds, fallback}
POST /api/extract             {"id": 1}    force re-extraction
POST /api/icons/refresh       {}           re-discover every feed icon, progress in /api/state
POST /api/shutdown            {"ok": true, "stopping": true, "pid": 1234}
```

`POST /api/feeds/update` with a `url` re-probes the address first and rejects the change when
another subscription already points at it.

`/api/icons/refresh` answers immediately with `{started, status}`; the job runs in the background
and reports through `/api/state`. It never replaces a working icon with a guess: when a site
declares no icon, the stored one stays.

## Examples

```bash
EP="$XDG_RUNTIME_DIR/knews-curator/endpoint.json"
PORT=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['port'])" "$EP")

# health, over the published loopback channel
curl -sS "http://127.0.0.1:$PORT/api/health"

# add a feed
curl -sS -H "X-Knews-Client: plasma" -X POST "http://127.0.0.1:$PORT/api/feeds" \
     -d '{"url": "https://lwn.net/headlines/rss", "folder": "Tech"}'

# export OPML
curl -sS -H "X-Knews-Client: plasma" -X POST "http://127.0.0.1:$PORT/api/opml/save" \
     -d '{"path": "~/Downloads/news-curator.opml"}'

# talk to a socket-mode daemon without HTTP
python3 ~/.local/share/knews-curator/app/knewsd.pyz --probe \
    --socket "$XDG_RUNTIME_DIR/knews-curator/knewsd.sock"
python3 ~/.local/share/knews-curator/app/knewsd.pyz --shutdown \
    --socket "$XDG_RUNTIME_DIR/knews-curator/knewsd.sock"
```

## Errors

Validation problems answer `400` with `{"error": "..."}`. A missing feed or item answers `404`.
Unexpected failures answer `500` and keep the daemon running. Mutating routes answer `200` with
the new state so a client does not need a second round trip.
