import json

from handlers import progress


def _event(method, body=None, user="u-1"):
    return {
        "requestContext": {"http": {"method": method}},
        "headers": {"x-mango-user": user},
        "body": json.dumps(body) if body is not None else None,
    }


def test_get_defaults_when_absent(aws):
    resp = progress.handler(_event("GET"), None)
    body = json.loads(resp["body"])
    assert body["totalXP"] == 0
    assert body["level"] == 1
    assert body["currentStreak"] == 0


def test_put_then_get_roundtrip(aws):
    put = progress.handler(
        _event(
            "PUT",
            {
                "totalXP": 120,
                "level": 2,
                "currentStreak": 3,
                "longestStreak": 5,
                "freezesAvailable": 1,
                "lastActiveDay": "2026-06-25",
            },
        ),
        None,
    )
    assert put["statusCode"] == 200

    got = json.loads(progress.handler(_event("GET"), None)["body"])
    assert got["totalXP"] == 120
    assert got["level"] == 2
    assert got["currentStreak"] == 3
    assert got["lastActiveDay"] == "2026-06-25"
