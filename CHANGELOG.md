# Changelog

All notable changes to this project. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the version numbers follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Releases before 1.10.0 are described on the
[releases page](https://github.com/motangpuar/kde-widget-rss-reader/releases).

## 1.10.0

### Added

- A supervisor timer that restarts the backend after a crash, an OOM kill or a session teardown,
  with 5 s to 60 s backoff and a 15 s health probe. Recovery no longer needs a widget reload.
- A status strip above the article list that reports a dead backend or a new release and offers
  **Restart backend**, **Update** and **Skip this version**.
- A daily release check with one desktop notification, plus a release dialog that shows the new
  version, the installed version, the release date and the release notes. The check is opt-out and
  never installs anything.
- *Settings → Updates*: check switch, **Check now**, **Details…** and **Reset** for a skipped
  version.
- `POST /api/icons/refresh` and *Settings → Backend → Refresh source icons*, with progress in
  `/api/state.icons`. The repair never replaces a working icon with a guess.
- Icon discovery that matches a browser: declared `<link rel="icon">`, `apple-touch-icon`,
  `mask-icon`, SVG, PNG and `.ico`, with `/favicon.ico` as the fallback. Icons served with the
  wrong content type are sniffed instead of dropped.
- `docs/ARCHITECTURE.md`, `docs/API.md` and `docs/DEVELOPMENT.md`, shipped in the tarball.
- This changelog, extracted into the GitHub release body by `scripts/release-notes.sh`.

### Changed

- The scope selector is a compact button with the chevron inline after the label. Unread, Starred
  and All items moved into its menu.
- Each header action carries its own icon again: search, mark all read, refresh, add feed,
  settings.
- The README is the user front page. Architecture, API and development material live under
  `docs/`.
- `install.sh --systemd` reached the host installer with its flags intact; before this release the
  distrobox hop discarded them.
- The launcher restarts the backend in the transport it is attached to, so a systemd unit restart
  cannot spawn a second daemon.

### Fixed

- The idle exit measured wall-clock time, so a suspended machine looked idle and the daemon
  exited under a visible widget. It now measures `CLOCK_MONOTONIC`.
- The background refresher treated a wall-clock jump as elapsed time and refreshed every feed at
  once after resume. Clock jumps now fold into a skew.
- The single-instance lock lived in the session runtime directory. When a session teardown deleted
  that directory, a second daemon could start on the same database.
- A daemon whose runtime directory disappeared kept running unreachable; it now exits on the next
  watchdog tick.
- A daemon that was alive, held the lock and answered nothing blocked every replacement. The
  bootstrap now resolves its pid, terminates it and starts one replacement.
- `KNEWS_ACCESS_LOG=1` made every unix-socket request fail with an `IndexError` inside
  `address_string`, so a live daemon answered nothing.
- A hung loopback request kept the list spinner running forever. Requests now report an error or a
  timeout exactly once, with a 15 s timeout.
- Article rows lost their hover state over the star and the browser icon, and titles ran under the
  scroll bar.

### Removed

- The smart-view tab row. Unread, Starred and All live in the scope menu.
- The header overflow menu. Every action is one icon in the bar.
