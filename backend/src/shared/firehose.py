"""Emit analytics events to Kinesis Firehose (best-effort, request-safe).

``put_event`` serializes a single event as one newline-terminated JSON record and
puts it on the delivery stream named by ``EVENTS_STREAM_NAME``. The delivery
stream lands records in the analytics S3 lake (see ``analytics_stack.py``).

Telemetry must never break a request: if the stream env var is missing (e.g. in
the offline/Mock path or a stage where analytics isn't wired) or the put fails,
this is a no-op that returns ``False`` instead of raising. boto3 is provided by
the Lambda runtime.
"""

import datetime
import json
import os

import boto3

_FIREHOSE = None


def _client():
    """Lazily create (and memoize) the Firehose client.

    Memoizing keeps warm invocations cheap; tests may monkeypatch this function
    or reset the module-level cache.
    """
    global _FIREHOSE
    if _FIREHOSE is None:
        _FIREHOSE = boto3.client("firehose")
    return _FIREHOSE


def _now_iso() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def put_event(event_type: str, user_id: str, props: dict) -> bool:
    """Best-effort emit one analytics event. Returns True if accepted by Firehose.

    Records are shaped to match the Glue ``events`` table columns: ``ts``,
    ``type``, ``userId``, ``props`` — where ``props`` is a JSON **string** (the
    Glue column is typed ``string``; free-form keys are queried in Athena via
    ``json_extract`` / ``get_json_object``). A trailing newline delimits records
    so the JSON SerDe reads one per line.
    """
    stream = os.environ.get("EVENTS_STREAM_NAME")
    if not stream:
        # Analytics not configured for this stage/path — silently skip.
        return False

    record = {
        "ts": _now_iso(),
        "type": event_type,
        "userId": user_id,
        "props": json.dumps(props or {}),
    }
    try:
        _client().put_record(
            DeliveryStreamName=stream,
            Record={"Data": json.dumps(record) + "\n"},
        )
        return True
    except Exception:
        # Never let telemetry failures surface to the caller's request.
        return False
