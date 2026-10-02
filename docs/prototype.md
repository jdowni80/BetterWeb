# Prototype app

Local BetterWeb shell that wires the four pillars:

| Component | Integration |
| --- | --- |
| **CraftRank** | Offline graph score on the seed corpus; blended into every search hit |
| **Lightpanda** | `bin/lightpanda fetch --dump html` for ingest (telemetry disabled) |
| **Servo** | `/api/open` launches Servo if `/Applications/Servo.app` (or `servo` on PATH) exists |
| **Ladybird** | `/api/open` launches Ladybird if installed similarly |

## Run

```bash
./scripts/run_prototype.sh
```

UI: http://127.0.0.1:8742

## UI

Frontend follows [UI Design Brain](../.cursor/skills/ui-design-brain/SKILL.md):

- Skip link, sticky header, brand hero
- Search input with icon, clear control, ⌘K focus, primary “Search web”
- Segmented control for Live / Local
- Result **list** (not card grid) with semantic badges
- Skeleton loading (>300 ms), empty + error states with recovery CTAs

## API

- `GET /api/engines` — availability of CraftRank / Lightpanda / Servo / Ladybird
- `GET /api/search?q=&mode=live` — discover live web candidates → fetch → CraftRank × quality rank
- `GET /api/search?q=&mode=local` — seed corpus only
- `POST /api/ingest` — `{ "url", "judge": false, "prefer_lightpanda": true }`
- `POST /api/open` — `{ "engine": "servo"|"ladybird", "url" }`
- `POST /api/seed/reload` — reload offline corpus

Live mode uses public meta-search **only as a candidate source**. Scoring/ranking stays BetterWeb-owned.

## Notes

- Seed corpus under `data/seed/corpus.json` makes search work offline.
- Outbound fetch may fail in restricted networks; Lightpanda binary still reports as available.
- Servo/Ladybird are optional browse engines — not required for search ranking (BetterWeb owns CraftRank).
