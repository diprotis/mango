"""GET/POST /v1/me/library and DELETE /v1/me/library/{bookId}.

Per-user book references live as PK=``USER#<sub>``, SK=``BOOK#<bookId>`` with a
GSI1 (``USER#<sub>`` / ``ADDED#<iso ts>``) so the library can be listed in
add-order. Handlers stay thin; identity comes from ``shared.response.user_id``.
"""

import datetime

from boto3.dynamodb.conditions import Key

from shared.response import (
    bad_request,
    http_method,
    json_response,
    ok,
    parse_body,
    user_id,
)
from shared.storage import table


def _now_iso() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def _book_id_from_path(event: dict):
    params = event.get("pathParameters") or {}
    return params.get("bookId")


def _item_to_ref(item: dict) -> dict:
    sk = item.get("SK", "")
    book_id = sk[len("BOOK#") :] if sk.startswith("BOOK#") else sk
    return {"bookId": book_id, "addedAt": item.get("addedAt")}


def handler(event, context):
    try:
        uid = user_id(event)
    except PermissionError:
        return json_response(401, {"error": "unauthorized"})

    method = http_method(event)

    if method == "GET":
        resp = table().query(
            KeyConditionExpression=Key("PK").eq(f"USER#{uid}") & Key("SK").begins_with("BOOK#")
        )
        items = [_item_to_ref(it) for it in resp.get("Items", [])]
        return ok({"items": items})

    if method == "DELETE":
        book_id = _book_id_from_path(event)
        if not book_id:
            return bad_request("bookId path parameter is required")
        table().delete_item(Key={"PK": f"USER#{uid}", "SK": f"BOOK#{book_id}"})
        return ok({"deleted": book_id})

    # POST — add a book reference to the caller's library.
    body = parse_body(event)
    book_id = (body.get("bookId") or "").strip()
    if not book_id:
        return bad_request("bookId is required")

    added_at = _now_iso()
    table().put_item(
        Item={
            "PK": f"USER#{uid}",
            "SK": f"BOOK#{book_id}",
            "GSI1PK": f"USER#{uid}",
            "GSI1SK": f"ADDED#{added_at}",
            "addedAt": added_at,
        }
    )
    return ok({"bookId": book_id, "addedAt": added_at})
