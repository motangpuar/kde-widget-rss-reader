"""HTTP client, feed refresh, article extraction and image caching (stdlib only)."""

from __future__ import annotations

import gzip
import hashlib
import json
import re
import time
import urllib.error
import urllib.request
import zlib
from pathlib import Path
from typing import Any
from urllib.parse import urljoin, urlparse

from . import feeds as feedmod
from . import readability
from .config import USER_AGENT, cache_dir
from .db import Store

MAX_FEED_BYTES = 8 << 20
MAX_PAGE_BYTES = 6 << 20
MAX_IMAGE_BYTES = 8 << 20
IMAGE_BUDGET_PER_ARTICLE = 16
EXTRACT_MIN_WORDS = 120


class FetchError(Exception):
    pass


def _decode_body(raw: bytes, encoding: str) -> bytes:
    encoding = (encoding or "").lower()
    try:
        if "gzip" in encoding:
            return gzip.decompress(raw)
        if "deflate" in encoding:
            try:
                return zlib.decompress(raw)
            except zlib.error:
                return zlib.decompress(raw, -zlib.MAX_WBITS)
        if "br" in encoding:  # no brotli in stdlib; ask for identity instead
            return raw
    except OSError:
        return raw
    return raw


def http_get(
    url: str,
    etag: str | None = None,
    last_modified: str | None = None,
    timeout: float = 20.0,
    max_bytes: int = MAX_FEED_BYTES,
) -> dict[str, Any]:
    headers = {
        "User-Agent": USER_AGENT,
        "Accept": "application/rss+xml, application/atom+xml, application/feed+json, "
                  "application/xml;q=0.9, text/xml;q=0.9, text/html;q=0.8, */*;q=0.5",
        "Accept-Language": "en-US,en;q=0.7",
        "Accept-Encoding": "gzip, deflate",
    }
    if etag:
        headers["If-None-Match"] = etag
    if last_modified:
        headers["If-Modified-Since"] = last_modified
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read(max_bytes + 1)
            body = _decode_body(raw[:max_bytes], response.headers.get("Content-Encoding", ""))
            return {
                "status": response.status,
                "body": body,
                "headers": {k.lower(): v for k, v in response.headers.items()},
                "url": response.geturl(),
            }
    except urllib.error.HTTPError as exc:
        if exc.code == 304:
            return {"status": 304, "body": b"", "headers": {}, "url": url}
        raise FetchError(f"HTTP {exc.code} for {url}") from exc
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise FetchError(f"{exc}") from exc


# --------------------------------------------------------------------- images
_EXT_BY_TYPE = {
    "image/jpeg": ".jpg", "image/jpg": ".jpg", "image/png": ".png", "image/gif": ".gif",
    "image/webp": ".webp", "image/avif": ".avif", "image/svg+xml": ".svg",
}


def _sniff_ext(blob: bytes, content_type: str) -> str:
    ext = _EXT_BY_TYPE.get(content_type.split(";")[0].strip().lower(), "")
    if ext:
        return ext
    if blob[:3] == b"\xff\xd8\xff":
        return ".jpg"
    if blob[:8] == b"\x89PNG\r\n\x1a\n":
        return ".png"
    if blob[:4] == b"GIF8":
        return ".gif"
    if blob[8:12] == b"WEBP":
        return ".webp"
    if blob[4:12] in (b"ftypavif", b"ftypavis"):
        return ".avif"
    return ""


def cache_image(url: str, timeout: float = 15.0) -> str:
    """Download an image into the cache; return a file:// URI ("" on failure)."""
    if not url or url.startswith("file:"):
        return url if url.startswith("file:") else ""
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https"):
        return ""
    images = cache_dir() / "images"
    key = hashlib.sha1(url.encode("utf-8")).hexdigest()[:20]
    for existing in images.glob(key + ".*"):
        return existing.as_uri()
    try:
        request = urllib.request.Request(
            url, headers={"User-Agent": USER_AGENT, "Accept": "image/*,*/*;q=0.5",
                          "Accept-Encoding": "gzip, deflate"}
        )
        with urllib.request.urlopen(request, timeout=timeout) as response:
            ctype = response.headers.get("Content-Type", "")
            if not ctype.lower().startswith("image/"):
                return ""
            blob = response.read(MAX_IMAGE_BYTES + 1)
            blob = _decode_body(blob[:MAX_IMAGE_BYTES], response.headers.get("Content-Encoding", ""))
    except (urllib.error.URLError, OSError, ValueError):
        return ""
    ext = _sniff_ext(blob, ctype)
    if not ext or len(blob) < 128:
        return ""
    target = images / f"{key}{ext}"
    try:
        target.write_bytes(blob)
    except OSError:
        return ""
    return target.as_uri()



