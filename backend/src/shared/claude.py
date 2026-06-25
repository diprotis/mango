"""Anthropic Messages API client. The API key is read from Secrets Manager.

Network + secret access are isolated in ``_invoke`` / ``_api_key`` so tests can
monkeypatch them without hitting AWS or Anthropic.
"""

import json
import os
import urllib.request

import boto3

from . import prompts

_API_URL = "https://api.anthropic.com/v1/messages"
_ANTHROPIC_VERSION = "2023-06-01"
_cached_key = None


def _api_key() -> str:
    global _cached_key
    if _cached_key:
        return _cached_key
    arn = os.environ["ANTHROPIC_SECRET_ARN"]
    secret = boto3.client("secretsmanager").get_secret_value(SecretId=arn)
    value = secret.get("SecretString", "")
    try:
        parsed = json.loads(value)
        key = parsed.get("apiKey") or parsed.get("ANTHROPIC_API_KEY") or value
    except (json.JSONDecodeError, TypeError):
        key = value
    if not key:
        raise ValueError("Anthropic API key is empty; set the secret value")
    _cached_key = key
    return _cached_key


def _invoke(system: str, user: str, max_tokens: int = 1500, temperature: float = 0.4) -> str:
    payload = json.dumps(
        {
            "model": os.environ.get("CLAUDE_MODEL", "claude-3-5-sonnet-latest"),
            "max_tokens": max_tokens,
            "temperature": temperature,
            "system": system,
            "messages": [{"role": "user", "content": user}],
        }
    ).encode("utf-8")
    request = urllib.request.Request(
        _API_URL,
        data=payload,
        method="POST",
        headers={
            "content-type": "application/json",
            "x-api-key": _api_key(),
            "anthropic-version": _ANTHROPIC_VERSION,
        },
    )
    with urllib.request.urlopen(request, timeout=50) as response:  # noqa: S310 (fixed host)
        body = json.loads(response.read().decode("utf-8"))
    parts = body.get("content", [])
    return "".join(p.get("text", "") for p in parts if p.get("type") == "text")


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
