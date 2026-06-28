import json

from handlers import generate_roadmap, progress, roadmap_status
from shared import agent

_FAKE = {
    "title": "T",
    "summary": "S",
    "milestones": [
        {
            "title": "M",
            "subtitle": "s",
            "lessons": [
                {
                    "title": "L",
                    "readingSummary": "r",
                    "estimatedMinutes": 5,
                    "exercises": [
                        {
                            "kind": "reflection",
                            "prompt": "p",
                            "options": None,
                            "answerIndex": None,
                            "xp": 25,
                        }
                    ],
                }
            ],
        }
    ],
}


def _event(method, body=None, headers=None):
    return {
        "requestContext": {"http": {"method": method}},
        "headers": headers if headers is not None else {"x-mango-user": "u-1"},
        "body": json.dumps(body) if body is not None else None,
    }


def test_roadmap_accepts_inline_book(aws, monkeypatch):
    # The iOS app sends inline book text, not a bookId. Generation is async:
    # POST → 202 + jobId, then poll the job for the completed roadmap.
    monkeypatch.setattr(agent, "generate_roadmap", lambda *a, **k: dict(_FAKE))
    resp = generate_roadmap.handler(
        {
            "body": json.dumps(
                {
                    "book": {"title": "Deep Work", "text": "Focus compounds over time."},
                    "profile": {},
                }
            )
        },
        None,
    )
    assert resp["statusCode"] == 202
    job_id = json.loads(resp["body"])["jobId"]

    poll = roadmap_status.handler({"pathParameters": {"jobId": job_id}, "headers": {}}, None)
    assert poll["statusCode"] == 200
    job = json.loads(poll["body"])
    assert job["status"] == "complete"
    assert job["roadmap"]["milestones"][0]["lessons"][0]["exercises"][0]["xp"] == 25


def test_progress_requires_auth_in_prod(monkeypatch):
    monkeypatch.setenv("STAGE", "prod")
    resp = progress.handler(_event("GET", headers={}), None)
    assert resp["statusCode"] == 401


def test_progress_coerces_float_to_int(aws):
    put = progress.handler(_event("PUT", {"totalXP": 120.0, "level": 2.0}), None)
    assert put["statusCode"] == 200
    got = json.loads(progress.handler(_event("GET"), None)["body"])
    assert got["totalXP"] == 120
    assert isinstance(got["totalXP"], int)
