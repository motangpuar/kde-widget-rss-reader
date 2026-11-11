"""HTTP JSON API on 127.0.0.1 for the Plasma widget."""

from __future__ import annotations

import json
import mimetypes
import os
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse

from . import config
from . import fetch as fetchmod
from . import feeds as feedmod
from .config import DEFAULT_PORT, VERSION
from .db import Store

CLIENT_HEADER = "x-knews-client"
ACCESS_LOG = os.environ.get("KNEWS_ACCESS_LOG") == "1"
ALLOWED_HOSTS = {"127.0.0.1", "localhost", "[::1]"}


def save_opml(store: Store, raw_path: str) -> dict[str, Any]:
    """Write an OPML export, falling back to the data dir when the target is read-only.

    The daemon runs under systemd with ``ProtectHome=read-only``, so a save dialog can
    legitimately point at a path the unit may not write. The export still lands somewhere
    the user can find, and the reply says which path was actually used.
    """
    raw = str(raw_path or "").strip()
    if not raw:
        raise ValueError("path required")
    target = Path(os.path.expanduser(raw))
    if not target.is_absolute():
        raise ValueError("absolute path required")
    if target.suffix.lower() not in (".opml", ".xml"):
        target = target.with_suffix(".opml")

    feeds = store.feeds()
    payload = feedmod.build_opml(feeds).encode()
    fallback = False
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        scratch = target.with_name(target.name + ".tmp")
        scratch.write_bytes(payload)
        scratch.replace(target)
    except OSError:
        fallback = True
        exports = config.data_dir() / "exports"
        exports.mkdir(parents=True, exist_ok=True)
        stamp = time.strftime("%Y%m%d-%H%M%S")
        target = exports / f"news-curator-{stamp}.opml"
        target.write_bytes(payload)

    return {"ok": True, "path": str(target), "requested": raw, "fallback": fallback,
            "bytes": len(payload), "feeds": len(feeds)}


class RefreshManager:
    """Serialises feed refreshes and exposes progress for UI polling."""

    def __init__(self, store: Store) -> None:
        self.store = store
        self._lock = threading.Lock()
        self._thread: threading.Thread | None = None
        self.state: dict[str, Any] = {"running": False, "done": 0, "total": 0,
                                      "new": 0, "errors": [], "finished": 0}

    def start(self, feed_id: int | None = None,
              feeds: list[dict[str, Any]] | None = None) -> bool:
        if self.state["running"]:
            return False
        if feeds is None:
            feeds = self.store.feeds(enabled_only=True) if feed_id is None else [self.store.feed(feed_id)]
        feeds = [f for f in feeds if f]
        if not feeds:
            return False
        self.state = {"running": True, "done": 0, "total": len(feeds), "new": 0,
                      "errors": [], "finished": 0}
        self._thread = threading.Thread(target=self._run, args=(feeds,), daemon=True)
        self._thread.start()
        return True

    def _run(self, feeds: list[dict[str, Any]]) -> None:
        with self._lock:
            max_items = int(self.store.prefs().get("max_items_per_feed", 300))
            for feed in feeds:
                result = fetchmod.refresh_feed(self.store, feed, max_items)
                self.state["done"] += 1
                self.state["new"] += int(result.get("new") or 0)
                if not result.get("ok"):
                    self.state["errors"].append(f"{result['feed']}: {result.get('error')}")
            self.state["running"] = False
            self.state["finished"] = time.time()


