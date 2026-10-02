"""BetterWeb prototype API — CraftRank search + engine adapters."""

from __future__ import annotations

from pathlib import Path

from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from betterweb.engines import engine_statuses, open_with_engine
from betterweb.judge import PageJudge
from betterweb.search import SearchIndex
from betterweb.search.ingest import ingest_url

REPO_ROOT = Path(__file__).resolve().parents[3]
SEED_PATH = REPO_ROOT / "data" / "seed" / "corpus.json"
WEB_DIST = REPO_ROOT / "web" / "dist"

app = FastAPI(title="BetterWeb", version="0.1.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

INDEX = SearchIndex()
JUDGE: PageJudge | None = None


@app.on_event("startup")
def _startup() -> None:
    if SEED_PATH.is_file():
        INDEX.load_seed(SEED_PATH)


class IngestBody(BaseModel):
    url: str
    judge: bool = Field(default=False, description="Run local GLiNER judge (slower)")
    prefer_lightpanda: bool = True


class OpenBody(BaseModel):
    url: str
    engine: str = Field(description="servo or ladybird")


@app.get("/api/health")
def health() -> dict:
    return {"ok": True, "docs": len(INDEX.docs)}


@app.get("/api/engines")
def engines() -> dict:
    return {"engines": [e.to_dict() for e in engine_statuses()]}


@app.get("/api/search")
def search(
    q: str = Query(..., min_length=1),
    limit: int = Query(default=20, ge=1, le=100),
) -> dict:
    hits = INDEX.search(q, limit=limit)
    return {
        "query": q,
        "count": len(hits),
        "ranking": "bm25 * craft * human-quality penalties",
        "hits": hits,
    }


@app.get("/api/corpus")
def corpus() -> dict:
    return {
        "count": len(INDEX.docs),
        "documents": [d.to_dict() for d in INDEX.docs],
    }


@app.post("/api/ingest")
def ingest(body: IngestBody) -> dict:
    global JUDGE
    judge = None
    if body.judge:
        if JUDGE is None:
            JUDGE = PageJudge(lazy=True)
        judge = JUDGE
    try:
        result = ingest_url(
            INDEX,
            body.url,
            judge=judge,
            prefer_lightpanda=body.prefer_lightpanda,
            run_judge=body.judge,
        )
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return result


@app.post("/api/open")
def open_url(body: OpenBody) -> dict:
    try:
        return open_with_engine(body.engine, body.url)
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.post("/api/seed/reload")
def reload_seed() -> dict:
    n = INDEX.load_seed(SEED_PATH)
    return {"reloaded": n}


if WEB_DIST.is_dir():
    app.mount("/assets", StaticFiles(directory=WEB_DIST / "assets"), name="assets")

    @app.get("/")
    def index_page() -> FileResponse:
        return FileResponse(WEB_DIST / "index.html")


def main() -> None:
    import uvicorn

    uvicorn.run(
        "betterweb.app.main:app",
        host="127.0.0.1",
        port=8742,
        reload=False,
    )


if __name__ == "__main__":
    main()
