from pathlib import Path

from betterweb.indexd import run, step
from betterweb.ingest import index_visit
from betterweb.store import PageRow, PageStore, now_iso


def _row(url: str, score: float, blob: str) -> PageRow:
    return PageRow(
        url=url,
        title=url,
        content=blob,
        video_url=None,
        commercial_count=0,
        commercial_bias=0,
        ad_use=0,
        commercial_promotion=0,
        citation_use=0,
        thought_quality=0,
        authorship_likeness="unknown",
        craftrank_score=score,
        fetch_engine="http",
        decisions={},
        crawled_at=now_iso(),
    )


def test_evicts_lowest_craft_until_under_budget(tmp_path: Path):
    store = PageStore(tmp_path / "index.sqlite")
    filler = "word " * 20_000
    store.upsert(_row("https://low.example/a", 1.0, filler))
    store.upsert(_row("https://high.example/b", 9.0, filler))
    store.upsert(_row("https://mid.example/c", 5.0, filler))
    size = store.db_bytes()
    removed = store.evict_to_budget(limit=size - 1, target=max(size - 3_000, 1))
    assert removed == 1
    urls = {row["url"] for row in store._conn.execute("SELECT url FROM pages")}
    assert urls == {"https://high.example/b", "https://mid.example/c"}
    store.close()


def test_indexd_playwright_js_hosts(tmp_path: Path, monkeypatch):
    html = """
    <html><head><title>The Library of Letourneau - YouTube</title></head>
    <body><p>Videos about libraries and long-form reading from this channel.</p></body></html>
    """
    monkeypatch.setattr("betterweb.browse.playwright_html", lambda url: (html, None, url))
    store = PageStore(tmp_path / "index.sqlite")
    store.enqueue("https://www.youtube.com/@TheLibraryofLetourneau/videos")
    assert step(store) == "ok"
    url = "https://www.youtube.com/@TheLibraryofLetourneau/videos"
    row = store.get(url)
    assert row is not None
    assert "libraries" in row.content
    assert store.was_seen(url)
    store.close()


def test_enqueue_and_dequeue(tmp_path: Path):
    store = PageStore(tmp_path / "index.sqlite")
    store.enqueue("https://danluu.com/web-bloat/")
    store.enqueue("https://danluu.com/web-bloat/")
    assert store.dequeue() == "https://danluu.com/web-bloat/"
    assert store.dequeue() is None
    store.close()


def test_step_can_teleport_to_unharvested_hub(tmp_path: Path, monkeypatch):
    store = PageStore(tmp_path / "index.sqlite")
    store.upsert(_row("https://en.wikipedia.org/wiki/Unix", 8.0, "word " * 800))
    store.enqueue("https://ieer.org/about-ieer/")
    monkeypatch.setattr("betterweb.indexd.random.random", lambda: 0.0)
    monkeypatch.setattr(
        "betterweb.indexd._harvest_one",
        lambda store, url: f"harvest {url}",
    )
    assert step(store) == "harvest https://en.wikipedia.org/wiki/Unix"
    store.close()


def test_visit_indexes_new_url_immediately(tmp_path: Path):
    store = PageStore(tmp_path / "index.sqlite")
    store.enqueue("https://other.example/waiting")
    html = """
    <html><body><article>
      <p>Unix is a family of multitasking, multiuser computer operating systems that derive from AT&amp;T Unix.</p>
      <a href="https://example.org/citation">citation</a>
    </article></body></html>
    """
    assert index_visit(store, "https://ex.test/unix#section", html) == "indexed"
    row = store.get("https://ex.test/unix")
    assert row is not None
    assert "multitasking" in row.content
    waiting = {store.dequeue() for _ in range(4)}
    waiting.discard(None)
    assert "https://ex.test/unix" not in waiting
    assert "https://other.example/waiting" in waiting
    store.close()


