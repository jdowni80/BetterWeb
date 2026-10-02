"""Fetch pages via Lightpanda (preferred) or plain HTTP; judge; index."""

from __future__ import annotations

import hashlib
from typing import Any
from urllib.parse import urlparse

from betterweb.engines import fetch_with_lightpanda, lightpanda_path
from betterweb.extract import extract_from_html, extract_from_url
from betterweb.judge import PageJudge
from betterweb.search import SearchIndex


def _doc_id_for_url(url: str) -> str:
    host = urlparse(url).netloc or "page"
    digest = hashlib.sha1(url.encode("utf-8")).hexdigest()[:10]
    return f"{host}:{digest}"


def ingest_url(
    index: SearchIndex,
    url: str,
    *,
    judge: PageJudge | None = None,
    prefer_lightpanda: bool = True,
    run_judge: bool = True,
) -> dict[str, Any]:
    html: str
    engine: str
    if prefer_lightpanda and lightpanda_path():
        try:
            html = fetch_with_lightpanda(url)
            engine = "lightpanda"
        except Exception:  # noqa: BLE001
            page = extract_from_url(url)
            engine = "http"
            text = page.judge_input
            title = page.title or url
            decisions = _maybe_judge(judge, text, title, url, run_judge)
            doc = index.add_document(
                doc_id=_doc_id_for_url(url),
                title=title,
                url=url,
                text=page.text,
                decisions=decisions,
                fetch_engine=engine,
            )
            index.rebuild()
            return {"document": doc.to_dict(), "fetch_engine": engine}
    else:
        page = extract_from_url(url)
        engine = "http"
        decisions = _maybe_judge(judge, page.judge_input, page.title, url, run_judge)
        doc = index.add_document(
            doc_id=_doc_id_for_url(url),
            title=page.title or url,
            url=url,
            text=page.text,
            decisions=decisions,
            fetch_engine=engine,
        )
        index.rebuild()
        return {"document": doc.to_dict(), "fetch_engine": engine}

    page = extract_from_html(html, url=url, source="lightpanda")
    decisions = _maybe_judge(judge, page.judge_input, page.title, url, run_judge)
    doc = index.add_document(
        doc_id=_doc_id_for_url(url),
        title=page.title or url,
        url=url,
        text=page.text,
        decisions=decisions,
        fetch_engine=engine,
    )
    index.rebuild()
    return {"document": doc.to_dict(), "fetch_engine": engine}


def _maybe_judge(
    judge: PageJudge | None,
    text: str,
    title: str,
    url: str,
    run_judge: bool,
) -> dict[str, Any]:
    if not run_judge or judge is None:
        return {
            "authorship_likeness": "unknown",
            "bot_spam": "uncertain",
            "propaganda_signal": "uncertain",
            "malice": "uncertain",
            "thought_quality": "3",
            "niche_value": "common",
        }
    result = judge.judge_text(text, title=title, url=url, source="ingest")
    return result.decisions
