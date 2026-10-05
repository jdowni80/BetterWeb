"""Fetch and trim page text."""

from __future__ import annotations

import random
import re
from dataclasses import dataclass
from html import unescape
from urllib.parse import urljoin, urlparse

import requests
from bs4 import BeautifulSoup

USER_AGENT = "BetterWeb/0.2 (+local; no-tracking)"
DEFAULT_TIMEOUT = 12
STORE_CHARS = 2_000
MAX_CHARS = STORE_CHARS
JUDGE_MAX_CHARS = 2_000


def clip_store_text(text: str, limit: int = STORE_CHARS) -> str:
    blob = text or ""
    if len(blob) <= limit:
        return blob
    return blob[:limit].rsplit(" ", 1)[0]


@dataclass
class PageExtract:
    source: str
    title: str
    text: str
    html: str = ""
    url: str | None = None

    @property
    def judge_input(self) -> str:
        parts = []
        if self.title:
            parts.append(f"Title: {self.title}")
        if self.url:
            parts.append(f"URL: {self.url}")
        parts.append(self.text)
        blob = "\n\n".join(parts).strip()
        if len(blob) > JUDGE_MAX_CHARS:
            return blob[:JUDGE_MAX_CHARS].rsplit(" ", 1)[0]
        return blob


def _clean_whitespace(text: str) -> str:
    text = unescape(text)
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


_WIKI_CHROME_SELECTORS = (
    ".mw-jump-link",
    ".vector-toc",
    "#vector-toc",
    ".mw-portlet-lang",
    "#p-lang-btn",
    ".vector-page-toolbar",
    ".vector-header-container",
    "#siteSub",
    ".mw-indicators",
    ".noprint",
)

_CHROME_LINES = frozenset(
    {
        "toggle the table of contents",
        "edit links",
        "article",
        "talk",
        "read",
        "edit",
        "view history",
        "tools",
        "contents",
        "cite",
        "advanced search",
        "sign in",
        "loading",
        "loading...",
        "my profile",
        "my library",
        "settings",
        "appearance",
        "add topic",
        "jump to content",
        "jump to search",
        "from wikipedia, the free encyclopedia",
        "switch to legacy parser",
    }
)
_CHROME_PREFIXES = (
    "toggle the table",
    "jump to ",
    "from wikipedia",
    "the system can't perform",
    "find articles",
    "with all of the words",
    "with the exact phrase",
    "with at least one",
    "without the words",
    "where my words occur",
    "return articles",
    "this article",
    "switch to legacy",
    "not to be confused",
    "for the company",
    "original author",
    "stable release",
)


def _drop_chrome_nodes(soup) -> None:
    _strip_chrome(soup)
    for selector in _WIKI_CHROME_SELECTORS:
        try:
            for tag in soup.select(selector):
                tag.decompose()
        except Exception:
            continue


def is_chrome_line(line: str) -> bool:
    text = re.sub(r"\s+", " ", line).strip().lower()
    if not text or text in _CHROME_LINES:
        return True
    if any(text.startswith(prefix) for prefix in _CHROME_PREFIXES):
        return True
    if text.endswith(" languages") and text.split()[0].isdigit():
        return True
    words = text.split()
    if len(words) <= 3 and "." not in text and len(text) < 32:
        return True
    if "." not in text and 4 <= len(words) <= 12 and " is " not in f" {text} ":
        return True
    return False


def is_prose_line(line: str) -> bool:
    compact = re.sub(r"\s+", " ", line).strip()
    if is_chrome_line(compact) or len(compact) < 50:
        return False
    letters = sum(ch.isalpha() for ch in compact)
    if letters < 32:
        return False
    words = compact.split()
    if len(words) >= 8:
        titled = sum(1 for word in words if word[:1].isupper())
        if titled / len(words) > 0.7:
            return False
    return True


def make_snippet(content: str, query: str = "", *, limit: int = 240) -> str:
    """Start of the article body after UI chrome, not a later query hit."""
    del query
    parts = []
    for part in re.split(r"\n+", content or ""):
        line = re.sub(r"\s+", " ", part).strip()
        if line and not is_chrome_line(line):
            parts.append(line)
    pick = " ".join(parts).strip()
    if len(pick) > limit:
        pick = pick[: limit - 1].rsplit(" ", 1)[0] + "…"
    return pick


