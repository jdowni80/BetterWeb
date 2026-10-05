"""Turn extracted HTML into a stored page row."""

from __future__ import annotations

from urllib.parse import urlparse

from betterweb.extract import PageExtract, clip_store_text, followable_citations
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
