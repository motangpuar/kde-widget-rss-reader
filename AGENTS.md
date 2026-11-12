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

# install widget to host (no init system: the widget supervises the backend)
./install.sh              # kpackagetool6 -i (host) + icons only
./install.sh --systemd    # opt-in: also install/enable the user unit
./uninstall.sh

# release artifacts (dist/: .plasmoid, tarball, SHA256SUMS)
./build.sh              # fails if metadata.json and backend VERSION disagree

# reload applet after QML edits
./dev-reload.sh

# full local CI gate (what the workflows run) — always run before pushing
./scripts/ci-local.sh
# replay the published release download + install (local HTTP mirror, real install)
./scripts/simulate-install.sh
# store-install path: bundled zipapp start / rerun / upgrade / stop
./scripts/test-bootstrap.sh
./scripts/ci-local.sh --skip-tests   # packaging only, used by the CI package job
```

CI logic must live in `scripts/`, never inline in a workflow `run:` block: heredocs there
cannot be tested locally and one already broke CI once. `scripts/ci-local.sh` enforces that.

Release flow: bump `KPlugin.Version` in
`plasmoid/io.github.infidel.newscurator/metadata.json` **and** `VERSION` in
`backend/knewsd/config.py`, commit, `git tag -a vX.Y.Z`,
`git push origin main --follow-tags`. `.github/workflows/release.yml` then builds and
attaches the artifacts; `.github/workflows/ci.yml` runs the tests and the packaging
check on every push/PR.

## Bundled backend (store install)
`build.sh` compiles `backend/knewsd/*.py` into a deterministic zipapp
(`contents/backend/knewsd.pyz`, gitignored) inside the package. `contents/backend/bootstrap.sh`
installs it to `~/.local/share/knews-curator/app/` and starts/restarts it;
`BackendLauncher.qml` runs that script through `org.kde.plasma.plasma5support`
(`engine: "executable"`) once per widget load, so a store package needs no installer.

## Backend lifetime model
The backend is a **client-supervised worker** (LSP model), not a system service. Exactly one
supervisor per deployment:

| Deployment | Supervisor | Lifetime |
|---|---|---|
| store package | the widget (`BackendLauncher.qml`) | spawned on widget load, stopped in `Component.onDestruction`, reaped by `KNEWS_IDLE_EXIT` (900 s default) |
| `install.sh --systemd` (opt-in) | `systemd --user` (`knewsd.service`) | unit owns it; `Environment=KNEWS_IDLE_EXIT=0` disables the reaper |

- **No autostart entry, no init system in the default path.** 1.8.x wrote
  `~/.config/autostart/knewsd.desktop`; that scoped the lifetime to the login session instead of
  to the client and left a daemon behind on uninstall. `bootstrap.sh` and `uninstall.sh` delete it
  on sight. Never reintroduce it. `install.sh` without `--systemd` installs **only** the applet and
  icons: no unit, no autostart, no process. The widget works on systems without systemd.
- **Orphan prevention is server-side**: the invariant "no process without a client" is enforced
  by the idle reaper inside `knewsd`, so a `plasmashell` crash or a `kpackagetool6 --remove`
  cannot leak a listener. Client cleanup is a convenience, not the guarantee.
- **Single instance** = `flock` on `$XDG_RUNTIME_DIR/knews-curator/knewsd.lock` **and** bind of
  the configured endpoint **and** an identity check over `/api/health` (`ok`, `version`, `pid`)
  before a client trusts a listener. A bound port alone proves nothing.
- **Transports**: HTTP over loopback (what QML uses — `XMLHttpRequest` cannot speak HTTP over
  `AF_UNIX`) or a unix socket (`--socket PATH`, port `0`). Socket mode publishes both channels in
  `$XDG_RUNTIME_DIR/knews-curator/endpoint.json` and prints `BOOTSTRAP_ENDPOINT <json>` for the
  widget. Never a TCP port on a non-loopback address.
- **Restart/stop are user-facing**: *Settings → Backend* and `bootstrap.sh --restart|--stop`;
  `install.sh` calls `--stop` before starting the unit to hand the port over.
- **systemd hardening gotcha**: `ProtectSystem=strict` makes `$XDG_RUNTIME_DIR` read-only, so the
  unit lists `ReadWritePaths=-%t/knews-curator`; `config.runtime_dir()` also falls back to the
  cache dir rather than aborting. `scripts/ci-local.sh` asserts both.
- `scripts/test-bootstrap.sh` covers: fresh start, idempotent rerun, upgrade restart, explicit
  restart, socket mode, socket stop, idle reaping of a client-less daemon, foreign daemon left
  alone, and a clean final stop. No autostart file may appear in any of them.

## Layout
```
backend/knewsd/{config,db,feeds,readability,fetch,api,__main__}.py
plasmoid/io.github.infidel.newscurator/contents/backend/{bootstrap.sh,knewsd.pyz}
backend/tests/
plasmoid/io.github.infidel.newscurator/  # KPackage root (metadata.json + contents/)
systemd/knewsd.service
icons/                                  # theme icons installed to hicolor
build.sh  install.sh  uninstall.sh  dev-reload.sh
.github/workflows/{ci,release}.yml
LICENSE
```

## Startup repaint contract (QML)
- **One request per view per refresh.** `loadItems` collapses duplicate triggers (initial load,
  endpoint report, retry poll, 60 s sync) with `inflightQuery`; the newest request owns
  `loadingItems`/`totalItems` via `itemRequestId`, so a stale answer for another view is dropped.
- **Never blank the pane for the same view.** Rows are only cleared when `itemQuery()` differs
  from `shownQuery` (real navigation); a reload swaps rows on arrival **without a model swap**.
  Clearing before the payload lands is what made the widget blink at every startup.
- **`/api/state` is single-flight** (`stateLoading`), stops `backendRetry` on success, and the
  retry poll exists only as a fallback for a slow backend.
- **`onBackendPortChanged` reloads only when the widget is not `backendUp`**: the endpoint line
  arrives right after the first successful sync, so reloading there repainted identical rows.

## Rules
- Backend must stay stdlib-only (host is an immutable OS; no pip installs).
- QML: Plasma 6 imports only (`org.kde.plasma.components` 3.0, `org.kde.kirigami`).
- Mutating API calls require header `X-Knews-Client: plasma` (CSRF guard, no CORS).
- Never write into host system dirs; data under `~/.local/share/knews-curator`, scratch under
  `$XDG_RUNTIME_DIR/knews-curator` (fallback `~/.cache/knews-curator/run`).
- Every file an installer creates must be removed by `uninstall.sh`; a GUI package removal is
  covered by the destruction handler + idle reaper, documented in the README.
