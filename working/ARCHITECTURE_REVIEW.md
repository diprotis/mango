# Mango — Architecture review & gap analysis

- **Date:** 2026-06-28 · **Scope:** the as-built backend + the 18 planning specs (`working/0008–0025`) · **Method:** 4 parallel research workflows (data model, S3 artifacts, catalog caching, cross-cutting sweep), each grounded by reading the current code.

## How to read this

This answers your three concerns with concrete proposed designs, then surfaces the
**other** gaps the architecture has that no current spec covers. It proposes a
numbered backlog (`0026+`) **for your review — none of these specs are drafted
yet.** Tell me which to write and I'll produce them at the same implementation
grade as 0008–0025.

---

## 1. Current architecture (as-built, verified today)

- **One DynamoDB table** (`PK`/`SK` + a single `GSI1`, on-demand, PITR+RETAIN in prod) holds: `USER#<sub>/PROFILE`, `/PROGRESS` (aggregate ints only), `/BOOK#<id>` (library, GSI1 by `ADDED#<ts>`), `/REFLECTION#<ts>`, `/ROADMAPJOB#<jobId>`; plus `BOOK#<id>/META`. `BOOK#<id>/ROADMAP`, `ACTIVITY#<date>`, `ACHV#<key>` are **documented but never written.**
- **Product S3 bucket**: only `books/<id>.txt` (full text) and `users/<sub>/…` (purged by `DELETE /v1/me`, which also deletes the Cognito user).
- **Separate analytics substrate** (`AnalyticsStack`): S3 lake + Firehose→Glue `events` table + `MangoFeatures-<stage>` online table — **producers/consumers unbuilt**.
- **Roadmap generation is async**: `POST /v1/roadmaps/generate` → persist job → `lambda.invoke(Event)` the `roadmap_worker` → `GET /v1/roadmaps/jobs/{id}` poll. Generation/ grading run on **Bedrock (Opus, IAM, no key)** via `shared/agent.py`. The roadmap is stored **as a JSON string on the user's job row** — not in S3, not shared per book.
- **Auth**: Cognito JWT authorizer server-side; **the app's sign-in flow is not shipped** (the single biggest blocker — see G3).
- **No** CloudWatch alarms/dashboards, X-Ray, WAF, AWS Budgets, rate-limiting, content moderation, or DLQ anywhere.

**The structural finding:** the 18 specs are excellent *product* specs (M3–M14 features). The *operational, safety, compliance, and platform* surface — the legacy roadmap's M13 (a11y/i18n) and M14 (observability/security/cost) epics — was never given specs. That's where most gaps cluster.

---

## 2. Your three concerns — findings & proposed designs

### 2.1 — User data + progress need real DDB tracking → **propose `0026`**

**Gap.** Server-side tracking is **aggregate-only**: `PROGRESS` holds six rollup ints; *which* lessons/exercises were done, *what* answer, *what* score, daily activity, achievements, and per-book journey state live **only in on-device SwiftData**. `grade_exercise` computes a score and **persists nothing**. The two tracking primitives your own `DATA_MODEL.md` names (`ACTIVITY#<date>`, `ACHV#<key>`) are documented but owned by no spec; `0014-progress-sync` explicitly syncs only the aggregate. A reinstall loses all granular history.

**Proposed design (`0026 — Server-side activity & achievement tracking`):**
- New items: `USER#<sub>/ACTIVITY#<date>` (atomic `ADD` daily rollups), `/ACHV#<key>` (idempotent unlock), `/LESSONDONE#<roadmapId>#<lessonId>` (the **trusted completion signal** 0023 credits-earn and 0021 ledger both need), extend the library item with `journeyState`+`confirmedMilestones` (0008), and **actually populate `BOOK#<id>/ROADMAP`**.
- Raw per-answer history is high-volume/immutable → send to the **events lake** (0015), not hot DDB.
- Add `version:int` to `PROGRESS` (optimistic lock) and a **TTL attribute** to the table (jobs currently leak — no TTL).
- `data_stack.py`: add **3 GSIs** the new specs need — `GSI_LEAGUE` (`LEAGUE#<weekId>#<tier>#<no>` / `XP#<zero-padded>#<sub>` for leaderboards), `GSI_CATALOG` (`REWARD#ACTIVE` / `<activeFrom>#<id>`), `GSI_DEVICE` (`DEVICE#ACTIVE` / `<lastSeen>#<sub>`). Stay single-table; keep `MangoFeatures` separate. Float-free throughout.
- On-device→server backfill on first launch (idempotent by date/key/lessonId).

### 2.2 — Roadmap assets + Q/A + responses in S3, with logging → **propose `0027`**

