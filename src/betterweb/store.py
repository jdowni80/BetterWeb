"""SQLite page index with FTS5 BM25."""

from __future__ import annotations

import json
import os
import random
import re
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

SCHEMA = """
CREATE TABLE IF NOT EXISTS pages (
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
    fetch_engine TEXT NOT NULL DEFAULT 'http',
    decisions_json TEXT NOT NULL DEFAULT '{}',
    crawled_at TEXT NOT NULL,
    needs_enrichment INTEGER NOT NULL DEFAULT 1
);
CREATE VIRTUAL TABLE IF NOT EXISTS pages_fts USING fts5(
    title, content, content='pages', content_rowid='rowid'
);
CREATE TABLE IF NOT EXISTS crawl_queue (
    url TEXT PRIMARY KEY,
    queued_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS crawl_seen (
    url TEXT PRIMARY KEY,
    seen_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS crawl_harvested (
    url TEXT PRIMARY KEY,
    harvested_at TEXT NOT NULL
);
"""

INDEX_SIZE_LIMIT = 500 * 1024 * 1024
INDEX_SIZE_TARGET = 450 * 1024 * 1024


def default_db_path() -> Path:
    env = os.environ.get("BETTERWEB_INDEX")
    if env:
        return Path(env)
    root = Path(__file__).resolve().parents[2]
    path = root / "data" / "runtime" / "index.sqlite"
    path.parent.mkdir(parents=True, exist_ok=True)
    return path


@dataclass
class PageRow:
    url: str
    title: str
    content: str
    video_url: str | None
    commercial_count: int
    commercial_bias: float
    ad_use: float
    commercial_promotion: float
    citation_use: float
    thought_quality: float
    authorship_likeness: str
    craftrank_score: float
    fetch_engine: str
    decisions: dict[str, Any]
    crawled_at: str
    needs_enrichment: bool = True

    def to_hit(self, relevance: float, score: float, query: str = "") -> dict[str, Any]:
        from betterweb.extract import make_snippet

        snippet = make_snippet(self.content, query)
        return {
            "url": self.url,
            "title": self.title or self.url,
            "snippet": snippet,
            "video_url": self.video_url,
            "commercial_count": self.commercial_count,
            "craftrank_score": round(self.craftrank_score, 4),
            "relevance": round(relevance, 4),
            "score": round(score, 4),
            "authorship_likeness": self.authorship_likeness,
            "decisions": self.decisions,
        }


