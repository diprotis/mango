"""POST /v1/roadmaps/generate — enqueue async roadmap generation.

Roadmap generation on Opus 4.8 exceeds the API Gateway 30s integration timeout,
so this endpoint is asynchronous: it persists a job, kicks off the worker Lambda
(``roadmap_worker``), and returns ``202 {jobId, status:"pending"}`` immediately.
The client polls ``GET /v1/roadmaps/jobs/{jobId}`` for the result.

Accepts EITHER an inline book ``{"book": {"title","author","text"}}`` (what the
iOS app sends) OR a stored ``bookId`` whose text is loaded from S3.

If no worker function is configured (local/offline e2e), generation runs inline
and the job is created already-complete, so the same poll contract still holds.
"""

import json

from shared import agent, roadmap_jobs
from shared.response import bad_request, json_response, not_found, parse_body, server_error, user_id
from shared.storage import lambda_client


def handler(event, context):
    try:
        uid = user_id(event)
    except PermissionError:
        return json_response(401, {"error": "unauthorized"})

    body = parse_body(event)
    book, full_text, book_id, error = roadmap_jobs.resolve_book(body)
    if error:
        status, message = error
        return not_found(message) if status == 404 else bad_request(message)

    profile = body.get("profile") or {}
    job_id = roadmap_jobs.new_job_id()
    roadmap_jobs.create_pending(uid, job_id, book, profile, full_text, book_id)

    worker = roadmap_jobs.worker_function_name()
    if worker:
        # Fire-and-forget: the worker generates and writes the result back.
        lambda_client().invoke(
            FunctionName=worker,
            InvocationType="Event",
            Payload=json.dumps({"uid": uid, "jobId": job_id}).encode(),
        )
        return json_response(202, {"jobId": job_id, "status": roadmap_jobs.PENDING})

    # No worker configured (local/offline): generate inline so the poll contract
    # still resolves. Bounded environments (tests) use fast/mocked generation.
    try:
        roadmap = agent.generate_roadmap(book, profile, full_text[:12000])
        if book_id:
            roadmap["bookId"] = book_id
        roadmap_jobs.mark_complete(uid, job_id, roadmap)
    except Exception as exc:  # noqa: BLE001
        roadmap_jobs.mark_failed(uid, job_id, f"roadmap generation failed: {exc}")
        return server_error(f"roadmap generation failed: {exc}")

    return json_response(202, {"jobId": job_id, "status": roadmap_jobs.PENDING})
