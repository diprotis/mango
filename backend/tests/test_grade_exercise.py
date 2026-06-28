import json

from handlers import grade_exercise
from shared import agent


def _invoke(payload):
    return grade_exercise.handler({"body": json.dumps(payload)}, None)


def test_quiz_correct_awards_xp():
    resp = _invoke({"kind": "quiz", "answerIndex": 2, "chosenIndex": 2, "prompt": "?"})
    body = json.loads(resp["body"])
    assert body["correct"] is True
    assert body["xpAwarded"] == 15


def test_quiz_wrong_no_xp():
    resp = _invoke({"kind": "quiz", "answerIndex": 2, "chosenIndex": 0, "prompt": "?"})
    body = json.loads(resp["body"])
    assert body["correct"] is False
    assert body["xpAwarded"] == 0


def test_reflection_uses_claude(monkeypatch):
    monkeypatch.setattr(agent, "grade", lambda *a, **k: {"score": 1.0, "feedback": "Great depth."})
    resp = _invoke(
        {"kind": "reflection", "prompt": "Where does this apply?", "answer": "In my mornings."}
    )
    body = json.loads(resp["body"])
    assert body["feedback"] == "Great depth."
    assert body["xpAwarded"] == 25  # base 25 * (0.5 + 0.5*1.0)


def test_reflection_requires_answer():
    resp = _invoke({"kind": "reflection", "prompt": "?", "answer": "   "})
    assert resp["statusCode"] == 400
