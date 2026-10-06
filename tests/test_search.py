from pathlib import Path
import threading

from betterweb.enrich import enrich_row, run_enricher
from betterweb.extract import PageExtract
from betterweb.ingest import ingest_extract
from betterweb.schema import numeric_decisions
from betterweb.search import search_index
from betterweb.store import PageStore


class _Judge:
    def __init__(self, model: str = "fastino/GLiNER2.5-Decide") -> None:
        self.model = model
        self.calls = 0

    def _load(self) -> None:
        return None

    def judge_text(self, text, title="", url="", source="search"):
        self.calls += 1
        high = numeric_decisions(
            {
                "is_human_generated": True,
                "is_ai_generated": False,
                "thought_quality": 0.9,
                "commercial_bias": 0.0,
                "ad_use": 0.0,
                "commercial_promotion": 0.0,
                "citation_use": 0.6,
            }
        )
        return {"model": self.model, "decisions": high}


def test_ingest_flags_heuristic_rows(tmp_path: Path):
    store = PageStore(tmp_path / "index.sqlite")
    ingest_extract(
        store,
        PageExtract(source="test", title="Essay", text="I measured the kernel.", url="https://ex.test/a"),
        fetch_engine="http",
    )
    row = store.get("https://ex.test/a")
    assert row is not None
    assert row.needs_enrichment is True
    assert row.decisions.get("_backend") == "heuristic"
    store.close()


def test_search_does_not_judge(tmp_path: Path):
    store = PageStore(tmp_path / "index.sqlite")
    ingest_extract(
        store,
        PageExtract(
            source="test",
            title="Kernel scheduler notes",
            text="I measured scheduler latency on Linux 6.1.",
            url="https://ex.test/kernel",
        ),
        fetch_engine="http",
    )
    before = store.get("https://ex.test/kernel")
    result = search_index(store, "kernel scheduler", limit=5)
    after = store.get("https://ex.test/kernel")
    assert after is not None and before is not None
    assert after.needs_enrichment is True
    assert after.craftrank_score == before.craftrank_score
    assert result["hits"]
    assert "bm25" in result["ranking"]
    store.close()


def test_background_enrichment_replaces_heuristic(tmp_path: Path):
    store = PageStore(tmp_path / "index.sqlite")
    ingest_extract(
        store,
        PageExtract(
            source="test",
            title="Kernel scheduler notes",
            text="I measured scheduler latency on Linux 6.1.",
            url="https://ex.test/kernel",
        ),
        fetch_engine="http",
    )
    before = store.get("https://ex.test/kernel")
    assert before is not None and before.needs_enrichment
    assert before.decisions.get("_backend") == "heuristic"
    enrich_row(store, before, _Judge())
    after = store.get("https://ex.test/kernel")
    assert after is not None
    assert after.needs_enrichment is False
    assert after.decisions.get("_backend") == "fastino/GLiNER2.5-Decide"
    store.close()


def test_enricher_loop_fills_then_idles(tmp_path: Path):
    store = PageStore(tmp_path / "index.sqlite")
    ingest_extract(
        store,
        PageExtract(source="test", title="Notes", text="I measured something specific.", url="https://ex.test/b"),
        fetch_engine="http",
    )
    stop = threading.Event()
    judge = _Judge()
    thread = threading.Thread(target=run_enricher, args=(store, stop), kwargs={"judge": judge}, daemon=True)
    thread.start()
    for _ in range(50):
        row = store.get("https://ex.test/b")
        if row and not row.needs_enrichment:
            break
        stop.wait(0.05)
    stop.set()
    thread.join(timeout=2)
    after = store.get("https://ex.test/b")
    assert after is not None
    assert after.needs_enrichment is False
    assert judge.calls >= 1
    store.close()


def test_failed_enrichment_keeps_flag(tmp_path: Path):
    store = PageStore(tmp_path / "index.sqlite")
    ingest_extract(
        store,
        PageExtract(source="test", title="Notes", text="I measured something specific.", url="https://ex.test/b"),
        fetch_engine="http",
    )
    row = store.get("https://ex.test/b")
    assert row is not None
    enrich_row(store, row, _Judge(model="heuristic"))
    after = store.get("https://ex.test/b")
    assert after is not None
    assert after.needs_enrichment is True
    store.close()


def test_enricher_skips_on_battery(tmp_path: Path, monkeypatch):
    monkeypatch.setattr("betterweb.power.on_ac_power", lambda: False)
    store = PageStore(tmp_path / "index.sqlite")
    ingest_extract(
        store,
        PageExtract(source="test", title="Notes", text="I measured something specific.", url="https://ex.test/b"),
        fetch_engine="http",
    )
    stop = threading.Event()
    judge = _Judge()
    thread = threading.Thread(target=run_enricher, args=(store, stop), kwargs={"judge": judge}, daemon=True)
    thread.start()
    stop.wait(0.15)
    stop.set()
    thread.join(timeout=2)
    after = store.get("https://ex.test/b")
    assert after is not None
    assert after.needs_enrichment is True
    assert judge.calls == 0
    store.close()
