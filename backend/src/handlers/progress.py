"""GET/PUT /v1/me/progress — read or upsert the caller's gamification progress."""

import datetime
from decimal import Decimal

from shared.response import http_method, json_response, ok, parse_body, user_id
from shared.storage import table

DEFAULT_PROGRESS = {
    "totalXP": 0,
    "level": 1,
    "currentStreak": 0,
    "longestStreak": 0,
    "freezesAvailable": 0,
    "lastActiveDay": None,
}

_INT_FIELDS = {"totalXP", "level", "currentStreak", "longestStreak", "freezesAvailable"}


def _key(uid: str) -> dict:
    return {"PK": f"USER#{uid}", "SK": "PROGRESS"}


def _to_plain(value):
    if isinstance(value, Decimal):
        return int(value)
    return value


def handler(event, context):
    try:
        uid = user_id(event)
    except PermissionError:
        return json_response(401, {"error": "unauthorized"})

    method = http_method(event)

    if method == "GET":
        item = table().get_item(Key=_key(uid)).get("Item") or {}
        progress = {k: _to_plain(item.get(k, DEFAULT_PROGRESS[k])) for k in DEFAULT_PROGRESS}
        progress["updatedAt"] = item.get("updatedAt")
        return ok(progress)

    # PUT — coerce numeric fields to int so boto3 never sees a float.
    body = parse_body(event)
    progress = {}
    for field, default in DEFAULT_PROGRESS.items():
        value = body.get(field, default)
        if field in _INT_FIELDS and isinstance(value, (int, float)):
            progress[field] = int(value)
        else:
            progress[field] = value
    progress["updatedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    table().put_item(Item={**_key(uid), **progress})
    return ok(progress)
