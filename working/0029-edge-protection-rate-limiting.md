# 0029 — Edge protection & request rate-limiting

- **Epic:** M14 · **Status:** Draft · **Owner:** unassigned · **Updated:** 2026-06-28
- **Reviewers:** Principal / SD / QA / Security

## 1. Summary
Protect the Mango backend from abuse and **denial-of-wallet** (DoW): a malicious or runaway client
hammering the expensive routes — `POST /v1/content/parse` (SSRF-guarded fetch + S3 write),
`POST /v1/exercises/grade` (Bedrock), `POST /v1/roadmaps/generate` (Bedrock; credit-gated by `0023`),
`POST /v1/events` (Firehose), `POST /v1/activities/{id}/upload-url` (presigned S3 PUT → downstream
Bedrock/Nova/Transcribe per `0040`), and the **public, unauthenticated** `GET /v1/catalog[/{id}]` and
`GET /health`. We add three reinforcing layers, all in CDK + stdlib/boto3: **(1)** stage- and
route-level **throttling** in API Gateway (HTTP API v2) with deliberately tight burst/rate on the
Bedrock/parse/upload routes; **(2)** an application **per-user + per-IP token-bucket** rate limiter —
a thin **Lambda `REQUEST` authorizer** in front of the existing Cognito JWT authorizer, backed by a
**DynamoDB atomic counter with TTL** (float-free) — enforcing requests-per-minute, an "expensive-op"
sub-budget, and a per-day cap, returning **HTTP 429** with a `Retry-After` header and a standard
error envelope; **(3)** an economic backstop tying every expensive/generative op to **credits**
(`0023`) plus **AWS Budgets + a Bedrock-cost CloudWatch alarm** (cross-ref `0032`) so spend is bounded
even if the request layer is bypassed. Because **AWS WAF cannot attach to an HTTP API v2** (only REST
API / ALB / AppSync / Cognito / CloudFront — verified §12), edge IP-reputation/managed-rule protection
for the public surface is delivered **optionally** by fronting **prod** with **CloudFront + WAF**
(rate-based rules + AWS managed rule sets) for `GET /v1/catalog` and `GET /health`. The work is
backend/infra-only; no iOS code is required for the limiter itself, but the client gains polite
**429 + `Retry-After`** handling (back-off, not a crash) and the `openapi.yaml` error envelope gains a
**429** response so the contract stays in sync.

## 2. Goals / Non-goals
- **Goals:**
  - **Bound worst-case Bedrock + S3 + Firehose spend** from a single abusive caller or a stolen/leaked
    JWT, so no actor can run an unbounded loop against a paid path (DoW defense).
  - **Stage- and route-level throttle config** in `api_stack.py`: a conservative default for every
    route plus **tighter** burst/rate overrides on the Bedrock (`generate`, `grade`), `parse`,
    `upload-url`, and `events` routes. (HTTP API v2 supports per-route `ThrottlingBurstLimit` /
    `ThrottlingRateLimit` — §12.)
  - A **per-user + per-IP token-bucket** application limiter enforcing **RPM**, an **expensive-op**
    sub-budget, and a **per-day** cap; returns **429** + `Retry-After` with the standard error
    envelope. Implemented as a **Lambda authorizer augmenting the JWT authorizer** (recommended) or a
    DynamoDB counter inside handlers — **float-free**, TTL-reaped.
  - **Tie generation/expensive ops to credits** (`0023`) as the economic backstop (already gates
    `generate`; this spec extends the *posture* to make the limiter the first wall and credits the
    second).
  - **AWS Budgets + a Bedrock cost alarm** as the denial-of-wallet *circuit-breaker of last resort*
    (cross-ref `0032`): alert (and optionally auto-throttle) when daily Bedrock/marketplace spend
    crosses a threshold.
  - **Optional CloudFront + WAF in front of prod** for the public `catalog`/`health` routes (edge
    rate-based rules + managed rule groups), since WAF cannot bind directly to the HTTP API.
  - **Abuse observability:** structured "throttled"/"rate-limited" logs, CloudWatch metrics, and an
    alarm on sustained 429/`Throttle` rates, so we *see* an attack.
  - Keep the **contract in sync**: a **429** response + `RateLimited` schema in
    `shared/api/openapi.yaml`, mirrored leniently in `DTOs.swift`; preserve all repo invariants
    (offline-first, Bedrock-only AI, least-privilege IAM, no `float` in DynamoDB, stdlib+boto3, no
    third-party iOS deps).
- **Non-goals:**
  - **A global distributed rate limiter with sub-5 ms p99** (ElastiCache/Redis + Lua). DynamoDB
    atomic counters are sufficient at Mango's scale and stay within the **stdlib+boto3, no extra
    infra** invariant; Redis is noted as a future option in §10 (D-6).
  - **Replacing the Cognito JWT authorizer.** The token-bucket authorizer **augments** it (the
    request authorizer validates the JWT *and* checks the bucket); we do not re-implement OIDC.
  - **Per-tenant billing/usage-plan API keys** (REST-API "usage plans"). HTTP API v2 has no usage-plan
    construct; identity-aware limits are done in the authorizer instead.
  - **Bot/credential-stuffing detection, CAPTCHA, account-takeover heuristics.** Only volumetric +
    expensive-op rate limiting and edge IP rules are in scope; behavioral defense is future work.
  - **The full AI-safety / prompt-injection / moderation surface** — that is `0030`
    (`0030-ai-safety-guardrails.md`); this spec is purely *volumetric/economic* protection.
  - **The full observability + worker-reliability build** (dashboards, X-Ray, DLQ, per-token cost
    metric) — that is `0032` (`0032-observability-cost-reliability.md`); here we add **only** the
    Budgets alert + the abuse/throttle metric + alarm needed for *this* feature and cross-reference
    `0032` for the rest.
  - **Mandatory CloudFront for all routes.** CloudFront/WAF is **prod-only and optional**, fronting the
    public routes; the authenticated API keeps talking to API Gateway directly (the app sends a Cognito
    JWT and is rate-limited at the authorizer regardless).