def extract_from_html(html: str, url: str | None = None, source: str = "html") -> PageExtract:
    soup = BeautifulSoup(html, "lxml")
    for tag in soup(["script", "style", "noscript", "svg"]):
        tag.decompose()
    _drop_chrome_nodes(soup)
    title = ""
    if soup.title and soup.title.string:
        title = soup.title.string.strip()
    if not title:
        og = soup.find("meta", property="og:title")
        if og:
            title = str(og.get("content") or "").strip()
    root = soup.find("article") or soup.find("main") or soup.body or soup
    raw = root.get_text("\n") if root else ""
    kept = [line.strip() for line in raw.splitlines() if line.strip() and not is_chrome_line(line)]
    text = _clean_whitespace("\n\n".join(kept))
    text = clip_store_text(text)
    return PageExtract(source=source, title=title, text=text, html=html, url=url)


def extract_from_text(text: str, title: str = "", url: str | None = None) -> PageExtract:
    cleaned = clip_store_text(_clean_whitespace(text))
    return PageExtract(source="text", title=title, text=cleaned, url=url)


def extract_from_url(url: str, timeout: int = DEFAULT_TIMEOUT) -> PageExtract:
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"}:
        raise ValueError(f"Only http(s) URLs are supported: {url}")
    response = requests.get(
        url,
        timeout=timeout,
        headers={"User-Agent": USER_AGENT, "Accept": "text/html,application/xhtml+xml"},
    )
    response.raise_for_status()
    return extract_from_html(_decode_body(response), url=url, source="http")


def _decode_body(response: requests.Response) -> str:
    header = response.headers.get("content-type", "").lower()
    if "charset=" in header:
        return response.text
    try:
        return response.content.decode("utf-8")
    except UnicodeDecodeError:
        return response.content.decode(response.apparent_encoding or "latin-1", errors="replace")


_WIKI_SKIP_PREFIX = (
    "wikipedia:",
    "help:",
    "special:",
    "talk:",
    "user:",
    "template:",
    "mediawiki:",
    "category:",
    "file:",
    "portal:",
    "draft:",
    "module:",
    "mediawiki talk:",
)


def _registrable(host: str) -> str:
    parts = host.lower().split(".")
    if len(parts) >= 2:
        return ".".join(parts[-2:])
    return host.lower()


_SKIP_HOSTS = {
    "donate.wikimedia.org",
    "foundation.wikimedia.org",
    "login.wikimedia.org",
}

ENQUEUE_LIMIT = 12
MAX_CRAWL_DEPTH = 2
SPARE_MIN_WORDS = 500
SPARE_LINK_TO_P_RATIO = 5.0
ENDLING_MIN_CONTENT_LINKS = 3

_NOISE_SEGMENTS = frozenset(
    {
        "login",
        "signup",
        "register",
        "logout",
        "cart",
        "checkout",
        "sharer",
        "shop",
        "store",
        "product",
        "products",
        "collections",
        "privacy-policy",
        "terms-of-service",
        "cookie-policy",
        "tickets",
        "knowledgebase",
        "feed",
        "rss",
        "atom",
    }
)
_UTILITY_SEGMENTS = frozenset(
    {
        "about",
        "ads",
        "creators",
        "terms",
        "privacy",
        "howyoutubeworks",
    }
)
_MEDIA_SEGMENTS = frozenset({"watch", "video", "embed", "track", "podcast"})
_MEDIA_IFRAME = re.compile(r"youtube|youtu\.be|vimeo|player\.", re.I)
_NOISE_QUERY = ("search=", "filter=", "sort=")
_NOISE_SUFFIXES = (
    ".pdf",
    ".jpg",
    ".jpeg",
    ".png",
    ".gif",
    ".zip",
    ".mp4",
    ".mp3",
    ".xml",
    ".rss",
    ".atom",
    ".webmanifest",
)
_HOMEPAGE_PATHS = frozenset({"", "/index.html", "/index.htm", "/index.php"})

