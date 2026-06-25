"""HTTP helpers shared by Lambda handlers (API Gateway v2 proxy format)."""

import base64
import json
import os

CORS_HEADERS = {
    "content-type": "application/json",
    "access-control-allow-origin": "*",
}


def json_response(status: int, body) -> dict:
    return {"statusCode": status, "headers": CORS_HEADERS, "body": json.dumps(body)}


def ok(body) -> dict:
    return json_response(200, body)


def bad_request(message: str) -> dict:
    return json_response(400, {"error": message})


def not_found(message: str = "not found") -> dict:
    return json_response(404, {"error": message})


def server_error(message: str) -> dict:
    return json_response(500, {"error": message})


def parse_body(event: dict) -> dict:
    raw = event.get("body") or "{}"
    if event.get("isBase64Encoded"):
        raw = base64.b64decode(raw).decode("utf-8")
    try:
        parsed = json.loads(raw)
        return parsed if isinstance(parsed, dict) else {}
    except (json.JSONDecodeError, TypeError):
        return {}


def http_method(event: dict) -> str:
    return (
        event.get("requestContext", {})
        .get("http", {})
        .get("method", event.get("httpMethod", "GET"))
    )


def user_id(event: dict) -> str:
    """Resolve the caller's id from the Cognito JWT claims, with a dev fallback."""
    try:
        claims = event["requestContext"]["authorizer"]["jwt"]["claims"]
        resolved = claims.get("sub") or claims.get("username")
        if resolved:
            return resolved
    except (KeyError, TypeError):
        pass
    # In deployed stages the Cognito authorizer guarantees claims; never trust a
    # client-supplied identity header there.
    if os.environ.get("STAGE", "dev") in ("prod", "beta"):
        raise PermissionError("unauthenticated request: missing JWT claims")
    headers = event.get("headers") or {}
    return headers.get("x-mango-user", "local-dev-user")
