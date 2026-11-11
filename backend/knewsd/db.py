"""SQLite persistence for feeds, items and preferences."""

from __future__ import annotations

import json
import sqlite3
import threading
import time
from pathlib import Path
from typing import Any, Iterable

from .config import PREF_DEFAULTS

SCHEMA = """
CREATE TABLE IF NOT EXISTS feeds (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    url          TEXT NOT NULL UNIQUE,
    site         TEXT NOT NULL DEFAULT '',
    title        TEXT NOT NULL DEFAULT '',
    folder       TEXT NOT NULL DEFAULT '',
    etag         TEXT,
    last_modified TEXT,
    last_fetch   REAL NOT NULL DEFAULT 0,
    last_error   TEXT,
    enabled      INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE IF NOT EXISTS items (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    feed_id      INTEGER NOT NULL REFERENCES feeds(id) ON DELETE CASCADE,
    guid         TEXT NOT NULL,
    url          TEXT NOT NULL DEFAULT '',
    title        TEXT NOT NULL DEFAULT '',
    author       TEXT NOT NULL DEFAULT '',
    summary      TEXT NOT NULL DEFAULT '',
    content      TEXT NOT NULL DEFAULT '',
    published    REAL NOT NULL DEFAULT 0,
    fetched      REAL NOT NULL DEFAULT 0,
    read         INTEGER NOT NULL DEFAULT 0,
    starred      INTEGER NOT NULL DEFAULT 0,
    blocks       TEXT,
    word_count   INTEGER NOT NULL DEFAULT 0,
    image        TEXT NOT NULL DEFAULT '',
    extract_state TEXT NOT NULL DEFAULT 'none',
    UNIQUE (feed_id, guid)
);
CREATE INDEX IF NOT EXISTS idx_items_feed_pub ON items (feed_id, published DESC);
CREATE INDEX IF NOT EXISTS idx_items_unread   ON items (read, published DESC);
CREATE INDEX IF NOT EXISTS idx_items_starred  ON items (starred, published DESC);
CREATE TABLE IF NOT EXISTS prefs (key TEXT PRIMARY KEY, value TEXT NOT NULL);
"""


