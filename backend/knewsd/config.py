"""Runtime paths and defaults for knewsd (stdlib only)."""

from __future__ import annotations

import os
from pathlib import Path

APP = "knews-curator"
VERSION = "1.9.0"
DEFAULT_PORT = 8770
# Seconds without a single request before the daemon exits. The widget is the supervisor and
# keeps it alive with its 60 s poll; the timeout only reaps a process whose client disappeared
# (plasmashell crash, package removed, uninstall that stopped nothing). 0 disables the reaper,
# which is what the systemd unit wants: there the OS owns the lifetime.
DEFAULT_IDLE_EXIT = 900
USER_AGENT = (
    f"Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
    f"Chrome/131.0 Safari/537.36 NewsCurator/{VERSION}"
)

PREF_DEFAULTS: dict[str, object] = {
    "reader_theme": "auto",      # auto | light | sepia | dark
    "serif": 0,
    "font_family": "",           # "" -> the widget picks Noto Sans / Noto Serif
    "font_scale": 100,           # percent, 80..170
    "line_height": 160,          # percent of font size
    "reader_padding": 100,       # percent of the reader side margin, 60..160
    "list_scale": 100,           # percent, headline list text size, 80..160
    "auto_mark_read": 1,
    "refresh_minutes": 30,       # 0 disables background refresh
    "open_external": 0,          # 1 -> single click opens system browser
    "max_items_per_feed": 300,
    "image_width": 900,
}


def data_dir() -> Path:
    base = os.environ.get("XDG_DATA_HOME") or str(Path.home() / ".local" / "share")
    p = Path(base) / APP
    p.mkdir(parents=True, exist_ok=True)
    return p


def cache_dir() -> Path:
    base = os.environ.get("XDG_CACHE_HOME") or str(Path.home() / ".cache")
    p = Path(base) / APP
    (p / "images").mkdir(parents=True, exist_ok=True)
    return p


def db_path() -> Path:
    env = os.environ.get("KNEWS_DB")
    if env:
        return Path(env)
    return data_dir() / "curator.db"

def runtime_dir() -> Path:
    """Per-user, per-session scratch space (sockets, lock, endpoint description).

    Falls back to the cache dir when the runtime dir is not writable: a hardened systemd unit
    with ``ProtectSystem=strict`` makes ``$XDG_RUNTIME_DIR`` read-only until the unit lists it
    in ``ReadWritePaths``, and a bind failure there must not take the whole daemon down.
    """
    base = os.environ.get("XDG_RUNTIME_DIR") or str(cache_dir())
    p = Path(base) / APP
    try:
        p.mkdir(parents=True, exist_ok=True)
    except OSError:
        p = cache_dir() / "run"
        p.mkdir(parents=True, exist_ok=True)
    return p

def socket_path() -> Path:
    env = os.environ.get("KNEWS_SOCKET")
    if env:
        return Path(env)
    return runtime_dir() / "knewsd.sock"

def endpoint_path() -> Path:
    """JSON file describing how a client reaches the running daemon.

    QML cannot open unix sockets, so socket mode also keeps a loopback listener and publishes
    its ephemeral port here. Clients read this file instead of guessing.
    """
    return runtime_dir() / "endpoint.json"

def lock_path() -> Path:
    return runtime_dir() / "knewsd.lock"
