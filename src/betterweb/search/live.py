"""Live web search: discover candidates, fetch pages, CraftRank-blend results."""

from __future__ import annotations

import hashlib
import re
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from typing import Any
from urllib.parse import urljoin, urlparse

from bs4 import BeautifulSoup

from betterweb.craftrank import CraftEdge, CraftNode, blend_with_craftrank, craftrank, prior_from_hints
from betterweb.engines import fetch_with_lightpanda, lightpanda_path
from betterweb.extract import extract_from_html, extract_from_url
from betterweb.judge import PageJudge, ranking_hints
from betterweb.schema import badges_from_decisions
from betterweb.search.heuristics import heuristic_decisions

_SKIP_HOSTS = {
    "youtube.com",
    "www.youtube.com",
    "facebook.com",
    "www.facebook.com",
    "twitter.com",
    "x.com",
    "instagram.com",
    "tiktok.com",
    "pinterest.com",
}


@dataclass
class Candidate:
    title: str
    url: str
    snippet: str
    source_rank: int


def discover_candidates(query: str, *, max_results: int = 10) -> list[Candidate]:
    """Discover candidate URLs from the public web (via ddgs meta-search)."""
    from ddgs import DDGS

    out: list[Candidate] = []
    seen: set[str] = set()
    with DDGS() as ddgs:
        rows = list(ddgs.text(query, max_results=max_results * 2))
    for row in rows:
        url = str(row.get("href") or row.get("url") or "").strip()
        title = str(row.get("title") or "").strip()
        snippet = str(row.get("body") or row.get("snippet") or "").strip()
        if not url or not url.startswith("http"):
            continue
        host = urlparse(url).netloc.lower()
        if host in _SKIP_HOSTS or any(host.endswith("." + h) for h in _SKIP_HOSTS):
            continue
        if url in seen:
            continue
        seen.add(url)
        out.append(
            Candidate(
                title=title or url,
                url=url,
                snippet=snippet,
                source_rank=len(out),
            )
        )
        if len(out) >= max_results:
            break
    return out


def _doc_id(url: str) -> str:
    host = urlparse(url).netloc or "page"
    digest = hashlib.sha1(url.encode("utf-8")).hexdigest()[:10]
    return f"{host}:{digest}"


def _fetch_page(url: str, *, prefer_lightpanda: bool) -> tuple[str, str, str, str]:
    """Return title, text, html, fetch_engine."""
    if prefer_lightpanda and lightpanda_path():
        try:
            html = fetch_with_lightpanda(url)
            page = extract_from_html(html, url=url, source="lightpanda")
            return page.title or url, page.text, html, "lightpanda"
        except Exception:
            pass
    page = extract_from_url(url, timeout=12)
    return page.title or url, page.text, "", "http"


def _extract_links(html: str, base_url: str) -> list[str]:
    if not html:
        return []
    soup = BeautifulSoup(html, "lxml")
    links: list[str] = []
    for a in soup.find_all("a", href=True):
        href = str(a.get("href", "")).strip()
        if not href or href.startswith("#") or href.startswith("javascript:"):
            continue
        abs_url = urljoin(base_url, href)
        if abs_url.startswith("http"):
            links.append(abs_url.split("#", 1)[0])
    return links


