"""Lightweight background indexer: HTTP + heuristics, one page at a time, 500 MB cap."""

from __future__ import annotations

import argparse
import os
import random
import time
from pathlib import Path
from urllib.parse import urlparse

from betterweb.crawl import SEEDS
from betterweb.extract import (
    content_link_urls,
    extract_from_url,
    followable_citations,
    sample_walk_urls,
    should_expand,
    should_follow,
    should_follow_citations,
)
from betterweb.ingest import ingest_extract, is_js_host
from betterweb.store import INDEX_SIZE_LIMIT, PageStore

SLEEP_SECONDS = 1.0
PID_NAME = "indexd.pid"
TELEPORT_P = 0.35
_last_host: str | None = None


def _parent_gone() -> bool:
    raw = os.environ.get("BETTERWEB_PARENT_PID")
    if not raw:
        return False
    try:
        os.kill(int(raw), 0)
    except OSError:
        return True
    return False


def _pid_path(store: PageStore) -> Path:
    return store.path.parent / PID_NAME


def _claim_lock(store: PageStore) -> Path | None:
    path = _pid_path(store)
    if path.exists():
        try:
            old = int(path.read_text().strip())
            os.kill(old, 0)
            return None
        except (ValueError, OSError):
            path.unlink(missing_ok=True)
    path.write_text(str(os.getpid()))
    return path


def _seed_queue(store: PageStore) -> None:
    for url in SEEDS:
        if is_js_host(url) or store.was_seen(url):
            continue
        store.enqueue(url)


def _remember_host(url: str) -> None:
    global _last_host
    _last_host = urlparse(url).netloc.lower() or None


def _walk_dests(source: str, html: str, *, citations_only: bool) -> list[str]:
    raw = followable_citations(html, source, limit=80) if citations_only else content_link_urls(html, source)
    dests: list[str] = []
    for dest in raw:
        if is_js_host(dest) or not should_follow(source, dest):
            continue
        dests.append(dest)
    return dests


def _enqueue_from(store: PageStore, source: str, html: str) -> None:
    if should_expand(source, html):
        dests = [dest for dest in _walk_dests(source, html, citations_only=False) if not store.was_seen(dest)]
        for dest in sample_walk_urls(source, dests):
            store.enqueue(dest)
        return
    if should_follow_citations(source, html):
        dests = [dest for dest in _walk_dests(source, html, citations_only=True) if not store.was_seen(dest)]
        for dest in sample_walk_urls(source, dests):
            store.enqueue(dest)


def _read_html(url: str) -> str:
    extract = extract_from_url(url)
    return extract


def _fetch_one(store: PageStore, url: str) -> str:
    if is_js_host(url) or store.was_seen(url):
        store.mark_seen(url)
        return "skip-js" if is_js_host(url) else "skip"
    try:
        extract = _read_html(url)
    except Exception as exc:
        store.mark_seen(url)
        return f"fail {exc}"
    ingest_extract(store, extract, fetch_engine="http", judge=None)
    store.mark_seen(url)
    store.mark_harvested(url)
    _enqueue_from(store, url, extract.html)
    store.evict_to_budget()
    _remember_host(url)
    return "ok"


def _harvest_one(store: PageStore, url: str) -> str:
    if is_js_host(url):
        store.mark_harvested(url)
        return "skip-js"
    try:
        extract = _read_html(url)
    except Exception as exc:
        store.mark_harvested(url)
        return f"harvest-fail {exc}"
    _enqueue_from(store, url, extract.html)
    store.mark_harvested(url)
    _remember_host(url)
    return "harvest"


def step(store: PageStore) -> str:
    harvest = store.next_harvest()
    if harvest and random.random() < TELEPORT_P:
        return _harvest_one(store, harvest)
    url = store.dequeue(avoid_host=_last_host)
    if url is None:
        _seed_queue(store)
        url = store.dequeue(avoid_host=_last_host)
    if url is not None:
        return _fetch_one(store, url)
    if harvest is None:
        return "idle"
    return _harvest_one(store, harvest)


def run(store: PageStore, *, once: bool = False, sleep: float = SLEEP_SECONDS) -> None:
    lock = _claim_lock(store)
    if lock is None:
        print(f"indexd already running ({_pid_path(store).read_text().strip()})", flush=True)
        return
    try:
        try:
            os.nice(15)
        except OSError:
            pass
        store.mark_index_seen()
        print(
            f"indexd db={store.path} cap={INDEX_SIZE_LIMIT // (1024 * 1024)}MB sleep={sleep}s",
            flush=True,
        )
        while True:
            if _parent_gone():
                print("indexd parent gone", flush=True)
                return
            status = step(store)
            print(
                f"indexd {status} pages={store.count()} bytes={store.db_bytes()}",
                flush=True,
            )
            if once:
                return
            wait = sleep if status != "idle" else max(sleep, 20.0)
            time.sleep(wait + random.uniform(0, 1.5))
    finally:
        lock.unlink(missing_ok=True)
        store.close()


def main() -> None:
    parser = argparse.ArgumentParser(description="Continuously crawl into the BetterWeb index.")
    parser.add_argument("--db", default=None)
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--sleep", type=float, default=SLEEP_SECONDS)
    args = parser.parse_args()
    store = PageStore(path=Path(args.db) if args.db else None)
    run(store, once=args.once, sleep=args.sleep)


if __name__ == "__main__":
    main()
