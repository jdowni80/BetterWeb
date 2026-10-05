"""CraftRank search API and local browser chrome."""

from __future__ import annotations

import os
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

from fastapi import FastAPI, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from betterweb.browse import open_page
from betterweb.enrich import start_enricher
from betterweb.search import search_index
from betterweb.store import PageStore

STATIC = Path(__file__).resolve().parent / "static"

app = FastAPI(title="BetterWeb", version="0.2.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

STORE = PageStore()
app.mount("/static", StaticFiles(directory=STATIC), name="static")


@app.get("/")
def chrome() -> FileResponse:
    return FileResponse(STATIC / "index.html")


@app.get("/api/health")
def health() -> dict:
    return {
        "ok": True,
        "docs": STORE.count(),
        "pending_enrichment": STORE.pending_enrichment(),
        "engine": "sqlite-crawlee",
    }


@app.get("/api/engines")
def engines() -> dict:
    return {
        "engines": [
            {
                "id": "html",
                "name": "HTML reader",
                "role": "text pages",
                "available": True,
                "path": None,
                "detail": "sanitized HTTP",
            },
            {
                "id": "playwright",
                "name": "Chromium",
                "role": "JS / media fallback",
                "available": True,
                "path": None,
                "detail": "Playwright",
            },
        ]
    }


@app.get("/api/search")
def search(
    q: str = Query(..., min_length=1),
    limit: int = Query(default=8, ge=1, le=50),
    candidates: int = Query(default=100, ge=10, le=200),
) -> dict:
    return search_index(STORE, q, limit=limit, candidates=candidates)


@app.get("/api/browse")
def browse(url: str = Query(..., min_length=8)) -> dict:
    view = open_page(url)
    landed = view.url or url
    queued = STORE.note_visit(landed)
    if view.html:
        STORE.refresh_snippet(landed, view.html)
    else:
        threading.Thread(target=STORE.refresh_snippet, args=(landed,), name="snippet-refresh", daemon=True).start()
    return {
        "url": view.url,
        "title": view.title,
        "engine": view.engine,
        "mode": view.mode,
        "html": view.html,
        "embed_url": view.embed_url,
        "queue": queued,
        "error": view.error,
    }


def _wait_for_health(port: int, attempts: int = 80) -> None:
    url = f"http://127.0.0.1:{port}/api/health"
    for _ in range(attempts):
        try:
            with urllib.request.urlopen(url, timeout=0.4) as response:
                if response.status == 200:
                    return
        except (urllib.error.URLError, TimeoutError, ConnectionError, OSError):
            time.sleep(0.1)
    raise RuntimeError(f"BetterWeb did not start on port {port}")


def _run_server(port: int) -> None:
    import uvicorn

    uvicorn.run(app, host="127.0.0.1", port=port, reload=False, log_level="info")


def main() -> None:
    start_enricher(STORE)
    port = int(os.environ.get("BETTERWEB_PORT", "8742"))
    _run_server(port)


def browse_main() -> None:
    start_enricher(STORE)
    port = int(os.environ.get("BETTERWEB_PORT", "8742"))
    thread = threading.Thread(target=_run_server, args=(port,), daemon=True)
    thread.start()
    _wait_for_health(port)
    url = f"http://127.0.0.1:{port}/"
    print(f"BetterWeb chrome {url}", flush=True)
    try:
        from playwright.sync_api import sync_playwright

        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(headless=False)
            page = browser.new_page()
            page.goto(url)
            while browser.is_connected() and any(ctx.pages for ctx in browser.contexts):
                time.sleep(0.4)
    except Exception as exc:
        print(f"headed Chromium unavailable ({exc}); opening the system browser", flush=True)
        import webbrowser

        webbrowser.open(url)
        thread.join()


if __name__ == "__main__":
    main()
