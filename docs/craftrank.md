# CraftRank — authority for the AI / SEO / ad / propaganda era

PageRank assumed links were scarce human endorsements. That world is gone.

Today the link graph is saturated with SEO farms, AI content mills, affiliate lattices, engagement bait, and coordinated political amplification. **Raw inlinks are no longer trust.**

**CraftRank** is BetterWeb’s replacement: a rapid, iterative graph score (PageRank-shaped) where authority only flows through edges that look like *earned human endorsement*, and where page priors already punish slop, ads-as-content, malice, and botnet patterns.

BetterWeb still owns the full ranking formula. CraftRank is the offline authority term inside it — not a Google/Bing dependency.

## What broke PageRank

| Old assumption | New reality |
| --- | --- |
| A link is a vote | A link is often a product (sold, swapped, generated, scraped) |
| Popular ≈ good | Popular ≈ optimized for ads / virality |
| More pages help discovery | More pages are synthetic filler |
| Homophily is mild | Propaganda and SEO clusters amplify themselves |

Classic PageRank on an ungated webgraph rewards whoever industrializes linking.

## CraftRank in one sentence

**Quality-weighted personalized PageRank on a cleaned endorsement graph, with anti-slop priors and anti-farm edge damping — propaganda flagged as a separate axis, not silently erased.**

## Signals (four layers)

### 1. Page prior \(q_i\) — local judgment (fast, ours)

From GLiNER2.5-Decide / v0 schema (already in `betterweb-judge`):

| Input | Effect on \(q_i\) |
| --- | --- |
| `thought_quality` high | Raise prior |
| `authorship_likeness = human_crafted` (low slop penalty) | Raise prior |
| `niche_value` | **No rank effect** — descriptive only (see below) |
| `synthetic_filler` / `bot_spam` | Crush prior |
| `malice = scam_or_harm` | Near-zero / hard demote |
| Ad-surface heuristics (affiliate density, popunders, endless “Buy now” chrome) | Demote prior *(schema head TBD: `ad_surface`)* |
| `propaganda_signal = clear` | **Does not zero \(q_i\)** — sets flag \(p_i\); see §Propaganda |

\(q_i \in (0, 1]\). Scam pages ≈ floor. Empty AI filler ≈ very low. High-craft human writing ≈ high — **whether or not it is niche**.

### Niche is not a virtue score

We want obscure *good* corners to remain findable. That does **not** mean “boost because rare.”

- **Rank for:** human craft + thought quality + earned endorsements (CraftRank).
- **Niche labels:** metadata / badges / optional explore surfaces — only after craft thresholds are met.
- **Never:** promote low-quality or synthetic pages just because few people link to them.

### 2. Endorsement edges — not all links are votes

Keep edge \(u \rightarrow v\) only if it looks like a real citation:

- In-content editorial link (not footer farm, not blogroll of 400 casino URLs)
- Anchor text is descriptive, not keyword-stuffed
- Source \(u\) itself has decent \(q_u\)
- Destination is not a pure redirect / doorway

Drop or heavily damp:

- Sitewide template links, reciprocal PBN cliques, sudden burst inlinks
- Near-duplicate site families (same generator, same WHOIS/hosting cluster when known)
- Links from `bot_spam` / ultra-low \(q\) hosts

Edge weight:

\[
w_{uv} = \mathrm{endorse}(u,v) \cdot q_u^{\alpha} \cdot (1 - \mathrm{farm}(u,v)) \cdot (1 - \beta\, p_u p_v)
\]

- \(\alpha \approx 1\): weak sources cannot mint strong authority  
- \(\mathrm{farm}\): structural spam score on the edge/host pair  
- \(p_u p_v\): damp **propaganda→propaganda** amplification (stops echo chambers from PageRanking each other into dominance) without deleting the pages

### 3. Iteration — PageRank-shaped, quality teleport

\[
r = (1-d)\, \hat{q} \;+\; d\, W^{\top} r
\]

- \(d \approx 0.85\) as usual  
- Teleport vector \(\hat{q}\) is **normalized page priors**, not uniform — quality pages are where random jumps land  
- \(W\) is row-normalized weighted endorsement matrix  

This is still \(O(\text{edges} \times \text{iters})\) — laptop-fast for millions of edges; cluster-fast for larger graphs. No LLM in the inner loop.

### 4. Query-time blend — still under our control

\[
\mathrm{score}(q, i) =
\mathrm{BM25}(q,i)
\cdot (1 + \gamma_r r_i)
\cdot \mathrm{qualityBoost}_i
\cdot \mathrm{slopPenalty}_i
\cdot \mathrm{malicePenalty}_i
\cdot \mathrm{adPenalty}(q,i)
\]

- No \(\gamma_n \mathrm{niche}\) term. Obscurity is not merit.
- Propaganda: multiply only if the **user** enables a strict filter; default is badge + optional soft damp, never a secret global blacklist  
- Ads: stronger demotion when query intent is informational (`how`, `why`, `notes`, `repair`) vs transactional

## Anti-gaming principles

1. **Authority is earned by craft, spent by linking.** Low-\(q\) pages cannot launder rank into high-\(q\) targets.
2. **Volume is suspicious.** Hosts that publish thousands of near-duplicate AI pages share a host-level prior cap.
3. **Engagement ≠ merit.** No click-feedback loop that rewards ragebait (that recreates ad-tech).
4. **Clusters don’t crown kings.** Dense mutual-link blocks get farm damping.
5. **Obscurity ≠ merit.** Niche discovery must not become a loophole for low-quality pages.
6. **Open schemas.** \(q_i\) labels and weights are versioned; communities can fork thresholds; the algorithm stays auditable.
7. **No ad auction.** There is no paid slot in \(\mathrm{score}\).

## Propaganda axis (orthogonal)

| Axis | Role |
| --- | --- |
| CraftRank \(r_i\) | “Is this an earned, high-craft node in the endorsement graph?” |
| Propaganda flag \(p_i\) | “Is this clear political mobilization content?” |

Users see badges. Rank does not pretend politics away. Coordinated propaganda *graphs* lose the ability to bootstrap authority through mutual linking (`\(\beta\, p_u p_v\)`).

## Relation to today’s toy scorer

`betterweb.rank.combine_score` is the **query-time stub** (BM25 relevance stand-in + judgment hints). CraftRank adds the missing **offline graph term** \(r_i\) once we have a crawl graph.

Migration path:

1. v0 — judgment-only re-rank (shipped)  
2. v0.1 — host-level priors + simple inlink counts weighted by source \(q\)  
3. v1 — full CraftRank iteration on endorsement graph  
4. v1+ — farm detector + ad_surface schema head + federated attestations as trusted teleport mass

## Why this is “rapid and smart”

- **Rapid:** same math class as PageRank; priors from a 340M local decision model run at crawl time, not per query over the whole web.  
- **Smart:** the model answers subjective gates (“slop?”, “craft?”, “scam?”); the graph answers structure (“who endorses whom for real?”).  
- **Ours:** every weight, schema, and damp factor is BetterWeb-controlled — no external rank API.

## Non-goals

- Training a click model on surveillance data  
- Selling “authority” to advertisers  
- One global political truth score that silently rewrites results for everyone
