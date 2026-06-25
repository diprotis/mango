"""GET /health — public liveness probe."""

import os

from shared.response import ok


def handler(event, context):
    return ok({"status": "ok", "stage": os.environ.get("STAGE", "dev")})
