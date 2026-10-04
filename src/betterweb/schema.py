"""v0 decision schema for BetterWeb page judgment."""

from __future__ import annotations

from typing import Any

SCHEMA_VERSION = "v0"

# Described labels help Decide stay precise without fine-tuning yet.
PAGE_SCHEMA: dict[str, Any] = {
    "authorship_likeness": {
        "labels": {
            "human_crafted": (
                "Specific, idiosyncratic writing with lived detail, original "
                "observation, or craft; not generic SEO filler"
            ),
            "mixed": (
                "Partly human and partly formulaic or lightly machine-polished"
            ),
            "synthetic_filler": (
                "Generic AI-slop: vague, interchangeable paragraphs, buzzword "
                "padding, no concrete experience"
            ),
            "unknown": "Not enough text to judge authorship style",
        },
    },
    "bot_spam": {
        "labels": {
            "yes": "Obvious bot, scraper dump, doorway page, or spam farm content",
            "no": "Looks like a real page meant for humans",
            "uncertain": "Could be spam or low-effort automation; unclear",
        },
    },
    "propaganda_signal": {
        "labels": ["clear", "none", "uncertain"],
        "prompt": (
            "Is this clear political propaganda that mobilizes for or against a "
            "party, government, candidate, or geopolitical cause? Answer clear "
            "only for political mobilization. Corporate marketing, SEO filler, "
            "product copy, and ordinary non-political blogs are none."
        ),
    },
    "malice": {
        "labels": {
            "benign": "Non-malicious informational or creative content",
            "scam_or_harm": (
                "Scam, phishing bait, malware lure, or clearly harmful corner"
            ),
            "uncertain": "Suspicious but not clearly malicious",
        },
    },
    "thought_quality": {
        "labels": {
            "1": "Empty or incoherent; no useful thought",
            "2": "Thin; mostly filler or restated common knowledge",
            "3": "Adequate; some useful points but shallow",
            "4": "Strong; specific argument, craft, or insight",
            "5": "Exceptional human thought; rare clarity or originality",
        },
    },
    "niche_value": {
        "labels": {
            "common": "Mainstream / widely duplicated topic coverage",
            "specialist_useful": (
                "Specialist or hobbyist topic — descriptive only; not a quality score"
            ),
            "rare_gem": (
                "Uncommon corner of the web — descriptive only; rank still depends "
                "on human craft and thought quality, never on obscurity alone"
            ),
        },
    },
}

BADGE_RULES: list[tuple[str, str, str]] = [
    # (field, value, badge)
    ("authorship_likeness", "synthetic_filler", "ai_slop"),
    ("authorship_likeness", "human_crafted", "human_craft"),
    ("bot_spam", "yes", "bot_spam"),
    ("propaganda_signal", "clear", "propaganda"),
    ("malice", "scam_or_harm", "malicious"),
    ("niche_value", "rare_gem", "rare_gem"),
    ("niche_value", "specialist_useful", "niche"),
    ("thought_quality", "5", "high_thought"),
    ("thought_quality", "4", "high_thought"),
]


def badges_from_decisions(decisions: dict[str, Any]) -> list[str]:
    """Map schema answers to UI-facing badges."""
    found: list[str] = []
    for field, value, badge in BADGE_RULES:
        if str(decisions.get(field, "")).lower() == value.lower():
            if badge not in found:
                found.append(badge)

    authorship = str(decisions.get("authorship_likeness", "")).lower()
    try:
        quality = float(str(decisions.get("thought_quality", "0")))
    except ValueError:
        quality = 0.0
    human_enough = authorship == "human_crafted" or (
        authorship == "mixed" and quality >= 4
    )

    # Niche badges require craft — obscurity alone is not a virtue signal.
    if not human_enough or quality < 4:
        found = [b for b in found if b not in {"rare_gem", "niche"}]

    # Coherence with ranking constraints in decision-schema-v0.md
    if str(decisions.get("bot_spam", "")).lower() == "yes":
        found = [b for b in found if b not in {"rare_gem", "niche", "high_thought"}]
    if str(decisions.get("malice", "")).lower() == "scam_or_harm":
        found = [b for b in found if b not in {"rare_gem", "niche", "high_thought", "human_craft"}]
    return found
