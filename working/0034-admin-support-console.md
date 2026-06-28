# 0034 — Admin & support console (internal)

- **Epic:** M14 · **Status:** Draft · **Owner:** unassigned · **Updated:** 2026-06-28
- **Reviewers:** Principal / SD / QA / Security

> ⚠️ **This is privileged tooling.** Every endpoint here can read another user's data, move
> their credits, or take enforcement action against an account. It therefore runs behind a
> **separate admin identity** (a Cognito **admin group**, distinct from the user JWT), is
> **MFA-required**, writes an **append-only audit record for every mutating call**, and is
> **least-privilege** down to the per-action IAM grant. The console **never silently bypasses a
> safety or age gate** ([`0030`]/[`0031`]): a privileged override is allowed only when it is
> **explicit, reason-tagged, and audited**. Treat the audit log as the load-bearing security
> control, not a nice-to-have.

## 1. Summary
Mango has **no internal tooling**. There is no way for an operator to look up a user for support,
adjust a credit balance, curate the catalog, or review flagged content — yet four shipped/planned
specs already assume that surface exists: [`0023`] defines an `admin_adjust` credit-ledger reason
**with nothing that can invoke it**; [`0024`] needs reward/redemption operations and refund
adjustments; [`0042`]/[`0043`] route spot-check failures, user reports, and safety flags to a
**moderation/escalation queue that does not exist**; [`0030`] sends *borderline* AI/media output to
"**0034 review**"; [`0027`] persists generation transcripts behind an `ARTIFACT#` index it says
"0033/0034 will read"; and [`0009`] needs **catalog curation** with a [`0028`] pre-warm trigger.
This spec builds the **minimal, secure internal admin & support console**: a small set of
**`/v1/admin/...`** HTTP endpoints behind an **admin-only authorizer** (Cognito admin group, MFA
expected), backed by thin Lambdas reusing the existing single-table/S3 patterns, plus a **mandatory
audit trail** (`ADMIN#AUDIT#<ts>#<uuid>`) written on every privileged action. It covers **user
lookup** (profile / progress / credits / redemptions / sessions), **credit & refund adjustment**
(invoking [`0023`]'s `admin_adjust` path), **catalog curation** (add / edit / disable catalog books;
trigger [`0028`] pre-warm), a **moderation queue** (review flagged AI output, user media, and
reports from [`0042`]/[`0043`]; take action — hide / warn / suspend / ban / escalate / dismiss),
**facilitator management** ([`0043`]), and **support notes**. The **recommended surface is a tiny
internal static React SPA** hosted privately (S3 + CloudFront, admin-Cognito Hosted UI sign-in) that
calls the same admin API — **separate from the iOS app**, so the *no third-party iOS deps* invariant
is untouched (this is web/ops tooling). A **break-glass** path and a thin **CLI** are provided for
emergencies and scripting. All repo invariants hold: Lambda **stdlib + boto3**, **single DDB table**,
**float-free**, **least-privilege IAM**, `openapi.yaml` ⇄ admin API in lockstep (a **separate
`shared/api/admin-openapi.yaml`** so admin paths never leak into the public/iOS contract).

## 2. Goals / Non-goals
- **Goals:**
  - A **dedicated admin authorization boundary**: an **admin authorizer distinct from the user JWT**
    authorizer — a **Cognito admin group** (`mango-admins`, with finer roles `support` / `moderator`
    / `catalog` / `admin`) whose membership a **Lambda authorizer** verifies and turns into a scoped
    policy + principal; **MFA required** for every admin; **no shared accounts**; deployed stages
    fail closed.
  - A **small, sufficient set of `/v1/admin/...` endpoints**: user lookup, credit/refund adjustment,
    catalog CRUD + pre-warm, moderation queue list/act, facilitator management, and support notes.
  - **Credit/refund adjustment that reuses [`0023`]'s ledger** — an admin adjustment is just a
    reason-tagged, idempotent, audited `admin_adjust` ledger entry (and matching `CREDITS` balance
    update); it **never** invents a parallel money path.
  - **Catalog curation** — add / edit / disable catalog books on the server (the [`0009`] dynamic
    catalog), and **trigger [`0028`]'s pre-warm** for a curated book — without a redeploy.
  - A **moderation/escalation queue** that aggregates the safety signals other specs already emit
    (`REPORT#`, `SAFETYFLAG#`, `MODFLAG#` from borderline [`0030`] output, [`0042`] spot-check
    escalations, [`0043`] no-show/abuse flags) into one reviewable list with a **clear action set**
    (hide content / warn / suspend / ban / remove facilitator / escalate / dismiss), each action
    **audited** and reversible where possible.
  - A **mandatory, append-only audit log** of **every privileged action** (actor, role, action,
    target, before/after or args, reason, request id, source IP, timestamp), queryable by target and
    by actor, with a **retention** posture and **tamper-resistance** (append-only writes; optional
    log-archive copy).
  - **Least-privilege IAM** per the existing `api_stack.py` discipline: the admin Lambdas get only
    the table/index/secret/Lambda-invoke they need; support-only paths can't write money; the
    moderation path can't read the credit ledger unless the action needs it.
  - A **recommended UI**: a **separate internal static React SPA** (S3 + CloudFront, admin-Cognito
    Hosted UI) — explicitly **not** part of the iOS app — plus a **break-glass** procedure and a thin
    **boto3/requests CLI** (`backend/scripts/mango_admin.py`) for emergencies/scripting.
  - **A hard boundary:** admin tooling **never silently bypasses** a safety ([`0030`]) or age
    ([`0031`]) gate; any override is **explicit + reason-required + audited**, and **destructive**
    actions (ban, hard-delete) require an elevated role and a typed confirmation.
  - Honor invariants: stdlib + boto3 Lambdas; single table; **float-free**; admin contract kept in a
    **separate** OpenAPI file; `cdk synth -c stage=beta` + `pytest` (moto) pass offline.
- **Non-goals:**
  - **A full SaaS admin platform / BI dashboards / cohort analytics.** Revenue/economy reporting is
    Athena/QuickSight over the [`0015`] lake; this console is **operational**, not analytical.
  - **Defining the credit ledger, rewards, moderation policy, age policy, or artifact store** — those
    are [`0023`]/[`0024`]/[`0030`]/[`0031`]/[`0027`]. This spec is the **operator surface** over them;
    it **consumes** their data shapes and primitives.
  - **Automated content classification / an ML moderation model.** Borderline classification is
    [`0030`] (Guardrails/Rekognition); this console is **human review of what those produce**.
  - **An end-user-facing appeals flow.** Appeals UX is a future product spec; here, an "appeal" is a
    queue item type an operator can action. (Apple/EU appeal obligations noted in §10.)
  - **Provisioning admins via the console.** Admin accounts/MFA/role membership are managed in the
    **AWS console / IaC by a super-admin** (or SSO/IdP-federated), not self-served in-app — adding an
    admin is itself a privileged, out-of-band act.
  - **Verifiable-parental-consent or KYC workflows** ([`0031b`] / [`0024`] partner) — out of scope.
  - **Changing the iOS app.** Zero iOS work; the *no third-party iOS deps* invariant is irrelevant to
    this web tool and is preserved by construction.

## 3. Background & context
**The gap (G10).** `working/ARCHITECTURE_REVIEW.md` §3 lists **G10 — "No admin/ops console (catalog
curation, moderation queue, support lookups, credit/refund `admin_adjust`)"** (🟠 High) with the
recommendation *"NEW 0034 — minimal internal authenticated tooling,"* depending on [`0026`]. This
spec is that tooling.

**What already assumes 0034 exists (verified by reading the specs):**
- **[`0023`] Payments & credits.** The credit-ledger `reason` enum is a **closed set** that includes
  **`admin_adjust`** (`§6.1`), and `shared/credits.py` exposes `credit(...)` / `_append_ledger(...)`
  / atomic balance updates. **Nothing invokes `admin_adjust` today** — there is no endpoint, so the
  reason is dead until this console adds the surface. The ledger item is
  `USER#<sub>/CREDITLEDGER#<ts>#<uuid>` with `delta:int`, `balanceAfter:int`, `reason`, `refType?`,
  `refId?`; the balance item is `USER#<sub>/CREDITS` (`balance:int`, `version:int`, lifetime
  roll-ups). Everything is **int** (float-free).
- **[`0024`] Rewards & coupons.** Catalog items `REWARD#<id>/META`, per-user `USER#<sub>/REDEMPTION#…`
  with `status ∈ {reserved, fulfilled, failed, refunded}`, coupon pools `COUPONPOOL#<rewardId>`, and
  a refund path. Operators need to **look up a redemption, re-issue or refund**, and **pause a
  reward** (`status=paused`). Catalog/pool items are described as **admin-seeded**.
- **[`0042`] External engagement.** `self_report+spotcheck` routes a `spotCheckRate` fraction to a
  **deeper check — "model re-verify … else human review per [`0034`]"** (FR-5); the operator story is
  *"pull the verification transcript ([`0027`]) … to audit or reverse it."*
