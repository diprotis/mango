"""Live smoke tests against a DEPLOYED Mango API.

Skipped entirely unless ``MANGO_API_URL`` is set. With the Cognito env
(``MANGO_USER_POOL_ID``, ``MANGO_CLIENT_ID``, ``MANGO_REGION``) it also runs the
authenticated journey, including a REAL Amazon Bedrock roadmap generation.

Run via ``make backend-e2e-live`` or ``scripts/deploy_and_verify.sh`` (which
exports these from the CloudFormation stack outputs). Stdlib + boto3 only.
"""

import json
import os
import time
import urllib.error
import urllib.request
import uuid

import pytest

API = os.environ.get("MANGO_API_URL", "").rstrip("/")
POOL = os.environ.get("MANGO_USER_POOL_ID")
CLIENT = os.environ.get("MANGO_CLIENT_ID")
REGION = os.environ.get("MANGO_REGION", "us-east-1")

pytestmark = pytest.mark.skipif(not API, reason="set MANGO_API_URL to run live smoke tests")


def _req(method, path, token=None, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"{API}{path}", data=data, method=method)
    req.add_header("x-mango-user", "smoke")
    if body is not None:
        req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=90) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        try:
            return exc.code, json.loads(raw) if raw else None
        except json.JSONDecodeError:
            return exc.code, None


def test_health_is_public_and_ok():
    status, body = _req("GET", "/health")
    assert status == 200 and body["status"] == "ok"


def test_catalog_is_public():
    status, body = _req("GET", "/v1/catalog")
    assert status == 200 and len(body["items"]) >= 1


def test_unauthenticated_v1_is_401():
    # No token → the Cognito authorizer rejects (unregistered/anonymous user).
    # HTTP API JWT authorizer returns 401 (occasionally 403) for a missing token.
    status, _ = _req("GET", "/v1/me/progress")
    assert status in (401, 403), f"expected 401/403 for no-token, got {status}"


def _admin_token():
    """Create a temp confirmed user and return (email, IdToken) via the admin flow.

    Requires the app client to allow ADMIN_USER_PASSWORD_AUTH; skips gracefully if not.
    """
    import boto3
    from botocore.exceptions import ClientError

    idp = boto3.client("cognito-idp", region_name=REGION)
    email = f"smoke-{uuid.uuid4().hex[:10]}@example.com"
    password = "Sm0ke!" + uuid.uuid4().hex[:12]
    try:
        idp.admin_create_user(
            UserPoolId=POOL,
            Username=email,
            MessageAction="SUPPRESS",
            UserAttributes=[
                {"Name": "email", "Value": email},
                {"Name": "email_verified", "Value": "true"},
            ],
        )
        idp.admin_set_user_password(
            UserPoolId=POOL, Username=email, Password=password, Permanent=True
        )
        result = idp.admin_initiate_auth(
            UserPoolId=POOL,
            ClientId=CLIENT,
            AuthFlow="ADMIN_USER_PASSWORD_AUTH",
            AuthParameters={"USERNAME": email, "PASSWORD": password},
        )
        return idp, email, result["AuthenticationResult"]["IdToken"]
    except ClientError as exc:
        try:
            idp.admin_delete_user(UserPoolId=POOL, Username=email)
        except ClientError:
            pass
        # Creds were provided (test gated on POOL+CLIENT), so a failure here is a
        # real failure, not a skip — the app client must allow the admin flow.
        pytest.fail(
            f"admin auth flow failed ({exc}); the app client must enable "
            "ADMIN_USER_PASSWORD_AUTH (auth_stack sets admin_user_password=True)"
        )


@pytest.mark.skipif(
    not (POOL and CLIENT), reason="set MANGO_USER_POOL_ID + MANGO_CLIENT_ID for the authed flow"
)
def test_authenticated_journey_with_real_bedrock():
    idp, email, token = _admin_token()
    try:
        status, _ = _req("PUT", "/v1/me/profile", token, {"goals": ["focus"], "dailyGoalUnits": 2})
        assert status == 200
        status, prof = _req("GET", "/v1/me/profile", token)
        assert status == 200 and prof["dailyGoalUnits"] == 2

        status, detail = _req("GET", "/v1/catalog/dummy-meditations")
        assert status == 200
        # Roadmap generation is async (real Bedrock exceeds the API Gateway 30s
        # cap): POST returns 202 + jobId, then poll until complete.
        status, enqueued = _req(
            "POST",
            "/v1/roadmaps/generate",
            token,
            {"book": {"title": detail["title"], "text": detail["text"]}, "profile": {}},
        )
        assert status == 202, f"expected 202 enqueue, got {status}: {enqueued}"
        job_id = enqueued["jobId"]
        roadmap = None
        for _ in range(40):  # up to ~80s of real generation
            time.sleep(2)
            status, job = _req("GET", f"/v1/roadmaps/jobs/{job_id}", token)
            assert status == 200, f"job poll failed: {status} {job}"
            if job["status"] == "complete":
                roadmap = job["roadmap"]
                break
            assert job["status"] != "failed", f"roadmap generation failed: {job.get('error')}"
        assert roadmap and roadmap.get(
            "milestones"
        ), "Bedrock returned no milestones (or timed out)"

        status, _ = _req("POST", "/v1/me/library", token, {"bookId": "dummy-meditations"})
        assert status == 200
        status, lib = _req("GET", "/v1/me/library", token)
        assert status == 200 and any(i["bookId"] == "dummy-meditations" for i in lib["items"])

        status, _ = _req("POST", "/v1/reflections", token, {"text": "A real, specific reflection."})
        assert status == 200
        status, grade = _req(
            "POST",
            "/v1/exercises/grade",
            token,
            {
                "kind": "reflection",
                "prompt": "Where does this apply?",
                "answer": "In my mornings, before email.",
            },
        )
        assert status == 200 and "xpAwarded" in grade

        status, _ = _req("DELETE", "/v1/me", token)
        assert status == 200
    finally:
        try:
            idp.admin_delete_user(UserPoolId=POOL, Username=email)
        except Exception:  # noqa: BLE001
            pass
