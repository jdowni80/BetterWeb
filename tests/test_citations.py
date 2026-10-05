from betterweb.extract import JUDGE_MAX_CHARS, PageExtract, is_homepage, should_expand, should_follow, should_follow_citations


def test_drops_wikipedia_interlanguage_and_project_pages():
    src = "https://en.wikipedia.org/wiki/Main_Page"
    assert not should_follow(src, "https://af.wikipedia.org/wiki/Wikipedia:Hulp")
    assert not should_follow(src, "https://en.wikipedia.org/wiki/Wikipedia:About")
    assert not should_follow(src, "https://en.wikipedia.org/wiki/Help:Contents")
    assert should_follow(src, "https://en.wikipedia.org/wiki/Operating_system")
    assert should_follow(src, "https://danluu.com/web-bloat/")
    assert not should_follow(src, "https://donate.wikimedia.org/?wmf_medium=sidebar")
    assert not should_follow(
        src, "https://en.wikipedia.org/w/index.php?title=Operating_system&action=edit"
    )


def test_keeps_ordinary_external_citation():
    assert should_follow("https://danluu.com/web-bloat/", "https://example.org/paper")


def test_drops_account_cart_search_and_media_noise():
    src = "https://danluu.com/web-bloat/"
    assert not should_follow(src, "https://www.patreon.com/login")
    assert not should_follow(src, "https://danluu.com/signup/")
    assert not should_follow(src, "https://shop.example.com/cart")
    assert not should_follow(src, "https://danluu.com/posts?search=bloat")
    assert not should_follow(src, "https://danluu.com/talk.pdf")
    assert should_follow(src, "https://idlewords.com/talks/website_obesity.htm")


def test_drops_feeds_shop_and_legal_keeps_docs():
    src = "https://danluu.com/web-bloat/"
    assert not should_follow(src, "https://ciechanow.ski/atom.xml")
    assert not should_follow(src, "https://example.com/product/watchmaking")
    assert not should_follow(src, "https://example.com/privacy-policy/")
    assert not should_follow(src, "https://www.patreon.com/about")
    assert not should_follow(src, "https://www.youtube.com/creators")
    assert should_follow(src, "https://jvns.ca/blog/2018/08/01/new-zine--help--i-don-t-understand-tcp-/")
    assert should_follow(src, "https://example.org/docs/tcp/")


def test_homepages_are_visited_but_never_expand():
    assert is_homepage("https://danluu.com/")
    assert is_homepage("https://ciechanow.ski")
    assert not is_homepage("https://danluu.com/web-bloat/")
    assert should_follow("https://danluu.com/web-bloat/", "https://danluu.com/")
    assert not should_expand("https://danluu.com/")
    assert not should_expand("https://ciechanow.ski/atom.xml")
    assert not should_follow_citations("https://danluu.com/")


def test_judge_input_is_truncated():
    extract = PageExtract(
        source="test",
        title="Essay",
        text="word " * 5000,
        url="https://danluu.com/web-bloat/",
    )
    assert len(extract.judge_input) <= JUDGE_MAX_CHARS
