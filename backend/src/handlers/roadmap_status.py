"""GET /v1/roadmaps/jobs/{jobId} — poll an async roadmap job.

Returns the job's current status, scoped to the caller:
  {"jobId": ..., "status": "pending"}
  {"jobId": ..., "status": "complete", "roadmap": {...}}
  {"jobId": ..., "status": "failed", "error": "..."}
404 if the caller has no such job (jobs are stored under PK=USER#<uid>).
"""

from shared import roadmap_jobs
from shared.response import bad_request, json_response, not_found, ok, user_id


def handler(event, context):
    try:
        uid = user_id(event)
    except PermissionError:
        return json_response(401, {"error": "unauthorized"})

    params = event.get("pathParameters") or {}
    job_id = params.get("jobId")
    if not job_id:
        return bad_request("jobId path parameter is required")

    view = roadmap_jobs.get_job(uid, job_id)
    if not view:
        return not_found("unknown jobId")
    return ok(view)
