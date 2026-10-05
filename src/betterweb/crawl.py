"""Crawlee crawl: HTTP first, Playwright+Chromium only for known JS hosts."""

from __future__ import annotations

import argparse
import asyncio
from pathlib import Path

from betterweb.extract import (
    ENQUEUE_LIMIT,
    MAX_CRAWL_DEPTH,
    NOISE_GLOBS,
    extract_from_html,
    followable_citations,
    should_expand,
    should_follow,
    should_follow_citations,
)
from betterweb.ingest import ingest_extract, is_js_host
from betterweb.judge import PageJudge, probe as judge_probe
from betterweb.store import PageStore, default_db_path

# Article/essay URLs — not site homepages or help centers.
SEEDS = [
    "https://danluu.com/web-bloat/",
    "https://idlewords.com/talks/website_obesity.htm",
    "https://ciechanow.ski/mechanical-watch/",
    "https://ciechanow.ski/airfoil/",
    "https://jvns.ca/blog/2016/03/16/tcpdump-is-amazing/",
    "https://www.joelonsoftware.com/2000/04/06/things-you-should-never-do-part-i/",
    "https://paulgraham.com/greatwork.html",
    "https://worrydream.com/KillMath/",
    "https://aphyr.com/posts/340-hexing-the-technical-interview",
    "https://www.benkuhn.net/abyss/",
    "https://en.wikipedia.org/wiki/Operating_system",
    "https://en.wikipedia.org/wiki/PageRank",
    "https://en.wikipedia.org/wiki/Unix",
    "https://en.wikipedia.org/wiki/Hypertext",
    "https://www.youtube.com/watch?v=26QPDBe-NB8",
]

TRACKER_PATTERNS = [
    "*doubleclick*",
    "*googlesyndication*",
    "*google-analytics*",
    "*googletagmanager*",
    "*facebook.net*",
    "*scorecardresearch*",
    "*adsystem*",
    "*hotjar*",
]


def _html_from_http(context) -> str:
    soup = getattr(context, "soup", None)
    if soup is not None:
        decode = getattr(soup, "decode", None)
        if callable(decode):
            return decode()
        return str(soup)
    response = getattr(context, "http_response", None)
    if response is None:
        return ""
    raw = getattr(response, "text", None)
    if isinstance(raw, str) and raw:
        return raw
    return ""


def _noise_globs():
    from crawlee import Glob

    return [Glob(pattern) for pattern in NOISE_GLOBS]


def _enqueue_kwargs(source_url: str, *, collect_js: list[str] | None, js_only: bool):
    def transform(options):
        url = options["url"].split("#", 1)[0]
        options = {**options, "url": url}
        if not should_follow(source_url, url):
            return "skip"
        js = is_js_host(url)
        if collect_js is not None and js:
            collect_js.append(url)
            return "skip"
        if js_only and not js:
            return "skip"
        return options

    return {
        "strategy": "all",
        "limit": ENQUEUE_LIMIT,
        "exclude": _noise_globs(),
        "transform_request_function": transform,
    }


def _citation_requests(source_url: str, html: str, *, collect_js: list[str] | None, js_only: bool) -> list[str]:
    kept: list[str] = []
    for dest in followable_citations(html, source_url):
        if not should_follow(source_url, dest):
            continue
        js = is_js_host(dest)
        if collect_js is not None and js:
            collect_js.append(dest)
            continue
        if js_only and not js:
            continue
        kept.append(dest)
    return kept


async def _grow_frontier(context, url: str, html: str, *, collect_js: list[str] | None, js_only: bool) -> None:
    if should_expand(url, html):
        await context.enqueue_links(**_enqueue_kwargs(url, collect_js=collect_js, js_only=js_only))
        return
    if should_follow_citations(url, html):
        dests = _citation_requests(url, html, collect_js=collect_js, js_only=js_only)
        if dests:
            await context.add_requests(dests)


async def _open_queue(alias: str, storage):
    from crawlee.storages import RequestQueue

    return await RequestQueue.open(alias=alias, storage_client=storage)


async def _run(seeds: list[str], max_requests: int, db_path: str | None, no_judge: bool) -> int:
    from crawlee import Request
    from crawlee.crawlers import BeautifulSoupCrawler, PlaywrightCrawler
    from crawlee.storage_clients import MemoryStorageClient

    store = PageStore(path=Path(db_path) if db_path else None)
    judge = None if no_judge else PageJudge(lazy=True)
    print(judge_probe(judge), flush=True)
    playwright_urls: list[str] = [s for s in seeds if is_js_host(s)]

    http_storage = MemoryStorageClient()
    soup = BeautifulSoupCrawler(
        max_requests_per_crawl=max_requests,
        max_crawl_depth=MAX_CRAWL_DEPTH,
        respect_robots_txt_file=True,
        storage_client=http_storage,
        request_manager=await _open_queue("betterweb-http", http_storage),
    )

    @soup.router.default_handler
    async def on_http(context) -> None:
        url = context.request.url
        if is_js_host(url):
            playwright_urls.append(url)
            return
        html = _html_from_http(context)
        extract = extract_from_html(html, url=url, source="http")
        ingest_extract(store, extract, fetch_engine="http", judge=judge)
        await _grow_frontier(context, url, html, collect_js=playwright_urls, js_only=False)

    http_seeds = [s for s in seeds if not is_js_host(s)]
    if http_seeds:
        await soup.run(http_seeds)

    playwright_urls = list(dict.fromkeys(playwright_urls))
    if playwright_urls:
        pw_storage = MemoryStorageClient()
        browser = PlaywrightCrawler(
            max_requests_per_crawl=max_requests,
            max_crawl_depth=MAX_CRAWL_DEPTH,
            respect_robots_txt_file=True,
            browser_type="chromium",
            storage_client=pw_storage,
            request_manager=await _open_queue("betterweb-playwright", pw_storage),
        )

        @browser.pre_navigation_hook
        async def block_bloat(context) -> None:
            await context.block_requests(url_patterns=TRACKER_PATTERNS)

        @browser.router.default_handler
        async def on_js(context) -> None:
            html = await context.page.content()
            extract = extract_from_html(html, url=context.request.url, source="playwright")
            ingest_extract(store, extract, fetch_engine="playwright", judge=judge)
            await _grow_frontier(
                context, context.request.url, html, collect_js=None, js_only=True
            )

        await browser.run([Request.from_url(u) for u in playwright_urls])

    count = store.count()
    store.close()
    return count


def main() -> None:
    parser = argparse.ArgumentParser(description="Crawl seeds into the BetterWeb SQLite index.")
    parser.add_argument("--max-requests", type=int, default=40)
    parser.add_argument("--db", default=None)
    parser.add_argument(
        "--no-judge",
        action="store_true",
        help="Skip GLiNER and score with the regex heuristic.",
    )
    parser.add_argument("seeds", nargs="*", default=SEEDS)
    args = parser.parse_args()
    n = asyncio.run(_run(args.seeds, args.max_requests, args.db, args.no_judge))
    print(f"index pages={n} db={args.db or default_db_path()}")


if __name__ == "__main__":
    main()
