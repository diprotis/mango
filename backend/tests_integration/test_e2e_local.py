"""End-to-end user journey through the Lambda handlers (moto-backed, CI-safe).

This is the *automated proof* that the Mango APIs persist state end to end. It
drives the real handler functions with simulated API-Gateway-v2 events (the exact
shape API Gateway delivers) and asserts the data actually lands in DynamoDB / S3
between steps. Only the Bedrock call is faked (monkeypatched ``shared.agent``);
everything else runs against moto. No network, no AWS account, no auth server.

Journey (single user, identified by an ``x-mango-user`` header — STAGE=test):
  (a) GET /v1/catalog → pick dummy-meditations → GET detail → get full text
  (b) POST /v1/roadmaps/generate with that text inline → 200 roadmap
  (c) POST /v1/me/library {bookId} → GET shows it
  (d) POST /v1/reflections → GET lists it
  (e) PUT /v1/me/progress → GET reads it back
  (f) DELETE /v1/me → library empty, S3 user objects gone, progress reset
"""

import json

import boto3

from handlers import (
    catalog,
    delete_account,
    generate_roadmap,
    library,
    profile,
    progress,
    reflections,
    roadmap_status,
)
from shared import agent
from shared.catalog_data import DUMMY_BOOK_ID
from tests_integration.conftest import BUCKET, REGION, TABLE

USER = "e2e-user-sub-123"


# ─────────────────────────── event + assertion helpers ──────────────────────


def _event(method, *, body=None, path_params=None, user=USER):
    """Build an API-Gateway-v2 proxy event, mirroring what API Gateway delivers."""
    return {
        "requestContext": {"http": {"method": method}},
        "headers": {"x-mango-user": user},
        "pathParameters": path_params,
        "body": json.dumps(body) if body is not None else None,
    }


def _call(handler_module, method, **kw):
    """Invoke a handler module's ``handler`` and return ``(status, parsed_body)``."""
    resp = handler_module.handler(_event(method, **kw), None)
    return resp["statusCode"], json.loads(resp["body"])


def _user_items(uid: str):
    from boto3.dynamodb.conditions import Key

    tbl = boto3.resource("dynamodb", region_name=REGION).Table(TABLE)
    return tbl.query(KeyConditionExpression=Key("PK").eq(f"USER#{uid}")).get("Items", [])


def _user_objects(uid: str):
    s3 = boto3.client("s3", region_name=REGION)
    return s3.list_objects_v2(Bucket=BUCKET, Prefix=f"users/{uid}/").get("Contents", [])


