import sqlite3
from pathlib import Path

from betterweb.extract import STORE_CHARS, PageExtract
from betterweb.ingest import ingest_extract
from betterweb.store import PageStore


def test_upsert_and_bm25(tmp_path: Path):
    store = PageStore(tmp_path / "index.sqlite")
    extract = PageExtract(
        source="test",
        title="Web Bloat",
        text="The web is getting slower. Modern frameworks send megabytes of JavaScript.",
        html='<html><body><p>The web is getting slower.</p><a href="https://example.org/paper">paper</a></body></html>',
        url="https://danluu.com/web-bloat/",
    )
    row, cites = ingest_extract(store, extract, fetch_engine="http")
    assert row.craftrank_score >= 0
    assert "https://example.org/paper" in cites
    hits = store.bm25("javascript frameworks", limit=10)
    assert hits
    assert hits[0][0].url == extract.url
    store.close()


def test_sales_page_ranks_below_essay(tmp_path: Path):
    store = PageStore(tmp_path / "index.sqlite")
    ingest_extract(
        store,
        PageExtract(
            source="test",
            title="How kernels schedule threads",
            text="I measured scheduler latency on Linux 6.1. Figure 2 shows the runqueue.",
            url="https://example.org/kernel",
        ),
        fetch_engine="http",
    )
    ingest_extract(
        store,
        PageExtract(
            source="test",
            title="Buy my course",
            text="Enroll now. Add to cart. Limited time offer. Buy my course today.",
            url="https://example.org/course",
        ),
        fetch_engine="http",
    )
    from betterweb.search import search_index

    result = search_index(store, "kernel schedule", limit=8)
    urls = [h["url"] for h in result["hits"]]
    assert urls[0] == "https://example.org/kernel"
    store.close()


def test_ingest_clips_stored_extract(tmp_path: Path):
    store = PageStore(tmp_path / "index.sqlite")
    text = "Intro paragraph about Unix pipes. " + ("later " * 2000)
    ingest_extract(
        store,
        PageExtract(
            source="test",
            title="Unix",
            text=text,
            url="https://ex.test/unix",
        ),
        fetch_engine="http",
    )
    row = store.get("https://ex.test/unix")
    assert row is not None
    assert len(row.content) <= STORE_CHARS
    assert row.content.startswith("Intro paragraph about Unix pipes.")
    hits = store.bm25("unix pipes", limit=5)
    assert hits and hits[0][0].url == "https://ex.test/unix"
    store.close()


def test_migrate_clips_content_and_drops_embeddings(tmp_path: Path):
    path = tmp_path / "old.sqlite"
    conn = sqlite3.connect(path)
    conn.executescript(
        """
        CREATE TABLE pages (
            url TEXT PRIMARY KEY,
            title TEXT NOT NULL DEFAULT '',
            content TEXT NOT NULL DEFAULT '',
            video_url TEXT,
            commercial_count INTEGER NOT NULL DEFAULT 0,
            commercial_bias REAL NOT NULL DEFAULT 0,
            ad_use REAL NOT NULL DEFAULT 0,
            commercial_promotion REAL NOT NULL DEFAULT 0,
            citation_use REAL NOT NULL DEFAULT 0,
            thought_quality REAL NOT NULL DEFAULT 0,
            authorship_likeness TEXT NOT NULL DEFAULT 'unknown',
            craftrank_score REAL NOT NULL DEFAULT 0,
            embedding BLOB,
            fetch_engine TEXT NOT NULL DEFAULT 'http',
            decisions_json TEXT NOT NULL DEFAULT '{}',
            crawled_at TEXT NOT NULL,
            needs_enrichment INTEGER NOT NULL DEFAULT 1
        );
        CREATE VIRTUAL TABLE pages_fts USING fts5(
            title, content, content='pages', content_rowid='rowid'
        );
        """
    )
    long = "alpha " + ("word " * 4000)
    conn.execute(
        "INSERT INTO pages (url, title, content, embedding, crawled_at) VALUES (?, ?, ?, ?, ?)",
        ("https://ex.test/long", "Long", long, b"\x00" * 3072, "2020-01-01"),
    )
    conn.execute("INSERT INTO pages_fts(rowid, title, content) SELECT rowid, title, content FROM pages")
    conn.commit()
    conn.close()

    store = PageStore(path)
    row = store.get("https://ex.test/long")
    assert row is not None
    assert len(row.content) <= STORE_CHARS
    assert row.content.startswith("alpha ")
    cols = {info[1] for info in store._conn.execute("PRAGMA table_info(pages)")}
    assert "embedding" not in cols
    hits = store.bm25("alpha", limit=5)
    assert hits and hits[0][0].url == "https://ex.test/long"
    assert store._freelist_pages() < 32
    store.close()
