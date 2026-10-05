"""Load a URL for the browser: raw HTML first, Playwright+Chromium if that fails."""

from __future__ import annotations

from dataclasses import dataclass
from urllib.parse import parse_qs, urljoin, urlparse

import requests
from bs4 import BeautifulSoup

from betterweb.extract import USER_AGENT, extract_from_html, is_media_url
from betterweb.ingest import is_js_host, is_thin

TRACKER_PATTERNS = [
    "*doubleclick*",
    "*googlesyndication*",
    "*google-analytics*",
    "*googletagmanager*",
    "*facebook.net*",
    "*scorecardresearch*",
    "*adsystem*",
    "*hotjar*",
]

_THIN_AFTER_PLAYWRIGHT = 80
_APP_HOST_SUFFIXES = (
    "google.com",
    "googleusercontent.com",
    "gstatic.com",
)
_FORM_LIVE_COUNT = 6


@dataclass
class BrowseView:
    url: str
    title: str
    engine: str
    mode: str
    html: str = ""
    embed_url: str | None = None
    error: str | None = None


def youtube_embed_url(url: str) -> str | None:
    dest = urlparse(url)
    host = dest.netloc.lower()
    if host.endswith("youtu.be"):
        vid = dest.path.strip("/").split("/", 1)[0]
        return f"https://www.youtube.com/embed/{vid}" if vid else None
    if "youtube.com" not in host:
        return None
    if dest.path.lower().rstrip("/") == "/embed":
        return url
    vid = parse_qs(dest.query).get("v", [""])[0]
    if vid:
        return f"https://www.youtube.com/embed/{vid}"
    return None


def is_app_host(url: str) -> bool:
    host = urlparse(url).netloc.lower()
    return any(host == suffix or host.endswith("." + suffix) for suffix in _APP_HOST_SUFFIXES)


def _form_control_count(html: str) -> int:
    soup = BeautifulSoup(html or "", "lxml")
    return len(soup.find_all(["input", "select", "textarea", "button"]))


def needs_chromium(url: str, html: str = "") -> bool:
    if is_media_url(url) or is_js_host(url) or is_app_host(url):
        return True
    return bool(html) and _form_control_count(html) >= _FORM_LIVE_COUNT


def _live_view(url: str, title: str = "", error: str | None = None) -> BrowseView:
    return BrowseView(
        url=url,
        title=title or url,
        engine="webkit",
        mode="live",
        error=error,
    )


def reader_document(html: str, url: str) -> str:
    soup = BeautifulSoup(html or "", "lxml")
    for tag in soup(["script", "noscript", "template"]):
        tag.decompose()
    for tag in list(soup.find_all(True)):
        attrs = getattr(tag, "attrs", None)
        if not isinstance(attrs, dict):
            continue
        for key in list(attrs):
            if str(key).lower().startswith("on"):
                del attrs[key]
    for tag in soup.find_all(["a", "img", "source", "link"]):
        for attr in ("href", "src", "srcset"):
            raw = tag.get(attr)
            if isinstance(raw, str) and raw and not raw.startswith(("data:", "javascript:", "#")):
                tag[attr] = urljoin(url, raw)
    if soup.head is None and soup.html is not None:
        soup.html.insert(0, soup.new_tag("head"))
    if soup.head is not None and not soup.head.find("base"):
        base = soup.new_tag("base", href=url)
        soup.head.insert(0, base)
    if soup.body is None:
        return f"<article><p>{soup.get_text(' ', strip=True)}</p></article>"
    return str(soup)


def _http_html(url: str) -> tuple[str, str | None]:
    try:
        response = requests.get(
            url,
            timeout=12,
            headers={"User-Agent": USER_AGENT, "Accept": "text/html,application/xhtml+xml"},
        )
        response.raise_for_status()
        header = response.headers.get("content-type", "").lower()
        if "charset=" in header:
            return response.text, None
        try:
            return response.content.decode("utf-8"), None
        except UnicodeDecodeError:
            return response.content.decode(response.apparent_encoding or "latin-1", errors="replace"), None
    except Exception as exc:
        return "", str(exc)


def _playwright_html(url: str) -> tuple[str, str | None]:
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        return "", "Playwright is not installed (pip install -e '.[crawl]')"
    try:
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(headless=True)
            page = browser.new_page()
            for pattern in TRACKER_PATTERNS:
                page.route(pattern, lambda route: route.abort())
            page.goto(url, wait_until="domcontentloaded", timeout=25_000)
            html = page.content()
            browser.close()
        return html, None
    except Exception as exc:
        return "", str(exc)


def open_page(url: str) -> BrowseView:
    dest = urlparse(url)
    if dest.scheme not in {"http", "https"} or not dest.netloc:
        return BrowseView(url=url, title="", engine="none", mode="error", error="Only http(s) URLs can be opened.")

    embed = youtube_embed_url(url)
    if embed:
        return BrowseView(url=url, title="YouTube", engine="playwright", mode="embed", embed_url=embed)

    if needs_chromium(url):
        return _live_view(url)

    html, http_error = _http_html(url)
    extract = extract_from_html(html, url=url, source="http") if html else None
    http_works = bool(extract and not is_thin(extract) and not needs_chromium(url, html))
    if http_works and extract is not None:
        return BrowseView(
            url=url,
            title=extract.title or url,
            engine="html",
            mode="reader",
            html=reader_document(html, url),
        )

    if html or not http_error:
        return _live_view(url, extract.title if extract else url)

    rendered, pw_error = _playwright_html(url)
    if rendered:
        extract = extract_from_html(rendered, url=url, source="playwright")
        if not is_thin(extract) or len(extract.text) >= _THIN_AFTER_PLAYWRIGHT:
            if needs_chromium(url, rendered):
                return _live_view(url, extract.title or url)
            return BrowseView(
                url=url,
                title=extract.title or url,
                engine="playwright",
                mode="reader",
                html=reader_document(rendered, url),
            )
        return _live_view(url, extract.title or url)

    reason = pw_error or http_error or "Could not load page."
    return BrowseView(url=url, title="", engine="webkit", mode="error", error=reason)
