# 0019 — Native Sign in with Apple

- **Epic:** M3 · **Status:** Draft · **Owner:** unassigned · **Updated:** 2026-06-26
- **Reviewers:** Principal, SD, QA

## 1. Summary
Replace the current **web-federated** Apple sign-in (a Cognito Hosted-UI button that
deep-links to `identity_provider=SignInWithApple` inside `ASWebAuthenticationSession`)
with a **native Sign in with Apple** experience using `ASAuthorizationAppleIDProvider`
/ SwiftUI's `SignInWithAppleButton`. The crux is that a Cognito **User Pool** cannot
directly consume a natively obtained Apple `id_token` through its public API — native
federation into a User Pool still expects the Hosted-UI `/oauth2/authorize` round-trip.
So delivering a fully native button requires either (B) a small **backend token-exchange
Lambda** that verifies the Apple `id_token` and mints a Cognito session, or (C) an
**Identity Pool** developer-authenticated path. This spec analyzes A/B/C, **recommends B**
for the native UX with a real account in our User Pool, details Apple token verification
(JWKS, `aud`, `nonce`), and frames the work against **App Store Review Guideline 4.8**
(if you offer Google, you must offer Sign in with Apple). It is **additive** to the
existing Hosted-UI flow, which stays as a fallback.

## 2. Goals / Non-goals
- **Goals:**
  - A native `SignInWithAppleButton` on `AuthView` (no web sheet for Apple) that signs the
    user into the **same Cognito User Pool** identity used by `/v1/*` (so progress sync,
    `response.user_id` → `USER#<sub>` etc. keep working).
  - End-to-end security: Apple **nonce** (SHA256-hashed in the request, verified in the
    `id_token`), `aud` = our Services ID/bundle, token-replay protection.
  - Capture Apple's **first-login-only** full name / relay email and persist them to the
    Cognito user.
  - Satisfy **App Store Guideline 4.8** now that we offer Google.
  - Keep the **no-third-party-iOS-deps** invariant (uses `AuthenticationServices`,
    first-party).
  - Be **purely additive** — Hosted-UI Apple/Google/phone/email continue to work; native
    Apple is an enhancement, dark-launchable.
- **Non-goals:**
  - Replacing Hosted UI for Google/phone/email (those stay web-federated for now).
  - Apple sign-in on non-Apple platforms / web.
  - Account-linking/merging across providers (if a user has both a Hosted-UI Apple account
    and a native-path account, dedupe is a follow-up — see §10 Risk).
  - Shipping any Apple/AWS key **in the app binary** (CLAUDE.md invariant — secrets are
    server-side only).

## 3. Background & context
`AuthService` (`ios/Mango/Services/Auth/AuthService.swift`) implements Cognito **Hosted
UI + ASWebAuthenticationSession + PKCE**: `signIn(idpHint:)` builds an
`/oauth2/authorize` URL (with `identity_provider`), runs the web auth, exchanges the code
at `/oauth2/token`, and stores an `AuthSession` in the Keychain. The `IdPHint` enum maps
`apple = "SignInWithApple"`, `google = "Google"`. `AuthView`
(`ios/Mango/Features/Auth/AuthView.swift`) shows a **"Sign in with Apple"** button that
calls `signIn(hint: .apple)` — i.e. **the web flow today**, rendered with a plain
`Label("Sign in with Apple", systemImage: "apple.logo")`, not Apple's native button.

Server side, `auth_stack.py` wires `UserPoolIdentityProviderApple` (Services ID, Team ID,
Key ID, `.p8` secret) into the same User Pool + public PKCE client (callback
`mango://callback`); Apple federation flows through Hosted UI at
`https://<domain>/oauth2/idpresponse`. `docs/AUTH_PROVIDERS_SETUP.md` step 4 sets this up
and explicitly notes: *"This is the web-federated Apple flow via Hosted UI; a fully native
`ASAuthorizationAppleIDButton` is a later enhancement."* `docs/specs/0003-authentication.md`
is the parent auth spec (Decision A = Hosted UI).