# ------------------------------------------------------------------ discovery
def _normalize_address(address: str) -> str:
    address = (address or "").strip()
    if not address:
        raise FetchError("empty address")
    if "://" not in address:
        address = "https://" + address
    parsed = urlparse(address)
    if parsed.scheme not in ("http", "https") or not parsed.netloc:
        raise FetchError(f"not a web address: {address}")
    return address


def discover(address: str, limit: int = 6, timeout: float = 10.0) -> dict[str, Any]:
    """Resolve an arbitrary address (site, feed, or YouTube style URL) to feeds.

    Returns {"url", "candidates": [{"url", "title", "icon"}], "direct": bool, "message"}.
    """
    url = _normalize_address(address)
    direct_error = ""
    try:
        response = http_get(url, timeout=timeout)
        parsed = feedmod.parse_feed(response["body"], response["url"] or url)
        resolved = response["url"] or url
        return {
            "url": resolved,
            "direct": True,
            "message": "",
            "candidates": [{"url": resolved, "title": parsed["title"] or urlparse(resolved).netloc,
                            "icon": parsed.get("icon") or ""}],
        }
    except Exception as exc:  # noqa: BLE001 - fall through to HTML discovery
        direct_error = str(exc)

    try:
        page = http_get(url, timeout=timeout)
    except Exception as exc:  # noqa: BLE001
        raise FetchError(f"could not reach {url}: {exc}") from exc

    final = page["url"] or url
    html_text = page["body"].decode("utf-8", "replace")
    candidates: list[dict[str, str]] = []
    seen: set[str] = set()
    for candidate in feedmod.discover_feed_urls(html_text, final):
        if len(candidates) >= limit:
            break
        if candidate in seen:
            continue
        seen.add(candidate)
        try:
            probe = http_get(candidate, timeout=timeout)
            parsed = feedmod.parse_feed(probe["body"], probe["url"] or candidate)
        except Exception:  # noqa: BLE001 - try the next candidate
            continue
        resolved = probe["url"] or candidate
        if resolved in seen and resolved != candidate:
            continue
        seen.add(resolved)
        candidates.append({
            "url": resolved,
            "title": parsed["title"] or urlparse(resolved).netloc,
            "icon": parsed.get("icon") or "",
            "entries": len(parsed["entries"]),
        })
    message = "" if candidates else f"no feeds found on {final} ({direct_error or 'no candidate parsed'})"
    return {"url": final, "direct": False, "candidates": candidates, "message": message}


def store_feed_icon(store: Store, feed: dict[str, Any], hint: str = "",
                    deep: bool = False) -> str:
    """Cache a favicon for the feed and persist the file URI on the row.

    ``deep=False`` only tries the feed's own icon and ``/favicon.ico`` so it can run on
    the add-feed request path; ``deep=True`` also scans the home page for a link tag.
    """
    if feed.get("icon"):
        return feed["icon"]
    site = feed.get("site") or ""
    feed_url = feed.get("url") or ""
    origin = "{0.scheme}://{0.netloc}".format(urlparse(site or feed_url))
    attempts: list[str] = []
    if hint:
        attempts.append(hint)
    if feed_url:
        attempts.append(urljoin(feed_url, "/favicon.ico"))
    if origin and origin + "/favicon.ico" not in attempts:
        attempts.append(urljoin(origin, "/favicon.ico"))
    for candidate in attempts:
        try:
            uri = cache_image(candidate, timeout=5)
        except Exception:  # noqa: BLE001
            uri = ""
        if uri:
            store.update_feed(feed["id"], icon=uri)
            return uri
    if not deep:
        return ""
    # optional: <link rel="icon"> declared by the site
    if origin:
        try:
            page = http_get(origin + "/", timeout=8)
        except Exception:  # noqa: BLE001
            return ""
        html_text = page["body"].decode("utf-8", "replace")
        for match in re.finditer(r"<link\b[^>]*>", html_text, re.I):
            tag = match.group(0)
            if not re.search(r"rel\s*=\s*[\"']?(?:shortcut )?icon", tag, re.I):
                continue
            href = re.search(r"href\s*=\s*[\"']([^\"']+)[\"']", tag, re.I)
            if not href:
                continue
            uri = cache_image(urljoin(origin + "/", href.group(1)), timeout=5)
            if uri:
                store.update_feed(feed["id"], icon=uri)
                return uri
    return ""