class Api:
    def __init__(self, store: Store) -> None:
        self.store = store
        self.refresh = RefreshManager(store)

    # ------------------------------------------------------------ serialisers
    def state(self) -> dict[str, Any]:
        feeds = self.store.feeds()
        return {
            "feeds": feeds,
            "folders": self.store.folders(),
            "counts": self.store.counts(),
            "prefs": self.store.prefs(),
            "refresh": self.refresh.state,
            "export_dir": str(Path.home() / "Downloads"),
            "version": VERSION,
        }

    def discover(self, query: dict[str, list[str]]) -> dict[str, Any]:
        """Resolve an address typed by the user into candidate feeds."""
        address = (query.get("url") or [""])[0]
        known = {feed["url"]: feed["title"] for feed in self.store.feeds()}
        try:
            result = fetchmod.discover(address)
        except fetchmod.FetchError as exc:
            return {"ok": False, "url": address, "candidates": [], "message": str(exc)}
        for candidate in result["candidates"]:
            candidate["existing"] = candidate["url"] in known
            if candidate["existing"]:
                candidate["title"] = candidate["title"] or known[candidate["url"]]
        result["ok"] = True
        return result

    def probe_urls(self, urls: list[Any], limit: int = 50) -> list[dict[str, Any]]:
        """Validate a list of addresses in parallel; never raises for bad input."""
        cleaned: list[str] = []
        for raw in urls or []:
            text = str(raw or "").strip()
            if text and text not in cleaned:
                cleaned.append(text)
        cleaned = cleaned[:limit]
        if not cleaned:
            return []
        known = {feed["url"]: feed["title"] for feed in self.store.feeds()}
        with ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(fetchmod.probe, cleaned))
        for item in results:
            item["existing"] = item["url"] in known
            if item["existing"]:
                item["title"] = item["title"] or known[item["url"]]
        return results

    def item_list(self, query: dict[str, list[str]]) -> dict[str, Any]:
        def one(name: str, default: str = "") -> str:
            return (query.get(name) or [default])[0]

        feed_id = one("feed")
        view = one("view", "unread")
        limit = min(max(int(one("limit", "120") or 120), 1), 400)
        offset = max(int(one("offset", "0") or 0), 0)
        rows, total = self.store.items(
            feed_id=int(feed_id) if feed_id else None,
            folder=one("folder") or None,
            view=view,
            query=one("q"),
            limit=limit,
            offset=offset,
        )
        for row in rows:
            row["thumb"] = bool(row.pop("image", ""))
        return {"items": rows, "total": total, "offset": offset}

    def item_detail(self, query: dict[str, list[str]]) -> dict[str, Any]:
        item_id = int((query.get("id") or ["0"])[0])
        item = self.store.item(item_id)
        if not item:
            raise KeyError("item not found")
        mark_read = (query.get("read") or ["0"])[0] == "1"
        if mark_read and not item["read"]:
            self.store.set_item_flags(item_id, read=True)
            item["read"] = 1
        needs_extract = not item.get("blocks") or (query.get("force") or ["0"])[0] == "1"
        if needs_extract:
            item = fetchmod.extract_item(self.store, item, force=(query.get("force") or ["0"])[0] == "1")
        blocks = item.get("blocks")
        item["blocks"] = json.loads(blocks) if isinstance(blocks, str) else (blocks or [])
        item["feed_link"] = item.get("feed_site") or ""
        item.pop("content", None)
        item["unread_total"] = self.store.counts()["unread"]
        return item

    def thumb_bytes(self, query: dict[str, list[str]]) -> tuple[bytes, str] | None:
        item_id = int((query.get("id") or ["0"])[0])
        item = self.store.item(item_id)
        if not item:
            return None
        source = item.get("image") or ""
        if not source:
            return None
        local = fetchmod.cache_image(source)
        if not local:
            return None
        path = Path(urlparse(local).path)
        try:
            blob = path.read_bytes()
        except OSError:
            return None
        ctype = mimetypes.guess_type(path.name)[0] or "image/jpeg"
        return blob, ctype