**Why now:** (1) **Guideline 4.8** — Mango offers "Continue with Google"; App Review
requires an equivalent **Sign in with Apple** with its privacy properties (limit data
collection to name+email, allow email relay, no tracking without consent). The Hosted-UI
Apple button technically satisfies presence, but a **native** button is the expected,
lowest-friction iOS UX and avoids the web sheet. (2) Native sign-in is a measurably better
conversion path on the signed-out gate, which is the activation funnel.

**The architectural crux:** a Cognito **User Pool**'s public API has no "exchange this
Apple `id_token` for Cognito tokens" call. `InitiateAuth`/`RespondToAuthChallenge` don't
accept a third-party OIDC token for a User Pool; User-Pool federation is designed around
the Hosted-UI authorize endpoint. So a native Apple credential can't be turned into a
User-Pool session without either Hosted UI (status quo) or a server component.

## 4. User stories
- As a new user on iPhone, I want to tap the **native Apple button** and authenticate with
  Face ID, so sign-in is one tap and never shows a web page.
- As a privacy-conscious user, I want to **hide my email** (Apple relay), so I control what
  Mango sees — and still have it work.
- As a returning user, I want the native button to sign me into the **same account** I get
  through any other path, so my streak/library follow me.
- As the app owner, I want to **pass App Review 4.8**, so the app ships.

## 5. Requirements
**Functional**
- **FR-1** `AuthView` shows a native `SignInWithAppleButton` (Apple HIG styling) in place
  of the current plain Apple `Label` button; tapping it starts `ASAuthorizationController`.
- **FR-2** The request sets `requestedScopes = [.fullName, .email]` and a **`nonce`** =
  raw random; the request carries `SHA256(nonce)` (Apple hashes via the request's `nonce`
  field), with the **raw** nonce retained for later verification.
- **FR-3** On success, `AuthService.signInWithAppleNative(credential:rawNonce:)` obtains an
  `AuthSession` for **our Cognito User Pool** (mechanism per the chosen option below) and
  stores it in the Keychain exactly like the Hosted-UI path, then `AppModel.reloadAIService()`.
- **FR-4 (Option B path)** A backend endpoint
  **`POST /v1/auth/apple`** accepts `{ id_token, raw_nonce, authorization_code?,
  full_name? }`, **verifies** the Apple `id_token`, maps the Apple `sub` to a Cognito user,
  and returns a Cognito session (Id/Access/Refresh) usable as `Authorization: Bearer` on
  `/v1/*`. Added to `shared/api/openapi.yaml`, `ios/.../DTOs.swift`, and a new handler.
- **FR-5** Apple's **first-login-only** `fullName`/email is persisted to the Cognito user
  on first sight (later logins omit it; we must not overwrite with empty).
- **FR-6** The Hosted-UI flow (`signIn(idpHint:)`) remains fully functional; native Apple
  is selected via a flag and gracefully falls back to Hosted-UI Apple if the native path
  errors or is disabled.
- **FR-7** `ASAuthorizationController` presentation is `@MainActor`-confined (matches how
  `AuthService` already pins only the UI-touching `ASWebAuthenticationSession` work).

**Non-functional / Security**
- **NFR-sec-1 (token verification, Option B):** the Lambda verifies the `id_token` against
  Apple's JWKS (`https://appleid.apple.com/auth/keys`, cached), checks `iss ==
  https://appleid.apple.com`, `aud ==` our client id (the **app bundle id** for native
  app tokens, or the Services ID), `exp`/`iat` validity, and **`nonce ==
  SHA256(raw_nonce)`** echoed by the client — defeating replay and audience confusion.
- **NFR-sec-2:** the Apple `id_token` and any minted Cognito tokens are **never logged**
  (consistent with `AuthService` and `response.py`); TLS only; PKCE preserved on the
  Hosted-UI path.
- **NFR-sec-3:** replay protection — the raw nonce is single-use; the server rejects a
  reused nonce within the token's short validity window (cache/`nonce` table, TTL).
- **NFR-sec-4:** the Apple `.p8`/AWS admin privileges live **only** in the backend
  (Secrets Manager / IAM); nothing sensitive ships in the app, preserving the CLAUDE.md
  invariant and matching the Bedrock/no-app-key rule.
