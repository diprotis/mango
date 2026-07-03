"""The async roadmap worker: generates from a pending job and writes the result."""

from handlers import roadmap_worker
from shared import agent, roadmap_jobs

_FAKE = {
    "title": "Focused Journey",
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
                    "exercises": [{"kind": "reflection", "prompt": "p", "xp": 25}],
                }
            ],
        }
    ],
}


def test_worker_completes_pending_job(aws, monkeypatch):
    uid, job_id = "user-x", roadmap_jobs.new_job_id()
    roadmap_jobs.create_pending(
        uid, job_id, {"title": "B"}, {"goals": []}, "excerpt text", book_id="bk1"
    )
    monkeypatch.setattr(agent, "generate_roadmap", lambda *a, **k: dict(_FAKE))

    out = roadmap_worker.handler({"uid": uid, "jobId": job_id}, None)
    assert out["ok"] is True

    job = roadmap_jobs.get_job(uid, job_id)
    assert job["status"] == "complete"
    assert job["roadmap"]["bookId"] == "bk1"  # worker stamps bookId on
    assert job["roadmap"]["title"] == "Focused Journey"


def test_worker_marks_failed_on_error(aws, monkeypatch):
    uid, job_id = "user-y", roadmap_jobs.new_job_id()
    roadmap_jobs.create_pending(uid, job_id, {"title": "B"}, {}, "excerpt", book_id=None)

    def _boom(*a, **k):
        raise RuntimeError("model exploded")

    monkeypatch.setattr(agent, "generate_roadmap", _boom)
    out = roadmap_worker.handler({"uid": uid, "jobId": job_id}, None)
    assert out["ok"] is False

    job = roadmap_jobs.get_job(uid, job_id)
    assert job["status"] == "failed"
    assert "model exploded" in job["error"]


def test_worker_handles_missing_job(aws):
    out = roadmap_worker.handler({"uid": "ghost", "jobId": "nope"}, None)
    assert out["ok"] is False
    assert out["reason"] == "job not found"


def test_oversized_excerpt_spills_to_s3_and_round_trips(aws, monkeypatch):
    """Full-book grounding can exceed DynamoDB's 400KB item cap: big excerpts must
    spill to S3 (excerptRef) and load back verbatim for the worker."""
    uid, job_id = "user-big", roadmap_jobs.new_job_id()
    big_text = ("The impediment to action advances action. " * 12000)  # ~516k chars
    assert len(big_text) > roadmap_jobs._INLINE_EXCERPT_MAX

    roadmap_jobs.create_pending(uid, job_id, {"title": "Big"}, {}, big_text, book_id=None)

    # The job row must NOT carry the text inline (would breach the item cap).
    from shared.storage import table

    item = table().get_item(
        Key={"PK": f"USER#{uid}", "SK": f"ROADMAPJOB#{job_id}"}
    )["Item"]
    assert "excerpt" not in item
    assert item["excerptRef"].startswith(f"users/{uid}/roadmap-jobs/")

    # The worker's input loader reads it back from S3, trimmed to the budget.
    inputs = roadmap_jobs.load_inputs(uid, job_id)
    expected = big_text[: roadmap_jobs.GROUNDING_CHAR_BUDGET]
    assert inputs["excerpt"] == expected

    # And the worker generates end-to-end from the spilled excerpt.
    captured = {}

    def _fake_generate(book, profile, excerpt_text):
        captured["len"] = len(excerpt_text)
        return dict(_FAKE)

    monkeypatch.setattr(agent, "generate_roadmap", _fake_generate)
    out = roadmap_worker.handler({"uid": uid, "jobId": job_id}, None)
    assert out["ok"] is True
    assert captured["len"] == len(expected)