# Crawlee enqueue_links exclude list (JS-style globs + bare account paths).
NOISE_GLOBS = (
    "**/login",
    "**/login/**",
    "**/signup",
    "**/signup/**",
    "**/register",
    "**/register/**",
    "**/logout",
    "**/logout/**",
    "**/cart",
    "**/cart/**",
    "**/checkout",
    "**/checkout/**",
    "**/*?*search=*",
    "**/*?*filter=*",
    "**/*?*sort=*",
    "**/*.{pdf,jpg,jpeg,png,gif,zip,mp4,mp3,xml,rss,atom,webmanifest}",
    "**/share?*",
    "**/sharer/**",
    "**/feed",
    "**/feed/**",
    "**/rss",
    "**/rss/**",
    "**/shop/**",
    "**/store/**",
    "**/product/**",
    "**/products/**",
    "**/collections/**",
    "**/privacy-policy/**",
    "**/terms-of-service/**",
    "**/cookie-policy/**",
    "**/tickets/**",
    "**/knowledgebase/**",
    "**/about",
    "**/about/**",
    "**/ads",
    "**/ads/**",
    "**/creators",
    "**/creators/**",
    "**/terms",
    "**/terms/**",
    "**/privacy",
    "**/privacy/**",
    "**/howyoutubeworks",
    "**/howyoutubeworks/**",
)


def is_homepage(url: str) -> bool:
    path = urlparse(url).path.lower().rstrip("/")
    return path in _HOMEPAGE_PATHS


def is_feed_url(url: str) -> bool:
    path = urlparse(url).path.lower()
    if any(path.endswith(suffix) for suffix in (".xml", ".rss", ".atom", ".webmanifest")):
        return True
    segments = {part for part in path.split("/") if part}
    return bool(segments & {"feed", "rss", "atom"})


def _path_segments(url: str) -> set[str]:
    return {part for part in urlparse(url).path.lower().split("/") if part}


def is_utility_url(url: str) -> bool:
    return bool(_path_segments(url) & _UTILITY_SEGMENTS)


def is_media_url(url: str) -> bool:
    dest = urlparse(url)
    if _path_segments(url) & _MEDIA_SEGMENTS:
        return True
    host = dest.netloc.lower()
    query = dest.query.lower()
    if "youtube.com" in host or host.endswith("youtu.be"):
        if "v=" in query or dest.path.lower().rstrip("/") in {"/watch", "/embed", "/shorts"}:
            return True
    return False


def _tag_attr(tag, name: str) -> str:
    attrs = getattr(tag, "attrs", None)
    if not isinstance(attrs, dict):
        return ""
    return str(attrs.get(name) or "")


def _strip_chrome(soup):
    for tag in soup(["script", "style", "noscript", "svg", "header", "nav", "footer"]):
        tag.decompose()
    for tag in list(soup.find_all(True)):
        if _tag_attr(tag, "role").lower() == "navigation":
            tag.decompose()
    return soup


def _content_root(html: str):
    soup = _strip_chrome(BeautifulSoup(html or "", "lxml"))
    return soup.find("article") or soup.find("main") or soup.body or soup


def _content_words(html: str) -> int:
    root = _content_root(html)
    if root is None:
        return 0
    return len(_clean_whitespace(root.get_text("\n")).split())


def is_media_page(url: str, html: str = "") -> bool:
    if is_media_url(url):
        return True
    if not html:
        return False
    soup = BeautifulSoup(html, "lxml")
    has_player = soup.find("video") is not None
    if not has_player:
        for frame in soup.find_all("iframe", src=True):
            if _MEDIA_IFRAME.search(str(frame.get("src") or "")):
                has_player = True
                break
    if not has_player:
        return False
    return _content_words(html) < SPARE_MIN_WORDS


def is_spare_page(html: str) -> bool:
    """Thin pages only. Link-dense longform (Wikipedia, essays) stays walkable."""
    if not html:
        return False
    return _content_words(html) < SPARE_MIN_WORDS


def content_link_urls(html: str, base_url: str) -> list[str]:
    root = _content_root(html)
    if root is None:
        return []
    found: list[str] = []
    seen: set[str] = set()
    for anchor in root.find_all("a", href=True):
        href = str(anchor.get("href", "")).strip()
        if not href or href.startswith("#") or href.startswith("javascript:"):
            continue
        absolute = urljoin(base_url, href).split("#", 1)[0]
        if absolute in seen:
            continue
        seen.add(absolute)
        found.append(absolute)
    return found


