"""Bedrock-backed agent client: response parsing + max-effort fallback.

These tests never touch AWS — ``agent._runtime`` is monkeypatched with a fake
client whose ``invoke_model`` returns a canned Bedrock payload.
"""

import io
import json

import botocore.exceptions
import pytest

from shared import agent


def _bedrock_response(text: str) -> dict:
    """Shape a fake bedrock-runtime ``invoke_model`` return value."""
    payload = {"content": [{"type": "text", "text": text}]}
    return {"body": io.BytesIO(json.dumps(payload).encode())}


class _FakeRuntime:
    def __init__(self, text: str):
        self._text = text
        self.calls = []

    def invoke_model(self, **kwargs):
        self.calls.append(kwargs)
        return _bedrock_response(self._text)


_ROADMAP_JSON = json.dumps(
    {
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
                        "reading": {
                            "locator": "Chapter 1: The Surprising Power of Tiny Habits",
                            "anchorQuote": "The aggregation of marginal gains.",
                            "whatToNoticeWhileReading": "Notice how 1% changes compound.",
                        },
                        "exercises": [
                            {
                                "kind": "reflection",
                                "prompt": "Name one tiny habit.",
                                "xp": 25,
                            }
                        ],
                    }
                ],
            }
        ],
    }
)


def test_grade_parses_bedrock_payload(monkeypatch):
    monkeypatch.setenv("AI_MAX_EFFORT", "false")
    fake = _FakeRuntime('{"score":0.9,"feedback":"good"}')
    monkeypatch.setattr(agent, "_runtime", lambda: fake)

    result = agent.grade("reflection", "Where does this apply?", "In my mornings.")

    assert result == {"score": 0.9, "feedback": "good"}
    # The request used the configured Bedrock model id (set in conftest).
    assert fake.calls[0]["modelId"] == "anthropic.claude-test"
    body = json.loads(fake.calls[0]["body"])
    assert body["anthropic_version"] == "bedrock-2023-05-31"
    assert body["messages"][0]["role"] == "user"
    # Current-generation models reject `temperature` — we must never send it.
    assert "temperature" not in body


def test_generate_roadmap_parses_bedrock_payload(monkeypatch):
    monkeypatch.setenv("AI_MAX_EFFORT", "false")
    fake = _FakeRuntime(_ROADMAP_JSON)
    monkeypatch.setattr(agent, "_runtime", lambda: fake)

    result = agent.generate_roadmap({"title": "X"}, {}, "excerpt")

    assert result["title"] == "Build Better Habits"
    lesson = result["milestones"][0]["lessons"][0]
    assert lesson["exercises"][0]["xp"] == 25
    # The optional reading slice survives extract_json verbatim (no field whitelisting).
    assert lesson["reading"]["anchorQuote"] == "The aggregation of marginal gains."
    assert lesson["reading"]["locator"].startswith("Chapter 1")


def test_max_effort_uses_adaptive_thinking(monkeypatch):
    """Max-effort sends adaptive extended thinking, never the legacy/temp form."""
    monkeypatch.setenv("AI_MAX_EFFORT", "true")
    fake = _FakeRuntime('{"score":0.8,"feedback":"ok"}')
    monkeypatch.setattr(agent, "_runtime", lambda: fake)

    agent.grade("reflection", "p", "a")

    body = json.loads(fake.calls[0]["body"])
    assert body["thinking"] == {"type": "adaptive"}
    assert body["output_config"] == {"effort": "medium"}
    assert "temperature" not in body


class _FlakyRuntime:
    """Raises a ClientError on the first (thinking) call, then succeeds."""

    def __init__(self, text: str):
        self._text = text
        self.calls = []

    def invoke_model(self, **kwargs):
        self.calls.append(kwargs)
        if len(self.calls) == 1:
            raise botocore.exceptions.ClientError(
                {"Error": {"Code": "ValidationException", "Message": "thinking unsupported"}},
                "InvokeModel",
            )
        return _bedrock_response(self._text)


def test_max_effort_falls_back_without_thinking(monkeypatch):
    monkeypatch.setenv("AI_MAX_EFFORT", "true")
    fake = _FlakyRuntime('{"score":0.5,"feedback":"ok"}')
    monkeypatch.setattr(agent, "_runtime", lambda: fake)

    result = agent.grade("reflection", "p", "a")

    assert result == {"score": 0.5, "feedback": "ok"}
    # First attempt carried a thinking block; the retry dropped it (plain body).
    assert len(fake.calls) == 2
    assert "thinking" in json.loads(fake.calls[0]["body"])
    retry = json.loads(fake.calls[1]["body"])
    assert "thinking" not in retry
    assert "output_config" not in retry
    assert "temperature" not in retry


def test_non_max_effort_does_not_retry(monkeypatch):
    monkeypatch.setenv("AI_MAX_EFFORT", "false")
    fake = _FlakyRuntime('{"score":1.0}')
    monkeypatch.setattr(agent, "_runtime", lambda: fake)

    # Without max-effort the first (and only) call raises and is re-raised.
    with pytest.raises(botocore.exceptions.ClientError):
        agent.grade("reflection", "p", "a")
    assert len(fake.calls) == 1