# Canned roadmap returned in place of a real Bedrock call (matches the shape the
# generate_roadmap handler / openapi Roadmap schema expects).
_CANNED_ROADMAP = {
    "title": "Reason in Daily Life",
    "summary": "Turn Stoic ideas into a daily practice.",
    "milestones": [
        {
            "title": "Foundations",
            "subtitle": "Meet the day with reason",
            "lessons": [
                {
                    "title": "The morning premeditation",
                    "readingSummary": "Expect friction; choose virtue anyway.",
                    "estimatedMinutes": 5,
                    "exercises": [
                        {
                            "kind": "reflection",
                            "prompt": "Name one obstacle you'll meet today.",
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


# ───────────────────────────────── the journey ──────────────────────────────


def test_full_user_journey_persists_end_to_end(aws, monkeypatch):
    # ---- (a) Browse the public catalog and fetch the dummy book's full text ----
    status, listing = _call(catalog, "GET")
    assert status == 200
    ids = [item["id"] for item in listing["items"]]
    assert DUMMY_BOOK_ID in ids
    # List view must not ship the heavy text.
    assert all("text" not in item for item in listing["items"])

    status, detail = _call(catalog, "GET", path_params={"id": DUMMY_BOOK_ID})
    assert status == 200
    book_text = detail["text"]
    assert isinstance(book_text, str) and len(book_text) > 50

    # ---- (b) Generate a roadmap from the inline text (Bedrock monkeypatched) ----
    # Async: POST returns 202 + jobId; with no worker configured it completes
    # inline, so the immediate poll returns the roadmap.
    monkeypatch.setattr(agent, "generate_roadmap", lambda *a, **k: dict(_CANNED_ROADMAP))
    status, enqueued = _call(
        generate_roadmap,
        "POST",
        body={
            "book": {"title": detail["title"], "author": detail["author"], "text": book_text},
            "profile": {},
        },
    )
    assert status == 202
    job_id = enqueued["jobId"]
    status, job = _call(roadmap_status, "GET", path_params={"jobId": job_id})
    assert status == 200
    assert job["status"] == "complete"
    roadmap = job["roadmap"]
    assert roadmap["title"] == _CANNED_ROADMAP["title"]
    assert roadmap["milestones"][0]["lessons"][0]["exercises"][0]["xp"] == 25

    # ---- (c) Add the book to the user's library, then list it back ----
    status, added = _call(library, "POST", body={"bookId": DUMMY_BOOK_ID})
    assert status == 200
    assert added["bookId"] == DUMMY_BOOK_ID

    status, lib = _call(library, "GET")
    assert status == 200
    assert [it["bookId"] for it in lib["items"]] == [DUMMY_BOOK_ID]

    # ---- (d) Record a reflection, then list it back ----
    status, reflection = _call(
        reflections, "POST", body={"text": "Today I expected friction and stayed calm."}
    )
    assert status == 200
    assert reflection["createdAt"]

    status, refs = _call(reflections, "GET")
    assert status == 200
    assert len(refs["items"]) == 1
    assert refs["items"][0]["text"] == "Today I expected friction and stayed calm."

    # ---- (e) (bonus) Save a profile, then upsert + read back progress ----
    status, _ = _call(profile, "PUT", body={"goals": ["focus"], "dailyGoalUnits": 4})
    assert status == 200

    status, _ = _call(
        progress,
        "PUT",
        body={
            "totalXP": 75,
            "level": 2,
            "currentStreak": 1,
            "longestStreak": 1,
            "freezesAvailable": 0,
            "lastActiveDay": "2026-06-25",
        },
    )
    assert status == 200

    status, prog = _call(progress, "GET")
    assert status == 200
    assert prog["totalXP"] == 75
    assert prog["level"] == 2
    assert prog["lastActiveDay"] == "2026-06-25"

    # Sanity: the user now actually has rows + an S3 artifact path is reachable.
    # (Seed one S3 object under the user prefix to prove DELETE cascades to S3 too;
    # the product handlers above only wrote DDB rows.)
    boto3.client("s3", region_name=REGION).put_object(
        Bucket=BUCKET, Key=f"users/{USER}/journal/r1.json", Body=b"{}"
    )
    assert len(_user_items(USER)) >= 3  # library + reflection + progress + profile
    assert len(_user_objects(USER)) == 1

    # ---- (f) Delete the account → all user data is erased ----
    status, deleted = _call(delete_account, "DELETE")
    assert status == 200
    assert deleted["deleted"] is True
    assert deleted["itemsDeleted"] >= 3
    assert deleted["objectsDeleted"] == 1

    # DDB rows gone, S3 objects gone.
    assert _user_items(USER) == []
    assert _user_objects(USER) == []

    # Library now lists nothing.
    status, lib_after = _call(library, "GET")
    assert status == 200
    assert lib_after["items"] == []

    # Reflections now list nothing.
    status, refs_after = _call(reflections, "GET")
    assert status == 200
    assert refs_after["items"] == []

    # Progress is back to defaults (no stored row → DEFAULT_PROGRESS).
    status, prog_after = _call(progress, "GET")
    assert status == 200
    assert prog_after["totalXP"] == 0
    assert prog_after["level"] == 1
    assert prog_after["currentStreak"] == 0


def test_delete_is_scoped_to_the_caller(aws, monkeypatch):
    """A second user's data survives the first user's account deletion."""
    # User A adds a book; user B adds a book.
    _call(library, "POST", body={"bookId": DUMMY_BOOK_ID}, user="user-a")
    _call(library, "POST", body={"bookId": "dummy-aesop"}, user="user-b")

    # Delete user A only.
    resp = delete_account.handler(_event("DELETE", user="user-a"), None)
    assert resp["statusCode"] == 200

    # User B is untouched.
    status, lib_b = _call(library, "GET", user="user-b")
    assert status == 200
    assert [it["bookId"] for it in lib_b["items"]] == ["dummy-aesop"]


def test_unknown_catalog_id_is_404(aws):
    status, body = _call(catalog, "GET", path_params={"id": "no-such-book"})
    assert status == 404
    assert "error" in body