## 3. Background & context
**Why now.** This expands review gap **G1** in `working/ARCHITECTURE_REVIEW.md` §3: *"No API
rate-limiting / denial-of-wallet protection. `/content/parse`, `/exercises/grade` (Bedrock),
`/events`, public `/catalog` are loop-callable. WAF cannot attach to HTTP API v2."* The review ranks
G1 🔴 Critical and sequences it **before any real traffic / monetization** (§5: *"Before any real
traffic / monetization: 0029 (rate-limit + Budgets), 0030 (AI safety), 0031 (COPPA), 0032
(observability)."*). The as-built backend has **no** rate-limiting, **no** WAF, **no** Budgets, and
**no** Bedrock cost monitoring anywhere (review §1).

**The DoW threat, concretely.** Bedrock Claude is the expensive path. `grade_exercise.handler`
(verified) calls `agent.grade(...)` (Bedrock Opus) on every reflection/application answer **with no
metering** — `grade_fn` deliberately has *no table access* (least-privilege, `api_stack.py`), so it
also has no place to count. `roadmap_worker_fn` runs an Opus generation (~27 s) per job;
`generate_roadmap` is gated by credits in `0023` but a caller with credits (or in a stage where
credits are off) can still loop. `content_parse.handler` fetches an arbitrary URL (SSRF-guarded by
`shared/http.py`, but each call is a 5 MB-capped outbound fetch + an S3 `PutObject`).
`events.handler` is fire-and-forget into Firehose. `0040`'s `POST /v1/activities/{id}/upload-url`
issues a presigned S3 PUT that *unlocks* a multimodal Bedrock/Nova/Transcribe pipeline. Industry
incidents show this is not theoretical: **$46,000/day** (Sysdig LLMjacking on Bedrock) and **$82,000
in 48 h** (a stolen Gemini key, Mar 2026) — and the key insight for LLM apps is that **standard
rate limiters count requests, not cost; an attacker can stay under a request limit while triggering
the most expensive execution paths** (AWS PartyRock write-up, §12). Hence the layered design:
volumetric RPM limit **and** a separate, much smaller **expensive-op** budget **and** credits **and**
a Budgets circuit-breaker.

**The platform constraint (verified).** Mango's API is an **API Gateway HTTP API (v2)**
(`apigw.HttpApi` in `api_stack.py`), chosen for cost/latency and the native `HttpUserPoolAuthorizer`.
**AWS WAF does not support HTTP API v2** — the WAF-protectable resources are CloudFront, **API Gateway
REST API**, ALB, AppSync GraphQL API, Cognito user pool, App Runner, Amplify, and Verified Access
(AWS docs, §12). So we **cannot** simply attach a Web ACL to the HTTP API. Two implications: (a) the
**identity-aware** limit must live in a **Lambda authorizer / DynamoDB counter** (application layer),
and (b) **edge** IP-reputation/managed-rule/rate-based protection for the **public** routes is
available only by putting **CloudFront (with a WAF Web ACL) in front** — which we do, optionally, for
prod.

**Current relevant state (verified):**
- **Routes & auth** (`api_stack.py`): the `route(path, method, fn, secured=True)` helper attaches the
  shared `HttpUserPoolAuthorizer` unless `secured=False`. **`/health` and `/v1/catalog[/{id}]` are
  `secured=False`** (public). The `HttpApi` is created with no `default_*` throttle and no per-route
  `throttle_settings` today.
- **Identity** (`shared/response.py`): `user_id(event)` reads the Cognito `sub` from
  `event.requestContext.authorizer.jwt.claims`, and **raises `PermissionError` in `prod`/`beta`** when
  claims are missing (handlers map that to 401). Outside prod/beta it trusts an `x-mango-user` header
  (dev only). The limiter reuses this exact identity resolution.
- **Error envelope** (`shared/response.py`): the house convention is `{"error": "<message>"}` via
  `bad_request`/`not_found`/`server_error` (+ `0023` adds a structured 402 `payment_required(payload)`
  with extra fields like `balance`/`cost`). This spec adds a sibling **`too_many_requests(...)`** that
  sets the `Retry-After` header and returns `{"error":"rate_limited", "retryAfterSec": N, "scope": …}`.
- **Single table** (`data_stack.py`): one on-demand table, `PK`/`SK` strings, one `GSI1`, **TTL not
  yet enabled** (review §2.1 G6 notes "jobs currently leak — no TTL"). The rate-counter items live on
  the **same** table with a **TTL attribute**, so they self-reap; enabling TTL also benefits the leaked
  jobs (coordinated with `0026`/`0032`).
- **Credits** (`0023`, verified): `POST /v1/roadmaps/generate` already does an atomic conditional
  decrement and returns **402** when insufficient — the **economic** backstop for *generation*. `0023`
  explicitly scopes *charging* to generation only (grade/parse are **not** charged), which is exactly
  why a **request-count** limiter is still needed for grade/parse/events/upload.
- **Style/runtime** (`CLAUDE.md`): backend Lambdas are **stdlib + boto3 only** (no packaging step); the
  DynamoDB resource API **rejects `float`** (coerce to `int`); black (100) + flake8 (120); tests run
  offline (`pytest` with moto; Claude monkeypatched) and `cdk synth -c stage=beta` must pass.

**Related specs.** `0023-payments-and-credits.md` (credits already gate generate — the economic
backstop). `0030-ai-safety-guardrails.md` (content safety; complementary, not overlapping). `0032-
observability-cost-reliability.md` (dashboards/alarms/DLQ/cost-metric — this spec contributes the
Budgets alert + abuse alarm and defers the rest there). `0038-agentic-roadmap-engine.md` and
`0040-multimodal-activities.md` (introduce additional Bedrock/upload spend the route-throttle table
must cover). `working/ARCHITECTURE_REVIEW.md` §3 G1 (the gap), §5 (sequencing).

## 4. User stories
- As **Mango (the business)**, I want a hard ceiling on how fast any single user or IP can hit the
  Bedrock/parse/upload routes, so a stolen token or a buggy client can't run up a five-figure AWS bill
  overnight.
- As a **platform engineer**, I want stage/route throttles plus an identity-aware token bucket so the
  *cheap* read paths stay responsive while the *expensive* paths are tightly capped — and I want a
  Budgets alarm that pages me if spend spikes anyway.
- As a **well-behaved app/user**, when I briefly exceed a limit I want a clean **429 with `Retry-After`**
  so the app can back off and retry, never a confusing error or a silent failure — and my normal usage
  (a handful of generations and a reading session) never trips a limit.
- As a **security reviewer**, I want the **public** `catalog`/`health` routes protected at the edge
  (IP reputation + rate-based rules) in prod, given WAF can't bind to the HTTP API directly, and I want
  abuse to be *observable* (metrics + an alarm) rather than discovered on the bill.
- As an **on-call responder**, I want a documented **kill-switch** (tighten the limit / flip a deny
  flag / drop the Budgets threshold) to throttle an in-progress abuse event without a redeploy.

## 5. Requirements
### 5.1 Functional
- **FR-1 (default stage throttle).** The HTTP API's **default route settings** set a conservative
  account-protecting `ThrottlingBurstLimit` / `ThrottlingRateLimit` for **every** route (so an
  unconfigured route is never unlimited). Values are **stage-configurable** (per environment in
  `stage`/`config`). *(Verify via `cdk synth`.)*
- **FR-2 (tighter per-route throttle on expensive routes).** Per-route overrides set **lower** burst+
  rate on: `POST /v1/roadmaps/generate`, `POST /v1/exercises/grade`, `POST /v1/content/parse`,
  `POST /v1/activities/{id}/upload-url` (when `0040` ships), and `POST /v1/events`. The Bedrock routes
  get the lowest limits. Exceeding a route throttle returns API Gateway's native **429 Too Many
  Requests**. *(Verify the per-route `RouteSettings` in `cdk synth`.)*
- **FR-3 (per-user token bucket — RPM).** Each authenticated principal (`sub`) has a **requests-per-
  minute** budget. Over budget ⇒ **429** with `Retry-After`. Implemented as a token bucket
  (capacity = burst, refill = rate) over a DynamoDB counter (§6.3).
- **FR-4 (per-user expensive-op sub-budget).** A **separate, smaller** budget counts only **expensive
  ops** (generate / grade / parse / upload-url). This is the core DoW control: a caller may make many
  cheap reads but only **E** expensive calls per window. Over budget ⇒ **429** + `Retry-After`.
- **FR-5 (per-user daily cap).** A **per-day** ceiling per principal on expensive ops (TTL-bounded
  counter keyed by `…#<yyyy-mm-dd>`), independent of the per-minute buckets, to bound a slow-drip
  attack that stays under RPM. Over cap ⇒ **429** (or, where it overlaps the `0023` generation daily
  cap, the credits-style response) with `Retry-After` until the next UTC day.
- **FR-6 (per-IP token bucket).** For **unauthenticated** requests (the public `catalog`/`health`
  routes, and any pre-auth call) and as a second dimension on authenticated requests, a **per-source-IP**
  token bucket (keyed by `requestContext.http.sourceIp`, honoring `X-Forwarded-For` when behind
  CloudFront — §6.6) limits volumetric abuse from a single address. Over budget ⇒ **429** +
  `Retry-After`.
- **FR-7 (429 envelope + `Retry-After`).** Every limiter rejection returns **HTTP 429** with a
  `Retry-After` header (integer seconds) and a JSON body
  `{"error":"rate_limited","retryAfterSec":N,"scope":"<user_rpm|user_expensive|user_daily|ip>"}`. When
  rejection happens in the **authorizer**, the deny is surfaced as a 429 (§6.4 covers the
  authorizer-can't-set-status nuance and the chosen approach).
- **FR-8 (limiter is fail-open on its own errors, fail-closed on budget).** If the counter backend
  errors or times out, the limiter **fails open** (allows the request) and emits a metric — never a
  false 429 that blocks real users — *except* the stage/route throttle (FR-1/2) and credits (FR-11)
  remain as independent ceilings, and Budgets (FR-12) remains the backstop. A genuine over-budget is
  **fail-closed** (429).
- **FR-9 (credits remain the economic backstop for generation).** No change to `0023`'s atomic spend/
  402 on `generate`; this spec sequences the **limiter first** (a 429 before the credit decrement
  avoids burning credits on throttled calls) and documents the ordering (limiter → credits → Bedrock).
- **FR-10 (AWS Budgets DoW backstop).** A **monthly cost Budget** (with the **AWS Marketplace / Bedrock**
  billing dimension included — Cost **Anomaly Detection does not cover third-party Marketplace LLMs**,
  §12) at a configurable threshold, plus alert subscribers (email/SNS), per stage. *(Verify the
  `AWS::Budgets::Budget` in `cdk synth`.)*
- **FR-11 (Bedrock cost/usage alarm).** A CloudWatch **alarm** on a Bedrock spend/usage signal
  (estimated-charges metric and/or Bedrock `InvocationCount`/token metrics) that fires on an abnormal
  spike, wired to the same SNS topic as Budgets. (Detailed cost-metric plumbing is owned by `0032`;
  this spec adds the alarm + topic so the feature is self-contained.)
- **FR-12 (abuse observability).** Limiter rejections and route throttles emit **structured logs** and
  **CloudWatch metrics** (`RateLimited` by scope; API Gateway's `4XXError`/throttle metrics), with an
  **alarm** on a sustained 429 rate (signal of an attack or a misbehaving client). No PII beyond the
  `sub`/IP already present.
- **FR-13 (optional CloudFront + WAF for prod public routes).** In **prod only** and behind a config
  flag, a **CloudFront distribution** fronts `GET /v1/catalog[/{id}]` and `GET /health` with a **WAF
  Web ACL** containing a **rate-based rule** (per-IP) and **AWS managed rule groups** (e.g.
  Common/IP-reputation/Anonymous-IP). Origin is the HTTP API endpoint. *(Verify the
  `CloudFront::Distribution` + `WAFv2::WebACL (scope=CLOUDFRONT, us-east-1)` in `cdk synth`.)*
- **FR-14 (public-route hardening without WAF).** Independent of FR-13, `catalog`/`health` are covered
  by the per-IP token bucket (FR-6) and the route throttle (FR-1) so they are **never** unprotected,
  even where CloudFront is off (dev/beta).
- **FR-15 (kill-switch / runtime tunables).** Limit parameters (RPM, expensive-op budget, daily cap,
  per-IP budget) and a global **deny flag** are read from **stage config / SSM Parameter Store / env**
  so on-call can tighten limits or hard-deny a principal **without a code change** (redeploy or SSM
  update). (Aligns with the future `0035` remote-config; here a minimal env/SSM read suffices.)
- **FR-16 (contract sync).** `shared/api/openapi.yaml` gains a reusable **`429`** response +
  `RateLimited` schema referenced by the expensive + public routes; `DTOs.swift` mirrors it leniently;
  the iOS client maps `APIError.badStatus(429, body)` to a polite back-off (honor `Retry-After`).

### 5.2 Non-functional
- **NFR-1 (latency budget).** The token-bucket check adds **one** DynamoDB `UpdateItem` (single-digit
  ms) to each request; the authorizer adds one Lambda hop. **Authorizer result caching is disabled**
  for the limiter (so cached auth never skips the counter — §12), trading a small per-request cost for
  correct accounting. Target added p50 latency **< 15 ms**, p99 **< 60 ms**.
- **NFR-2 (float-free).** Counters, token balances, timestamps, TTLs are **integers** (e.g. token
  balance stored as **milli-tokens** ints if fractional refill is needed, or whole-token buckets with
  integer refill). No `float` reaches DynamoDB (`CLAUDE.md` invariant). Reads coerce `Decimal`→`int`.
- **NFR-3 (atomicity).** Counter mutation is a **single conditional/atomic `UpdateItem`** (`ADD` +
  conditional refill) so concurrent requests can't over-allow past the bucket (race-safe).
- **NFR-4 (TTL hygiene).** Every counter item has a **TTL** (`expiresAt` epoch-seconds) a small margin
  past its window so the table self-cleans; per-minute items expire in minutes, per-day items next day.
- **NFR-5 (least privilege).** The **authorizer Lambda** gets read/write on **only** the rate-counter
  key space (scoped `dynamodb:UpdateItem`/`GetItem` on the table, ideally constrained by a
  `LeadingKeys` condition to `RL#*` if feasible). **`grade_fn` still gets no table access** — its
  metering lives entirely in the authorizer, preserving that invariant. The Budgets/WAF/CloudFront
  resources add no Lambda permissions.
- **NFR-6 (offline-first preserved).** This is backend/infra only. First launch (Mock AI + bundled
  sample) makes **no** network call and is **completely unaffected**; limits apply only to the
  `RemoteAIService` backend path. The app must keep working offline (`CLAUDE.md`).
- **NFR-7 (no new third-party iOS deps; backend stdlib+boto3).** The limiter is pure stdlib + boto3
  (token-bucket math + `UpdateItem`). No Redis, no packaging step. iOS back-off uses `URLSession` only.
- **NFR-8 (cost of the control itself).** The counter writes are on the existing on-demand table
  (a few WCUs per request) and one extra Lambda invoke per request — **negligible** vs. a single
  Bedrock Opus call it prevents. CloudFront/WAF cost is prod-only and bounded.
- **NFR-9 (security & privacy).** Only `sub` and source IP are used as keys (both already present in
  the request context); no new PII. The deny path leaks no internal detail (generic `rate_limited`).
  The SSRF guard in `shared/http.py` is **retained unchanged** (this spec is additive).
- **NFR-10 (testability).** Token-bucket math is a **pure, unit-tested** function (mirrors the repo's
  preference for pure tested logic — `LevelCurve`/`StreakCalculator`). Counter behavior tested with
  **moto**; `cdk synth -c stage={dev,beta,prod}` validates throttle/Budgets/WAF wiring offline.

## 6. Design

### 6.1 Layered defense (overview)
```
                         (prod, optional)
        Internet ─▶ CloudFront + WAF Web ACL ─┐   ← FR-13: per-IP rate-based rule + managed groups
                    (public catalog/health)    │      (WAF can't bind to HTTP API ⇒ front w/ CFN)
                                               ▼
   all clients ─────────────────────────▶ API Gateway HTTP API (v2)
                                               │  FR-1/2: stage default + per-route throttle (429)
                                               ▼
                        ┌──────────────────────────────────────────┐
   secured routes ─────▶│ Lambda REQUEST authorizer (augments JWT)  │ FR-3/4/5/6: token bucket
                        │  • validate Cognito JWT (or delegate)     │   per-user RPM + expensive +
                        │  • DynamoDB atomic counter (TTL)          │   daily + per-IP  → allow/deny
                        └──────────────────────────────────────────┘
                                               │ allow
                                               ▼
                                         Lambda handler
                                               │  FR-9: credits.spend() (generate only, 0023) → 402
                                               ▼
                                       Bedrock / S3 / Firehose
                                               ▲
        AWS Budgets (Marketplace/Bedrock dim) ─┘  FR-10/11: spend circuit-breaker + alarm (0032)
```
**Why all four layers:** route throttle is **coarse + identity-blind** (protects the account, fast,
but a distributed/low-rate attacker slips under it); the token bucket is **identity-aware** (the real
per-user/IP cap, and the *expensive-op* sub-budget that counts cost-not-just-requests); credits are
the **economic** truth for generation; Budgets is the **last-resort** dollar ceiling that doesn't care
how the spend happened. No single layer is sufficient against DoW (§3, §12).

### 6.2 Stage- & route-level throttling (`api_stack.py`)
HTTP API v2 supports a **default** throttle for the stage and **per-route** overrides
(`ThrottlingBurstLimit` = bucket size / max concurrent before 429; `ThrottlingRateLimit` = steady
refill req/s — §12). In CDK these are set via the stage's `default_route_settings` and per-route
`RouteSettings` (or `add_routes(..., throttle=...)`/an L1 `CfnStage.route_settings` escape hatch). All
values come from `config` so each environment differs.

| Route | Default (all routes) | Override (this route) | Why |
|---|---|---|---|
| *every route* | burst **20**, rate **10/s** | — | account-protecting floor (FR-1) |
| `POST /v1/roadmaps/generate` | — | burst **2**, rate **0.2/s** (~12/min) | Opus generation; also credit-gated |
| `POST /v1/exercises/grade` | — | burst **3**, rate **0.5/s** | Bedrock per answer; **un-credited** |
| `POST /v1/content/parse` | — | burst **3**, rate **0.5/s** | outbound fetch + S3 write |
| `POST /v1/activities/{id}/upload-url` | — | burst **3**, rate **0.5/s** | unlocks Nova/Transcribe (`0040`) |
| `POST /v1/events` | — | burst **10**, rate **5/s** | cheap but loopable into Firehose |
| `GET /v1/catalog[/{id}]`, `GET /health` | (default) | burst **20**, rate **10/s** | public; also per-IP bucket + opt. WAF |

*(Numbers are starting points, tuned in review; all in `config` per stage. Default route settings
**cannot exceed account-level** limits — §12.)* These limits are **identity-blind** (API Gateway
throttles per-route in aggregate); the per-*user* enforcement is the token bucket (§6.3).

### 6.3 Token-bucket limiter (DynamoDB atomic counter, float-free)
**Item shape** (same single table; new key space, TTL’d):

| Purpose | PK | SK | Attributes (all int) |
|---|---|---|---|
| Per-user RPM bucket | `RL#USER#<sub>` | `RPM#<windowStartEpochMin>` | `count`, `expiresAt` |
| Per-user expensive bucket | `RL#USER#<sub>` | `EXP#<windowStartEpochMin>` | `count`, `expiresAt` |
| Per-user daily cap | `RL#USER#<sub>` | `DAY#<yyyy-mm-dd>` | `count`, `expiresAt` |
| Per-IP bucket | `RL#IP#<ip>` | `RPM#<windowStartEpochMin>` | `count`, `expiresAt` |

Two equivalent algorithms (D-2 picks one):
- **(A) Fixed/rolling-window counter (recommended, simplest, float-free).** Key the item by the
  current window (`epoch // windowSec`). One **atomic** `UpdateItem` does `ADD count :one` with a
  **`ConditionExpression` `count < :limit`** (and `attribute_not_exists` bootstraps the item +
  `expiresAt`). On the conditional-check failure ⇒ **over budget** ⇒ compute `Retry-After =
  secondsUntilNextWindow` ⇒ deny. TTL = window end + small margin. No floats anywhere.
- **(B) True token bucket (smoother).** Store `tokensMilli:int` (milli-tokens) + `lastRefillEpochMs`.
  On each request: `refill = floor((now-last) * ratePerMs)`, `tokens = min(cap, tokens+refill) - cost`,
  conditional-write back if `tokens >= 0`. Fractional refill handled in **integer milli-tokens** (no
  float persisted). More accurate burst behavior; slightly more logic.

**Pure function (`shared/ratelimit.py`), unit-tested in isolation:**
```python
# Pure: no AWS. Decides allow/deny + retry-after from current counter state and config.
def decide(count: int, limit: int, window_sec: int, now_epoch: int) -> Decision:
    """Window-counter variant. Returns (allowed, retry_after_sec, new_count)."""
    if count >= limit:
        retry = window_sec - (now_epoch % window_sec)
        return Decision(allowed=False, retry_after_sec=retry, new_count=count)
    return Decision(allowed=True, retry_after_sec=0, new_count=count + 1)
```
The DynamoDB wrapper performs the **atomic** conditional `UpdateItem` (the real race-safe gate; the
pure `decide` is what tests exercise and what the wrapper mirrors). Expensive ops consume from **both**
the RPM bucket **and** the EXP bucket **and** the DAY cap (deny if *any* is exhausted; the *tightest*
`Retry-After` wins). Cheap ops consume from RPM (+ per-IP) only.

**Default budgets (config, per stage — starting points):**

| Budget | Window | Default limit | Notes |
|---|---|---|---|
| User RPM | 60 s | **60 req/min** | generous for a reading session |
| User expensive ops | 60 s | **6 / min** | generate+grade+parse+upload combined |
| User daily expensive | 1 day (UTC) | **40 / day** | overlaps `0023`'s 5/day generation cap; daily cap here is the *all-expensive* ceiling |
| Per-IP RPM | 60 s | **120 req/min** | NAT-friendly; tighter at the WAF edge in prod |

### 6.4 Where the limiter runs — Lambda authorizer (recommended) vs. handler counter
**Chosen mechanism: a Lambda `REQUEST` authorizer that augments the Cognito JWT authorizer and
enforces the token bucket, denying over-budget callers.** Rationale and the nuance:
- HTTP API v2 lets a route use **one** authorizer. To both validate the JWT **and** rate-limit, the
  cleanest design is a **single custom `REQUEST` (Lambda) authorizer** that (a) **verifies the Cognito
  JWT** itself (validate `iss`/`aud`/`exp` against the user-pool JWKS — cached in the Lambda) and (b)
  runs the token-bucket check, returning **`{"isAuthorized": false}`** when over budget. **Authorizer
  result caching is disabled** (`results_cache_ttl = 0`) so every request hits the counter (a cached
  *allow* would let a flood through — §12).
- **The 429 nuance.** A simple-response Lambda authorizer can only return **allow/deny**; a *deny*
  becomes API Gateway's **403** (not 429). To return a **true 429 + `Retry-After`** we use one of
  (D-1):
  - **(D-1a) Authorizer denies → 403, mapped to 429 by a gateway response.** Configure the API's
    `gateway response` so an authorizer denial returns status **429** with a `Retry-After`/body. The
    authorizer passes the computed `retryAfterSec`/scope via **`context`** and a response-mapping
    template surfaces them. *(Requires HTTP-API gateway-response/header-mapping support; verify in
    synth.)*
  - **(D-1b) Authorizer authorizes everything; the per-user budget is enforced in a tiny shared
    pre-handler that returns a real 429.** The authorizer still validates the JWT (or we keep the
    native JWT authorizer) and writes the counter decision into `requestContext.authorizer` context;
    a one-line guard at the top of each expensive handler (`ratelimit.enforce(event)`) returns
    `too_many_requests(...)` (a genuine 429 + header) when the context says "deny". This keeps full
    control of the status/headers in handler code (where `0023` already returns 402) at the cost of a
    per-handler call.
  - **Recommendation: (D-1b)** for correctness and simplicity of the **429 + `Retry-After`** contract
    (handlers already own status codes; mirrors `0023`'s 402-in-handler pattern), with the
    **authorizer doing the counting/decision** (so even *unrouted-to-handler* abuse and the per-IP
    pre-auth case are still counted). The authorizer remains the single place that *decides*; the
    handler guard is the single place that *renders* the 429. For the **public** routes (no
    authorizer), the per-IP check runs as the same `ratelimit.enforce(event)` guard at the top of
    `catalog`/`health` (cheap; fail-open on counter error).
- **Alternative considered: pure handler-side DynamoDB counter, no custom authorizer.** Simpler (no
  JWT re-validation, keep the native `HttpUserPoolAuthorizer`), but it can't gate **pre-handler** (the
  request already reached a billed Lambda invocation) and duplicates the counter call across handlers.
  We still use a handler guard in (D-1b) — but pairing it with the authorizer means the *decision* is
  centralized and the JWT is validated before any handler runs. (If the team prefers minimal moving
  parts for v1, a **handler-only** counter with the native JWT authorizer is an acceptable **Phase 1**,
  adding the custom authorizer in **Phase 2** — see §9/§11.)

### 6.5 `shared/response.py` addition (429 helper)
Mirror the existing helpers; set the `Retry-After` header explicitly (CORS headers preserved):
```python
def too_many_requests(retry_after_sec: int, scope: str) -> dict:
    headers = {**CORS_HEADERS, "Retry-After": str(int(retry_after_sec))}
    body = {"error": "rate_limited", "retryAfterSec": int(retry_after_sec), "scope": scope}
    return {"statusCode": 429, "headers": headers, "body": json.dumps(body)}
```
`enforce(event)` (in `shared/ratelimit.py`) resolves `uid` (reusing `response.user_id`’s logic, but
**non-raising** for the per-IP-only public case) + `sourceIp`, runs the atomic counters, and either
returns `None` (allowed) or a ready `too_many_requests(...)` dict the handler returns immediately.

### 6.6 Source-IP resolution (CloudFront-aware)
`requestContext.http.sourceIp` is the immediate client IP. When **CloudFront** fronts the route
(prod, FR-13), the origin sees CloudFront IPs, so the **real** client is the **left-most** trustworthy
entry of `X-Forwarded-For` (CloudFront appends it). The limiter reads XFF **only when the request is
known to come through our CloudFront** (a shared secret header injected by the distribution, or
restricting the origin to CloudFront via a custom header) — otherwise XFF is **spoofable** and ignored.
Documented as a security note; default (no CloudFront) uses `sourceIp` directly.

### 6.7 AWS Budgets + Bedrock cost alarm (FR-10/11)
- **`AWS::Budgets::Budget`** (cost type), per stage, with **`CostFilters`** including the **AWS
  Marketplace** billing entity (so **third-party Bedrock model charges are captured** — Cost Anomaly
  Detection alone does **not** monitor Marketplace LLMs, §12), at a configurable monthly `amount` with
  notification thresholds (e.g. 50/80/100% actual + a forecasted-overage alert) → an **SNS topic**
  (email subscribers from config). This is the **dollar circuit-breaker**.
- **CloudWatch alarm** on Bedrock spend/usage: at minimum an alarm on the AWS/Billing
  `EstimatedCharges` metric scoped to the service, and (when `0032`’s per-invocation token/cost metric
  lands) an alarm on a sudden Bedrock `InvocationCount`/token spike. Same SNS topic.
- **Optional automated response (D-5):** an SNS→Lambda subscriber that, on the high-threshold alert,
  **tightens the SSM-stored limits** (or flips the deny flag, FR-15) to choke spend until a human
  intervenes — a true *circuit breaker*. v1 may ship **alert-only** and add auto-throttle later.
- The deep cost-metric/dashboard build is **owned by `0032`**; this spec ships the Budget + topic +
  one alarm so G1 is self-contained.

### 6.8 Optional CloudFront + WAF for prod public routes (FR-13)
- **Scope:** prod only, behind `config["edge"]["cloudfrontEnabled"]`. A **CloudFront distribution**
  with the HTTP API as a custom origin, a cache policy suited to the (cacheable) catalog, forwarding
  `GET /v1/catalog[/{id}]` and `GET /health`. (The authenticated API can keep hitting API Gateway
  directly; we do **not** route private, per-user traffic through a shared cache.)
- **WAF Web ACL** (`scope=CLOUDFRONT`, **must be created in us-east-1** — §12) associated to the
  distribution, with: a **rate-based rule** (e.g. block an IP exceeding N requests / 5-min on these
  paths), **AWS managed rule groups** (`AWSManagedRulesCommonRuleSet`,
  `AWSManagedRulesAmazonIpReputationList`, optionally `AnonymousIpList`), and a default **allow**.
- **Why here and not on the API:** **WAF cannot associate with an HTTP API v2** (§12). CloudFront is
  the supported attachment point that also gives us edge caching for the public catalog (a nice
  side-effect aligned with `0028`’s public-catalog caching) and absorbs volumetric floods before they
  reach Lambda. For **dev/beta**, the per-IP token bucket (FR-6) + route throttle (FR-1) provide the
  floor without the CloudFront cost.

### 6.9 API / contract (`shared/api/openapi.yaml`)
Add a reusable response + schema and reference it from the expensive + public routes:
```yaml
components:
  responses:
    RateLimited:
      description: Too many requests — slow down and retry after the indicated delay.
      headers:
        Retry-After:
          schema: { type: integer }
          description: Seconds to wait before retrying.
      content:
        application/json:
          schema: { $ref: "#/components/schemas/RateLimited" }
  schemas:
    RateLimited:
      type: object
      properties:
        error:        { type: string, example: rate_limited }
        retryAfterSec:{ type: integer, example: 12 }
        scope:
          type: string
          enum: [user_rpm, user_expensive, user_daily, ip]
# …and on each of: /v1/roadmaps/generate, /v1/exercises/grade, /v1/content/parse,
#    /v1/activities/{id}/upload-url, /v1/events, /v1/catalog, /v1/catalog/{id}, /health
        "429": { $ref: "#/components/responses/RateLimited" }
```
**openapi ⇄ DTO ⇄ client sync.** Add `RateLimitedDTO { error: String; retryAfterSec: Int; scope:
String }` to `DTOs.swift` (lenient decode, default `retryAfterSec` to a sensible fallback if absent).
No new request fields anywhere.

### 6.10 iOS handling (no limiter logic on-device; polite back-off only)
- `APIClient` already surfaces non-2xx as `APIError.badStatus(code, body)`. Add a small interceptor:
  on **429**, read the **`Retry-After`** response header (fallback to `retryAfterSec` in the body, then
  to an exponential-backoff-with-jitter default), and **retry once** after the delay for **idempotent
  GETs** (catalog); for user-initiated POSTs (generate/grade/parse/upload) surface a calm "You're going
  a little fast — try again in a moment" using `DesignSystem` tokens (no error red), never a crash.
- This is the **only** iOS change and it is small; the limiter is entirely server-side. Offline/Mock/
  Direct paths are untouched (no backend ⇒ no 429). *(Honor `Retry-After` first — §12.)*

### 6.11 CDK / infra summary (`api_stack.py` + new construct)
- **Throttle:** set `default_route_settings` (burst/rate from `config`) on the stage; add per-route
  overrides for the five expensive routes (CDK `add_routes(throttle=…)` or `CfnStage.route_settings`
  escape hatch). Validate in synth.
- **Authorizer (D-1b chosen):** add `RateLimitAuthorizerFn` (`handlers.ratelimit_authorizer.handler`)
  as an `HttpLambdaAuthorizer` (response-format simple, **cache disabled**) applied to the **secured**
  routes; it validates the JWT (JWKS cached) and writes the bucket decision into context. Grant it
  scoped `dynamodb:GetItem`/`UpdateItem` on the table (RL key space). Keep the existing
  `HttpUserPoolAuthorizer` only if we *don't* re-validate in the custom authorizer (D-1 records which).
- **Handler guards:** each expensive handler (and `catalog`/`health` for the IP case) calls
  `ratelimit.enforce(event)` first and returns its 429 if denied.
- **Budgets/alarm:** `AWS::Budgets::Budget` + SNS topic + CloudWatch alarm(s) (FR-10/11), per stage.
- **Edge (prod, optional):** CloudFront distribution + `WAFv2::WebACL` (CLOUDFRONT scope, us-east-1) +
  association, behind a config flag (FR-13).
- **TTL:** enable DynamoDB **TTL** on the table’s `expiresAt` attribute (coordinated with `0026`/`0032`;
  benefits leaked jobs too).
- **Least privilege preserved:** `grade_fn` gains **no** table access (its metering is in the
  authorizer). No wildcard `Resource:"*"` except where unavoidable (verify in synth).

## 7. Acceptance criteria
- [ ] **AC-1 (pure token-bucket math).** `shared/ratelimit.decide(...)` (and/or the milli-token bucket)
  allows up to `limit` within a window and denies the next, computing a correct `retryAfterSec`; pure,
  no AWS. *(unit: `test_ratelimit_decide`.)*
- [ ] **AC-2 (atomic counter race-safe).** Concurrent `UpdateItem`s on the same window key never allow
  past `limit` (conditional check holds); the `(limit+1)`-th call is denied. *(moto unit:
  `test_ratelimit_counter_atomic`.)*
- [ ] **AC-3 (429 + `Retry-After` envelope).** An over-budget request returns **HTTP 429**, a
  `Retry-After` integer-seconds header, and body `{"error":"rate_limited","retryAfterSec":N,"scope":…}`.
  *(unit: `test_ratelimit_429_response_shape`.)*
- [ ] **AC-4 (expensive-op sub-budget).** With RPM not exhausted but the **expensive** budget spent, an
  expensive op (e.g. `grade`) is **429**’d while a cheap op (`catalog`) still passes. *(unit:
  `test_expensive_budget_blocks_grade_allows_catalog`.)*
- [ ] **AC-5 (daily cap).** After the daily expensive cap, expensive ops 429 with a `Retry-After`
  pointing to the next UTC day; the per-minute buckets reset sooner but the day cap still blocks.
  *(unit: `test_daily_cap_blocks_until_next_day`.)*
- [ ] **AC-6 (per-IP bucket on public routes).** Unauthenticated `GET /v1/catalog` past the per-IP
  budget returns 429; a different IP is unaffected. *(unit: `test_ip_bucket_public_route`.)*
- [ ] **AC-7 (fail-open on backend error).** If the counter `UpdateItem` raises/times out, the request
  is **allowed** (not falsely 429’d) and a `RateLimitBackendError` metric/log is emitted; a genuine
  over-budget is still denied. *(unit: `test_ratelimit_fails_open_on_ddb_error`.)*
- [ ] **AC-8 (limiter precedes credits on generate).** A throttled `generate` returns **429 before**
  any credit decrement (no credits burned on a throttled call); within budget, `0023`’s spend/402 path
  is unchanged. *(unit: `test_generate_429_does_not_spend_credits`, monkeypatch `credits.spend` to fail
  if called.)*
- [ ] **AC-9 (grade stays table-less).** `grade_fn` has **no** table IAM; its rate metering is enforced
  by the authorizer/guard, not by giving it table access. *(`cdk synth` IAM inspection +
  `test_grade_fn_has_no_table_grant`.)*
- [ ] **AC-10 (stage + route throttle present).** `cdk synth -c stage=beta` shows default route
  settings and the lower per-route burst/rate on `generate`/`grade`/`parse`/`upload-url`/`events`.
  *(synth assertion `test_synth_route_throttles`.)*
- [ ] **AC-11 (Budgets + alarm present).** Synth shows an `AWS::Budgets::Budget` (with the Marketplace
  cost dimension), an SNS topic, and a Bedrock-cost CloudWatch alarm wired to it, per stage. *(synth
  assertion `test_synth_budget_and_alarm`.)*
- [ ] **AC-12 (CloudFront+WAF optional, prod-only).** With `cloudfrontEnabled=true` (prod), synth shows
  a CloudFront distribution fronting catalog/health and a `WAFv2::WebACL` (scope CLOUDFRONT, us-east-1)
  with a rate-based rule + managed groups associated to it; with it disabled (dev/beta) neither exists
  and the routes are still covered by the per-IP bucket + route throttle. *(synth assertion
  `test_synth_edge_waf_prod_only`.)*
- [ ] **AC-13 (abuse observability).** Limiter denials emit a `RateLimited{scope}` metric and a
  structured log; an alarm on sustained 429 rate exists. *(log/metric unit check + synth.)*
- [ ] **AC-14 (kill-switch).** Tightening the SSM/env limit (or flipping the deny flag) changes
  enforcement **without a code change**; a hard-deny principal is 429’d on every expensive op. *(unit:
  `test_killswitch_denies`, reading config/SSM stub.)*
- [ ] **AC-15 (contract sync).** `openapi.yaml` defines the reusable 429 response + `RateLimited`
  schema on the expensive + public routes; `DTOs.swift` mirrors it and decodes leniently; `cdk synth
  -c stage=beta` passes. *(openapi lint + DTO decode test + synth.)*
- [ ] **AC-16 (offline-first preserved).** Fresh install, Mock AI, no network/auth: first journey +
  activities run with **no** limiter calls and **no** 429. *(manual offline run.)*
- [ ] **AC-17 (iOS polite back-off).** A stubbed 429 with `Retry-After` causes an idempotent GET to
  retry once after the delay and a user POST to show a calm "slow down" message (not a crash/error
  red). *(iOS unit/UI check.)*

## 8. Test plan
**Backend — `pytest` (moto; Bedrock/Apple monkeypatched), new files under `backend/tests/`:**
- `test_ratelimit.py` — the pure math (`decide`, milli-token bucket): boundary at `limit`, refill,
  `retryAfterSec` correctness, integer-only (no float) — AC-1, AC-5.
- `test_ratelimit_counter.py` (moto) — atomic conditional `UpdateItem` allows/denies correctly under
  repeated calls; TTL `expiresAt` set; window rollover; fail-open on a simulated `ClientError` —
  AC-2, AC-7.
- `test_ratelimit_enforce.py` — `enforce(event)` returns `None` (allow) vs a 429 dict (deny) for the
  RPM/expensive/daily/IP scopes; the **429 shape + `Retry-After`** is exact — AC-3, AC-4, AC-6.
- `test_generate_ratelimit.py` — a throttled `generate` 429s **before** `credits.spend` (monkeypatched
  to raise if called) — AC-8; within budget the `0023` path is intact.
- `test_killswitch.py` — config/SSM stub flips limits/deny flag and enforcement follows — AC-14.
- **Synth assertions** (extend the existing synth test or `tests/test_api_stack_synth.py`): route/stage
  throttles (AC-10), Budgets + alarm + SNS (AC-11), CloudFront+WAF prod-only (AC-12), `grade_fn`
  table-less (AC-9), abuse alarm (AC-13). Run `cdk synth -c stage={dev,beta,prod}`.
- `test_contract.py` (extend) — the 429 response + `RateLimited` schema exist and a 429 body decodes
  (AC-15).
**iOS — `MangoTests` (XCTest):**
- `RateLimitBackoffTests.swift` — a stubbed 429 + `Retry-After` drives one retry for an idempotent GET
  and the calm message path for a POST; `RateLimitedDTO` decodes leniently — AC-17, AC-15.
**Manual / verified by hand:**
- Offline first-run unaffected (AC-16). A scripted burst against a dev deploy returns 429s with
  `Retry-After` and the CloudWatch `RateLimited` metric increments. (Optional) a prod CloudFront+WAF
  smoke: a rate-based-rule block on the public catalog.

## 9. Rollout & migration
- **Phase 0 (config + contract).** Land `config` keys (throttle numbers, budgets, limits, flags), the
  `openapi.yaml` 429 response/schema, `DTOs.swift` mirror, and the iOS back-off — all inert until
  enforcement turns on. No behavior change.
- **Phase 1 (cheap wins, no custom authorizer).** Enable **stage + per-route throttles** (FR-1/2),
  **AWS Budgets + Bedrock alarm** (FR-10/11), and the **handler-guard token bucket** (FR-3/4/5/6 via
  `ratelimit.enforce` in each expensive handler + `catalog`/`health`). This delivers the bulk of the
  DoW protection with minimal moving parts and the native JWT authorizer untouched. Ship to **dev →
  beta** first; watch the `RateLimited`/4XX metrics; tune limits.
- **Phase 2 (custom authorizer).** Add the `REQUEST` Lambda authorizer (validates JWT + centralizes the
  decision, **cache disabled**) so counting happens **before** any handler invocation and the per-IP
  pre-auth case is covered uniformly (D-1b). Flip secured routes to it behind a flag; verify parity
  with Phase 1, then make it the default.
- **Phase 3 (edge, prod).** Enable **CloudFront + WAF** for the public routes in **prod** (FR-13)
  behind `cloudfrontEnabled`; point the catalog/health DNS at the distribution; keep authenticated
  traffic on the API Gateway endpoint.
- **Backward compatibility.** Limits are tuned **generous** initially (alert-but-rarely-block), then
  tightened with data. The 429 path is additive (clients that ignore it just see an occasional error;
  the updated app backs off). **Teardown:** disabling enforcement is a config flip; counter items TTL
  away on their own.
- **Migration:** enabling table **TTL** is a one-time, non-destructive table setting (coordinate with
  `0026`/`0032`); no data migration. No iOS forced-update required (back-off is best-effort).

## 10. Risks & open decisions
- **Risk: false positives behind shared NAT/corporate IPs.** Per-IP limits could throttle many users
  behind one IP. *Mitigation:* per-IP limit is **generous** and is a **secondary** dimension; the
  **per-user** bucket is primary; tune with data; exempt nothing by default but allow an allow-list in
  config.
- **Risk: authorizer cost/latency + the disabled-cache trade-off.** Disabling authorizer caching means
  a Lambda + DDB write per request. *Mitigation:* the math is trivial, the counter is one `UpdateItem`,
  and Phase 1 (handler guard) avoids the extra authorizer hop entirely; revisit caching only if metrics
  demand it.
- **Risk: 429-from-authorizer requires a gateway-response/header mapping that HTTP API may constrain.**
  *Mitigation:* **D-1b** (handler renders the 429) sidesteps this; the authorizer only decides.
- **Risk: DoW via the *un-credited* grade/parse paths.** Credits only gate generation (`0023`).
  *Mitigation:* that is **exactly** why the expensive-op sub-budget (FR-4) + route throttle exist;
  consider extending credits to grade/upload later (cross-ref `0023` §2 non-goals).
- **Risk: Budgets/alarm latency.** Cost data can lag hours, so Budgets is a *backstop*, not real-time.
  *Mitigation:* the request-layer limits are the real-time control; Budgets catches what slips.
- **Risk: counter hot-partition.** A single abusive IP/user concentrates writes on one key.
  *Mitigation:* on-demand table absorbs it; the whole point is to *deny* that key quickly; window keys
  spread over time.
- **Decisions needed:**
  - **D-1 (429 surfacing).** **Recommend D-1b** — custom authorizer **decides**, handler **renders** the
    429 + `Retry-After` (clean contract; mirrors `0023`’s 402-in-handler). (Alt D-1a: authorizer-deny
    mapped to 429 via gateway response.)
  - **D-2 (algorithm).** **Recommend the window-counter (A)** for v1 (simplest, provably float-free);
    upgrade to the **milli-token bucket (B)** if smoother bursting is needed.
  - **D-3 (mechanism placement / phasing).** **Recommend Phase 1 handler-guard first, Phase 2 custom
    authorizer.** (Alt: ship the custom authorizer from day one.)
  - **D-4 (CloudFront+WAF scope).** **Recommend prod-only + optional** (public routes only). (Alt: also
    front beta; or skip WAF and rely solely on the per-IP bucket — weaker against distributed floods.)
  - **D-5 (auto-throttle on Budget alarm).** **Recommend alert-only for v1**, add the SNS→Lambda
    auto-tighten circuit-breaker in a follow-up.
  - **D-6 (Redis later?).** **Recommend no** — DynamoDB counters suffice at Mango scale; revisit only if
    p99 limiter latency becomes a problem (would deviate from stdlib+boto3/no-extra-infra).

## 11. Tasks & estimate
1. **(S)** Add `config`/SSM keys (throttle burst/rate per route, RPM/expensive/daily/IP limits, budget
   amount + subscribers, `cloudfrontEnabled`, deny flag) across `stage`/env. *(Phase 0.)*
2. **(S)** `shared/ratelimit.py`: pure `decide`/token-bucket math (+ unit tests) — float-free.
3. **(M)** `shared/ratelimit.py`: DynamoDB atomic counter wrapper (conditional `UpdateItem` + TTL),
   `enforce(event)` resolving `uid`+`sourceIp`, fail-open on backend error (+ moto tests).
4. **(S)** `shared/response.py`: `too_many_requests(retry_after_sec, scope)` helper (+ test).
5. **(S)** Wire `ratelimit.enforce(...)` guard into the expensive handlers (`generate`, `grade`,
   `content_parse`, `events`, and `upload_url` when `0040` lands) **before** `credits.spend`, and into
   `catalog`/`health` for the per-IP case. *(Phase 1.)*
6. **(M)** `api_stack.py`: stage `default_route_settings` + per-route throttle overrides (escape hatch
   if needed); synth assertions. *(Phase 1.)*
7. **(M)** Budgets: `AWS::Budgets::Budget` (Marketplace cost dimension) + SNS topic + Bedrock-cost
   CloudWatch alarm + the sustained-429 abuse alarm; synth assertions. *(Phase 1; coordinate cost
   metric with `0032`.)*
8. **(S)** Enable DynamoDB **TTL** on `expiresAt` (coordinate with `0026`/`0032`).
9. **(M)** `openapi.yaml` 429 response + `RateLimited` schema on the expensive + public routes; lint.
10. **(S)** `DTOs.swift` `RateLimitedDTO` (lenient) + decode test.
11. **(S)** iOS `APIClient` 429 back-off (honor `Retry-After`, one retry for idempotent GET, calm copy
    for POST) + `RateLimitBackoffTests`. *(Phase 0/1.)*
12. **(L)** `handlers/ratelimit_authorizer.py`: `REQUEST` Lambda authorizer (JWT validation via cached
    JWKS + bucket decision, **cache disabled**); wire as `HttpLambdaAuthorizer` on secured routes;
    least-privilege RL-scoped table grant; parity tests + synth. *(Phase 2.)*
13. **(L)** Edge (prod): CloudFront distribution fronting catalog/health + `WAFv2::WebACL`
    (CLOUDFRONT/us-east-1) rate-based rule + managed groups + association, behind `cloudfrontEnabled`;
    XFF-trust handling (§6.6); synth assertions. *(Phase 3.)*
14. **(S)** Optional SNS→Lambda **auto-throttle** circuit-breaker on the high Budget threshold (D-5).
    *(Follow-up.)*
15. **(S)** Update `docs/BACKEND.md`/`OPERATIONS.md` runbook: the kill-switch, tuning the limits, and
    reading the abuse metrics/alarms.

## 12. References
- AWS — *Throttle requests to your HTTP APIs for better throughput in API Gateway* (stage default +
  per-route `ThrottlingBurstLimit`/`ThrottlingRateLimit`, token-bucket model, 429 behavior):
  https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-throttling.html
- AWS — *Resources that you can protect with AWS WAF* (supported: CloudFront, **API Gateway REST API**,
  ALB, AppSync, Cognito, App Runner, Amplify, Verified Access — **HTTP API v2 not supported**; CLOUDFRONT
  Web ACLs must be created in us-east-1):
  https://docs.aws.amazon.com/waf/latest/developerguide/how-aws-waf-works-resources.html
- AWS Samples — *API Gateway rate limiting using a Lambda authorizer* (per-tenant token bucket in a
  Lambda authorizer; DynamoDB `UpdateItem` atomic increment + TTL; **disable authorizer result caching**
  so the counter is hit per request):
  https://github.com/aws-samples/api-gateway-websocket-saas-rate-limiting-using-aws-lambda-authorizer
- AWS Networking & Content Delivery Blog — *Securing PartyRock: protecting Amazon Bedrock endpoints
  using AWS WAF* (DoW/DDoS on Bedrock apps; **standard rate limiters count requests, not cost** — an
  attacker can stay under a request limit while triggering the most expensive paths):
  https://aws.amazon.com/blogs/networking-and-content-delivery/securing-partyrock-how-we-protect-amazon-bedrock-endpoints-using-aws-waf/
- AWS — *AWS Cost Anomaly Detection* / *AWS Budgets* (Anomaly Detection **does not** monitor third-party
  AWS Marketplace LLMs like Anthropic Claude on Bedrock — use **AWS Budgets** with the Marketplace
  billing dimension to alert on those charges; the denial-of-wallet cost backstop):
  https://aws.amazon.com/aws-cost-management/aws-cost-anomaly-detection/faqs/
- MDN / RFC — *429 Too Many Requests* + **`Retry-After`** (RFC 9110/6585; honor `Retry-After` first,
  else exponential backoff with jitter; the 429 + `Retry-After` contract this spec implements):
  https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Status/429
- Internal: `working/ARCHITECTURE_REVIEW.md` §3 (G1), §5 (sequencing); `working/0023-payments-and-credits.md`
  (credits economic backstop, 402 pattern, `response.py` idioms); `working/0032-observability-cost-reliability.md`
  (dashboards/alarms/cost metric — cross-ref); `working/0030-ai-safety-guardrails.md` (content safety —
  complementary); `working/0040-multimodal-activities.md` (`/v1/activities/{id}/upload-url`);
  `backend/mango_backend/api_stack.py`, `backend/src/shared/{response.py,http.py}`,
  `backend/src/handlers/{content_parse.py,grade_exercise.py,events.py,catalog.py}`.
