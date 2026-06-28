"""Async roadmap worker — invoked (InvocationType=Event) by generate_roadmap.

Not behind API Gateway, so it can take its full Lambda timeout (60s) to call
Bedrock. Reads the pending job's inputs, generates the roadmap, and writes the
result back to the job row (status "complete"/"failed"). The client learns the
outcome by polling ``GET /v1/roadmaps/jobs/{jobId}``.

Event shape: ``{"uid": "<sub>", "jobId": "<hex>"}``.
"""

from shared import agent, roadmap_jobs


def handler(event, context):
    uid = event.get("uid")
    job_id = event.get("jobId")
    if not uid or not job_id:
        # Nothing we can record against; surface for CloudWatch and stop.
        raise ValueError("roadmap_worker requires uid and jobId")

    inputs = roadmap_jobs.load_inputs(uid, job_id)
    if not inputs:
        # Job row vanished (e.g. account deleted before the worker ran).
        return {"ok": False, "reason": "job not found"}

    try:
        roadmap = agent.generate_roadmap(inputs["book"], inputs["profile"], inputs["excerpt"])
        if inputs.get("bookId"):
            roadmap["bookId"] = inputs["bookId"]
        roadmap_jobs.mark_complete(uid, job_id, roadmap)
        return {"ok": True, "jobId": job_id}
    except Exception as exc:  # noqa: BLE001
        roadmap_jobs.mark_failed(uid, job_id, f"roadmap generation failed: {exc}")
        return {"ok": False, "jobId": job_id, "error": str(exc)}