**Gap.** The roadmap lives only as a DDB JSON string; the **generation transcript** (prompt, model, raw output, token usage, latency, stop-reason), the **user's answers**, and the **grading responses** are all **ephemeral**. When a roadmap is low-quality or a grade looks wrong, there is nothing to inspect.

**Proposed design (`0027 — Generation artifact store & LLM observability`):**
- S3 layout, everything user-scoped under `users/<sub>/` (so `DELETE /v1/me` still purges it):
  `users/<sub>/roadmaps/<roadmapId>/roadmap.json` + `generation.json` (transcript) + `lessons/<lessonId>/<exerciseId>/{answer.json,grading.json}`; shared `books/<bookId>/{content.txt,provenance.json}`.
- Writers: the **worker** writes `roadmap.json`+transcript; **grade** writes answer+grading (needs a new *write-only, prefix-scoped* bucket grant — today `grade_fn` has none, and it must also start calling `user_id`); **content_parse** writes provenance. All best-effort (never fail the request), idempotent by id. Keep DDB `job.roadmap` as a **pointer** to dodge the 400 KB item limit.
- **Observability:** `jobId` as the correlation id across POST→worker→poll; structured JSON logs (model, latency, **token usage + estimated cost**, prompt hash, outcome); CloudWatch metric filters + **alarms on failure rate / `stop_reason=max_tokens` truncation / p99→60 s**; optional X-Ray on the async hop; a DDB **artifact index** (`USER#<sub>/ARTIFACT#…`) for "show everything generated for this user."
- Lifecycle: transcripts/answers → IA@30 d → Glacier@90 d. **Not** S3 Object-Lock (would break GDPR deletion).

### 2.3 — Cache per-book catalog activities, shared across users → **propose `0028`**

**Gap.** Generation is **per-user, async, uncached**; `BOOK#<id>/ROADMAP` is dead. 100 users opening *Meditations* = 100 ~27 s Opus generations of a near-identical artifact (and 100× credit burn under 0023). The catalog detail can't show "what activities are possible" without a generated artifact. Crucially, **the prompt is already profile-agnostic today** (profile is empty until 0020) — so a shared cache is essentially free quality-wise right now.

**Proposed design (`0028 — Shared per-book roadmap cache & activity templates`):**
- A **shared, versioned activity template** per catalog book: `BOOK#<id>/ROADMAP#latest` (DDB pointer + lightweight `outline`) + `ROADMAP#v<ver>` with the full roadmap in S3 (`templates/<bookId>/<ver>.json`). Cache key = `sha256(promptVersion + modelId + excerptHash)`.
- **Single-flight lock** (DDB conditional write) so concurrent first-opens trigger **one** generation; `lockExpiresAt` prevents a wedged book.
- **Population:** lazy on first start + a **batch pre-warm** Lambda over the 100-book catalog (0009) so it ships warm.
- **Public `GET /v1/catalog/{id}/activities`** (outline) behind **CloudFront**; `POST /v1/roadmaps/generate` becomes cache-aware — a hit **clones** the shared template into the user's job instantly (same `202 {jobId}` contract, **no iOS change**).
- **Boundary:** viewing + cloning the shared base = **free**; personalization (0020) is a thin **personalize-on-clone** layer (not in-prompt), so the cache stays ~100% hot, and **only a true personalized re-gen costs credits** (resolves the 0020⇄0023 tension). Requires extending `response.ok()` to set `Cache-Control`.

