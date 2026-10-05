"""Toy re-ranker using judgment ranking_hints."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from betterweb.judge import PageJudge, ranking_hints
from betterweb.schema import badges_from_decisions


@dataclass
class RankedHit:
    id: str
    title: str
    url: str
    snippet: str
    relevance: float
    betterweb_score: float
    badges: list[str]
    decisions: dict[str, Any]

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "title": self.title,
            "url": self.url,
            "snippet": self.snippet,
            "relevance": self.relevance,
            "betterweb_score": round(self.betterweb_score, 4),
            "badges": self.badges,
            "decisions": self.decisions,
        }


def combine_score(relevance: float, hints: dict[str, float]) -> float:
    """
    score = relevance
          + 0.45 * thought_quality
          - slop_penalty
          - malice_penalty

    Rank for human craft + quality — not obscurity.
    niche_bonus is ignored (kept in hints for API stability; always 0).
    propaganda_flag is badge-only (does not silently delete).
    """
    return (
        float(relevance)
        + 0.45 * hints.get("thought_quality", 3.0)
        - hints.get("slop_penalty", 0.0)
        - hints.get("malice_penalty", 0.0)
    )


def rerank_hits(
    hits: list[dict[str, Any]],
    judge: PageJudge,
) -> list[RankedHit]:
    ranked: list[RankedHit] = []
    for hit in hits:
        text = "\n\n".join(
            part
            for part in (
                f"Title: {hit.get('title', '')}",
                f"URL: {hit.get('url', '')}",
                hit.get("snippet", ""),
            )
            if part
        )
        judgment = judge.judge_text(
            text,
            title=str(hit.get("title", "")),
            url=hit.get("url"),
            source="search_hit",
        )
        relevance = float(hit.get("relevance", 0.0))
        if isinstance(judgment, dict):
            decisions = dict(judgment.get("decisions") or {})
            hints = ranking_hints(decisions)
            badges = badges_from_decisions(decisions)
        else:
            decisions = judgment.decisions
            hints = judgment.ranking_hints
            badges = judgment.badges
        score = combine_score(relevance, hints)
        ranked.append(
            RankedHit(
                id=str(hit.get("id", hit.get("url", ""))),
                title=str(hit.get("title", "")),
                url=str(hit.get("url", "")),
                snippet=str(hit.get("snippet", "")),
                relevance=relevance,
                betterweb_score=score,
                badges=badges,
                decisions=decisions,
            )
        )
    ranked.sort(key=lambda h: h.betterweb_score, reverse=True)
    return ranked


def rerank_from_decisions(hits: list[dict[str, Any]]) -> list[RankedHit]:
    """Re-rank when decisions are already attached (offline / mock)."""
    ranked: list[RankedHit] = []
    for hit in hits:
        decisions = dict(hit.get("decisions") or {})
        hints = ranking_hints(decisions)
        badges = list(hit.get("badges") or badges_from_decisions(decisions))
        relevance = float(hit.get("relevance", 0.0))
        ranked.append(
            RankedHit(
                id=str(hit.get("id", hit.get("url", ""))),
                title=str(hit.get("title", "")),
                url=str(hit.get("url", "")),
                snippet=str(hit.get("snippet", "")),
                relevance=relevance,
                betterweb_score=combine_score(relevance, hints),
                badges=badges,
                decisions=decisions,
            )
        )
    ranked.sort(key=lambda h: h.betterweb_score, reverse=True)
    return ranked