- **NFR-privacy:** request only name+email; support Apple's private-relay email; record an
  App Privacy nutrition-label note (data used for account only).
- **NFR-deps:** iOS uses only `AuthenticationServices`/`CryptoKit` (first-party). Backend
  uses **stdlib + boto3 only** (CLAUDE.md) — JWKS fetch via `urllib`, JWT verify
  hand-rolled or via a stdlib-friendly approach (RS256 with `hashlib`/`hmac` won't do
  RSA; see §10 decision on a tiny pure-Python RSA verify vs. accepting one vetted dep with
  sign-off).
- **NFR-a11y:** native button respects Dynamic Type and Dark Mode automatically; honors
  the DesignSystem layout (`Metrics` spacing) around it.

## 6. Design
**Decision required: how a native Apple credential becomes a Cognito identity**

| Option | What | Pros | Cons |
|---|---|---|---|
| **A** | **Keep Hosted-UI Apple** (status quo): native button is cosmetic, still opens the web flow, or we just relabel | Zero new backend; already shipped; satisfies 4.8 *presence* | **Not actually native** (web sheet); poorer UX; doesn't deliver the goal |
| **B (recommended)** | **Native `ASAuthorization` → `POST /v1/auth/apple` token-exchange Lambda** that verifies the Apple `id_token` and maps it to a **Cognito User-Pool** user (admin create/get + mint a session), returning Cognito tokens | Fully native one-tap UX; real account in our existing User Pool → progress sync & `USER#<sub>` unchanged; secrets stay server-side | New endpoint + handler + Apple JWT verification; "mint a Cognito session" needs a deliberate mechanism (see below); most code |
| **C** | **Cognito *Identity Pool* developer-authenticated identities**: app sends Apple token to a Lambda → `GetOpenIdTokenForDeveloperIdentity` → AWS creds | Native; AWS-native dev-auth pattern | Identity **Pool** ≠ the **User Pool** the JWT authorizer + `/v1` use today; would fork our identity model and `response.user_id`; bigger architectural change |