def test_visit_indexes_js_host_via_playwright(tmp_path: Path, monkeypatch):
    html = """
    <html><head><title>The Library of Letourneau - YouTube</title></head>
    <body><p>Channel videos about libraries and long-form reading.</p></body></html>
    """
    monkeypatch.setattr("betterweb.browse.playwright_html", lambda url: (html, None, url))
    store = PageStore(tmp_path / "index.sqlite")
    url = "https://www.youtube.com/@TheLibraryofLetourneau/videos"
    assert index_visit(store, url) == "indexed"
    row = store.get(url)
    assert row is not None
    assert "Letourneau" in row.title
    assert "libraries" in row.content
    hits = store.bm25("letourneau library", limit=5)
    assert hits and hits[0][0].url == url
    store.close()


def test_visit_refreshes_stored_snippet(tmp_path: Path):
    store = PageStore(tmp_path / "index.sqlite")
    store.upsert(_row("https://en.wikipedia.org/wiki/Unix", 8.0, "Toggle the table of contents\n44 languages"))
    html = """
    <html><body><main>
      <div class="vector-toc">Toggle the table of contents</div>
      <p>Unix is a family of multitasking, multiuser computer operating systems that derive from the original AT&amp;T Unix.</p>
    </main></body></html>
    """
    assert store.refresh_snippet("https://en.wikipedia.org/wiki/Unix", html)
    row = store.get("https://en.wikipedia.org/wiki/Unix")
    assert row is not None
    assert row.craftrank_score == 8.0
    assert "multitasking" in row.content
    assert "Toggle" not in row.content
    store.close()


def test_visit_keeps_craftrank_on_existing_page(tmp_path: Path):
    store = PageStore(tmp_path / "index.sqlite")
    store.upsert(_row("https://en.wikipedia.org/wiki/Unix", 8.0, "old chrome text"))
    html = """
    <html><body><main>
      <p>Unix is a family of multitasking, multiuser computer operating systems that derive from the original AT&amp;T Unix.</p>
    </main></body></html>
    """
    assert index_visit(store, "https://en.wikipedia.org/wiki/Unix", html) == "updated"
    row = store.get("https://en.wikipedia.org/wiki/Unix")
    assert row is not None
    assert row.craftrank_score == 8.0
    assert "multitasking" in row.content
    hits = store.bm25("multitasking", limit=5)
    assert hits and hits[0][0].url == "https://en.wikipedia.org/wiki/Unix"
    store.close()


def test_visit_unharvests_when_extract_fails(tmp_path: Path, monkeypatch):
    store = PageStore(tmp_path / "index.sqlite")
    store.upsert(_row("https://en.wikipedia.org/wiki/Unix", 8.0, "word " * 200))
    store.mark_harvested("https://en.wikipedia.org/wiki/Unix")

    def boom(_url: str):
        raise RuntimeError("offline")

    monkeypatch.setattr("betterweb.ingest.extract_from_url", boom)
    assert index_visit(store, "https://en.wikipedia.org/wiki/Unix") == "hub"
    assert store.next_harvest() == "https://en.wikipedia.org/wiki/Unix"
    assert store.dequeue() is None
    store.close()


def test_visit_ignores_non_http(tmp_path: Path):
    store = PageStore(tmp_path / "index.sqlite")
    assert index_visit(store, "ftp://example.com/file") == "ignore"
    store.close()


def test_dequeue_hops_hosts(tmp_path: Path):
    store = PageStore(tmp_path / "index.sqlite")
    store.enqueue("https://danluu.com/web-bloat/")
    store.enqueue("https://en.wikipedia.org/wiki/Unix")
    hopped = {store.dequeue(avoid_host="danluu.com") for _ in range(1)}
    assert hopped == {"https://en.wikipedia.org/wiki/Unix"}
    store.close()


def test_run_once_skips_fetch_on_battery(tmp_path: Path, monkeypatch):
    monkeypatch.setattr("betterweb.power.on_ac_power", lambda: False)
    store = PageStore(tmp_path / "index.sqlite")
    store.enqueue("https://example.org/essay")
    run(store, once=True)
    store = PageStore(tmp_path / "index.sqlite")
    assert store.count() == 0
    store.close()
