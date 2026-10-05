"""CLI: search the local index."""

from __future__ import annotations

import argparse
import json

from betterweb.search import search_index
from betterweb.store import PageStore, default_db_path


def search_main() -> None:
    parser = argparse.ArgumentParser(description="Search the BetterWeb SQLite index.")
    parser.add_argument("query")
    parser.add_argument("--limit", type=int, default=8)
    parser.add_argument("--db", default=None)
    args = parser.parse_args()
    store = PageStore(path=__import__("pathlib").Path(args.db) if args.db else None)
    result = search_index(store, args.query, limit=args.limit)
    store.close()
    print(json.dumps(result, indent=2))
    print(f"# db={args.db or default_db_path()} hits={result['count']}", file=__import__("sys").stderr)
