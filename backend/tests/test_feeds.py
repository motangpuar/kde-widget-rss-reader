import unittest

from knewsd import feeds

RSS = b"""<?xml version="1.0"?>
<rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/"
     xmlns:media="http://search.yahoo.com/mrss/" xmlns:dc="http://purl.org/dc/elements/1.1/">
 <channel>
  <title>LWN &amp; friends</title>
  <link>https://lwn.net/</link>
  <item>
   <title>Kernel news &amp; patches</title>
   <link>/Articles/1</link>
   <guid isPermaLink="false">tag:lwn,2026:1</guid>
   <pubDate>Tue, 10 Nov 2026 14:30:00 +0000</pubDate>
   <dc:creator>Jonathan Corbet</dc:creator>
   <description>&lt;p&gt;Short &lt;b&gt;teaser&lt;/b&gt;.&lt;/p&gt;</description>
   <content:encoded>&lt;p&gt;Full body text.&lt;/p&gt;&lt;img src="/img/a.png"/&gt;</content:encoded>
   <media:thumbnail url="/img/thumb.jpg"/>
  </item>
 </channel>
</rss>"""

ATOM = b"""<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
 <title>Planet KDE</title>
 <link rel="alternate" href="https://planet.kde.org/"/>
 <entry>
  <title>Plasma 6.7 released</title>
  <id>urn:uuid:abc</id>
  <link rel="alternate" href="https://kde.org/announcements/6.7"/>
  <updated>2026-11-09T08:00:00Z</updated>
  <author><name>KDE Promo</name></author>
  <summary type="html">&lt;p&gt;Plasma 6.7 is here.&lt;/p&gt;</summary>
  <content type="html">&lt;div&gt;&lt;p&gt;Long form text of the announcement.&lt;/p&gt;&lt;/div&gt;</content>
 </entry>
</feed>"""

JSONFEED = b"""{"version":"https://jsonfeed.org/version/1.1","title":"JSON News",
"home_page_url":"https://example.org","items":[{"id":"1","url":"/a/1","title":"Hi",
"content_html":"<p>body</p>","date_published":"2026-11-01T10:00:00Z",
"image":"https://example.org/i.png"}]}"""

OPML = """<?xml version="1.0"?><opml version="2.0"><body>
<outline text="Tech">
  <outline text="LWN" type="rss" xmlUrl="https://lwn.net/headlines/rss"/>
</outline>
<outline text="Phoronix" type="rss" xmlUrl="https://phoronix.com/rss.php"/>
</body></opml>"""


class FeedParseTests(unittest.TestCase):
    def test_rss2(self):
        parsed = feeds.parse_feed(RSS, "https://lwn.net/headlines/rss")
        self.assertEqual(parsed["title"], "LWN & friends")
        self.assertEqual(parsed["site"], "https://lwn.net/")
        entry = parsed["entries"][0]
        self.assertEqual(entry["guid"], "tag:lwn,2026:1")
        self.assertEqual(entry["url"], "https://lwn.net/Articles/1")
        self.assertEqual(entry["author"], "Jonathan Corbet")
        self.assertEqual(entry["title"], "Kernel news & patches")
        self.assertIn("teaser", entry["summary"])
        self.assertIn("Full body text", entry["content"])
        self.assertEqual(entry["image"], "https://lwn.net/img/thumb.jpg")
        self.assertEqual(int(entry["published"]), 1794321000)

    def test_atom(self):
        parsed = feeds.parse_feed(ATOM, "https://planet.kde.org/atom.xml")
        self.assertEqual(parsed["title"], "Planet KDE")
        self.assertEqual(parsed["site"], "https://planet.kde.org/")
        entry = parsed["entries"][0]
        self.assertEqual(entry["guid"], "urn:uuid:abc")
        self.assertEqual(entry["url"], "https://kde.org/announcements/6.7")
        self.assertEqual(entry["author"], "KDE Promo")
        self.assertIn("Long form text", entry["content"])
        self.assertEqual(int(entry["published"]), 1794211200)

    def test_json_feed(self):
        parsed = feeds.parse_feed(JSONFEED, "https://example.org/feed.json")
        self.assertEqual(parsed["title"], "JSON News")
        self.assertEqual(parsed["entries"][0]["url"], "https://example.org/a/1")
        self.assertEqual(parsed["entries"][0]["image"], "https://example.org/i.png")

    def test_rejects_html(self):
        with self.assertRaises(ValueError):
            feeds.parse_feed(b"<!doctype html><html><body>nope</body></html>", "https://x")

    def test_date_formats(self):
        self.assertEqual(int(feeds.parse_date("Tue, 10 Nov 2026 14:30:00 +0000")), 1794321000)
        self.assertEqual(int(feeds.parse_date("2026-11-10T14:30:00Z")), 1794321000)
        self.assertEqual(feeds.parse_date("garbage"), 0.0)

    def test_discovery_prefers_alternate_link(self):
        page = ('<html><head><link rel="alternate" type="application/rss+xml" '
                'href="/feeds/main.xml"></head><body></body></html>')
        candidates = feeds.discover_feed_urls(page, "https://example.org/blog/post")
        self.assertEqual(candidates[0], "https://example.org/feeds/main.xml")
        self.assertIn("https://example.org/feed", candidates)

    def test_opml_roundtrip(self):
        parsed = feeds.parse_opml(OPML)
        self.assertEqual(len(parsed), 2)
        self.assertEqual(parsed[0]["folder"], "Tech")
        self.assertEqual(parsed[0]["title"], "LWN")
        xml = feeds.build_opml([
            {"url": "https://a", "title": "A", "folder": "Tech", "site": ""},
            {"url": "https://b", "title": "B", "folder": "", "site": ""},
        ])
        again = feeds.parse_opml(xml)
        self.assertEqual({e["url"] for e in again}, {"https://a", "https://b"})
        self.assertEqual({e["url"]: e["folder"] for e in again}["https://a"], "Tech")


if __name__ == "__main__":
    unittest.main()
