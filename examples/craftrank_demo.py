#!/usr/bin/env python3
"""Tiny CraftRank demo: SEO farm vs niche craft vs propaganda clique."""

from __future__ import annotations

import json
import sys
from pathlib import Path

# Allow running without install
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from betterweb.craftrank import CraftEdge, CraftNode, craftrank


def main() -> None:
    nodes = [
        CraftNode("niche.radio.notes", prior=0.92, propaganda=0.0),
        CraftNode("wiki.electronics", prior=0.8, propaganda=0.0),
        CraftNode("ai-synergy.farm", prior=0.12, propaganda=0.0),
        CraftNode("ai-synergy.farm/page2", prior=0.1, propaganda=0.0),
        CraftNode("ai-synergy.farm/page3", prior=0.1, propaganda=0.0),
        CraftNode("mobilize.now", prior=0.45, propaganda=1.0),
        CraftNode("mobilize.mirror", prior=0.4, propaganda=1.0),
        CraftNode("scam.parcel", prior=0.02, propaganda=0.0),
    ]
    edges = [
        # Earned citations into niche craft
        CraftEdge("wiki.electronics", "niche.radio.notes", endorse=1.0),
        CraftEdge("niche.radio.notes", "wiki.electronics", endorse=0.6),
        # SEO farm clique (high farm damping)
        CraftEdge("ai-synergy.farm", "ai-synergy.farm/page2", endorse=1.0, farm=0.9),
        CraftEdge("ai-synergy.farm/page2", "ai-synergy.farm/page3", endorse=1.0, farm=0.9),
        CraftEdge("ai-synergy.farm/page3", "ai-synergy.farm", endorse=1.0, farm=0.9),
        # Farm tries to launder into niche
        CraftEdge("ai-synergy.farm", "niche.radio.notes", endorse=1.0, farm=0.85),
        # Propaganda mutual amplification (damped by beta * p_u * p_v)
        CraftEdge("mobilize.now", "mobilize.mirror", endorse=1.0),
        CraftEdge("mobilize.mirror", "mobilize.now", endorse=1.0),
        # Scam outbound ignored via tiny prior
        CraftEdge("scam.parcel", "niche.radio.notes", endorse=1.0, farm=0.5),
    ]

    scores = craftrank(nodes, edges)
    ranked = sorted(scores.items(), key=lambda kv: kv[1], reverse=True)
    print(json.dumps({"craftrank": {k: round(v, 6) for k, v in ranked}}, indent=2))


if __name__ == "__main__":
    main()
