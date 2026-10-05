"""Query the local SQLite index: BM25 for relevance, then blend stored CraftRank."""

from __future__ import annotations

from typing import Any

from betterweb.store import PageStore

CRAFT_WEIGHT = 0.55
RELEVANCE_WEIGHT = 0.45


def search_index(
    store: PageStore,
    query: str,
    *,
    limit: int = 20,
    candidates: int = 100,
) -> dict[str, Any]:
    retrieved = store.bm25(query, limit=candidates)
    hits: list[dict[str, Any]] = []
    for row, relevance in retrieved:
        craft = row.craftrank_score / 10.0
        blended = 10.0 * (RELEVANCE_WEIGHT * relevance + CRAFT_WEIGHT * craft)
        hits.append(row.to_hit(relevance, blended, query=query))
    hits.sort(key=lambda h: h["score"], reverse=True)
    return {
        "query": query,
        "mode": "index",
        "count": len(hits[:limit]),
        "hits": hits[:limit],
        "candidates": len(retrieved),
        "ranking": "bm25 × stored craftrank_score",
        "errors": [],
    }
