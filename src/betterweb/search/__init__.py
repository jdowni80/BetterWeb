"""In-memory BM25 + CraftRank search index for the prototype."""

from __future__ import annotations

import json
import re
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

from rank_bm25 import BM25Okapi

from betterweb.craftrank import CraftEdge, CraftNode, blend_with_craftrank, craftrank, prior_from_hints
from betterweb.judge import ranking_hints
from betterweb.schema import badges_from_decisions
from betterweb.search.local_index import search_index

TOKEN_RE = re.compile(r"[a-z0-9]{2,}")


@dataclass
class Document:
    id: str
    title: str
    url: str
    text: str
    decisions: dict[str, Any] = field(default_factory=dict)
    badges: list[str] = field(default_factory=list)
    fetch_engine: str = "seed"
    craft: float = 0.0

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def _tokenize(text: str) -> list[str]:
    return TOKEN_RE.findall(text.lower())


class SearchIndex:
    def __init__(self) -> None:
        self.docs: list[Document] = []
        self._bm25: BM25Okapi | None = None
        self._tokens: list[list[str]] = []
        self._craft: dict[str, float] = {}
        self._edges: list[CraftEdge] = []

    def clear(self) -> None:
        self.docs.clear()
        self._bm25 = None
        self._tokens = []
        self._craft = {}
        self._edges = []

    def add_document(
        self,
        *,
        doc_id: str,
        title: str,
        url: str,
        text: str,
        decisions: dict[str, Any],
        fetch_engine: str = "seed",
    ) -> Document:
        hints = ranking_hints(decisions)
        badges = badges_from_decisions(decisions)
        doc = Document(
            id=doc_id,
            title=title,
            url=url,
            text=text,
            decisions=decisions,
            badges=badges,
            fetch_engine=fetch_engine,
            craft=0.0,
        )
        # Replace if same id
        self.docs = [d for d in self.docs if d.id != doc_id]
        self.docs.append(doc)
        return doc

    def set_edges(self, edges: list[dict[str, Any]]) -> None:
        self._edges = [
            CraftEdge(
                src=str(e["src"]),
                dst=str(e["dst"]),
                endorse=float(e.get("endorse", 1.0)),
                farm=float(e.get("farm", 0.0)),
            )
            for e in edges
        ]

    def rebuild(self) -> None:
        self._tokens = [_tokenize(f"{d.title}\n{d.text}") for d in self.docs]
        self._bm25 = BM25Okapi(self._tokens) if self._tokens else None

        nodes: list[CraftNode] = []
        for d in self.docs:
            hints = ranking_hints(d.decisions)
            prop = 1.0 if str(d.decisions.get("propaganda_signal", "")).lower() == "clear" else 0.0
            nodes.append(
                CraftNode(
                    id=d.id,
                    prior=prior_from_hints(hints, propaganda_flag=prop),
                    propaganda=prop,
                )
            )
        scores = craftrank(nodes, self._edges) if nodes else {}
        self._craft = scores
        for d in self.docs:
            d.craft = float(scores.get(d.id, 0.0))

    def search(self, query: str, *, limit: int = 20) -> list[dict[str, Any]]:
        if not self.docs or not self._bm25:
            return []
        q_tokens = _tokenize(query)
        if not q_tokens:
            return []
        raw = self._bm25.get_scores(q_tokens)
        ranked: list[dict[str, Any]] = []
        for doc, relevance in zip(self.docs, raw, strict=True):
            if relevance <= 0:
                continue
            hints = ranking_hints(doc.decisions)
            score = blend_with_craftrank(float(relevance), hints, doc.craft)
            snippet = doc.text.strip().replace("\n", " ")
            if len(snippet) > 220:
                snippet = snippet[:217] + "…"
            ranked.append(
                {
                    "id": doc.id,
                    "title": doc.title,
                    "url": doc.url,
                    "snippet": snippet,
                    "relevance": round(float(relevance), 4),
                    "craft": round(doc.craft, 6),
                    "betterweb_score": round(score, 4),
                    "badges": doc.badges,
                    "decisions": doc.decisions,
                    "fetch_engine": doc.fetch_engine,
                }
            )
        ranked.sort(key=lambda h: h["betterweb_score"], reverse=True)
        return ranked[:limit]

    def load_seed(self, path: Path) -> int:
        payload = json.loads(path.read_text(encoding="utf-8"))
        self.clear()
        for item in payload.get("documents", []):
            self.add_document(
                doc_id=str(item["id"]),
                title=str(item["title"]),
                url=str(item["url"]),
                text=str(item["text"]),
                decisions=dict(item.get("decisions") or {}),
                fetch_engine=str(item.get("fetch_engine", "seed")),
            )
        self.set_edges(list(payload.get("edges") or []))
        self.rebuild()
        return len(self.docs)
