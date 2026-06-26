# 0007 — Integration & end-to-end testing

- **Epic:** M3/M4 hardening · **Status:** ✅ implemented · **Updated:** 2026-06-25

## 1. Summary
Two layers of cross-component tests prove the Mango backend persists state end to
end and that a deployed stage actually works against real Cognito + Bedrock:

1. **Local e2e (`tests_integration/test_e2e_local.py`)** — runs in CI, offline.
   Drives the real Lambda handlers with simulated API-Gateway-v2 events against
   **moto** (mock DynamoDB + S3). Only Bedrock is monkeypatched. Asserts the full
   journey: browse catalog → generate roadmap (inline dummy book) → add to library
   → reflect → save profile/progress → **delete account** (and verifies the DDB +
   S3 cascade, scoped to the caller).
2. **Live smoke (`tests_integration/live_smoke.py`)** — runs against a **deployed**
   API. Skips unless `MANGO_API_URL` is set. Checks: `/health` + `/v1/catalog`
   public; unauthenticated `/v1/*` → **401**; and (when `MANGO_USER_POOL_ID` +
   `MANGO_CLIENT_ID` are set) an authenticated journey including a **real Bedrock**
   roadmap generation, then deletes the temp user.

## 2. How to run
- Local: `make backend-e2e-local` (also runs in `backend-ci`).
- Live, one command: `make backend-deploy-verify STAGE=dev PROFILE=diprotis-dev`
  — deploys the stage, reads the stack outputs, exports `MANGO_*`, runs the smoke.
- Live, against an already-deployed stage: export `MANGO_API_URL` (and the Cognito
  vars for the authed flow) then `make backend-e2e-live`.

## 3. Minimal end-to-end acceptance (the "it works" bar)
A brand-new user signs in (Hosted UI: Google / Apple / phone / email), opens the
**Catalog**, picks the **dummy book**, and creates a roadmap — served by a real
Bedrock call. The local e2e covers every server step of this; the authed live
smoke covers it against the deployed stack with real Cognito + Bedrock.

## 4. Notes / requirements
- The authed live smoke uses Cognito's `ADMIN_USER_PASSWORD_AUTH` admin flow to
  mint a token without the Hosted-UI browser step; it **skips gracefully** if that
  auth flow isn't enabled on the app client.
- Bedrock model access must be enabled and `bedrockModelId` set in
  `backend/config/<stage>.json` for the roadmap step to pass.
- Live smoke is **read/normal** + self-cleaning (creates then deletes its own temp
  user and data); never point it at a stage with real user data.

## 5. References
`backend/tests_integration/`, `backend/scripts/deploy_and_verify.sh`,
[../DEPLOY.md](../DEPLOY.md), [0003](0003-authentication.md), [0006](0006-data-lake.md).