def sample_walk_urls(source_url: str, dests: list[str], *, limit: int = ENQUEUE_LIMIT) -> list[str]:
    """Random sample of neighbors, mixing same-host and off-site when both exist."""
    if limit <= 0 or not dests:
        return []
    src_host = urlparse(source_url).netloc.lower()
    same: list[str] = []
    other: list[str] = []
    seen: set[str] = set()
    for dest in dests:
        if dest in seen:
            continue
        seen.add(dest)
        if urlparse(dest).netloc.lower() == src_host:
            same.append(dest)
        else:
            other.append(dest)
    random.shuffle(same)
    random.shuffle(other)
    if same and other:
        off = min(len(other), max(limit // 2, 1))
        on = min(len(same), limit - off)
        picked = other[:off] + same[:on]
        leftover = limit - len(picked)
        if leftover:
            picked.extend((other[off:] + same[on:])[:leftover])
        return picked
    pool = same or other
    return pool[:limit]


def is_endling(url: str, html: str) -> bool:
    if not html:
        return False
    n = 0
    for dest in content_link_urls(html, url):
        if should_follow(url, dest):
            n += 1
            if n >= ENDLING_MIN_CONTENT_LINKS:
                return False
    return True


def _is_dead_end(url: str, html: str = "") -> bool:
    return (
        is_homepage(url)
        or is_feed_url(url)
        or is_utility_url(url)
        or is_media_page(url, html)
        or is_spare_page(html)
    )


def should_expand(url: str, html: str = "") -> bool:
    """Substantive hubs may call enqueue_links. GLiNER is not consulted."""
    if _is_dead_end(url, html):
        return False
    return not is_endling(url, html)


def should_follow_citations(url: str, html: str = "") -> bool:
    """Leaf essays still spend budget on citations; media/spare/hubs do not use this path."""
    if _is_dead_end(url, html):
        return False
    return is_endling(url, html)


def is_noise_url(url: str) -> bool:
    dest = urlparse(url)
    path = dest.path.lower()
    query = dest.query.lower()
    segments = {part for part in path.split("/") if part}
    if segments & _NOISE_SEGMENTS or segments & _UTILITY_SEGMENTS:
        return True
    if any(path.endswith(suffix) for suffix in _NOISE_SUFFIXES):
        return True
    if any(token in query for token in _NOISE_QUERY):
        return True
    if path.rstrip("/").endswith("/share") and query:
        return True
    return False


def should_follow(source_url: str, dest_url: str) -> bool:
    """Keep editorial links; drop chrome, noise paths, interwiki, and project namespaces."""
    dest = urlparse(dest_url)
    src = urlparse(source_url)
    if dest.scheme not in {"http", "https"} or not dest.netloc:
        return False
    host = dest.netloc.lower()
    if host in _SKIP_HOSTS or host.endswith(".wikimedia.org"):
        return False
    if is_noise_url(dest_url):
        return False
    query = dest.query.lower()
    if "action=" in query or "redlink=" in query:
        return False
    if dest.path.startswith("/w/index.php"):
        return False
    if host.endswith("wikipedia.org"):
        src_host = src.netloc.lower()
        if host != src_host:
            return False
        slug = dest.path.split("/wiki/", 1)[-1] if "/wiki/" in dest.path else dest.path
        head = slug.split("/", 1)[0].replace("_", " ").lower()
        if ":" in head:
            return False
    return True


def followable_citations(html: str, base_url: str, *, limit: int = 8) -> list[str]:
    out: list[str] = []
    for url in content_link_urls(html, base_url):
        if not should_follow(base_url, url):
            continue
        out.append(url)
        if len(out) >= limit:
            break
    return out


def citation_urls(html: str, base_url: str) -> list[str]:
    if not html:
        return []
    soup = BeautifulSoup(html, "lxml")
    found: list[str] = []
    seen: set[str] = set()
    for anchor in soup.find_all("a", href=True):
        href = str(anchor.get("href", "")).strip()
        if not href or href.startswith("#") or href.startswith("javascript:"):
            continue
        absolute = urljoin(base_url, href).split("#", 1)[0]
        if not absolute.startswith("http"):
            continue
        if absolute in seen:
            continue
        seen.add(absolute)
        found.append(absolute)
    return found