# ---------------------------------------------------------------------- feeds
def refresh_feed(store: Store, feed: dict[str, Any], max_items: int) -> dict[str, Any]:
    url = feed["url"]
    try:
        response = http_get(url, feed.get("etag"), feed.get("last_modified"))
    except FetchError as exc:
        store.update_feed(feed["id"], last_fetch=time.time(), last_error=str(exc)[:300])
        return {"feed": feed["title"] or url, "ok": False, "error": str(exc)}
    if not feed.get("icon"):
        try:
            store_feed_icon(store, feed, deep=True)
        except Exception:  # noqa: BLE001 - icons are cosmetic
            pass
    if response["status"] == 304:
        store.update_feed(feed["id"], last_fetch=time.time(), last_error=None)
        return {"feed": feed["title"] or url, "ok": True, "new": 0, "not_modified": True}
    try:
        parsed = feedmod.parse_feed(response["body"], response["url"] or url)
    except Exception as exc:  # noqa: BLE001 - malformed feeds must not kill refresh
        store.update_feed(feed["id"], last_fetch=time.time(), last_error=f"parse: {exc}"[:300])
        return {"feed": feed["title"] or url, "ok": False, "error": f"parse: {exc}"}

    before = store.counts()["all"]
    for entry in parsed["entries"]:
        store.upsert_item(feed["id"], entry, max_items)
    new = max(0, store.counts()["all"] - before)
    store.update_feed(
        feed["id"],
        title=feed["title"] or parsed["title"] or urlparse(url).netloc,
        site=feed["site"] or parsed["site"],
        etag=response["headers"].get("etag"),
        last_modified=response["headers"].get("last-modified"),
        last_fetch=time.time(),
        last_error=None,
    )
    return {"feed": feed["title"] or parsed["title"] or url, "ok": True, "new": new,
            "items": len(parsed["entries"])}


def probe(address: str, timeout: float = 15.0) -> dict[str, Any]:
    """Check that a single address is a usable feed, without touching the store.

    Strict by design: no HTML discovery, no redirect guessing. Returns
    {"url", "ok", "title", "entries", "empty", "icon", "error"}.
    """
    try:
        url = _normalize_address(address)
    except FetchError as exc:
        return {"url": str(address or "").strip(), "ok": False, "error": str(exc)}

    try:
        response = http_get(url, timeout=timeout)
        parsed = feedmod.parse_feed(response["body"], response["url"] or url)
    except Exception as exc:  # noqa: BLE001 - report instead of raising
        return {"url": url, "ok": False, "error": str(exc)}

    resolved = response["url"] or url
    entries = len(parsed["entries"])
    result: dict[str, Any] = {
        "url": resolved,
        "ok": True,
        "title": parsed["title"] or urlparse(resolved).netloc,
        "site": parsed["site"] or resolved,
        "icon": parsed.get("icon") or "",
        "entries": entries,
        "empty": entries == 0,
        "newest": (parsed["entries"][0].get("published") or 0) if entries else 0,
        "error": "" if entries else "feed is valid but currently empty",
    }
    return result


def change_url(store: Store, feed_id: int, address: str, title: str = "",
               folder: str | None = None) -> dict[str, Any]:
    """Point an existing subscription at a different address.

    The address must resolve to a feed right now, and must not already belong to another
    subscription, so a typo can never blank out a working feed.
    """
    feed = store.feed(feed_id)
    if feed is None:
        raise FetchError("no such feed")
    result = probe(address)
    if not result["ok"]:
        raise FetchError(result["error"] or "that address is not a feed")

    new_url = result["url"]
    for other in store.feeds():
        if other["id"] != feed_id and other["url"] == new_url:
            raise FetchError("that address is already followed")

    if new_url == feed["url"] and (folder is None or folder == feed["folder"]) \
            and (not title or title == feed["title"]):
        raise FetchError("nothing to change")

    fields: dict[str, Any] = {"url": new_url, "etag": None, "last_modified": None,
                              "last_error": None}
    if title:
        fields["title"] = title
    elif not feed["title"]:
        fields["title"] = result["title"]
    if folder is not None:
        fields["folder"] = folder
    if not feed.get("icon") and result.get("icon"):
        fields["icon"] = result["icon"]
    try:
        store.update_feed(feed_id, **fields)
    except ValueError as exc:
        raise FetchError(str(exc)) from exc
    return {"ok": True, "feed": store.feed(feed_id), "entries": result["entries"]}


