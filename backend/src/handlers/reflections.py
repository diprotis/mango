"""GET/POST /v1/reflections — the caller's reflection journal.

Single-table items: PK=``USER#<sub>``, SK=``REFLECTION#<iso ts>`` (see
docs/DATA_MODEL.md). Because the SK is an ISO timestamp it sorts chronologically,
so listing newest-first is a reverse-ordered query. Handlers stay thin.
"""

import datetime

from boto3.dynamodb.conditions import Key

from shared.response import bad_request, http_method, json_response, ok, parse_body, user_id
from shared.storage import table


def _now_iso() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def _item_to_reflection(item: dict) -> dict:
    sk = item.get("SK", "")
    created_at = sk[len("REFLECTION#") :] if sk.startswith("REFLECTION#") else sk
    return {
        "createdAt": created_at,
        "text": item.get("text", ""),
        "chapterRef": item.get("chapterRef"),
    }


def handler(event, context):
    try:
        uid = user_id(event)
    except PermissionError:
        return json_response(401, {"error": "unauthorized"})

    method = http_method(event)

    if method == "GET":
        resp = table().query(
            KeyConditionExpression=Key("PK").eq(f"USER#{uid}")
            & Key("SK").begins_with("REFLECTION#"),
            ScanIndexForward=False,  # newest first
        )
        items = [_item_to_reflection(it) for it in resp.get("Items", [])]
        return ok({"items": items})

    # POST — append a reflection.
    body = parse_body(event)
    text = (body.get("text") or "").strip()
    if not text:
        return bad_request("text is required")
    chapter_ref = body.get("chapterRef")

    created_at = _now_iso()
    item = {
        "PK": f"USER#{uid}",
        "SK": f"REFLECTION#{created_at}",
        "text": text,
    }
    if chapter_ref is not None:
        item["chapterRef"] = chapter_ref
    table().put_item(Item=item)
    return ok({"createdAt": created_at, "text": text, "chapterRef": chapter_ref})
