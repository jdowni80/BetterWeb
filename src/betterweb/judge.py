"""Score a page with GLiNER when available; otherwise conservative heuristics."""

from __future__ import annotations

import os
import re
import threading
from typing import Any

from betterweb.schema import PAGE_SCHEMA, SCHEMA_VERSION, numeric_decisions

DEFAULT_MODEL = "fastino/GLiNER2.5-Decide"
_JUDGE_LOCK = threading.Lock()

_SLOP = re.compile(
    r"\b(rapidly evolving digital landscape|harness(?:ing)? the power of|"
    r"in today's world|game[- ]changer|leverage AI|cutting[- ]edge solutions)\b",
    re.I,
)
_FIRST = re.compile(r"\b(I|I've|I'm|we|our|my)\b")
_SPECIFIC = re.compile(r"\b(\d{2,4}|measured|schematic|solder|kernel|citation|figure)\b", re.I)
_ADS = re.compile(r"\b(sponsored|affiliate|buy now|limited time|as an amazon associate)\b", re.I)
_SELL = re.compile(r"\b(buy (?:my |the )?course|enroll now|add to cart|order now|pricing plans)\b", re.I)
_CITE = re.compile(r"\[[0-9]{1,3}\]|https?://|doi:|et al\.", re.I)


def heuristic_decisions(title: str, text: str, url: str = "") -> dict[str, Any]:
    blob = f"{title}\n{text}"
    words = re.findall(r"[A-Za-z]{3,}", blob)
    n = max(len(words), 1)
    unique = len({w.lower() for w in words}) / n
    slop = len(_SLOP.findall(blob))
    first = len(_FIRST.findall(blob))
    specific = len(_SPECIFIC.findall(blob))
    ads = len(_ADS.findall(blob))
    sell = len(_SELL.findall(blob))
    cites = len(_CITE.findall(blob))

    if slop >= 2 or (slop and unique < 0.35) or ("seo" in url.lower() and slop):
        is_human, is_ai = False, True
        thought = 0.15
    elif first >= 2 and specific >= 2 and unique > 0.4:
        is_human, is_ai = True, False
        thought = 0.75 if specific >= 4 else 0.6
    else:
        is_human, is_ai = False, False
        if first or specific:
            thought = 0.45
        else:
            thought = 0.35 if len(text) > 400 else 0.2

    if len(text) < 80:
        thought = min(thought, 0.2)

    ad_use = min(1.0, 0.25 * ads)
    commercial_promotion = min(1.0, 0.4 * sell + 0.15 * ads)
    commercial_bias = min(1.0, 0.5 * sell + (0.2 if "course" in blob.lower() else 0.0))
    citation_use = min(1.0, 0.12 * cites)

    return numeric_decisions(
        {
            "is_human_generated": is_human,
            "is_ai_generated": is_ai,
            "thought_quality": thought,
            "commercial_bias": commercial_bias,
            "ad_use": ad_use,
            "commercial_promotion": commercial_promotion,
            "citation_use": citation_use,
        }
    )


def probe(judge: PageJudge | None) -> str:
    if judge is None:
        return "gliner disabled; heuristic fallback"
    try:
        judge._load()
        return f"gliner {judge.model_id} ready"
    except Exception as exc:
        return f"gliner unavailable ({type(exc).__name__}); heuristic fallback"


class PageJudge:
    def __init__(self, model_id: str = DEFAULT_MODEL, map_location: str | None = None, lazy: bool = True) -> None:
        self.model_id = model_id
        self.map_location = map_location
        self._model = None
        if not lazy:
            self._load()

    def _load(self) -> None:
        if self._model is not None:
            return
        import gliner2

        os.environ.setdefault("HF_HUB_OFFLINE", "1")
        kwargs = {"local_files_only": True}
        if self.map_location:
            kwargs["map_location"] = self.map_location
        try:
            self._model = gliner2.AutoExtractor.from_pretrained(self.model_id, **kwargs)
        except Exception:
            kwargs.pop("local_files_only", None)
            os.environ.pop("HF_HUB_OFFLINE", None)
            self._model = gliner2.AutoExtractor.from_pretrained(self.model_id, **kwargs)

    def judge_text(self, text: str, title: str = "", url: str = "", source: str = "crawl") -> dict[str, Any]:
        try:
            self._load()
            with _JUDGE_LOCK:
                result = self._model.classify_text(text, PAGE_SCHEMA)
            raw = result.model_dump() if hasattr(result, "model_dump") else dict(result)
            decisions = numeric_decisions(_flatten(raw))
            backend = self.model_id
        except Exception:
            decisions = heuristic_decisions(title, text, url)
            backend = "heuristic"
        return {
            "schema_version": SCHEMA_VERSION,
            "model": backend,
            "source": source,
            "title": title,
            "url": url,
            "decisions": decisions,
        }


def _flatten(raw: dict[str, Any]) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for key, value in raw.items():
        if isinstance(value, dict):
            out[key] = value.get("value") or value.get("label") or value.get("answer") or value
        else:
            out[key] = value
    return out
