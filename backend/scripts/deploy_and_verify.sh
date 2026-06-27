#!/usr/bin/env bash
#
# Deploy a Mango stage to AWS, then run the live smoke tests against it.
#
#   bash scripts/deploy_and_verify.sh [STAGE] [PROFILE]
#   STAGE   default: dev      PROFILE default: diprotis-dev
#   PROFILE may be "" (or none/-) to use ambient credentials (CI / OIDC role).
#
# Prereqs (one-time, see docs/DEPLOY.md):
#   * AWS creds for the profile (`aws sso login --profile <p>` or keys)
#   * `make backend-bootstrap` once per account/region
#   * Amazon Bedrock model access enabled for the configured bedrockModelId,
#     and that id set in backend/config/<stage>.json
#
set -euo pipefail

STAGE="${1:-dev}"
PROFILE="${2:-diprotis-dev}"
cd "$(dirname "$0")/.."  # -> backend/

banner() { printf '\n\033[1m▶ %s\033[0m\n' "$*"; }

# PROFILE is optional: "" / none / - uses ambient credentials (CI OIDC role);
# a named profile is used for local SSO/keys.
PROFILE_ARG=""
case "${PROFILE}" in
  "" | none | -) PROFILE_LABEL="ambient creds" ;;
  *)
    PROFILE_ARG="--profile ${PROFILE}"
    PROFILE_LABEL="profile ${PROFILE}"
    # Export so the pytest subprocess (boto3 in live_smoke.py) authenticates with
    # the same identity — `--profile` only reaches the CDK CLI, not boto3.
    export AWS_PROFILE="${PROFILE}"
    ;;
esac

OUTPUTS="/tmp/mango-${STAGE}-outputs.json"

banner "Deploying Mango-${STAGE} (${PROFILE_LABEL})"
# The stacks live inside a CDK Stage construct ("Mango-<stage>"), so they are in
# a NESTED cloud assembly. `--all` only sees the main assembly and finds nothing
# ("No stack found in the main cloud assembly"); select the stage's stacks with
# a glob instead. `stage` maps 1:1 to the construct id in every config/<stage>.json.
# shellcheck disable=SC2086
npx --yes aws-cdk@2 deploy -c stage="${STAGE}" ${PROFILE_ARG} \
  --require-approval never "Mango-${STAGE}/*" --outputs-file "${OUTPUTS}"

banner "Reading stack outputs from ${OUTPUTS}"
# Flatten every stage stack's outputs into one map, then pull by output key.
# Scoped to THIS deploy's outputs file, so there are no cross-stage collisions.
# NOTE: write `export …` lines to a temp file and `source` it rather than
# `eval "$(python3 … <<'PY' … PY)"` — a quoted heredoc nested inside command
# substitution mis-parses on the closing `)` and yields empty/garbage values.
ENVFILE="$(mktemp)"
python3 - "${OUTPUTS}" > "${ENVFILE}" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
flat = {}
for stack_outputs in data.values():
    flat.update(stack_outputs)
for var, key in (("MANGO_API_URL", "ApiUrl"),
                 ("MANGO_USER_POOL_ID", "UserPoolId"),
                 ("MANGO_CLIENT_ID", "UserPoolClientId")):
    print(f'export {var}="{flat.get(key, "")}"')
PY
# shellcheck disable=SC1090
source "${ENVFILE}"
rm -f "${ENVFILE}"
# shellcheck disable=SC2086
export MANGO_REGION="${AWS_REGION:-$(aws configure get region ${PROFILE_ARG} 2>/dev/null || echo us-east-1)}"

echo "  API_URL  = ${MANGO_API_URL:-<none>}"
echo "  POOL_ID  = ${MANGO_USER_POOL_ID:-<none>}"
echo "  CLIENT   = ${MANGO_CLIENT_ID:-<none>}"
echo "  REGION   = ${MANGO_REGION}"

if [[ -z "${MANGO_API_URL}" ]]; then
  echo "✗ Could not read ApiUrl from stack outputs — aborting." >&2
  exit 1
fi
if [[ -z "${MANGO_USER_POOL_ID}" || -z "${MANGO_CLIENT_ID}" ]]; then
  echo "✗ Missing Cognito outputs — the authenticated smoke (real Bedrock) would skip. Aborting." >&2
  exit 1
fi

banner "Running live smoke tests"
if python3 -m pytest tests_integration/live_smoke.py -q; then
  printf '\n\033[1;32m✅ DEPLOY + LIVE SMOKE PASSED (%s)\033[0m\n' "${STAGE}"
else
  printf '\n\033[1;31m❌ LIVE SMOKE FAILED (%s)\033[0m\n' "${STAGE}" >&2
  exit 1
fi
