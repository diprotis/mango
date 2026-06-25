"""Anthropic-on-Amazon-Bedrock client (IAM auth — no API key).

Calls Claude through ``bedrock-runtime:InvokeModel`` using the Anthropic
"messages" body format, so the rest of the codebase (prompt building + JSON
extraction) is unchanged. The Bedrock client lives behind ``_runtime`` so tests
can monkeypatch it without hitting AWS.
"""

import json
import os

import boto3
import botocore.exceptions

from . import prompts

_ANTHROPIC_VERSION = "bedrock-2023-05-31"
_cached_runtime = None


def _runtime():
    """Return a cached ``bedrock-runtime`` boto3 client (monkeypatchable)."""
    global _cached_runtime
    if _cached_runtime is None:
        region = os.environ.get("BEDROCK_REGION") or os.environ.get("AWS_REGION") or "us-east-1"
        _cached_runtime = boto3.client("bedrock-runtime", region_name=region)
    return _cached_runtime


def _max_effort() -> bool:
    return os.environ.get("AI_MAX_EFFORT", "true").lower() == "true"


def _invoke(system: str, user: str, max_tokens: int = 1500, temperature: float = 0.4) -> str:
    model_id = os.environ["BEDROCK_MODEL_ID"]

    def _body(thinking: bool) -> dict:
        body = {
            "anthropic_version": _ANTHROPIC_VERSION,
            "max_tokens": max_tokens,
            "system": system,
            "messages": [{"role": "user", "content": user}],
            "temperature": temperature,
        }
        if thinking:
            # Extended thinking requires temperature=1 and enough headroom for
            # the thinking budget plus the visible answer.
            body["thinking"] = {"type": "enabled", "budget_tokens": 4000}
            body["temperature"] = 1
            body["max_tokens"] = max(max_tokens, 4000 + 1024)
        return body

    def _call(body: dict) -> str:
        resp = _runtime().invoke_model(
            modelId=model_id,
            contentType="application/json",
            accept="application/json",
            body=json.dumps(body),
        )
        payload = json.loads(resp["body"].read())
        parts = payload.get("content", [])
        return "".join(p.get("text", "") for p in parts if p.get("type") == "text")

    thinking = _max_effort()
    try:
        return _call(_body(thinking))
    except botocore.exceptions.ClientError:
        # Max-effort (extended thinking) is best-effort: if the chosen model
        # rejects the thinking block, retry once without it.
        if thinking:
            return _call(_body(False))
        raise


def extract_json(text: str) -> dict:
    """Tolerantly pull the first JSON object out of a model response."""
    start = text.find("{")
    end = text.rfind("}")
    if start == -1 or end == -1 or end < start:
        raise ValueError("no JSON object found in model output")
    return json.loads(text[start : end + 1])


def generate_roadmap(book: dict, profile: dict, excerpt_text: str) -> dict:
    out = _invoke(
        prompts.roadmap_system(),
        prompts.roadmap_user(book, profile, excerpt_text),
        max_tokens=2500,
        temperature=0.5,
    )
    return extract_json(out)


def grade(kind: str, prompt: str, answer: str) -> dict:
    out = _invoke(
        prompts.grade_system(),
        prompts.grade_user(kind, prompt, answer),
        max_tokens=600,
        temperature=0.2,
    )
    return extract_json(out)
