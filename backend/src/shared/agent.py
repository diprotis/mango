"""Anthropic-on-Amazon-Bedrock client (IAM auth — no API key).

Calls Claude through ``bedrock-runtime:InvokeModel`` using the Anthropic
"messages" body format, so the rest of the codebase (prompt building + JSON
extraction) is unchanged. The Bedrock client lives behind ``_runtime`` so tests
can monkeypatch it without hitting AWS.

Body contract notes (verified against the deployed model, Claude Opus 4.8):
  * ``temperature`` is rejected by current-generation models, so we never send
    it — it is optional for every model, so omitting it is universally safe.
  * Max-effort uses adaptive extended thinking (``thinking.type=adaptive`` +
    ``output_config.effort``); the legacy ``thinking.type=enabled`` form is
    rejected by current models. If a model rejects the thinking block at all we
    retry once with a plain body.
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


def _invoke(system: str, user: str, max_tokens: int = 1500) -> str:
    model_id = os.environ["BEDROCK_MODEL_ID"]

    base = {
        "anthropic_version": _ANTHROPIC_VERSION,
        "max_tokens": max_tokens,
        "system": system,
        "messages": [{"role": "user", "content": user}],
    }

    def _with_thinking() -> dict:
        # Adaptive extended thinking: the model manages its own thinking budget
        # via ``output_config.effort``. Extended thinking shares the max_tokens
        # budget, so add headroom for the thinking tokens on top of the visible
        # answer or the JSON body gets truncated. Effort is "medium": the roadmap
        # is a well-specified JSON task, and the API Gateway integration caps the
        # synchronous call at 30s, so we trade a little depth for latency margin.
        body = dict(base)
        body["max_tokens"] = max_tokens + 4096
        body["thinking"] = {"type": "adaptive"}
        body["output_config"] = {"effort": "medium"}
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

    if _max_effort():
        try:
            return _call(_with_thinking())
        except botocore.exceptions.ClientError:
            # Extended thinking is best-effort: if the model rejects the thinking
            # block, retry once with a plain body.
            return _call(base)
    return _call(base)


def extract_json(text: str) -> dict:
    """Tolerantly pull the first JSON object out of a model response."""
    start = text.find("{")
    end = text.rfind("}")
    if start == -1 or end == -1 or end < start:
        raise ValueError("no JSON object found in model output")
    return json.loads(text[start : end + 1])


def generate_roadmap(book: dict, profile: dict, excerpt_text: str) -> dict:
    # A focused 3×2×2 journey fits comfortably in ~1500 visible tokens; capping
    # output here is the main lever that keeps the synchronous call under the
    # API Gateway 30s integration timeout (generation time scales with output).
    out = _invoke(
        prompts.roadmap_system(),
        prompts.roadmap_user(book, profile, excerpt_text),
        max_tokens=1600,
    )
    return extract_json(out)


def grade(kind: str, prompt: str, answer: str) -> dict:
    out = _invoke(
        prompts.grade_system(),
        prompts.grade_user(kind, prompt, answer),
        max_tokens=600,
    )
    return extract_json(out)
