"""CLI: betterweb-judge — local page judgment and mock re-rank."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from betterweb.extract import extract_from_html, extract_from_text, extract_from_url
from betterweb.judge import DEFAULT_MODEL, PageJudge
from betterweb.rank import rerank_from_decisions, rerank_hits


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="betterweb-judge",
        description=(
            "Judge page text with GLiNER2.5-Decide (local): badges for slop, "
            "bots, propaganda, quality, and niche value."
        ),
    )
    parser.add_argument(
        "--model",
        default=DEFAULT_MODEL,
        help=f"Hugging Face model id (default: {DEFAULT_MODEL})",
    )
    parser.add_argument(
        "--device",
        default=None,
        help="Optional map_location for AutoExtractor (cpu, mps, cuda)",
    )
    parser.add_argument(
        "--pretty",
        action="store_true",
        help="Pretty-print JSON",
    )

    sub = parser.add_subparsers(dest="command", required=True)

    judge = sub.add_parser("judge", help="Judge text, a file, or a URL")
    src = judge.add_mutually_exclusive_group(required=True)
    src.add_argument("--text", help="Raw text to judge")
    src.add_argument("--file", type=Path, help="Path to .txt or .html")
    src.add_argument("--url", help="Fetch and judge a public URL")
    judge.add_argument("--title", default="", help="Optional title override")

    rerank = sub.add_parser(
        "rerank",
        help="Re-rank mock search hits (JSON list) with the local judge",
    )
    rerank.add_argument(
        "hits",
        type=Path,
        help="JSON file: list of {id,title,url,snippet,relevance}",
    )
    rerank.add_argument(
        "--offline",
        action="store_true",
        help="Use precomputed decisions on each hit (no model load)",
    )

    return parser


def _load_input(args: argparse.Namespace):
    if args.text is not None:
        return extract_from_text(args.text, title=args.title, source="cli_text")
    if args.file is not None:
        raw = args.file.read_text(encoding="utf-8")
        suffix = args.file.suffix.lower()
        if suffix in {".html", ".htm"}:
            return extract_from_html(raw, source=str(args.file))
        return extract_from_text(raw, title=args.title, source=str(args.file))
    assert args.url is not None
    return extract_from_url(args.url)


def _dumps(payload: object, pretty: bool) -> str:
    if pretty:
        return json.dumps(payload, indent=2, ensure_ascii=False)
    return json.dumps(payload, ensure_ascii=False)


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)

    try:
        if args.command == "judge":
            page = _load_input(args)
            judge = PageJudge(model_id=args.model, map_location=args.device)
            result = judge.judge_text(
                page.judge_input,
                title=page.title,
                url=page.url,
                source=page.source,
            )
            print(_dumps(result.to_dict(), args.pretty))
            return 0

        if args.command == "rerank":
            hits = json.loads(args.hits.read_text(encoding="utf-8"))
            if not isinstance(hits, list):
                raise ValueError("hits JSON must be a list")
            if args.offline:
                ranked = rerank_from_decisions(hits)
            else:
                judge = PageJudge(model_id=args.model, map_location=args.device)
                ranked = rerank_hits(hits, judge)
            print(_dumps([h.to_dict() for h in ranked], args.pretty))
            return 0
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr)
        return 130
    except Exception as exc:  # noqa: BLE001 — CLI boundary
        print(f"error: {exc}", file=sys.stderr)
        return 1

    parser.error(f"unknown command: {args.command}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