class Handler(BaseHTTPRequestHandler):
    server_version = f"knewsd/{VERSION}"
    protocol_version = "HTTP/1.1"
    api: Api  # type: ignore[assignment]

    # -------------------------------------------------------------- plumbing
    def log_message(self, fmt: str, *args: Any) -> None:  # quieter logs
        if ACCESS_LOG:
            sys.stderr.write("request %s - %s\n" % (self.address_string(), fmt % args))
            sys.stderr.flush()

    def _host_ok(self) -> bool:
        host = (self.headers.get("Host") or "").split(":")[0]
        return host in ALLOWED_HOSTS

    def _send(self, status: int, payload: Any, ctype: str = "application/json",
              extra: dict[str, str] | None = None) -> None:
        body = payload if isinstance(payload, bytes) else json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _error(self, status: int, message: str) -> None:
        self._send(status, {"error": message})

    def _guard(self, mutating: bool) -> bool:
        if not self._host_ok():
            self._error(403, "bad host")
            return False
        if self.headers.get("Origin"):
            self._error(403, "browser origins are not allowed")
            return False
        if mutating and (self.headers.get(CLIENT_HEADER) or "") != "plasma":
            self._error(403, "missing client header")
            return False
        return True

    def _body(self) -> dict[str, Any]:
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return {}
        if length <= 0:
            return {}
        raw = self.rfile.read(min(length, 4 << 20))
        try:
            data = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return {}
        return data if isinstance(data, dict) else {}

    # ----------------------------------------------------------------- verbs
    def do_GET(self) -> None:  # noqa: N802
        if not self._guard(False):
            return
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        route = parsed.path
        try:
            if route == "/api/health":
                self._send(200, {"ok": True, "version": VERSION, **self.api.store.counts()})
            elif route == "/api/state":
                self._send(200, self.api.state())
            elif route == "/api/items":
                self._send(200, self.api.item_list(query))
            elif route == "/api/item":
                self._send(200, self.api.item_detail(query))
            elif route == "/api/thumb":
                result = self.api.thumb_bytes(query)
                if not result:
                    self._error(404, "no thumbnail")
                else:
                    self._send(200, result[0], result[1])
            elif route == "/api/discover":
                self._send(200, self.api.discover(query))
            elif route == "/api/validate":
                results = self.api.probe_urls([(query.get("url") or [""])[0]])
                self._send(200, results[0] if results
                           else {"url": "", "ok": False, "error": "no url given"})
            elif route == "/api/refresh/status":
                self._send(200, self.api.refresh.state)
            elif route == "/api/opml":
                feeds = self.api.store.feeds()
                body = feedmod.build_opml(feeds).encode()
                self._send(200, body, "text/xml; charset=utf-8",
                           {"Content-Disposition": 'attachment; filename="news-curator.opml"'})
            else:
                self._error(404, "unknown route")
        except KeyError as exc:
            self._error(404, str(exc))
        except (ValueError, TypeError) as exc:
            self._error(400, str(exc))
        except Exception as exc:  # noqa: BLE001
            self._error(500, f"{type(exc).__name__}: {exc}")

    def do_POST(self) -> None:  # noqa: N802
        if not self._guard(True):
            return
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        body = self._body()
        route = parsed.path
        store = self.api.store
        try:
            if route == "/api/feeds":
                url = str(body.get("url") or "").strip()
                result = fetchmod.add_feed(store, url, str(body.get("folder") or ""),
                                           str(body.get("title") or ""))
                self._send(200, {"ok": True, "feed": result, "state": self.api.state()})
            elif route == "/api/validate":
                urls = body.get("urls")
                if urls is None:
                    urls = [body.get("url") or ""]
                if isinstance(urls, str):
                    urls = [urls]
                self._send(200, {"results": self.api.probe_urls(list(urls))})
            elif route == "/api/feeds/bulk":
                folder = str(body.get("folder") or "")
                urls = body.get("urls")
                if isinstance(urls, str):
                    urls = [urls]
                results = []
                for raw in list(urls or [])[:50]:
                    url = str(raw or "").strip()
                    if not url:
                        continue
                    try:
                        feed = fetchmod.add_feed(store, url, folder, "")
                        results.append({"url": url, "ok": True, "feed": feed})
                    except Exception as exc:  # noqa: BLE001 - report per url
                        results.append({"url": url, "ok": False, "error": str(exc)})
                self._send(200, {"ok": True,
                                 "added": len([r for r in results if r["ok"]]),
                                 "results": results,
                                 "state": self.api.state()})
            elif route == "/api/feeds/delete":
                store.delete_feed(int(body.get("id") or 0))
                self._send(200, self.api.state())
            elif route == "/api/feeds/update":
                feed_id = int(body.get("id") or 0)
                feed = store.feed(feed_id)
                if feed is None:
                    self._send(404, {"error": "no such feed"})
                    return
                new_url = str(body.get("url") or "").strip()
                folder = body.get("folder")
                folder = None if folder is None else str(folder).strip()
                title = str(body.get("title") or "").strip()
                if new_url and new_url != feed["url"]:
                    try:
                        changed = fetchmod.change_url(store, feed_id, new_url, title, folder)
                    except fetchmod.FetchError as exc:
                        self._send(400, {"error": str(exc)})
                        return
                    self.api.refresh.start(feeds=[store.feed(feed_id)])
                    self._send(200, {**self.api.state(), "feed": changed["feed"],
                                     "entries": changed["entries"]})
                    return
                allowed: dict[str, Any] = {}
                if title:
                    allowed["title"] = title
                if folder is not None:
                    allowed["folder"] = folder
                if "enabled" in body:
                    allowed["enabled"] = 1 if body["enabled"] else 0
                if not allowed:
                    self._send(400, {"error": "nothing to change"})
                    return
                try:
                    store.update_feed(feed_id, **allowed)
                except ValueError as exc:
                    self._send(400, {"error": str(exc)})
                    return
                self._send(200, {**self.api.state(), "feed": store.feed(feed_id)})
            elif route == "/api/item":
                item_id = int(body.get("id") or 0)
                read = body.get("read")
                starred = body.get("starred")
                store.set_item_flags(item_id, None if read is None else bool(read),
                                     None if starred is None else bool(starred))
                self._send(200, {"ok": True, "counts": store.counts()})
            elif route == "/api/mark-all":
                feed_id = body.get("feed")
                folder = body.get("folder")
                changed = store.mark_all_read(int(feed_id) if feed_id else None, folder or None)
                self._send(200, {"ok": True, "changed": changed, "state": self.api.state()})
            elif route == "/api/mark-unread":
                feed_id = body.get("feed")
                folder = body.get("folder")
                ids = body.get("ids")
                if ids is not None and not isinstance(ids, list):
                    self._send(400, {"error": "ids must be a list"})
                    return
                changed = store.mark_unread(int(feed_id) if feed_id else None,
                                            folder or None,
                                            [int(i) for i in ids] if ids else None)
                self._send(200, {"ok": True, "changed": changed, "state": self.api.state()})
            elif route == "/api/refresh":
                feed_id = body.get("feed")
                started = self.api.refresh.start(int(feed_id) if feed_id else None)
                self._send(200, {"started": started, "status": self.api.refresh.state})
            elif route == "/api/prefs":
                prefs = body.get("prefs") or {}
                self._send(200, {"prefs": store.set_prefs(dict(prefs)) if isinstance(prefs, dict) else store.prefs()})
            elif route == "/api/opml":
                text = str(body.get("opml") or "")
                added = []
                for entry in feedmod.parse_opml(text):
                    try:
                        added.append(fetchmod.add_feed(store, entry["url"], entry["folder"],
                                                       entry["title"]))
                    except fetchmod.FetchError as exc:
                        added.append({"url": entry["url"], "error": str(exc)})
                self._send(200, {"ok": True, "imported": added, "state": self.api.state()})
            elif route == "/api/opml/save":
                self._send(200, save_opml(store, str(body.get("path") or "")))
            elif route == "/api/extract":
                item_id = int(body.get("id") or 0)
                item = store.item(item_id)
                if not item:
                    raise KeyError("item not found")
                item = fetchmod.extract_item(store, item, force=True)
                blocks = item.get("blocks")
                item["blocks"] = json.loads(blocks) if isinstance(blocks, str) else (blocks or [])
                item.pop("content", None)
                self._send(200, item)
            else:
                self._error(404, "unknown route")
        except KeyError as exc:
            self._error(404, str(exc))
        except fetchmod.FetchError as exc:
            self._error(400, str(exc))
        except (ValueError, TypeError) as exc:
            self._error(400, str(exc))
        except Exception as exc:  # noqa: BLE001
            self._error(500, f"{type(exc).__name__}: {exc}")


