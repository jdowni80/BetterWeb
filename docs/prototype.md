# Prototype app

BetterWeb has two shells:

| Surface | What it is |
| --- | --- |
| **Mac app** (`scripts/run_mac_app.sh`) | Product: SwiftUI chrome + Servo browse helper + CraftRank sidecar |
| **Web UI** (`scripts/run_prototype.sh`) | Search-only Vite prototype (dev fallback) |

## Mac browser (preferred)

```bash
./scripts/run_mac_app.sh
```

| Component | Integration |
| --- | --- |
| **CraftRank** | Python sidecar on `127.0.0.1:8742` |
| **Lightpanda** | Optional JS fetch for ingest/live search |
| **Servo** | `rust/browse` → `betterweb-browse` (libservo, no Chromium/WKWebView) |
| **Ladybird** | Optional external later — not required |

## Web prototype

```bash
./scripts/run_prototype.sh
```

UI: http://127.0.0.1:8742

Frontend follows [UI Design Brain](../.cursor/skills/ui-design-brain/SKILL.md).

## API

- `GET /api/engines` — CraftRank / Lightpanda / Servo / Ladybird
- `GET /api/search?q=&mode=live` — discover → fetch → CraftRank × quality
- `GET /api/search?q=&mode=local` — seed corpus only
- `POST /api/ingest` — `{ "url", "judge": false, "prefer_lightpanda": true }`
- `POST /api/open` — `{ "engine": "servo"|"ladybird", "url" }` (Mac app navigates in-process instead)
- `POST /api/seed/reload` — reload offline corpus

Live mode uses public meta-search **only as a candidate source**. Scoring/ranking stays BetterWeb-owned.
