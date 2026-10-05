from bs4 import BeautifulSoup

from betterweb.extract import (
    _strip_chrome,
    _tag_attr,
    followable_citations,
    is_endling,
    is_media_url,
    is_spare_page,
    is_utility_url,
    sample_walk_urls,
    should_expand,
    should_follow,
    should_follow_citations,
)


def _page(words: int, links: list[str], paragraphs: int = 8, footer_links: list[str] | None = None) -> str:
    tokens = ["word"] * words
    chunk = max(1, len(tokens) // paragraphs)
    parts = []
    for i in range(paragraphs):
        parts.append(f"<p>{' '.join(tokens[i * chunk : (i + 1) * chunk])}</p>")
    anchors = "".join(f'<a href="{href}">ref</a>' for href in links)
    footer = ""
    if footer_links:
        footer = "<footer>" + "".join(f'<a href="{href}">nav</a>' for href in footer_links) + "</footer>"
    return f"<html><body><article>{''.join(parts)}{anchors}</article>{footer}</body></html>"


HUB = "https://danluu.com/web-bloat/"
CITES = [
    "https://example.org/paper-a",
    "https://example.org/paper-b",
    "https://example.org/paper-c",
]


def test_utility_paths_are_not_followed():
    assert is_utility_url("https://www.patreon.com/about")
    assert is_utility_url("https://www.youtube.com/howyoutubeworks")
    assert not should_follow(HUB, "https://www.patreon.com/about")
    assert should_follow(HUB, "https://idlewords.com/talks/website_obesity.htm")


def test_media_watch_is_fetched_but_does_not_expand():
    watch = "https://www.youtube.com/watch?v=26QPDBe-NB8"
    assert is_media_url(watch)
    assert should_follow(HUB, watch)
    assert not should_expand(watch, _page(800, CITES))
    assert not should_follow_citations(watch, _page(800, CITES))


def test_spare_page_is_stored_without_expand_or_citations():
    html = _page(40, CITES, paragraphs=2)
    assert is_spare_page(html)
    assert not should_expand(HUB, html)
    assert not should_follow_citations(HUB, html)


def test_link_dense_longform_is_walkable():
    many = [f"https://example.org/item-{i}" for i in range(12)]
    html = _page(520, many, paragraphs=2)
    assert not is_spare_page(html)
    assert should_expand(HUB, html)


def test_sample_walk_mixes_hosts():
    dests = [f"https://danluu.com/p{i}" for i in range(8)] + [
        f"https://other.test/p{i}" for i in range(8)
    ]
    picked = sample_walk_urls(HUB, dests, limit=8)
    hosts = {u.split("/")[2] for u in picked}
    assert "danluu.com" in hosts
    assert "other.test" in hosts
    assert len(picked) == 8


def test_endling_essay_still_follows_citations():
    html = _page(520, CITES[:2], footer_links=["https://danluu.com/about", "https://danluu.com/login"])
    assert not is_spare_page(html)
    assert is_endling(HUB, html)
    assert not should_expand(HUB, html)
    assert should_follow_citations(HUB, html)
    assert followable_citations(html, HUB) == CITES[:2]


def test_substantive_hub_expands():
    html = _page(520, CITES)
    assert should_expand(HUB, html)
    assert not should_follow_citations(HUB, html)


def test_strip_chrome_when_tag_attrs_is_none():
    class NoAttrs:
        attrs = None

    assert _tag_attr(NoAttrs(), "role") == ""
    soup = BeautifulSoup("<html><body><p>hello</p></body></html>", "lxml")
    for tag in soup.find_all(True):
        tag.attrs = None
    _strip_chrome(soup)


def test_footer_links_do_not_turn_a_leaf_into_a_hub():
    html = _page(
        520,
        CITES[:1],
        footer_links=[
            "https://example.org/extra-1",
            "https://example.org/extra-2",
            "https://example.org/extra-3",
        ],
    )
    assert is_endling(HUB, html)
    assert should_follow_citations(HUB, html)
