"""RSS 2.0 / RSS 1.0 (RDF) / Atom / JSON Feed parsing, feed discovery, OPML."""

from __future__ import annotations

import html
import json
import re
from email.utils import parsedate_to_datetime
from datetime import datetime, timezone
from urllib.parse import urljoin, urlparse
from xml.etree import ElementTree as ET

TAG_RE = re.compile(r"<[^>]+>")
WS_RE = re.compile(r"\s+")
FEED_TYPES = (
    "application/rss+xml",
    "application/atom+xml",
    "application/feed+json",
    "application/xml",
    "text/xml",
    "application/rdf+xml",
)
COMMON_PATHS = ("/feed", "/feed.xml", "/rss", "/rss.xml", "/atom.xml", "/index.xml", "/feeds/posts/default")


def local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1].lower()


def text_of(node: ET.Element | None) -> str:
    if node is None:
        return ""
    return "".join(node.itertext()).strip()


def strip_html(value: str) -> str:
    if not value:
        return ""
    value = re.sub(r"(?is)<(script|style)[^>]*>.*?</\1>", " ", value)
    value = re.sub(r"(?i)<br\s*/?>", " ", value)
    value = TAG_RE.sub(" ", value)
    return WS_RE.sub(" ", html.unescape(value)).strip()


def parse_date(value: str) -> float:
    value = (value or "").strip()
    if not value:
        return 0.0
    try:
        dt = parsedate_to_datetime(value)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.timestamp()
    except (TypeError, ValueError, IndexError):
        pass
    iso = value.replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(iso)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.timestamp()
    except ValueError:
        pass
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d", "%d %b %Y %H:%M:%S"):
        try:
            return datetime.strptime(value[:19], fmt).replace(tzinfo=timezone.utc).timestamp()
        except ValueError:
            continue
    return 0.0


def _first_image(fragment: str) -> str:
    m = re.search(r"""(?is)<img[^>]+src\s*=\s*["']([^"']+)["']""", fragment or "")
    if not m:
        return ""
    src = m.group(1).strip()
    if src.startswith("data:"):
        return ""
    return src


def _entry_image(node: ET.Element, content: str, base: str) -> str:
    for child in node.iter():
        name = local(child.tag)
        if name in ("thumbnail", "content", "image", "enclosure", "link"):
            url = child.get("url") or child.get("href") or ""
            mtype = (child.get("type") or child.get("medium") or "").lower()
            if url and (mtype.startswith("image") or name in ("thumbnail", "image")):
                if name == "link" and (child.get("rel") or "alternate") != "enclosure":
                    continue
                return urljoin(base, url)
    first = _first_image(content)
    return urljoin(base, first) if first else ""


def _atom_link(node: ET.Element, base: str, rel: str = "alternate") -> str:
    fallback = ""
    for child in node:
        if local(child.tag) != "link":
            continue
        href = child.get("href") or ""
        if not href:
            continue
        if (child.get("rel") or "alternate") == rel:
            return urljoin(base, href)
        fallback = fallback or urljoin(base, href)
    return fallback


def parse_feed(data: bytes | str, base_url: str = "") -> dict:
    """Return {"title","site","entries":[{"guid","url","title","author","summary","content","published","image"}]}."""
    if isinstance(data, bytes):
        text = data.decode("utf-8", "replace")
        stripped = text.lstrip()
        if stripped.startswith("{") or stripped.startswith("["):
            return _parse_json_feed(stripped, base_url)
        if not stripped.startswith("<"):
            # Bail out on garbage/HTML served with a feed content type.
            raise ValueError("not a feed")
        try:
            root = ET.fromstring(data)
        except ET.ParseError as exc:
            raise ValueError(f"not a feed: {exc}") from exc
    else:
        stripped = data.lstrip()
        if stripped.startswith("{") or stripped.startswith("["):
            return _parse_json_feed(stripped, base_url)
        try:
            root = ET.fromstring(data)
        except ET.ParseError as exc:
            raise ValueError(f"not a feed: {exc}") from exc

    kind = local(root.tag)
    base = base_url
    if kind == "rss":
        channel = next((c for c in root if local(c.tag) == "channel"), root)
        title = text_of(next((c for c in channel if local(c.tag) == "title"), None))
        site = _atom_link(channel, base, "alternate") or text_of(
            next((c for c in channel if local(c.tag) in ("link", "guid")), None)
        )
        nodes = [c for c in channel if local(c.tag) == "item"]
    elif kind in ("feed",):  # Atom
        title = text_of(next((c for c in root if local(c.tag) == "title"), None))
        site = _atom_link(root, base, "alternate") or base
        nodes = [c for c in root if local(c.tag) == "entry"]
    elif kind == "rdf":  # RSS 1.0
        channel = next((c for c in root if local(c.tag) == "channel"), root)
        title = text_of(next((c for c in channel if local(c.tag) == "title"), None))
        site = text_of(next((c for c in channel if local(c.tag) == "link"), None))
        nodes = [c for c in root if local(c.tag) == "item"]
    else:
        raise ValueError(f"unsupported feed root: {kind}")

    entries = []
    for node in nodes:
        url = _atom_link(node, base, "alternate")
        if not url:
            for child in node:
                if local(child.tag) == "link" and text_of(child):
                    url = urljoin(base, text_of(child))
                    break
        url = url or base
        content = ""
        summary = ""
        for child in node:
            name = local(child.tag)
            if name in ("encoded", "content"):
                content = content or (child.text or "").strip()
            elif name in ("description", "summary"):
                summary = summary or (child.text or "").strip()
        if not content:
            content = summary
        title_ = text_of(next((c for c in node if local(c.tag) == "title"), None))
        author = ""
        for child in node.iter():
            if local(child.tag) == "author":
                author = text_of(child) or child.get("name") or child.get("email") or author
            elif local(child.tag) == "creator" and not author:
                author = text_of(child)
        published = 0.0
        for child in node:
            if local(child.tag) in ("pubdate", "published", "updated", "date", "created"):
                published = parse_date(text_of(child)) or published
                if published:
                    break
        guid = ""
        for child in node:
            if local(child.tag) in ("guid", "id"):
                guid = text_of(child) or child.get("isPermaLink") or ""
                break
        entries.append(
            {
                "guid": guid or url or title_,
                "url": url,
                "title": strip_html(title_) or strip_html(content)[:120],
                "author": strip_html(author)[:120],
                "summary": strip_html(summary or content)[:1200],
                "content": content,
                "published": published,
                "image": _entry_image(node, content, base),
            }
        )
    return {"title": strip_html(title), "site": urljoin(base, site or ""),
            "icon": _xml_feed_icon(root, base), "entries": entries}


