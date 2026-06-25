import json

import boto3

from handlers import generate_roadmap
from shared import claude
from tests.conftest import BUCKET, TABLE


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


def test_generate_roadmap_happy_path(aws, monkeypatch):
    book_id = _seed_book()
    monkeypatch.setattr(claude, "generate_roadmap", lambda *a, **k: dict(_FAKE_ROADMAP))
    resp = generate_roadmap.handler(
        {"body": json.dumps({"bookId": book_id, "profile": {"goals": ["focus"]}})}, None
    )
    assert resp["statusCode"] == 200
    body = json.loads(resp["body"])
    assert body["bookId"] == book_id
    assert body["milestones"][0]["lessons"][0]["exercises"][0]["xp"] == 25


def test_generate_roadmap_unknown_book(aws):
    resp = generate_roadmap.handler({"body": json.dumps({"bookId": "nope"})}, None)
    assert resp["statusCode"] == 404


def test_generate_roadmap_requires_book_id(aws):
    resp = generate_roadmap.handler({"body": "{}"}, None)
    assert resp["statusCode"] == 400
