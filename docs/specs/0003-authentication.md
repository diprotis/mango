# 0003 — Authentication (Cognito + app)

- **Epic:** M3 · **Status:** Draft (decision open) · **Updated:** 2026-06-25

## 1. Summary
Users sign up / sign in; the app obtains a Cognito JWT and sends it on `/v1/*` so
real-backend features work end-to-end. Signed-out, the app still works fully offline.

## 2. Goals / Non-goals
- **Goals:** secure sign-up / sign-in / password reset; JWT on requests; silent token
  refresh; sign-out; account deletion (→ data deletion, with 0004); keep first-run
  offline; ideally keep the **no third-party iOS deps** invariant.
- **Non-goals:** social graph / friends (M8); enterprise SSO; multi-device session mgmt.

## 3. Background
The Cognito user pool + app client already exist (`auth_stack.py`). `/v1/*` uses a
Cognito JWT authorizer; the app sends no token today, so those calls 401 (OPERATIONS
SOP 5). This epic closes that gap.

## 4. User stories
Sign up with email · verify email · sign in · stay signed in across launches · reset
password · sign out · delete my account and data.

## 5. Requirements
- **FR-1** Email + password sign-up with verification and a password policy.
- **FR-2** Sign-in returns Id/Access/Refresh tokens.
- **FR-3** `Authorization: Bearer <IdToken>` attached to all `/v1` calls.
- **FR-4** Silent refresh; tokens stored in the Keychain.
- **FR-5** Sign-out clears tokens → app falls back to Offline.
- **FR-6** `DELETE /v1/me` deletes the Cognito user + all backend data (cascades 0004).
- **FR-7** Server maps Cognito `sub` → `USER#<sub>` (already in `response.user_id`).
- **NFR:** tokens never logged; PKCE; TLS only; no secrets in the app binary.

## 6. Design — **Decision required: auth client approach**

| Option | What | Pros | Cons |
|---|---|---|---|
| **A (recommended)** | Cognito **Hosted UI + `ASWebAuthenticationSession`** (OAuth2 + PKCE) | Zero third-party deps (system API); Cognito hosts sign-up/in/reset + optional Apple/social; least code | A web auth sheet (less "native"); needs a Cognito domain + callback URL scheme |
| **B** | Native screens calling the `cognito-idp` JSON API over HTTPS (e.g. `USER_PASSWORD_AUTH`) | Fully native UI; zero deps | We hand-build signup/confirm/auth/refresh; `USER_PASSWORD` weaker than SRP; more code |
| **C** | **AWS Amplify Auth** SDK | Easiest, full-featured | **Adds the first third-party iOS dependency** — breaks the CLAUDE.md invariant; needs an explicit exception |

**Recommendation: Option A.** Confirm before building.

**Backend changes:** add a Cognito **domain** + app-client OAuth config (callback /
logout URLs, `authorization_code` + PKCE flow, scopes) to `auth_stack.py`; output the
domain + client id; add a `delete_account` Lambda (with 0004).
**iOS:** `AuthService` (start session via `ASWebAuthenticationSession`, exchange code
for tokens, store in Keychain, refresh, expose `currentSession`); a signed-out gate /
`AuthView`; wire `APIClient.authToken` from the live session; an Account screen (sign
out, delete). `AIServiceProvider` uses the live token; real-backend modes require a
session.

## 7. Acceptance criteria
- [ ] New user signs up + verifies, signs in, and the app calls
      `/v1/roadmaps/generate` on **Beta** returning **200** (not 401).
- [ ] Session persists across launches; refresh works; sign-out → Offline.
- [ ] `DELETE /v1/me` removes the Cognito user and the user's backend data.
- [ ] Signed-out app remains fully usable offline.
- [ ] No token appears in logs.

## 8. Test plan
- **Backend:** synth of the authorizer/domain config; pytest for `delete_account`
  (moto) including the data cascade.
- **iOS:** unit tests for the token store (Keychain) + session-expiry logic; manual
  end-to-end Hosted-UI flow against Beta.

## 9. Rollout & migration
Deploy auth config to dev/beta; register the callback URL scheme in the app; gate
real-backend modes on a session; optional feature flag. No data migration (new).

## 10. Risks & open decisions
**Decision A/B/C (above).** Hosted-UI domain name; callback scheme; refresh-token
rotation; handling an expired refresh (force re-auth). Risk: web sheet UX — mitigate
with a clean signed-out screen that launches it.

## 11. Tasks
1. Confirm option (you). 2. Backend OAuth/domain config + outputs (S). 3. `AuthService`
+ Keychain token store (M). 4. `AuthView` + Account screen (M). 5. Wire `APIClient`
token (S). 6. `delete_account` Lambda + tests (M, with 0004). 7. iOS auth tests (M).

## 12. References
`backend/mango_backend/auth_stack.py`, [../OPERATIONS.md](../OPERATIONS.md) SOP 5,
`shared/api/openapi.yaml`, [../ROADMAP.md](../ROADMAP.md) M3.
