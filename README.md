# BetterWeb

A **browser and search engine** that favors human thought over AI slop, flags clear propaganda, skips ads and tracking, and helps people find high-quality human corners of the web (including obscure ones — without boosting obscurity alone).

## Principles

- **Quality ranking** — CraftRank + human craft / thought quality (not ads or SEO volume)
- **Filter obvious bots / AI filler** — demote synthetic spam without pretending the model is omniscient
- **Flag propaganda** — surface clear political propaganda; don’t silently rewrite the web
- **Niche discovery** — help find uncommon corners *when they are human + high quality*
- **Decentralized & local-first** — no ad auction, no behavioral dossier, no Chromium
- **Open-weight decisions** — local schema judgments via [GLiNER2.5-Decide](https://huggingface.co/fastino/GLiNER2.5-Decide)

## Product surface (Mac)

BetterWeb ships as a **native Mac app**: Apheleia-style vertical tabs + omnibox chrome, **Servo** for page rendering (no Chromium, no WKWebView), and the local CraftRank search API as a sidecar.

| Piece | Role |
| --- | --- |
| **SwiftUI chrome** (`macos/`) | Tabs, URL/search bar, new-tab search UI, settings |
| **betterweb-browse** (`rust/browse/`) | Out-of-process Servo (`libservo`) → RGBA frames |
| **CraftRank API** (`src/betterweb/`) | Live/local search, judgment, ingest |
| **Lightpanda** | Optional non-Chromium JS fetch for indexing |

```bash
cd ~/Documents/GitHub/BetterWeb
chmod +x scripts/run_mac_app.sh
./scripts/run_mac_app.sh
```

This builds the Servo helper, then launches the Mac chrome. The app starts the Python search sidecar on `127.0.0.1:8742` and the Servo browse helper for page views.

## Prototype web UI (dev fallback)

The Vite UI remains useful for search-only work without the Mac shell:

```bash
./scripts/run_prototype.sh
```

Open **[BetterWeb](http://127.0.0.1:8742)**.

**Live search** (default): discovers public-web candidates, fetches pages, then re-ranks with CraftRank + human-quality signals. Meta-search is only for discovery — BetterWeb owns ranking.

```bash
curl 'http://127.0.0.1:8742/api/search?q=vacuum%20tube%20heater%20wiring&mode=live'
```

Use `mode=local` for the offline seed corpus only.

Dev mode (API + Vite separately):

```bash
source .venv/bin/activate
pip install -e .
# terminal 1
python -m betterweb.app.main
# terminal 2
cd web && npm install && npm run dev   # http://127.0.0.1:8743
```

Optional engines:

- Lightpanda binary → `bin/lightpanda` (script downloads macOS aarch64 nightly; telemetry off via `LIGHTPANDA_DISABLE_TELEMETRY=true`)
- In-app Servo → `cargo build --release` in `rust/browse` (or `BETTERWEB_BROWSE`)
- Ladybird → optional external open later ([ladybird.org](https://ladybird.org/)); not the embed path

Docs: [`docs/CONCEPT.md`](docs/CONCEPT.md) · [`docs/craftrank.md`](docs/craftrank.md) · [`docs/architecture-web-stack.md`](docs/architecture-web-stack.md)

## Judge CLI

```bash
source .venv/bin/activate
pip install -e .
betterweb-judge judge --file examples/pages/human-niche.txt --pretty
betterweb-judge rerank examples/search/mock_hits.json --offline --pretty
python examples/craftrank_demo.py
```

## Layout

```text
macos/           # SwiftUI Mac browser chrome
rust/browse/     # Servo browse helper (JSON-lines IPC)
src/betterweb/   # judge, CraftRank, engines, search, API
web/             # Vite search UI (dev fallback)
data/seed/       # offline corpus for prototype search
bin/             # local Lightpanda (gitignored)
docs/            # concept + architecture
scripts/         # run_mac_app.sh, run_prototype.sh
```

## Remote

https://github.com/jdowni80/BetterWeb
