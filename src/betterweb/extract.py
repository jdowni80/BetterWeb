"""Fetch and trim page text for local judgment."""

from __future__ import annotations

import re
from dataclasses import dataclass
from html import unescape
from urllib.parse import urlparse

import requests
from bs4 import BeautifulSoup

USER_AGENT = "BetterWebJudge/0.1 (+local; no-tracking)"
DEFAULT_TIMEOUT = 20
MAX_CHARS = 4000


@dataclass
class PageExtract:
    source: str
    title: str
    text: str
    url: str | None = None

    @property
    def judge_input(self) -> str:
        parts = []
        if self.title:
            parts.append(f"Title: {self.title}")
        if self.url:
            parts.append(f"URL: {self.url}")
        parts.append(self.text)
        return "\n\n".join(parts).strip()


def _clean_whitespace(text: str) -> str:
    text = unescape(text)
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def extract_from_html(html: str, *, url: str | None = None, source: str = "html") -> PageExtract:
    soup = BeautifulSoup(html, "lxml")
    for tag in soup(["script", "style", "noscript", "svg", "iframe"]):
        tag.decompose()

    title = ""
    if soup.title and soup.title.string:
        title = soup.title.string.strip()
    if not title:
        og = soup.find("meta", property="og:title")
        if og and og.get("content"):
            title = str(og["content"]).strip()

    description = ""
    for key in ("description", "og:description"):
        meta = soup.find("meta", attrs={"name": key}) or soup.find(
            "meta", property=key
        )
        if meta and meta.get("content"):
            description = str(meta["content"]).strip()
            break

    main = soup.find("article") or soup.find("main") or soup.body or soup
    paragraphs = [
        _clean_whitespace(p.get_text(" ", strip=True))
        for p in main.find_all(["p", "li", "h1", "h2", "h3"])
    ]
    paragraphs = [p for p in paragraphs if len(p) > 40]

    chunks: list[str] = []
    if description:
        chunks.append(description)
    chunks.extend(paragraphs)
    if not chunks:
        chunks.append(_clean_whitespace(main.get_text(" ", strip=True)))

    text = _clean_whitespace("\n\n".join(chunks))
    if len(text) > MAX_CHARS:
        text = text[: MAX_CHARS - 1].rsplit(" ", 1)[0] + "…"

    return PageExtract(source=source, title=title, text=text, url=url)


def extract_from_text(text: str, *, title: str = "", source: str = "text") -> PageExtract:
    cleaned = _clean_whitespace(text)
    if len(cleaned) > MAX_CHARS:
        cleaned = cleaned[: MAX_CHARS - 1].rsplit(" ", 1)[0] + "…"
    return PageExtract(source=source, title=title, text=cleaned)


def extract_from_url(url: str, *, timeout: int = DEFAULT_TIMEOUT) -> PageExtract:
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"}:
        raise ValueError(f"Only http(s) URLs are supported: {url}")

    response = requests.get(
        url,
        headers={"User-Agent": USER_AGENT, "Accept": "text/html,application/xhtml+xml"},
        timeout=timeout,
    )
    response.raise_for_status()
    return extract_from_html(response.text, url=url, source="url")
