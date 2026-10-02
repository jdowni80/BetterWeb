# BetterWeb

A **browser and search engine** that favors human thought over AI slop, flags clear propaganda, skips ads and tracking, and helps people find niche, non-malicious corners of the web.

## Principles

- **Quality ranking** — not just links and keyword relevance; score craft and human signal
- **Filter obvious bots / AI filler** — demote synthetic spam without pretending the model is omniscient
- **Flag propaganda** — surface clear political propaganda; don’t silently rewrite the web
- **Niche discovery** — make small, virtuous sites findable on purpose
- **Decentralized & local-first** — no ad auction, no behavioral dossier
- **Open-weight decisions** — local schema judgments via [GLiNER2.5-Decide](https://huggingface.co/fastino/GLiNER2.5-Decide)

## Status

First slice: a **local judge CLI** that scores page text with the v0 schema and can re-rank mock search hits.

Vision: [`docs/CONCEPT.md`](docs/CONCEPT.md) · Schema: [`docs/decision-schema-v0.md`](docs/decision-schema-v0.md) · Web stack (no Chromium): [`docs/architecture-web-stack.md`](docs/architecture-web-stack.md)

## Setup

```bash
cd ~/Documents/GitHub/BetterWeb
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
```

First run downloads `fastino/GLiNER2.5-Decide` from Hugging Face (needs network). Inference stays on-device afterward.

## Judge a page

```bash
# Raw text / sample files
betterweb-judge judge --file examples/pages/human-niche.txt --pretty
betterweb-judge judge --file examples/pages/ai-slop.txt --pretty

# Or a URL (fetches HTML, trims to title/meta/lead text)
betterweb-judge judge --url 'https://example.com' --pretty

# Optional device hint for AutoExtractor
betterweb-judge judge --text 'short sample' --pretty --device mps
```

`--url` needs outbound HTTPS from this machine. If fetch fails, use `--file` / `--text`.

Output includes `decisions`, `badges`, and `ranking_hints`.

## Re-rank mock search hits

Offline (uses precomputed decisions in the JSON — no model download):

```bash
betterweb-judge rerank examples/search/mock_hits.json --offline --pretty
```

Live (runs the local model on each snippet):

```bash
betterweb-judge rerank examples/search/mock_hits.json --pretty
```

## Layout

```text
src/betterweb/   # extract, judge, rank, CLI
examples/        # sample pages + mock SERP
docs/            # concept + schema
```

## Remote

https://github.com/jdowni80/BetterWeb