def _parse_json_feed(text: str, base_url: str) -> dict:
    doc = json.loads(text)
    entries = []
    for e in doc.get("items", []):
        content = e.get("content_html") or e.get("summary") or ""
        entries.append(
            {
                "guid": str(e.get("id") or e.get("url") or e.get("title") or ""),
                "url": urljoin(base_url, e.get("url") or e.get("external_url") or ""),
                "title": strip_html(e.get("title") or "")[:300],
                "author": strip_html((e.get("author") or {}).get("name", "") if isinstance(e.get("author"), dict) else "")[:120],
                "summary": strip_html(e.get("summary") or content)[:1200],
                "content": content,
                "published": parse_date(e.get("date_published") or e.get("date_modified") or ""),
                "image": e.get("image") or e.get("banner_image") or "",
            }
        )
    return {
        "icon": urljoin(base_url, doc.get("icon") or doc.get("favicon") or ""),
        "title": strip_html(doc.get("title") or ""),
        "site": doc.get("home_page_url") or base_url,
        "entries": entries,
    }


def _xml_feed_icon(root: ET.Element, base_url: str) -> str:
    """Best-effort feed logo: atom:icon/logo, RSS <image><url>, itunes:image."""
    for node in root.iter():
        name = local(node.tag)
        if name in ("icon", "logo"):
            value = text_of(node) or node.get("href") or ""
            if value:
                return urljoin(base_url, value.strip())
    for node in root.iter():
        if local(node.tag) == "image":
            for sub in node.iter():
                if local(sub.tag) == "url":
                    value = text_of(sub)
                    if value:
                        return urljoin(base_url, value.strip())
    return ""


def discover_feed_urls(page_html: str, base_url: str) -> list[str]:
    """Return candidate feed URLs found in an HTML page (alternate links first)."""
    found: list[str] = []
    for m in re.finditer(r"<link\b[^>]*>", page_html, re.I):
        tag = m.group(0)
        if not re.search(r"""type\s*=\s*["']?application/(rss|atom)\+xml""", tag, re.I):
            continue
        href = re.search(r"""href\s*=\s*["']([^"']+)["']""", tag, re.I)
        if href:
            found.append(urljoin(base_url, href.group(1)))
    if not found:
        sm = re.search(r"""<a\b[^>]+href\s*=\s*["']([^"']*(?:rss|feed|atom)[^"']*)["']""", page_html, re.I)
        if sm:
            found.append(urljoin(base_url, sm.group(1)))
    origin = "{0.scheme}://{0.netloc}".format(urlparse(base_url))
    for path in COMMON_PATHS:
        found.append(urljoin(origin, path))
    seen: set[str] = set()
    out = []
    for u in found:
        if u not in seen:
            seen.add(u)
            out.append(u)
    return out


def parse_opml(text: str) -> list[dict[str, str]]:
    """Return [{"url","title","folder"}] from an OPML document."""
    root = ET.fromstring(text)
    out: list[dict[str, str]] = []

    def walk(node: ET.Element, folder: str) -> None:
        for child in node:
            if local(child.tag) != "outline":
                continue
            url = child.get("xmlUrl") or child.get("xmlurl") or ""
            if url:
                out.append(
                    {
                        "url": url.strip(),
                        "title": (child.get("title") or child.get("text") or "").strip(),
                        "folder": folder,
                    }
                )
            else:
                walk(child, (child.get("title") or child.get("text") or folder).strip())

    body = next((c for c in root if local(c.tag) == "body"), root)
    walk(body, "")
    return out


def build_opml(feeds: list[dict]) -> str:
    def esc(v: str) -> str:
        return html.escape(v or "", quote=True)

    by_folder: dict[str, list[dict]] = {}
    for f in feeds:
        by_folder.setdefault(f.get("folder") or "", []).append(f)
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<opml version="2.0"><head><title>News Curator</title></head><body>',
    ]
    for folder in sorted(by_folder):
        entries = by_folder[folder]
        if folder:
            lines.append(f'  <outline text="{esc(folder)}" title="{esc(folder)}">')
            pad = "    "
        else:
            pad = "  "
        for f in entries:
            lines.append(
                f'{pad}<outline type="rss" text="{esc(f.get("title"))}" title="{esc(f.get("title"))}" '
                f'xmlUrl="{esc(f.get("url"))}" htmlUrl="{esc(f.get("site"))}"/>'
            )
        if folder:
            lines.append("  </outline>")
    lines.append("</body></opml>")
    return "\n".join(lines) + "\n"
