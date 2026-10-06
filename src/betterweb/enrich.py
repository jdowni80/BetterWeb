"""Background GLiNER CraftRank: keep the model warm and fill heuristic rows."""

from __future__ import annotations

import threading

from betterweb import power
from betterweb.extract import JUDGE_MAX_CHARS
from betterweb.ingest import commercial_count
from betterweb.judge import PageJudge
from betterweb.score import craftrank_score
from betterweb.store import PageRow, PageStore

SLEEP_IDLE = 5.0
SLEEP_STEP = 0.4
SLEEP_BATTERY = 20.0


def score_backend(row: PageRow) -> str:
    return str(row.decisions.get("_backend") or "heuristic")


def enrich_row(store: PageStore, row: PageRow, judge: PageJudge) -> PageRow:
    blob = f"Title: {row.title}\nURL: {row.url}\n\n{row.content}".strip()
    if len(blob) > JUDGE_MAX_CHARS:
        blob = blob[:JUDGE_MAX_CHARS].rsplit(" ", 1)[0]
    judged = judge.judge_text(blob, title=row.title, url=row.url, source="background")
    model = str(judged.get("model") or "heuristic")
    if model != "heuristic":
        decisions = {**judged["decisions"], "_backend": model}
        row.decisions = decisions
        row.craftrank_score = craftrank_score(decisions)
        row.commercial_count = commercial_count(decisions)
        row.commercial_bias = float(decisions.get("commercial_bias") or 0)
        row.ad_use = float(decisions.get("ad_use") or 0)
        row.commercial_promotion = float(decisions.get("commercial_promotion") or 0)
        row.citation_use = float(decisions.get("citation_use") or 0)
        row.thought_quality = float(decisions.get("thought_quality") or 0)
        row.authorship_likeness = str(decisions.get("authorship_likeness") or "unknown")
    row.needs_enrichment = score_backend(row) == "heuristic"
    store.save_enrichment(row)
    return row


def run_enricher(store: PageStore, stop: threading.Event, *, judge: PageJudge | None = None) -> None:
    active = judge or PageJudge(lazy=True)
    loaded = False
    while not stop.is_set():
        if not power.on_ac_power():
            stop.wait(SLEEP_BATTERY)
            continue
        if not loaded:
            try:
                active._load()
                print(f"enricher gliner ready pending={store.pending_enrichment()}", flush=True)
            except Exception as exc:
                print(f"enricher gliner load failed ({exc}); will retry per page", flush=True)
            loaded = True
        row = store.next_enrichment()
        if row is None:
            stop.wait(SLEEP_IDLE)
            continue
        try:
            enrich_row(store, row, active)
        except Exception as exc:
            print(f"enricher fail {row.url}: {exc}", flush=True)
            stop.wait(SLEEP_IDLE)
            continue
        stop.wait(SLEEP_STEP)


def start_enricher(store: PageStore) -> threading.Event:
    stop = threading.Event()
    thread = threading.Thread(target=run_enricher, args=(store, stop), name="craftrank-enricher", daemon=True)
    thread.start()
    return stop
