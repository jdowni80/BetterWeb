"""Lightweight background indexer: HTTP + heuristics, one page at a time, 500 MB cap."""

from __future__ import annotations

import argparse
import os
import random
import time
from pathlib import Path
from urllib.parse import urlparse

from betterweb.crawl import SEEDS
from betterweb.extract import extract_from_html, extract_from_url
from betterweb import power
from betterweb.ingest import enqueue_walk, ingest_extract, is_js_host
from betterweb.store import INDEX_SIZE_LIMIT, PageStore

SLEEP_SECONDS = 1.0
SLEEP_BATTERY = 20.0
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
        if store.was_seen(url):
            continue
        store.enqueue(url)


def _remember_host(url: str) -> None:
    global _last_host
    _last_host = urlparse(url).netloc.lower() or None


def _enqueue_from(store: PageStore, source: str, html: str) -> None:
    enqueue_walk(store, source, html)


def _extract_page(url: str):
    if is_js_host(url):
        from betterweb.browse import playwright_html

        html, err, final = playwright_html(url)
        if not html:
            raise RuntimeError(err or "playwright empty")
        return extract_from_html(html, url=final or url, source="playwright")
    return extract_from_url(url)


def _fetch_one(store: PageStore, url: str) -> str:
    if store.was_seen(url):
        store.mark_seen(url)
        return "skip"
    try:
        extract = _extract_page(url)
    except Exception as exc:
        store.mark_seen(url)
        return f"fail {exc}"
    engine = "playwright" if is_js_host(url) else "http"
    ingest_extract(store, extract, fetch_engine=engine, judge=None)
    landed = extract.url or url
    store.mark_seen(url)
    if landed != url:
        store.mark_seen(landed)
    store.mark_harvested(landed)
    _enqueue_from(store, landed, extract.html)
    store.evict_to_budget()
    _remember_host(url)
    return "ok"


def _harvest_one(store: PageStore, url: str) -> str:
    try:
        extract = _extract_page(url)
    except Exception as exc:
        store.mark_harvested(url)
        return f"harvest-fail {exc}"
    _enqueue_from(store, extract.url or url, extract.html)
    store.mark_harvested(extract.url or url)
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
            if not power.on_ac_power():
                print("indexd on-battery", flush=True)
                if once:
                    return
                time.sleep(SLEEP_BATTERY)
                continue
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