- **[`0043`] Peer & human sessions.** Emits `REPORT#<id>/META` and `SAFETYFLAG#<id>/META`, plus a
  **facilitator pool** `FACILITATOR#<sub>/META` (`status ∈ {active, suspended, removed}`). It states
  the feature **"does not ship without somewhere for a report to go,"** and names **[`0034`]** as the
  moderation queue / facilitator-management home (FR-10/FR-11, §6.6). Until 0034, its *minimum*
  surface is "a `REPORT#`/`SAFETYFLAG#` DDB write + an internal-only Lambda behind staff auth" — this
  spec **is** that surface, generalized.
- **[`0030`] AI safety.** Borderline output (Guardrail/Rekognition "flagged" rather than "blocked")
  is **"graded but queued for 0034 review"** (§ image filters); 0034 is called the *"moderation
  **review console**."* CSAM/illegal-content is a Legal/T&S ops runbook (out of automated scope).
- **[`0027`] Generation artifacts.** Persists `roadmap.json` + a generation **transcript** + answers/
  grading under `users/<sub>/…`, indexed by `USER#<sub>/ARTIFACT#…`, explicitly *"read by future
  0033/0034,"* and reserves a `GET /v1/me/artifacts`. The moderation/support views read those
  artifacts to inspect *why* a roadmap or grade looks wrong.
- **[`0009`] Catalog expansion.** The catalog is moving from a 3-entry hand-written list to a
  **build-time `catalog_seed.json`** of 100+ titles loaded into `BOOK#<id>/META` (or served from the
  seed). Curation today is a code change + redeploy; operators need **runtime** add/edit/disable.
- **[`0031`] Age assurance.** Age band lives server-authoritatively; gates **fail closed**. The
  console must be able to **see** a user's band for support **without** offering a silent way to flip
  a restriction (an override must be explicit + audited).

**Current backend state (verified).**
- `api_stack.py`: thin Lambdas via `make_fn(name, handler, timeout, memory)`; routes via
  `route(path, method, fn, secured=True)`; a **single** `HttpUserPoolAuthorizer("JwtAuthorizer", …)`
  applied to all secured routes; CORS `allow_origins=["*"]`. **Least-privilege is explicit**
  ("grade_fn never touches the table"); `bedrock_policy` is scoped to foundation-model /
  inference-profile ARNs. `delete_fn` already holds the only `cognito-idp:AdminDeleteUser` grant and
  the `COGNITO_USER_POOL_ID` env — the **pattern for a Cognito-admin Lambda already exists** and is
  the template for admin user actions (disable/global-sign-out).
- `auth_stack.py`: one `UserPool` + one **public PKCE** app client + a **Hosted UI** domain; optional
  Google/Apple IdPs. **No groups defined yet.** The admin pool/group is added here (or in a new
  `admin_auth_stack.py`).
- `response.py`: `user_id(event)` reads `event.requestContext.authorizer.jwt.claims.sub` and **raises
  `PermissionError` in `prod`/`beta`** when claims are missing (the dev `x-mango-user` fallback is
  outside deployed stages). Admin identity resolution mirrors this but reads the **admin** claims and
  **group** membership. `json_response/ok/bad_request/not_found/server_error` are reused; we add
  `forbidden(...)` (403) and `unauthorized(...)` (401) helpers.
- `delete_account.py`: shows the **paginated query+batch-delete** over `USER#<sub>` and the
  **paginated S3 delete** under `users/<sub>/` — the read idiom the user-lookup aggregator reuses
  (read-only) and the cascade the audit log must record when an admin triggers a deletion.
- `catalog.py` + `catalog_data.py`: **public** (`secured=False`) `GET /v1/catalog[/{id}]` over a
  static in-memory list. Curation writes go to **DDB `BOOK#<id>/META`** (the [`0009`]/[`0028`] home),
  and the public reader is updated by those specs to prefer DDB; this console is the **writer**.
- `data_stack.py`: one `PAY_PER_REQUEST` table, `PK`/`SK`, **one** `GSI1` (`GSI1PK`/`GSI1SK`); prod
  PITR + RETAIN. We add **one** GSI for the moderation queue (justified in §6.4) and otherwise reuse
  the single table.

**Why an internal SPA (recommendation, not the iOS app).** The console is **web/ops tooling** used by
a handful of staff. A tiny **static React SPA behind admin-Cognito + CloudFront** gives a usable
moderation/triage UI (tables, filters, action buttons, transcript viewer) without touching the iOS
app or its zero-deps invariant. The **API is the contract**; the SPA and the **CLI** are two thin
clients of it. We keep the SPA dependency-light (Vite + React + `aws-amplify` auth or
`amazon-cognito-identity-js`) and **out of the iOS build entirely** (a new `admin/` web project,
its own CI). The CLI (`scripts/mango_admin.py`, boto3 + requests, stdlib-ish) covers break-glass and
automation. (Decisions D-1/D-2.)

**Related specs.** Consumes/serves: [`0023`] (credits/`admin_adjust`), [`0024`] (rewards/redemptions),
[`0030`] (flagged content), [`0027`] (artifacts/transcripts), [`0009`]/[`0028`] (catalog + pre-warm),
[`0042`]/[`0043`] (reports/spot-checks/facilitators), [`0031`] (age band), [`0026`] (server-side
progress/activity — what user-lookup reads), [`0033`] (DSAR export/deletion — an admin can trigger
it), [`0021`] (block/report graph), [`0019`] (sign-in — admin sign-in is its own pool/Hosted-UI).
**Hard dependency:** [`0026`] (so user lookup has real progress/activity to show) and at least the
**data shapes** of [`0023`]/[`0024`]/[`0043`] (so the operator surfaces have something to operate on).

## 4. User stories
- As a **support agent**, when a user emails "my credits are wrong / my purchase didn't land," I look
  them up by email or `sub`, see their **balance, recent ledger, redemptions, and recent activity**,
  and — if warranted — **grant or deduct credits** with a required **reason**, which the user sees as
  an `admin_adjust` line and which is **audited** under my identity.
