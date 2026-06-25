"""Source helpers (Project Gutenberg URL building, etc.)."""

import re

_GUTENBERG_ID_RE = re.compile(r"(\d+)")


def gutenberg_id(value: str) -> str:
    """Accept a raw id, an ebooks URL, or 'gutenberg:1080' and return the id."""
    match = _GUTENBERG_ID_RE.search(str(value))
    if not match:
        raise ValueError("could not find a Gutenberg id")
    return match.group(1)


def gutenberg_text_url(value: str) -> str:
    book_id = gutenberg_id(value)
    return f"https://www.gutenberg.org/cache/epub/{book_id}/pg{book_id}.txt"