class PageStore:
    def __init__(self, path: Path | None = None) -> None:
        self.path = path or default_db_path()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._conn = sqlite3.connect(self.path, check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        self._conn.execute("PRAGMA foreign_keys = ON")
        self._conn.execute("PRAGMA journal_mode=WAL")
        self._conn.executescript(SCHEMA)
        self._migrate()
        self._conn.commit()

    def _migrate(self) -> None:
        from betterweb.extract import clip_store_text

        cols = {info[1] for info in self._conn.execute("PRAGMA table_info(pages)")}
        if "needs_enrichment" not in cols:
            self._conn.execute(
                "ALTER TABLE pages ADD COLUMN needs_enrichment INTEGER NOT NULL DEFAULT 1"
            )
        dropped = False
        if "embedding" in cols:
            dropped = True
            try:
                self._conn.execute("ALTER TABLE pages DROP COLUMN embedding")
            except sqlite3.OperationalError:
                self._conn.execute("UPDATE pages SET embedding = NULL")
        clipped = False
        for row in self._conn.execute("SELECT url, content FROM pages").fetchall():
            text = clip_store_text(row["content"] or "")
            if text != (row["content"] or ""):
                self._conn.execute("UPDATE pages SET content = ? WHERE url = ?", (text, row["url"]))
                clipped = True
        if clipped:
            self._rebuild_fts()
        self._reclaim_space(force=clipped or dropped)

    def _rebuild_fts(self) -> None:
        self._conn.execute("INSERT INTO pages_fts(pages_fts) VALUES('rebuild')")

    def _freelist_pages(self) -> int:
        return int(self._conn.execute("PRAGMA freelist_count").fetchone()[0])

    def _reclaim_space(self, *, force: bool = False) -> None:
        self._conn.commit()
        free = self._freelist_pages()
        if free == 0 or (not force and free < 32):
            return
        try:
            self._conn.execute("VACUUM")
        except sqlite3.OperationalError:
            return
        self._conn.commit()

    def close(self) -> None:
        self._conn.close()

    def upsert(self, row: PageRow) -> None:
        from betterweb.extract import clip_store_text

        content = clip_store_text(row.content)
        payload = (
            row.url,
            row.title,
            content,
            row.video_url,
            row.commercial_count,
            row.commercial_bias,
            row.ad_use,
            row.commercial_promotion,
            row.citation_use,
            row.thought_quality,
            row.authorship_likeness,
            row.craftrank_score,
            row.fetch_engine,
            json.dumps(row.decisions),
            row.crawled_at,
            1 if row.needs_enrichment else 0,
        )
        existing = self._conn.execute("SELECT rowid FROM pages WHERE url = ?", (row.url,)).fetchone()
        self._conn.execute(
            """
            INSERT INTO pages (
                url, title, content, video_url, commercial_count, commercial_bias,
                ad_use, commercial_promotion, citation_use, thought_quality,
                authorship_likeness, craftrank_score, fetch_engine,
                decisions_json, crawled_at, needs_enrichment
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(url) DO UPDATE SET
                title=excluded.title,
                content=excluded.content,
                video_url=excluded.video_url,
                commercial_count=excluded.commercial_count,
                commercial_bias=excluded.commercial_bias,
                ad_use=excluded.ad_use,
                commercial_promotion=excluded.commercial_promotion,
                citation_use=excluded.citation_use,
                thought_quality=excluded.thought_quality,
                authorship_likeness=excluded.authorship_likeness,
                craftrank_score=excluded.craftrank_score,
                fetch_engine=excluded.fetch_engine,
                decisions_json=excluded.decisions_json,
                crawled_at=excluded.crawled_at,
                needs_enrichment=excluded.needs_enrichment
            """,
            payload,
        )
        if existing:
            self._conn.execute(
                "UPDATE pages_fts SET title = ?, content = ? WHERE rowid = ?",
                (row.title, content, existing["rowid"]),
            )
        else:
            new = self._conn.execute("SELECT rowid FROM pages WHERE url = ?", (row.url,)).fetchone()
            self._conn.execute(
                "INSERT INTO pages_fts(rowid, title, content) VALUES (?, ?, ?)",
                (new["rowid"], row.title, content),
            )
        self._conn.commit()

    def save_enrichment(self, row: PageRow) -> None:
        self._conn.execute(
            """
            UPDATE pages SET
                commercial_count = ?,
                commercial_bias = ?,
                ad_use = ?,
                commercial_promotion = ?,
                citation_use = ?,
                thought_quality = ?,
                authorship_likeness = ?,
                craftrank_score = ?,
                decisions_json = ?,
                needs_enrichment = ?
            WHERE url = ?
            """,
            (
                row.commercial_count,
                row.commercial_bias,
                row.ad_use,
                row.commercial_promotion,
                row.citation_use,
                row.thought_quality,
                row.authorship_likeness,
                row.craftrank_score,
                json.dumps(row.decisions),
                1 if row.needs_enrichment else 0,
                row.url,
            ),
        )
        self._conn.commit()

    def get(self, url: str) -> PageRow | None:
        row = self._conn.execute("SELECT * FROM pages WHERE url = ?", (url,)).fetchone()
        return _row_from_sql(row) if row else None

    def next_enrichment(self) -> PageRow | None:
        row = self._conn.execute(
            "SELECT * FROM pages WHERE needs_enrichment = 1 ORDER BY crawled_at ASC LIMIT 1"
        ).fetchone()
        return _row_from_sql(row) if row else None

    def pending_enrichment(self) -> int:
        return int(self._conn.execute("SELECT COUNT(*) FROM pages WHERE needs_enrichment = 1").fetchone()[0])

    def count(self) -> int:
        return int(self._conn.execute("SELECT COUNT(*) FROM pages").fetchone()[0])

    def db_bytes(self) -> int:
        self._conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        main = self.path.stat().st_size if self.path.exists() else 0
        wal = Path(str(self.path) + "-wal")
        shm = Path(str(self.path) + "-shm")
        extra = (wal.stat().st_size if wal.exists() else 0) + (shm.stat().st_size if shm.exists() else 0)
        return main + extra

    def delete(self, url: str) -> None:
        row = self._conn.execute("SELECT rowid FROM pages WHERE url = ?", (url,)).fetchone()
        if not row:
            return
        self._conn.execute("DELETE FROM pages_fts WHERE rowid = ?", (row["rowid"],))
        self._conn.execute("DELETE FROM pages WHERE url = ?", (url,))
        self._conn.commit()

    def evict_to_budget(self, limit: int = INDEX_SIZE_LIMIT, target: int = INDEX_SIZE_TARGET) -> int:
        size = self.db_bytes()
        if size <= limit:
            return 0
        need = max(size - target, 1)
        rows = self._conn.execute(
            "SELECT url, length(content) AS n FROM pages ORDER BY craftrank_score ASC, crawled_at ASC"
        ).fetchall()
        removed = 0
        freed = 0
        for row in rows:
            if freed >= need:
                break
            freed += int(row["n"]) + 2048
            self.delete(row["url"])
            removed += 1
        if self.db_bytes() > target:
            self._conn.execute(
                "DELETE FROM crawl_seen WHERE url NOT IN (SELECT url FROM pages)"
            )
            self._conn.execute("DELETE FROM crawl_queue")
            self._conn.commit()
        if removed or self.db_bytes() > target:
            self._conn.execute("VACUUM")
            self._conn.commit()
        return removed

    QUEUE_CAP = 400

    def enqueue(self, url: str, *, force: bool = False) -> None:
        queued = int(self._conn.execute("SELECT COUNT(*) FROM crawl_queue").fetchone()[0])
        if not force and queued >= self.QUEUE_CAP:
            return
        self._conn.execute(
            "INSERT OR IGNORE INTO crawl_queue(url, queued_at) VALUES (?, ?)",
            (url, now_iso()),
        )
        self._conn.commit()

    def unsee(self, url: str) -> None:
        self._conn.execute("DELETE FROM crawl_seen WHERE url = ?", (url,))
        self._conn.commit()

    def unharvest(self, url: str) -> None:
        self._conn.execute("DELETE FROM crawl_harvested WHERE url = ?", (url,))
        self._conn.commit()

    def note_visit(self, url: str) -> str:
        dest = urlparse(url)
        if dest.scheme not in {"http", "https"} or not dest.netloc:
            return "ignore"
        url = url.split("#", 1)[0]
        if self.get(url):
            self.unharvest(url)
            return "hub"
        self.unsee(url)
        self.enqueue(url, force=True)
        return "queued"

    def update_text(self, url: str, *, title: str, content: str) -> bool:
        from betterweb.extract import clip_store_text

        existing = self._conn.execute(
            "SELECT rowid, title, content FROM pages WHERE url = ?", (url,)
        ).fetchone()
        if existing is None:
            return False
        title = title or existing["title"]
        content = clip_store_text(content)
        rid = existing["rowid"]
        self._conn.execute(
            "INSERT INTO pages_fts(pages_fts, rowid, title, content) VALUES('delete', ?, ?, ?)",
            (rid, existing["title"], existing["content"]),
        )
        self._conn.execute(
            "UPDATE pages SET title = ?, content = ? WHERE url = ?",
            (title, content, url),
        )
        self._conn.execute(
            "INSERT INTO pages_fts(rowid, title, content) VALUES (?, ?, ?)",
            (rid, title, content),
        )
        self._conn.commit()
        return True

    def refresh_snippet(self, url: str, html: str = "") -> bool:
        from betterweb.extract import extract_from_html, extract_from_url

        dest = urlparse(url)
        if dest.scheme not in {"http", "https"} or not dest.netloc:
            return False
        url = url.split("#", 1)[0]
        if not self.get(url):
            return False
        try:
            extract = extract_from_html(html, url=url, source="visit") if html else extract_from_url(url)
        except Exception:
            return False
        text = extract.text
        if not text.strip():
            return False
        return self.update_text(url, title=extract.title, content=text)

    def mark_index_seen(self) -> None:
        self._conn.execute(
            "INSERT OR IGNORE INTO crawl_seen(url, seen_at) SELECT url, crawled_at FROM pages"
        )
        self._conn.commit()

    def mark_harvested(self, url: str) -> None:
        self._conn.execute(
            "INSERT OR REPLACE INTO crawl_harvested(url, harvested_at) VALUES (?, ?)",
            (url, now_iso()),
        )
        self._conn.commit()

    def next_harvest(self) -> str | None:
        row = self._conn.execute(
            """
            SELECT url FROM pages
            WHERE url NOT IN (SELECT url FROM crawl_harvested)
            ORDER BY RANDOM()
            LIMIT 1
            """
        ).fetchone()
        return str(row["url"]) if row else None

    def dequeue(self, avoid_host: str | None = None) -> str | None:
        rows = self._conn.execute("SELECT url FROM crawl_queue").fetchall()
        if not rows:
            return None
        urls = [str(row["url"]) for row in rows]
        avoid = (avoid_host or "").lower()
        hopped = [url for url in urls if urlparse(url).netloc.lower() != avoid] if avoid else urls
        url = random.choice(hopped or urls)
        self._conn.execute("DELETE FROM crawl_queue WHERE url = ?", (url,))
        self._conn.commit()
        return url

    def mark_seen(self, url: str) -> None:
        self._conn.execute(
            "INSERT OR REPLACE INTO crawl_seen(url, seen_at) VALUES (?, ?)",
            (url, now_iso()),
        )
        self._conn.commit()

    def was_seen(self, url: str) -> bool:
        row = self._conn.execute("SELECT 1 FROM crawl_seen WHERE url = ?", (url,)).fetchone()
        return row is not None

    def bm25(self, query: str, limit: int = 100) -> list[tuple[PageRow, float]]:
        tokens = re.findall(r"[A-Za-z0-9]{2,}", query)
        if not tokens:
            return []
        match = " OR ".join(tokens)
        rows = self._conn.execute(
            """
            SELECT pages.*, bm25(pages_fts) AS rank
            FROM pages_fts
            JOIN pages ON pages.rowid = pages_fts.rowid
            WHERE pages_fts MATCH ?
            ORDER BY rank
            LIMIT ?
            """,
            (match, limit),
        ).fetchall()
        out: list[tuple[PageRow, float]] = []
        for row in rows:
            # FTS5 bm25: lower is better. Flip to a 0–1-ish relevance.
            rank = float(row["rank"])
            relevance = 1.0 / (1.0 + max(0.0, rank + 8.0))
            out.append((_row_from_sql(row), relevance))
        return out


def _row_from_sql(row: sqlite3.Row) -> PageRow:
    return PageRow(
        url=row["url"],
        title=row["title"],
        content=row["content"],
        video_url=row["video_url"],
        commercial_count=int(row["commercial_count"]),
        commercial_bias=float(row["commercial_bias"]),
        ad_use=float(row["ad_use"]),
        commercial_promotion=float(row["commercial_promotion"]),
        citation_use=float(row["citation_use"]),
        thought_quality=float(row["thought_quality"]),
        authorship_likeness=row["authorship_likeness"],
        craftrank_score=float(row["craftrank_score"]),
        fetch_engine=row["fetch_engine"],
        decisions=json.loads(row["decisions_json"] or "{}"),
        crawled_at=row["crawled_at"],
        needs_enrichment=bool(row["needs_enrichment"]) if "needs_enrichment" in row.keys() else True,
    )


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()
