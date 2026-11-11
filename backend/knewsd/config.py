"""Runtime paths and defaults for knewsd (stdlib only)."""

from __future__ import annotations

import os
from pathlib import Path

APP = "knews-curator"
VERSION = "1.3.0"
DEFAULT_PORT = 8770
USER_AGENT = (
    f"Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
    f"Chrome/131.0 Safari/537.36 NewsCurator/{VERSION}"
)

PREF_DEFAULTS: dict[str, object] = {
    "reader_theme": "auto",      # auto | light | sepia | dark
    "serif": 0,
    "font_scale": 100,           # percent, 80..160
    "line_height": 160,          # percent of font size
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
