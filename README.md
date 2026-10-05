# BetterWeb

Owned search: Crawlee fills a local SQLite index. CraftRank is a page score from the local decision model. Queries use BM25, then blend stored craft with `nomic-embed-text` relevance. There is no DuckDuckGo / Google re-ranker.

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -e ".[dev,crawl,judge]"
playwright install chromium
betterweb-crawl --max-requests 20
betterweb-search "operating systems"
betterweb-browse   # headed Chromium chrome; HTML first, Playwright fallback
betterweb-indexd   # background HTTP crawl; heuristic scores; 500 MB cap
# API only
betterweb-app   # http://127.0.0.1:8742/
```

CraftRank uses GLiNER2.5-Decide by default (`fastino/GLiNER2.5-Decide`). If the model is missing or a call fails, the regex heuristic is used. `--no-judge` forces the heuristic. Crawl direction is heuristic (path shape + page structure), not GLiNER. Embeddings call local Ollama (`nomic-embed-text`) and ignore HTTP proxies so `127.0.0.1:11434` is reachable. The crawl starts from article/essay URLs, not site homepages.

Ladybird is not part of this search slice. Browse-path Chromium/HTML rendering is a later change.
