"""BetterWeb prototype API — CraftRank search + engine adapters."""

from __future__ import annotations

from pathlib import Path

from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from betterweb.engines import engine_statuses, open_with_engine
from betterweb.judge import PageJudge
from betterweb.media import MediaError, native_master_playlist
from betterweb.media import resolve as resolve_media
from betterweb.search import SearchIndex
from betterweb.search.ingest import ingest_url
from betterweb.search.live import live_search

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
    limit: int = Query(default=8, ge=1, le=30),
    mode: str = Query(
        default="live",
        description="live = discover+fetch+rank the web; local = seed corpus only",
    ),
    candidates: int = Query(default=8, ge=3, le=15),
    lightpanda: bool = Query(default=False, description="Prefer Lightpanda for page fetch"),
    judge: bool = Query(default=False, description="Run local GLiNER judge (slower)"),
) -> dict:
    if mode == "local":
        hits = INDEX.search(q, limit=limit)
        return {
            "query": q,
            "mode": "local",
            "count": len(hits),
            "ranking": "bm25 * craft * human-quality penalties",
            "hits": hits,
            "errors": [],
        }

    global JUDGE
    j = None
    if judge:
        if JUDGE is None:
            JUDGE = PageJudge(lazy=True)
        j = JUDGE
    try:
        return live_search(
            q,
            max_candidates=candidates,
            limit=limit,
            prefer_lightpanda=lightpanda,
            use_judge=judge,
            judge=j,
        )
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=502, detail=f"Live search failed: {exc}") from exc


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


@app.get("/api/media/resolve")
def media_resolve(url: str = Query(..., min_length=1)) -> dict:
    try:
        return resolve_media(url)
    except MediaError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@app.get("/api/media/hls/{video_id}.m3u8")
def media_hls(video_id: str) -> Response:
    try:
        body = native_master_playlist(video_id)
    except MediaError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=502, detail=f"Playlist fetch failed: {exc}") from exc
    return Response(content=body, media_type="application/vnd.apple.mpegurl")


@app.post("/api/seed/reload")
def reload_seed() -> dict:
    n = INDEX.load_seed(SEED_PATH)
    return {"reloaded": n}


if WEB_DIST.is_dir():
    app.mount("/assets", StaticFiles(directory=WEB_DIST / "assets"), name="assets")

    @app.get("/")
    def index_page() -> FileResponse:
        return FileResponse(WEB_DIST / "index.html")


def _exit_with_parent(parent_pid: int) -> None:
    """Exit when the embedding app dies so no stale sidecar keeps serving old code."""
    import os
    import threading
    import time

    def watch() -> None:
        while True:
            time.sleep(1.0)
            if os.getppid() != parent_pid:
                os._exit(0)

    threading.Thread(target=watch, name="parent-watchdog", daemon=True).start()


def main() -> None:
    import os

    import uvicorn

    parent = os.environ.get("BETTERWEB_PARENT_PID")
    if parent and parent.isdigit():
        _exit_with_parent(int(parent))

    uvicorn.run(
        "betterweb.app.main:app",
        host="127.0.0.1",
        port=int(os.environ.get("BETTERWEB_PORT", "8742")),
        reload=False,
        log_level=os.environ.get("BETTERWEB_LOG_LEVEL", "info"),
    )


if __name__ == "__main__":
    main()
