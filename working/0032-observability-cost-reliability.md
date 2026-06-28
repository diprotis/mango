# 0032 — Observability, cost guardrails & worker reliability

- **Epic:** M14 · **Status:** Draft · **Owner:** unassigned · **Updated:** 2026-06-28
- **Reviewers:** Principal / SD / QA

## 1. Summary

The Mango backend ships with **zero operational instrumentation**: no CloudWatch
dashboards, no alarms, no X-Ray, no AWS Budgets, no Bedrock cost monitoring, and the
async roadmap path has **no DLQ, no bounded retry, no idempotency, no job TTL, and no
Bedrock throttling backoff** (`ARCHITECTURE_REVIEW.md` §1, §3 G5/G6/G7). Today the only
failure signal is `roadmap_worker` raising `ValueError` into raw Lambda logs and
`mark_failed` writing an `error` string onto the job row; a wedged or throttled
generation simply **vanishes** (the user polls a job that never leaves `pending`), and a
runaway or compromised client could run an **unbounded, unobserved Bedrock bill**. This
spec makes the backend **operable, cost-bounded, and reliable in production**. It adds,
all in CDK + stdlib/boto3: **(a)** a **per-stack CloudWatch dashboard + alarm set** —
Lambda errors / throttles / duration-p99, API Gateway 4xx/5xx, DynamoDB throttles, **DLQ
depth**, and a **roadmap-generation failure-rate** alarm — every alarm wired to an **SNS
ops topic**; **(b)** a **structured-log standard** (one JSON line per request/model call,
keyed by the `jobId`/request correlation id) that *consumes* the per-generation
`llm_call` logs and `Mango/Generation` metrics defined by [`0027`] rather than
re-emitting them, plus the **CloudWatch EMF** option for first-class custom metrics; **(c)**
**optional X-Ray active tracing** on the async `POST → roadmap_worker` hop (flag-gated);
**(d)** **Bedrock cost monitoring** — an **AWS Budgets** cost budget with the **AWS
Marketplace** billing dimension (the only way to alert on third-party Claude-on-Bedrock
charges, since **Cost Anomaly Detection does not cover Marketplace LLMs**), a **Cost
Anomaly Detection** monitor for the rest of the AWS spend, and a CloudWatch alarm on the
estimated-token-cost metric from [`0027`] — the **denial-of-wallet backstop** (cross-ref
[`0029`]); and **(e)** **worker reliability**: an **SQS dead-letter queue** wired as the
`roadmap_worker`'s **on-failure destination** with **`maximumRetryAttempts` + a max event
age**, **worker idempotency** (skip generation if the job is already `complete`), a **TTL
attribute** on `ROADMAPJOB#` items (and the table generally), and a **Bedrock
exponential-backoff-with-jitter** retry wrapper in `shared/agent.py` for
`ThrottlingException`/transient errors. We **defer Step Functions orchestration to
[`0038`]** but note exactly which of these guardrails fold into that state machine when it
lands. The work is backend/infra-only; **no iOS change** is required (the poll contract is
unchanged) and the offline/Mock first-run path is untouched.

This spec is the **operational umbrella** for the M14 cluster. It **does not** own
per-generation artifact logging or the `Mango/Generation` metric *definitions* — those are
[`0027`]'s (this spec **dashboards and alarms** them). It **does not** own request
rate-limiting or the credits backstop — those are [`0029`]'s (this spec owns the **Budgets +
cost alarm** that [`0029`] cross-references). It **does not** build the agentic pipeline —
that is [`0038`] (which inherits this spec's DLQ/idempotency/TTL/backoff posture, applied to
the Step Functions state machine instead of the single worker Lambda).

## 2. Goals / Non-goals