**Recommendation: Option B.** It is the only option that yields a *native* button **and**
keeps the **single User-Pool identity** the rest of the backend already assumes
(`auth_stack.py` JWT authorizer, `response.user_id` → `USER#<sub>`, progress sync in
Roadmap #2). A is insufficient (not native); C forks identity.

**Option B — minting a Cognito User-Pool session (sub-decision).** The User Pool's public
API won't take the Apple token, so the Lambda (with admin IAM) does one of:
1. **Keep the Apple IdP federation, drive it server-side:** ensure the Apple-federated user
   exists (it does, since the same Services ID/Apple IdP is configured), then issue tokens
   via an **admin/custom-auth** flow. The app client already enables `admin_user_password`
   (admin-only, server-side) and `user_srp`; we add a **custom auth** (`CUSTOM_AUTH`,
   Define/Create/Verify-Auth-Challenge Lambdas) where the challenge is "present a valid
   Apple `id_token` for this `sub`", and on success Cognito returns real tokens. This keeps
   one user record per Apple `sub` and yields standard Cognito JWTs.
2. **Admin-create + custom-auth mint** for a username derived from the Apple `sub`
   (`SignInWithApple_<sub>`-style), email = Apple email, mark verified; same custom-auth
   challenge issues tokens.
   *(Recommend #1 if federation user records are reusable; otherwise #2. Both avoid ever
   needing the user's password and never put admin creds on-device.)*

**Apple token verification (Lambda)**
1. Decode `id_token` header → `kid`; fetch & cache Apple **JWKS**.
2. Verify **RS256** signature with the matching JWK.
3. Assert `iss == https://appleid.apple.com`, `aud ==` our client id (bundle id for the
   native app audience), `exp > now`, `iat` sane.
4. Assert `nonce == base64url(SHA256(raw_nonce))` (the value the client put in the request).
5. Single-use the `raw_nonce` (TTL cache) → defeat replay.
6. Extract `sub` (stable Apple user id), `email`, `email_verified`,
   `is_private_email`; persist first-login `full_name` from the request body (Apple sends
   the name to the **client** only on first auth, not in the token).

**API / contract** (`shared/api/openapi.yaml` — keep in sync per CLAUDE.md):
```
POST /v1/auth/apple
  request:  { id_token: string, raw_nonce: string,
              authorization_code?: string, full_name?: string }
  response: { id_token: string, access_token: string,
              refresh_token: string, expires_in: int }   # Cognito tokens
  errors:   401 invalid_apple_token | 401 nonce_mismatch | 409 account_conflict
```
Mirror DTOs in `ios/Mango/Services/Networking/DTOs.swift`; new handler under
`backend/src/handlers/` (thin) with verification logic in `backend/src/shared/` (e.g.
`apple.py`, alongside the existing `claude.py`/`http.py`); IAM grants least-privilege
(`cognito-idp:AdminInitiateAuth`/`AdminCreateUser`/custom-auth as needed) in `api_stack.py`.

**Data**
- Reuses the existing Cognito User Pool + the same `AuthSession`/Keychain on iOS — **no new
  client-side identity model**. Server: one Cognito user per Apple `sub`; a small
  **nonce-replay** store (DynamoDB single table item `NONCE#<hash>` with TTL, fitting the
  `PK`/`SK` + TTL pattern) — or an in-memory/short-TTL cache if acceptable.

**iOS — screens/state/services**
- `AuthView.actions`: swap the Apple `Button { signIn(hint:.apple) }` for
  `SignInWithAppleButton(.signIn) { request in request.requestedScopes = [.fullName, .email]; request.nonce = sha256(rawNonce) } onCompletion: { result in … }`
  styled with `.signInWithAppleButtonStyle(.black/.white adaptive)` and Metrics spacing.
  Keep "Continue" (Hosted UI all-providers) and "Continue with Google" as-is.
- `AuthService`:
  - `enum AppleSignInError` (cancelled / failed / notConfigured) feeding the same
    non-technical, token-free error copy as `AuthError`.
  - `func signInWithAppleNative(authorization: ASAuthorization, rawNonce: String) async throws`
    — extracts `ASAuthorizationAppleIDCredential.identityToken` + `fullName`/`email`, calls
    `POST /v1/auth/apple` via `APIClient`, decodes Cognito tokens into `AuthSession`,
    `Keychain.saveSession`, sets `session`.
  - Nonce helpers reuse the existing `PKCE`/`CryptoKit` (`SHA256`) utilities already in the
    file — add `makeRawNonce()` + `sha256Hex/base64url(nonce)`.
  - An `ASAuthorizationControllerPresentationContextProviding`/delegate (mirroring
    `WebAuthPresenter`), `@MainActor`-confined.
- Flag: `AppConfig`/`AppSettings.nativeAppleEnabled` (and an `AppleClientID`/bundle-audience
  value) gates the native path; if off or on error, fall back to `signIn(hint: .apple)`.

**Diagram (Option B flow)**
```
AuthView ─SignInWithAppleButton(nonce=SHA256(raw))▶ ASAuthorizationController (Face ID)
   │ ASAuthorizationAppleIDCredential { identityToken, fullName?, email? }
   ▼
AuthService.signInWithAppleNative ─POST /v1/auth/apple {id_token, raw_nonce, full_name?}▶ Lambda
                                                                                  │ verify JWKS/aud/nonce
                                                                                  │ map Apple sub → Cognito user
                                                                                  │ custom-auth mint
   ◀──────────────── Cognito {id,access,refresh} ────────────────────────────────┘
   ▼
Keychain.saveSession ─▶ Authorization: Bearer <IdToken> on /v1/*  (same identity as Hosted UI)
```

## 7. Acceptance criteria
- [ ] `AuthView` shows the **native** Apple button (Apple HIG); tapping it presents the
      system Apple sheet — **no web view**. *(→ manual on device)*
- [ ] A first-time native Apple sign-in creates/links a Cognito user, returns Cognito
      tokens, and a subsequent `/v1/roadmaps/generate` on **Beta** returns **200** (same
      identity guarantees as Hosted UI). *(→ manual e2e + backend test)*
- [ ] The Lambda **rejects** an `id_token` with a wrong `aud`, expired `exp`, bad
      signature, or **nonce mismatch** with 401, and rejects a **replayed** nonce. *(→
      pytest with crafted tokens + JWKS fixture, moto)*
- [ ] Apple **private-relay** email works (account usable, no PII beyond relay). *(→ manual)*
- [ ] First-login `fullName` is persisted; a second login (Apple omits the name) does **not**
      blank it. *(→ pytest)*
- [ ] No Apple or Cognito **token** appears in any log (client or server). *(→ code review +
      log scan)*
- [ ] Disabling `nativeAppleEnabled` (or a forced native error) **falls back** to the
      Hosted-UI Apple flow with no user-visible breakage. *(→ manual)*
- [ ] App still builds with **no** added third-party iOS dep; backend uses stdlib+boto3
      (or a dep approved per §10). *(→ ios-ci / backend-ci)*
- [ ] App Review **4.8**: Sign in with Apple is presented alongside Google with limited
      data + relay email. *(→ review checklist)*

## 8. Test plan
**Backend (pytest, offline — moto + monkeypatched JWKS, per CLAUDE.md)**
- `test_auth_apple.py`: happy path (valid signed token + matching nonce → tokens),
  and rejection matrix — bad signature, wrong `aud`, expired, missing/!= nonce, replayed
  nonce. Use a locally generated RSA keypair to **sign** test tokens and a stubbed JWKS
  endpoint. `cdk synth -c stage=beta` must still pass with the new endpoint/IAM.
- First-login name persistence; no-overwrite on second login.

**iOS (XCTest, offline)**
- Unit-test the nonce helpers (`makeRawNonce`, `sha256` of nonce) and the
  `POST /v1/auth/apple` request/response DTO encode/decode (mirrors existing DTO-decoding
  tests). `ASAuthorization` itself is UI/system — covered manually.

**Manual / device**
- End-to-end native sign-in on a real device (Face ID), incl. hide-my-email; verify a `/v1`
  call succeeds; verify fallback when the flag is off; VoiceOver/Dynamic Type on the button.
- App Review dry-run against Guideline 4.8 expectations.

**Not automated:** `ASAuthorizationController` UI, real Apple ID round-trip, Keychain on
device, private-relay deliverability.

## 9. Rollout & migration
- **Additive & flagged.** Land the backend `POST /v1/auth/apple` + custom-auth wiring
  first (dark, behind no client use), deploy to **dev → beta**. Then ship the iOS native
  button behind `nativeAppleEnabled` (default **off** → enable on Beta → Prod after soak).
- **Fallback always present:** Hosted-UI Apple (`signIn(idpHint:.apple)`) stays wired; on
  any native failure the app uses it, so there is no regression risk to existing sign-in.
- **Backward compatibility:** existing Hosted-UI Apple users and native users that resolve
  to the **same Apple `sub`** should be the **same Cognito user** (federation keyed on
  `sub`), so progress/library carry over; verify this mapping on Beta before Prod (see §10).
- **Config:** reuse the existing `appleServicesId`/`appleTeamId`/`appleKeyId` secrets;
  add the **app bundle id** as an accepted `aud` for native tokens; add the nonce-store
  table/TTL. No app-shipped secrets.
- **Teardown:** flipping `nativeAppleEnabled` off reverts to Hosted-UI Apple instantly; the
  endpoint can remain (idle) or be removed in a later cleanup.

## 10. Risks & open decisions
- **Decision A/B/C (above) — recommend B.** Confirm before building; B is the only native
  path that preserves the single User-Pool identity.
- **Sub-decision — Cognito mint mechanism** (federated-user + CUSTOM_AUTH vs admin-create +
  CUSTOM_AUTH). *Recommend* CUSTOM_AUTH challenge that validates the Apple token; pick the
  user-record strategy based on whether the existing Apple-IdP federation records are
  reusable. Needs a short spike.
- **Decision — backend RSA verification under stdlib-only.** Verifying Apple's **RS256**
  needs RSA signature verification, which Python stdlib doesn't provide ergonomically.
  *Options:* (i) a tiny pure-Python RSA/PKCS#1v1.5 verify using `hashlib` + integer math
  (no dep, more code to test); (ii) request a **single vetted dependency** exception
  (`PyJWT[crypto]`/`cryptography`) — note CLAUDE.md says backend Lambdas use **stdlib +
  boto3 only**, so this needs **explicit owner sign-off** and a packaging step the repo
  currently avoids. *Recommendation:* try (i); escalate to (ii) only if (i) is fragile.
- **Risk — account duplication** between the Hosted-UI Apple user and the native-path user
  if `sub` mapping differs. *Mitigation:* key strictly on Apple `sub`; test cross-path
  sign-in lands on one Cognito user; if not, add a linking step.
- **Risk — nonce replay / token theft.** *Mitigation:* single-use raw nonce with TTL,
  strict `aud`/`iss`/`exp`, never log tokens (NFR-sec-1..3).
- **Risk — first-login name loss** (Apple returns name only once). *Mitigation:* send
  `full_name` in the first `/v1/auth/apple` call and persist immediately; never overwrite
  with empty.
- **Risk — App Review 4.8 nuance.** *Mitigation:* limit scopes to name+email, support
  relay email, present Apple at least as prominently as Google; document in the review
  checklist.
- **Risk — capability/provisioning.** Native Sign in with Apple requires the **Sign in with
  Apple capability/entitlement** and the App ID configured (paid membership). *Mitigation:*
  provisioning checklist mirrored from `docs/AUTH_PROVIDERS_SETUP.md`.

## 11. Tasks & estimate
1. **(S)** Spike: confirm the Cognito mint mechanism (federated-user vs admin-create +
   CUSTOM_AUTH) on a dev pool; confirm native-token `aud` (bundle id) handling.
2. **(M)** Backend `apple.py` verifier: JWKS fetch/cache, RS256 verify (per RSA decision),
   `iss`/`aud`/`exp`/**nonce** checks, replay store. **+ pytest with a local keypair/JWKS.**
3. **(M)** CUSTOM_AUTH Lambdas (Define/Create/Verify-Auth-Challenge) or admin mint path;
   `POST /v1/auth/apple` handler returning Cognito tokens; least-privilege IAM in
   `api_stack.py`. **+ pytest.**
4. **(S)** `shared/api/openapi.yaml` + `ios/.../DTOs.swift` for `/v1/auth/apple` (keep
   contract in sync).
5. **(M)** iOS `AuthService.signInWithAppleNative(...)`: credential extraction, nonce
   helpers (reuse `PKCE`/CryptoKit), `APIClient` call, `AuthSession`/Keychain, presentation
   delegate (`@MainActor`). **+ DTO/nonce unit tests.**
6. **(S)** `AuthView`: native `SignInWithAppleButton`, Apple-HIG styling, keep
   Continue/Google; flag + Hosted-UI fallback.
7. **(S)** `AppSettings/AppConfig.nativeAppleEnabled` + accepted-`aud` config; nonce table
   + TTL in the data stack.
8. **(S)** Sign in with Apple **capability/entitlement** + App ID provisioning; App Review
   4.8 checklist.
9. **(S)** Dark-launch on Beta, verify same-identity mapping vs Hosted-UI Apple, then enable
   on Prod; log-scan for tokens.

_Rough total: ~3 M + 6 S (+ 1 spike)._

## 12. References
- `ios/Mango/Services/Auth/AuthService.swift` (`IdPHint`, `signIn`, `PKCE`, Keychain),
  `ios/Mango/Features/Auth/AuthView.swift` (current Apple button)
- `backend/mango_backend/auth_stack.py` (`UserPoolIdentityProviderApple`, app client),
  `backend/mango_backend/api_stack.py` (IAM), `backend/src/shared/` (handler home)
- `docs/AUTH_PROVIDERS_SETUP.md` (step 4 — Hosted-UI Apple; "native is a later
  enhancement"), `docs/specs/0003-authentication.md` (parent auth spec)
- `shared/api/openapi.yaml`, `ios/Mango/Services/Networking/DTOs.swift`
- `CLAUDE.md` (no-app-key / stdlib+boto3 / no-third-party-deps invariants)
- Apple: *Sign in with Apple REST API* (id_token claims, JWKS at
  `appleid.apple.com/auth/keys`), `ASAuthorizationAppleIDProvider`, `SignInWithAppleButton`;
  **App Store Review Guideline 4.8**.
