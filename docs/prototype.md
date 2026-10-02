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

## API

- `GET /api/engines` — availability of CraftRank / Lightpanda / Servo / Ladybird
- `GET /api/search?q=` — BM25 × CraftRank × quality penalties
- `POST /api/ingest` — `{ "url", "judge": false, "prefer_lightpanda": true }`
- `POST /api/open` — `{ "engine": "servo"|"ladybird", "url" }`
- `POST /api/seed/reload` — reload offline corpus

## Notes

- Seed corpus under `data/seed/corpus.json` makes search work offline.
- Outbound fetch may fail in restricted networks; Lightpanda binary still reports as available.
- Servo/Ladybird are optional browse engines — not required for search ranking (BetterWeb owns CraftRank).
