"""POST /v1/exercises/grade — grade an answer and award XP.

Quizzes are graded deterministically (no model call). Reflections and application
tasks are graded by Claude for depth/specificity.
"""

from shared import agent
from shared.response import bad_request, ok, parse_body, server_error

XP_BY_KIND = {"quiz": 15, "reflection": 25, "application": 40}


def handler(event, context):
    body = parse_body(event)
    kind = body.get("kind")
    prompt = body.get("prompt") or ""
    answer = body.get("answer") or ""

    if kind not in ("quiz", "reflection", "application"):
        return bad_request("kind must be quiz|reflection|application")

    if kind == "quiz":
        answer_index = body.get("answerIndex")
        chosen_index = body.get("chosenIndex")
        correct = chosen_index is not None and chosen_index == answer_index
        return ok(
            {
                "correct": bool(correct),
                "score": 1.0 if correct else 0.0,
                "feedback": "Correct!" if correct else "Not quite — revisit the idea and retry.",
                "xpAwarded": XP_BY_KIND["quiz"] if correct else 0,
            }
        )

    if not answer.strip():
        return bad_request("answer is required for reflection/application")

    try:
        result = agent.grade(kind, prompt, answer)
    except Exception as exc:  # noqa: BLE001
        return server_error(f"grading failed: {exc}")

    score = max(0.0, min(1.0, float(result.get("score", 0.7))))
    base = XP_BY_KIND[kind]
    xp = int(round(base * (0.5 + 0.5 * score)))
    return ok(
        {
            "correct": None,
            "score": score,
            "feedback": result.get("feedback", "Thanks for putting in the work."),
            "xpAwarded": xp,
        }
    )
