"""CLI entry to run the BetterWeb prototype server."""

from __future__ import annotations


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