> These three are the highest *product* leverage and reinforce each other (0027's S3 layout hosts 0028's templates; 0026's completion signal feeds credits/leagues).

---

## 3. Cross-cutting gaps not covered by any spec

Condensed coverage read (full matrix in the workflow output). **Severity:** 🔴 Critical · 🟠 High · 🟡 Medium.

| # | Gap | Sev | Recommendation |
|---|---|---|---|
| G1 | **No API rate-limiting / denial-of-wallet protection.** `/content/parse`, `/exercises/grade` (Bedrock), `/events`, public `/catalog` are loop-callable. **WAF cannot attach to HTTP API v2.** | 🔴 | NEW `0029` — per-user/IP token-bucket (Lambda authorizer / DDB counter) + stage throttle + **AWS Budgets**; CloudFront+WAF only if fronting prod. |
| G2 | **No AI moderation / prompt-injection defense.** Raw user answers + book excerpts go straight into Bedrock; output shown unfiltered (self-help risk). | 🔴 | NEW `0030` — **Bedrock Guardrails** (input+output), tag user/book text, denied medical topics, standing **not-medical-advice + crisis** disclaimer. |
| G3 | **App sign-in not shipped.** Gates 0014/0020/0021/0023/0024/0025 — the whole server-side half. | 🔴 | **Promote `0019`** to "ship the sign-in client + token storage + `APIClient` Authorization now" (Hosted-UI interim if native slips). Sequence first. |
| G4 | **No COPPA / age-gating** for a gamified app selling credits + redeemable rewards (FTC focus; Apr 2026 deadline). | 🔴 | NEW `0031` — neutral DOB age gate; under-13 → block monetization/social/push or parental consent. Blocks 0023/0024 to prod. Needs counsel. |
| G5 | **No observability:** zero alarms/dashboards/X-Ray; **no Bedrock cost monitoring.** | 🟠 | NEW `0032` — CloudWatch dashboards+alarms per stack, **Bedrock token/cost metric + Budgets alert**, structured-log standard. |
| G6/G7 | **Async worker has no DLQ/retry/idempotency; jobs no TTL; no Bedrock backoff.** | 🟠 | Fold into `0032` — SQS DLQ + bounded retry + worker idempotency + job TTL + throttling backoff. |
| G8 | **No GDPR/CCPA data export** (only deletion). `GAMIFICATION.md` even promises export. | 🟠 | NEW `0033` — `GET /v1/me/export` (zip/JSON). |
| G9 | **Analytics-lake per-user deletion gap** (events + `MangoFeatures` not purged on delete). | 🟠 | Fold into `0033` — per-user tombstones / partition-rewrite + `MangoFeatures` row delete; enforce non-sensitive `props` until then. |
| G10 | **No admin/ops console** (catalog curation, moderation queue, support lookups, credit/refund `admin_adjust`). | 🟠 | NEW `0034` — minimal internal authenticated tooling. |
| G11 | **No feature flags / remote config** (server kill-switch / dark-launch). | 🟡 | NEW `0035` — `GET /v1/config` from DDB. |
| G12 | **No A/B experimentation** (the 0008/0010/0013 bets are unmeasured). | 🟡 | Fold into `0020` (feature store buckets) + G11. |
| G13 | **No i18n/localization** foundation (string catalog). | 🟡 | NEW `0036` — localization foundation (plumbing before translating). |
| G15 | **No transactional email** (receipts, refunds, sweepstakes winners, security). 0025 is push/local only. | 🟡 | NEW `0037` — SES transactional email (channel-extends 0025). |
| G14/G16–G20 | a11y audit · backup/DR runbook (RPO/RTO) · standardized error envelope+pagination+API-versioning · load testing · prompt-version/eval harness · web-landing+support. | 🟡 | Ops/QA tasks or fold into 0022 / 0032 / 0030. |

---

## 4. Proposed new spec backlog (for your review)

| # | Spec (proposed) | Addresses | Priority | Depends on |
|---|---|---|---|---|
| 0026 | Server-side activity & achievement tracking | Concern #1 | Now | sign-in; pairs 0014; unblocks 0021/0023 |
| 0027 | Generation artifact store & LLM observability | Concern #2 | Now | 0026, 0028 |
| 0028 | Shared per-book roadmap cache & activity templates | Concern #3 | Now (with 0009) | 0008, 0009; precedes 0020 |
| 0029 | Edge protection & request rate-limiting | G1 | Before scale | — |
| 0030 | AI safety: Guardrails + input tagging + disclaimers | G2 | Before scale | — |
| 0031 | Age assurance & COPPA/kids compliance | G4 | Before monetize | counsel; blocks 0023/0024 |
| 0032 | Observability, cost guardrails & worker reliability | G5/G6/G7 | Before scale | — |
| 0033 | Data export (DSAR) + analytics-lake deletion | G8/G9 | High | 0015 |
| 0034 | Admin & support console (internal) | G10 | High | 0026 |
| 0035 | Remote config & kill-switches | G11 | Medium | — |
| 0036 | Localization foundation | G13 | Medium | — |
| 0037 | Transactional email (SES) | G15 | Medium | 0025 |
| — | Promote **0019** → ship sign-in client now | G3 | **First** | — |
| — | Fold A/B (G12)→0020; a11y (G14)→0022; DR/API/load/eval/web (G16–G20)→ ops tasks | — | — | — |

## 5. Recommended sequencing

1. **Unblock everything:** ship sign-in (promote **0019**).
2. **Before any real traffic / monetization:** **0029** (rate-limit + Budgets), **0030** (AI safety), **0031** (COPPA), **0032** (observability + worker DLQ/cost).
3. **Your three concerns (high product value):** **0026** tracking → **0028** catalog cache (land with 0009) → **0027** artifacts/observability.
4. **Compliance + ops:** **0033** export/deletion, **0034** admin console.
5. **Then:** 0035 flags, 0036 i18n, 0037 email, and the folded ops tasks.

## 6. What I need from you

Tell me which to draft into full specs. Sensible default: **draft 0026, 0027, 0028 now** (your three concerns), **promote 0019**, and **draft 0029–0032** (the before-scale safety/ops cluster) — leaving 0033–0037 as approved-but-later. I'll write whichever set you pick at full implementation grade and extend `INDEX.md`.
