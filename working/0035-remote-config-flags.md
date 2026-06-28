# 0035 — Remote config & feature flags

- **Epic:** M14 · **Status:** Draft · **Owner:** unassigned · **Updated:** 2026-06-28
- **Reviewers:** Principal / SD / QA

> Expands review gap **G11** in `working/ARCHITECTURE_REVIEW.md` §3 ("No feature flags / remote config —
> server kill-switch / dark-launch"). Today Mango's only feature gating is **compile-time local flags**
> (`activityFirstEnabled` in `0008`, `AppSettings` booleans, the `aiMode`/`apiEnvironment` switches) — there
> is **no server-driven way to kill a feature, stage a rollout, or tune a numeric threshold without an App
> Store release.** Several drafted specs already assume one exists: `0031` wants its age-band `POLICY`
> thresholds remote-tunable; `0042`/`0043` gate **risky** external/peer features behind flags; `0023`/`0024`
> gate monetization; `0008` ships behind `activityFirstEnabled`. This spec builds that substrate **once** and
> makes the existing local flags migrate onto it.

## 1. Summary
Build **server-driven remote configuration + feature flags + kill-switches** for Mango: a small, cacheable
**`GET /v1/config`** endpoint that returns a typed, versioned document of **boolean flags** (feature on/off,
staged-rollout, kill-switch) and **numeric/string params** (e.g. age-band thresholds surfaced to the client,
rate limits surfaced for UX, rollout percentages, retry windows), backed by **DynamoDB** `CONFIG#<env>` items
edited through the admin console (`0034`). The endpoint is **partly public** — a pre-auth slice (`scope=public`)
serves flags the app needs **before sign-in** (e.g. `catalogEnabled`, `signInRequired`, kill-switches for
first-run-visible surfaces), and an **authed slice** layers **per-user targeting** (staged rollout by a stable
hash of the Cognito `sub`, age band, or named cohort) so a feature can be dark-launched to 5% → 50% → 100% or
to internal testers only. An **iOS `RemoteConfig` service** fetches the document at launch (and on a throttled
schedule), **caches the last-known-good document on disk**, and exposes typed accessors backed by **safe local
defaults compiled into the app** — so the app works **fully offline / on fetch failure**, preserving the
offline-first invariant. The load-bearing safety rule: **kill-switches fail closed** — a flag that *disables* a
risky feature, when config is unreachable, resolves to **disabled** (the safe state), while ordinary
feature/UX flags **fail open** to their baked default (the app keeps working). The contract is explicit that
**flags are not a security boundary**: the server still independently enforces every gated action (the
`require(...)`/authorizer checks in `0031`/`0023`/`0042`/`0043` are the real gate; the flag only decides
*visibility* and *rollout*). All repo invariants hold (offline-first first-run, zero third-party iOS deps,
Lambda stdlib+boto3, float-free DDB, `openapi.yaml` ⇄ `DTOs.swift` ⇄ handlers in lockstep, single-table DDB,
least-privilege IAM).

## 2. Goals / Non-goals
- **Goals:**
  - A **`GET /v1/config`** endpoint returning a **typed, versioned** config document: a `flags` map (booleans),
    a `params` map (ints / strings — **no floats**, see NFR-6), a `rollouts` map (named rollout specs), plus
    `version`, `etag`, and `ttlSeconds`. **Cacheable** (CDN + client) and cheap (no Bedrock, tiny payload).
  - **Two scopes in one endpoint:** a **`public`** slice callable **before sign-in** (returns only
    pre-auth-safe flags; no per-user targeting), and an **authed** slice that adds **per-user evaluation** —
    staged-rollout bucketing and cohort/age-band targeting keyed off the caller's `sub`.
  - **DynamoDB-backed config** as `CONFIG#<env>` items in the existing single table, **edited via the admin
    console (`0034`)** — a tiny, auditable write path; **no app release** needed to flip a flag or tune a param.
    (AWS AppConfig is evaluated as the alternative and documented as the upgrade path — §10 D-1.)
  - An **iOS `RemoteConfig` service** with **safe local defaults compiled in**, **disk-cached last-known-good**,
    launch + throttled refresh, and **typed accessors** (`bool(_:)`, `int(_:)`, `string(_:)`, `isEnabled(_:)`)
    so call sites read flags in one line and **never crash / never block** on the network.
  - **Staged rollout + per-user targeting:** consistent **deterministic bucketing** (a stable hash of
    `sub`+flagKey → 0–9999 basis points compared against a rollout percentage), **named cohorts** (e.g.
    `internal`, `beta_testers`), and **age-band** targeting (consume `0031`'s band) — same algorithm twinned on
    client and server so a stale client and the server agree.
  - **Kill-switches that fail safe:** a flag marked as a **kill-switch for a risky feature** resolves to its
    **safe (disabled) state** when the config is missing/unreachable/stale — even though most flags fail open.
  - A clean **migration** for the existing **local** flags (`activityFirstEnabled` and friends): each becomes a
    remote flag with the **current compile-time value as its safe default**, so behavior is identical on day one
    and the flag becomes server-tunable thereafter.
  - **Make it the substrate other specs call:** publish the **typed accessor** + the **`config.evaluate(...)`**
    server helper so `0031` (tunable `POLICY`), `0042`/`0043` (gate risky features), `0023`/`0024` (gate
    monetization), `0008` (`activityFirstEnabled`) each consume it instead of inventing their own flag plumbing.
  - **Observability:** the served `version`/`etag` is logged (per request) and the **resolved config version**
    is attached to analytics events (`0015`) so a flip can be correlated with metric changes (feeds `0012`-style
    experimentation — the G12 fold).
  - Honor invariants: **offline-first first launch is unaffected** (baked defaults make the app fully functional
    with zero config calls); zero iOS deps; stdlib+boto3; **float-free**; contract lockstep; least-privilege IAM.
- **Non-goals:**
  - **A full experimentation/A-B platform** (assignment logging, metric pipelines, stats). This spec provides the
    **mechanism** (deterministic bucketing + version-on-events) that `0012`/`0020` (G12) build experiments on; it
    does **not** compute experiment results or own a metrics dashboard.
  - **A flag-authoring UI.** Editing/auditing config is the **admin console's** job (`0034`); this spec defines
    the **item shape + a validated write path + an audit trail** the console drives, not its screens.
  - **Treating flags as a security/authorization boundary.** Flags decide *visibility* and *rollout*; **the
    server still independently enforces** every gated action (NFR-2). A jailbroken client flipping a cached flag
    must still hit the server's `require(...)`/authorizer and get a 403 — exactly as `0031` §NFR-1 already
    specifies. This spec **must not** become the place auth decisions live.
  - **Real-time push of config changes** (websocket/SSE). v1 is **pull + TTL** (poll on launch/foreground +
    short server TTL); near-real-time propagation is a documented future option (§10 R-3), not built.
  - **Per-device / per-OS targeting, geo-targeting, time-windowed flags.** v1 targets by **rollout %**, **cohort**,
    and **age band** only; richer targeting is additive future work (§10 R-4).
  - **Remote *code* / remote feature *delivery***. We toggle and tune **already-shipped** code paths; we never
    download executable logic (App Store rule + safety).
  - **Re-implementing** `0031`/`0023`/`0042`/`0043`/`0008` — this spec defines the **flag substrate they call**;
    each consuming spec wires its own gate/threshold onto it.

## 3. Background & context
**Why now.** Mango is about to ship features that **must** be killable and gradually rollable from the server:
- **`0042`/`0043`** add *risky* surfaces (public social posting, external content fetch, human↔human sessions).
  Their own specs call for **flag-gating** so a misbehaving verifier, a moderation gap, or a cost spike can be
  **disabled in seconds without an App Store release** — the canonical kill-switch use case.
- **`0023`/`0024`** add **monetization** (StoreKit credits, redeemable rewards). These must be **gateable per
  environment / per rollout** and instantly disable-able if pricing, fraud, or a StoreKit issue appears.
- **`0031`** (age assurance / COPPA) explicitly wants its **age-band `POLICY` thresholds** *server-tunable* so
  counsel can tighten (e.g. flip teen IAP) **without an app release** (`0031` §6.3, §9 — *"`POLICY` thresholds
  are overridable via `0035` remote config"*). That is a **numeric/threshold remote-config** need, not just on/off.
- **`0008`** ships the activity-first reframe behind **`activityFirstEnabled`** and recommends *"ship behind the
  flag for one release, then delete the flag"* — a **staged-rollout + safe-removal** workflow this spec
  standardizes.

**Current state (verified by reading the code).**
- **All gating today is compile-time + local.** `ios/Mango/Services/Persistence/AppSettings.swift` (verified)
  holds `@Observable` booleans/enums persisted in `UserDefaults` — `apiEnvironment` (Mock/Personal/Beta/Prod),
  `useDirectClaudeWhenOffline`, `reminderEnabled`, `themePreference` — and computed helpers
  (`effectiveBackendURL`, `isRealBackend`). `0008`'s `activityFirstEnabled` is planned to live here too. There is
  **no fetch of any server-side config**; nothing can be changed without rebuilding the app.
- **The networking client is a thin JSON `URLSession` wrapper.** `ios/Mango/Services/Networking/APIClient.swift`
  (verified) sends `x-mango-user` + optional `Authorization: Bearer <idToken>`, `getJSON`/`postJSON`/`delete`,
  60 s timeout, typed `APIError` (`.notConfigured` when offline). `AppModel.apiClient()` returns `nil` when
  offline (Mock) so callers degrade gracefully — the exact pattern the `RemoteConfig` service will reuse (a
  `nil` client ⇒ fall back to cache/defaults).
- **There is already a public, unauthenticated GET pattern to copy.** `backend/src/handlers/catalog.py`
  (verified) serves `GET /v1/catalog[/{id}]` **with no auth** (`route(..., secured=False)` in
  `api_stack.py`) — *"the catalog is static, non-sensitive data so a first-run app can browse before sign-in."*
  `GET /v1/config`'s **public slice** is the same shape (public, cacheable, thin handler over a shared data
  module). The **authed slice** adds per-user evaluation behind the Cognito authorizer.
- **`response.user_id(event)`** (verified) resolves the caller from Cognito JWT claims and **only** trusts the
  `x-mango-user` header outside `prod`/`beta` — so the authed `/config` evaluation can key targeting off a
  trusted `sub` in deployed stages.
- **`response.ok(body)`** (verified, `shared/response.py`) returns `200` with a fixed `CORS_HEADERS` map and
  **no `Cache-Control`**. Serving a cacheable config (CDN/client) needs `ok()`/a new helper to **set
  `Cache-Control`** (the same small extension `0028` calls for) — §6.5.
- **The data + compose layers are ready for one more item type and (optionally) one construct.**
  `data_stack.py` (verified) is a single table (`PK`/`SK` + `GSI1`, on-demand, PITR/RETAIN in prod); a
  `CONFIG#<env>` item slots in with **no new table**. `stage.py` (verified) composes Data/Auth/Ai/Analytics →
  `ApiStack`; adding a config item needs **no** new stack (DDB), and the AppConfig alternative would add one
  small construct (documented, not chosen — §10 D-1).
- **Float-free is enforced** (`progress.py` coerces `Decimal`→`int`; `generate_roadmap.py` stores JSON strings).
  Config **params are `int`/`str` only**; any "percentage" is an **int basis-points / whole-percent**, never a
  float (NFR-6).

**The research (June 2026 — cited in §12).**
- **Mobile flag best practices** converge on: *fetch at startup (and periodically), cache the last-known-good
  config locally, and code defensively with a per-flag **safe default** so an offline phone or an unreachable
  flag service still returns usable values and the UI doesn't break.* Consistent **user bucketing** uses a
  **stable hash of a unique id** (user id) so the same user always lands in the same group across launches.
- **Kill-switches** are *"inverted feature flags that gracefully disable parts of a system with known weak
  spots"* and *"the fastest incident resolution is flipping the feature off"* — but the app **must not depend on
  the flag service's availability**, hence baked defaults + caching.
- **Fail-open vs fail-closed** is a deliberate per-flag choice: *fail-closed stops/prevents operation on
  failure; fail-open proceeds as normal.* The right mode *depends on what breaks worse — downtime or unprotected
  access*: a CDN fails open to keep loading; a payment gateway fails closed. **Applied here:** UX/feature flags
  **fail open** (keep the app working with the baked default), **risky-feature kill-switches fail closed**
  (stay disabled when config is unreachable). And flags **should not be a security boundary** — the server
  enforces (NFR-2).
- **AWS AppConfig vs DynamoDB.** AppConfig is *purpose-built* for flags: **schema validation before deploy**,
  **CloudWatch-alarm auto-rollback**, and **deployment strategies (gradual rollout / bake time)** that limit
  blast radius — features DynamoDB lacks. **But** for **mobile**, AWS itself recommends **a Lambda proxy in
  front of AppConfig** (the app does **not** call AppConfig directly — it *"decouples call volume from user-base
  size and reduces cost"*) and the **client must still cache locally with safe defaults**. So **either way the
  app talks to our own `GET /v1/config`** Lambda. Given Mango already has (a) the single-table + thin-Lambda +
  public-GET pattern, (b) an admin console (`0034`) that **edits DDB items**, and (c) the
  **stdlib+boto3-only / no-packaging** invariant, a **homegrown DynamoDB-backed `/config`** is the lower-risk,
  lower-moving-parts v1; **AppConfig becomes the documented upgrade** when we want managed staged-deploys +
  auto-rollback (§10 D-1).

**Related specs.** Provides the substrate consumed by **`0031`** (tunable age `POLICY`/thresholds; targeting by
band), **`0042`/`0043`** (kill-switches for risky external/peer features; rollout), **`0023`/`0024`** (gate
monetization per env/rollout), **`0008`** (`activityFirstEnabled` staged rollout + clean removal). Reuses the
**public-GET** + **least-privilege** patterns from **`0009`**/catalog and the **`Cache-Control`** extension from
**`0028`**. Edited/audited by **`0034`** (admin console — the flag write path). Consumes **`0019`** (sign-in —
the authed slice keys targeting off `sub`; pre-auth flags work without it) and **`0031`** (age band as a
targeting input). Emits the resolved `configVersion` into **`0015`** analytics; the deterministic bucketing it
provides is the seam **`0012`/`0020`** (G12) build A/B on. Swept by **`0033`** only insofar as no per-user PII is
stored (none is — config is per-environment, evaluation is stateless).

## 4. User stories
- As an **operator/on-call**, when `0042`'s external-content verifier starts producing bad results (or a cost
  spike fires), I **flip `externalEngagementEnabled` off in the admin console** and within the client's TTL
  every app **hides the feature and the server refuses it** — **no App Store release, no redeploy**.
- As a **release manager**, I **dark-launch** `0008`'s activity-first UI to **5% of users**, watch the metrics,
  then ramp **5 → 25 → 100%** by editing one rollout number — and the **same users** stay in the treatment each
  launch (consistent bucketing), so the experience isn't flickering.
- As **Legal/Compliance via `0031`**, I tighten a teen monetization threshold (e.g. flip `iap_purchase` for
  teens, or lower a daily cap) by **editing a `param`**, and it takes effect server-side **without shipping an
  app** — because the age `POLICY` reads remote config with the in-code values as safe defaults.
- As an **internal tester**, I'm in the **`internal` cohort**, so flags targeted to `internal` are on for me and
  off for everyone else — letting the team try an unreleased surface in the production app.
- As a **user on a plane (offline)**, the app **opens and works** entirely on **baked defaults + the cached
  config from my last online launch**; nothing blocks on the network, and the **first sample lesson with Mock
  AI is unchanged** — remote config never gates the offline first-run.
- As a **user whose config fetch fails** mid-session, the app keeps using the **last-known-good cached config**;
  if a **risky feature's kill-switch** can't be confirmed, that feature **stays off** (fail-closed) — I never get
  a half-working risky surface — while ordinary features keep their last value.
- As a **security reviewer**, I confirm that a **jailbroken client flipping a cached flag** still gets a **403**
  from every gated endpoint, because the **server re-evaluates and enforces** independently — the flag is *not*
  the boundary.
- As a **product analyst**, every analytics event carries the **`configVersion`** that was active, so when a
  metric moves I can tell **which config flip** it followed.

## 5. Requirements

### 5.1 Functional
- **FR-1 (`GET /v1/config` document).** Add **`GET /v1/config`** returning a typed JSON document:
  ```jsonc
  { "version": 42, "etag": "v42-<hash>", "ttlSeconds": 300,
    "flags":  { "activityFirstEnabled": true, "externalEngagementEnabled": false, "creditsEnabled": true, … },
    "params": { "ageGatePolicyVersion": 3, "externalDailyCap": 5, "rateLimitPerMin": 60, … },
    "rollouts": { "activityFirstEnabled": { "percent": 25, "cohorts": ["internal"], "bands": ["adult","teen"] } } }
  ```
  `flags` are **booleans**, `params` are **ints or strings** (NFR-6), `rollouts` are named specs (FR-5).
- **FR-2 (two scopes: public pre-auth + authed per-user).** `GET /v1/config` is **callable without auth**
  (mirrors `catalog`, `secured=False`) and returns the **public slice** — only flags marked `scope:"public"`,
  with rollouts evaluated **without** a user (a public flag is on iff its rollout has **no** user-only
  conditions and its `percent` ≥ 100, else off; public flags are intended to be simple env-level toggles /
  kill-switches for first-run-visible surfaces). When a **valid `Authorization` bearer** is present, the handler
  resolves `uid = user_id(event)` and returns the **authed slice**: the public flags **plus** non-public flags,
  **each evaluated for that user** (rollout %, cohort, age band — FR-5). The response indicates which scope was
  served (`scope: "public" | "user"`).
- **FR-3 (DynamoDB-backed, env-scoped, admin-edited).** The document is assembled from **`CONFIG#<env>` items**
  in the single table (§6.3): a `CONFIG#<env> / DOC` item holding the flag/param/rollout definitions (+ `version`,
  `updatedAt`, `updatedBy`). Writes happen **only** through the admin path (`0034`) using a **validated**
  mutation (schema-checked: flag values boolean, params int/str, percents 0–100, referenced cohorts known) that
  **bumps `version`** and appends an **audit record** (`CONFIG#<env> / AUDIT#<ts>` — who/what/old→new). The
  config Lambda is **read-only** on the table.
- **FR-4 (typed, versioned, cacheable).** The response carries `version` + `etag` + `ttlSeconds`; the handler
  sets **`Cache-Control: public, max-age=<ttl>`** on the **public** slice (CDN-cacheable) and
  **`Cache-Control: private, max-age=<ttl>`** on the **authed** slice (per-user, not shared-cacheable), and
  supports **`ETag`/`If-None-Match`** → **304** when unchanged (cheap polling). (Needs the `response` cache
  extension, §6.5.)
- **FR-5 (staged rollout + targeting — deterministic).** For each flag a `rollout` may specify any of:
  **`percent`** (0–100; the flag is on if the user's bucket < percent), **`cohorts`** (on if the user is in any
  listed cohort), **`bands`** (on if the user's `0031` age band is listed). **Bucketing is deterministic and
  stable:** `bucket(sub, flagKey) = (sha256("<sub>:<flagKey>") → first 4 bytes → uint) % 10000` (basis points);
  on iff `bucket < percent*100`. The **same algorithm is twinned** in Swift and Python (§6.2) so the client's
  optimistic local evaluation and the server's evaluation agree. Absent a user (public slice), only env-level
  flags resolve true; user-conditioned flags resolve **false** in the public slice (fail-closed to "not in
  rollout").
- **FR-6 (iOS `RemoteConfig` service — fetch, cache, typed access).** Add `RemoteConfig` (`@Observable`, in
  `AppModel`): on launch (and on foreground, **throttled** to ≥ `ttlSeconds`) it calls `GET /v1/config` via the
  resolved `APIClient` (authed when signed in, public when not / offline-capable), **persists the document to
  disk** (last-known-good) and exposes typed accessors: `isEnabled(_ key:) -> Bool`, `int(_ key:, default:)`,
  `string(_ key:, default:)`. Resolution order per key: **fresh fetch → disk cache → baked default**. The service
  **never blocks UI** and **never throws to callers** (accessors always return a value).
- **FR-7 (safe local defaults compiled in).** A **`ConfigDefaults`** table compiled into the app gives **every
  known key** a default value **and** a **`failClosed: Bool`** marker. When no fetched/cached value exists, an
  accessor returns the baked default; for a `failClosed` (kill-switch) key the baked default is the **safe
  (disabled) state** (FR-9). New keys added server-side that the app doesn't know are simply **ignored** (forward-
  compatible); keys the app knows but the server omits fall back to the baked default.
- **FR-8 (flags fail open; app keeps working).** For ordinary feature/UX flags and params, an unreachable/stale
  config resolves to the **baked default** (the value shipped in the binary) so the app is **fully functional
  offline** — *fail open* to the known-good behavior. This is the **default** mode for any key **not** marked
  `failClosed`.
- **FR-9 (kill-switches fail closed — the load-bearing safety rule).** A flag whose **purpose is to disable a
  risky feature** (e.g. `externalEngagementEnabled`, `peerSessionsEnabled`, `creditsEnabled`,
  `rewardsRedeemEnabled`) is marked **`failClosed`** with baked default **`false`** *for the risky-on
  interpretation*. **When config is missing/unreachable/stale, the feature resolves to DISABLED** — i.e. the
  client hides it and treats it as off — **regardless** of any cached "on". (Concretely: a `failClosed` key only
  resolves **enabled** when a **fresh-or-cached fetch explicitly says enabled**; otherwise it's off.) This means
  a launch during a config outage **cannot** silently leave a risky feature on. The **server still enforces**
  the same disablement independently (NFR-2), so even a stale-cached "on" client is refused.
- **FR-10 (migrate existing local flags).** Replace the compile-time local flags with remote flags **without
  behavior change on day one**: `activityFirstEnabled` (`0008`) and any other `AppSettings`/compile flags become
  keys in `ConfigDefaults` with their **current value as the baked default**, read via `RemoteConfig.isEnabled`.
  Per-environment device switches that are **operational, not feature** (`apiEnvironment`,
  `useDirectClaudeWhenOffline`, `themePreference`, `reminderEnabled`) **stay in `AppSettings`** (they're local
  user/dev choices, not server-driven) — §6.6 draws the line. `0008`'s "ship behind flag for one release, then
  delete" becomes: ship with remote default off → ramp rollout → set default on → later remove the key.
- **FR-11 (substrate for other specs).** Publish the server helper **`config.evaluate(uid, key) -> bool`** /
  **`config.param(key, default)`** and the iOS accessors as the **single** way these specs consult flags:
  `0031` reads its `POLICY` thresholds via `config.param(...)` (in-code values as defaults) and may target by
  band; `0042`/`0043` gate their risky surfaces with `config.evaluate(uid, "externalEngagementEnabled")` /
  `"peerSessionsEnabled"` (server) + `RemoteConfig.isEnabled(...)` (client hide); `0023`/`0024` gate with
  `"creditsEnabled"`/`"rewardsRedeemEnabled"`; `0008` with `"activityFirstEnabled"`.
- **FR-12 (observability + version-on-events).** The handler **logs** the served `version`/`etag`/`scope` per
  request (structured JSON, no PII). The client attaches the **resolved `configVersion`** to analytics events
  (`0015`) so flips can be correlated with metric changes; a **CloudWatch metric/alarm** fires on config-handler
  error rate (fold into `0032`).
- **FR-13 (contract).** Add `GET /v1/config` (+ the `ConfigDocument` schema and a `304` path) to
  `shared/api/openapi.yaml`, mirrored in `DTOs.swift` (`ConfigDocumentDTO`), with **lenient decoding** (unknown
  flags/params ignored; missing keys fall back to baked defaults) so server and client can evolve independently.

### 5.2 Non-functional
- **NFR-1 (offline-first preserved — the hard invariant).** The app is **fully usable with zero config calls**:
  every feature path has a baked default; the **offline first-run** (bundled sample + Mock AI) **never** calls
  `/config` and **never** depends on a flag. A fresh install with no network completes the first lesson; the
  config fetch is **best-effort** and **non-blocking**. (CLAUDE.md invariant.)
- **NFR-2 (flags are NOT a security boundary — explicit).** Remote config decides **visibility and rollout
  only**. **Every** gated action is **independently enforced server-side** (the Cognito authorizer + the
  `require(...)`/policy checks in `0031`/`0023`/`0024`/`0042`/`0043`). A client that flips a cached flag, or a
  forged `/config` response, **cannot** unlock a gated action — it still gets the server's **403**. The config
  endpoint **never** returns secrets, keys, URLs to privileged resources, or anything whose disclosure matters.
- **NFR-3 (fail-safe semantics are per-flag and tested).** Each key declares its failure mode: **fail-open**
  (baked default; ordinary flags) or **fail-closed** (safe-disabled; risky kill-switches). The resolution
  function is **pure and unit-tested** on both sides (the `LevelCurve`/`StreakCalculator` style) so the
  semantics can't silently regress (§8).
- **NFR-4 (cost & performance).** `/config` is **tiny + cacheable**: no Bedrock, a single DDB read (or a cached
  doc), `Cache-Control` + `ETag`/`304` to make polling near-free, and a CDN-cacheable public slice. The client
  caps fetches to **≤ once per `ttlSeconds`** (launch + foreground, throttled). The DDB read is a single item
  (`CONFIG#<env>/DOC`); the handler may also keep a short **in-Lambda warm cache** to cut reads under burst.
- **NFR-5 (security / least-privilege).** The config Lambda has **table read-only** (no write, no Bedrock, no
  S3, no secrets). The **admin write path** (`0034`) is the only writer and is itself authed + audited
  (`updatedBy`, `AUDIT#<ts>`). The public slice is safe to serve unauthenticated (no PII, no per-user data); the
  authed slice requires the Cognito JWT (`response.user_id`). No new secrets. `cdk synth` shows no wildcard
  `Resource:"*"` for the config function.
- **NFR-6 (float-free + types).** `flags` are booleans; `params` are **`int`** or **`str`**; **percentages are
  whole-number ints** (0–100) or basis-point ints — **no float ever reaches DynamoDB** (reuse `progress.py`
  `Decimal`→`int` coercion on read). The DTO decodes `params` as a typed union (`int`/`string`), tolerating
  unknown keys.
- **NFR-7 (consistency / determinism).** Bucketing + evaluation are **deterministic** (stable hash; no
  randomness, no time-of-day) so a user's assignment is **stable across launches** and the **client and server
  agree** (the twinned function). Re-evaluation on a new `version` is allowed to **move** a user only if the
  rollout changed.
- **NFR-8 (contract lockstep & zero iOS deps).** `openapi.yaml` ⇄ `DTOs.swift` ⇄ handlers in sync; new iOS files
  under `ios/Mango/` auto-register (Xcode-16 sync groups); pure SwiftUI/Foundation — **no SDKs** (no AppConfig
  SDK, no flag-vendor SDK; v1 is a plain `URLSession` GET to our own endpoint).
- **NFR-9 (backend style/runtime).** stdlib + boto3 only; black (100) + flake8 (120); `pytest` (moto; Bedrock
  N/A here) **and** `cdk synth -c stage=beta` pass **offline**.
- **NFR-10 (accessibility & UX of gated surfaces).** When a flag hides a surface, the surface is **absent**, not
  a broken/greyed control (matches `0031`'s "absent, not greyed" rule); any "temporarily unavailable" state for a
  killed feature uses `Palette`/`Typo`/`Metrics`, calm copy, VoiceOver labels, Dynamic Type. Flag flips must not
  cause layout jank mid-session (apply on next natural navigation; §6.6).

## 6. Design

### 6.1 The config document (what `GET /v1/config` returns)
A single typed document (FR-1). **Flags** = booleans the app reads to show/enable a path. **Params** = tunable
numbers/strings (thresholds, caps, windows). **Rollouts** = per-flag targeting specs evaluated for the caller.
```jsonc
{
  "version": 42,                     // monotonically bumped on every admin edit (FR-3)
  "etag": "v42-7f3a…",               // hash of the resolved (per-scope) document; drives 304 (FR-4)
  "ttlSeconds": 300,                 // client refresh cap + Cache-Control max-age (FR-4, NFR-4)
  "scope": "user",                   // "public" (pre-auth) | "user" (authed, per-user evaluated) (FR-2)
  "flags": {
    "activityFirstEnabled": true,        // 0008  (fail-open; UX)
    "externalEngagementEnabled": false,  // 0042  (fail-CLOSED; risky)  ← kill-switch
    "peerSessionsEnabled": false,        // 0043  (fail-CLOSED; risky)  ← kill-switch
    "creditsEnabled": true,              // 0023  (fail-CLOSED; monetization)
    "rewardsRedeemEnabled": true,        // 0024  (fail-CLOSED; monetization)
    "signInRequired": false,             // public; gates whether app pushes sign-in
    "catalogEnabled": true               // public; first-run-visible surface
  },
  "params": {
    "ageGatePolicyVersion": 3,           // 0031 (int)
    "externalDailyCap": 5,               // 0042 FR-10 (int)
    "rateLimitPerMinHint": 60,           // surfaced to client for UX (int) — server still authoritative
    "minSessionGapDays": 1               // example (int)
  },
  "rollouts": {                          // only present/evaluated for keys with a rollout
    "activityFirstEnabled": { "percent": 25, "cohorts": ["internal"], "bands": ["adult","teen"] }
  }
}
```
- The **public slice** omits non-public flags entirely and evaluates rollouts **without** a user (so
  user-conditioned flags simply don't appear / resolve false). The **authed slice** includes non-public flags,
  **each already resolved to a boolean for that user** (the client doesn't need the rollout math, but the
  `rollouts` block is included for transparency/debugging and so the **client twin** can optimistically
  pre-resolve before the next fetch).
- **Why both "resolved boolean" and "rollout spec"?** The server resolves authoritatively (FR-2/FR-5); the
  client carries the spec so that, between fetches, a newly-signed-in user (whose first fetch was public) can
  **locally** resolve a user-conditioned flag with the **same twin** without waiting — still overridden by the
  next authed fetch.

### 6.2 Evaluation + bucketing (pure, unit-tested, twinned client/server)
A single rule, **byte-identical** on both sides (the `LevelCurve`/`StreakCalculator`/`AgeBand` pattern):
```python
# backend/src/shared/config_eval.py   (stdlib only; pure; unit-tested)
import hashlib

def bucket(sub: str, flag_key: str) -> int:
    """Stable 0..9999 basis-point bucket for (user, flag). Deterministic; no time, no randomness."""
    h = hashlib.sha256(f"{sub}:{flag_key}".encode()).digest()
    return int.from_bytes(h[:4], "big") % 10000

def evaluate(flag_key: str, rollout: dict | None, *, sub: str | None,
             cohorts: set[str], band: str | None) -> bool:
    """Resolve a flag for a user. No rollout ⇒ env-level (the flag's base value governs).
    With a rollout: ON iff (percent gate) OR (cohort match) OR (band match). Fail-closed for the
    *public* slice when the rollout is user-conditioned and there is no user."""
    if rollout is None:
        return True                      # base value applied by caller; rollout only *narrows*
    if sub is None:                      # public slice, user-conditioned rollout → not in rollout
        return rollout.get("percent", 0) >= 100 and not rollout.get("cohorts") and not rollout.get("bands")
    if rollout.get("cohorts") and cohorts.intersection(rollout["cohorts"]):
        return True
    if rollout.get("bands") and band in (rollout.get("bands") or []):
        return True
    return bucket(sub, flag_key) < int(rollout.get("percent", 0)) * 100
```
```swift
// ios/Mango/Services/Config/ConfigEval.swift   (Foundation only; mirrors the Python twin byte-for-byte)
enum ConfigEval {
    static func bucket(sub: String, flagKey: String) -> Int { /* sha256(":")[0..<4] big-endian % 10000 */ }
    static func evaluate(flagKey: String, rollout: Rollout?, sub: String?, cohorts: Set<String>, band: String?) -> Bool { /* same rule */ }
}
```
- **Server is authoritative.** The authed `/config` resolves every non-public flag with `evaluate(...)` and
  returns booleans; the **client twin** is only for **optimistic** pre-resolution between fetches and for tests
  that assert client==server on the same inputs (§8).
- **`cohorts`** for a user are derived server-side (e.g. an `internal` allow-list keyed by `sub`, or a
  `USER#<sub>/COHORTS` item the admin console sets); **`band`** comes from `0031`'s `current_band(uid)` (config
  **consumes** it; it does not store age data). For the public slice both are empty/nil → user-conditioned flags
  resolve false.

### 6.3 Data — DynamoDB (single-table, env-scoped, float-free)
No new table; new item types under the existing `PK`/`SK`:
| Entity | PK | SK | Key attributes |
|---|---|---|---|
| **Config doc** | `CONFIG#<env>` | `DOC` | `version` (N int), `flagsJSON` (S — JSON of `{key:bool}` + per-flag `scope`/`failClosed` meta), `paramsJSON` (S — JSON of `{key:int|str}`), `rolloutsJSON` (S — JSON of `{key:{percent,cohorts,bands}}`), `updatedAt` (S iso), `updatedBy` (S admin id) |
| **Config audit** | `CONFIG#<env>` | `AUDIT#<ts>` | `version` (N int), `actor` (S), `change` (S — JSON diff old→new), `note` (S) |
| **User cohorts** (opt.) | `USER#<sub>` | `COHORTS` | `cohorts` (SS or S JSON — e.g. `["internal","beta"]`), `updatedBy`, `updatedAt` — set by `0034`; absent ⇒ no cohorts |
- **Why JSON-string columns?** Same reason `generate_roadmap.py` stores JSON strings: keeps the item simple,
  **float-free** (we serialize `int`/`bool`/`str` only — never a DDB `float`), and dodges the resource-API
  `float` rejection. The handler `json.loads` them and assembles the document; the admin write path
  `json.dumps` validated structures.
- **Env scoping.** `CONFIG#<env>` (`env` = `beta`/`prod`/`dev` from `STAGE`) so beta and prod have independent
  flags — you can dark-launch in beta first. The handler reads `CONFIG#<STAGE>/DOC`.
- **No per-user config rows** (evaluation is stateless); the only per-user item is the optional `COHORTS` list
  (no PII). `DELETE /v1/me` (`0033`) sweeps `USER#<sub>/COHORTS` like any user item.

### 6.4 API / contract (add to `shared/api/openapi.yaml`)
```yaml
  /v1/config:
    get:
      summary: Typed remote config + feature flags. Public slice pre-auth; per-user slice when authed.
      parameters:
        - { name: If-None-Match, in: header, required: false, schema: { type: string } }
      responses:
        "200":
          description: Config document (scope=public when unauthenticated, scope=user when a valid bearer is sent)
          headers:
            ETag:          { schema: { type: string } }
            Cache-Control: { schema: { type: string } }
          content: { application/json: { schema: { $ref: "#/components/schemas/ConfigDocument" } } }
        "304": { description: Not modified (ETag matched If-None-Match) }
components:
  schemas:
    ConfigDocument:
      type: object
      required: [version, etag, ttlSeconds, scope, flags, params]
      properties:
        version:    { type: integer }
        etag:       { type: string }
        ttlSeconds: { type: integer }
        scope:      { type: string, enum: [public, user] }
        flags:      { type: object, additionalProperties: { type: boolean } }
        params:     { type: object, additionalProperties: {} }          # int or string (NFR-6)
        rollouts:
          type: object
          additionalProperties:
            type: object
            properties:
              percent: { type: integer, minimum: 0, maximum: 100 }
              cohorts: { type: array, items: { type: string } }
              bands:   { type: array, items: { type: string, enum: [under13, teen, adult] } }
```
**openapi ⇄ DTO ⇄ handler sync.** `DTOs.swift` gains `ConfigDocumentDTO { version: Int, etag: String,
ttlSeconds: Int, scope: String, flags: [String:Bool], params: [String: ConfigParam], rollouts: [String:
RolloutDTO]? }` where `ConfigParam` decodes leniently as `.int(Int)` / `.string(String)` and **ignores unknown
shapes**; unknown flag/param keys are tolerated (forward-compat). The authed write side (no public OpenAPI
surface here) is the admin console's contract in `0034`.

### 6.5 Backend handler + cache header (thin; logic in `shared/config_data.py`)
- `backend/src/handlers/config.py` (new), mirroring `catalog.py`'s thin shape:
  - Resolve `env = os.environ["STAGE"]`; load `CONFIG#<env>/DOC` (with a short in-Lambda warm cache, NFR-4);
    on a **missing item**, serve the **empty document** `{flags:{},params:{},rollouts:{}, version:0}` so clients
    fall back entirely to baked defaults (which is *safe* — fail-open flags keep working, fail-closed flags stay
    off; §6.7).
  - Determine scope: try `uid = user_id(event)`; if it **raises `PermissionError`** (no/invalid bearer) or the
    route is hit anonymously → **public slice** (filter to `scope:"public"` flags; evaluate rollouts with no
    user). If a `uid` resolves → **user slice**: load `cohorts` (`USER#<uid>/COHORTS`) + `band`
    (`0031.current_band(uid)` when available, else `None`), and **resolve every flag** via `config_eval.evaluate`.
  - Compute `etag` over the resolved (per-scope) document; honor **`If-None-Match`** → `304`. Set
    **`Cache-Control`** (`public` for public slice, `private` for user slice; `max-age=ttlSeconds`) via the new
    `response.ok_cached(body, cache_control=…, etag=…)` helper (extends `shared/response.py`; the same extension
    `0028` requests). Log `version`/`etag`/`scope` (structured, no PII).
- `api_stack.py` wiring: `config_fn = make_fn("ConfigFn", "handlers.config.handler", timeout=10, memory=128)`;
  **`route("/v1/config", GET, config_fn, secured=False)`** (the handler itself upgrades to the user slice when a
  bearer is present — like a public endpoint that *optionally* reads identity; this keeps a single route while
  serving both scopes). `table.grant_read_data(config_fn)` (**read-only** — least privilege; no write, no
  Bedrock, no S3, no secrets). *(Decision D-3 considers a separate secured `/v1/config` route vs. the single
  optional-auth route; recommend the single route — §10.)*
- **Admin write path (defined here, screens in `0034`):** a `config_admin` mutation (in the admin console's
  authed handler) validates a proposed change (booleans/ints/strs; percent 0–100; known cohorts), **bumps
  `version`**, writes `CONFIG#<env>/DOC` + `CONFIG#<env>/AUDIT#<ts>`. This spec ships the **validator**
  (`shared/config_data.validate_change(...)`) + the item shapes; `0034` calls them. (Belt-and-suspenders: the
  validator rejects a float, an unknown flag type, or an out-of-range percent.)

### 6.6 iOS — `RemoteConfig` service, defaults, and how surfaces read flags
- **`ConfigDefaults` (compiled in).** A single source of baked defaults + failure modes:
  ```swift
  enum ConfigKey: String { case activityFirstEnabled, externalEngagementEnabled, peerSessionsEnabled,
                                creditsEnabled, rewardsRedeemEnabled, signInRequired, catalogEnabled /* … */ }
  struct ConfigDefault { let value: ConfigValue; let failClosed: Bool }   // value: .bool/.int/.string
  // failClosed:true ⇒ kill-switch; resolves ENABLED only on an explicit fetched/cached "true", else OFF.
  ```
  Defaults mirror today's compile-time behavior (FR-10): `activityFirstEnabled` = current `0008` value
  (fail-open); `externalEngagementEnabled`/`peerSessionsEnabled`/`creditsEnabled`/`rewardsRedeemEnabled` =
  `false`+`failClosed:true` (risky/monetization off until explicitly enabled by a fetched config).
- **`RemoteConfig` (`@Observable`, in `AppModel`).** Holds the **resolved document** (in memory) + the **disk
  cache** (a JSON file in Application Support, last-known-good). API:
  - `refreshIfStale()` — called on launch + foreground; no-ops if the last fetch is within `ttlSeconds`. Uses
    `AppModel.apiClient()` (authed when signed in, else a public client; **`nil` when offline ⇒ skip, keep
    cache**). Sends `If-None-Match`; on `304` keeps the doc and resets the timer; on `200` replaces memory + disk;
    on **any error** keeps the **cached** doc.
  - `isEnabled(_ key: ConfigKey) -> Bool` — resolution: **(a)** if a fetched/cached value exists → use it
    (for `failClosed` keys, "enabled" requires an explicit `true`); **(b)** else → the **baked default** (for
    `failClosed` keys that's the **safe off**). Never throws; never blocks.
  - `int(_:default:)` / `string(_:default:)` — typed params with caller-supplied fallback (also covered by
    `ConfigDefaults`).
  - On **sign-in** (`AppModel.reloadAIService()` path), trigger a `refresh` so the **user slice** replaces the
    public slice (a previously-public flag may now resolve via the user's rollout/cohort/band).
- **How a surface reads a flag (one line).** Feature entry points read `RemoteConfig`:
  `if remoteConfig.isEnabled(.externalEngagementEnabled) { /* show feed entry */ }` — **absent** when off
  (NFR-10). `0008`'s reframed UI checks `.activityFirstEnabled`; `0023`/`0024` paywall/rewards entries check
  `.creditsEnabled`/`.rewardsRedeemEnabled`; `0042`/`0043` external/peer entries check their kill-switches.
  Because the **server independently enforces** (NFR-2), a stale "on" client at worst shows an entry that the
  server then refuses with a calm 403 (the consuming spec handles that copy).
- **Apply-on-navigation (NFR-10).** A flag flip observed mid-session is applied at the **next natural
  navigation** (a `RemoteConfig` change republishes; views re-evaluate on appear) to avoid yanking UI out from
  under the user.
- **Migration line (FR-10).** `activityFirstEnabled` moves from `AppSettings` to `ConfigDefaults`/`RemoteConfig`;
  **operational** device switches (`apiEnvironment`, `useDirectClaudeWhenOffline`, `themePreference`,
  `reminderEnabled`) **stay** in `AppSettings` (local user/dev choices, not server-driven). A short table in §9
  records the split.

### 6.7 The two failure-mode flows (diagram)
```
App launch / foreground
  └─ RemoteConfig.refreshIfStale()
       ├─ online + (cache fresh within ttl) → use in-memory doc
       ├─ online + stale → GET /v1/config (If-None-Match)
       │     ├─ 304 → keep doc, reset timer
       │     ├─ 200 → replace memory + disk (last-known-good)
       │     └─ error/timeout → keep CACHED doc
       └─ offline (apiClient nil) → keep CACHED doc (or none)

Read a flag:  isEnabled(key)
  ├─ fetched/cached value present?
  │     ├─ yes → use it   (failClosed key: ENABLED only if value == true)
  │     └─ no  → baked ConfigDefault
  │                 ├─ ordinary flag (fail-OPEN) → baked default (app keeps working)
  │                 └─ kill-switch  (fail-CLOSED) → SAFE OFF (risky feature stays disabled)
  └─ server still independently enforces the gated action (NFR-2)  ← the real boundary
```
**Worked example (config outage at launch, no cache):** `activityFirstEnabled` → baked default (say `true`) →
**UI works**; `externalEngagementEnabled` (failClosed) → **OFF** → the risky feed is **absent** and the server
refuses it anyway. The app is fully usable; nothing risky leaks.

### 6.8 IAM (least-privilege — mirror `api_stack.py`)
- **`ConfigFn`:** `table.grant_read_data` **only** (read `CONFIG#<env>/DOC`, `USER#<uid>/COHORTS`). **No** write,
  **no** Bedrock, **no** S3, **no** secrets. (Tighter than most handlers — it's a read endpoint.)
- **Admin write** (the `0034` console handler, not this Lambda) gets `table.grant_read_write_data` scoped to the
  `CONFIG#<env>` items + audit; it is itself behind the admin auth (`0034`). This spec adds **no** new broad
  grant; `cdk synth` shows **no** wildcard `Resource:"*"` for `ConfigFn`.

## 7. Acceptance criteria
- [ ] **AC-1 (document shape + types).** `GET /v1/config` returns `version`/`etag`/`ttlSeconds`/`scope`/`flags`
  (booleans)/`params` (int|str)/optional `rollouts`; **no float** appears anywhere. *(pytest on the handler +
  DTO decode test; assert `params` decode as int/string.)*
- [ ] **AC-2 (public slice pre-auth).** Called **without** a bearer, the endpoint returns **only `scope:"public"`
  flags**, evaluates user-conditioned rollouts to **false**, and sets **`Cache-Control: public, max-age=ttl`**.
  *(pytest: no-auth request → only public flags; a user-conditioned flag absent/false.)*
- [ ] **AC-3 (authed per-user slice).** With a valid bearer, the endpoint returns public **plus** non-public
  flags, **each resolved for that `sub`**, and sets **`Cache-Control: private`**. *(pytest: two different `sub`s
  with a 50% rollout get stable, differing resolutions; same `sub` is stable across calls.)*
- [ ] **AC-4 (flag fetch + cache — iOS).** `RemoteConfig` fetches on launch, **persists the doc to disk**, and on
  a subsequent launch **with no network** serves the **cached** values (not just defaults). *(iOS test: stub a
  200, relaunch with `apiClient == nil`, assert cached values returned; assert no fetch within `ttlSeconds`.)*
- [ ] **AC-5 (safe-default on failure — fail-open).** With **no fetched/cached** value (cold start, offline), an
  **ordinary** flag/param resolves to its **baked default** and the app is **fully functional**; the **offline
  first-run sample lesson** completes with **zero** `/config` calls. *(iOS test asserting baked default returned;
  manual offline run.)*
- [ ] **AC-6 (kill-switch fail-safe — the load-bearing test).** A **`failClosed`** kill-switch
  (`externalEngagementEnabled`) resolves to **DISABLED** when config is **missing/unreachable/stale**, **even if**
  a stale cache said "on" is absent — it only resolves **enabled** on an **explicit fetched/cached `true`**; the
  client **hides** the surface and the **server refuses** it. *(iOS test: no value → off; cached `true` → on;
  error during refresh with no prior `true` → off. pytest: server `evaluate` returns false absent the flag,
  gated handler 403.)*
- [ ] **AC-7 (rollout bucketing — deterministic + twinned).** `bucket(sub, key)` is **stable** for a given
  `(sub, key)` and **distributes** ~uniformly; the **Swift twin matches the Python twin byte-for-byte** on a
  shared vector; a 25% rollout includes ~25% of a large `sub` sample and the **same** `sub` stays in/out across
  re-evaluations unless the percent changes. *(pytest `test_config_eval.py` + iOS `ConfigEvalTests` on the same
  fixtures; distribution + stability assertions.)*
- [ ] **AC-8 (targeting by cohort + band).** A `sub` in the `internal` cohort gets a cohort-targeted flag on
  while others don't; a flag targeted to `bands:["adult"]` is on for an adult `sub` and off for a teen.
  *(pytest with stubbed cohorts + `current_band`.)*
- [ ] **AC-9 (304 / cacheability).** A request with a matching `If-None-Match` returns **304**; the `etag`
  changes when `version` bumps. *(pytest on the ETag path.)*
- [ ] **AC-10 (admin edit bumps version + audits + validates).** A validated admin change writes
  `CONFIG#<env>/DOC` with **`version+1`** and a `CONFIG#<env>/AUDIT#<ts>` diff; an invalid change (float param,
  unknown flag type, percent > 100) is **rejected**. *(pytest on `validate_change` + the write path.)*
- [ ] **AC-11 (flags are not a security boundary).** With a flag flipped **on** only in a forged client (server
  config says off / user not in rollout), the gated endpoint (`0042` submit / `0023` purchase) still returns
  **403**; nothing is unlocked by the client flag. *(pytest: server `evaluate=false` → gated handler 403
  regardless of request-supplied flag; code review that `/config` returns no secrets.)*
- [ ] **AC-12 (migration parity).** With **no remote config present**, `activityFirstEnabled` (and any migrated
  flag) resolves to **exactly** its prior compile-time value (baked default), so day-one behavior is unchanged.
  *(iOS test: empty doc → baked default equals the pre-migration constant.)*
- [ ] **AC-13 (least-privilege + auth-optional route).** `ConfigFn` has **table read-only** (no Bedrock/S3/
  secrets/write); the route serves **public** unauthenticated and **user** when a valid bearer is present.
  *(pytest auth/scopes + `cdk synth` IAM inspection.)*
- [ ] **AC-14 (contract sync).** `openapi.yaml` defines `/v1/config` + `ConfigDocument` (+ 304); `DTOs.swift`
  mirrors it and **decodes leniently** (unknown flags/params ignored; missing keys → baked defaults);
  `cdk synth -c stage=beta` passes. *(openapi lint + DTO decode test + synth.)*
- [ ] **AC-15 (version-on-events / observability).** Analytics events carry the **resolved `configVersion`**; the
  handler logs `version`/`etag`/`scope` (no PII). *(iOS test that the events emitter includes `configVersion`;
  pytest that logs exclude identity beyond `sub`.)*
- [ ] **AC-16 (offline-first preserved).** Fresh install, Mock AI, no network/auth: app launches, **no
  `/config` call blocks anything**, first sample lesson completes; config fetch is best-effort. *(manual offline
  run + iOS test that a failed/absent fetch never blocks UI.)*

## 8. Test plan
**Backend — `pytest` (moto; offline), `backend/tests/`:**
- `test_config_eval.py` — the **pure** evaluator: `bucket` stability + distribution; `evaluate` for
  no-rollout/percent/cohort/band; **public slice** fail-closed for user-conditioned flags; **boundary** at
  `percent` (e.g. a `sub` whose bucket == percent*100 is **off**). (AC-7/AC-8)
- `test_config_handler.py` — public vs user slice (AC-2/AC-3); `Cache-Control` per scope; `If-None-Match` → 304
  + etag changes on version bump (AC-9); missing `CONFIG#<env>/DOC` → empty doc (defaults govern); `Decimal`→`int`
  on `params` (NFR-6); auth-optional route resolves identity only when a bearer is present (AC-13). Mirrors
  `test_catalog.py`/`test_progress.py` idioms.
- `test_config_admin.py` — `validate_change` rejects float/unknown-type/percent>100/unknown-cohort; a valid
  change bumps `version` and writes the audit diff (AC-10).
- `test_config_not_a_boundary.py` — a gated handler (an `0042` submit stub / `0023` purchase stub) returns **403**
  when the **server** `evaluate` is false, **regardless** of any request-supplied flag (AC-11).
- `cdk synth -c stage=beta` — `/v1/config` route present + `secured=False`; `ConfigFn` **read-only** grant; no
  wildcard resource.

**iOS — `MangoTests` (pure/fast) + flow:**
- `ConfigEvalTests` — the Swift twin of `bucket`/`evaluate`; **must match the Python twin byte-for-byte** on a
  shared vector (commit the same fixtures both sides) incl. the percent boundary + cohort/band cases (AC-7/AC-8).
- `RemoteConfigTests` — fetch → in-memory + **disk cache**; relaunch offline serves cache (AC-4); throttle ≤
  `ttlSeconds`; `304` keeps doc; **error keeps cache** (AC-5); sign-in triggers a refresh that swaps public→user.
- `ConfigFailSafeTests` — **fail-open** ordinary flag → baked default; **fail-closed** kill-switch → **OFF**
  unless an explicit fetched/cached `true` (AC-6); migration parity: empty doc → prior compile-time value (AC-12).
- `ConfigDTOTests` — lenient decode: unknown flags/params ignored; `params` as int/string; missing keys fall back
  (AC-14).
- (Smoke) `RemoteConfig` never blocks: a 60 s-hung stub still lets the first sample lesson complete (AC-16).

**Manual / process:**
- Offline first-run (Mock AI) — confirm **no** `/config` dependency; app fully usable. (AC-16)
- Admin console (`0034`) dry-run: flip `externalEngagementEnabled` off → within `ttlSeconds` apps hide it and the
  server refuses it; ramp `activityFirstEnabled` 5→25→100 and confirm stable per-user assignment. (AC-6/AC-7)
- VoiceOver/Dynamic-Type pass on any "temporarily unavailable" state for a killed feature. (NFR-10)

## 9. Rollout & migration
- **Dependency ordering.** Land the **substrate first** (`/config` endpoint + `RemoteConfig` + `ConfigDefaults` +
  the twinned evaluator + the `0034` write path/validator), **with the empty-document fallback** so it's inert
  until items exist. Then **migrate `activityFirstEnabled`** (FR-10) with its current value as the baked default
  (zero behavior change). Only **after** the consuming specs ship do their kill-switches/params get used:
  `0031` reads thresholds via `config.param`; `0042`/`0043` gate risky surfaces; `0023`/`0024` gate monetization.
- **Local→remote flag split (FR-10).**
  | Today (local) | Destination | Why |
  |---|---|---|
  | `activityFirstEnabled` (`0008`) | **Remote** (`ConfigDefaults`+`RemoteConfig`) | feature/rollout — server-driven |
  | `creditsEnabled`/`rewardsRedeemEnabled` (`0023`/`0024`) | **Remote** (fail-closed) | monetization kill-switch |
  | `externalEngagementEnabled`/`peerSessionsEnabled` (`0042`/`0043`) | **Remote** (fail-closed) | risky kill-switch |
  | age `POLICY` thresholds (`0031`) | **Remote params** (in-code defaults) | counsel-tunable without release |
  | `apiEnvironment`, `useDirectClaudeWhenOffline` | **Stay in `AppSettings`** | local dev/user choice, not server-driven |
  | `themePreference`, `reminderEnabled` | **Stay in `AppSettings`** | local user preference |
- **Per-environment dark-launch.** `CONFIG#<env>` is independent per stage → flip in **beta** first, watch, then
  **prod**. A flag absent from `CONFIG#<env>` ⇒ clients use baked defaults (safe).
- **Flag lifecycle (research best practice).** Each flag gets an **owner + intended removal** noted in the admin
  console; `0008`'s "flag for one release then delete" generalizes: ship remote default off → ramp rollout →
  set default on (and bake it) → **remove the key** in a later release (the lenient DTO tolerates the key
  vanishing). Track stale flags as tech debt.
- **Backward-compat / teardown.** Additive everywhere. Disabling the whole system = the endpoint returns the
  empty document → **baked defaults govern** (fail-open flags work; fail-closed stay off) — i.e. graceful
  degradation to today's compile-time behavior. No destructive migration; the optional `USER#<sub>/COHORTS` item
  is swept by `DELETE /v1/me`.

## 10. Risks & open decisions
- **Risk — a forged/altered `/config` or a flipped client flag unlocking something.** *Mitigation:* **NFR-2** —
  flags are **never** the boundary; the server independently enforces every gated action and `/config` returns
  **no secrets**. A jailbroken client gets a 403. Tested by AC-11.
- **Risk — a config outage silently leaving a risky feature on.** *Mitigation:* **fail-closed kill-switches**
  (FR-9) — risky flags resolve **off** unless an explicit fetched/cached `true` says otherwise; the server also
  refuses independently. Tested by AC-6.
- **Risk — breaking offline-first by making the app wait on `/config`.** *Mitigation:* baked defaults + non-
  blocking best-effort fetch + disk cache (NFR-1, FR-6/FR-7); the offline first-run never calls `/config`
  (AC-16).
- **Risk — client/server disagree on a user's rollout (flicker / wrong cohort).** *Mitigation:* the
  **deterministic twinned** evaluator (§6.2, NFR-7); the **server is authoritative** and the client only
  optimistically pre-resolves; a stable hash keeps a user's assignment fixed across launches (AC-7).
- **Risk — cost / chattiness of polling.** *Mitigation:* tiny payload, `Cache-Control` + `ETag`/`304`, client
  throttle ≤ `ttlSeconds`, CDN-cacheable public slice, in-Lambda warm cache (NFR-4).
- **Risk — float sneaking into a percentage/param.** *Mitigation:* params are `int`/`str`, percents are whole
  ints/basis points, the **validator rejects floats**, and reads coerce `Decimal`→`int` (NFR-6, AC-10).

**Decisions needed (with recommendations):**
- **D-1 (DynamoDB vs AWS AppConfig — the central choice).** **Recommend a homegrown DynamoDB-backed `/config`
  for v1.** Rationale: the **app talks to our own `GET /v1/config` either way** (AWS recommends a Lambda proxy in
  front of AppConfig for mobile, never direct calls); Mango already has the **single-table + thin-Lambda +
  public-GET** pattern and an **admin console (`0034`) that edits DDB items**; and the **stdlib+boto3-only /
  no-packaging** invariant means **no new SDK or build step**. AppConfig's wins (schema validation, **CloudWatch-
  alarm auto-rollback**, managed **gradual-deploy strategies**) are real but add a service + IAM + agent/extension
  to learn; we replicate the essential safety (validation in `validate_change`, version+audit, staged rollout via
  `percent`) in app code. **Document AppConfig as the upgrade path** (`0035b`) for when we want managed staged
  deploys + automatic rollback on a CloudWatch alarm; the `/config` endpoint shape stays the same (the Lambda just
  reads AppConfig instead of DDB), so the iOS side is unaffected.
- **D-2 (single optional-auth route vs. two routes).** **Recommend a single `/v1/config` route** that serves the
  public slice unauthenticated and **upgrades** to the user slice when a valid bearer is present (the handler
  reads identity opportunistically, like a public endpoint that personalizes if it can). Simpler client, one
  cache key per scope. *Alternative:* a separate **secured** `/v1/config?scope=user`; more explicit but doubles
  the surface. (If a clean CDN cache key for the public slice matters, a dedicated public path
  `/v1/config/public` is the fallback.)
- **D-3 (what's a flag vs. a param vs. an `AppSettings` local).** **Recommend** the §9 split: **server-driven
  feature/rollout/kill-switch/threshold** → remote; **local user/dev preference** (`apiEnvironment`, theme,
  reminder, direct-Claude) → `AppSettings`. Avoids turning every local toggle into a network dependency.
- **D-4 (cohort source).** **Recommend** a small admin-set `USER#<sub>/COHORTS` item (e.g. `internal`,
  `beta_testers`) for v1; richer cohorting (derived from behavior/segments) is future work with `0020`/G12.
- **D-5 (propagation latency).** **Recommend** pull + short `ttlSeconds` (default **300 s**, tunable as a param)
  for v1; near-real-time push (SSE/websocket) is deferred (§2 non-goal, R-3).
- **D-6 (default `ttlSeconds`).** **Recommend 300 s** (balance freshness vs. chattiness); kill-switch urgency is
  bounded by it — note for ops that a kill takes up to one TTL to propagate to already-open apps (a
  foreground-refresh shortens it). If faster kills are needed, lower the TTL or pursue R-3.

**Future (R-#):** **R-1** AppConfig migration (managed deploys + auto-rollback). **R-2** richer targeting
(device/OS/geo/time-window). **R-3** push-based propagation for instant kills. **R-4** per-flag analytics
(assignment exposure logging) to fully power A/B with `0012`/`0020` (G12). **R-5** a flag-cleanup linter
(surface stale keys) per the research best-practice.

## 11. Tasks & estimate
**Small (S)**
1. `shared/response.py`: add `ok_cached(body, *, cache_control, etag)` + `If-None-Match`→304 helper (shared with `0028`). **S**
2. `openapi.yaml`: add `GET /v1/config` + `ConfigDocument` (+304); `DTOs.swift`: `ConfigDocumentDTO`/`ConfigParam`/`RolloutDTO` (lenient). **S**
3. iOS `ConfigDefaults` (baked defaults + `failClosed` markers) incl. migrating `activityFirstEnabled` (FR-10). **S**

**Medium (M)**
4. `shared/config_eval.py` (pure `bucket`/`evaluate`) + `ConfigEval.swift` twin + shared test vectors. **M**
5. `shared/config_data.py` (load `CONFIG#<env>/DOC`, assemble doc, `validate_change`) + `handlers/config.py` (scopes, etag/304, cache headers, empty-doc fallback, warm cache). **M**
6. `api_stack.py`: `ConfigFn` (read-only grant) + `route("/v1/config", GET, secured=False)`; `cdk synth` IAM/route assertions. **M**
7. iOS `RemoteConfig` service (launch/foreground throttled fetch, disk last-known-good, typed accessors, fail-open/closed resolution, sign-in refresh). **M**
8. Wire consuming call sites to **read** flags (substrate hookup): `0008` `activityFirstEnabled`; stubs/seams for `0042`/`0043`/`0023`/`0024` kill-switches + `0031` `param` reads (the actual gates live in those specs). **M**
9. Backend tests (`test_config_eval`, `test_config_handler`, `test_config_admin`, `test_config_not_a_boundary`) + iOS tests (`ConfigEvalTests`, `RemoteConfigTests`, `ConfigFailSafeTests`, `ConfigDTOTests`). **M**

**Large (L)**
10. Admin write path integration with `0034` (validated mutation UI → `validate_change` → version bump + `AUDIT#<ts>`; owner/removal metadata; per-env beta-first dark-launch). **L** *(shared with `0034`)*
11. Observability: `configVersion` on `0015` events + CloudWatch metric/alarm on config-handler errors (fold into `0032`); flag-lifecycle/stale-key surfacing (R-5 seed). **L**

## 12. References
- ARCHITECTURE_REVIEW G11 (this gap) and consuming specs: `working/ARCHITECTURE_REVIEW.md` §3 (G11), `working/0031-age-assurance-coppa.md` (§6.3/§9 — `POLICY` thresholds via `0035`), `working/0042-external-engagement-activities.md` (flag-gated risky features), `working/0034-admin-support-console.md` (who edits flags), `working/0008-product-reframe-activity-first.md` (`activityFirstEnabled`), `working/0028-*` (`Cache-Control` extension), `working/0009-*`/`backend/src/handlers/catalog.py` (public-GET pattern), `backend/src/shared/response.py` (`user_id`, `ok`).
- AWS AppConfig — what it is, feature flags, deployment strategies/auto-rollback: <https://docs.aws.amazon.com/appconfig/latest/userguide/what-is-appconfig.html> and AppConfig feature-flags blog <https://aws.amazon.com/blogs/mt/using-aws-appconfig-feature-flags/>
- AWS AppConfig — **browser & mobile use** (proxy recommended; cache locally with safe defaults): <https://docs.aws.amazon.com/appconfig/latest/userguide/appconfig-retrieving-mobile.html>
- Mobile feature-flag best practices (fetch-at-startup, cache last-known-good, per-flag safe defaults, stable user-hash bucketing): <https://docs.getunleash.io/guides/feature-flag-best-practices>
- Kill-switches as inverted flags; fastest incident resolution; don't depend on the flag service: <https://www.getunleash.io/blog/kill-switches-best-practice>
- Fail-open vs fail-closed as a deliberate per-flag failure mode: <https://launchdarkly.com/blog/operational-flags-best-practices/>
