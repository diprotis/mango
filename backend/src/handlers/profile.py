"""GET/PUT /v1/me/profile — read or upsert the caller's profile.

Single-table item: PK=``USER#<sub>``, SK=``PROFILE`` (see docs/DATA_MODEL.md).
Handlers stay thin; identity comes from ``shared.response.user_id``.
"""

import datetime

from shared.response import http_method, json_response, ok, parse_body, user_id
from shared.storage import table

DEFAULT_PROFILE = {
    "goals": [],
    "interests": [],
    "readingLevel": "focused",
    "dailyGoalUnits": 3,
    "name": None,
}

_INT_FIELDS = {"dailyGoalUnits"}
_LIST_FIELDS = {"goals", "interests"}


def _key(uid: str) -> dict:
    return {"PK": f"USER#{uid}", "SK": "PROFILE"}


def handler(event, context):
    try:
        uid = user_id(event)
    except PermissionError:
        return json_response(401, {"error": "unauthorized"})

    method = http_method(event)

    if method == "GET":
        item = table().get_item(Key=_key(uid)).get("Item") or {}
        profile = {k: item.get(k, default) for k, default in DEFAULT_PROFILE.items()}
        # DynamoDB stores ints as Decimal; normalize to a plain int for JSON.
        profile["dailyGoalUnits"] = int(profile["dailyGoalUnits"])
        profile["updatedAt"] = item.get("updatedAt")
        return ok(profile)

    # PUT — coerce numeric fields to int so boto3 never sees a float.
    body = parse_body(event)
    profile = {}
    for field, default in DEFAULT_PROFILE.items():
        value = body.get(field, default)
        if field in _INT_FIELDS and isinstance(value, (int, float)):
            profile[field] = int(value)
        elif field in _LIST_FIELDS:
            profile[field] = list(value) if isinstance(value, list) else default
        else:
            profile[field] = value
    profile["updatedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    table().put_item(Item={**_key(uid), **profile})
    return ok(profile)
