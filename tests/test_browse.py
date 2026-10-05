from betterweb.browse import needs_chromium, open_page, reader_document, youtube_embed_url


def test_youtube_uses_embed():
    assert (
        youtube_embed_url("https://www.youtube.com/watch?v=26QPDBe-NB8")
        == "https://www.youtube.com/embed/26QPDBe-NB8"
    )


def test_js_hosts_need_chromium():
    assert needs_chromium("https://www.youtube.com/watch?v=26QPDBe-NB8")
    assert needs_chromium("https://constructionphysics.substack.com/p/foo")
    assert needs_chromium("https://scholar.google.com/")
    assert not needs_chromium("https://danluu.com/web-bloat/")


def test_form_heavy_pages_need_live_layout():
    html = "".join(f'<input name="q{i}">' for i in range(8))
    assert needs_chromium("https://example.org/search", html)
    assert not needs_chromium("https://example.org/essay", "<p>An essay with one <input type='hidden'></p>")


def test_scholar_opens_live_without_reader():
    view = open_page("https://scholar.google.com/")
    assert view.mode == "live"
    assert view.html == ""


def test_reader_strips_scripts_keeps_style_and_rewrites_links():
    html = reader_document(
        '<html><head><style>p{color:red}</style></head><body><script>alert(1)</script>'
        '<a href="/next">n</a><img src="/x.png"></body></html>',
        "https://danluu.com/web-bloat/",
    )
    assert "alert" not in html
    assert "p{color:red}" in html
    assert "https://danluu.com/next" in html
    assert "https://danluu.com/x.png" in html
    assert 'href="https://danluu.com/web-bloat/"' in html


def test_rejects_non_http():
    view = open_page("ftp://example.com/file")
    assert view.mode == "error"
