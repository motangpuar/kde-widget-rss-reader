"""Readability-style article extraction producing structured blocks for QML.

Blocks are plain dicts so the plasmoid can render Instapaper-like typography
without a rich-text/HTML engine:

    {"type": "heading", "level": 2, "text": "..."}
    {"type": "paragraph", "runs": [{"text": "...", "b": false, "i": false, "href": ""}]}
    {"type": "list", "ordered": false, "items": [[run, ...], ...]}
    {"type": "quote", "runs": [...]}
    {"type": "code", "text": "..."}
    {"type": "image", "src": "https://...", "alt": "...", "width": 0, "height": 0, "caption": ""}
    {"type": "divider"}
"""

from __future__ import annotations

import re
from html.parser import HTMLParser
from typing import Any, Callable
from urllib.parse import urljoin, urlparse

VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
        "param", "source", "track", "wbr"}
DROP = {"script", "style", "noscript", "nav", "footer", "header", "aside", "form", "iframe",
        "svg", "button", "select", "input", "textarea", "label", "canvas", "object", "embed",
        "video", "audio", "template", "dialog", "menu"}
INLINE = {"b", "strong", "i", "em", "code", "a", "span", "sup", "sub", "mark", "small",
          "u", "s", "del", "ins", "abbr", "kbd", "samp", "var", "q", "cite", "time", "font"}
BLOCK = {"p", "div", "section", "article", "main", "ul", "ol", "li", "blockquote", "pre",
         "figure", "figcaption", "table", "thead", "tbody", "tr", "td", "th", "h1", "h2",
         "h3", "h4", "h5", "h6", "hr", "header", "footer", "aside", "nav", "address", "dl",
         "dt", "dd", "details", "summary", "center"}
HEADINGS = {"h1", "h2", "h3", "h4", "h5", "h6"}
AUTOCLOSE = {"p", "li", "dt", "dd", "tr", "td", "th", "option"}

NOISE_RE = re.compile(
    r"(?i)(^|[-_ ])(ad|ads|advert|advertisement|promo|sponsor|share|sharing|social|related|"
    r"recommend|outbrain|taboola|comment|comments|sidebar|newsletter|subscribe|cookie|consent|"
    r"banner|breadcrumb|pagination|pager|pager|popup|modal|toolbar|menu|nav|navigation|"
    r"footer|header|masthead|skip|paywall|signup|login|search)([-_ ]|$)"
)
BAD_IMG_RE = re.compile(r"(?i)((^|/)(1x1|pixel|spacer|blank|transparent|tracking|beacon)[.\-_/]|"
                        r"feedburner|doubleclick|googletag|/ads?/|analytics)")


class Node:
    __slots__ = ("tag", "attrs", "children", "parent")

    def __init__(self, tag: str, attrs: dict[str, str], parent: "Node | None" = None) -> None:
        self.tag = tag
        self.attrs = attrs
        self.children: list["Node | str"] = []
        self.parent = parent

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return f"<{self.tag} {len(self.children)}>"


