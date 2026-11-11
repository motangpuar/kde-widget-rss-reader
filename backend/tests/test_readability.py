import unittest

from knewsd import readability

ARTICLE = """<!doctype html><html><head>
<title>Plasma 6.7 Arrives | KDE.news</title>
<meta property="og:title" content="Plasma 6.7 Arrives">
<meta name="author" content="By Jane Doe">
<meta property="article:published_time" content="2026-11-09T08:00:00Z">
<meta property="og:site_name" content="KDE.news">
<style>.x{color:red}</style>
<script>var track = 1;</script>
</head><body>
<header class="site-header"><nav><a href="/">Home</a><a href="/news">News</a></nav></header>
<div class="share-buttons"><a href="/share">Share this</a></div>
<main>
 <article>
  <h1>Plasma 6.7 Arrives</h1>
  <p class="byline">By Jane Doe</p>
  <p>Plasma 6.7 is the newest release of the <a href="/plasma">Plasma</a> desktop, and it brings
     a long list of refinements for panels, widgets, and the Wayland session overall.</p>
  <p>Performance work landed across the board, <strong>cutting</strong> idle wakeups and
     improving <em>power</em> usage on laptops by a noticeable margin.</p>
  <h2>What is new</h2>
  <ul>
    <li>Reworked widget explorer with keyboard navigation.</li>
    <li>New screen locking defaults.</li>
    <li><a href="https://kde.org/">KDE</a> branding refresh.</li>
  </ul>
  <img src="/img/plasma.png" data-src="/img/plasma-lazy.png" alt="Plasma desktop" width="1200" height="675">
  <figure>
    <img src="/img/chart.png" alt="chart">
    <figcaption>Benchmark results for the year.</figcaption>
  </figure>
  <blockquote><p>The best release we have shipped so far.</p></blockquote>
  <p>Read more: <a href="/more">More coverage</a></p>
  <p>Short trail paragraph closing the article with a few words.</p>
 </article>
 <aside class="related-posts"><p>Related: ten other stories you may enjoy reading today</p></aside>
</main>
<footer class="site-footer"><p>Copyright 2026 KDE e.V. All rights reserved worldwide.</p></footer>
<script>window.ads = [];</script>
</body></html>"""


class ReadabilityTests(unittest.TestCase):
    def test_extracts_core_blocks(self):
        doc = readability.extract(ARTICLE, "https://kde.news/2026/plasma-6-7/")
        self.assertEqual(doc["title"], "Plasma 6.7 Arrives")
        self.assertEqual(doc["byline"], "Jane Doe")
        self.assertNotIn("Jane Doe", readability.blocks_text(doc["blocks"]))
        self.assertEqual(int(doc["published"]), 1794211200)
        kinds = [b["type"] for b in doc["blocks"]]
        self.assertIn("paragraph", kinds)
        self.assertIn("heading", kinds)
        self.assertIn("list", kinds)
        self.assertIn("image", kinds)
        self.assertIn("quote", kinds)
        # h1 duplicates the headline and must be dropped
        self.assertNotIn("h1-heading", kinds)
        self.assertNotIn("Plasma 6.7 Arrives", [b.get("text") for b in doc["blocks"] if b["type"] == "heading"])

    def test_noise_removed(self):
        doc = readability.extract(ARTICLE, "https://kde.news/x")
        text = readability.blocks_text(doc["blocks"])
        self.assertNotIn("Copyright 2026", text)
        self.assertNotIn("Related: ten other stories", text)
        self.assertNotIn("var track", text)
        self.assertNotIn("Share this", text)

    def test_links_and_runs(self):
        doc = readability.extract(ARTICLE, "https://kde.news/2026/plasma-6-7/")
        first = next(b for b in doc["blocks"] if b["type"] == "paragraph"
                     and "newest release" in readability.blocks_text([b]))
        hrefs = [r["href"] for r in first["runs"] if r["href"]]
        self.assertEqual(hrefs, ["https://kde.news/plasma"])
        bold = [r for b in doc["blocks"] if b["type"] == "paragraph"
                for r in b["runs"] if r["b"]]
        self.assertTrue(any("cutting" in r["text"] for r in bold))
        self.assertTrue(all("\n" not in r["text"] for b in doc["blocks"]
                            if b["type"] == "paragraph" for r in b["runs"]))

    def test_images_absolute_and_lazy(self):
        doc = readability.extract(ARTICLE, "https://kde.news/post/")
        images = [b for b in doc["blocks"] if b["type"] == "image"]
        self.assertEqual(images[0]["src"], "https://kde.news/img/plasma.png")
        self.assertEqual(images[0]["alt"], "Plasma desktop")
        self.assertEqual(images[1]["caption"], "Benchmark results for the year.")
        self.assertEqual(doc["hero"], images[0]["src"])

    def test_image_hook_can_drop_images(self):
        doc = readability.extract(ARTICLE, "https://kde.news/p/", image_hook=lambda url: "")
        self.assertFalse([b for b in doc["blocks"] if b["type"] == "image"])

    def test_link_only_paragraph_dropped(self):
        doc = readability.extract(ARTICLE, "https://kde.news/p/")
        text = readability.blocks_text(doc["blocks"])
        self.assertNotIn("More coverage", text)
        self.assertIn("Short trail paragraph", text)

    def test_word_count_and_empty_input(self):
        doc = readability.extract(ARTICLE, "https://kde.news/p/")
        self.assertGreater(doc["word_count"], 40)
        empty = readability.extract("", "https://x/")
        self.assertEqual(empty["blocks"], [])

    def test_lists_flatten(self):
        doc = readability.extract(ARTICLE, "https://kde.news/p/")
        listing = next(b for b in doc["blocks"] if b["type"] == "list")
        self.assertEqual(len(listing["items"]), 3)
        self.assertFalse(listing["ordered"])


if __name__ == "__main__":
    unittest.main()
