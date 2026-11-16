# Architecture

Two processes: the Plasma applet (`contents/ui/*.qml`) and one backend daemon (`knewsd`). The
applet draws and supervises. The daemon holds the database, the network and extraction.

## Components

```
plasmoid/io.github.infidel.newscurator/   KPackage root
  contents/ui/main.qml                    state, API calls, supervisor, update check
  contents/ui/ArticleList.qml             header, status strip, list, scope menu
  contents/ui/ReaderView.qml              block renderer and typography menu
  contents/ui/SettingsSheet.qml           reading, feeds, OPML, backend, updates
  contents/ui/UpdateDialog.qml            release details
  contents/ui/BackendLauncher.qml         runs bootstrap.sh, reports endpoint and transport
  contents/ui/Api.js                      HTTP client and formatting helpers
  contents/backend/bootstrap.sh           start, stop, restart, adopt, replace
  contents/backend/knewsd.pyz             bundled backend (built by build.sh)
backend/knewsd/                           source of the daemon, standard library only
  feeds.py                                RSS, Atom, JSON Feed parsing, OPML
  readability.py                          DOM pruning and block extraction
  fetch.py                                conditional HTTP, image cache, icon discovery
  db.py                                   SQLite store, WAL
  api.py                                  HTTP JSON API, refresh manager, icon repair, reaper
  config.py                               paths, defaults, constants
  __main__.py                             argument parsing, single instance, serve
```

## Lifetime

The backend is a worker process, not a system service. One supervisor exists per deployment:

| Deployment | Supervisor | Lifetime |
|---|---|---|
| Store package, tarball install | the widget (`BackendLauncher.qml` plus the supervisor timer) | starts on load, restarts with backoff while offline, stops on destruction, exits after 900 s without a request |
| `install.sh --systemd` | `systemd --user` | the unit controls the process, `KNEWS_IDLE_EXIT=0` disables the idle exit |

Rules that follow from that model:

- No autostart entry. Version 1.8.x wrote `~/.config/autostart/knewsd.desktop`; both the bootstrap
  and the uninstaller delete it on sight.
- The default install writes no unit and starts no process. `install.sh` without flags touches
  only the applet and the icons.
- The invariant "no process without a client" belongs to the server. The idle watchdog enforces
  it, so a `plasmashell` crash or a package removal cannot leak a listener.
- Idle time is measured on `CLOCK_MONOTONIC`. `CLOCK_REALTIME` advances during suspend and jumps
  on NTP steps, which would reap a daemon whose widget is on screen.
- A daemon whose `endpoint.json` disappeared or names another pid exits on the next watchdog tick.
  Removal of `$XDG_RUNTIME_DIR` leaves nothing behind.

## Single instance

Three checks, in order:

1. `flock` on `~/.local/share/knews-curator/knewsd.lock`. The lock lives in the data directory,
   not in the per-session runtime directory, because a session teardown deletes the runtime
   directory and a lock on a deleted inode no longer excludes a second process.
2. Bind of the configured endpoint: unix socket path or loopback port.
3. Identity check over `/api/health` (`ok`, `version`, `pid`) before any client trusts a listener.

A bound port proves nothing on its own. A daemon that holds the lock and answers nothing is
treated as wedged: the bootstrap reads the pid from the lock file, verifies
`/proc/<pid>/cmdline` contains the installed zipapp, sends `TERM`, then `KILL` after 5 seconds,
and starts one replacement.

## Transports

| Mode | Listener | Client |
|---|---|---|
| `socket` (default) | `$XDG_RUNTIME_DIR/knews-curator/knewsd.sock`, plus an ephemeral loopback port | widget uses the loopback port from `endpoint.json`; tools use the socket |
| `port` | loopback port, default 8770 | both |

QML has no HTTP-over-`AF_UNIX` transport, so socket mode always keeps a loopback channel. The
daemon publishes both channels in `endpoint.json` and prints `BOOTSTRAP_ENDPOINT <json>` on
stdout. Never a TCP port on a non-loopback address.

Changing endpoint or transport is supported: `bootstrap.sh --restart` and `--stop` resolve the
published endpoint first, so the daemon that actually runs is the one that stops. A plain start
does the same when nothing answers on the requested endpoint. When the daemon on the published
endpoint is not ours (systemd unit, foreign listener) the bootstrap adopts it
(`BOOTSTRAP_ALREADY`) instead of starting a second one.

## Threads

| Thread | Job | Shutdown |
|---|---|---|
| main | argument parsing, `serve_forever` per listener | sets the stop event on `SIGTERM`/`SIGINT` |
| HTTP request threads | one per request, `ThreadingHTTPServer` | joined by `server.shutdown()` |
| `RefreshManager` | serialises feed refreshes, exposes progress | joined with a timeout |
| `AutoRefresher` | background refresh every `refresh_minutes` | wakes on the stop event |
| `IdleWatchdog` | idle exit, endpoint-loss exit | same event |

One SQLite connection with an `RLock` guards the store today. Moving to a connection per thread is
the open data-plane item in issue #5.

`AutoRefresher` compares wall clock with monotonic clock and folds the difference into a skew, so
a suspend or a clock step cannot make every feed look overdue and fire a refresh burst.

## Storage

SQLite in WAL mode at `~/.local/share/knews-curator/curator.db`. Tables: `feeds`, `items`,
`prefs`. Schema additions run through `Store._migrate()`.

Article images and feed icons live in `~/.cache/knews-curator/images`, addressed by a SHA-1 of the
source URL, served to QML as `file://` URIs.

## Article model

The daemon converts HTML into blocks, and the applet renders those blocks:

```json
{"type": "paragraph", "runs": [{"text": "Hello ", "b": false, "i": false, "href": ""}]}
{"type": "heading", "level": 2, "text": "..."}
{"type": "list", "ordered": false, "items": [[run], [run]]}
{"type": "quote", "runs": [run]}
{"type": "code", "text": "..."}
{"type": "image", "src": "file:///...", "alt": "", "caption": ""}
{"type": "divider"}
```

QML renders the blocks, so the reader inherits Plasma colours, fonts and scaling, and works with
the network off once an article is extracted. The applet never parses HTML.

## Security model

- Loopback and unix socket only.
- State-changing POSTs require `X-Knews-Client: plasma`. Requests with an `Origin` header or a
  non-loopback `Host` are rejected.
- The unix socket is created with mode 0600.
- The systemd unit runs with `NoNewPrivileges`, `PrivateTmp`, `ProtectSystem=strict`,
  `ProtectHome=read-only` and an explicit `ReadWritePaths` list.
- The backend holds no credentials. Feeds are fetched over plain HTTPS with a browser user agent.

## Failure modes and the expected outcome

| Failure | Outcome |
|---|---|
| widget crashes | daemon reaps itself after 900 s |
| daemon crashes, OOM kill | supervisor restarts it within 20 s, with backoff |
| session teardown removes `$XDG_RUNTIME_DIR` | daemon exits on the next watchdog tick; the next start publishes a fresh endpoint |
| suspend for hours | daemon survives; no replay of idle time, no refresh burst |
| `kill -9` during a refresh | WAL replays on the next open; `PRAGMA integrity_check` reports `ok` |
| two starts at once | second process exits with "already running" |
| wedged daemon (alive, silent) | bootstrap replaces it once |
| endpoint or transport changed in Settings | old daemon stops before the new one starts |
