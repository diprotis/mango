"""Pure text utilities: HTML extraction, reading stats, cover hue.

Deliberately dependency-free (stdlib only) so the Lambda needs no packaging.
"""

import hashlib
import html as _html
import re

_SCRIPT_RE = re.compile(r"<(script|style)[^>]*>.*?</\1>", re.IGNORECASE | re.DOTALL)
_TAG_RE = re.compile(r"<[^>]+>")
_INLINE_WS_RE = re.compile(r"[ \t\r\f\v]+")
_MULTI_NL_RE = re.compile(r"\n{3,}")
_WORD_RE = re.compile(r"\b\w+\b")
_TITLE_RE = re.compile(r"<title[^>]*>(.*?)</title>", re.IGNORECASE | re.DOTALL)


def extract_readable_text(html: str) -> str:
    """Best-effort readable-text extraction from raw HTML (no external deps)."""
    if not html:
        return ""
    text = _SCRIPT_RE.sub(" ", html)
    text = re.sub(r"<br\s*/?>", "\n", text, flags=re.IGNORECASE)
    text = re.sub(r"</(p|div|h[1-6]|li)>", "\n\n", text, flags=re.IGNORECASE)
    text = _TAG_RE.sub(" ", text)
    text = _html.unescape(text)
    text = _INLINE_WS_RE.sub(" ", text)
    text = _MULTI_NL_RE.sub("\n\n", text)
    return text.strip()


def extract_title(html: str, fallback: str = "Untitled") -> str:
    match = _TITLE_RE.search(html or "")
    if match:
        title = _html.unescape(_TAG_RE.sub("", match.group(1))).strip()
        if title:
            return title
    return fallback


def word_count(text: str) -> int:
    return len(_WORD_RE.findall(text or ""))


def estimated_minutes(words: int, wpm: int = 200) -> int:
    return max(1, round(words / wpm)) if words else 1


def cover_hue(seed: str) -> int:
    digest = hashlib.sha256((seed or "mango").encode("utf-8")).hexdigest()
    return int(digest[:6], 16) % 360


def excerpt(text: str, length: int = 400) -> str:
    flat = (text or "").strip().replace("\n", " ")
    flat = _INLINE_WS_RE.sub(" ", flat)
    return (flat[:length] + "…") if len(flat) > length else flat
