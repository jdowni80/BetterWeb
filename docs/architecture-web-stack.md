# Accessing the real web without Chromium

BetterWeb needs two different things people often smash together:

1. **A search engine** — discover URLs, fetch pages, index text, rank results.
2. **A browser** — render pages for humans and let them navigate.

Chromium is neither required nor desirable for either, if we split the problem correctly. “From scratch” is the right *ambition for independence*, but the wrong *first deliverable* if it means rewriting Blink before BetterWeb can search anything.

## The hard truth

| Layer | Build from scratch? | Why |
| --- | --- | --- |
| Ranking + judgment (our soul) | **Yes** | This is BetterWeb. Local GLiNER schemas, quality scores, no ads, federated attestations. |
| Crawl / index / query | **Mostly yes** | Polite fetcher, WARC store, inverted index, BM25 + quality blend are tractable and owned by us. |
| Full modern *rendering* engine | **Not as our main product** | HTML/CSS/JS/Wasm/security is a multi-year standards project. Ladybird exists for that. |
| JS-capable *fetch* for crawlers | **Use a non-Chromium headless** | Many pages need JS; Lightpanda (Zig, from-scratch, CDP) is built for this without shipping Chrome. |

Shipping a daily-driver browser engine ourselves would consume the whole project. Partnering with / embedding an independent engine keeps BetterWeb’s scarce effort on **judgment, ranking, privacy, and niche discovery**.

## Recommended stack (phased)

```text
                    ┌─────────────────────────────────────┐
                    │         BetterWeb judgment          │
                    │   GLiNER2.5-Decide + v0 schemas     │
                    └───────────────┬─────────────────────┘
                                    │
          ┌─────────────────────────┼─────────────────────────┐
          ▼                         ▼                         ▼
   Search path                 Index / rank              Browse path
   (access WWW)                (our IR)                  (human UI)
          │                         │                         │
  1) HTTP fetch + HTML         WARC + tantivy-like       Ladybird (goal)
     extract (most pages)      BM25 + quality hints      or Servo embed
  2) Lightpanda CDP            federated shards          (not Chromium)
     for JS-heavy pages        peer query fan-out
```

### Phase A — Search that touches the live web (now)

Own the search pipeline. No browser shell required.

1. **Seed** niche / virtuous hosts (curated lists + Common Crawl host ranks for bootstrap).
2. **Polite crawler**: `robots.txt`, per-host rate limits, backoff, honest User-Agent.
3. **Fetch path A (default):** HTTP GET → HTML extract (what `betterweb-judge` already does) → judge → index.
4. **Fetch path B (JS when needed):** [Lightpanda](https://github.com/lightpanda-io/browser) over CDP — from-scratch Zig headless, not a Chromium fork; obey robots; fall back only when a page is empty/broken under Lightpanda.
5. **Store:** raw WARC (source of truth) + disposable inverted index.
6. **Rank:** BM25 × **CraftRank** (quality-weighted endorsement graph) × judgment penalties. See [`craftrank.md`](craftrank.md). Propaganda = badge/filter, not silent delete.
7. **Node model:** each install is a complete mini search engine; peers optionally share WARC shards / attestations (mycel-style federation, not a Google clone).

This is how we “access the actual WWW” without installing Chrome as a dependency.

### Phase B — Human browser without Chromium

Do **not** fork Chromium/Electron/CEF.

| Option | Role for BetterWeb | Fit |
| --- | --- | --- |
| **[Ladybird](https://ladybird.org/)** | Long-term browse shell | From-scratch engine, non-profit, no search-deal monetization, Linux/macOS alpha targeted 2026. Closest values match. |
| **[Servo](https://servo.org/)** | Embeddable engine | Rust, crates.io embedding + emerging C API; good if we want a custom chrome/UI around an independent engine sooner. |
| **WebKit (system)** | Temporary macOS-only viewer | Not Chromium, but Apple-controlled. Acceptable only as a thin “open this URL” bridge — never the crawler, never the telemetry story. |
| **Chromium / Electron** | Rejected | Bloat + Google-shaped incentives; contradicts the premise. |

**Practical browse plan:** keep BetterWeb’s product chrome (search UI, badges, local index, filters) in our app; embed Ladybird or Servo for page view when ready. Until then, search + judge work fully without a full browser.

### Phase C — Decentralized discovery

- Local-first personal index (pages you visit, opt-in).
- Federated peers exchange **signed index packs / attestations**, not clickstreams.
- No ad graph → nothing to sell.
- Open, versioned decision schemas so communities can fork thresholds without forking the crawler.

## What we refuse

- Electron / CEF / “privacy Chromium” skins as the architecture.
- Centralized answer-engine that replaces reading pages.
- Silent global censorship of politics (flags + user filters only).
- Default telemetry or account-gated search.

## Why not “write the engine ourselves”?

Ladybird’s FAQ-scale reality: independent LibWeb/LibJS is already hundreds of thousands of lines and still an alpha trajectory. Building a *second* from-scratch engine inside BetterWeb would delay the thing users actually need: **a search experience that prefers human corners of the web**.

“From scratch” for BetterWeb means:

- from-scratch **product ethics and ranking**,
- from-scratch **index and federation**,
- from-scratch **local judgment**,
- and **independent** (non-Chromium) engines for fetch/render — built by projects whose job that is.

## Concrete next build slices

1. **Crawler v0** — polite HTTP fetch + frontier + WARC, wired to existing judge.
2. **Index v0** — BM25 over judged docs; CLI `betterweb-search "query"`.
3. **JS fetch adapter** — optional Lightpanda path when extract text is empty.
4. **Seed pack** — curated niche hosts + optional Common Crawl bootstrap.
5. **Browse spike** — evaluate Servo embed vs waiting on Ladybird alpha; document decision.

## References

- Ladybird: https://ladybird.org/ (independent engine; alpha 2026 Linux/macOS)
- Servo: https://servo.org/ (embeddable; crates.io)
- Lightpanda: https://github.com/lightpanda-io/browser (non-Chromium headless for crawl/automation)
- Federated full-stack node pattern (inspiration): [mycel](https://github.com/splch/mycel) — complete search node + optional peer fan-out
