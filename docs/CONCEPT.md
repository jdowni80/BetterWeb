# BetterWeb concept

BetterWeb is a **browser + search engine** built to surface human-made, high-quality corners of the web — and to demote AI slop, obvious bots, and clear propaganda — without ads, without surveillance capitalism, and without a single company owning the index.

## Why it exists

Mainstream search optimizes for links, engagement, and ad inventory. That pushes the web toward synthetic filler, SEO farms, and politically weaponized content, while niche honest sites disappear under noise.

BetterWeb optimizes for **quality of thought** and **discoverability of the good small web**.

## Product promise

| Principle | Meaning |
| --- | --- |
| Human-first ranking | Prefer evidence of craft, specificity, and lived knowledge over keyword match and backlink mass |
| Slop & bot filter | Demote AI-generated filler and automated spam; do not pretend every page is equal |
| Propaganda flagging | Label *clear* political propaganda so users can see the signal — not silently rewrite reality |
| Niche discovery | Help people *find* obscure corners — but only elevate them when they are human + high quality (obscurity alone is not merit) |
| Local-first privacy | No behavioral dossier; browsing and judgment stay on-device by default |
| No ads | No auction over attention; no “sponsored” poison in results |
| Decentralized | Shared indexes and reputations can federate; no mandatory central tracker |

## Two surfaces, one judgment layer

1. **Search** — query → ranked results scored for relevance *and* human quality signals.
2. **Browser** — while reading, the same local decision model can badge pages (slop / bot / propaganda / high-craft / niche gem) and feed an optional personal index.

The shared core is a **local decision engine**: open-weight, schema-defined judgments — a smart `if` over page text and metadata.

## Decision model: GLiNER2.5-Decide

Primary candidate: [`fastino/GLiNER2.5-Decide`](https://huggingface.co/fastino/GLiNER2.5-Decide) (Apache 2.0, ~340M, CPU-friendly).

It is a **structured decision model**, not a chatbot:

- You pass text + a schema of typed questions (labels, ordinals, multi-label, constraints).
- It returns answers, probabilities, confidence, and constraint feasibility.
- No open-ended generation; no “explain yourself” essay — just operational judgments.
- Latency is practical locally (~tens of ms on GPU, ~100–200 ms class on CPU for short docs).

That matches BetterWeb’s need: **policy and ranking gates**, not another generative overlay on the web.

### Example schema heads (v0)

For a page snippet / extract:

- `authorship_likeness`: `human_crafted` | `mixed` | `synthetic_filler` | `unknown`
- `bot_spam`: `yes` | `no` | `uncertain`
- `propaganda_signal`: `clear` | `none` | `uncertain` *(flag, don’t censor by default)*
- `malice`: `benign` | `scam_or_harm` | `uncertain`
- `thought_quality`: ordinal `1–5` (specificity, argument, original observation)
- `niche_value`: `common` | `specialist_useful` | `rare_gem`

Constraints can enforce coherence (e.g. `bot_spam=yes` ⇒ demote `thought_quality`).

Fine-tune later on BetterWeb-labeled examples; start with described labels and human review loops.

## Ranking philosophy

Not vanilla PageRank (links are gamed). BetterWeb uses **CraftRank** — a PageRank-shaped authority score on a *quality-weighted endorsement graph*, with anti-slop priors and anti-farm edge damping. Full write-up: [`craftrank.md`](craftrank.md).

Blend at query time:

1. **Lexical / semantic relevance** to the query (BM25-class IR).
2. **CraftRank** offline authority \(r_i\) (earned endorsements only).
3. **Decision scores** from the local model — **thought quality + human craft** first; malice/slop/ads as penalties.
4. **Community attestations** (optional, signed, portable) — “this site is real and useful,” not “this site is obscure.”
5. **Personal taste** — on-device preferences; never uploaded by default.

**Niche is not a rank feature.** Rarity labels may badge or feed an explore UI *after* craft thresholds; they must not outrank clear human quality writing just for being uncommon.

Propaganda is **surfaced as a flag**, not deleted. Users stay in control of filters. Propaganda↔propaganda link loops are damped so they cannot PageRank themselves into dominance.

## Decentralization sketch

- **Local index first** — pages you visit (opt-in) become searchable privately.
- **Federated peers** — communities publish optional indexes / attestations (signed bundles), not clickstreams.
- **No central ad graph** — there is nothing to sell because there is no profile product.
- **Open schemas** — decision schemas are versioned and auditable; forks can disagree on politics thresholds without forking the browser.

Exact networking (DHT, ActivityPub-like feeds, BitTorrent-style index packs) is an implementation choice after the judgment + ranking loop works offline.

## Privacy & anti-tracking

- No third-party ad or analytics SDKs.
- No mandatory account.
- Sync (if ever) is E2E or user-hosted.
- Model weights and page judgment run **on device** whenever possible.
- Telemetry, if any, is opt-in, aggregate, and never content-level by default.

## Non-goals (for now)

- Becoming a generative “answer engine” that replaces reading the web.
- Centralized trust-and-safety theater that silently rewrites results for everyone.
- Monetizing attention with ads or data brokerage.
- Claiming perfect political neutrality from a model — schemas and thresholds must be transparent and user-configurable.

## First build slice (suggested)

1. Local **judge service** wrapping GLiNER2.5-Decide with the v0 schema. *(shipped: `betterweb-judge`)*
2. **CLI / small UI**: paste URL or HTML text → structured badges + scores. *(shipped)*
3. Tiny **result scorer**: mock search hits re-ranked by judge outputs. *(shipped)*
4. Seed list of niche “good web” sites for discovery demos.

## Web stack (no Chromium, no WKWebView)

Search and browse are split: we **own crawl/index/rank/judgment**; we **do not** rebuild Blink. Live-web fetch uses HTTP + HTML extract, with optional non-Chromium headless (Lightpanda) for JS pages. Human browsing uses **embedded Servo** inside BetterWeb.app (Swift chrome + `betterweb-browse` helper) — never Electron/CEF/WKWebView.

Full plan: [`architecture-web-stack.md`](architecture-web-stack.md).

## Open questions

- Default propaganda threshold vs. user-tunable schemas.
- How community attestations resist brigading without recentralizing.
- Crawl ethics and robots.txt in a federated indexer.
- Whether the browser is Chromium-based, WebKit, or a privacy fork.
