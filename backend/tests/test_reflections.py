import json

import boto3

from handlers import reflections

TABLE = "MangoTest"


def _event(method, body=None, user="u-1"):
    return {
        "requestContext": {"http": {"method": method}},
        "headers": {"x-mango-user": user},
        "body": json.dumps(body) if body is not None else None,
    }


def test_empty_lists_nothing(aws):
    resp = reflections.handler(_event("GET"), None)
    body = json.loads(resp["body"])
    assert resp["statusCode"] == 200
    assert body["items"] == []


def test_post_then_get(aws):
    post = reflections.handler(
        _event("POST", {"text": "Atomic habits compound.", "chapterRef": "ch-3"}), None
    )
    assert post["statusCode"] == 200
    created = json.loads(post["body"])
    assert created["text"] == "Atomic habits compound."
    assert created["chapterRef"] == "ch-3"
    assert created["createdAt"]

    listed = json.loads(reflections.handler(_event("GET"), None)["body"])["items"]
    assert len(listed) == 1
    assert listed[0]["text"] == "Atomic habits compound."
    assert listed[0]["chapterRef"] == "ch-3"


def test_post_requires_text(aws):
    resp = reflections.handler(_event("POST", {"text": "   "}), None)
    assert resp["statusCode"] == 400


def test_listed_newest_first(aws):
    # Seed deterministic timestamps so ordering is unambiguous.
    table = boto3.resource("dynamodb", region_name="us-east-1").Table(TABLE)
    for ts, txt in [
        ("2026-06-01T10:00:00+00:00", "first"),
        ("2026-06-02T10:00:00+00:00", "second"),
        ("2026-06-03T10:00:00+00:00", "third"),
    ]:
        table.put_item(Item={"PK": "USER#u-1", "SK": f"REFLECTION#{ts}", "text": txt})

    items = json.loads(reflections.handler(_event("GET"), None)["body"])["items"]
    assert [it["text"] for it in items] == ["third", "second", "first"]


def test_reflections_are_per_user(aws):
    reflections.handler(_event("POST", {"text": "u1 note"}, user="u-1"), None)
    reflections.handler(_event("POST", {"text": "u2 note"}, user="u-2"), None)
    u1 = json.loads(reflections.handler(_event("GET", user="u-1"), None)["body"])["items"]
    u2 = json.loads(reflections.handler(_event("GET", user="u-2"), None)["body"])["items"]
    assert [it["text"] for it in u1] == ["u1 note"]
    assert [it["text"] for it in u2] == ["u2 note"]