- As a **support agent**, I can **leave a support note** on an account ("contacted re: refund, see
  ticket #123") that other agents can see, without touching any user-visible data.
- As a **moderator**, I open the **moderation queue**, see flagged AI output / user media / reports /
  spot-check escalations sorted by **severity and age**, open one to see the **context** (the
  [`0027`] transcript, the [`0030`] flag reason, the report text), and take an **action** — *hide the
  content*, *warn*, *suspend*, *ban*, *remove a facilitator*, *escalate to Legal*, or *dismiss* — each
  with a reason and an audit entry; the item moves to a **resolved** state.
- As a **catalog curator**, I **add a new public-domain title** (or **edit** a blurb/category, or
  **disable** a problematic one) and **trigger a [`0028`] pre-warm** so the activity template is ready
  — all at runtime, no redeploy, every change audited.
- As a **T&S lead / facilitator manager** ([`0043`]), I **suspend or remove a facilitator instantly**,
  and that facilitator can no longer be matched.
- As a **security reviewer / auditor**, I can pull the **complete history of privileged actions** for
  a given user (or by a given admin) and see exactly **who did what, when, why, and from where** —
  the log is **append-only** and **can't be edited from the console**.
- As an **on-call engineer in an emergency** (active abuse, runaway spend), I use a **break-glass**
  role to take a blunt action (disable an account, pause a reward, kill a catalog item) — and that
  emergency access is **time-boxed, heavily logged, and reviewed after**.
- As a **non-admin user** (or a signed-in regular app user), every `/v1/admin/...` call I attempt is
  **403** — the admin surface is invisible and inert to me.

## 5. Requirements
### 5.1 Functional
- **FR-1 (admin auth boundary).** All `/v1/admin/...` routes are protected by an **admin authorizer**
  distinct from the user JWT authorizer. A caller is admin **iff** their token is from the **admin
  user pool/client** *and* they are a member of the **`mango-admins`** group (with a role sub-claim);
  in `prod`/`beta` a missing/invalid admin claim ⇒ **401/403** and **no side effect**. A regular app
  user token is **never** accepted on an admin route.
- **FR-2 (role scoping).** Roles gate actions: **`support`** (read users, adjust credits within a cap,
  add notes), **`moderator`** (moderation queue + content/account actions), **`catalog`** (catalog
  CRUD + pre-warm), **`admin`** (everything, incl. destructive actions and large adjustments). The
  authorizer/handlers enforce the **action→role** matrix (§6.3); an out-of-role action ⇒ **403 +
  audit of the denied attempt**.
- **FR-3 (MFA required).** Every admin account **must** have MFA (TOTP) enforced at the pool; sign-in
  without MFA is impossible. (Enforced in Cognito config, asserted by `cdk synth`.)
- **FR-4 (user lookup).** `GET /v1/admin/users/{sub}` and `GET /v1/admin/users?email=…` return an
  **aggregated, read-only** view: profile ([`0026`] minus secrets), progress, **credits state +
  recent ledger** ([`0023`]), **redemptions** ([`0024`]), **sessions/facilitator status** ([`0043`]),
  **age band** ([`0031`]), and a **support-notes** list — assembled by **read-only** queries on
  `USER#<sub>` (+ Cognito `AdminGetUser` for email→sub/account-status). Reads are **audited** too
  (privileged read of another user's data).
- **FR-5 (credit/refund adjustment → `admin_adjust`).** `POST /v1/admin/users/{sub}/credits/adjust`
  with `{ delta:int, reason:str (required, free-text justification), refType?, refId? }` performs an
  **idempotent** (client `Idempotency-Key`) credit adjustment by **calling [`0023`]'s primitive**:
  update `USER#<sub>/CREDITS` (`balance += delta`, bump `version`, roll-ups) **and** append
  `CREDITLEDGER#…` with **`reason="admin_adjust"`** (the user-facing reason is `admin_adjust`; the
  operator justification is stored on the **audit** record, not necessarily shown to the user). A
  `delta` beyond a **per-role cap** requires `admin` role. Returns the new `CreditsState`. **Every
  adjust writes an audit entry** (FR-9). Refund-style adjustments for a [`0024`] redemption reference
  it via `refType="redemption", refId=<id>`.
- **FR-6 (catalog curation).** `POST /v1/admin/catalog` (create), `PUT /v1/admin/catalog/{id}`
  (edit), `POST /v1/admin/catalog/{id}/disable` + `/enable` (soft-disable via a `status` flag) write
  **`BOOK#<id>/META`** (the [`0009`]/[`0028`] catalog home) with validation (required fields, license
  field present). `POST /v1/admin/catalog/{id}/prewarm` **triggers [`0028`]'s pre-warm** for that book
  (async-invoke the pre-warm worker, or enqueue), returning a job/status ref. **Disable hides** a book
  from the public catalog (the [`0009`] reader respects `status`); it does **not** delete user data.
  All catalog writes are **audited**.
- **FR-7 (moderation queue).** `GET /v1/admin/moderation?status=open&severity=&type=&cursor=` lists
  queue items newest/most-severe first; `GET /v1/admin/moderation/{id}` returns the item **with
  context** (the linked [`0027`] artifact snippet/transcript, [`0030`] flag reason, the report text,
  the involved handles/`sub`s — least data needed). `POST /v1/admin/moderation/{id}/action` takes
  `{ action ∈ {dismiss, hide_content, warn_user, suspend_user, ban_user, remove_facilitator,
  escalate}, reason:str, targetSub?, contentRef? }`, applies the effect (set content/account/
  facilitator state), transitions the item to **`actioned`/`dismissed`/`escalated`**, and **audits**
  it. The queue **aggregates** existing signals: `REPORT#` ([`0021`]/[`0043`]), `SAFETYFLAG#`
  ([`0043`]), and a new `MODFLAG#` written by [`0030`] for borderline output and by [`0042`] for
  spot-check escalations (see §6.4 producers).
- **FR-8 (facilitator + account actions).** `POST /v1/admin/users/{sub}/suspend` / `/unsuspend`,
  `POST /v1/admin/users/{sub}/ban`, `POST /v1/admin/facilitators/{sub}` (set `status ∈ {active,
  suspended, removed}`) update the relevant items. **Suspend/ban** set an **account-status flag** the
  app/authorizers honor (the user's app JWT remains valid until expiry, so ban also performs a Cognito
  **global sign-out** + **disable user** via the admin API, mirroring `delete_account`'s grant). Ban
  is **destructive** ⇒ `admin` role + typed confirmation; every action **audited**.
- **FR-9 (mandatory audit log).** **Every mutating admin call** (and every privileged **read** of
  user data) writes an **append-only** audit item `ADMIN#AUDIT#<ts>#<uuid>` capturing
  `{ actorSub, actorEmail, role, action, method, path, targetType, targetId, argsRedacted, before?,
  after?, reason, requestId, sourceIp, userAgent, stage, createdAt }`. The write happens in a
  **shared decorator/helper** so a handler **cannot forget it** (and a handler that fails to audit
  **fails the request**). Audit items are queryable **by target** (`GET /v1/admin/audit?targetId=…`)
  and **by actor** (`?actorSub=…`) via `GSI1` (`GSI1PK=ADMINAUDIT#<targetId>`,
  `GSI1SK=<ts>#<uuid>`). Audit items are **never editable/deletable** through the console.
- **FR-10 (support notes).** `POST /v1/admin/users/{sub}/notes` `{ text }` and the notes list in FR-4
  store `USER#<sub>/ADMINNOTE#<ts>#<uuid>` (`{ authorSub, authorEmail, text, createdAt }`) — internal
  only, never returned on any user-facing endpoint; audited.
- **FR-11 (no silent gate bypass).** No admin endpoint may **silently** flip a [`0031`] age
  restriction or [`0030`] safety decision. An override (e.g. re-enabling a feature for an account, or
  un-hiding flagged content) is a **distinct, reason-required, `admin`-role, audited** action
  (`POST /v1/admin/users/{sub}/override` `{ gate, value, reason }`), surfaced in the audit and (where
  relevant) reflected to the user. Default is **deny**; overrides are exceptions, logged as such.
- **FR-12 (break-glass).** A **time-boxed emergency role** (`admin-breakglass`, assumed out-of-band)
  grants the destructive subset for ≤2h; its use is **flagged in the audit** (`role=breakglass`) and
  triggers a **post-hoc review** notice (an alarm/notification). The CLI is the primary break-glass
  client when the SPA is unavailable.
- **FR-13 (separate admin contract).** Admin endpoints live in **`shared/api/admin-openapi.yaml`**
  (not the public `openapi.yaml`), so the iOS contract and DTOs **never** gain admin shapes. The SPA
  and CLI consume the admin spec; CI lints both.

### 5.2 Non-functional
- **NFR-1 (security — defense in depth).** Distinct admin pool/group + **MFA** + Lambda authorizer +
  per-action role checks **in the handler** (never trust the client) + least-privilege IAM + audit.
  CORS for the admin API is **locked to the admin SPA origin(s)** (CloudFront domain), **not `*`**.
  No admin secret/PII in logs; audit `argsRedacted` strips tokens/PII beyond ids.
- **NFR-2 (least privilege IAM).** Each admin Lambda gets only what it needs: the **credit-adjust**
  Lambda gets table read/write (credit items) + `Idempotency`; the **catalog** Lambda gets table
  read/write (`BOOK#` items) + `lambda:InvokeFunction` on the [`0028`] pre-warm worker only; the
  **moderation** Lambda gets table read/write (queue + flagged items) + read on [`0027`] artifacts
  (S3 `GetObject` on `users/*`, read-only) + (for ban) the Cognito admin grant; **support/lookup**
  is **read-mostly** (no credit *write*, no Cognito *delete*). No wildcard `Resource:"*"` except where
  a service requires it. `cdk synth` IAM inspection is part of CI (AC-9).
- **NFR-3 (auditability/tamper-resistance).** Audit writes are **append-only** (no update/delete code
  path; IAM for admin Lambdas excludes `DeleteItem`/`UpdateItem` on `ADMIN#AUDIT#…`); optionally a
  **second copy** to a write-once log archive (CloudWatch Logs/S3 with Object-Lock on a *separate*
  audit bucket — not the user-data bucket, to avoid the GDPR-deletion conflict [`0027`] calls out).
  Audit is **synchronous and blocking** for mutations (no audit ⇒ no action).
- **NFR-4 (privacy / data minimization).** The console reads **only what the task needs**; the
  moderation context shows the **minimum** ([`0027`] *snippet*, not full third-party content; handles
  over emails where possible). Admin **reads of user data are themselves audited** (FR-9) so privileged
  access is accountable. Admin actions on a user are included in that user's [`0033`] export only as
  permitted by policy (decision deferred to [`0033`]/Legal).
- **NFR-5 (no end-user impact / offline-first intact).** This is a **separate** API + web app; it adds
  **no** routes to the public API surface the iOS app uses, **no** iOS code, and **no** dependency to
  the app build. Offline-first first-run is entirely unaffected.
- **NFR-6 (backend style/runtime).** Lambdas: **stdlib + boto3 only**; black (100) + flake8 (120);
  **float-free** (credit deltas/`balance` are `int`; any score in basis points). `pytest` (moto;
  Cognito/Bedrock monkeypatched) + `cdk synth -c stage=beta` pass **offline**.
- **NFR-7 (availability/blast-radius).** Admin tooling is **operational**, low-QPS; a bug must not be
  able to mass-mutate — **bulk** operations are out of v1 (one target per call), and destructive
  actions are role- and confirmation-gated. The admin API can be **disabled** (a stage flag /
  authorizer that denies all) as a kill-switch.
- **NFR-8 (SPA security).** The admin SPA is a **static** site behind **CloudFront + admin-Cognito
  Hosted UI** (auth-code + PKCE), short token lifetimes, **no secrets in the bundle**, CSP locked
  down; it holds **no** privileges itself — every privileged action is an authorized API call. (If
  even a private SPA is deemed too much surface for v1, the **CLI-only** path satisfies all FRs — D-1.)
- **NFR-9 (testability).** Pure authz/role logic and the audit-wrapper are **unit-tested**; handler
  tests assert **(a) non-admin → 403**, **(b) audit written on every mutation**, **(c) `admin_adjust`
  ledger path**, **(d) least-privilege synth**. (These map to the named tests in §7/§8.)

## 6. Design

### 6.1 Admin authorization boundary (the load-bearing decision)
**Separate admin identity, distinct authorizer.** Two viable shapes; we **recommend (A)**:
- **(A) Separate admin user pool (recommended).** A new **`AdminUserPool`** (in
  `auth_stack.py` or a new `admin_auth_stack.py`) with **MFA required (TOTP)**, **self-sign-up
  disabled** (admins are invited/provisioned), a **group `mango-admins`** plus role groups
  (`mango-support`, `mango-moderator`, `mango-catalog`, `mango-admin`, `mango-admin-breakglass`), and
  its **own Hosted-UI** app client for the SPA. Admin identities are **wholly separate** from end
  users — a compromised app account can never be an admin, and the blast radius / token lifetimes /
  MFA policy are independent. **Recommended** for clean separation and least surprise.
- **(B) One pool + an admin group.** Reuse the existing user pool and add a `mango-admins` group;
  the admin authorizer checks the `cognito:groups` claim. Less infra, but **mixes** end-user and
  admin identity in one pool (and Mango's app client is a *public PKCE* client — not ideal to also
  carry admin sessions). Acceptable only if MFA can be **forced for admins specifically** (group-based
  MFA is awkward). **Not recommended.**

**The admin authorizer.** A **Lambda (REQUEST/JWT) authorizer** distinct from the public
`HttpUserPoolAuthorizer`:
1. Validates the JWT against the **admin** pool/client (issuer + audience + signature via the pool
   JWKS; `boto3`/stdlib JWKS fetch + cache, or a Cognito JWT authorizer that we then *augment* — but
   group/role enforcement must happen regardless because a plain Cognito authorizer only checks pool
   membership, per AWS guidance, [§12]).
2. Requires **`mango-admins`** membership and extracts the **highest role** present.
3. Emits an **IAM policy** (allow on `/v1/admin/*`) plus a **context** `{ adminSub, adminEmail, role,
   mfa: true }` the handlers read (analogous to `response.user_id`, but `admin_identity(event)`).
4. **Fails closed**: not admin pool / not in group / no MFA AMR claim ⇒ **deny** (401/403), no
   context. In `dev` only, a `MANGO_ADMIN_DEV` env + `x-mango-admin` header may stub an admin (mirrors
   the `x-mango-user` dev fallback in `response.py`) — **never** in `prod`/`beta`.

```python
# backend/src/shared/admin_auth.py  (stdlib + boto3)
ADMIN_GROUP = "mango-admins"
ROLE_RANK = {"support": 1, "catalog": 1, "moderator": 2, "admin": 3, "breakglass": 3}

def admin_identity(event: dict) -> dict:
    """Resolve {adminSub, adminEmail, role} from the admin authorizer context.
    Raises PermissionError when not a verified admin (handlers → 401/403). Fails closed
    in prod/beta; a dev-only x-mango-admin stub is allowed when MANGO_ADMIN_DEV is set."""
    ctx = (event.get("requestContext", {}).get("authorizer") or {})
    ident = ctx.get("lambda") or ctx  # HTTP API REQUEST-authorizer context shape
    if ident.get("adminSub") and ident.get("role"):
        return {"adminSub": ident["adminSub"], "adminEmail": ident.get("adminEmail", ""),
                "role": ident["role"]}
    if os.environ.get("STAGE", "dev") not in ("prod", "beta") and os.environ.get("MANGO_ADMIN_DEV"):
        h = event.get("headers") or {}
        if h.get("x-mango-admin"):
            return {"adminSub": h["x-mango-admin"], "adminEmail": "dev@local", "role": "admin"}
    raise PermissionError("not an admin")

def require_role(identity: dict, minimum: str) -> None:
    if ROLE_RANK.get(identity["role"], 0) < ROLE_RANK[minimum]:
        raise PermissionError(f"role {identity['role']} < required {minimum}")
```

### 6.2 The audit wrapper (a handler cannot forget to audit)
A single decorator wraps every admin handler; the **mutation cannot commit-and-return without an
audit write**, and a failed audit write **fails the request** (NFR-3).

```python
# backend/src/shared/admin_audit.py  (stdlib + boto3; float-free)
def audited(action: str, target_of, *, mutating: bool):
    """Decorator: resolve admin identity, run the handler, and WRITE an append-only
    ADMIN#AUDIT#<ts>#<uuid> item (by-target + by-actor via GSI1). On a mutating action the
    audit write is synchronous and blocking — if it fails, the whole request 500s (we do not
    silently take a privileged action without a trail)."""
    def wrap(handler):
        def inner(event, context):
            try:
                ident = admin_identity(event)
            except PermissionError:
                return forbidden("admin only")     # 403, NO side effect
            resp = handler(event, context, ident)  # handler does role checks + the action
            _put_audit_item(                        # PK=ADMIN#AUDIT#<ts>#<uuid>, GSI1 by target
                actor=ident, action=action, method=http_method(event), path=_path(event),
                target=target_of(event), args=_redact(parse_body(event)),
                reason=(parse_body(event).get("reason")), request_id=_req_id(event),
                source_ip=_ip(event), status=resp.get("statusCode"))
            return resp
        return inner
    return wrap
```
- Audit item attributes: `actorSub, actorEmail, role, action, method, path, targetType, targetId,
  argsRedacted (json str), reason, requestId, sourceIp, userAgent, stage, statusCode, createdAt` —
  all strings/ints (**float-free**). `before/after` are optional JSON-string snapshots for
  credit/catalog/state changes.
- **Append-only:** the admin Lambdas' IAM policy permits `PutItem` on the table but the audit path
  uses **conditional create** (`attribute_not_exists(PK)`, unique uuid) and there is **no** code path
  that updates/deletes an `ADMIN#AUDIT#…` item; optionally a `kms`-signed or Object-Locked archive
  copy (NFR-3).

### 6.3 Action → role matrix (enforced in handler via `require_role`)
| Action | Endpoint | Min role | Notes |
|---|---|---|---|
| Look up a user (read) | `GET /v1/admin/users/{sub}` · `?email=` | `support` | privileged **read** is audited |
| Add support note | `POST …/{sub}/notes` | `support` | internal only |
| Credit adjust ≤ cap | `POST …/{sub}/credits/adjust` | `support` | `admin_adjust`; idempotent |
| Credit adjust > cap | same | `admin` | large grants/clawbacks |
| Catalog create/edit | `POST/PUT /v1/admin/catalog[/{id}]` | `catalog` | writes `BOOK#…/META` |
| Catalog disable/enable | `POST …/catalog/{id}/disable`·`/enable` | `catalog` | soft `status` flip |
| Catalog pre-warm | `POST …/catalog/{id}/prewarm` | `catalog` | triggers [`0028`] |
| Moderation list/get | `GET /v1/admin/moderation[/{id}]` | `moderator` | with context |
| Moderation action (dismiss/hide/warn/suspend/escalate) | `POST …/moderation/{id}/action` | `moderator` | per-action |
| Ban user / remove facilitator | `…/action` (ban) · `POST …/facilitators/{sub}` | `admin` | destructive + confirm |
| Safety/age **override** | `POST …/{sub}/override` | `admin` | explicit, reason-required |
| Read audit | `GET /v1/admin/audit?targetId=`·`?actorSub=` | `moderator` (own scope) / `admin` (all) | append-only |
| Break-glass destructive | (any destructive) | `breakglass` | time-boxed, alarmed |

### 6.4 Moderation queue — producers, item shape, and the one new GSI
**Producers (existing/other specs write the flags; this spec reads + actions them):**
- **`REPORT#<id>/META`** — user reports from [`0021`]/[`0043`] (`reporterSub, targetHandle, sessionId?,
  reason, detail?, at, status`).
- **`SAFETYFLAG#<id>/META`** — [`0043`] no-show/abuse flags (`subjectSub, kind, sessionId?, at,
  status`).
- **`MODFLAG#<id>/META`** *(new; written by [`0030`] and [`0042`])* — borderline AI/media output
  ([`0030`] "flagged") and [`0042`] spot-check escalations: `{ kind ∈ {ai_output, user_media,
  spotcheck}, subjectSub, artifactKey? (→ [`0027`]), contentRef?, severity:int, reason, at, status }`.
  *(0030/0042 own the write; this spec defines the item so all three queue sources are uniform — a
  small contract note added to those specs.)*

**Unified queue read.** To list "open items, most severe/newest first" across these PKs without a
`Scan`, add **one GSI** `GSI_MOD` (`data_stack.py`): `GSI_MODPK = "MODQUEUE#<status>"` (e.g.
`MODQUEUE#open`), `GSI_MODSK = "<severityDesc>#<ts>"`. Each producer sets the two GSI attributes when
`status=open`; an action handler updates `status` (→ removes from the `open` partition). One `Query`
on `MODQUEUE#open` returns the worklist; filtering by `type/severity` is in-handler. *(Alternative
considered: reuse `GSI1` with `GSI1PK="MODQUEUE#open"` — viable, but `GSI1` is already heavily used by
library/leagues/audit-by-target; a dedicated low-cardinality `GSI_MOD` keeps the hot worklist query
clean. Decision D-3.)*

**Item (queue projection) + action.**
```
GET /v1/admin/moderation/{id} →
  { id, type, severity, status, subjectSub?, handle?, reason,
    context: { artifact?: {key, snippet}, report?: {text}, flag?: {kind, sessionId} },
    createdAt }
POST /v1/admin/moderation/{id}/action  { action, reason, targetSub?, contentRef? }
  action ∈ { dismiss, hide_content, warn_user, suspend_user, ban_user, remove_facilitator, escalate }
  → applies effect (set content status / account flag / facilitator status / escalate ticket),
    sets queue item status (actioned|dismissed|escalated), writes ADMIN#AUDIT#… (FR-9).
```
- **hide_content** flips a `status` flag on the offending item (e.g. a generated roadmap artifact
  pointer, a user-media item) so it is suppressed; **un-hide** is an `override` (FR-11).
- **escalate** writes an escalation marker (and, if [`0037`]/SES exists, notifies Legal/T&S) and
  parks the item `escalated` for a higher tier — matching the **multi-level** moderation pattern
  ([§12]).

### 6.5 Credit/refund adjustment — reusing [`0023`] (no parallel money path)
The adjust handler **does not** re-implement balance math; it calls [`0023`]'s primitive with the
`admin_adjust` reason and an idempotency key:
```python
# handlers/admin_users.py (excerpt) — role-checked, idempotent, audited by the wrapper
def _adjust(event, context, ident):
    require_role(ident, "support")
    body = parse_body(event); delta = int(body["delta"])         # int → float-free
    if abs(delta) > SUPPORT_ADJUST_CAP:
        require_role(ident, "admin")                              # large adjust ⇒ admin
    sub = _sub(event); key = _idempotency_key(event)             # Idempotency-Key header
    state = credits.admin_adjust(sub, delta, reason_ref=body.get("refType"),
                                 ref_id=body.get("refId"), idem_key=key)  # 0023 primitive
    return ok(state)                                             # CreditsState; wrapper audits
```
- **[`0023`] addition (small):** expose `credits.admin_adjust(uid, delta, *, reason_ref, ref_id,
  idem_key)` = idempotent `UpdateItem` on `CREDITS` (`balance += delta`, `version += 1`, roll-ups) +
  `_append_ledger(reason="admin_adjust", delta, balanceAfter, refType, refId)`, guarded by an
  `ADMINADJ#<idemKey>` marker so retries don't double-apply. The **operator justification** (`reason`
  free-text) lives on the **audit** item; the **ledger** keeps the closed-enum `admin_adjust` reason
  the user can see. Balance may go negative (clawback) exactly as [`0023`] allows.
- **Refunds for [`0024`]:** an operator refund of a redemption is an `admin_adjust` with
  `refType="redemption", refId=<redemptionId>` (and, where the redemption is reversible, a [`0024`]
  status set to `refunded`); the partner/coupon side is [`0024`]'s concern.

### 6.6 Catalog curation + [`0028`] pre-warm
- Writes **`BOOK#<id>/META`** with the [`0009`] schema (`title, author, excerpt, categories[],
  coverURL?, coverHue, source, license, gutenbergId?, status ∈ {active, disabled}`), validating
  required fields + **license present** (the [`0009`] compliance invariant). The **public**
  `catalog.py` reader is updated (by [`0009`]/[`0028`]) to prefer DDB and **respect `status`** so a
  disabled book disappears from `GET /v1/catalog` without touching user data.
- **Pre-warm:** `POST …/catalog/{id}/prewarm` **async-invokes [`0028`]'s pre-warm worker**
  (`lambda.invoke(Event)`, the established roadmap-worker pattern) so the shared activity template for
  that book is generated and cached; returns `{ status: "queued", ref }`. The pre-warm worker itself
  (and the single-flight lock) is [`0028`]; this is just the **operator trigger**.

### 6.7 API / contract (in **`shared/api/admin-openapi.yaml`** — separate from the public spec)
All paths under `/v1/admin/`, **admin-authorizer-secured**, JSON. (Excerpt; full file is the
deliverable.)
```yaml
# admin-openapi.yaml — NOT bundled into the iOS contract
paths:
  /v1/admin/users/{sub}:
    get: { summary: Aggregated read-only user view (audited), responses: { "200": {...}, "403": {...} } }
  /v1/admin/users:
    get: { summary: Lookup by email (?email=), responses: { "200": {...} } }
  /v1/admin/users/{sub}/credits/adjust:
    post:  # Idempotency-Key header; admin_adjust via 0023
      summary: Adjust a user's credit balance (admin_adjust, audited, idempotent)
      requestBody: { required: true, content: { application/json: { schema: { $ref: "#/components/schemas/CreditAdjust" } } } }
      responses: { "200": { $ref: "#/components/responses/CreditsState" }, "403": {...}, "409": { description: idempotent replay } }
  /v1/admin/users/{sub}/notes:        { post: { summary: Add internal support note } }
  /v1/admin/users/{sub}/suspend:      { post: { summary: Suspend account (moderator+) } }
  /v1/admin/users/{sub}/ban:          { post: { summary: Ban (admin; global sign-out + disable) } }
  /v1/admin/users/{sub}/override:     { post: { summary: Explicit safety/age gate override (admin, reason) } }
  /v1/admin/catalog:                  { post: { summary: Create catalog book (catalog role) } }
  /v1/admin/catalog/{id}:             { put:  { summary: Edit catalog book } }
  /v1/admin/catalog/{id}/disable:     { post: { summary: Soft-disable (status) } }
  /v1/admin/catalog/{id}/prewarm:     { post: { summary: Trigger 0028 pre-warm } }
  /v1/admin/moderation:               { get:  { summary: Queue (status/severity/type filters) } }
  /v1/admin/moderation/{id}:          { get:  { summary: Item + context (0027 snippet, report, flag) } }
  /v1/admin/moderation/{id}/action:   { post: { summary: Take action (dismiss/hide/warn/suspend/ban/remove_facilitator/escalate) } }
  /v1/admin/facilitators/{sub}:       { post: { summary: Set facilitator status (0043) } }
  /v1/admin/audit:                    { get:  { summary: Audit by targetId or actorSub (append-only) } }
components:
  schemas:
    CreditAdjust:
      type: object
      required: [delta, reason]
      properties:
        delta:   { type: integer, example: 20 }       # int (float-free); negative = clawback
        reason:  { type: string, description: operator justification (stored on audit) }
        refType: { type: string, nullable: true, enum: [redemption, ticket, goodwill, correction] }
        refId:   { type: string, nullable: true }
    ModerationAction:
      type: object
      required: [action, reason]
      properties:
        action:   { type: string, enum: [dismiss, hide_content, warn_user, suspend_user, ban_user, remove_facilitator, escalate] }
        reason:   { type: string }
        targetSub:{ type: string, nullable: true }
        contentRef:{ type: string, nullable: true }
```
**Contract sync:** `admin-openapi.yaml` ⇄ `backend/src/handlers/admin_*.py` ⇄ the **SPA/CLI** clients.
The **public** `openapi.yaml` and `DTOs.swift` are **untouched** (FR-13).

### 6.8 Data — single-table items (all `int`-safe; one new GSI)
```
# Audit (append-only) — by-target & by-actor via GSI1
PK = ADMIN#AUDIT#<ts>#<uuid>     SK = META
  attrs: actorSub, actorEmail, role, action, method, path, targetType, targetId,
         argsRedacted(S json), before(S json,opt), after(S json,opt), reason(S,opt),
         requestId, sourceIp, userAgent, stage, statusCode(N int), createdAt(S iso)
  GSI1: GSI1PK = ADMINAUDIT#<targetId>     GSI1SK = <ts>#<uuid>     # "history for this user/book"
        (a second mirror row or a sparse GSI2-style key gives by-actor; or query+filter actorSub)

# Support notes (internal only)
PK = USER#<sub>                  SK = ADMINNOTE#<ts>#<uuid>   { authorSub, authorEmail, text, createdAt }

# Account status flag (suspend/ban; honored by app/authorizers)
PK = USER#<sub>                  SK = ACCOUNTSTATUS           { status: active|suspended|banned, by, reason, at }

# Moderation queue items (producers in §6.4) — unified worklist via GSI_MOD
PK = MODFLAG#<id> | REPORT#<id> | SAFETYFLAG#<id>   SK = META
  shared queue attrs when open: status(open|actioned|dismissed|escalated), severity(N int),
         GSI_MODPK = MODQUEUE#<status>   GSI_MODSK = <severityDesc>#<ts>
# Catalog (curation target; 0009/0028 home)
PK = BOOK#<id>                   SK = META    { ...0009 fields..., status: active|disabled, updatedBy, updatedAt }
# Facilitator pool (0043)
PK = FACILITATOR#<sub>           SK = META    { status: active|suspended|removed, ... , updatedBy, updatedAt }
```
- **New GSI `GSI_MOD`** added in `data_stack.py` (low-cardinality `MODQUEUE#<status>` partition); all
  other access uses `PK`/`SK` + the existing `GSI1`. **Float-free** throughout (`severity`,
  `statusCode`, any score are `int`).
- Admin items **scope by target** so [`0033`] deletion and the existing `DELETE /v1/me` cascade can
  decide their fate (notes/audit retention is a **policy** call — audit is typically retained for the
  account's life or a fixed window even post-deletion, per Legal; flagged in §10).

### 6.9 IAM (least-privilege; mirror `api_stack.py`)
Distinct Lambdas, each with the **minimum** grant:
- **`AdminAuthorizerFn`** — no table/data access; only JWKS fetch (public) + emits policy/context.
- **`AdminUsersFn`** (lookup, notes, credits-adjust, suspend/ban, override) — table **read/write** on
  `USER#…` + `ADMIN#AUDIT#…` (Put-only on audit) + the **Cognito admin** grant scoped to the
  **user** pool (`AdminGetUser`, `AdminUserGlobalSignOut`, `AdminDisableUser`) — mirroring
  `delete_account`'s single scoped Cognito grant. **No** Bedrock, **no** S3 (except none needed).
- **`AdminCatalogFn`** — table read/write on `BOOK#…` + `ADMIN#AUDIT#…` + `lambda:InvokeFunction` on
  the **[`0028`] pre-warm worker only**. No Cognito, no credit write.
- **`AdminModerationFn`** — table read/write on queue items + account/facilitator/content `status` +
  `ADMIN#AUDIT#…`; **S3 `GetObject` read-only on `users/*`** (read [`0027`] artifact snippets); the
  **Cognito** grant only for the ban action (or delegate ban to `AdminUsersFn`). No credit write, no
  Bedrock.
- **Audit append-only:** no admin Lambda gets `DeleteItem`/`UpdateItem` permission on
  `ADMIN#AUDIT#…` (NFR-3). `cdk synth` shows **no** wildcard `Resource:"*"` beyond service
  requirements (AC-9).

### 6.10 The console UI (recommendation) + break-glass + CLI
- **Recommended: a separate internal static React SPA** (`admin/` web project — Vite + React +
  `aws-amplify`/`amazon-cognito-identity-js` for **admin-Cognito Hosted-UI** auth), hosted on **S3 +
  CloudFront** with **admin-pool** sign-in, short token lifetimes, locked CORS/CSP, **no secrets in
  the bundle**. Screens: **User lookup** (search → aggregated view → adjust-credits / add-note /
  suspend), **Moderation queue** (table with severity/age sort, item drawer with [`0027`] transcript
  viewer + action buttons), **Catalog** (list/create/edit/disable + pre-warm), **Facilitators**,
  **Audit** (filter by user/admin). It is **not** part of the iOS app and adds **no** iOS dependency.
- **Break-glass + CLI:** `backend/scripts/mango_admin.py` (boto3 + requests) authenticates as an admin
  (or assumes `admin-breakglass`) and calls the same admin API — the primary tool when the SPA is down
  and for scripted/bulk-free operations; every call is audited identically.
- **Decision D-1:** **SPA + CLI** recommended; if v1 wants the smallest surface, **ship CLI-only
  first** (it satisfies every FR) and add the SPA in a follow-up. Either way the **API is the
  product**; the clients are thin.

### 6.11 CDK / infra
- **Auth:** add `AdminUserPool` + role groups + admin Hosted-UI client (recommend a new
  `admin_auth_stack.py`, or extend `auth_stack.py`), **MFA required**.
- **API:** either **a second HTTP API** `mango-admin-<stage>` (clean isolation, admin authorizer,
  CORS locked to the SPA origin) **or** an `/v1/admin/*` route group on the existing API with the
  **admin** authorizer attached to those routes (the existing `route(...)` helper extended to accept
  an `authorizer=` override). **Recommend a separate admin HTTP API** for blast-radius isolation and
  independent CORS/throttle (Decision D-4). New Lambdas via `make_fn`; routes via the helper;
  least-privilege grants per §6.9.
- **SPA:** S3 bucket (BlockPublicAccess) + CloudFront (OAC) + the admin Hosted-UI callback; its own CI
  job. **Audit archive (optional):** a separate, Object-Locked S3 bucket / dedicated CloudWatch Logs
  group for the write-once audit copy (NFR-3) — **not** the product bucket.
- `cdk synth -c stage=beta` must pass (admin pool+MFA, separate authorizer, routes, least-privilege,
  the new GSI).

### 6.12 Sequence (credit adjust) & (moderation action)
```
Credit adjust (support):
  SPA/CLI ──(admin JWT, Idempotency-Key)── POST /v1/admin/users/{sub}/credits/adjust {delta, reason}
   → AdminAuthorizerFn: admin pool? in mango-admins? MFA? → context{adminSub, role}
   → AdminUsersFn: require_role(support); |delta|>cap ⇒ require_role(admin)
   → credits.admin_adjust(sub, delta, idem)  [0023: UpdateItem CREDITS + ledger(admin_adjust)]
   → audited wrapper: PutItem ADMIN#AUDIT#…(actor, before/after, reason)   [blocking — no audit ⇒ 500]
   → 200 CreditsState

Moderation action (moderator):
  SPA ── GET /v1/admin/moderation?status=open  → Query GSI_MOD(MODQUEUE#open) → worklist
  SPA ── GET /v1/admin/moderation/{id}        → item + 0027 snippet + report/flag context
  SPA ── POST /v1/admin/moderation/{id}/action {action:suspend_user, reason}
   → AdminModerationFn: require_role(moderator); apply ACCOUNTSTATUS=suspended (+Cognito sign-out if ban)
   → set queue item status=actioned (leaves MODQUEUE#open partition)
   → audited PutItem ADMIN#AUDIT#…  → 200
```

## 7. Acceptance criteria
- [ ] **AC-1 (admin authz denies non-admins).** A request to any `/v1/admin/...` route with **(a) no
  token, (b) a valid *end-user* app JWT, or (c) an admin-pool token lacking `mango-admins`** returns
  **401/403** and produces **no side effect**. *(named: `test_admin_authz_denies_non_admin`.)*
- [ ] **AC-2 (role scoping).** A `support`-role admin calling a `moderator`/`admin`-only action (e.g.
  ban, or a credit adjust above the support cap) gets **403**, and the **denied attempt is audited**.
  *(named: `test_admin_role_scoping_denied_attempt_audited`.)*
- [ ] **AC-3 (audit log written on every mutation).** Each mutating admin call writes exactly one
  append-only `ADMIN#AUDIT#…` item with actor, action, target, reason, requestId, sourceIp; a
  **forced audit-write failure makes the request 500** (no silent privileged action). The item is
  queryable by `targetId` via `GSI1`. *(named: `test_admin_audit_written_on_mutation`,
  `test_admin_audit_failure_blocks_action`.)*
- [ ] **AC-4 (credit adjust path → `admin_adjust`).** `POST …/credits/adjust {delta, reason}` updates
  `USER#<sub>/CREDITS` by `delta` (int), appends a `CREDITLEDGER#…` entry with
  **`reason="admin_adjust"`**, is **idempotent** under a repeated `Idempotency-Key` (one ledger
  entry), and returns the new `CreditsState`. *(named: `test_admin_credit_adjust_admin_adjust_ledger`,
  `test_admin_credit_adjust_idempotent`.)*
- [ ] **AC-5 (catalog curation + pre-warm).** Create/edit/disable writes `BOOK#<id>/META` (with
  `status` + license validation); **disable** removes the book from the public `GET /v1/catalog`;
  `…/prewarm` **invokes the [`0028`] worker** (asserted via a stubbed `lambda.invoke`). *(named:
  `test_admin_catalog_crud_and_status`, `test_admin_catalog_prewarm_invokes_0028`.)*
- [ ] **AC-6 (moderation queue + action).** The queue lists open `REPORT#`/`SAFETYFLAG#`/`MODFLAG#`
  items via `GSI_MOD`; an action (e.g. `suspend_user`) sets the **account status flag**, transitions
  the item out of `open`, and is **audited**; `ban_user` requires `admin` role and performs the
  Cognito global-sign-out + disable. *(named: `test_admin_moderation_list_and_action`,
  `test_admin_ban_requires_admin_and_signs_out`.)*
- [ ] **AC-7 (no silent gate bypass).** There is **no** endpoint that flips a [`0031`] age
  restriction or un-hides [`0030`]-flagged content **without** the explicit `override` action
  (`admin` role + reason), and that override is audited. *(named: `test_admin_override_required_and_audited`.)*
- [ ] **AC-8 (privileged reads audited).** `GET /v1/admin/users/{sub}` (reading another user's
  profile/credits) writes an audit item. *(named: `test_admin_user_read_is_audited`.)*
- [ ] **AC-9 (least-privilege IAM).** `cdk synth -c stage=beta` shows: the admin authorizer has no
  data access; `AdminUsersFn` has the scoped Cognito grant but **no Bedrock**; `AdminCatalogFn` has
  **only** `BOOK#`/audit + the pre-warm `InvokeFunction`; **no** admin Lambda can `DeleteItem`/
  `UpdateItem` an `ADMIN#AUDIT#…`; **no** wildcard `Resource:"*"` beyond service needs; the public
  `grade_fn` still has no table access. *(named: `test_admin_iam_least_privilege` / synth inspection.)*
- [ ] **AC-10 (MFA + separate identity).** The admin pool requires MFA (TOTP) and self-sign-up is
  disabled; the admin authorizer is **distinct** from the public user-pool authorizer. *(synth/config
  inspection.)*
- [ ] **AC-11 (contract isolation).** Admin paths exist **only** in `admin-openapi.yaml`; the public
  `openapi.yaml` and `DTOs.swift` gain **no** admin shapes; both specs lint. *(CI lint + diff check.)*
- [ ] **AC-12 (no iOS/offline impact).** No iOS files change; the app's public API surface is
  unchanged; offline-first first-run is unaffected. *(repo diff + existing iOS tests stay green.)*
- [ ] **AC-13 (style/runtime).** Lambdas stdlib + boto3; black(100)+flake8(120); float-free;
  `pytest` (moto; Cognito/Bedrock monkeypatched) + `cdk synth ×stage` pass offline. *(CI.)*

## 8. Test plan
**Backend — `pytest` (moto; Cognito + Bedrock + `lambda.invoke` monkeypatched), new files under
`backend/tests/`:**
- `test_admin_auth.py` — `admin_identity` resolves context; **fails closed** with no/invalid/non-group
  token (AC-1); `require_role` matrix (AC-2); dev `x-mango-admin` stub works only when
  `MANGO_ADMIN_DEV` set and stage∉{prod,beta}.
- `test_admin_audit.py` — the `audited` wrapper writes one append-only item per mutation (AC-3),
  records actor/action/target/reason/ip/requestId, indexes by `targetId` (GSI1), and **fails the
  request when the audit write fails**; asserts **no** update/delete path exists for audit items.
- `test_admin_users.py` — lookup aggregates read-only items + `AdminGetUser` (stubbed) and **audits
  the read** (AC-8); `credits/adjust` writes `admin_adjust` + idempotent (AC-4); suspend/ban set the
  flag + (ban) Cognito global-sign-out/disable, `admin`-only (AC-6); `override` required + audited
  (AC-7).
- `test_admin_catalog.py` — CRUD writes `BOOK#…/META` with `status`+license validation; disable hides
  from public catalog; `prewarm` invokes the [`0028`] worker (stubbed `lambda.invoke`) (AC-5).
- `test_admin_moderation.py` — seed `REPORT#`/`SAFETYFLAG#`/`MODFLAG#`; list via `GSI_MOD`; action
  transitions status + applies effect + audits (AC-6); context view returns a [`0027`] artifact
  snippet (stubbed S3 get).
- `test_admin_iam_synth.py` / extend `test_contract.py` — `cdk synth -c stage=beta` IAM + authorizer +
  MFA + GSI assertions (AC-9/AC-10); `admin-openapi.yaml` parses and the public `openapi.yaml` has
  **no** `/v1/admin` paths (AC-11).
**SPA (if built):** a lightweight component/e2e smoke (sign-in via admin Hosted-UI mock → load queue →
take an action against a stubbed API) — non-blocking for v1 if CLI-only ships first.
**CLI:** unit-test the request builder/auth; a manual break-glass dry-run on Beta.
**Manual / operational (Beta):** create an admin (MFA), look up a seeded user, do a credit adjust and
confirm the user sees `admin_adjust`, disable+pre-warm a catalog book, action a seeded moderation
item, and pull the audit trail by user and by admin; confirm a non-admin app token gets 403.

## 9. Rollout & migration
- **Stages/flags.** Build behind an **`adminConsoleEnabled`** stage flag; the admin API/authorizer can
  be **disabled** (deny-all) as a kill-switch (NFR-7). Land **Beta first**, soak, then **Prod**.
- **Order.** (1) `AdminUserPool` + groups + MFA + admin authorizer; (2) audit wrapper + `ADMIN#AUDIT#`
  + `GSI_MOD` in `data_stack`; (3) user-lookup + credits-adjust ([`0023`] `admin_adjust` seam); (4)
  catalog CRUD + [`0028`] pre-warm trigger; (5) moderation queue list/action + [`0030`]/[`0042`]
  `MODFLAG#` producer note + [`0043`] report/facilitator wiring; (6) overrides + break-glass; (7) the
  SPA (or CLI-only first).
- **Dependencies.** [`0026`] (real progress/activity for lookup) is the practical prerequisite; the
  **data shapes** of [`0023`]/[`0024`]/[`0043`] must exist for those surfaces to operate (a surface
  can ship "empty" before its producer does). [`0030`]/[`0042`] add a one-line `MODFLAG#` write when
  they land; until then the queue carries `REPORT#`/`SAFETYFLAG#` only.
- **Provisioning admins** is **out-of-band** (AWS console/IaC/SSO) — adding/removing an admin and
  assigning a role is itself privileged and never self-served (Non-goals).
- **Data migration.** Additive only (new item types + one GSI); no rewrite of existing rows. Disabling
  a book or pausing a reward is reversible (`status` flips).
- **Teardown.** Disabling the flag denies the admin API and hides the surface; audit data is retained
  per policy (§10).

## 10. Risks & open decisions
- **R-1 (the console is the keys to the kingdom).** A compromised admin can read PII and move credits.
  *Mitigation:* separate MFA-required pool, least-privilege per-action IAM, **everything audited**
  (incl. reads), role caps, destructive actions gated + confirmed, CORS/CSP locked, no secrets in the
  SPA, kill-switch. **Standing privilege is minimized**; break-glass is time-boxed + alarmed
  ([§12 PAM/break-glass]).
- **R-2 (audit integrity).** An attacker who can edit/delete audit rows defeats the control.
  *Mitigation:* append-only (no update/delete IAM on audit items), unique-uuid conditional create,
  optional Object-Locked/CloudWatch **archive copy** in a **separate** bucket (kept out of the
  GDPR-deletion path [`0027`] flags). **Decision D-5:** ship the in-table append-only audit in v1; add
  the write-once archive copy in the same milestone if Security requires immutability guarantees.
- **R-3 (silent gate bypass / abuse of override).** An operator could re-enable a feature for an
  under-13 or un-hide harmful content. *Mitigation:* overrides are a **distinct, `admin`-only,
  reason-required, audited** action (FR-11); default deny; alarms on override usage; periodic audit
  review. **Never** an implicit side effect of another endpoint.
- **R-4 (data minimization vs. usefulness).** Showing operators everything is convenient but
  over-exposes PII. *Mitigation:* aggregate view returns the **minimum**; moderation context is a
  **snippet** not full content; handle-over-email where possible; reads audited. (NFR-4.)
- **R-5 (admin actions vs. user deletion / DSAR).** When a user is deleted ([`0033`]/`DELETE /v1/me`),
  what happens to audit/notes about them? *Mitigation/Decision D-6:* **retain audit** for a fixed
  window (or account-life) even post-deletion for security/forensics, **pseudonymized** where the law
  requires; notes deleted or retained per Legal. **Counsel decides**; the spec keeps audit
  target-scoped so either is implementable.
- **R-6 (SPA surface).** A web console is more attack surface than no UI. *Mitigation:* static site,
  private behind CloudFront + admin-Cognito + MFA, no privilege in the client, locked CSP/CORS; **or**
  **ship CLI-only first** (D-1) and add the SPA later.
- **R-7 (appeals / regulatory obligations).** Apple/EU regimes may require user appeal paths for
  enforcement actions. *Mitigation:* the queue supports an `escalate`/appeal item type; a user-facing
  appeals **flow** is a future product spec (Non-goals). Flag for Legal.
- **R-8 (separate API vs. route group).** A second HTTP API isolates blast radius but is more infra.
  **Decision D-4 (recommend separate admin HTTP API)** for independent CORS/throttle/authorizer.
- **Decisions needed (with recommendations):**
  - **D-1 — UI shape.** *Recommend* **internal static React SPA (S3+CloudFront+admin-Cognito) + a CLI
    for break-glass/scripting**; acceptable minimal-v1 is **CLI-only** then SPA. (Either way, API-first.)
  - **D-2 — Admin identity.** *Recommend* **separate admin user pool** (MFA, no self-sign-up, role
    groups) over reusing the app's public-PKCE pool.
  - **D-3 — Moderation index.** *Recommend* **a dedicated `GSI_MOD` (`MODQUEUE#<status>`)** over
    overloading `GSI1`.
  - **D-4 — API isolation.** *Recommend* **a separate `mango-admin-<stage>` HTTP API** with the admin
    authorizer (vs. an `/v1/admin/*` group on the existing API).
  - **D-5 — Audit immutability.** *Recommend* **in-table append-only now**, write-once archive copy if
    Security requires; revisit per R-2.
  - **D-6 — Audit/notes retention vs. deletion.** *Recommend* **retain audit for a fixed window
    post-deletion (pseudonymized as required); notes per Legal** — confirm with counsel ([`0033`]).
  - **D-7 — `MODFLAG#` ownership.** *Recommend* **[`0030`]/[`0042`] write `MODFLAG#`; 0034 defines the
    shared item + reads/actions it** (a one-line contract note added to those specs).

## 11. Tasks & estimate
1. **Admin auth:** `AdminUserPool` + role groups + MFA + admin Hosted-UI client (`admin_auth_stack.py`
   or extend `auth_stack.py`) + the **Lambda admin authorizer** (`AdminAuthorizerFn`) + `cdk synth`
   assertions (AC-1/AC-10). **(M)**
2. `backend/src/shared/admin_auth.py` (`admin_identity`, `require_role`, role ranks) + `response.py`
   `forbidden`/`unauthorized` helpers + pytest (`test_admin_auth.py`, AC-1/AC-2). **(S)**
3. `backend/src/shared/admin_audit.py` — the **`audited` wrapper** + append-only `ADMIN#AUDIT#` writer
   (by-target GSI1) + redaction + **fail-closed on audit-write failure** + pytest (AC-3/AC-8). **(M)**
4. `data_stack.py` — add **`GSI_MOD`**; reserve audit/account/notes/queue item shapes; `cdk synth`. **(S)**
5. `backend/src/handlers/admin_users.py` — lookup (aggregate read-only + `AdminGetUser`), **credits
   adjust → [`0023`] `admin_adjust`** (idempotent), notes, suspend/ban (Cognito sign-out/disable),
   **override** + pytest (`test_admin_users.py`, AC-4/AC-6/AC-7/AC-8). **(L)**
6. **[`0023`] seam:** add `credits.admin_adjust(uid, delta, *, reason_ref, ref_id, idem_key)`
   (idempotent ledger `admin_adjust`) + pytest. **(S)**
7. `backend/src/handlers/admin_catalog.py` — CRUD on `BOOK#…/META` (+ `status` + license validation) +
   **pre-warm trigger ([`0028`] `lambda.invoke`)** + pytest (`test_admin_catalog.py`, AC-5). **(M)**
8. `backend/src/handlers/admin_moderation.py` — queue list (`GSI_MOD`), item+context (read [`0027`]
   snippet), **action** (dismiss/hide/warn/suspend/ban/remove_facilitator/escalate) + facilitator
   status + pytest (`test_admin_moderation.py`, AC-6). **(L)**
9. **`MODFLAG#` producer notes** — coordinate one-line writes from [`0030`] (borderline) and [`0042`]
   (spot-check escalation); define the shared queue item in this spec. **(S)**
10. `shared/api/admin-openapi.yaml` — author the **separate** admin contract; CI lint + assert public
    `openapi.yaml` has no `/v1/admin` paths (AC-11). **(M)**
11. `api_stack.py` / new admin API — Lambdas via `make_fn`, routes (admin authorizer), **least-
    privilege grants** per §6.9, locked CORS; `cdk synth ×stage` (AC-9). **(M)**
12. `backend/scripts/mango_admin.py` — **CLI** (boto3+requests; admin/break-glass auth) covering every
    endpoint + a manual break-glass runbook. **(M)**
13. *(If D-1 = SPA)* `admin/` **static React SPA** (Vite + admin-Cognito Hosted-UI) — user lookup,
    moderation queue + [`0027`] transcript viewer, catalog, facilitators, audit — S3+CloudFront + its
    own CI; **no iOS dependency**. **(L)**
14. Audit-archive (optional, R-2/D-5): write-once copy to a separate Object-Locked bucket / dedicated
    Logs group + alarm on override/break-glass usage. **(S)**
15. Manual Beta e2e (admin MFA sign-in; adjust→`admin_adjust` visible; catalog disable+pre-warm; action
    a moderation item; pull audit by user/admin; non-admin → 403). **(M)**

## 12. References
**Repo (read for accuracy):**
- `working/ARCHITECTURE_REVIEW.md` §3 **G10** (this spec's origin) + §4 backlog row 0034.
- `working/0023-payments-and-credits.md` — credit ledger + the **`admin_adjust`** reason (§6.1) +
  `shared/credits.py` primitives this spec invokes (the **only** money path).
- `working/0024-rewards-and-coupons.md` — `REWARD#`/`REDEMPTION#`/`COUPONPOOL#`, refund + `status`
  (pause), admin-seeded catalog/pools (refund/reward ops).
- `working/0042-external-engagement-activities.md` (FR-5 spot-check → **human review per 0034**;
  operator pulls the [`0027`] transcript) and `working/0043-peer-and-human-activities.md`
  (`REPORT#`/`SAFETYFLAG#`/`FACILITATOR#`; **moderation/escalation queue + facilitator management**
  named as 0034; "does not ship without somewhere for a report to go").
- `working/0030-ai-safety-guardrails.md` — borderline output **"queued for 0034 review"**; 0034 = the
  **moderation review console**; CSAM/illegal as a Legal/T&S runbook.
- `working/0027-generation-artifact-store-observability.md` — `ARTIFACT#` index + transcripts **"read
  by 0033/0034"**; reserved `GET /v1/me/artifacts`.
- `working/0009-catalog-expansion-100-books.md` (catalog schema + `catalog_seed.json`, license field)
  and the [`0028`] pre-warm seam; `working/0031-age-assurance-coppa.md` (age band; **fail-closed**
  gates the console must not silently bypass).
- `backend/mango_backend/api_stack.py` (thin-Lambda/`route`/authorizer + **least-privilege** pattern;
  `delete_fn`'s scoped **Cognito admin** grant + `COGNITO_USER_POOL_ID` env — the template for admin
  Cognito actions), `auth_stack.py` (user pool + Hosted UI; **no groups yet**),
  `backend/src/handlers/delete_account.py` (paginated read/cascade idiom; Cognito admin delete),
  `backend/src/handlers/catalog.py` + `backend/src/shared/catalog_data.py` (public catalog reader),
  `backend/src/shared/response.py` (`user_id` fail-closed-in-prod pattern mirrored by
  `admin_identity`), `backend/mango_backend/data_stack.py` (single table + `GSI1`; the new `GSI_MOD`),
  `docs/specs/SPEC_TEMPLATE.md`, `CLAUDE.md` (invariants).

**Research (web) — admin authz, audit, break-glass, moderation (cite; verify at build):**
- AWS — *Controlling serverless API access* (separate users into groups/roles via token claims;
  Cognito authorizer only checks pool membership, so use a **Lambda authorizer + `cognito:groups`**
  for fine-grained admin authz): https://aws.amazon.com/blogs/compute/building-well-architected-serverless-applications-controlling-serverless-api-access-part-3/
  and *RBAC with Amazon Cognito*: https://aws.amazon.com/blogs/security/role-based-access-control-using-amazon-cognito-and-an-external-identity-provider/
- The Burning Monk — *Fine-grained access control in API Gateway with Cognito groups & a Lambda
  authorizer* (the exact admin-authorizer pattern):
  https://theburningmonk.com/2024/08/fine-grained-access-control-in-api-gateway-with-cognito-groups-lambda-authorizer/
- AWS — *Managing temporary elevated access* / break-glass (`EmergencyAccessRole`, time-boxed,
  fully logged): https://aws.amazon.com/blogs/security/managing-temporary-elevated-access-to-your-aws-environment/
  and *IAM security best practices* (least privilege, MFA, audit):
  https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html
- AWS Well-Architected (FSI lens) — *Monitor activity in your AWS account* (privileged-action audit
  via CloudTrail, tamper-resistant logs linking actions to identities):
  https://docs.aws.amazon.com/wellarchitected/latest/financial-services-industry-lens/monitor-activity-in-your-aws-account.html
- Trust & Safety Professional Association — *Content moderation & operations* (review **queues**,
  **multi-level escalation**, decision logging/QA — the moderation-queue design basis):
  https://www.tspa.org/curriculum/ts-fundamentals/content-moderation-and-operations/setting-up-content-moderation-teams/
- AWS — *Building an admin console to manage Cognito users* (internal admin-tool + MFA posture for the
  SPA): https://reintech.io/blog/building-admin-console-manage-aws-cognito-users