def live_search(
    query: str,
    *,
    max_candidates: int = 8,
    limit: int = 8,
    prefer_lightpanda: bool = False,
    use_judge: bool = False,
    judge: PageJudge | None = None,
) -> dict[str, Any]:
    """
    Discover → fetch → judge/heuristic → CraftRank among result set → score.

    Ranking stays BetterWeb-owned; meta-search is only candidate discovery.
    """
    candidates = discover_candidates(query, max_results=max_candidates)
    if not candidates:
        return {
            "query": query,
            "mode": "live",
            "count": 0,
            "hits": [],
            "errors": ["No web candidates discovered"],
            "ranking": "bm25 * craft * human-quality penalties",
        }

    fetched: list[dict[str, Any]] = []
    errors: list[str] = []

    def work(c: Candidate) -> dict[str, Any] | None:
        try:
            title, text, html, engine = _fetch_page(
                c.url, prefer_lightpanda=prefer_lightpanda
            )
            if len(text.strip()) < 40:
                text = c.snippet or text
            if use_judge and judge is not None:
                decisions = judge.judge_text(
                    f"Title: {title}\n\nURL: {c.url}\n\n{text[:3500]}",
                    title=title,
                    url=c.url,
                    source="live",
                ).decisions
            else:
                decisions = heuristic_decisions(title, text, c.url)
            return {
                "id": _doc_id(c.url),
                "title": title or c.title,
                "url": c.url,
                "text": text,
                "snippet_src": c.snippet,
                "html": html,
                "fetch_engine": engine,
                "source_rank": c.source_rank,
                "decisions": decisions,
                "out_links": _extract_links(html, c.url) if html else [],
            }
        except Exception as exc:  # noqa: BLE001
            errors.append(f"{c.url}: {exc}")
            # Still surface the SERP snippet so the query isn't empty
            decisions = heuristic_decisions(c.title, c.snippet, c.url)
            return {
                "id": _doc_id(c.url),
                "title": c.title,
                "url": c.url,
                "text": c.snippet,
                "snippet_src": c.snippet,
                "html": "",
                "fetch_engine": "serp_snippet",
                "source_rank": c.source_rank,
                "decisions": decisions,
                "out_links": [],
                "fetch_error": str(exc),
            }

    with ThreadPoolExecutor(max_workers=min(6, len(candidates))) as pool:
        futs = [pool.submit(work, c) for c in candidates]
        for fut in as_completed(futs):
            row = fut.result()
            if row:
                fetched.append(row)

    if not fetched:
        return {
            "query": query,
            "mode": "live",
            "count": 0,
            "hits": [],
            "errors": errors or ["All fetches failed"],
            "ranking": "bm25 * craft * human-quality penalties",
        }

    # Mini CraftRank over the fetched set
    url_to_id = {r["url"]: r["id"] for r in fetched}
    nodes: list[CraftNode] = []
    edges: list[CraftEdge] = []
    for r in fetched:
        hints = ranking_hints(r["decisions"])
        prop = 1.0 if str(r["decisions"].get("propaganda_signal", "")).lower() == "clear" else 0.0
        nodes.append(
            CraftNode(
                id=r["id"],
                prior=prior_from_hints(hints, propaganda_flag=prop),
                propaganda=prop,
            )
        )
        for link in r.get("out_links") or []:
            if link in url_to_id and url_to_id[link] != r["id"]:
                edges.append(CraftEdge(src=r["id"], dst=url_to_id[link], endorse=0.8))

    craft_scores = craftrank(nodes, edges)

    # BM25-ish relevance: query token overlap against title+text
    q_tokens = set(re.findall(r"[a-z0-9]{2,}", query.lower()))
    hits: list[dict[str, Any]] = []
    for r in fetched:
        blob = f"{r['title']}\n{r['text']}".lower()
        tokens = re.findall(r"[a-z0-9]{2,}", blob)
        if not tokens:
            rel = 0.0
        else:
            tf = sum(1 for t in tokens if t in q_tokens)
            rel = tf / (1.0 + 0.01 * len(tokens))
            # Prefer earlier SERP only slightly — CraftRank/quality dominate
            rel += max(0.0, 0.15 - 0.02 * int(r["source_rank"]))
        hints = ranking_hints(r["decisions"])
        craft = float(craft_scores.get(r["id"], 0.0))
        score = blend_with_craftrank(rel, hints, craft)
        # Prefer pages we actually fetched over SERP stubs.
        if r["fetch_engine"] == "serp_snippet":
            score -= 2.5
        elif r["fetch_engine"] in {"http", "lightpanda"} and len(r["text"]) > 400:
            score += 0.4
        # Prefer body extract over marketing title fluff when available
        snippet = r["text"].strip().replace("\n", " ")
        if len(snippet) < 80:
            snippet = (r.get("snippet_src") or snippet).strip().replace("\n", " ")
        if len(snippet) > 240:
            snippet = snippet[:237] + "…"
        hits.append(
            {
                "id": r["id"],
                "title": r["title"],
                "url": r["url"],
                "snippet": snippet,
                "relevance": round(rel, 4),
                "craft": round(craft, 6),
                "betterweb_score": round(score, 4),
                "badges": badges_from_decisions(r["decisions"]),
                "decisions": r["decisions"],
                "fetch_engine": r["fetch_engine"],
                "source": "live",
            }
        )

    hits.sort(key=lambda h: h["betterweb_score"], reverse=True)
    return {
        "query": query,
        "mode": "live",
        "count": len(hits[:limit]),
        "hits": hits[:limit],
        "errors": errors,
        "ranking": "live-discover → fetch → craft × human-quality (BetterWeb-owned)",
        "candidates": len(candidates),
        "fetched": len(fetched),
    }