- **Goals:**
  - **Per-stack CloudWatch dashboards** (CDK-authored, one per environment) graphing the
    fleet: each Lambda's Invocations / Errors / Throttles / Duration-p99 / Concurrency,
    API Gateway request count / latency / 4xx / 5xx, DynamoDB consumed capacity +
    **throttled requests**, Firehose delivery, the **DLQ visible-message count**, and the
    [`0027`] generation metrics (`GenerationFailures`, `Truncations`,
    `GenerationLatencyMs`, `GenerationCostMicroUsd`).
  - **A curated alarm set** wired to an **SNS ops topic** (email/chat subscribers per
    stage): Lambda **error-rate** (metric-math % over a window) and **throttles** on the
    hot functions; API Gateway **5xx** (and elevated 4xx); DynamoDB **`ThrottledRequests`/
    `UserErrors`**; **DLQ depth > 0** (a failed roadmap job landed); **roadmap-generation
    failure-rate** (consuming [`0027`]'s `GenerationFailures`); **p99 generation latency**
    approaching the worker budget; and the **Bedrock cost** alarm (FR-9).
  - **A structured-log standard**: a tiny `shared/logs.py` emitting **one JSON line** per
    request and per model call — `requestId`/`jobId` correlation id, `route`, `uid`,
    `stage`, `latencyMs`, `outcome`, and (for model calls, **already emitted by [`0027`]**)
    `modelId`/tokens/`estCostMicroUsd`/`stopReason` — so logs are queryable in CloudWatch
    Logs Insights and **metric-filterable**. Document **CloudWatch EMF** as the path to
    promote any of these JSON fields to a first-class metric without a `PutMetricData`
    call.
  - **Optional X-Ray active tracing** on the async hop (`roadmap_fn` → `roadmap_worker_fn`,
    with a subsegment around the Bedrock `invoke_model`), **flag-gated** and off by default
    (coordinated with [`0027`] FR-10 so the two specs don't both toggle it).
  - **Bedrock cost monitoring (denial-of-wallet backstop):** an **`AWS::Budgets::Budget`**
    (monthly, **Marketplace billing dimension** included) + thresholds → SNS; an **AWS Cost
    Anomaly Detection** monitor (AWS-service dimension) for non-Marketplace spend; and a
    CloudWatch **alarm** on the estimated per-token cost metric ([`0027`]'s
    `GenerationCostMicroUsd`) and/or Bedrock's `Invocations`/`InputTokenCount` runtime
    metrics. **Single source of truth** for the Budget construct lives **here**; [`0029`]
    cross-references it.
  - **Worker reliability — DLQ + on-failure destination + bounded retry.** Give
    `roadmap_worker_fn` an **`onFailure` SQS destination** (a new DLQ) and set
    **`retryAttempts` (`maximumRetryAttempts`) + `maxEventAge`** on its async invoke config,
    so an exhausted/expired generation lands a record (with the failure context) instead of
    disappearing; alarm on the DLQ.
  - **Worker idempotency.** The worker MUST **no-op when the job is already `complete`**
    (re-delivery / retry / replay safe), and the failure path MUST be safe to re-run.
  - **Job TTL.** Add a numeric **`expiresAt` TTL attribute** to `ROADMAPJOB#` items (and
    enable DynamoDB **TTL** on the table) so completed/failed/abandoned jobs self-reap (they
    leak today). Coordinated with the [`0029`] rate-counter TTL and [`0026`] (same table
    setting).
  - **Bedrock throttling backoff.** Wrap the `invoke_model` call in `shared/agent.py` with
    **exponential backoff + full jitter**, retrying only **transient** errors
    (`ThrottlingException`, `ModelTimeoutException`, `ServiceUnavailableException`,
    `(Internal)ServerException`) and **never** client errors (`ValidationException`,
    `AccessDeniedException`), bounded by attempt count + the Lambda timeout.
  - **A `MANGO_OBSERVABILITY` config block** (per stage) for alarm thresholds, the budget
    amount + subscribers, the DLQ/retry knobs, and the X-Ray + Cost-Anomaly flags, so each
    environment differs without code changes.
  - Preserve every repo invariant: **offline-first** (first run unaffected), **Bedrock-only
    AI via IAM** (no key), **least-privilege IAM** (the new DLQ/SNS/Budgets grants are
    scoped; `grade_fn` still gets **no** table access), **no `float` in DynamoDB** (TTL is an
    int epoch-seconds), **stdlib + boto3 only** (no packaging, no new deps), **no new
    third-party iOS deps** (none needed), black (100) + flake8 (120), `cdk synth` + `pytest`
    pass offline.
- **Non-goals:**
  - **Per-generation artifact persistence + the `llm_call` log line + the `Mango/Generation`
    metric *definitions*** — those are [`0027`]. This spec **consumes** them (dashboards +
    alarms) and standardizes the *request-level* log around the same correlation id; it does
    **not** re-emit the generation metrics or re-write the artifact store.
  - **Request rate-limiting, the token bucket, route/stage throttles, the 429 contract, and
    CloudFront/WAF** — those are [`0029`]. This spec owns only the **Budgets + Bedrock-cost
    alarm + SNS topic** that [`0029`] reuses; the request-layer DoW controls live there.
  - **The Step Functions multi-agent pipeline** and its per-stage retries/idempotency/state
    trace — [`0038`]. This spec hardens the **as-built single worker Lambda**; §6.8 + §10
    record exactly what carries over to (or is superseded by) the state machine so 0038 does
    not re-litigate DLQ/TTL/backoff.
  - **AI safety / Guardrails / moderation** — [`0030`].
  - **A custom metrics/observability vendor** (Datadog, etc.). CloudWatch + X-Ray only
    (stdlib/boto3, no extra infra).
  - **Synthetic canaries / load testing / a full DR runbook (RPO/RTO)** — noted as follow-up
    ops tasks in `ARCHITECTURE_REVIEW.md` §3 (G16–G18); this spec adds the *signals* a load
    test would watch but does not build the canary.
  - **A user-facing status page** — internal observability only.

## 3. Background & context

**Why now.** This expands review gaps **G5/G6/G7** of `working/ARCHITECTURE_REVIEW.md` §3:
*"G5 — No observability: zero alarms/dashboards/X-Ray; no Bedrock cost monitoring (🟠
High). G6/G7 — Async worker has no DLQ/retry/idempotency; jobs no TTL; no Bedrock backoff
(🟠 High) → Fold into 0032 — SQS DLQ + bounded retry + worker idempotency + job TTL +
throttling backoff."* The review sequences 0032 **before any real traffic / monetization**
(§5: *"Before any real traffic / monetization: 0029 (rate-limit + Budgets), 0030 (AI
safety), 0031 (COPPA), 0032 (observability + worker DLQ/cost)."*). The moment a signed-in
build (G3 / [`0019`]) drives real generation traffic, we need to **see failures, bound the
bill, and not silently drop jobs** — none of which is possible today.

**As-built backend (verified by reading the code).**

- **Async roadmap path.** `POST /v1/roadmaps/generate`
  (`backend/src/handlers/generate_roadmap.py`) persists a pending job
  (`roadmap_jobs.create_pending`: `PK=USER#<uid>`, `SK=ROADMAPJOB#<jobId>`), then
  `lambda_client().invoke(FunctionName=worker, InvocationType="Event", Payload={uid,
  jobId})` and returns `202 {jobId,status:"pending"}`. The worker
  (`backend/src/handlers/roadmap_worker.py`) loads inputs, calls
  `agent.generate_roadmap(...)`, and `mark_complete`/`mark_failed`. **The async invoke has
  no `onFailure`/`onSuccess` destination and no DLQ; the worker has the default
  async-retry behavior (2 retries) but those retries are silent and there is no place a
  finally-failed event lands.**
- **No idempotency.** `roadmap_worker.handler` regenerates unconditionally on every
  delivery — it never checks whether the job is already `complete`. Lambda async invokes
  are **at-least-once**, so a redelivery (or any future manual replay) **re-bills a full
  Opus generation** and overwrites the result.
- **Jobs leak (no TTL).** `roadmap_jobs.create_pending` writes `createdAt` but **no TTL
  attribute**, and `data_stack.py`'s table has **no `time_to_live_attribute`**. Completed,
  failed, and abandoned (`pending`-forever) job rows accumulate indefinitely
  (`ARCHITECTURE_REVIEW.md` §2.1: *"jobs currently leak — no TTL"*).
- **No Bedrock backoff.** `shared/agent.py` `_invoke` makes **one** `invoke_model` call;
  the only retry is the *thinking-block-rejection* fallback (catch `ClientError` → retry
  **once** with a plain body). A `ThrottlingException` (HTTP 429 — Bedrock enforces per-
  model RPM/TPM quotas) is **not** distinguished and **not** backed off; it propagates as
  a generation failure.
- **No observability anywhere.** `ARCHITECTURE_REVIEW.md` §1/§3 G5: *"No CloudWatch
  alarms/dashboards, X-Ray, WAF, AWS Budgets, rate-limiting, content moderation, or DLQ
  anywhere."* There is no dashboard, no alarm, no SNS ops topic, and no cost monitoring.
  Lambda/API Gateway/DynamoDB publish their **standard** metrics to CloudWatch
  automatically, but **nothing alarms on them**.
- **Stacks & wiring.** `MangoStage` (`stage.py`) composes `DataStack` (single table +
  content bucket), `AuthStack` (Cognito), `AiStack` (optional secret), `AnalyticsStack`
  (lake + Firehose + features table), and `ApiStack` (the HTTP API + all Lambdas + grants).
  `ApiStack.make_fn` builds every Lambda; the grant loop deliberately **excludes `grade_fn`**
  from table access (least-privilege). The Bedrock policy is scoped to
  `bedrock:InvokeModel*` on foundation-model + inference-profile ARNs.
- **Invariants** (`CLAUDE.md`): Bedrock via IAM (no key); app runs fully offline on first
  launch; **no `float`** reaches the DynamoDB resource API (coerce to int / JSON string);
  Lambdas **stdlib + boto3 only**; least-privilege IAM; black (100) + flake8 (120); `pytest`
  (moto; Bedrock monkeypatched) **and** `cdk synth -c stage=beta` must pass offline.

**What [`0027`] already provides (and this spec must not duplicate).** [`0027`] adds, at the
**model boundary** (`agent.py` returning an `InvokeResult` with `stop_reason`/`usage`/
`latencyMs`/`modelId`): a per-call **`llm_call` JSON log** keyed by `jobId`
(`modelId`/`latencyMs`/`inputTokens`/`outputTokens`/`estCostMicroUsd`/`promptHash`/
`stopReason`/`outcome`); **CloudWatch metric filters + alarms** in a shared
**`Mango/Generation`** namespace (`GenerationFailures`, `Truncations`,
`GenerationLatencyMs`, plus a `GenerationCostMicroUsd` metric it emits but does **not**
alarm); and an `est_cost_micro_usd(model_id, in, out)` price-table helper. **This spec
consumes those** — it puts them on the dashboard, adds the **fleet** alarms 0027 doesn't
(API/DDB/DLQ/throttle), owns the **cost Budget + Cost-Anomaly** that 0027 explicitly leaves
to it (0027 §6.4: *"0032 builds the dashboard that graphs them and the AWS Budgets alert"*),
and standardizes the **request-level** (not just model-call) log line. The `agent.py`
backoff wrapper (FR-11) is layered **inside** 0027's `_invoke` capture so both land
together (§9 coordination).

**Related specs.** [`0027`] (generation artifacts + the `llm_call` log + `Mango/Generation`
metrics this spec dashboards/alarms; the `agent.py` boundary this spec's backoff wraps).
[`0029`] (rate-limit + credits; **this spec owns the Budgets/cost alarm it cross-refs**, and
the table **TTL** both enable). [`0026`] (server-side tracking; same table TTL; the job-row
lifecycle). [`0038`] (agentic Step Functions engine — inherits the DLQ/idempotency/TTL/
backoff posture, applied to the state machine). `ARCHITECTURE_REVIEW.md` §1 (as-built), §3
G5/G6/G7 (the gaps), §5 (sequencing). `docs/OPERATIONS.md` (the SOPs this spec extends with
an alarm/DLQ/cost runbook).

## 4. User stories

- As an **on-call engineer**, when generation starts failing, a CloudWatch alarm pages the
  **SNS ops topic** and I open the stage **dashboard** to see *which* Lambda is erroring,
  whether it's Bedrock throttling vs a code error, the DLQ depth, and the p99 — instead of
  discovering it from a user complaint.
- As an **on-call engineer**, a **wedged or throttled roadmap job no longer vanishes**: the
  failed async event lands in the **DLQ** (with the failure context), the **DLQ-depth alarm**
  fires, and I can inspect/replay it — and because the worker is **idempotent**, replaying
  it (or a Lambda auto-retry) won't double-bill a generation or clobber a good result.
- As a **FinOps / cost owner**, an **AWS Budget** with the **Marketplace** dimension alerts
  me when Claude-on-Bedrock spend crosses a threshold (the one signal Cost Anomaly Detection
  can't give me for third-party LLMs), and a **cost-anomaly** monitor catches unusual
  non-Marketplace spend — so a denial-of-wallet event is caught on the **alert**, not the
  invoice.
- As a **platform engineer**, every request and model call emits a **single structured JSON
  log line** with the **same correlation id** (`jobId`/`requestId`), so I can trace a single
  user's generation end-to-end in **Logs Insights**, and I can promote any field to a metric
  via **EMF** without new `PutMetricData` plumbing.
- As an **SRE doing a latency investigation**, I flip on **X-Ray** for a stage and see the
  `POST → worker → Bedrock invoke_model` async hop as a trace, isolating Bedrock latency from
  Lambda overhead — then flip it back off to avoid the cost.
- As a **Bedrock integrator**, transient **`ThrottlingException`s retry automatically with
  exponential backoff + jitter** (bounded by the worker timeout) instead of failing the job
  on the first 429, while **client errors fail fast** (no pointless retries).
- As a **product owner**, a **roadmap-generation failure-rate** alarm tells me when a model/
  prompt change has degraded generation, with the [`0027`] `generation.json` transcript one
  `jobId` away for root-cause.
- As an **offline first-run user**, none of this touches me: the bundled sample + Mock AI run
  with **zero network**, no SNS/DLQ/Budgets/X-Ray in the loop (the `CLAUDE.md` offline
  invariant holds).

## 5. Requirements

### 5.1 Functional — observability

- **FR-1 (per-stack dashboard).** CDK MUST create **one CloudWatch dashboard per
  environment** graphing, at minimum: per-Lambda **Invocations / Errors / Throttles /
  Duration (p99) / ConcurrentExecutions**; **API Gateway** (`AWS/ApiGateway`) request
  count, **4xx**, **5xx**, integration latency, p99 latency; **DynamoDB**
  (`AWS/DynamoDB`) consumed RCU/WCU + **`ThrottledRequests`/`ReadThrottleEvents`/
  `WriteThrottleEvents`** + `UserErrors`; **Firehose** delivery success; the **DLQ**
  `ApproximateNumberOfMessagesVisible`; and the [`0027`] **`Mango/Generation`** metrics
  (`GenerationFailures`, `Truncations`, `GenerationLatencyMs`, `GenerationCostMicroUsd`).
  *(Verify the `AWS::CloudWatch::Dashboard` in `cdk synth`.)*
- **FR-2 (SNS ops topic).** CDK MUST create a per-stage **SNS topic** (`mango-ops-<stage>`)
  with config-driven subscribers (email and/or HTTPS/chat). **Every alarm** action (and the
  Budgets/anomaly notifications, FR-9/FR-10) targets this topic. *(Verify the
  `AWS::SNS::Topic` + subscriptions + alarm `AlarmActions` in synth.)*
- **FR-3 (Lambda alarms).** For the hot functions (`roadmap_worker_fn`, `roadmap_fn`,
  `grade_fn`, `parse_fn`, and a configurable set), CDK MUST create alarms on: **error-rate**
  (a metric-math expression `Errors/Invocations` ≥ threshold over N periods, so low-traffic
  single errors don't page) **and** **Throttles ≥ 1** sustained. Thresholds are
  config-driven per stage. *(Synth assertion.)*
- **FR-4 (API Gateway alarms).** CDK MUST alarm on **5xx rate** (server faults) and an
  elevated **4xx rate** (possible abuse/regression — complements [`0029`]'s 429 abuse
  alarm), over a window. *(Synth assertion.)*
- **FR-5 (DynamoDB alarm).** CDK MUST alarm on the table's **throttled/`UserErrors`** signal
  (the on-demand table should rarely throttle, so any sustained throttling is notable).
  *(Synth assertion.)*
- **FR-6 (roadmap-failure alarm).** CDK MUST alarm on the **roadmap-generation failure
  rate**, consuming [`0027`]'s **`GenerationFailures`** metric (failure **rate** over a
  window, or absolute count where rate is noisy at low volume); and on **p99
  `GenerationLatencyMs`** approaching the worker 60 s budget. If [`0027`] has not yet
  landed, this spec MAY emit a minimal `GenerationFailures` metric filter itself as an
  interim (flagged for removal once 0027 owns it) — **but the steady-state owner of the
  metric is 0027**. *(Synth assertion; coordination note §9.)*
- **FR-7 (structured-log standard).** A `shared/logs.py` helper MUST emit **one JSON line**
  per request (from each handler) and per model call, including a **correlation id**
  (`jobId` on the roadmap path; otherwise `requestId` = `event.requestContext.requestId`),
  `route`/`stage`, `uid` (when resolved), `latencyMs`, `outcome`, and an `evt` tag. The
  model-call line is **the [`0027`] `llm_call` line** (this spec does not duplicate it; it
  *standardizes the request line around the same id and shape*). Logging MUST be
  **best-effort** (never throw to the caller). *(Unit: log-shape test.)*
- **FR-8 (EMF option + Logs Insights).** The structured-log standard MUST be **EMF-
  compatible**: §6.3 documents (and provides a helper for) emitting a field as a
  first-class **CloudWatch metric via the embedded metric format** (no synchronous
  `PutMetricData`, no throttling concern) for any metric we'd rather not derive from a log
  metric-filter, and documents the canonical **Logs Insights** queries for the correlation
  id. *(Doc + a unit test asserting a valid EMF `_aws` envelope when EMF mode is on.)*
- **FR-9 (Bedrock cost monitoring — the DoW backstop).** CDK MUST create, per stage: an
  **`AWS::Budgets::Budget`** (cost, **monthly**) whose `CostFilters` **include the AWS
  Marketplace billing entity** (so **third-party Claude-on-Bedrock charges are captured** —
  Cost Anomaly Detection does **not** monitor Marketplace LLMs, §12), at a config-driven
  `amount` with notification thresholds (e.g. 50/80/100% actual + a forecasted-overage
  alert) → the SNS ops topic; **and** a CloudWatch **alarm** on Bedrock cost/usage — at
  minimum on [`0027`]'s `GenerationCostMicroUsd` (sum over a window) and/or the Bedrock
  runtime `Invocations`/`InputTokenCount` metrics. This is the **single source of truth**
  for the Budget; [`0029`] FR-10/FR-11 cross-reference it. *(Synth assertion
  `test_synth_budget_marketplace_and_cost_alarm`.)*
- **FR-10 (Cost Anomaly Detection).** CDK SHOULD create an **AWS Cost Anomaly Detection**
  monitor (`AWS::CE::AnomalyMonitor`, AWS-services dimension) + subscription
  (`AWS::CE::AnomalySubscription`) → SNS, **flag-gated** per stage, to catch unusual
  **non-Marketplace** AWS spend (Lambda/DDB/S3/Firehose). The spec MUST **explicitly note**
  the Marketplace-LLM gap that makes the FR-9 Budget the authoritative Bedrock-spend signal.
  *(Synth assertion when enabled.)*
- **FR-11 (optional X-Ray).** The async hop `roadmap_fn` → `roadmap_worker_fn` SHOULD be
  traceable via **active tracing** (`tracing=Active`), with an optional **subsegment around
  `invoke_model`** in `agent.py`, **behind a single config flag** shared with [`0027`]
  FR-10 (one flag, not two). Off by default. When on, the execution role gains the X-Ray
  write permissions (CDK adds them automatically for `Tracing.ACTIVE`). *(Synth assertion
  that tracing is `Active` only when the flag is set.)*

### 5.2 Functional — worker reliability

- **FR-12 (DLQ + on-failure destination).** `roadmap_worker_fn` MUST have an **`onFailure`
  destination** set to a **new SQS dead-letter queue** (`mango-roadmap-dlq-<stage>`), so a
  generation that fails **all** async retries (or exceeds the max event age) lands a record
  — including the failure context (Lambda destinations include the response/stack trace) —
  instead of vanishing. The DLQ MUST itself be durable (a redrive-from-DLQ path is noted for
  ops). *(Synth assertion `test_synth_worker_onfailure_dlq`.)*
- **FR-13 (bounded async retry).** The worker's **async invoke config** MUST set
  **`retryAttempts` (`maximumRetryAttempts`, 0–2; recommend the default **2**)** and a
  **`maxEventAge`** (`maximumEventAge`, recommend a small bound so a stuck event doesn't
  retry for the 6 h default) — config-driven. *(Synth assertion of the
  `AWS::Lambda::EventInvokeConfig`.)*
- **FR-14 (worker idempotency).** `roadmap_worker.handler` MUST **load the job first and
  return a no-op when its status is already `complete`** (re-delivery / retry / manual
  replay safe), and the `mark_failed` path MUST be safe to re-run (idempotent write). A
  redelivered event MUST NOT trigger a second Bedrock generation for an already-completed
  job. *(Unit: `test_worker_skips_completed_job`.)*
- **FR-15 (DLQ-depth alarm).** CDK MUST alarm on the DLQ's
  **`ApproximateNumberOfMessagesVisible` > 0** (any failed-and-exhausted roadmap job is an
  ops event) → SNS. *(Synth assertion.)*
- **FR-16 (job TTL).** `ROADMAPJOB#` items MUST carry a numeric **`expiresAt`** attribute
  (Unix **epoch-seconds**, an **int** — not a float) set at `create_pending` (e.g. now +
  N days, config-driven), and the DynamoDB table MUST have **TTL enabled** on that
  attribute, so finished/abandoned jobs self-reap. The TTL setting is **coordinated** with
  [`0029`] (rate-counter items) and [`0026`] (same single table) — whoever lands first
  enables the table TTL; the others assert it. *(Unit: `test_create_pending_sets_ttl`;
  synth assertion `test_table_ttl_enabled`.)*
- **FR-17 (Bedrock throttling backoff).** `shared/agent.py` MUST retry the `invoke_model`
  call with **exponential backoff + full jitter** on **transient** Bedrock errors —
  `ThrottlingException` (HTTP 429), `ModelTimeoutException`, `ServiceUnavailableException`,
  `InternalServerException`/`ServiceException` — and MUST **not** retry **client** errors
  (`ValidationException`, `AccessDeniedException`, `ResourceNotFoundException`). The retry
  is **bounded** (config-driven max attempts + a cap that respects the Lambda timeout), and
  the existing **thinking-block-rejection** retry (plain-body fallback) MUST be preserved
  and composed sensibly with the backoff (a `ValidationException` from the thinking body is
  a **client** error → the existing one-shot plain-body retry handles it, **not** the
  backoff loop). A botocore **`Config(retries=…)` adaptive/standard mode** MAY be used in
  addition, but the explicit, unit-testable backoff is the contract. *(Unit:
  `test_invoke_backoff_on_throttling`, `test_invoke_no_retry_on_validation`.)*

### 5.3 Non-functional

- **NFR-1 (best-effort observability).** No log line, metric emit, or dashboard/alarm
  evaluation may affect a request's status code or body. `shared/logs.py` swallows its own
  exceptions (mirrors `firehose.put_event` returning `False`). The reliability changes
  (DLQ/idempotency/TTL/backoff) are the only ones that change runtime behavior, and each is
  **fail-safe** (idempotency only *adds* a guard; backoff only *adds* bounded retries; TTL
  only *adds* an attribute).
- **NFR-2 (float-free).** The TTL `expiresAt` and every numeric metric/threshold persisted
  to DynamoDB is an **int**. Cost is handled as **int micro-USD** ([`0027`]'s
  `estCostMicroUsd`); no `float` reaches the DynamoDB resource API (invariant).
- **NFR-3 (least privilege).** The new grants are scoped: `roadmap_worker_fn` gets
  `sqs:SendMessage` on **only** the DLQ (CDK wires this automatically for an `onFailure`
  SqsDestination); alarms only **publish** to the **one** SNS ops topic; Budgets/Cost-
  Anomaly create no Lambda permissions. **`grade_fn` still gets no table access** (the
  observability work adds none). No wildcard `Resource:"*"` is introduced except where AWS
  requires it (e.g. X-Ray `PutTraceSegments`, which CDK scopes via the managed policy).
  *(Synth IAM inspection.)*
- **NFR-4 (cost of the controls).** Dashboards/alarms/SNS/Budgets/Cost-Anomaly are
  near-free; the DLQ is a standard SQS queue (pennies); EMF/log volume is bounded (one line
  per request/call). X-Ray is **off by default** (sampling cost only when enabled). The
  controls cost **orders of magnitude less** than the single runaway Opus bill they prevent.
- **NFR-5 (offline-first preserved).** Backend/infra only. First launch (Mock AI + bundled
  sample) makes **no** network call and is **completely unaffected**; the worker/DLQ/alarms/
  Budgets engage only on the deployed `RemoteAIService` path (`CLAUDE.md`).
- **NFR-6 (stdlib + boto3; synth/test offline).** New runtime code (`shared/logs.py`, the
  `agent.py` backoff, the worker idempotency guard, the `roadmap_jobs` TTL) is **stdlib +
  boto3 only**. `cdk synth -c stage={dev,beta,prod}` (dashboard, alarms, SNS, DLQ, event-
  invoke config, Budget, table TTL) and `pytest` (moto for SQS/DDB; Bedrock monkeypatched;
  `time.sleep` patched for the backoff test) MUST pass **offline**. black (100) + flake8
  (120) clean.
- **NFR-7 (no iOS change).** The poll contract (`202 {jobId}` → `GET
  /v1/roadmaps/jobs/{jobId}`) is **unchanged**; a job that ultimately fails still surfaces
  via `status:"failed"` (now also captured in the DLQ for ops). No `DTOs.swift`/`openapi`
  change is required by this spec. (A DLQ-landed failure MAY, as a nicety, still write
  `mark_failed` so the poll reflects it — see §6.6.)
- **NFR-8 (testability).** The backoff schedule (`delay(attempt)`) and the transient-vs-
  client error classification are **pure, unit-tested** functions (mirrors the repo's
  `LevelCurve`/`StreakCalculator` preference). DLQ/TTL/idempotency are moto-tested; alarms/
  dashboards/Budgets are synth-asserted.

## 6. Design

### 6.1 Where it lives — a new `ObservabilityStack` (composed into `MangoStage`)

The dashboards, alarms, SNS topic, DLQ, Budget, and Cost-Anomaly monitor are a **new
`ObservabilityStack`** added to `MangoStage` (`stage.py`), constructed **after** the others
so it can reference their resources (Lambdas, table, API, Firehose) to build metrics and
alarms:

```python
# stage.py (sketch)
data      = DataStack(self, "Data", config=config)
auth      = AuthStack(self, "Auth", config=config)
ai        = AiStack(self, "Ai", config=config)
analytics = AnalyticsStack(self, "Analytics", config=config)
api       = ApiStack(self, "Api", config=config, table=data.table, bucket=data.bucket, ...)
ObservabilityStack(
    self, "Observability", config=config,
    table=data.table,
    functions=api.functions,          # NEW: ApiStack exposes its Lambdas (incl. the DLQ owner)
    http_api=api.http_api,            # NEW: expose for AWS/ApiGateway dimensions
    firehose_name=analytics.delivery_stream_name,
    roadmap_dlq=api.roadmap_dlq,      # the DLQ created in ApiStack (FR-12) — alarmed here
)
```

The **DLQ + the worker's `onFailure`/event-invoke config + the TTL attribute write** are the
runtime-adjacent pieces and live where the worker and table are defined (`ApiStack` /
`roadmap_jobs.py` / `data_stack.py`); the **dashboard/alarms/SNS/Budget/anomaly** are the
pure-observability pieces and live in `ObservabilityStack`. `ApiStack` is extended to
**expose** `self.functions` (a name→`Function` dict), `self.http_api`, and `self.roadmap_dlq`
so the new stack can build metrics without re-creating anything. (Alternative: put alarms in
`ApiStack` directly; a separate stack keeps `ApiStack` focused and lets observability be
toggled/owned independently — recommended, D-1.)

### 6.2 Dashboards & alarms (CDK, `aws_cloudwatch` + `aws_cloudwatch_actions`)

Built with the L2 `aws_cloudwatch` constructs (`Dashboard`, `GraphWidget`, `Alarm`,
`MathExpression`) and `aws_cloudwatch_actions.SnsAction(topic)`:

**Dashboard rows (per stage):**

| Row | Widgets | Source |
|---|---|---|
| **Lambda fleet** | per-fn Invocations, Errors, Throttles, Duration **p99**, ConcurrentExecutions | `fn.metric_invocations()/metric_errors()/metric_throttles()/metric_duration(statistic="p99")` |
| **API Gateway** | Count, 4xx, 5xx, IntegrationLatency, Latency **p99** | `AWS/ApiGateway` by `ApiId` |
| **DynamoDB** | Consumed RCU/WCU, **ReadThrottleEvents/WriteThrottleEvents**, UserErrors, SuccessfulRequestLatency | `table.metric_*` + `AWS/DynamoDB` |
| **Generation (0027)** | `GenerationFailures`, `Truncations`, `GenerationLatencyMs` p99, `GenerationCostMicroUsd` (sum) | `Mango/Generation` namespace (0027) |
| **Reliability & cost** | DLQ `ApproximateNumberOfMessagesVisible`, Firehose `DeliveryToS3.Success`, Bedrock `Invocations`/`InputTokenCount` | SQS/Firehose/`AWS/Bedrock` |

**Alarms → `SnsAction(ops_topic)`:**

| Alarm | Metric / expression | Default condition |
|---|---|---|
| Worker error-rate | `MathExpression("e/i", {e: worker.metric_errors(sum), i: worker.metric_invocations(sum)})` | ≥ **0.10** for 3×5 min (and ≥ a min-volume guard) |
| Worker throttles | `roadmap_worker_fn.metric_throttles(sum)` | ≥ **1** for 3×5 min |
| Grade/parse error-rate | same math per fn | ≥ **0.10** (config) |
| API 5xx | `AWS/ApiGateway 5xx` (sum) | ≥ **N** / 5 min |
| API 4xx (regression/abuse) | `AWS/ApiGateway 4xx` (sum) | ≥ **M** / 5 min (complements 0029) |
| DDB throttling | `Read/WriteThrottleEvents` (sum) | ≥ **1** sustained |
| **DLQ depth** (FR-15) | `dlq.metric_approximate_number_of_messages_visible(max)` | ≥ **1** |
| **Roadmap failure-rate** (FR-6) | `Mango/Generation:GenerationFailures` (rate or count) | ≥ threshold over 15 min |
| Generation p99 latency | `Mango/Generation:GenerationLatencyMs` p99 | ≥ **55 s** (→ 60 s budget) |
| **Bedrock cost** (FR-9) | `Mango/Generation:GenerationCostMicroUsd` (sum) and/or `AWS/Bedrock:Invocations` | ≥ config $/window |

All thresholds, periods, and evaluation counts come from `config["observability"]` per
stage (alert-but-rarely-page in dev/beta; tighter in prod). **Composite alarms** (e.g.
"worker error-rate **AND** DLQ depth") MAY reduce noise during a correlated incident (D-2).

### 6.3 Structured-log standard + EMF (`shared/logs.py`)

A tiny best-effort helper, used by handlers for the **request line** and reused by [`0027`]
for the **`llm_call` line** (one shape, one correlation id):

```python
# shared/logs.py — stdlib only; never raises
def log_event(evt: str, *, correlation_id: str, **fields) -> None:
    """Emit one structured JSON line to stdout (CloudWatch Logs)."""
    try:
        rec = {"evt": evt, "cid": correlation_id, "ts": _now_iso(), **fields}
        print(json.dumps(rec, separators=(",", ":"), default=str))
    except Exception:
        pass  # logging must never break a request (NFR-1)

def emf_metric(namespace, metrics: dict, dimensions: dict, **fields) -> None:
    """Emit a CloudWatch EMF line so `metrics` become first-class CW metrics
    with no PutMetricData call (CloudWatch Logs extracts them asynchronously)."""
    # builds the `_aws.CloudWatchMetrics` envelope per the EMF spec (§12)
```

- **Correlation id.** On the roadmap path it is the **`jobId`** (already threaded POST →
  worker via the `{uid,jobId}` event and onto the job row); elsewhere it is
  `event.requestContext.requestId`. Every handler logs **one** `request` line
  (`{evt:"request", cid, route, stage, uid?, latencyMs, status, outcome}`) on the way out.
- **Reuse, not duplication.** [`0027`]'s `log_generation(...)` emits the `llm_call` line
  using **this** helper (or an identical shape); this spec **owns the convention**
  (`evt`/`cid`/`ts` keys, JSON-single-line, best-effort) and the **request-level** line;
  0027 owns the **model-call** line's *fields*. The dashboards' metric filters and the Logs
  Insights queries key on `cid`.
- **EMF (FR-8).** For any value we'd rather have as a **native metric** than a log-derived
  one (e.g. a business KPI), `emf_metric(...)` writes the embedded-metric envelope so
  CloudWatch publishes it asynchronously — **no `PutMetricData` latency or throttling**
  (§12). The 0027 `Mango/Generation` metrics may be sourced **either** via metric-filters
  (0027's current design) **or** promoted to EMF; §9 records the choice (D-3: keep 0027's
  metric-filters as-is for v1; offer EMF as the documented path for new metrics).
- **Logs Insights queries** (documented in `OPERATIONS.md`): trace one generation
  (`fields @timestamp,@message | filter cid="<jobId>" | sort @timestamp`), failure triage
  (`filter evt="llm_call" and outcome="failed"`), cost rollup
  (`filter evt="llm_call" | stats sum(estCostMicroUsd) by bin(1h)`).

### 6.4 Bedrock cost monitoring (FR-9/FR-10) — the denial-of-wallet backstop

Three layers, **this spec the owner**, [`0029`] the cross-referencer:

1. **AWS Budgets (authoritative for Bedrock spend).** An `AWS::Budgets::Budget` (cost type,
   **monthly**) with `CostFilters` including the **AWS Marketplace** billing entity, because
   **Cost Anomaly Detection does not monitor third-party Marketplace LLMs** (Anthropic Claude
   on Bedrock) — **AWS Budgets is the documented way to alert on those charges** (§12).
   Notifications at 50/80/100% **actual** + a **forecasted** > 100% alert → the SNS ops
   topic (config subscribers). Per stage; the `amount` is config-driven.
2. **Cost Anomaly Detection (the rest of AWS spend).** An `AWS::CE::AnomalyMonitor`
   (DIMENSIONAL, `AWS_SERVICES`) + `AWS::CE::AnomalySubscription` → SNS, **flag-gated**,
   catching unusual Lambda/DDB/S3/Firehose spend. The spec **states the Marketplace gap**
   so no one mistakes anomaly detection for Bedrock-cost coverage.
3. **CloudWatch cost alarm (near-real-time).** Budgets data lags hours, so a CloudWatch
   **alarm** on [`0027`]'s `GenerationCostMicroUsd` (sum over a short window) and/or the
   Bedrock runtime `Invocations`/`InputTokenCount` gives a **faster** signal of a spend
   spike, wired to the same topic. (`0027` emits the cost metric but explicitly does **not**
   alarm it — this spec does.)

**Boundary with [`0029`].** [`0029`] FR-10/FR-11 list a Budget + Bedrock-cost alarm as part
of its DoW story but says the *deep* cost plumbing is 0032's. To avoid a **double Budget**,
**0032 creates the Budget + SNS + cost alarm**; [`0029`] references `obs.ops_topic` /
`obs.budget` rather than creating its own (or, if 0029 ships first, it creates a minimal
Budget that 0032 takes ownership of — recorded in both specs, D-4). The **request-layer**
limiter remains entirely 0029's.

### 6.5 Worker reliability — DLQ, retry, idempotency, TTL (FR-12/13/14/16)

**CDK (`ApiStack`):**

```python
# ApiStack — roadmap worker reliability (sketch)
self.roadmap_dlq = sqs.Queue(self, "RoadmapDlq",
    queue_name=f"mango-roadmap-dlq-{stage}",
    retention_period=Duration.days(14),
    enforce_ssl=True)
roadmap_worker_fn.configure_async_invoke(
    retry_attempts=config["observability"]["workerRetryAttempts"],   # 0–2 (default 2)
    max_event_age=Duration.minutes(config["observability"]["workerMaxEventAgeMin"]),
    on_failure=destinations.SqsDestination(self.roadmap_dlq),
)
# (equivalently event_invoke_config kwargs on the Function; CDK grants SendMessage to the DLQ)
```

This produces an `AWS::Lambda::EventInvokeConfig` with `MaximumRetryAttempts` +
`MaximumEventAgeInSeconds` + an `OnFailure` `Destination` = the DLQ ARN, and the SQS
`SendMessage` grant on the worker role (least-privilege, NFR-3). **Lambda Destinations are
preferred over a bare `deadLetterQueue`** because the on-failure record includes the
**failure context** (response + stack trace), not just the original event (§12).

**Worker idempotency (`roadmap_worker.handler`, FR-14):**

```python
def handler(event, context):
    uid, job_id = event.get("uid"), event.get("jobId")
    if not uid or not job_id:
        raise ValueError("roadmap_worker requires uid and jobId")   # → retries → DLQ
    job = roadmap_jobs.get_job(uid, job_id)
    if job and job.get("status") == roadmap_jobs.COMPLETE:
        logs.log_event("worker_skip", correlation_id=job_id, reason="already_complete")
        return {"ok": True, "jobId": job_id, "skipped": True}        # idempotent no-op
    inputs = roadmap_jobs.load_inputs(uid, job_id)
    if not inputs:
        return {"ok": False, "reason": "job not found"}              # account deleted
    try:
        roadmap = agent.generate_roadmap(...)
        roadmap_jobs.mark_complete(uid, job_id, roadmap)
        return {"ok": True, "jobId": job_id}
    except Exception as exc:
        roadmap_jobs.mark_failed(uid, job_id, f"roadmap generation failed: {exc}")
        raise                                                        # re-raise → retry/DLQ (D-5)
```

Two nuances: **(a)** raising (vs the current swallow-and-return) is what lets Lambda's async
retry + the on-failure DLQ engage (D-5 — recommend **raise after `mark_failed`** so the job
row reflects the failure *and* the DLQ captures it; the idempotency guard makes the retry
safe); **(b)** the `already_complete` skip prevents a redelivery from re-billing Opus.

**Job TTL (`roadmap_jobs.create_pending`, FR-16):**

```python
item = { **_job_key(uid, job_id), "status": PENDING, "createdAt": _now_iso(),
         "expiresAt": int(time.time()) + JOB_TTL_DAYS*86400,   # int epoch-seconds (no float)
         "book": ..., "profile": ..., "excerpt": full_text[:12000] }
```

and `data_stack.py` enables TTL on the attribute:

```python
ddb.Table(..., time_to_live_attribute="expiresAt")
```

DynamoDB deletes expired items within ~48 h, **no WCU consumed** (§12). Enabling TTL is a
**non-destructive** one-time table setting; whichever of {0032, 0029, 0026} lands first
sets `time_to_live_attribute="expiresAt"` and the others **assert** it (the attribute name
`expiresAt` is the shared contract).

### 6.6 Bedrock throttling backoff (`shared/agent.py`, FR-17)

Wrap the `invoke_model` call (inside [`0027`]'s `_invoke`/`_call`, so the two land together)
with bounded exponential backoff + **full jitter**, classifying errors:

```python
# shared/agent.py — backoff (stdlib: random, time; boto3 ClientError)
_TRANSIENT = {"ThrottlingException", "ModelTimeoutException",
              "ServiceUnavailableException", "InternalServerException", "ServiceException"}
_CLIENT    = {"ValidationException", "AccessDeniedException", "ResourceNotFoundException"}

def _is_transient(err: ClientError) -> bool:
    code = err.response.get("Error", {}).get("Code", "")
    return code in _TRANSIENT or err.response.get("ResponseMetadata", {}).get("HTTPStatusCode") == 429

def _backoff_delay(attempt: int, base=0.5, cap=8.0) -> float:
    return random.uniform(0, min(cap, base * (2 ** attempt)))      # full jitter (§12)

def _call_with_backoff(call, body, max_attempts):
    for attempt in range(max_attempts):
        try:
            return call(body)
        except ClientError as e:
            if not _is_transient(e) or attempt == max_attempts - 1:
                raise                                              # client error → fail fast
            time.sleep(_backoff_delay(attempt))                   # bounded by Lambda timeout
```

- **Composition with the existing thinking-retry.** The current code catches `ClientError`
  on the *thinking* body and retries **once** with a plain body — that error is typically a
  `ValidationException` (a **client** error), so it is **not** in `_TRANSIENT` and must keep
  its dedicated one-shot fallback; the **backoff** loop wraps **each** `_call` (thinking
  body and plain body) for **throttling/transient** errors. Net: a 429 backs off and
  retries the *same* body; a thinking-rejection falls back to the plain body (then that
  plain body also gets throttle-backoff). Both behaviors are preserved and unit-tested.
- **Bounds.** `max_attempts` (default ~4) and the `cap` keep total sleep well inside the
  worker's 60 s and the grade Lambda's 60 s budgets. A botocore
  `Config(retries={"mode":"adaptive","max_attempts":N})` MAY be added on the client as a
  second layer, but the explicit wrapper is the **tested** contract (so the behavior is
  deterministic in CI with `time.sleep` patched).
- **Monitoring.** Each retry logs `{evt:"bedrock_retry", cid, code, attempt}`; a sustained
  retry rate is visible on the dashboard and can feed the cost/throttle story.

### 6.7 Config (`config/<stage>.json` → `MANGO_OBSERVABILITY`)

```jsonc
"observability": {
  "opsTopicSubscribers": ["oncall@example.com"],      // SNS subscriptions
  "lambdaErrorRate": 0.10, "lambdaErrorEvalPeriods": 3,
  "api5xxPerPeriod": 5, "api4xxPerPeriod": 50,
  "generationFailureRate": 0.20, "generationP99Sec": 55,
  "budgetMonthlyUsd": 200, "budgetThresholdsPct": [50, 80, 100],
  "costAnomalyEnabled": false,
  "xrayEnabled": false,                               // shared with 0027 FR-10
  "workerRetryAttempts": 2, "workerMaxEventAgeMin": 30,
  "jobTtlDays": 7,
  "bedrockBackoffMaxAttempts": 4, "bedrockBackoffBaseSec": 0.5, "bedrockBackoffCapSec": 8
}
```

All have **safe defaults** so `cdk synth` works with an empty/missing block (mirrors
`config.load_config`'s `setdefault` pattern); dev/beta are generous, prod is tight.

### 6.8 What folds into [`0038`] (Step Functions) vs stays here

This spec hardens the **single async worker Lambda**. When [`0038`] replaces it with a Step
Functions Standard state machine:

- **Superseded by Step Functions:** the **per-stage retry/backoff** (SFN `Retry` on
  `ThrottlingException` with `BackoffRate`/`JitterStrategy`), **per-stage idempotency**
  (a stage overwrites its artifact), and the **DLQ-equivalent** (SFN `Catch` → a failure
  state + the DLQ for the *start* invocation) move into the ASL. The **`agent.py` backoff**
  (FR-17) **still applies** to each Bedrock call the state machine makes (it's in the shared
  client), so it carries over unchanged.
- **Stays here regardless of 0038:** the **dashboards/alarms** (extended with SFN
  `ExecutionsFailed`/`ExecutionThrottled` metrics), the **SNS ops topic**, the **Budgets +
  cost monitoring**, the **structured-log/EMF standard**, the **job TTL**, and **X-Ray**
  (SFN integrates with X-Ray natively). 0038's NFR/FR explicitly *"ties 0032"* and *"folds
  the new state machine into"* this spec — so 0032 ships the worker-Lambda hardening now and
  **adds SFN alarms** when 0038 lands, without rework.

### 6.9 Diagram

```
POST /v1/roadmaps/generate ─persist job (USER#sub/ROADMAPJOB#id, expiresAt=TTL int)─▶ DDB
        │  async invoke {uid, jobId}                          cid = jobId
        ▼
   roadmap_worker  ──(idempotent: skip if status==complete)
        │  agent.generate_roadmap()
        │     └─ _call_with_backoff(invoke_model)  ──exp backoff+jitter on Throttling──▶ Bedrock
        ├─ success → mark_complete                                   (client error → fail fast)
        └─ failure → mark_failed → RAISE ──Lambda async retry (≤2, maxEventAge)──┐
                                                                                  ▼  exhausted
                                                          SQS DLQ (onFailure dest) ─▶ alarm → SNS

logs.log_event("request"|"llm_call"|"bedrock_retry", cid=jobId, …)  ─▶ CloudWatch Logs
        │ (metric filters / EMF)                                        Logs Insights by cid
        ▼
CloudWatch Dashboard (per stage):  Lambda errs/throttles/p99 · API 4xx/5xx · DDB throttles
        · DLQ depth · Mango/Generation (0027) · Bedrock Invocations/cost
        │
        ▼ alarms ─▶ SNS mango-ops-<stage> ◀─ AWS Budgets (Marketplace dim) ◀─ Cost Anomaly (flag)
                                            ◀─ Bedrock cost alarm (GenerationCostMicroUsd / 0027)

DynamoDB TTL on expiresAt ─▶ finished/abandoned jobs self-reap (no WCU)
X-Ray (flag, shared w/ 0027): POST → worker → invoke_model subsegment
```

## 7. Acceptance criteria

- [ ] **AC-1 (dashboard synth).** `cdk synth -c stage=beta` produces an
      `AWS::CloudWatch::Dashboard` with Lambda (errors/throttles/p99), API Gateway
      (4xx/5xx/latency), DynamoDB (throttles), DLQ-depth, and `Mango/Generation` widgets.
      *(`test_synth_dashboard_exists`.)*
- [ ] **AC-2 (SNS ops topic + subscriptions).** Synth shows an `AWS::SNS::Topic`
      (`mango-<stage>` ops) with the config subscribers, and **every** alarm's `AlarmActions`
      reference it. *(`test_synth_ops_topic_and_alarm_actions`.)*
- [ ] **AC-3 (Lambda + API + DDB alarms).** Synth shows: a worker **error-rate** metric-math
      alarm + a **Throttles** alarm; an API **5xx** and **4xx** alarm; a DDB
      **throttle/UserErrors** alarm — all wired to SNS, thresholds from config.
      *(`test_synth_core_alarms`.)*
- [ ] **AC-4 (roadmap-failure + generation-p99 alarms).** Synth shows alarms on
      `Mango/Generation:GenerationFailures` (rate/count) and `GenerationLatencyMs` p99
      (≈55 s). *(`test_synth_generation_alarms` — works whether 0027 or this spec emits the
      metric.)*
- [ ] **AC-5 (DLQ + on-failure + bounded retry).** Synth shows an `AWS::SQS::Queue`
      (`mango-roadmap-dlq-<stage>`) and the worker's `AWS::Lambda::EventInvokeConfig` with
      `OnFailure`→that DLQ, `MaximumRetryAttempts` (0–2), and `MaximumEventAgeInSeconds`;
      the worker role has `sqs:SendMessage` on **only** the DLQ. *(`test_synth_worker_dlq_and_retry`.)*
- [ ] **AC-6 (DLQ-depth alarm).** Synth shows an alarm on the DLQ's
      `ApproximateNumberOfMessagesVisible ≥ 1` → SNS. *(`test_synth_dlq_alarm`.)*
- [ ] **AC-7 (worker idempotency).** A worker invocation for a job already `complete`
      **returns a no-op and does NOT call `agent.generate_roadmap`** (monkeypatched to fail
      if called); a `pending` job generates normally. *(`test_worker_skips_completed_job`,
      `test_worker_generates_pending_job`.)*
- [ ] **AC-8 (job TTL set + table TTL enabled).** `create_pending` writes an **int**
      `expiresAt` ≈ now + `jobTtlDays`; `cdk synth` shows the table with
      `TimeToLiveSpecification` on `expiresAt` (Enabled). *(`test_create_pending_sets_ttl`,
      `test_synth_table_ttl_enabled`.)*
- [ ] **AC-9 (Bedrock backoff on throttling).** `_invoke` retries on a
      `ThrottlingException`/429 with increasing (jittered) delays up to the max, then
      succeeds if a later attempt returns; `time.sleep` is patched so the test is fast and
      asserts the **schedule** (monotonic, jittered, bounded). *(`test_invoke_backoff_on_throttling`.)*
- [ ] **AC-10 (no retry on client error).** A `ValidationException`/`AccessDeniedException`
      from `invoke_model` is **not** retried by the backoff loop (raises immediately), while
      the existing **thinking-block** plain-body fallback still works. *(`test_invoke_no_retry_on_validation`,
      `test_invoke_thinking_fallback_preserved`.)*
- [ ] **AC-11 (AWS Budgets + Marketplace + cost alarm).** Synth shows an
      `AWS::Budgets::Budget` whose `CostFilters` include the **Marketplace** billing entity,
      with notification subscribers → SNS, **and** a CloudWatch cost alarm
      (`GenerationCostMicroUsd`/Bedrock). *(`test_synth_budget_marketplace_and_cost_alarm`.)*
- [ ] **AC-12 (Cost Anomaly Detection, flag).** With `costAnomalyEnabled=true`, synth shows
      `AWS::CE::AnomalyMonitor` + `AWS::CE::AnomalySubscription` → SNS; with it false,
      neither exists. *(`test_synth_cost_anomaly_flag`.)*
- [ ] **AC-13 (X-Ray flag, shared).** With `xrayEnabled=true`, `roadmap_fn` +
      `roadmap_worker_fn` synthesize with `TracingConfig: Active` and the X-Ray policy; with
      it false, tracing is `PassThrough`/unset. *(`test_synth_xray_flag`.)*
- [ ] **AC-14 (structured log + correlation id + EMF).** A handler emits **one** `request`
      JSON line with `cid` = `jobId`/`requestId`, `route`, `latencyMs`, `outcome`; an
      `emf_metric(...)` call produces a valid `_aws.CloudWatchMetrics` envelope; logging
      never raises. *(`test_request_log_shape`, `test_emf_envelope_valid`,
      `test_log_swallows_errors`.)*
- [ ] **AC-15 (least privilege preserved).** Synth IAM inspection: the worker gains **only**
      `sqs:SendMessage` on the DLQ (+ X-Ray when enabled); alarms only `sns:Publish` to the
      one topic; **`grade_fn` still has no table grant**; no new wildcard `Resource:"*"`
      except AWS-required (X-Ray). *(`test_synth_least_privilege_obs`.)*
- [ ] **AC-16 (poll contract unchanged).** A job that ultimately fails still surfaces via
      `GET /v1/roadmaps/jobs/{jobId}` as `status:"failed"` (and a DLQ record exists);
      `202 {jobId}` is unchanged; **no** `openapi`/`DTOs.swift` change. *(`test_failed_job_still_polls`
      + contract regression.)*
- [ ] **AC-17 (offline-first + invariants).** Fresh install, Mock AI, no network: first
      journey runs with **no** SNS/DLQ/Budgets/X-Ray in the loop; backend `pytest` + `cdk
      synth -c stage={dev,beta,prod}` green; black/flake8 clean; **no `float`** in any DDB
      write (TTL is int). *(CI + offline run.)*

## 8. Test plan

**Backend — `pytest` (moto for SQS/DDB; Bedrock + `time.sleep` monkeypatched), new files
under `backend/tests/`:**
- `test_agent_backoff.py` — pure `_backoff_delay` schedule (monotone bound, jitter range,
  cap) and `_is_transient` classification; `_invoke` retries a stubbed `ThrottlingException`
  then succeeds (AC-9); a `ValidationException` is not retried and the **thinking-block**
  plain-body fallback is preserved (AC-10). `time.sleep` patched → fast + deterministic.
- `test_worker_idempotency.py` — `handler` skips a `complete` job (generation monkeypatched
  to raise if called), generates a `pending` job, re-raises after `mark_failed` on a
  generation error so the async retry/DLQ path engages (AC-7, D-5).
- `test_roadmap_jobs_ttl.py` — `create_pending` sets an **int** `expiresAt` ≈ now+TTL; no
  float written (AC-8).
- `test_logs.py` — `log_event` one-line JSON with `cid`/`evt`/required fields; swallows an
  injected serialization error; `emf_metric` emits a spec-valid `_aws` envelope (AC-14).
- **Synth assertions** (extend `tests/` over `cdk synth -c stage={dev,beta,prod}`):
  dashboard (AC-1), ops topic + alarm actions (AC-2), core alarms (AC-3), generation alarms
  (AC-4), worker DLQ + event-invoke config + scoped grant (AC-5), DLQ-depth alarm (AC-6),
  table TTL (AC-8), Budget+Marketplace+cost alarm (AC-11), cost-anomaly flag on/off (AC-12),
  X-Ray flag on/off (AC-13), least-privilege + `grade_fn` table-less (AC-15).
- `test_roadmap_status` regression — a `failed` job still returns the failed view (AC-16).
**iOS — `MangoTests`:** none required (no contract change); a **regression** run of the
existing job-poll DTO tests confirms `202 {jobId}` + the job view are unchanged (AC-16).
**Manual / verified by hand (beta):**
- Force a worker failure (e.g. temporarily point at a bad model id) → confirm the event
  lands in the **DLQ**, the **DLQ-depth alarm** fires to SNS, and the job polls `failed`;
  **replay** the DLQ message → confirm the **idempotency** skip (no second generation).
- Drive enough generations to trip the **Bedrock cost** alarm threshold (low test budget) →
  confirm the SNS notification and the **Budgets** email.
- Flip `xrayEnabled` → confirm the `POST → worker → invoke_model` trace appears; flip off.
- `aws dynamodb describe-time-to-live` shows TTL **ENABLED** on `expiresAt`; an expired job
  row disappears within ~48 h.
- Run a Logs Insights query by `cid` to trace one generation end-to-end.

## 9. Rollout & migration

- **Phase 0 (config + log standard).** Land `config["observability"]` (with safe defaults),
  `shared/logs.py` (request line + EMF helper), and route the existing handlers through the
  request-line log — **inert** observability, no behavior change. Coordinate the `cid`
  convention with [`0027`] so the `llm_call` line uses the same shape.
- **Phase 1 (worker reliability).** Add the **DLQ + on-failure + retry/maxEventAge**
  (`ApiStack`), the **idempotency guard** + **raise-after-`mark_failed`** (`roadmap_worker`),
  the **job TTL** attribute (`roadmap_jobs.create_pending`) + **enable table TTL**
  (`data_stack`), and the **Bedrock backoff** (`agent.py`, layered into [`0027`]'s `_invoke`).
  Ship to **dev → beta**; exercise the DLQ + replay; watch for unintended retries.
- **Phase 2 (dashboards + alarms + SNS).** Add the `ObservabilityStack` (dashboard, alarms,
  SNS topic, DLQ-depth + generation + cost alarms). Verify in synth, deploy to beta, confirm
  alarms can reach the ops topic (send a test notification).
- **Phase 3 (cost guardrails).** Add **AWS Budgets** (Marketplace dim) + the **cost alarm**;
  optionally enable **Cost Anomaly Detection**. Coordinate ownership with [`0029`] (this spec
  owns the Budget; 0029 references it — D-4).
- **Phase 4 (X-Ray, optional).** Enable `xrayEnabled` only where async-hop latency needs
  tracing; otherwise leave off (shared flag with [`0027`]).
- **Backward compatibility.** **No contract change** — the poll/`202` shape is identical; old
  iOS builds are unaffected (NFR-7). The only **runtime** behavior changes are: the worker
  **skips already-complete jobs** (strictly safer), **raises after `mark_failed`** so failed
  events DLQ (the job row still shows `failed`, so the poll is unchanged for the user), and
  Bedrock calls **retry transient errors** (fewer spurious failures). Enabling **table TTL**
  is a one-time, non-destructive setting; **existing job rows without `expiresAt` are simply
  never auto-expired** (acceptable — only new jobs get the TTL; no backfill required).
- **Coordination.** **TTL on the single table** is shared with [`0029`] (rate counters) and
  [`0026`] (tracking) — first-to-land sets `time_to_live_attribute="expiresAt"`, others
  assert. The **`agent.py` backoff** is layered with [`0027`]'s `InvokeResult` capture (land
  in the same PR or sequence 0027 first). The **Budget/SNS** is the single source [`0029`]
  cross-refs. When [`0038`] lands, **add SFN alarms** to the dashboard and let the state
  machine's `Retry`/`Catch` supersede the single-worker DLQ for the *pipeline* (the start
  invoke + the `agent.py` backoff still apply) — §6.8.
- **Teardown / kill-switch.** Each piece is independently disable-able: alarms/dashboard can
  be removed without touching runtime; X-Ray/Cost-Anomaly are flags; the DLQ/idempotency/TTL/
  backoff are safe to keep. Raising alarm thresholds (config) quiets noise without a code
  change; the **SNS topic** is the single place to (un)subscribe responders.

## 10. Risks & open decisions

- **R-1 (raising in the worker changes the failure shape).** Switching the worker from
  swallow-and-return to **raise-after-`mark_failed`** is what enables the DLQ, but it means a
  generation error now also produces Lambda `Errors` + async retries. *Mitigation:* the
  idempotency guard makes retries safe (no double-bill), `mark_failed` keeps the user-facing
  poll correct, and the **error-rate** alarm is metric-math (rate, with a min-volume guard)
  so a few expected failures don't page. (D-5 records this choice.)
- **R-2 (double Budget / ownership overlap with [`0029`]).** Both specs mention a Budget +
  Bedrock-cost alarm. *Mitigation:* **0032 owns** the Budget/SNS/cost alarm; 0029 references
  them (D-4). The synth tests assert **one** `AWS::Budgets::Budget` per stage.
- **R-3 (alarm noise in low-traffic stages).** Rate alarms divide by small invocation counts.
  *Mitigation:* metric-math with a **min-volume** denominator guard + generous dev/beta
  thresholds; tighten in prod with data; composite alarms (D-2) for correlated incidents.
- **R-4 (X-Ray double-toggle with [`0027`]).** Both specs touch X-Ray on the same functions.
  *Mitigation:* **one shared flag** `xrayEnabled` (FR-11) drives it; whichever spec lands the
  tracing wiring, the other only references the flag.
- **R-5 (TTL deletes a job a late poll still wants).** A 7-day TTL could reap a job a user
  polls much later. *Mitigation:* TTL is **days** (config), far beyond the seconds-to-minutes
  poll window; [`0027`]'s `roadmapRef` resolve already tolerates a missing artifact
  gracefully; the roadmap also lives client-side once delivered.
- **R-6 (backoff eats the Lambda budget).** Aggressive backoff could exhaust the 60 s worker
  timeout. *Mitigation:* `max_attempts`+`cap` are config-bounded and small (total sleep ≪
  60 s); a persistent throttle ultimately **fails → DLQ → alarm** (the correct outcome).
- **R-7 (Cost Anomaly Detection gives false confidence for Bedrock).** Someone may assume it
  covers Claude spend. *Mitigation:* the spec **states the Marketplace gap** prominently
  (§6.4) and makes the **Budget** the authoritative Bedrock signal; the anomaly monitor is
  explicitly for *other* AWS spend.
- **R-8 (a separate `ObservabilityStack` adds cross-stack references).** Referencing
  `ApiStack`'s Lambdas/API from a new stack creates `Export`/`Import` coupling. *Mitigation:*
  same `MangoStage` (same deploy), constructed after `ApiStack`; if cross-stack exports are
  awkward, **fold the alarms into `ApiStack`** (D-1 fallback) — the metrics are the same.
- **Decisions needed (with recommendations):**
  - **D-1 (placement).** **Recommend a separate `ObservabilityStack`** (clean separation,
    independently ownable) with the **DLQ/event-invoke/TTL** in `ApiStack`/`data_stack`
    (runtime-adjacent); **fallback** = alarms inline in `ApiStack` if cross-stack refs are
    painful.
  - **D-2 (composite alarms).** **Recommend metric-math single alarms for v1**, add
    **composite** alarms (error-rate AND DLQ-depth) if incident noise warrants.
  - **D-3 (metric source).** **Recommend keeping [`0027`]'s metric-filters** for
    `Mango/Generation` as-is; offer **EMF** (`emf_metric`) as the documented path for **new**
    metrics (no PutMetricData). Don't re-plumb 0027's metrics.
  - **D-4 (Budget ownership).** **Recommend 0032 owns** the Budget + SNS + cost alarm;
    [`0029`] references them. (Alt: 0029 ships a minimal Budget first; 0032 takes ownership.)
  - **D-5 (worker failure mode).** **Recommend raise-after-`mark_failed`** (DLQ engages; job
    row still `failed`; idempotency makes retries safe). (Alt: keep swallow-and-return and
    add a **manual** DLQ-by-detecting-stuck-`pending` sweep — weaker.)
  - **D-6 (Step Functions now?).** **Recommend defer to [`0038`]** — harden the single worker
    now (this spec); 0038 moves orchestration to SFN and inherits this posture (§6.8). (Alt:
    jump straight to SFN — out of scope here and couples observability to a bigger change.)
  - **D-7 (botocore adaptive retries vs explicit backoff).** **Recommend the explicit,
    unit-tested wrapper** as the contract; a botocore `Config(retries=adaptive)` MAY be added
    as defense-in-depth (not the tested surface).

## 11. Tasks & estimate

1. **(S)** Add `config["observability"]` keys + safe defaults across `stage`/`config`
   (`load_config` `setdefault`); document in `OPERATIONS.md`. *(Phase 0.)*
2. **(S)** `shared/logs.py`: `log_event` (one-line JSON, `cid`, best-effort) + `emf_metric`
   (EMF envelope) + unit tests; thread the **request line** through the handlers (reuse
   [`0027`]'s `llm_call` shape). *(Phase 0.)*
3. **(M)** `shared/agent.py`: `_is_transient`/`_backoff_delay`/`_call_with_backoff`
   (exp backoff + full jitter), compose with the existing thinking-retry; layer **inside**
   [`0027`]'s `_invoke` capture; unit tests (`time.sleep` patched). *(Phase 1.)*
4. **(M)** `roadmap_worker.handler`: **idempotency** skip (status==complete) +
   **raise-after-`mark_failed`** (D-5); unit tests (generation monkeypatched). *(Phase 1.)*
5. **(S)** `roadmap_jobs.create_pending`: write int `expiresAt` (config TTL days);
   `data_stack.py`: `time_to_live_attribute="expiresAt"` (coordinate w/ 0029/0026); unit +
   synth tests. *(Phase 1.)*
6. **(M)** `ApiStack`: create the **SQS DLQ**, set the worker's **`onFailure` destination +
   `retryAttempts` + `maxEventAge`**; **expose** `self.functions`/`self.http_api`/
   `self.roadmap_dlq`; synth assertions (DLQ, event-invoke config, scoped `SendMessage`).
   *(Phase 1.)*
7. **(L)** `ObservabilityStack` (new): per-stage **dashboard** (Lambda/API/DDB/DLQ/
   generation widgets) + **alarms** (error-rate, throttles, 5xx/4xx, DDB throttle,
   DLQ-depth, generation failure-rate + p99) + **SNS ops topic** + subscriptions +
   `SnsAction`; wire into `MangoStage`; synth assertions. *(Phase 2.)*
8. **(M)** Cost guardrails: **`AWS::Budgets::Budget`** (Marketplace dim) + thresholds → SNS,
   the **CloudWatch cost alarm** (`GenerationCostMicroUsd`/Bedrock), and the **flag-gated
   Cost Anomaly** monitor/subscription; synth assertions; cross-ref [`0029`] (D-4).
   *(Phase 3.)*
9. **(S)** X-Ray: `tracing=Active` on `roadmap_fn`/`roadmap_worker_fn` behind the shared
   `xrayEnabled` flag; optional `invoke_model` subsegment in `agent.py`; synth assertion.
   *(Phase 4.)*
10. **(S)** `docs/OPERATIONS.md` runbook: the alarm catalog + SNS responders, **DLQ
    inspect/replay** procedure, the **cost/Budgets** response, the **Logs Insights**
    correlation-id queries, and the kill-switch (thresholds/flags). *(Phase 2–3.)*
11. **(S)** `working/INDEX.md`: flip 0032 to drafted; note the [`0027`]/[`0029`]/[`0026`]/
    [`0038`] coordination (TTL, Budget ownership, metric source, X-Ray flag).

*Total: roughly 1 L + 4 M + 6 S, backend/CDK only, no iOS change, landable in phases behind
config flags with the poll contract unchanged.*

## 12. References

**Repo (read for accuracy):**
- `CLAUDE.md` (invariants: Bedrock/IAM, offline-first, **no DDB floats**, stdlib+boto3,
  least-privilege, black/flake8); `working/ARCHITECTURE_REVIEW.md` (**§3 G5/G6/G7** the gaps
  this spec expands; §1 as-built — "No CloudWatch alarms/dashboards, X-Ray, AWS Budgets, or
  DLQ anywhere"; §5 sequencing); `docs/OPERATIONS.md` (the SOPs this spec extends).
- Backend: `backend/mango_backend/stage.py` (stage composition — where `ObservabilityStack`
  slots), `backend/mango_backend/api_stack.py` (`make_fn`; the async worker invoke; the
  grant loop **excluding `grade_fn`**; the Bedrock policy — where the DLQ/event-invoke
  config + the `functions`/`http_api` exposure go), `backend/mango_backend/data_stack.py`
  (the single table — **no TTL today** — where `time_to_live_attribute` goes),
  `backend/mango_backend/analytics_stack.py` (Firehose name for the dashboard),
  `backend/src/handlers/{generate_roadmap.py,roadmap_worker.py}` (the async hop +
  swallow-and-return failure path this spec changes), `backend/src/shared/agent.py`
  (`_invoke` — **one** call, thinking-retry only, **no backoff** — where FR-17 layers),
  `backend/src/shared/roadmap_jobs.py` (`create_pending` — **no `expiresAt`**; `get_job`;
  `mark_complete`/`mark_failed`), `backend/src/shared/firehose.py` (the best-effort
  request-safe pattern `shared/logs.py` mirrors).
- **Sibling specs:** `working/0027-generation-artifact-store-observability.md` (the
  `agent.py` `InvokeResult` capture, the `llm_call` log, the **`Mango/Generation`** metric
  filters this spec dashboards/alarms, the `est_cost_micro_usd` helper, the shared X-Ray
  flag — **this spec consumes those, not duplicates them**),
  `working/0029-edge-protection-rate-limiting.md` (**Budgets/Bedrock-cost alarm cross-ref**;
  the table **TTL** both enable; the 429 abuse alarm this spec's 4xx alarm complements),
  `working/0026-server-side-activity-achievement-tracking.md` (same single-table **TTL**),
  `working/0038-agentic-roadmap-engine.md` (the Step Functions engine that **inherits this
  DLQ/idempotency/TTL/backoff posture**; §6.8 the fold-in boundary).

**Research (web):**
- AWS — *Capturing records of Lambda asynchronous invocations* (on-success/on-failure
  **Destinations**, **`MaximumRetryAttempts` 0–2 + `MaximumEventAge`**, DLQ vs Destinations,
  the failure record includes the response/stack trace) —
  https://docs.aws.amazon.com/lambda/latest/dg/invocation-async-retain-records.html
- AWS Compute Blog — *Introducing AWS Lambda Destinations* (on-failure SQS/SNS destination
  for async invokes; Destinations preferred over a bare DLQ for the richer record) —
  https://aws.amazon.com/blogs/compute/introducing-aws-lambda-destinations/
- AWS — *Using time to live (TTL) in DynamoDB* (per-item **epoch-seconds Number** TTL
  attribute; enable on the table; deletion within ~48 h, **no WCU consumed**) —
  https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/TTL.html
- AWS re:Post — *Implement retry logic and exponential backoff for Amazon Bedrock* +
  *Troubleshoot Bedrock 429 Throttling* (retry **`ThrottlingException`/`ModelTimeoutException`/
  `ServiceUnavailableException`/`InternalServerException`** with **exponential backoff +
  jitter**; **don't** retry `ValidationException`/`AccessDeniedException`; monitor
  `InputTokenCount`/`Invocations`; RPM/TPM quotas) —
  https://repost.aws/knowledge-center/bedrock-retry-exponential-backoff-api ·
  https://repost.aws/knowledge-center/bedrock-throttling-error
- AWS — *Specification: CloudWatch embedded metric format (EMF)* + *Embedding metrics within
  logs* (write a structured JSON line; CloudWatch Logs **extracts custom metrics
  asynchronously** — no `PutMetricData` latency/throttling; query the source logs in Logs
  Insights) —
  https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch_Embedded_Metric_Format_Specification.html ·
  https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch_Embedded_Metric_Format.html
- AWS — *Detecting unusual spend with AWS Cost Anomaly Detection* (**does NOT monitor
  third-party AWS Marketplace products incl. Anthropic Claude on Bedrock** — use **AWS
  Budgets** with the Marketplace billing dimension to alert on those charges) —
  https://docs.aws.amazon.com/cost-management/latest/userguide/manage-ad.html
- AWS CDK — *Amazon CloudWatch Construct Library* (`Dashboard`/`GraphWidget`/`Alarm`/
  `MathExpression`; `aws_cloudwatch_actions.SnsAction(topic)` for alarm→SNS; metric-math
  error-rate alarms) —
  https://docs.aws.amazon.com/cdk/api/v2/python/aws_cdk.aws_cloudwatch/README.html
- AWS — *Visualize Lambda function invocations using AWS X-Ray* (**active tracing**
  auto-segments invokes; trace context via `_X_AMZN_TRACE_ID`; the execution role gains
  X-Ray write perms; tracing the async hop + a downstream subsegment) —
  https://docs.aws.amazon.com/lambda/latest/dg/services-xray.html
- AWS Networking & Content Delivery Blog — *Securing PartyRock: protecting Amazon Bedrock
  endpoints using AWS WAF* (denial-of-wallet on Bedrock apps; **standard rate limiters count
  requests, not cost** — the rationale for the cost/Budgets backstop here and in [`0029`]) —
  https://aws.amazon.com/blogs/networking-and-content-delivery/securing-partyrock-how-we-protect-amazon-bedrock-endpoints-using-aws-waf/
