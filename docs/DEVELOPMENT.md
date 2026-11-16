# Development

Audience: anyone building, testing or releasing the applet. Users start at [../README.md](../README.md).

## Prerequisites

| Tool | Purpose |
|---|---|
| Plasma 6 | running the applet; `kpackagetool6` for install and upgrade |
| Python | `python3` 3.11 or newer, standard library only |
| Qt QML tools | `qmllint` (container: `/usr/lib/qt6/bin/qmllint`, host: `/usr/lib64/qt6/bin/`) |
| Bash | every script targets bash 5 |
| git | release tags drive the release workflow |

The backend has no third-party dependencies and must keep none: the host is an immutable system
(rpm-ostree), so a pip install is not available there.

## Layout

```
plasmoid/io.github.infidel.newscurator/   KPackage root: metadata.json + contents/
backend/knewsd/                           daemon source, standard library only
backend/tests/                            unittest suite
systemd/knewsd.service                    optional user unit
icons/                                    theme icons, installed into hicolor
docs/                                     architecture, API, this document
build.sh                                  builds dist/ artifacts
install.sh  uninstall.sh  dev-reload.sh   install paths and the dev loop
scripts/                                  every CI check, callable locally
.github/workflows/                        ci.yml and release.yml, thin wrappers only
```

## Build

```bash
./build.sh
```

`build.sh` reads the version from `metadata.json`, exits non-zero when
`backend/knewsd/config.py` holds a different version, and writes:

| Artifact | Contents |
|---|---|
| `io.github.infidel.newscurator-<v>.plasmoid` | zip whose root is `metadata.json` and `contents/`; KPackage and store.kde.org accept it as-is |
| `news-curator-<v>.tar.gz` | `news-curator-<v>/` with applet, backend, unit, icons, installer |
| `SHA256SUMS` | checksums of both |

The build is reproducible: fixed timestamps in the zip, `gzip -9 -n` for the tarball, so two runs
produce identical bytes.

## Test

```bash
./scripts/ci-local.sh                                        # the full gate, same as CI
python3 -m unittest discover -s backend/tests -t backend -v  # backend only
./scripts/test-bootstrap.sh                                  # start, stop, adopt, wedge, wipe
./scripts/simulate-install.sh                                # release download and install, for real
qmllint plasmoid/io.github.infidel.newscurator/contents/ui/*.qml
./dev-reload.sh                                              # push to the host, restart plasmashell
```

`dev-reload.sh` restarts `plasmashell`, the only reliable way to reload applet QML in Plasma 6. It
prints QML errors from the journal. On systems without systemd it replaces the process instead of
restarting a unit.

`simulate-install.sh` builds the artifacts, serves them on `127.0.0.1:8790` under the same
`/releases/download/<tag>/<asset>` path that GitHub uses, then runs the documented commands:
`curl`, `sha256sum -c`, `tar -xzf`, `./install.sh`, plus a widget-only install into a scratch
`XDG_DATA_HOME`. It compares the installed applet against the downloaded tarball, so a broken
release fails before a tag exists. It installs the applet on the real host by design and restores
a running backend at the end.

`test-bootstrap.sh` runs in a throwaway `HOME` and covers: fresh start, repeat run, upgrade,
explicit restart, endpoint change, empty socket path, runtime-directory wipe, wedged daemon, idle
exit, foreign daemon adoption, stop.

### What CI enforces

| Gate | Script |
|---|---|
| Metadata and version agreement | `scripts/check-metadata.py` |
| Backend unit tests (60) | `python3 -m unittest` |
| Backend lifetime scenarios | `scripts/test-bootstrap.sh` |
| Duplicate QML root handlers | inline scan in `ci-local.sh` (qmllint cannot see these) |
| Default transport is the socket, empty `--socket` accepted | `ci-local.sh` |
| systemd unit sanity | `ci-local.sh` |
| Installer re-execs before parsing arguments | `ci-local.sh` |
| Package contents and checksums | `scripts/verify-package.sh` |
| Reproducible build | `ci-local.sh` (two builds, byte compare) |
| Workflows contain no inline shell | `ci-local.sh` |

Every check lives in `scripts/`. The workflows only call them, so `./scripts/ci-local.sh`
reproduces CI on the local machine.

## Conventions

- The backend stays standard library only.
- QML imports Plasma 6 modules: `org.kde.plasma.components` 3.0, `org.kde.kirigami`.
- State-changing API calls require the header `X-Knews-Client: plasma`. No CORS.
- Data lives under `~/.local/share/knews-curator`; scratch under `$XDG_RUNTIME_DIR/knews-curator`,
  with the cache directory as fallback.
- Any file an installer creates must be removed by `uninstall.sh`.
- Icons must exist in Breeze at 22 px. Check before adding a name.
- Menus are left aligned, every row carries an icon, folders are submenus.
- One request per view per refresh; never clear the list for a same-view reload. The contract is
  written down in `AGENTS.md`.
- Duplicate `onFoo` handlers on one object do not compile and `qmllint` does not report them; the
  CI gate scans for that class of error.

## Release

```bash
# 1. bump both version homes
#    plasmoid/io.github.infidel.newscurator/metadata.json -> KPlugin.Version
#    backend/knewsd/config.py                            -> VERSION
./scripts/ci-local.sh
git commit -am "Ship X.Y.Z"
git tag -a vX.Y.Z -m "News Curator X.Y.Z"
git push origin main --follow-tags
```

`.github/workflows/release.yml` runs the tests, fails when the tag and the `metadata.json` version
differ, builds the artifacts, and attaches them to a GitHub release. Upload the `.plasmoid` from that release to
store.kde.org under **Plasma Add-ons → Plasma Add-ons → Applets**; the tarball is what users
download to get a working backend.

## Debugging

```bash
# run a daemon by hand against a scratch database
KNEWS_DB=/tmp/scratch.db python3 -m knewsd --port 8899

# with request logging
KNEWS_DB=/tmp/scratch.db KNEWS_ACCESS_LOG=1 python3 -m knewsd --socket /tmp/kn.sock
python3 -m knewsd --probe --socket /tmp/kn.sock
```

Location of the evidence:

| Question | Where |
|---|---|
| Did the widget start the backend? | `journalctl --user -b \| grep newscurator` |
| Which endpoint is live? | `$XDG_RUNTIME_DIR/knews-curator/endpoint.json` |
| What did the daemon print? | `~/.cache/knews-curator/knewsd.log` |
| What did the unit print? | `journalctl --user -u knewsd -f` |
| Is the database healthy? | `sqlite3 ~/.local/share/knews-curator/curator.db 'pragma integrity_check'` |

## Contributing

Open an issue first for behavioural changes. Keep a change to one concern per commit, run
`./scripts/ci-local.sh` before pushing, and state the verification in the pull request: command,
output, and what it proves.