class Store:
    def __init__(self, path: str | Path) -> None:
        self.path = str(path)
        self._lock = threading.RLock()
        self.db = sqlite3.connect(self.path, check_same_thread=False, timeout=15)
        self.db.row_factory = sqlite3.Row
        with self._lock:
            self.db.execute("PRAGMA journal_mode=WAL")
            self.db.execute("PRAGMA synchronous=NORMAL")
            self.db.execute("PRAGMA foreign_keys=ON")
            self.db.executescript(SCHEMA)
            self.db.commit()

    # ---------------------------------------------------------------- prefs
    def prefs(self) -> dict[str, Any]:
        out = dict(PREF_DEFAULTS)
        with self._lock:
            for row in self.db.execute("SELECT key, value FROM prefs"):
                try:
                    out[row["key"]] = json.loads(row["value"])
                except (TypeError, ValueError):
                    out[row["key"]] = row["value"]
        return out

    def set_prefs(self, values: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            for key, value in values.items():
                if key not in PREF_DEFAULTS:
                    continue
                self.db.execute(
                    "INSERT INTO prefs (key, value) VALUES (?, ?) "
                    "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    (key, json.dumps(value)),
                )
            self.db.commit()
        return self.prefs()

    # ---------------------------------------------------------------- feeds
    def feeds(self, enabled_only: bool = False) -> list[dict[str, Any]]:
        sql = "SELECT * FROM feeds"
        if enabled_only:
            sql += " WHERE enabled = 1"
        sql += " ORDER BY folder COLLATE NOCASE, title COLLATE NOCASE"
        with self._lock:
            rows = [dict(r) for r in self.db.execute(sql)]
        counts = self.unread_by_feed()
        for row in rows:
            row["unread"] = counts.get(row["id"], 0)
        return rows

    def feed(self, feed_id: int) -> dict[str, Any] | None:
        with self._lock:
            row = self.db.execute("SELECT * FROM feeds WHERE id = ?", (feed_id,)).fetchone()
        return dict(row) if row else None

    def feed_by_url(self, url: str) -> dict[str, Any] | None:
        with self._lock:
            row = self.db.execute("SELECT * FROM feeds WHERE url = ?", (url,)).fetchone()
        return dict(row) if row else None

    def add_feed(self, url: str, title: str, site: str, folder: str = "") -> int:
        with self._lock:
            self.db.execute(
                "INSERT INTO feeds (url, title, site, folder) VALUES (?, ?, ?, ?) "
                "ON CONFLICT(url) DO UPDATE SET title = CASE WHEN excluded.title <> '' "
                "THEN excluded.title ELSE feeds.title END, "
                "site = CASE WHEN excluded.site <> '' THEN excluded.site ELSE feeds.site END, "
                "folder = CASE WHEN excluded.folder <> '' THEN excluded.folder ELSE feeds.folder END",
                (url, title, site, folder),
            )
            self.db.commit()
            row = self.db.execute("SELECT id FROM feeds WHERE url = ?", (url,)).fetchone()
        return int(row["id"])

    def update_feed(self, feed_id: int, **fields: Any) -> None:
        allowed = {"title", "folder", "site", "etag", "last_modified", "last_fetch", "last_error", "enabled"}
        sets = {k: v for k, v in fields.items() if k in allowed}
        if not sets:
            return
        sql = "UPDATE feeds SET " + ", ".join(f"{k} = ?" for k in sets) + " WHERE id = ?"
        with self._lock:
            self.db.execute(sql, (*sets.values(), feed_id))
            self.db.commit()

    def delete_feed(self, feed_id: int) -> None:
        with self._lock:
            self.db.execute("DELETE FROM feeds WHERE id = ?", (feed_id,))
            self.db.commit()

    def unread_by_feed(self) -> dict[int, int]:
        with self._lock:
            rows = self.db.execute(
                "SELECT feed_id, COUNT(*) AS n FROM items WHERE read = 0 GROUP BY feed_id"
            ).fetchall()
        return {int(r["feed_id"]): int(r["n"]) for r in rows}

    # ---------------------------------------------------------------- items
    def upsert_item(self, feed_id: int, item: dict[str, Any], max_items: int) -> None:
        now = time.time()
        with self._lock:
            self.db.execute(
                """INSERT INTO items (feed_id, guid, url, title, author, summary, content,
                                      published, fetched, image)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                   ON CONFLICT(feed_id, guid) DO UPDATE SET
                       url = excluded.url,
                       title = CASE WHEN excluded.title <> '' THEN excluded.title ELSE items.title END,
                       author = CASE WHEN excluded.author <> '' THEN excluded.author ELSE items.author END,
                       summary = CASE WHEN excluded.summary <> '' THEN excluded.summary ELSE items.summary END,
                       content = CASE WHEN excluded.content <> '' THEN excluded.content ELSE items.content END,
                       image = CASE WHEN excluded.image <> '' THEN excluded.image ELSE items.image END,
                       published = CASE WHEN excluded.published > 0 THEN excluded.published ELSE items.published END""",
                (
                    feed_id,
                    item["guid"],
                    item.get("url", ""),
                    item.get("title", ""),
                    item.get("author", ""),
                    item.get("summary", ""),
                    item.get("content", ""),
                    float(item.get("published") or 0),
                    now,
                    item.get("image", ""),
                ),
            )
            if max_items > 0:
                self.db.execute(
                    """DELETE FROM items WHERE feed_id = ? AND id NOT IN (
                           SELECT id FROM items WHERE feed_id = ?
                           ORDER BY published DESC, id DESC LIMIT ?)""",
                    (feed_id, feed_id, max_items),
                )
            self.db.commit()

    def items(
        self,
        feed_id: int | None = None,
        folder: str | None = None,
        view: str = "unread",
        query: str = "",
        limit: int = 100,
        offset: int = 0,
    ) -> tuple[list[dict[str, Any]], int]:
        where: list[str] = []
        params: list[Any] = []
        if feed_id:
            where.append("i.feed_id = ?")
            params.append(feed_id)
        if folder:
            where.append("f.folder = ?")
            params.append(folder)
        if view == "unread":
            where.append("i.read = 0")
        elif view == "starred":
            where.append("i.starred = 1")
        if query:
            where.append("(i.title LIKE ? OR i.summary LIKE ? OR i.author LIKE ?)")
            like = f"%{query}%"
            params.extend([like, like, like])
        clause = ("WHERE " + " AND ".join(where)) if where else ""
        base = (
            "FROM items i JOIN feeds f ON f.id = i.feed_id "
            f"{clause} "
        )
        with self._lock:
            total = int(self.db.execute("SELECT COUNT(*) " + base, params).fetchone()[0])
            rows = self.db.execute(
                "SELECT i.id, i.feed_id, i.url, i.title, i.author, i.summary, i.published, "
                "i.read, i.starred, i.image, f.title AS feed_title, f.folder AS folder "
                + base
                + "ORDER BY i.published DESC, i.id DESC LIMIT ? OFFSET ?",
                (*params, limit, offset),
            ).fetchall()
        return [dict(r) for r in rows], total

    def item(self, item_id: int) -> dict[str, Any] | None:
        with self._lock:
            row = self.db.execute(
                "SELECT i.*, f.title AS feed_title, f.site AS feed_site, f.folder AS folder "
                "FROM items i JOIN feeds f ON f.id = i.feed_id WHERE i.id = ?",
                (item_id,),
            ).fetchone()
        return dict(row) if row else None

    def set_item_flags(self, item_id: int, read: bool | None = None, starred: bool | None = None) -> None:
        sets: list[str] = []
        params: list[Any] = []
        if read is not None:
            sets.append("read = ?")
            params.append(1 if read else 0)
        if starred is not None:
            sets.append("starred = ?")
            params.append(1 if starred else 0)
        if not sets:
            return
        with self._lock:
            self.db.execute(f"UPDATE items SET {', '.join(sets)} WHERE id = ?", (*params, item_id))
            self.db.commit()

    def set_blocks(self, item_id: int, blocks: list[dict[str, Any]], word_count: int,
                   image: str, state: str) -> None:
        with self._lock:
            self.db.execute(
                "UPDATE items SET blocks = ?, word_count = ?, image = ?, extract_state = ? WHERE id = ?",
                (json.dumps(blocks, ensure_ascii=False), word_count, image, state, item_id),
            )
            self.db.commit()

    def mark_all_read(self, feed_id: int | None = None, folder: str | None = None) -> int:
        sql = "UPDATE items SET read = 1 WHERE read = 0"
        params: list[Any] = []
        if feed_id:
            sql += " AND feed_id = ?"
            params.append(feed_id)
        elif folder:
            sql += " AND feed_id IN (SELECT id FROM feeds WHERE folder = ?)"
            params.append(folder)
        with self._lock:
            cur = self.db.execute(sql, params)
            self.db.commit()
            return cur.rowcount

    def counts(self) -> dict[str, int]:
        with self._lock:
            unread = int(self.db.execute("SELECT COUNT(*) FROM items WHERE read = 0").fetchone()[0])
            starred = int(self.db.execute("SELECT COUNT(*) FROM items WHERE starred = 1").fetchone()[0])
            total = int(self.db.execute("SELECT COUNT(*) FROM items").fetchone()[0])
            feeds = int(self.db.execute("SELECT COUNT(*) FROM feeds").fetchone()[0])
        return {"unread": unread, "starred": starred, "all": total, "feeds": feeds}

    def folders(self) -> list[str]:
        with self._lock:
            rows = self.db.execute(
                "SELECT DISTINCT folder FROM feeds WHERE folder <> '' ORDER BY folder COLLATE NOCASE"
            ).fetchall()
        return [str(r["folder"]) for r in rows]

    def iter_feed_items(self, feed_id: int) -> Iterable[sqlite3.Row]:
        with self._lock:
            return self.db.execute("SELECT * FROM items WHERE feed_id = ?", (feed_id,)).fetchall()