def add_feed(store: Store, url: str, folder: str = "", title: str = "") -> dict[str, Any]:
    """Add a feed URL, following HTML pages to discover the feed."""
    url = url.strip()
    if not url:
        raise FetchError("empty url")
    if not url.startswith(("http://", "https://")):
        url = "https://" + url
    direct_error = ""
    try:
        response = http_get(url)
        parsed = feedmod.parse_feed(response["body"], response["url"] or url)
        resolved = response["url"] or url
    except Exception as exc:  # noqa: BLE001 - try discovery next
        direct_error = str(exc)
        try:
            page = http_get(url)
            html_text = page["body"].decode("utf-8", "replace")
            candidates = feedmod.discover_feed_urls(html_text, page["url"] or url)
            parsed = None
            resolved = url
            for candidate in candidates:
                try:
                    probe = http_get(candidate, timeout=12)
                    parsed = feedmod.parse_feed(probe["body"], probe["url"] or candidate)
                    resolved = probe["url"] or candidate
                    break
                except Exception:  # noqa: BLE001
                    continue
            if parsed is None:
                raise FetchError(direct_error or "no feed found") from exc
        except Exception as exc2:  # noqa: BLE001
            raise FetchError(f"not a feed and discovery failed: {exc2}") from exc2

    feed_id = store.add_feed(
        resolved,
        title or parsed["title"] or urlparse(resolved).netloc,
        parsed["site"] or resolved,
        folder.strip(),
    )
    feed = store.feed(feed_id)
    assert feed is not None
    try:
        store_feed_icon(store, feed, parsed.get("icon") or "")
    except Exception:  # noqa: BLE001 - icons are cosmetic
        pass
    result = refresh_feed(store, feed, int(store.prefs().get("max_items_per_feed", 300)))
    return {"id": feed_id, "url": resolved, "title": feed["title"], "refresh": result}


# ------------------------------------------------------------------ extraction
def _article_from_html(html_text: str, base_url: str, budget: list[int]) -> dict[str, Any]:
    def hook(url: str) -> str:
        if budget[0] <= 0:
            return ""
        local = cache_image(url)
        if local:
            budget[0] -= 1
            return local
        return ""

    return readability.extract(html_text, base_url, image_hook=hook)


def extract_item(store: Store, item: dict[str, Any], force: bool = False) -> dict[str, Any]:
    """Populate item blocks from the article page, falling back to feed content."""
    if item.get("blocks") and not force and item.get("extract_state") == "ok":
        return item

    budget = [IMAGE_BUDGET_PER_ARTICLE]
    best: dict[str, Any] | None = None
    state = "failed"
    if item.get("url"):
        try:
            page = http_get(item["url"], timeout=18, max_bytes=MAX_PAGE_BYTES)
            ctype = page["headers"].get("content-type", "").lower()
            if "html" in ctype or ctype == "":
                candidate = _article_from_html(page["body"].decode("utf-8", "replace"), item["url"], budget)
                best = candidate
                state = "ok" if candidate["word_count"] >= EXTRACT_MIN_WORDS else "partial"
        except FetchError:
            pass

    if best is None or best["word_count"] < EXTRACT_MIN_WORDS:
        # Fall back to whatever the feed shipped (content:encoded is often full text).
        feed_html = item.get("content") or ""
        if feed_html:
            fed = _article_from_html(feed_html, item.get("url") or "", budget)
            if best is None or fed["word_count"] > best["word_count"]:
                best, state = fed, "feed"
    if best is None:
        blocks = [{"type": "paragraph", "runs": [{"text": item.get("summary") or "No content available.",
                                                  "b": False, "i": False, "href": "", "mono": False}]}]
        store.set_blocks(item["id"], blocks, 0, item.get("image", ""), "failed")
        return {**item, "blocks": json.dumps(blocks), "word_count": 0, "extract_state": "failed"}

    words = best["word_count"]
    store.set_blocks(item["id"], best["blocks"], words, best.get("hero") or item.get("image", ""), state)
    refreshed = store.item(item["id"])
    return refreshed or item