class AutoRefresher(threading.Thread):
    def __init__(self, store: Store, manager: RefreshManager) -> None:
        super().__init__(daemon=True)
        self.store = store
        self.manager = manager

    def run(self) -> None:
        while True:
            time.sleep(30)
            try:
                minutes = int(self.store.prefs().get("refresh_minutes", 30) or 0)
                if minutes <= 0 or self.manager.state["running"]:
                    continue
                feeds = self.store.feeds(enabled_only=True)
                due = [f for f in feeds if time.time() - float(f["last_fetch"] or 0) >= minutes * 60]
                if due:
                    self.manager.start(feeds=due)
            except Exception:  # noqa: BLE001 - never let the loop die
                continue


def build_server(store: Store, host: str = "127.0.0.1", port: int = DEFAULT_PORT) -> ThreadingHTTPServer:
    api = Api(store)
    handler = type("BoundHandler", (Handler,), {"api": api})
    server = ThreadingHTTPServer((host, port), handler)
    server.daemon_threads = True
    server.api = api  # type: ignore[attr-defined]
    return server


def serve(store: Store, host: str = "127.0.0.1", port: int = DEFAULT_PORT) -> None:
    server = build_server(store, host, port)
    AutoRefresher(store, server.api.refresh).start()  # type: ignore[attr-defined]
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        server.server_close()
