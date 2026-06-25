from shared import text as T


def test_extract_readable_text_strips_markup_and_scripts():
    html = (
        "<html><head><title>Hi</title><style>.a{}</style></head>"
        "<body><script>evil()</script><h1>Heading</h1><p>One &amp; two.</p>"
        "<p>Second.</p></body></html>"
    )
    out = T.extract_readable_text(html)
    assert "evil" not in out
    assert ".a{}" not in out
    assert "Heading" in out
    assert "One & two." in out
    assert "Second." in out


def test_extract_title():
    assert T.extract_title("<title>The Book</title>") == "The Book"
    assert T.extract_title("<p>no title</p>", "Fallback") == "Fallback"


def test_word_count_and_minutes():
    assert T.word_count("one two three") == 3
    assert T.estimated_minutes(0) == 1
    assert T.estimated_minutes(400, wpm=200) == 2


def test_cover_hue_is_stable_and_in_range():
    h1 = T.cover_hue("Atomic Habits")
    h2 = T.cover_hue("Atomic Habits")
    assert h1 == h2
    assert 0 <= h1 < 360


def test_excerpt_truncates():
    assert T.excerpt("short text") == "short text"
    long = "x " * 500
    assert T.excerpt(long, 50).endswith("…")
