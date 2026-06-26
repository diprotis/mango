"""POST /v1/events — accept a single analytics event from the app.

Thin handler: resolve the caller, validate the event ``type``, and forward it to
Firehose via ``shared.firehose.put_event`` (which lands it in the analytics S3
lake). The response is intentionally minimal — clients fire-and-forget.

The body is ``{ "type": "<event_type>", "props": { ... } }``. ``props`` is an
optional free-form object (e.g. ``{ "bookId": "…", "xp": 10 }``). Emission is
best-effort: even if Firehose is unavailable the request still succeeds, so a
flaky analytics pipeline never degrades the app.
"""

from shared import firehose
from shared.response import bad_request, json_response, ok, parse_body, user_id


def handler(event, context):
    try:
        uid = user_id(event)
    except PermissionError:
        return json_response(401, {"error": "unauthorized"})

    body = parse_body(event)
    event_type = (body.get("type") or "").strip()
    if not event_type:
        return bad_request("type is required")

    props = body.get("props")
    if props is not None and not isinstance(props, dict):
        return bad_request("props must be an object")

    firehose.put_event(event_type, uid, props or {})
    return ok({"accepted": True})
