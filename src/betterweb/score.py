"""Page-property CraftRank: weighted mix of decision-model heads.

Weight *order* is the learner's. Magnitudes are a first cut that respects
that order (quality > human > citations; synthetic > promo > bias > ads).
Neither/unknown authorship is neutral — no mixed demote.
"""

from __future__ import annotations

from typing import Any

from betterweb.schema import authorship_flags

# Promote (strongest first) / demote (strongest first).
WEIGHTS = {
    "thought_quality": 3.0,
    "human_authorship": 2.0,
    "citation_use": 1.0,
    "synthetic_authorship": 3.0,
    "commercial_promotion": 2.4,
    "commercial_bias": 1.8,
    "ad_use": 0.8,
}

CITATION_PROMOTE_FLOOR = 0.4


def _clamp01(value: float) -> float:
    return max(0.0, min(1.0, float(value)))


def _float(decisions: dict[str, Any], key: str, default: float = 0.0) -> float:
    raw = decisions.get(key, default)
    try:
        return _clamp01(float(raw))
    except (TypeError, ValueError):
        return default


def citation_promotion(citation_use: float) -> float:
    """Low citation is zero effect; high citation promotes."""
    use = _clamp01(citation_use)
    if use < CITATION_PROMOTE_FLOOR:
        return 0.0
    return (use - CITATION_PROMOTE_FLOOR) / (1.0 - CITATION_PROMOTE_FLOOR)


def authorship_terms(decisions: dict[str, Any] | str) -> tuple[float, float]:
    """Return (human_promo, synthetic_demo) each in {0, 1}."""
    if isinstance(decisions, str):
        decisions = {"authorship_likeness": decisions}
    is_human, is_ai = authorship_flags(decisions)
    return float(is_human), float(is_ai)


def craftrank_score(decisions: dict[str, Any]) -> float:
    """Combine heads into a 0–10 page score (neutral ≈ 5)."""
    human, synthetic = authorship_terms(decisions)
    raw = (
        WEIGHTS["thought_quality"] * _float(decisions, "thought_quality")
        + WEIGHTS["human_authorship"] * human
        + WEIGHTS["citation_use"] * citation_promotion(_float(decisions, "citation_use"))
        - WEIGHTS["synthetic_authorship"] * synthetic
        - WEIGHTS["commercial_promotion"] * _float(decisions, "commercial_promotion")
        - WEIGHTS["commercial_bias"] * _float(decisions, "commercial_bias")
        - WEIGHTS["ad_use"] * _float(decisions, "ad_use")
    )
    return max(0.0, min(10.0, 5.0 + raw))
