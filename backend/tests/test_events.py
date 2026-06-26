import json

import pytest

from handlers import events
from shared import firehose


class _FakeFirehose:
    """Captures put_record calls so the test can assert on the emitted record."""

    def __init__(self):
        self.calls = []

    def put_record(self, **kwargs):
        self.calls.append(kwargs)
        return {"RecordId": "fake-record-id"}


@pytest.fixture
def fake_firehose(monkeypatch):
    fake = _FakeFirehose()
    monkeypatch.setenv("EVENTS_STREAM_NAME", "mango-events-test")
    # Replace the lazily-created boto3 client with our capturing fake.
    monkeypatch.setattr(firehose, "_client", lambda: fake)
    return fake


def _event(method="POST", body=None, user="u-1"):
    return {
        "requestContext": {"http": {"method": method}},
        "headers": {"x-mango-user": user},
        "body": json.dumps(body) if body is not None else None,
    }


def test_accepts_valid_event(fake_firehose):
    resp = events.handler(
        _event(body={"type": "lesson_completed", "props": {"bookId": "b-1", "xp": 10}}),
        None,
    )
    assert resp["statusCode"] == 200
    assert json.loads(resp["body"]) == {"accepted": True}

    # One record was put on the configured stream.
    assert len(fake_firehose.calls) == 1
    call = fake_firehose.calls[0]
    assert call["DeliveryStreamName"] == "mango-events-test"

    data = call["Record"]["Data"]
    assert data.endswith("\n")  # newline-delimited for the JSON SerDe
    record = json.loads(data)
    assert record["type"] == "lesson_completed"
    assert record["userId"] == "u-1"
    assert json.loads(record["props"]) == {"bookId": "b-1", "xp": 10}
    assert record["ts"]  # ISO timestamp present


def test_rejects_missing_type(fake_firehose):
    resp = events.handler(_event(body={"props": {"x": 1}}), None)
    assert resp["statusCode"] == 400
    assert fake_firehose.calls == []  # nothing emitted on validation failure


def test_rejects_blank_type(fake_firehose):
    resp = events.handler(_event(body={"type": "   "}), None)
    assert resp["statusCode"] == 400
    assert fake_firehose.calls == []


def test_rejects_non_object_props(fake_firehose):
    resp = events.handler(_event(body={"type": "x", "props": "nope"}), None)
    assert resp["statusCode"] == 400
    assert fake_firehose.calls == []


def test_event_without_props_defaults_to_empty(fake_firehose):
    resp = events.handler(_event(body={"type": "app_opened"}), None)
    assert resp["statusCode"] == 200
    record = json.loads(fake_firehose.calls[0]["Record"]["Data"])
    assert json.loads(record["props"]) == {}


def test_put_event_is_noop_without_stream_env(monkeypatch):
    # No EVENTS_STREAM_NAME → put_event must be a no-op and return False,
    # never raising (telemetry must not break a request).
    monkeypatch.delenv("EVENTS_STREAM_NAME", raising=False)
    assert firehose.put_event("any", "u-1", {"a": 1}) is False


def test_handler_succeeds_even_when_stream_unconfigured(monkeypatch):
    # Handler still returns 200 when analytics isn't wired for the stage.
    monkeypatch.delenv("EVENTS_STREAM_NAME", raising=False)
    resp = events.handler(_event(body={"type": "app_opened"}), None)
    assert resp["statusCode"] == 200
    assert json.loads(resp["body"])["accepted"] is True
