import json

from handlers import profile


def _event(method, body=None, user="u-1"):
    return {
        "requestContext": {"http": {"method": method}},
        "headers": {"x-mango-user": user},
        "body": json.dumps(body) if body is not None else None,
    }


def test_get_defaults_when_absent(aws):
    resp = profile.handler(_event("GET"), None)
    body = json.loads(resp["body"])
    assert resp["statusCode"] == 200
    assert body["goals"] == []
    assert body["interests"] == []
    assert body["readingLevel"] == "focused"
    assert body["dailyGoalUnits"] == 3
    assert body["name"] is None
    assert body["updatedAt"] is None


def test_put_then_get_roundtrip(aws):
    put = profile.handler(
        _event(
            "PUT",
            {
                "goals": ["learn faster", "remember more"],
                "interests": ["productivity", "psychology"],
                "readingLevel": "deep",
                "dailyGoalUnits": 5,
                "name": "Ada",
            },
        ),
        None,
    )
    assert put["statusCode"] == 200

    got = json.loads(profile.handler(_event("GET"), None)["body"])
    assert got["goals"] == ["learn faster", "remember more"]
    assert got["interests"] == ["productivity", "psychology"]
    assert got["readingLevel"] == "deep"
    assert got["dailyGoalUnits"] == 5
    assert got["name"] == "Ada"
    assert got["updatedAt"] is not None


def test_daily_goal_coerced_to_int(aws):
    # A float from JSON must not be written to DynamoDB as a float.
    profile.handler(_event("PUT", {"dailyGoalUnits": 4.0}), None)
    got = json.loads(profile.handler(_event("GET"), None)["body"])
    assert got["dailyGoalUnits"] == 4
    assert isinstance(got["dailyGoalUnits"], int)


def test_profiles_are_per_user(aws):
    profile.handler(_event("PUT", {"name": "Ada"}, user="u-1"), None)
    profile.handler(_event("PUT", {"name": "Grace"}, user="u-2"), None)
    u1 = json.loads(profile.handler(_event("GET", user="u-1"), None)["body"])
    u2 = json.loads(profile.handler(_event("GET", user="u-2"), None)["body"])
    assert u1["name"] == "Ada"
    assert u2["name"] == "Grace"
