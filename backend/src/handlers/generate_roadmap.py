"""POST /v1/roadmaps/generate — build a gamified roadmap with Claude.

Accepts EITHER an inline book ``{"book": {"title","author","text"}}`` (what the
iOS app sends) OR a stored ``bookId`` whose text is loaded from S3.
"""

import json

from shared import claude
from shared.response import bad_request, not_found, ok, parse_body, server_error
from shared.storage import bucket_name, s3_client, table


def handler(event, context):
    body = parse_body(event)
    book_id = body.get("bookId")
    profile = body.get("profile") or {}
    inline = body.get("book") or {}
    inline_text = (inline.get("text") or "").strip()

    if inline_text:
        book = {
            "title": inline.get("title") or "Untitled",
            "author": inline.get("author"),
            "wordCount": len(inline_text.split()),
        }
        full_text = inline_text
    elif book_id:
        item = table().get_item(Key={"PK": f"BOOK#{book_id}", "SK": "META"}).get("Item")
        if not item:
            return not_found("unknown bookId")
        try:
            obj = s3_client().get_object(Bucket=bucket_name(), Key=item["contentRef"])
            full_text = obj["Body"].read().decode("utf-8", errors="replace")
        except Exception as exc:  # noqa: BLE001
            return server_error(f"failed to load book content: {exc}")
        book = {
            "title": item.get("title"),
            "author": item.get("author"),
            "wordCount": int(item.get("wordCount", 0)),
        }
    else:
        return bad_request("provide either book.text (inline) or bookId")

    try:
        roadmap = claude.generate_roadmap(book, profile, full_text[:12000])
    except Exception as exc:  # noqa: BLE001
        return server_error(f"roadmap generation failed: {exc}")

    if book_id:
        roadmap["bookId"] = book_id
        # Best-effort cache as a JSON string (sidesteps DynamoDB float/Decimal limits).
        try:
            table().put_item(
                Item={"PK": f"BOOK#{book_id}", "SK": "ROADMAP", "roadmap": json.dumps(roadmap)}
            )
        except Exception:  # noqa: BLE001
            pass

    return ok(roadmap)
