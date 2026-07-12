"""Async roadmap-generation jobs (shared by the POST handler + the worker).

Roadmap generation on Opus 4.8 takes ~20-35s — longer than the API Gateway HTTP
API 30s integration timeout. So generation is asynchronous:

  POST /v1/roadmaps/generate  → persist a job (status "pending"), async-invoke the
                                worker Lambda, return 202 {jobId,status}.
  worker (roadmap_worker)     → generate (up to the Lambda's own 600s), write the
                                roadmap back to the job (status "complete"/"failed").
  GET  /v1/roadmaps/jobs/{id} → read the job's current status/result.

Jobs are single-table rows scoped to the caller:
  PK = USER#<uid>, SK = ROADMAPJOB#<jobId>.
"""

import datetime
import json
import os
import uuid

from . import catalog_data
from .prompts import GROUNDING_CHAR_BUDGET
from .storage import bucket_name, s3_client, table

PENDING = "pending"
COMPLETE = "complete"
FAILED = "failed"

_JOB_SK_PREFIX = "ROADMAPJOB#"

# DynamoDB items are hard-capped at 400KB. Full-book grounding (GROUNDING_CHAR_BUDGET,
# up to 600k chars) can exceed that, so large excerpts spill to S3 and the job row
# stores a pointer instead. Small excerpts stay inline (fast path, one read).
_INLINE_EXCERPT_MAX = 300_000  # chars; leaves item headroom for book/profile/keys


def _excerpt_s3_key(uid: str, job_id: str) -> str:
    # Lives under users/<uid>/ so the account-erasure sweep (delete_account's
    # users/<uid>/ prefix delete) removes it automatically.
    return f"users/{uid}/roadmap-jobs/{job_id}/excerpt.txt"


def new_job_id() -> str:
    return uuid.uuid4().hex


def _now_iso() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def _job_key(uid: str, job_id: str) -> dict:
    return {"PK": f"USER#{uid}", "SK": f"{_JOB_SK_PREFIX}{job_id}"}


def resolve_book(body: dict) -> tuple:
    """Resolve the generation inputs from a request body.

    Returns ``(book, full_text, book_id, error)`` where ``error`` is a
    ``(status, message)`` tuple when the input is invalid / not found, else None.
    Mirrors the original synchronous handler's inline-or-bookId logic.
    """
    book_id = body.get("bookId")
    inline = body.get("book") or {}
    inline_text = (inline.get("text") or "").strip()

    if inline_text:
        book = {
            "title": inline.get("title") or "Untitled",
            "author": inline.get("author"),
            "wordCount": len(inline_text.split()),
        }
        return book, inline_text, None, None

    if book_id:
        # First try a user-imported book (DynamoDB BOOK#<id> + text in S3).
        item = table().get_item(Key={"PK": f"BOOK#{book_id}", "SK": "META"}).get("Item")
        if item:
            try:
                obj = s3_client().get_object(Bucket=bucket_name(), Key=item["contentRef"])
                full_text = obj["Body"].read().decode("utf-8", errors="replace")
            except Exception as exc:  # noqa: BLE001
                return None, None, None, (500, f"failed to load book content: {exc}")
            book = {
                "title": item.get("title"),
                "author": item.get("author"),
                "wordCount": int(item.get("wordCount", 0)),
            }
            return book, full_text, book_id, None

        # Otherwise fall back to the bundled catalog (text is inline, no S3).
        entry = catalog_data.get_item(book_id)
        if entry:
            book = {
                "title": entry.get("title"),
                "author": entry.get("author"),
                "wordCount": int(entry.get("wordCount", 0)),
            }
            return book, entry.get("text", ""), book_id, None

        return None, None, None, (404, "unknown bookId")

    return None, None, None, (400, "provide either book.text (inline) or bookId")


def create_pending(uid: str, job_id: str, book: dict, profile: dict, full_text: str, book_id):
    """Persist a pending job carrying everything the worker needs to generate.

    The grounding excerpt goes inline in the job row when small, or spills to S3
    (with an ``excerptRef`` pointer) when it would threaten DynamoDB's 400KB item cap.
    """
    excerpt = full_text[:GROUNDING_CHAR_BUDGET]
    item = {
        **_job_key(uid, job_id),
        "status": PENDING,
        "createdAt": _now_iso(),
        # Generation inputs (the worker reads these; trimmed to the prompt budget).
        "book": json.dumps(book),
        "profile": json.dumps(profile or {}),
    }
    if book_id:
        item["bookId"] = book_id

    if len(excerpt) > _INLINE_EXCERPT_MAX:
        key = _excerpt_s3_key(uid, job_id)
        s3_client().put_object(
            Bucket=bucket_name(), Key=key, Body=excerpt.encode("utf-8")
        )
        item["excerptRef"] = key
    else:
        item["excerpt"] = excerpt
    table().put_item(Item=item)


def get_job(uid: str, job_id: str):
    """Return the job's public view (status + roadmap/error), or None if absent."""
    item = table().get_item(Key=_job_key(uid, job_id)).get("Item")
    if not item:
        return None
    view = {"jobId": job_id, "status": item.get("status", PENDING)}
    if item.get("status") == COMPLETE and item.get("roadmap"):
        view["roadmap"] = json.loads(item["roadmap"])
    if item.get("status") == FAILED:
        view["error"] = item.get("error", "generation failed")
    return view


def load_inputs(uid: str, job_id: str):
    """Read back the generation inputs the worker needs (plus the job's current
    status/startedAt so a retried invoke can no-op — same single read). None if
    the job is gone."""
    item = table().get_item(Key=_job_key(uid, job_id)).get("Item")
    if not item:
        return None
    excerpt = item.get("excerpt", "")
    ref = item.get("excerptRef")
    if not excerpt and ref:
        obj = s3_client().get_object(Bucket=bucket_name(), Key=ref)
        excerpt = obj["Body"].read().decode("utf-8", errors="replace")
    return {
        "book": json.loads(item.get("book", "{}")),
        "profile": json.loads(item.get("profile", "{}")),
        "excerpt": excerpt,
        "bookId": item.get("bookId"),
        "status": item.get("status", PENDING),
        "startedAt": item.get("startedAt"),
    }


def mark_started(uid: str, job_id: str):
    """Stamp the moment generation begins, so a re-invoke of a still-pending job
    is recognizable as Lambda's retry after a timeout (vs the first attempt)."""
    table().update_item(
        Key=_job_key(uid, job_id),
        UpdateExpression="SET startedAt = :t",
        ExpressionAttributeValues={":t": _now_iso()},
    )


def mark_complete(uid: str, job_id: str, roadmap: dict):
    table().update_item(
        Key=_job_key(uid, job_id),
        UpdateExpression="SET #s = :s, roadmap = :r, completedAt = :t",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={
            ":s": COMPLETE,
            ":r": json.dumps(roadmap),
            ":t": _now_iso(),
        },
    )


def mark_failed(uid: str, job_id: str, message: str):
    table().update_item(
        Key=_job_key(uid, job_id),
        UpdateExpression="SET #s = :s, #e = :e, completedAt = :t",
        ExpressionAttributeNames={"#s": "status", "#e": "error"},
        ExpressionAttributeValues={":s": FAILED, ":e": message[:500], ":t": _now_iso()},
    )


def worker_function_name() -> str:
    return os.environ.get("ROADMAP_WORKER_FUNCTION", "")
