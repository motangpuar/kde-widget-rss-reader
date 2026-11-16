# News Curator

Feed reader for the KDE Plasma 6 desktop. It keeps subscriptions, articles, read state and
cached images on the local machine. No account, no cloud, no telemetry.

[![KDE Store](https://img.shields.io/badge/KDE%20Store-install-1f6feb?logo=kde&logoColor=white)](https://www.opendesktop.org/p/2381657/)
[![release](https://img.shields.io/github/v/release/motangpuar/kde-widget-rss-reader?label=release&color=blue)](https://github.com/motangpuar/kde-widget-rss-reader/releases/latest)
[![downloads](https://img.shields.io/github/downloads/motangpuar/kde-widget-rss-reader/total?label=downloads&logo=kde&logoColor=white&color=1f6feb)](https://github.com/motangpuar/kde-widget-rss-reader/releases)
[![CI](https://img.shields.io/github/actions/workflow/status/motangpuar/kde-widget-rss-reader/ci.yml?label=CI)](https://github.com/motangpuar/kde-widget-rss-reader/actions/workflows/ci.yml)
[![license](https://img.shields.io/github/license/motangpuar/kde-widget-rss-reader?label=license&color=blue)](LICENSE)

Plasmoid ID: `io.github.infidel.newscurator`

## Features

- Scope menu with folders, single feeds and the smart views Unread, Starred and All.
- Article list with unread counts, stars, source icons and infinite scroll.
- Reader view that renders extracted blocks (paragraphs, headings, lists, quotes, code, images)
  with QML instead of a WebView, so it follows Plasma colours, fonts and scaling.
- Feed discovery: type `lwn.net` or `blog.example.org` and pick from the feeds the page declares.
- RSS 2.0, RSS 1.0/RDF, Atom and JSON Feed. OPML import and export.
- Offline image cache under `~/.cache/knews-curator/images`.
- Local backend over a unix socket by default, a loopback port on request.
- Daily update check with a release dialog. The widget links to the release page and never
  installs anything itself.

## Requirements

| Item | Detail |
|---|---|
| Desktop | Plasma 6 (developed against 6.7) |
| Python | `python3` 3.11 or newer on the host, standard library only |
| Init system | none needed; systemd is optional and opt-in |
| Build tools | none for the release tarball; `kpackagetool6` for a manual install |

## Install

### From the KDE store

Search for *News Curator* under **Plasma Add-Ons → Applets**, or install the `.plasmoid` from the
latest release. The package carries the backend, so the widget starts it on first load.

### From a release tarball

```bash
# download news-curator-<version>.tar.gz from
# https://github.com/motangpuar/kde-widget-rss-reader/releases/latest
tar -xzf news-curator-*.tar.gz && cd news-curator-*/
./install.sh
```

`./install.sh` installs the applet and the icons. It writes no unit, no autostart entry and starts
no process: the widget runs the backend it ships.

Add `--systemd` only when the backend should keep refreshing while no widget is loaded. That path
installs `knewsd.service` in the user manager, and `./uninstall.sh` removes it again.

### From a git checkout

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## First run

1. Right-click the panel or desktop, choose **Add Widgets**, then **News Curator**.
2. Press `+` in the widget header and type a site address. **Find feeds** lists what the page
   declares, **Follow** subscribes to one entry.
3. Optional: import an OPML file from *Settings → Feeds*.

The first refresh starts immediately. Articles appear as each feed answers.

## Using it

| Action | Where |
|---|---|
| Change the scope | the scope button in the header: icon, name, chevron. The menu holds Unread, Starred, All items, then folder submenus, then ungrouped feeds |
| Add a feed | `+` in the header |
| Read an article | click a row; the reader replaces the list |
| Open in browser | `internet-services` on a row, or the reader toolbar |
| Star | star icon on a row or in the reader toolbar |
| Mark everything read | `mail-mark-read` in the header, then confirm. The notice banner keeps an Undo for 9 seconds |
| Refresh now | `view-refresh` in the header |
| Search | `edit-find` in the header toggles the search field. `Enter` closes it |
| Text appearance in the reader | `Text` button at the end of the reader toolbar |
| List text size | *Settings → Reading*, first row |
| Backend status or a new release | the strip above the list, visible only when it has something to report |

## Settings

| Card | Contents |
|---|---|
| Reading | list text size, reader theme, font, size, line height, measure, padding |
| Backend | connection mode (unix socket or loopback port), socket path or port, **Restart backend**, **Stop backend**, **Refresh source icons** |
| Feeds | grouped subscription list, inline edit, pause, delete, folder move, OPML export and import |
| Updates | daily check switch, **Check now**, **Details…** when a release exists, **Reset** for a skipped version |

## Backend and recovery

The widget supervises one backend process per user. It starts on widget load, stops on widget
destruction, and restarts on its own after a crash, an OOM kill or a session teardown, with a
5 second to 60 second backoff. The daemon also exits by itself after 15 minutes without a request,
which covers a client that disappeared. A strip above the list reports the state and offers
**Restart backend** as a shortcut.

The transport is a unix socket at `$XDG_RUNTIME_DIR/knews-curator/knewsd.sock`. QML has no unix
socket support, so the daemon also publishes a loopback port in
`$XDG_RUNTIME_DIR/knews-curator/endpoint.json` for the widget itself. Port mode replaces the
socket with a fixed loopback port.

Design, invariants and failure modes: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Troubleshooting

| Symptom | Check |
|---|---|
| The strip shows *Backend stopped responding* | the supervisor restarts it within 20 seconds. For a manual restart use *Settings → Backend → Restart backend* |
| Strip stays after a restart | `journalctl --user -b \| grep newscurator` for bootstrap lines, then `~/.cache/knews-curator/knewsd.log` |
| A feed shows no icon | some sites declare none and return 404 for `/favicon.ico`; the browser shows a generic icon there too. *Refresh source icons* retries the whole list |
| Wrong icon after a site redesign | *Settings → Backend → Refresh source icons* |
| No update notice | the check runs once a day and is opt-out. *Settings → Updates → Check now* forces one |
| OPML export fails | with the systemd unit only `~/Downloads`, `~/Documents` and `~/Desktop` are writable; other paths fall back to `~/.local/share/knews-curator/exports/` |

## Files

| Path | Purpose |
|---|---|
| `~/.local/share/plasma/plasmoids/io.github.infidel.newscurator` | installed applet |
| `~/.local/share/knews-curator/curator.db` | SQLite database: feeds, items, preferences |
| `~/.local/share/knews-curator/app/` | installed backend code |
| `~/.local/share/knews-curator/knewsd.lock` | single-instance lock |
| `~/.cache/knews-curator/images` | image cache |
| `~/.cache/knews-curator/knewsd.log` | backend output |
| `$XDG_RUNTIME_DIR/knews-curator/` | socket, `endpoint.json`, session scratch |
| `~/.config/systemd/user/knewsd.service` | user unit, only with `install.sh --systemd` |

## Uninstall

```bash
./uninstall.sh          # applet, icons, backend copy, unit, runtime files
./uninstall.sh --purge  # also delete the database and the image cache
```

Removing the applet from the GUI deletes the package only. The widget stops its backend on
destruction, and the idle exit covers the rest.

## Limits

- Article extraction is heuristic. Paywalled or JavaScript-only pages fall back to the summary in
  the feed, and the reader labels that case.
- The database keeps the newest 300 items per feed.
- Feed discovery reads the page the address points at. Feeds announced only in client-side
  JavaScript stay invisible.
- The update check sends one request per day to `api.github.com`. Unauthenticated GitHub allows
  60 requests per hour per IP, so a shared address can hit the limit; the check then waits for the
  next day.
- An icon that the site does not publish cannot be reconstructed.

## Documentation

| Document | Audience |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | how the backend lives, talks and fails |
| [docs/API.md](docs/API.md) | HTTP API reference |
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | build, test, CI, release |

## License

MIT. See [LICENSE](LICENSE).
