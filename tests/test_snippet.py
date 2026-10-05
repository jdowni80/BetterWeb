from betterweb.extract import extract_from_html, make_snippet

WIKI = """Toggle the table of contents

Qt (software)

44 languages

Deutsch
Español
Français
日本語

Edit links

Article

Talk

Qt is a free and open-source widget toolkit for creating graphical user interfaces as well as cross-platform applications.
"""

SCHOLAR = """Loading...
The system can't perform the operation now. Try again later.
Cite
Advanced search
Find articles
with all of the words
with the exact phrase
"""


def test_snippet_skips_wikipedia_chrome():
    snippet = make_snippet(WIKI, "toolkit")
    assert "Toggle" not in snippet
    assert "languages" not in snippet
    assert snippet.startswith("Qt is a free and open-source widget toolkit")


def test_snippet_uses_intro_not_later_query_hit():
    body = (
        WIKI
        + "\n\nLater on, the library of Letourneau is mentioned only in a footnote about citations.\n"
    )
    snippet = make_snippet(body, "letourneau library")
    assert snippet.startswith("Qt is a free")


def test_snippet_empty_when_only_ui_chrome():
    assert make_snippet(SCHOLAR, "library") == ""


def test_extract_drops_wiki_language_rail():
    html = """
    <html><body><main>
      <div class="vector-toc">Toggle the table of contents</div>
      <p>Unix is a family of multitasking, multiuser computer operating systems.</p>
    </main></body></html>
    """
    extract = extract_from_html(html, url="https://en.wikipedia.org/wiki/Unix")
    assert "Toggle" not in extract.text
    assert "multitasking" in extract.text
