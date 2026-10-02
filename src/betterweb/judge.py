"""Local GLiNER2.5-Decide page judge."""

from __future__ import annotations

import json
import re
from dataclasses import asdict, dataclass, field
from typing import Any

from betterweb.schema import PAGE_SCHEMA, SCHEMA_VERSION, badges_from_decisions

DEFAULT_MODEL = "fastino/GLiNER2.5-Decide"

# Zero-shot Decide sometimes tags marketing filler as propaganda.
# Until we fine-tune, require a political cue before keeping `clear`.
_POLITICAL_CUE = re.compile(
    r"\b("
    r"vote|voting|election|ballot|campaign|candidate|partisan|party|"
    r"democrat|republican|congress|parliament|senator|president|"
    r"regime|geopolitic\w*|patriot|propaganda|mobilize|mobilise|"
    r"left[- ]wing|right[- ]wing|liberal elite|deep state"
    r")\b",
    re.IGNORECASE,
)


@dataclass
class Judgment:
    schema_version: str
    model: str
    source: str
    title: str
    url: str | None
    decisions: dict[str, Any]
    badges: list[str]
    raw: dict[str, Any] = field(default_factory=dict)
    ranking_hints: dict[str, float] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def _normalize_decisions(raw: Any) -> dict[str, Any]:
    """Flatten classify_text output into a simple field -> answer map."""
    if raw is None:
        return {}
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except json.JSONDecodeError:
            return {"value": raw}

    # Some versions wrap under "classification" / "results"
    if isinstance(raw, dict):
        for key in ("classification", "classifications", "results", "output"):
            if key in raw and isinstance(raw[key], dict):
                raw = raw[key]
                break

    if not isinstance(raw, dict):
        return {"value": raw}

    decisions: dict[str, Any] = {}
    for key, value in raw.items():
        if isinstance(value, dict):
            if "label" in value:
                decisions[key] = value["label"]
            elif "labels" in value and isinstance(value["labels"], list) and value["labels"]:
                decisions[key] = value["labels"][0]
            elif "answer" in value:
                decisions[key] = value["answer"]
            else:
                decisions[key] = value
        elif isinstance(value, list) and value:
            decisions[key] = value[0] if len(value) == 1 else value
        else:
            decisions[key] = value
    return decisions


def apply_v0_guards(decisions: dict[str, Any], text: str) -> dict[str, Any]:
    """Conservative post-filters for known zero-shot failure modes."""
    out = dict(decisions)
    prop = str(out.get("propaganda_signal", "")).lower()
    if prop == "clear" and not _POLITICAL_CUE.search(text):
        out["propaganda_signal"] = "uncertain"
    return out


def ranking_hints(decisions: dict[str, Any]) -> dict[str, float]:
    """Toy numeric hooks for re-ranking (see docs/decision-schema-v0.md)."""
    quality_raw = str(decisions.get("thought_quality", "3"))
    try:
        quality = float(quality_raw)
    except ValueError:
        quality = 3.0

    niche = str(decisions.get("niche_value", "common")).lower()
    niche_bonus = {"common": 0.0, "specialist_useful": 0.8, "rare_gem": 1.6}.get(niche, 0.0)

    authorship = str(decisions.get("authorship_likeness", "unknown")).lower()
    slop_penalty = {
        "human_crafted": 0.0,
        "mixed": 0.4,
        "synthetic_filler": 1.5,
        "unknown": 0.2,
    }.get(authorship, 0.2)

    if str(decisions.get("bot_spam", "")).lower() == "yes":
        slop_penalty += 2.0
        niche_bonus = min(niche_bonus, 0.0)

    malice = str(decisions.get("malice", "benign")).lower()
    malice_penalty = {"benign": 0.0, "uncertain": 0.7, "scam_or_harm": 5.0}.get(malice, 0.0)

    propaganda_flag = 1.0 if str(decisions.get("propaganda_signal", "")).lower() == "clear" else 0.0

    return {
        "thought_quality": quality,
        "niche_bonus": niche_bonus,
        "slop_penalty": slop_penalty,
        "malice_penalty": malice_penalty,
        "propaganda_flag": propaganda_flag,
    }


class PageJudge:
    def __init__(
        self,
        model_id: str = DEFAULT_MODEL,
        *,
        map_location: str | None = None,
        lazy: bool = True,
    ) -> None:
        self.model_id = model_id
        self.map_location = map_location
        self._model = None
        if not lazy:
            self._load()

    def _load(self) -> Any:
        if self._model is not None:
            return self._model
        from gliner2 import AutoExtractor

        kwargs: dict[str, Any] = {}
        if self.map_location:
            kwargs["map_location"] = self.map_location
        self._model = AutoExtractor.from_pretrained(self.model_id, **kwargs)
        return self._model

    def judge_text(
        self,
        text: str,
        *,
        title: str = "",
        url: str | None = None,
        source: str = "text",
    ) -> Judgment:
        model = self._load()
        raw = model.classify_text(text, PAGE_SCHEMA)
        # Prefer returning raw as dict when possible
        raw_dict: dict[str, Any]
        if hasattr(raw, "model_dump"):
            raw_dict = raw.model_dump()
        elif isinstance(raw, dict):
            raw_dict = raw
        else:
            raw_dict = {"result": raw}

        decisions = apply_v0_guards(_normalize_decisions(raw), text)
        badges = badges_from_decisions(decisions)
        hints = ranking_hints(decisions)
        return Judgment(
            schema_version=SCHEMA_VERSION,
            model=self.model_id,
            source=source,
            title=title,
            url=url,
            decisions=decisions,
            badges=badges,
            raw=raw_dict,
            ranking_hints=hints,
        )
