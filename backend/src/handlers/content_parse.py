"""POST /v1/content/parse — fetch + normalize source material into a Book."""

from shared import text as T
from shared.http import fetch_url
from shared.ids import new_id
from shared.response import bad_request, ok, parse_body, server_error
from shared.sources import gutenberg_text_url
from shared.storage import bucket_name, s3_client, table


def _first_line(text: str):
    for line in (text or "").splitlines():
        stripped = line.strip()
        if stripped:
            return stripped[:120]
    return None


def handler(event, context):
    body = parse_body(event)
    source = body.get("source") or {}
    stype = source.get("type")
    value = (source.get("value") or "").strip()

    if stype not in ("url", "text", "gutenberg"):
        return bad_request("source.type must be one of url|text|gutenberg")
    if stype != "text" and not value:
        return bad_request("source.value is required for url/gutenberg")

    try:
        if stype == "text":
            content = value
            title = source.get("title") or _first_line(content) or "Pasted Text"
        elif stype == "gutenberg":
            raw = fetch_url(gutenberg_text_url(value))
            content = raw
            title = source.get("title") or T.extract_title(raw, "Gutenberg Book")
        else:  # url
            raw = fetch_url(value)
            content = T.extract_readable_text(raw)
            title = source.get("title") or T.extract_title(raw, "Web Article")
    except Exception as exc:  # noqa: BLE001 — surface fetch/parse failure to client
        return server_error(f"fetch/parse failed: {exc}")

    content = content.strip()
    if len(content) < 50:
        return bad_request("parsed content is too short to build a journey")

    words = T.word_count(content)
    book_id = new_id("bk")
    content_key = f"books/{book_id}.txt"

    try:
        s3_client().put_object(
            Bucket=bucket_name(),
            Key=content_key,
            Body=content.encode("utf-8"),
            ContentType="text/plain; charset=utf-8",
        )
    except Exception as exc:  # noqa: BLE001
        return server_error(f"content store failed: {exc}")

    book = {
        "id": book_id,
        "title": title[:200],
        "author": source.get("author"),
        "wordCount": words,
        "estimatedMinutes": T.estimated_minutes(words),
        "coverHue": T.cover_hue(title),
        "excerpt": T.excerpt(content),
        "contentRef": content_key,
    }

    try:
        table().put_item(Item={"PK": f"BOOK#{book_id}", "SK": "META", **book})
    except Exception as exc:  # noqa: BLE001
        return server_error(f"metadata persist failed: {exc}")

    return ok(book)
