"""Lightweight page quality heuristics for live search (no model required)."""

from __future__ import annotations

import re
from typing import Any

_SLOP = re.compile(
    r"\b("
    r"rapidly evolving digital landscape|unlock(?:ing)? (?:unprecedented )?synergies|"
    r"harness(?:ing)? the power of|holistic transformation|cutting[- ]edge solutions|"
    r"future[- ]proof|in today's world|game[- ]changer|leverage AI|"
    r"seamless(?:ly)? optimize|empower stakeholders"
    r")\b",
    re.I,
)
_FIRST_PERSON = re.compile(r"\b(I|I've|I'm|we|our|my)\b", re.I)
_SPECIFIC = re.compile(
    r"\b(\d{2,4}|mm|mhz|ohm|vacuum|schematic|measured|solder|rust|compost|notebook)\b",
    re.I,
)
_PROP = re.compile(
    r"\b(vote|election|campaign|patriot|regime|mobilize|mobilise|deep state|"
    r"left[- ]wing|right[- ]wing|betray the)\b",
    re.I,
)
_SCAM = re.compile(
    r"\b(enter (?:your )?cvv|verify (?:your )?banking|package (?:is )?held|"
    r"click here within|act now or)\b",
    re.I,
)
_AFFILIATE = re.compile(
    r"\b(buy now|limited time offer|sponsored|affiliate|as an amazon associate)\b",
    re.I,
)


def heuristic_decisions(title: str, text: str, url: str = "") -> dict[str, Any]:
    blob = f"{title}\n{text}"
    words = re.findall(r"[A-Za-z]{3,}", blob)
    n = max(len(words), 1)
    unique = len({w.lower() for w in words}) / n
    slop_hits = len(_SLOP.findall(blob))
    first = len(_FIRST_PERSON.findall(blob))
    specific = len(_SPECIFIC.findall(blob))

    if _SCAM.search(blob):
        malice = "scam_or_harm"
    elif _AFFILIATE.search(blob) and slop_hits:
        malice = "uncertain"
    else:
        malice = "benign"

    if slop_hits >= 2 or (slop_hits and unique < 0.35):
        authorship = "synthetic_filler"
    elif (first >= 2 and specific >= 2 and unique > 0.4) or (
        specific >= 4 and unique > 0.42 and len(text) > 500
    ):
        authorship = "human_crafted"
    elif first or specific:
        authorship = "mixed"
    else:
        authorship = "unknown"

    bot = "yes" if unique < 0.28 and len(text) > 400 else "no"
    if slop_hits and "seo" in url.lower():
        bot = "yes"

    quality = 3
    if authorship == "human_crafted":
        quality = 4 + (1 if specific >= 4 else 0)
    elif authorship == "synthetic_filler":
        quality = 1
    elif authorship == "mixed":
        quality = 3
    if len(text) < 120:
        quality = min(quality, 2)

    if _PROP.search(blob) and re.search(r"\b(enemy|betray|share this now)\b", blob, re.I):
        propaganda = "clear"
    elif _PROP.search(blob):
        propaganda = "uncertain"
    else:
        propaganda = "none"

    niche = "common"
    if authorship == "human_crafted" and specific >= 3 and len(text) < 3500:
        niche = "specialist_useful"

    return {
        "authorship_likeness": authorship,
        "bot_spam": bot if bot == "yes" else "no",
        "propaganda_signal": propaganda,
        "malice": malice,
        "thought_quality": str(min(5, max(1, quality))),
        "niche_value": niche,
    }
