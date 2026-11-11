import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from unittest import mock

from knewsd import api as api_mod
from knewsd.fetch import FetchError
from knewsd import feeds as feedmod
from knewsd.db import Store

FEED = b"""<?xml version="1.0"?><rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/">
<channel><title>Test Feed</title><link>https://example.org/</link>
<item><title>First post</title><link>https://example.org/p1</link>
<guid>p1</guid><pubDate>Tue, 10 Nov 2026 14:30:00 +0000</pubDate>
<description>&lt;p&gt;Teaser one.&lt;/p&gt;</description>
<content:encoded>&lt;p&gt;Teaser one.&lt;/p&gt;</content:encoded></item>
<item><title>Second post</title><link>https://example.org/p2</link>
<guid>p2</guid><pubDate>Wed, 11 Nov 2026 14:30:00 +0000</pubDate>
<description>&lt;p&gt;Teaser two.&lt;/p&gt;</description></item>
</channel></rss>"""

PAGE = """<html><head><title>First post</title><meta name="author" content="Ann"></head>
<body><article><h1>First post</h1>
<p>Real article body that is long enough to be considered readable content by the extractor, because it keeps going with several more clauses and commas, and it does not stop early.</p>
<p>A second paragraph adds more substance so the word count crosses the minimum extraction threshold comfortably.</p>
<p>Third paragraph continues describing the situation with enough detail to be useful for a reader.</p>
<p>Fourth paragraph wraps up the story with a closing remark about future work.</p>
</article></body></html>"""


class ApiTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.tmp.name) / "test.db")

        def fake_get(url, etag=None, last_modified=None, timeout=20, max_bytes=None):
            if url.endswith("/broken") or "broken" in url:
                raise FetchError(f"HTTP 404 for {url}")
            if url.endswith("/p1"):
                return {"status": 200, "body": PAGE.encode(), "url": url,
                        "headers": {"content-type": "text/html; charset=utf-8"}}
            return {"status": 200, "body": FEED, "url": url,
                    "headers": {"content-type": "application/rss+xml", "etag": '"v1"'}}

        self.patch = mock.patch("knewsd.fetch.http_get", side_effect=fake_get)
        self.patch.start()
        self.icon_patch = mock.patch("knewsd.fetch.cache_image", return_value="")
        self.icon_patch.start()
        self.server = api_mod.build_server(self.store, "127.0.0.1", 0)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.patch.stop()
        self.icon_patch.stop()
        self.store.db.close()
        self.tmp.cleanup()

    # ------------------------------------------------------------------ utils
    def get(self, path):
        request = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}")
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                body = response.read()
                ctype = response.headers.get("Content-Type", "")
                return response.status, (json.loads(body) if "json" in ctype else body)
        except urllib.error.HTTPError as exc:
            return exc.code, json.loads(exc.read() or b"{}")

    def post(self, path, payload, headers=None):
        data = json.dumps(payload).encode()
        request = urllib.request.Request(
            f"http://127.0.0.1:{self.port}{path}", data=data, method="POST",
            headers={"Content-Type": "application/json", "X-Knews-Client": "plasma", **(headers or {})},
        )
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                return response.status, json.loads(response.read() or b"{}")
        except urllib.error.HTTPError as exc:
            return exc.code, json.loads(exc.read() or b"{}")

    def add_feed(self):
        status, body = self.post("/api/feeds", {"url": "https://example.org/feed.xml", "folder": "Tech"})
        self.assertEqual(status, 200, body)
        return body["feed"]["id"]

    # ------------------------------------------------------------------ tests
    def test_health_and_state(self):
        status, body = self.get("/api/health")
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])
        status, state = self.get("/api/state")
        self.assertEqual(status, 200)
        self.assertEqual(state["counts"]["feeds"], 0)
        self.assertIn("prefs", state)

    def test_validate_single_url(self):
        status, body = self.get("/api/validate?url=https://example.org/feed.xml")
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"], body)
        self.assertEqual(body["title"], "Test Feed")
        self.assertEqual(body["entries"], 2)
        self.assertFalse(body["existing"])

        self.add_feed()
        status, body = self.get("/api/validate?url=https://example.org/feed.xml")
        self.assertTrue(body["existing"])

        status, body = self.get("/api/validate?url=https://example.org/broken")
        self.assertEqual(status, 200)
        self.assertFalse(body["ok"])
        self.assertTrue(body["error"])

    def test_validate_many_urls(self):
        status, body = self.post("/api/validate", {"urls": ["https://example.org/feed.xml",
                                                            "https://example.org/broken",
                                                            "https://example.org/feed.xml"]})
        self.assertEqual(status, 200, body)
        results = body["results"]
        self.assertEqual(len(results), 2)          # duplicates collapsed
        self.assertTrue(results[0]["ok"])
        self.assertFalse(results[1]["ok"])

    def test_bulk_add_feeds(self):
        status, body = self.post("/api/feeds/bulk",
                                 {"urls": ["https://example.org/feed.xml",
                                           "https://example.org/broken"],
                                  "folder": "Batch"})
        self.assertEqual(status, 200, body)
        self.assertEqual(body["added"], 1)
        outcomes = {r["url"]: r["ok"] for r in body["results"]}
        self.assertTrue(outcomes["https://example.org/feed.xml"])
        self.assertFalse(outcomes["https://example.org/broken"])
        self.assertEqual(body["state"]["counts"]["feeds"], 1)
        self.assertEqual(body["state"]["feeds"][0]["folder"], "Batch")

    def test_export_opml_falls_back_when_target_unwritable(self):
        from unittest import mock

        from knewsd import api as api_mod

        path = Path(self.tmp.name) / "blocked" / "export.opml"
        real_write = Path.write_bytes

        def guarded(self, data):
            if str(self).startswith(str(path.parent)):
                raise OSError(30, "Read-only file system")
            return real_write(self, data)

        with mock.patch.object(Path, "write_bytes", guarded):
            payload = api_mod.save_opml(self.store, str(path))

        self.assertTrue(payload["ok"])
        self.assertTrue(payload["fallback"])
        self.assertEqual(payload["requested"], str(path))
        self.assertTrue(Path(payload["path"]).is_file())
        self.assertTrue(Path(payload["path"]).read_bytes().startswith(b"<?xml"))

    def test_state_exposes_export_dir(self):
        status, payload = self.get("/api/state")
        self.assertEqual(status, 200)
        self.assertTrue(payload["export_dir"].endswith("Downloads"))

    def test_export_opml_to_file(self):
        self.add_feed()
        target = Path(self.tmp.name) / "exports" / "backup.opml"
        status, body = self.post("/api/opml/save", {"path": str(target.with_suffix(""))})
        self.assertEqual(status, 200, body)
        self.assertTrue(body["ok"])
        self.assertEqual(Path(body["path"]), target)
        self.assertGreaterEqual(body["feeds"], 1)
        self.assertIn("<opml", target.read_text(encoding="utf-8"))

        status, body = self.post("/api/opml/save", {"path": "relative.opml"})
        self.assertEqual(status, 400)
        self.assertFalse(body.get("ok", False))

    def test_add_feed_and_list_items(self):
        feed_id = self.add_feed()
        status, listing = self.get(f"/api/items?view=unread&feed={feed_id}")
        self.assertEqual(status, 200)
        self.assertEqual(listing["total"], 2)
        titles = [i["title"] for i in listing["items"]]
        self.assertEqual(titles, ["Second post", "First post"])
        self.assertEqual(listing["items"][0]["feed_title"], "Test Feed")
        status, state = self.get("/api/state")
        self.assertEqual(state["counts"]["unread"], 2)
        self.assertEqual(state["folders"], ["Tech"])

    def test_item_detail_extracts_and_marks_read(self):
        self.add_feed()
        _, listing = self.get("/api/items?view=unread")
        item_id = [i for i in listing["items"] if i["title"] == "First post"][0]["id"]
        status, detail = self.get(f"/api/item?id={item_id}&read=1")
        self.assertEqual(status, 200)
        self.assertIn(detail["extract_state"], ("ok", "partial"))
        self.assertTrue(detail["read"])
        self.assertTrue(any(b["type"] == "paragraph" for b in detail["blocks"]))
        self.assertGreater(detail["word_count"], 20)
        _, state = self.get("/api/state")
        self.assertEqual(state["counts"]["unread"], 1)

    def test_star_and_mark_all(self):
        feed_id = self.add_feed()
        _, listing = self.get("/api/items?view=unread")
        item_id = listing["items"][0]["id"]
        status, body = self.post("/api/item", {"id": item_id, "starred": True, "read": True})
        self.assertEqual(status, 200)
        self.assertEqual(body["counts"]["starred"], 1)
        _, starred = self.get("/api/items?view=starred")
        self.assertEqual(starred["total"], 1)
        status, body = self.post("/api/mark-all", {"feed": feed_id})
        self.assertEqual(status, 200)
        self.assertEqual(body["changed"], 1)
        _, unread = self.get("/api/items?view=unread")
        self.assertEqual(unread["total"], 0)

    def test_prefs_roundtrip_and_validation(self):
        status, body = self.post("/api/prefs", {"prefs": {"reader_theme": "sepia", "bogus": 1}})
        self.assertEqual(status, 200)
        self.assertEqual(body["prefs"]["reader_theme"], "sepia")
        self.assertNotIn("bogus", body["prefs"])
        _, state = self.get("/api/state")
        self.assertEqual(state["prefs"]["reader_theme"], "sepia")

    def test_opml_export_and_import(self):
        self.add_feed()
        status, body = self.get("/api/opml")
        self.assertEqual(status, 200)
        self.assertIn(b"example.org/feed.xml", body)
        parsed = feedmod.parse_opml(body.decode())
        self.assertEqual(parsed[0]["folder"], "Tech")
        opml = ('<?xml version="1.0"?><opml version="2.0"><body>'
                '<outline text="X" type="rss" xmlUrl="https://example.org/other.xml"/>'
                '</body></opml>')
        status, result = self.post("/api/opml", {"opml": opml})
        self.assertEqual(status, 200, result)
        self.assertEqual(len(self.store.feeds()), 2)

    def test_guard_blocks_mutations_without_header(self):
        status, body = self.post("/api/refresh", {}, headers={"X-Knews-Client": ""})
        self.assertEqual(status, 403)
        status, body = self.post("/api/refresh", {}, headers={"Origin": "https://evil.example"})
        self.assertEqual(status, 403)

    def test_refresh_flow(self):
        self.add_feed()
        status, body = self.post("/api/refresh", {})
        self.assertEqual(status, 200)
        self.assertTrue(body["started"])
        for _ in range(50):
            _, status_body = self.get("/api/refresh/status")
            if not status_body["running"]:
                break
            threading.Event().wait(0.05)
        self.assertFalse(status_body["running"])
        self.assertEqual(status_body["done"], 1)

    def test_discover_direct_feed(self):
        status, data = self.get("/api/discover?url=example.org/feed.xml")
        self.assertEqual(status, 200)
        self.assertTrue(data["ok"])
        self.assertTrue(data["direct"])
        self.assertEqual(data["candidates"][0]["title"], "Test Feed")

    def test_discover_html_page(self):
        page = b"""<html><head>
        <link rel="alternate" type="application/rss+xml" href="/feed.xml"/></head>
        <body>blog</body></html>"""

        def fake_get(url, etag=None, last_modified=None, timeout=20, max_bytes=None):
            if url.endswith("/feed.xml"):
                return {"status": 200, "body": FEED, "url": url, "headers": {}}
            return {"status": 200, "body": page, "url": url, "headers": {}}

        self.patch.stop()
        with mock.patch("knewsd.fetch.http_get", side_effect=fake_get):
            status, data = self.get("/api/discover?url=https://blog.example/")
        self.patch.start()
        self.assertEqual(status, 200)
        self.assertFalse(data["direct"])
        urls = [c["url"] for c in data["candidates"]]
        self.assertTrue(any(u.endswith("/feed.xml") for u in urls), urls)

    def test_discover_reports_unreachable(self):
        self.patch.stop()
        with mock.patch("knewsd.fetch.http_get", side_effect=OSError("boom")):
            status, data = self.get("/api/discover?url=down.example")
        self.patch.start()
        self.assertEqual(status, 200)
        self.assertFalse(data["ok"])
        self.assertIn("could not reach", data["message"])

    def test_feed_icon_column_and_state(self):
        status, data = self.post("/api/feeds", {"url": "https://example.org/feed.xml"})
        self.assertEqual(status, 200)
        feed = [f for f in data["state"]["feeds"] if f["url"] == "https://example.org/feed.xml"][0]
        self.assertIn("icon", feed)
        self.assertIsInstance(feed["icon"], str)

    def test_delete_feed_removes_items(self):
        feed_id = self.add_feed()
        status, _ = self.post("/api/feeds/delete", {"id": feed_id})
        self.assertEqual(status, 200)
        self.assertEqual(self.store.feeds(), [])
        _, listing = self.get("/api/items?view=all")
        self.assertEqual(listing["total"], 0)


if __name__ == "__main__":
    unittest.main()
