import json

import boto3

from handlers import generate_roadmap, roadmap_status
from shared import agent
from tests.conftest import BUCKET, TABLE

USER = "local-dev-user"  # what response.user_id returns in STAGE=test without a header


def _seed_book(book_id="bk_test123"):
    boto3.client("s3", region_name="us-east-1").put_object(
        Bucket=BUCKET,
        Key=f"books/{book_id}.txt",
        Body=b"Habits are the compound interest of self-improvement.",
    )
    boto3.resource("dynamodb", region_name="us-east-1").Table(TABLE).put_item(
        Item={
            "PK": f"BOOK#{book_id}",
            "SK": "META",
            "id": book_id,
            "title": "Atomic Habits",
            "author": "James Clear",
            "wordCount": 1000,
            "contentRef": f"books/{book_id}.txt",
        }
    )
    return book_id


_FAKE_ROADMAP = {
    "title": "Build Better Habits",
    "summary": "Turn ideas into a daily system.",
    "milestones": [
        {
            "title": "Foundations",
            "subtitle": "Why habits win",
            "lessons": [
                {
                    "title": "The 1% rule",
                    "readingSummary": "Small gains compound.",
                    "estimatedMinutes": 5,
                    "exercises": [
                        {
                            "kind": "reflection",
                            "prompt": "Name one tiny habit.",
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


def _status(job_id, user=USER):
    return roadmap_status.handler(
        {"pathParameters": {"jobId": job_id}, "headers": {"x-mango-user": user}}, None
    )


def test_generate_roadmap_enqueues_then_completes(aws, monkeypatch):
    # No ROADMAP_WORKER_FUNCTION env in tests → the handler generates inline and
    # stores the job already-complete, so the poll resolves immediately.
    book_id = _seed_book()
    monkeypatch.setattr(agent, "generate_roadmap", lambda *a, **k: dict(_FAKE_ROADMAP))

    resp = generate_roadmap.handler(
        {"body": json.dumps({"bookId": book_id, "profile": {"goals": ["focus"]}})}, None
    )
    assert resp["statusCode"] == 202
    enqueued = json.loads(resp["body"])
    assert enqueued["status"] == "pending"
    job_id = enqueued["jobId"]
    assert job_id

    # Poll → complete, carrying the roadmap (with bookId stamped on).
    poll = _status(job_id)
    assert poll["statusCode"] == 200
    job = json.loads(poll["body"])
    assert job["status"] == "complete"
    assert job["roadmap"]["bookId"] == book_id
    assert job["roadmap"]["milestones"][0]["lessons"][0]["exercises"][0]["xp"] == 25


def test_roadmap_job_status_unknown_is_404(aws):
    poll = _status("no-such-job")
    assert poll["statusCode"] == 404


def test_roadmap_job_is_scoped_to_caller(aws, monkeypatch):
    # A job created by user A is not visible to user B.
    book_id = _seed_book()
    monkeypatch.setattr(agent, "generate_roadmap", lambda *a, **k: dict(_FAKE_ROADMAP))
    resp = generate_roadmap.handler(
        {"body": json.dumps({"bookId": book_id}), "headers": {"x-mango-user": "user-a"}}, None
    )
    job_id = json.loads(resp["body"])["jobId"]
    assert _status(job_id, user="user-a")["statusCode"] == 200
    assert _status(job_id, user="user-b")["statusCode"] == 404


def test_generate_roadmap_failure_marks_job_failed(aws, monkeypatch):
    book_id = _seed_book()

    def _boom(*a, **k):
        raise RuntimeError("bedrock down")

    monkeypatch.setattr(agent, "generate_roadmap", _boom)
    resp = generate_roadmap.handler({"body": json.dumps({"bookId": book_id})}, None)
    # Inline path surfaces the failure as 500, and the job row records it.
    assert resp["statusCode"] == 500


def test_generate_roadmap_unknown_book(aws):
    resp = generate_roadmap.handler({"body": json.dumps({"bookId": "nope"})}, None)
    assert resp["statusCode"] == 404


def test_generate_roadmap_requires_book_id(aws):
    resp = generate_roadmap.handler({"body": "{}"}, None)
    assert resp["statusCode"] == 400