class _TreeBuilder(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.root = Node("#document", {})
        self.stack = [self.root]

    def _open(self, node: Node) -> None:
        self.stack[-1].children.append(node)
        node.parent = self.stack[-1]
        self.stack.append(node)

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        tag = tag.lower()
        while len(self.stack) > 1 and self.stack[-1].tag in AUTOCLOSE and self.stack[-1].tag == tag:
            self.stack.pop()
        if len(self.stack) > 1 and self.stack[-1].tag == "p" and tag in BLOCK:
            self.stack.pop()
        node = Node(tag, {k.lower(): (v or "") for k, v in attrs})
        if tag in VOID:
            self.stack[-1].children.append(node)
            node.parent = self.stack[-1]
        else:
            self._open(node)

    def handle_endtag(self, tag: str) -> None:
        tag = tag.lower()
        for i in range(len(self.stack) - 1, 0, -1):
            if self.stack[i].tag == tag:
                del self.stack[i:]
                return

    def handle_data(self, data: str) -> None:
        if data:
            self.stack[-1].children.append(data)

    # comments/decls/processing instructions are ignored by default


def build_tree(html_text: str) -> Node:
    builder = _TreeBuilder()
    builder.feed(html_text)
    builder.close()
    return builder.root


def _attr(node: Node, *names: str) -> str:
    for name in names:
        value = node.attrs.get(name)
        if value:
            return value.strip()
    return ""


def _walk(node: Node):
    for child in node.children:
        if isinstance(child, Node):
            yield child
            yield from _walk(child)


def _raw_text(node: Node) -> str:
    if node.tag in DROP:
        return ""
    parts: list[str] = []
    for child in node.children:
        parts.append(child if isinstance(child, str) else _raw_text(child))
    return " ".join(parts)


def text_of(node: Node) -> str:
    return re.sub(r"\s+", " ", _raw_text(node)).strip()


def _link_text_len(node: Node) -> int:
    total = 0
    for child in _walk(node):
        if child.tag == "a":
            total += len(text_of(child))
    return total


def _prune(node: Node) -> None:
    keep: list[Node | str] = []
    for child in node.children:
        if isinstance(child, str):
            keep.append(child)
            continue
        if child.tag in DROP:
            continue
        ident = f"{child.attrs.get('class', '')} {child.attrs.get('id', '')}".strip()
        role = child.attrs.get("role", "").lower()
        if role in ("navigation", "banner", "contentinfo", "complementary", "search"):
            continue
        if ident and NOISE_RE.search(ident) and child.tag not in ("body", "html"):
            continue
        if child.attrs.get("aria-hidden") == "true":
            continue
        _prune(child)
        keep.append(child)
    node.children = keep


def _best_root(root: Node) -> Node:
    body = next((n for n in _walk(root) if n.tag == "body"), root)
    best, best_score = body, 0.0
    for node in _walk(body):
        if node.tag not in ("article", "main", "div", "section", "td", "body"):
            continue
        score = 0.0
        for child in _walk(node):
            if child.tag in ("p", "pre", "blockquote", "td"):
                text = text_of(child)
                if len(text) < 25:
                    continue
                score += len(text) + 20 * text.count(",") + 10 * text.count("。")
        score += 40 if node.tag == "article" else 0
        score += 25 if node.tag == "main" else 0
        inner = text_of(node)
        if score and inner:
            density = _link_text_len(node) / max(len(inner), 1)
            score *= max(0.0, 1.0 - density)
        if score > best_score:
            best, best_score = node, score
    return best


def _run(text: str, bold: bool = False, italic: bool = False, href: str = "", mono: bool = False) -> dict | None:
    text = re.sub(r"[ \t\r\f\v]+", " ", text.replace("\n", " "))
    if not text.strip():
        return None
    return {"text": text, "b": bold, "i": italic, "href": href, "mono": mono}


def _inline_runs(node: Node, base: str, bold: bool = False, italic: bool = False,
                 href: str = "", mono: bool = False) -> list[dict]:
    runs: list[dict] = []
    for child in node.children:
        if isinstance(child, str):
            r = _run(child, bold, italic, href, mono)
            if r:
                runs.append(r)
            continue
        tag = child.tag
        if tag in DROP:
            continue
        if tag == "br":
            runs.append({"text": "\n", "b": bold, "i": italic, "href": href, "mono": mono})
            continue
        if tag == "img":
            alt = _attr(child, "alt", "title")
            if alt:
                runs.append({"text": f" [{alt}] ", "b": False, "i": True, "href": "", "mono": False})
            continue
        sub_href = href or (_safe_url(_attr(child, "href"), base) if tag == "a" else "")
        runs.extend(
            _inline_runs(
                child,
                base,
                bold or tag in ("b", "strong"),
                italic or tag in ("i", "em", "cite", "q"),
                sub_href,
                mono or tag in ("code", "kbd", "samp", "pre"),
            )
        )
    return runs


def _safe_url(url: str, base: str) -> str:
    url = (url or "").strip()
    if not url or url.startswith(("data:", "javascript:", "#")):
        return ""
    return urljoin(base, url)


def _normalize_text(runs: list[dict]) -> str:
    return re.sub(r"\s+", " ", "".join(r["text"] for r in runs)).strip()


def _image_block(node: Node, base: str, image_hook: Callable[[str], str] | None) -> dict | None:
    src = _attr(node, "src", "data-src", "data-original", "data-lazy-src", "data-url")
    if not src:
        srcset = _attr(node, "srcset", "data-srcset")
        if srcset:
            candidates = []
            for part in srcset.split(","):
                bits = part.strip().split()
                if bits:
                    weight = 0
                    if len(bits) > 1 and bits[1].endswith("w"):
                        weight = int(bits[1][:-1] or 0)
                    candidates.append((weight, bits[0]))
            if candidates:
                src = max(candidates)[1]
    src = _safe_url(src, base)
    if not src:
        return None
    try:
        width = int(float(_attr(node, "width") or 0))
    except ValueError:
        width = 0
    try:
        height = int(float(_attr(node, "height") or 0))
    except ValueError:
        height = 0
    if 0 < width <= 2 or 0 < height <= 2:
        return None
    if BAD_IMG_RE.search(urlparse(src).path or src):
        return None
    if image_hook is not None:
        local = image_hook(src)
        if not local:
            return None
        src = local
    return {"type": "image", "src": src, "alt": _attr(node, "alt", "title"),
            "width": width, "height": height, "caption": ""}


def _flatten_list(node: Node, base: str) -> list[list[dict]]:
    items: list[list[dict]] = []
    for child in node.children:
        if not isinstance(child, Node):
            continue
        if child.tag == "li":
            runs = _inline_runs(child, base)
            if _normalize_text(runs):
                items.append(runs)
        elif child.tag in ("ul", "ol"):
            items.extend(_flatten_list(child, base))
    return items


class _Blocks:
    def __init__(self, base: str, image_hook: Callable[[str], str] | None) -> None:
        self.base = base
        self.image_hook = image_hook
        self.blocks: list[dict] = []
        self.buffer: list[dict] = []

    def flush(self) -> None:
        if not self.buffer:
            return
        runs = self.buffer
        self.buffer = []
        while runs and runs[0]["text"].strip() == "":
            runs.pop(0)
        if not runs:
            return
        text = _normalize_text(runs)
        if len(text) < 2:
            return
        linked = sum(len(r["text"]) for r in runs if r["href"])
        if len(text) < 120 and linked / max(len(text), 1) > 0.5:
            return  # "Read more" / nav-link style line
        self.blocks.append({"type": "paragraph", "runs": runs})

    def add(self, block: dict | None) -> None:
        if block:
            self.blocks.append(block)


def _extract_blocks(root: Node, base: str, image_hook: Callable[[str], str] | None,
                    title: str) -> list[dict]:
    out = _Blocks(base, image_hook)

    def walk(node: Node) -> None:
        for child in node.children:
            if isinstance(child, str):
                out.buffer.append(_run(child) or {})
                out.buffer = [r for r in out.buffer if r]
                continue
            tag = child.tag
            if tag in DROP:
                continue
            if tag in INLINE:
                out.buffer.extend(_inline_runs(child, base))
            elif tag in HEADINGS:
                out.flush()
                text = text_of(child)
                if text and not (tag == "h1" and re.sub(r"\W+", "", text.lower()) == re.sub(r"\W+", "", title.lower())):
                    out.add({"type": "heading", "level": int(tag[1]), "text": text})
            elif tag == "p":
                out.flush()
                out.buffer = _inline_runs(child, base)
                out.flush()
            elif tag in ("ul", "ol"):
                out.flush()
                items = _flatten_list(child, base)
                items = [i for i in items if len(_normalize_text(i)) >= 3]
                if items:
                    out.add({"type": "list", "ordered": tag == "ol", "items": items})
            elif tag == "blockquote":
                out.flush()
                runs: list[dict] = []
                for inner in _walk(child):
                    if inner.tag == "p":
                        runs.extend(_inline_runs(inner, base))
                        runs.append({"text": " ", "b": False, "i": False, "href": "", "mono": False})
                if not runs:
                    runs = _inline_runs(child, base)
                if _normalize_text(runs):
                    out.add({"type": "quote", "runs": runs})
            elif tag == "pre":
                out.flush()
                code = "\n".join(
                    (c if isinstance(c, str) else _raw_text(c)).strip("\n") for c in child.children
                )
                code = re.sub(r"\n{3,}", "\n\n", code).strip()
                if code:
                    out.add({"type": "code", "text": code[:8000]})
            elif tag == "figure":
                out.flush()
                img = next((n for n in _walk(child) if n.tag == "img"), None)
                caption = ""
                cap_node = next((n for n in _walk(child) if n.tag == "figcaption"), None)
                if cap_node is not None:
                    caption = text_of(cap_node)
                if img is not None:
                    block = _image_block(img, base, image_hook)
                    if block:
                        block["caption"] = caption[:300]
                        out.add(block)
            elif tag == "img":
                out.flush()
                out.add(_image_block(child, base, image_hook))
            elif tag == "hr":
                out.flush()
                out.add({"type": "divider"})
            elif tag in ("table",):
                out.flush()
                rows = []
                for tr in (n for n in _walk(child) if n.tag == "tr"):
                    cells = [text_of(c) for c in tr.children if isinstance(c, Node) and c.tag in ("td", "th")]
                    cells = [c for c in cells if c]
                    if cells:
                        rows.append(" | ".join(cells))
                if rows:
                    out.add({"type": "code", "text": "\n".join(rows)[:6000]})
            else:
                walk(child)

    walk(root)
    out.flush()

    # Post-process: drop boundary noise, dedupe neighbours, merge bare paragraphs.
    cleaned: list[dict] = []
    for block in out.blocks:
        kind = block["type"]
        if kind == "paragraph" and not _normalize_text(block["runs"]):
            continue
        if kind == "divider" and not cleaned:
            continue
        if cleaned and cleaned[-1]["type"] == kind:
            prev = cleaned[-1]
            if kind in ("paragraph", "quote") and _normalize_text(prev["runs"]) == _normalize_text(block["runs"]):
                continue
        cleaned.append(block)
    while cleaned and cleaned[-1]["type"] == "divider":
        cleaned.pop()
    return cleaned


def _drop_byline_dup(blocks: list[dict], byline: str) -> list[dict]:
    if not byline:
        return blocks
    target = re.sub(r"[^a-z0-9]", "", byline.lower())
    out = []
    for block in blocks:
        if block["type"] == "paragraph":
            text = re.sub(r"[^a-z0-9]", "", _normalize_text(block["runs"]).lower())
            if text in (target, "by" + target, target + "bio"):
                continue
        out.append(block)
    return out


META_RE = re.compile(r"<meta\b[^>]+>", re.I)
TITLE_RE = re.compile(r"(?is)<title[^>]*>(.*?)</title>")
TIME_RE = re.compile(r"""<time\b[^>]+datetime\s*=\s*["']([^"']+)["']""", re.I)


def _meta(html_text: str, *names: str) -> str:
    for tag in META_RE.findall(html_text):
        key = re.search(r"""(?:property|name|itemprop)\s*=\s*["']([^"']+)["']""", tag, re.I)
        if not key or key.group(1).lower() not in names:
            continue
        content = re.search(r"""content\s*=\s*["']([^"']*)["']""", tag, re.I)
        if content and content.group(1).strip():
            return content.group(1).strip()
    return ""


def extract(html_text: str, base_url: str = "", image_hook: Callable[[str], str] | None = None) -> dict:
    """Extract a readable article from an HTML document."""
    from .feeds import strip_html, parse_date

    root = build_tree(html_text or "")
    title = _meta(html_text, "og:title", "twitter:title")
    if not title:
        m = TITLE_RE.search(html_text or "")
        if m:
            title = strip_html(m.group(1))
    if not title:
        node = next((n for n in _walk(root) if n.tag == "h1"), None)
        title = text_of(node) if node is not None else ""
    title = title.split(" | ")[0].split(" - ")[0].strip()[:300]

    byline = _meta(html_text, "author", "article:author", "twitter:creator", "byl", "dc.creator")
    byline = re.sub(r"^by\s+", "", byline, flags=re.I).strip()[:120]

    published = parse_date(_meta(html_text, "article:published_time", "og:published_time",
                                 "datepublished", "pubdate", "date"))
    if not published:
        m = TIME_RE.search(html_text or "")
        if m:
            published = parse_date(m.group(1))
    site_name = _meta(html_text, "og:site_name")

    _prune(root)
    body = next((n for n in _walk(root) if n.tag == "body"), root)
    for node in (n for n in _walk(body) if n.tag == "article"):
        pass
    best = _best_root(root)
    blocks = _extract_blocks(best, base_url, image_hook, title)
    if not any(b["type"] in ("paragraph", "list", "quote", "code") for b in blocks):
        blocks = _extract_blocks(body, base_url, image_hook, title)

    words = sum(len(_normalize_text(b.get("runs", [])).split()) for b in blocks if b["type"] in ("paragraph", "quote"))
    words += sum(len(b.get("text", "").split()) for b in blocks if b["type"] in ("heading", "code"))
    for b in blocks:
        if b["type"] == "list":
            words += sum(len(_normalize_text(i).split()) for i in b["items"])
    blocks = _drop_byline_dup(blocks, byline)
    hero = next((b["src"] for b in blocks if b["type"] == "image"), "")
    return {
        "title": title,
        "byline": byline,
        "site_name": site_name,
        "published": published,
        "blocks": blocks,
        "word_count": words,
        "hero": hero,
    }


def blocks_text(blocks: list[dict]) -> str:
    parts: list[str] = []
    for b in blocks:
        if b["type"] in ("paragraph", "quote"):
            parts.append(_normalize_text(b["runs"]))
        elif b["type"] == "heading":
            parts.append(b["text"])
        elif b["type"] == "code":
            parts.append(b["text"])
        elif b["type"] == "list":
            parts.extend(_normalize_text(i) for i in b["items"])
    return "\n".join(parts)
