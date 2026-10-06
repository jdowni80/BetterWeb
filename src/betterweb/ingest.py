"""Turn extracted HTML into a stored page row."""

from __future__ import annotations

from urllib.parse import urlparse

from betterweb.extract import (
    PageExtract,
    clip_store_text,
    content_link_urls,
    extract_from_html,
    extract_from_url,
    followable_citations,
    sample_walk_urls,
    should_expand,
    should_follow,
    should_follow_citations,
)
from betterweb.judge import PageJudge, heuristic_decisions
from betterweb.score import craftrank_score
from betterweb.store import PageRow, PageStore, now_iso

_JS_HOSTS = (
    "youtube.com",
    "www.youtube.com",
    "m.youtube.com",
    "substack.com",
    "youtu.be",
)


def is_js_host(url: str) -> bool:
    host = urlparse(url).netloc.lower()
    if host.endswith(".substack.com"):
        return True
    return any(host == h or host.endswith("." + h) for h in _JS_HOSTS)


def is_thin(extract: PageExtract) -> bool:
    return len(extract.text.strip()) < 200


def commercial_count(decisions: dict) -> int:
    ads = float(decisions.get("ad_use") or 0)
    promo = float(decisions.get("commercial_promotion") or 0)
    return int(round(4 * ads + 2 * promo))


def ingest_extract(
    store: PageStore,
    extract: PageExtract,
    *,
    fetch_engine: str,
    judge: PageJudge | None = None,
) -> tuple[PageRow, list[str]]:
    url = extract.url or ""
    backend = "heuristic"
    if judge is not None:
        judged = judge.judge_text(extract.judge_input, title=extract.title, url=url, source="crawl")
        decisions = judged["decisions"]
        backend = str(judged.get("model") or "heuristic")
    else:
        decisions = heuristic_decisions(extract.title, extract.text, url)
    decisions = {**decisions, "_backend": backend}
    score = craftrank_score(decisions)
    cites = followable_citations(extract.html, url) if extract.html else []
    video = url if is_js_host(url) and "youtube" in urlparse(url).netloc else None
    row = PageRow(
        url=url,
        title=extract.title,
        content=clip_store_text(extract.text),
        video_url=video,
        commercial_count=commercial_count(decisions),
        commercial_bias=float(decisions.get("commercial_bias") or 0),
        ad_use=float(decisions.get("ad_use") or 0),
        commercial_promotion=float(decisions.get("commercial_promotion") or 0),
        citation_use=float(decisions.get("citation_use") or 0),
        thought_quality=float(decisions.get("thought_quality") or 0),
        authorship_likeness=str(decisions.get("authorship_likeness") or "unknown"),
        craftrank_score=score,
        fetch_engine=fetch_engine,
        decisions=decisions,
        crawled_at=now_iso(),
        needs_enrichment=backend == "heuristic",
    )
    store.upsert(row)
    return row, cites


def enqueue_walk(store: PageStore, source: str, html: str) -> None:
    if should_expand(source, html):
        raw = content_link_urls(html, source)
    elif should_follow_citations(source, html):
        raw = followable_citations(html, source, limit=80)
    else:
        return
    dests = [
        dest
        for dest in raw
        if should_follow(source, dest) and not store.was_seen(dest)
    ]
    for dest in sample_walk_urls(source, dests):
        store.enqueue(dest)


def _extract_for_visit(url: str, html: str) -> PageExtract | None:
    try:
        if is_js_host(url):
            from betterweb.browse import playwright_html

            rendered, _err, final = playwright_html(url)
            if rendered:
                return extract_from_html(rendered, url=final or url, source="playwright")
            if html:
                return extract_from_html(html, url=url, source="visit")
            return None
        if html:
            return extract_from_html(html, url=url, source="visit")
        return extract_from_url(url)
    except Exception:
        return None


def index_visit(store: PageStore, url: str, html: str = "", title: str = "") -> str:
    dest = urlparse(url)
    if dest.scheme not in {"http", "https"} or not dest.netloc:
        return "ignore"
    url = url.split("#", 1)[0]
    extract = _extract_for_visit(url, html)
    if extract is None:
        if store.get(url):
            store.unharvest(url)
            return "hub"
        extract = PageExtract(source="visit", title=title or url, text="", url=url)
    if title and not extract.title:
        extract.title = title
    landed = (extract.url or url).split("#", 1)[0]
    extract.url = landed
    body = extract.text.strip()
    if not body:
        extract.title = extract.title or title or landed
        extract.text = extract.title
        walk = False
    else:
        walk = bool(extract.html)
    existing = store.get(landed)
    if existing:
        store.update_text(landed, title=extract.title, content=extract.text)
        status = "updated"
    else:
        engine = "playwright" if is_js_host(landed) else "visit"
        ingest_extract(store, extract, fetch_engine=engine, judge=None)
        status = "indexed"
    store.mark_seen(url)
    if landed != url:
        store.mark_seen(landed)
    if walk:
        enqueue_walk(store, landed, extract.html)
        store.mark_harvested(landed)
    elif existing:
        store.unharvest(landed)
    else:
        store.mark_harvested(landed)
    return status
