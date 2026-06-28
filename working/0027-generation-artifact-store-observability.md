# 0027 — Generation artifact store & LLM observability

- **Epic:** M9 · **Status:** Draft · **Owner:** unassigned · **Updated:** 2026-06-28
- **Reviewers:** Principal/SD/QA

## 1. Summary

Today a Mango "roadmap" exists only as a **JSON string on the user's DynamoDB job
row** (`roadmap_jobs.mark_complete` writes `roadmap = json.dumps(...)` onto
`PK=USER#<sub>`, `SK=ROADMAPJOB#<jobId>`). The **generation transcript** (the prompt,
the model id, the raw model output, the `stop_reason`, token usage, latency), the
user's **exercise answers**, and the **grading responses** are all **ephemeral** —
`agent._invoke` parses the text and throws the envelope away; `grade_exercise`
computes a score and **persists nothing** (and `grade_fn` has **no** table or bucket
grant at all). When a roadmap is low quality, a grade looks wrong, or generation
costs spike, **there is nothing to inspect**. This spec makes every generation
artifact durable and every model call observable. It defines (a) a clean,
**user-scoped S3 layout** for roadmaps, generation transcripts, exercise Q&A, and
grading responses (so `DELETE /v1/me` still purges everything), plus a shared
per-book `content.txt`+`provenance.json`; (b) the **write paths** — the worker writes
`roadmap.json`+`generation.json`; `grade` writes `answer.json`+`grading.json` (and
gets a new **write-only, prefix-scoped** bucket grant and must finally call
`user_id`); `content_parse` writes `provenance.json`; (c) a **model-boundary capture**
in `agent.py` so the raw output, `stop_reason`, token usage, and latency are returned
to callers instead of discarded; (d) **DDB↔S3 pointers** plus a `USER#<sub>/ARTIFACT#…`
**index** for "show everything generated for this user"; and (e) **structured JSON
logging** with `jobId` as the correlation id (model, latency, tokens, estimated cost,
prompt hash, outcome), **CloudWatch metric filters + alarms** (generation failure
rate, `stop_reason=max_tokens` truncation, p99 latency), optional **X-Ray** on the
async hop, and an **S3 lifecycle** (IA@30d / Glacier@90d). All writes are
**best-effort** (never fail the request) and **idempotent by id**. We keep the DDB
`job.roadmap` value as a small **pointer** to dodge the 400 KB item limit.

This spec **owns the artifact store + per-generation logging primitives**. The
sibling [`0032-observability-cost-reliability`] owns **dashboards, AWS Budgets, and
worker DLQ/retry/idempotency**; [`0038-agentic-roadmap-engine`] (which replaces the
single Bedrock call with a Step Functions pipeline) **writes its per-stage artifacts
through this store**; and [`0039-activity-type-framework`] owns the richer
`Activity`/submission **schema** whose media artifacts land under the `submissions/`
prefix this spec namespaces. We design the layout and the `agent.py` capture so all
three land on top without a rewrite.

## 2. Goals / Non-goals

- **Goals:**
  - **Persist the roadmap to S3** (not just a DDB string): `users/<sub>/roadmaps/<roadmapId>/roadmap.json`,
    with DDB keeping a **pointer** (`roadmapRef`) instead of the full body.
  - **Persist the generation transcript** (`generation.json`) — prompt(s), system
    prompt, model id, **raw output**, `stop_reason`, **input/output token usage**,
    **latency**, prompt hash, effort/thinking config, outcome — so any low-quality
    roadmap is fully diagnosable.
  - **Persist exercise Q&A + grading**: per attempt,
    `users/<sub>/roadmaps/<roadmapId>/lessons/<lessonId>/<exerciseId>/{answer.json,grading.json}`
    (the answer the user submitted; the model's full grading envelope incl. raw
    output + tokens + latency for the model-graded path).
  - **Capture the model boundary in `agent.py`**: change `_invoke` to return the raw
    response envelope (text **+** `stop_reason` **+** `usage` **+** `latencyMs` **+**
    `modelId`) so `generate_roadmap`/`grade` (and 0038's stages) can persist + log it,
    rather than discarding it after `extract_json`.
  - **Add the write-only, prefix-scoped grant + `user_id` call to `grade_fn`**: today
    it has **no** bucket grant and **never** resolves the caller — both required to
    write `users/<sub>/…` artifacts.
  - **Shared per-book artifacts**: keep the existing `books/<bookId>.txt` content (or
    promote to `books/<bookId>/content.txt`) and add `books/<bookId>/provenance.json`
    (source url/type, fetched-at, parser, word count, content hash) written by
    `content_parse`.
  - **DDB pointers + a DDB artifact index**: `USER#<sub>/ARTIFACT#<roadmapId>#<kind>`
    rows (and `…#<lessonId>#<exerciseId>#<kind>`) carrying the S3 key + lightweight
    metadata (model, tokens, latency, cost-est, stop-reason, createdAt) so the API can
    enumerate everything generated for a user/roadmap without scanning S3.
  - **Structured observability**: one-line JSON logs per model call keyed by `jobId`
    (the correlation id across POST → worker → poll), with model/latency/tokens/cost/
    promptHash/outcome; **CloudWatch metric filters + alarms** for generation failure
    rate, `stop_reason=max_tokens` truncation, and p99 latency; optional **X-Ray** on
    the async invoke hop.
  - **Lifecycle**: transcripts/answers/grading transition **Standard → IA@30d →
    Glacier@90d**; everything user-scoped so account deletion still purges it.
  - **Invariants honored**: float-free DDB (cost stored as **int micro-USD**; tokens
    as ints); stdlib + boto3 only; least-privilege IAM (grade gets a *write-only*
    prefix grant, not full bucket access); best-effort writes never fail a request.
- **Non-goals:**
  - **Dashboards, AWS Budgets, the worker DLQ/retry/idempotency, and Bedrock backoff**
    — those are [`0032`] (this spec emits the **metrics + logs** 0032 charts and
    budgets against; it does not build the dashboard or the DLQ).
  - **The Step Functions multi-stage pipeline** and its `research/plan/activities/
    verdict` artifacts — [`0038`] (it persists *through* this store using the same
    layout + `agent.py` capture; this spec ships against today's single-call worker
    and reserves the per-stage seam).
  - **The richer `Activity`/submission schema and grading contract** (modalities,
    media submissions, pluggable graders) — [`0039`]; this spec persists the **as-built**
    `quiz/reflection/application` answer/grading shape and namespaces the `submissions/`
    media prefix 0039 will use, but does not define those schemas.
  - **Per-book roadmap caching / shared templates / single-flight** — [`0028`] (its
    `templates/<bookId>/<ver>.json` lives in this S3 layout; cache mechanics are 0028's).
  - **The analytics events lake** (`/v1/events` → Firehose → Glue) — [`0015`]/0006.
    High-volume, immutable **per-answer history for analytics** rides that lake;
    **this** store keeps the *inspectable artifact* of a specific generation/grade. They
    are different substrates with different purposes (audit/debug vs. aggregate analytics).
  - **A user-facing "my data" screen** or DSAR export — export is [`0033`]; this spec
    only makes the artifacts *exist + enumerable* (the index 0033/0034 will read).
  - **Content moderation / Guardrails** on the persisted text — [`0030`].

## 3. Background & context

**As-built generation + grading (verified by reading the code).**

- **Roadmap is a DDB string.** `POST /v1/roadmaps/generate`
  (`backend/src/handlers/generate_roadmap.py`) resolves the book (inline `book.text`
  or stored `bookId` → S3 `contentRef`), persists a pending job
  (`roadmap_jobs.create_pending`: `PK=USER#<uid>`, `SK=ROADMAPJOB#<jobId>` carrying
  `book`, `profile`, `excerpt=full_text[:12000]`), async-invokes the worker, and
  returns `202 {jobId, status:"pending"}`. The worker
  (`backend/src/handlers/roadmap_worker.py`) calls `agent.generate_roadmap(...)`,
  then `roadmap_jobs.mark_complete(uid, job_id, roadmap)` which does
  `SET roadmap = :r` with `:r = json.dumps(roadmap)` — **the entire roadmap is one
  DDB attribute on the user's job row**. `BOOK#<id>/ROADMAP` is documented in
  `docs/DATA_MODEL.md` but **never written** (`ARCHITECTURE_REVIEW.md` §1).
- **The transcript is discarded.** `agent._invoke` (`backend/src/shared/agent.py`)
  does `payload = json.loads(resp["body"].read())` and returns **only**
  `"".join(text parts)` — the `stop_reason`, the Bedrock `usage` block (input/output
  tokens), and the latency are **dropped on the floor**. `extract_json` then keeps
  only the parsed object. There is no record of *what the model actually returned* or
  *how much it cost*.
- **Grading persists nothing and can't.** `grade_exercise.py` grades quizzes
  deterministically and reflections/applications via `agent.grade(...)`, then returns
  `{correct, score, feedback, xpAwarded}` to the client and **writes nothing**.
  Critically, in `api_stack.py` the grant loop `for fn in (parse_fn, roadmap_fn,
  roadmap_worker_fn, …): table.grant_read_write_data(fn)` **excludes `grade_fn`**, and
  `bucket.grant_*` is only given to `parse_fn`/`roadmap_fn`/`roadmap_worker_fn`/
  `delete_fn` — `grade_fn` has **no table and no bucket access** by design ("grade_fn
  never touches the table", `api_stack.py:83`). Also `grade_exercise.handler` **never
  calls `user_id(event)`**, so today it has no idea *whose* answer it is grading. Both
  must change for grade to write user-scoped artifacts.
- **Product S3 today.** Only `books/<bookId>.txt` (full normalized text, written by
  `content_parse`, referenced by `BOOK#<id>/META.contentRef`) and `users/<sub>/…`
  (**fully enumerated + deleted** by `DELETE /v1/me`, `delete_account._delete_s3_objects`
  walks `users/<sub>/`). The bucket (`data_stack.py`) is `BLOCK_ALL` public access,
  SSE-S3, `enforce_ssl`, versioned+RETAIN in prod. **No lifecycle rules** exist on it.
- **Bedrock + invariants.** Models run on **Bedrock via `InvokeModel`, IAM, no API key**
  (`CLAUDE.md`). DynamoDB **rejects Python `float`** — coerce to int / JSON string
  (`progress.py`, `generate_roadmap.py`). Lambdas are **stdlib + boto3 only**. Backend
  style: black (100) + flake8 (120). `response.user_id` trusts the JWT `sub` in
  prod/beta and an `x-mango-user` header only outside them.
- **No observability anywhere.** `ARCHITECTURE_REVIEW.md` §1/§3 (G5): "**No**
  CloudWatch alarms/dashboards, X-Ray … no Bedrock cost monitoring." The only failure
  signal today is `roadmap_worker` raising `ValueError` (visible in raw Lambda logs)
  and `mark_failed` writing an `error` string onto the job row.

**Why now.** This is recommendation **§2.2** of `ARCHITECTURE_REVIEW.md` ("Roadmap
assets + Q/A + responses in S3, with logging → propose `0027`"). It is a prerequisite
for the whole agentic cluster: [`0038`] explicitly says "every stage emits an artifact
+ transcript to the 0027 store" and lists 0027 as a forward dependency; [`0039`]
coordinates its S3 submission layout with 0027; [`0028`] hosts its shared templates in
this layout; and [`0032`]'s cost/failure alarms consume the structured logs + metrics
this spec emits. Operationally, the moment any real traffic hits generation we need to
answer "why is this roadmap bad / this grade wrong / this bill high" — and right now we
can't, because the evidence is thrown away.

**Related specs.** [`0026`] (server-side activity/achievement tracking — owns the DDB
`ACTIVITY#`/`ACHV#`/`LESSONDONE#` items and routes *analytics* per-answer history to the
events lake; this spec keeps the *inspectable* answer/grading artifact). [`0028`]
(shared per-book cache — `templates/` live here). [`0032`] (dashboards/budgets/worker
reliability — consumes these metrics/logs). [`0038`] (agentic engine — writes per-stage
artifacts through this store). [`0039`] (activity schema — `submissions/` media prefix).
[`0015`]/0006 (analytics lake — the *other* substrate). [`0033`] (DSAR export — reads
the artifact index).

## 4. User stories

- As a **product owner**, when a generated roadmap looks off, I can open
  `users/<sub>/roadmaps/<roadmapId>/generation.json` and see the exact prompt, the raw
  model output, the `stop_reason`, and the token usage — and tell at a glance whether
  it truncated, drifted, or just produced a weak plan.
- As a **support engineer**, when a user says "my reflection got a 0 and that's
  wrong," I can read `…/lessons/<lessonId>/<exerciseId>/answer.json` (what they wrote)
  and `…/grading.json` (the model's full grading envelope + raw text) and either
  confirm or refund.
- As an **on-call engineer**, a CloudWatch alarm fires when **generation failure rate**
  crosses a threshold or when Opus starts hitting `stop_reason=max_tokens` (silent
  truncation), and I can pivot from the alarm to the exact run by **`jobId`** because
  every log line is tagged with it.
- As a **FinOps/cost owner**, every model call logs **input/output tokens + an
  estimated USD (as int micro-USD)**, so [`0032`] can chart spend and set a Budgets
  alert without me instrumenting anything new.
- As a **privacy-conscious user**, when I delete my account, **everything generated for
  me** — roadmaps, transcripts, my answers, the grading of my answers — is purged,
  because it all lives under `users/<sub>/` (and there is **no Object Lock** preventing
  deletion).
- As the **0038 engine** (future), each pipeline stage writes its artifact + transcript
  to this store under the same `roadmapId` using the same `agent.py` capture, keyed by
  `jobId`, with no new plumbing.
- As an **offline first-run user**, none of this is on my critical path: the bundled
  sample + `MockAIService` run with **zero network**, no S3, no Bedrock — artifact
  persistence simply doesn't engage (the `CLAUDE.md` offline invariant is untouched).

## 5. Requirements

### Functional

- **FR-1 (roadmap → S3 + pointer).** On successful generation, the worker MUST write
  the roadmap body to `users/<sub>/roadmaps/<roadmapId>/roadmap.json` and store a
  **pointer** in DDB. `roadmap_jobs.mark_complete` MUST stop inlining the full JSON and
  instead persist `roadmapRef` (the S3 key) + a small `roadmapMeta` (title, milestone/
  lesson counts) on the job row; `get_job` MUST resolve the pointer (read S3) when the
  client polls a `complete` job, preserving the existing `{jobId,status,roadmap}` poll
  response. (`roadmapId` = the `jobId` for the as-built single-call path; see §6.2 D-1.)
- **FR-2 (generation transcript).** On every roadmap generation attempt (success **or**
  failure), the worker MUST write `users/<sub>/roadmaps/<roadmapId>/generation.json`
  capturing: `system`, `user` prompt, `modelId`, `promptHash`, effort/thinking config,
  **raw model text**, `stopReason`, `inputTokens`, `outputTokens`, `latencyMs`,
  `outcome` (`complete|failed|parse_error`), and on failure the error string. Best-effort.
- **FR-3 (exercise answer + grading → S3).** For reflection/application grades (the
  model-graded path), and for quizzes (deterministic), `grade_exercise` MUST write
  `users/<sub>/roadmaps/<roadmapId>/lessons/<lessonId>/<exerciseId>/answer.json` (the
  submission: kind, prompt, answer text or chosen index) and `…/grading.json` (score,
  feedback, xpAwarded, and for model-graded: the full `agent.grade` envelope incl. raw
  text, `stopReason`, tokens, latencyMs). Idempotent by a client-supplied `attemptId`
  (or a server `attemptId` when absent — §6.2 D-2). Best-effort: a write failure MUST
  NOT change the grade returned to the client.
- **FR-4 (grade gets identity + a write-only grant).** `grade_exercise.handler` MUST
  call `user_id(event)` (401 on `PermissionError`, mirroring the other handlers) and
  the request MUST carry `roadmapId`/`lessonId`/`exerciseId` (so the artifact can be
  keyed); `api_stack.py` MUST grant `grade_fn` a **write-only, prefix-scoped** PUT on
  `users/*` of the content bucket — **not** `grant_read_write` and **not** table access
  (it still needs neither read of others' data nor any table write; the artifact index
  row for grades is written by a path that *does* have table access — see §6.5 D-3).
- **FR-5 (content provenance).** `content_parse` MUST write
  `books/<bookId>/provenance.json` alongside the content: `{ sourceType, sourceValue?,
  title, author?, wordCount, fetchedAt, parser, contentHash, contentKey }`. The
  content key MAY remain `books/<bookId>.txt` (back-compat) or move to
  `books/<bookId>/content.txt` (§6.2 D-4); either way `META.contentRef` stays the
  source of truth.
- **FR-6 (model-boundary capture in `agent.py`).** `agent._invoke` MUST be refactored
  to return a structured result (`text`, `stopReason`, `usage{inputTokens,outputTokens}`,
  `latencyMs`, `modelId`, the body sent) instead of only the joined text.
  `generate_roadmap` and `grade` MUST surface that envelope to their callers (a
  `(parsed, meta)` tuple or a small dataclass-like dict) so the worker/grade handler can
  persist + log it. The **parsing + retry-on-thinking-rejection behavior MUST be
  preserved** (the adaptive-thinking call, the single retry with a plain body, tolerant
  `extract_json`).
- **FR-7 (DDB artifact index).** Each persisted artifact MUST get an index row:
  `PK=USER#<sub>`, `SK=ARTIFACT#<roadmapId>#<kind>` (kind ∈ `roadmap|generation`) and
  `SK=ARTIFACT#<roadmapId>#<lessonId>#<exerciseId>#<kind>` (kind ∈ `answer|grading`),
  carrying `s3Key`, `createdAt`, and lightweight metadata (`modelId?`, `inputTokens?`,
  `outputTokens?`, `latencyMs?`, `estCostMicroUsd?`, `stopReason?`, `outcome?`). All
  **ints/strings only** (no floats). Best-effort. This is the enumeration surface for
  "everything generated for this user" (and for the resolve in FR-1).
- **FR-8 (correlation id + structured logs).** Every model call and artifact write MUST
  emit a **single-line JSON log** including `jobId` (the correlation id), `uid`, `stage`
  (`roadmap|grade` today; the 0038 stages later), `modelId`, `latencyMs`, `inputTokens`,
  `outputTokens`, `estCostMicroUsd`, `promptHash`, `stopReason`, and `outcome`. `jobId`
  MUST thread POST → worker (via the existing `{uid,jobId}` event payload) → the job row
  the poll reads. Logging MUST never throw to the caller.
- **FR-9 (CloudWatch metric filters + alarms).** CDK MUST define metric filters over the
  Lambda log groups extracting: generation **failure** (count where `outcome=failed`),
  **truncation** (count where `stopReason=max_tokens`), and **latency** (`latencyMs`).
  Alarms MUST fire on: generation failure-rate over a window, any sustained truncation,
  and **p99 latency** approaching the worker budget (60 s). Metric **namespace + names**
  are shared with [`0032`] (which owns the dashboard + Budgets that read them) — this
  spec defines/emits them; 0032 composes them.
- **FR-10 (optional X-Ray).** The async hop (`generate_roadmap` → `roadmap_worker`)
  SHOULD be traceable: enable **active tracing** on `roadmap_fn`/`roadmap_worker_fn`
  (and optionally subsegments around the Bedrock call), behind a config flag so it is
  off where not wanted. Trace id MAY be logged alongside `jobId`.
- **FR-11 (lifecycle).** The content bucket MUST gain lifecycle rules transitioning
  **`users/<sub>/roadmaps/` artifacts** (transcripts, answers, grading) to **IA at 30d**
  and **Glacier at 90d**. `roadmap.json` MAY stay Standard (it is read on poll); the
  rule MUST NOT touch `books/<bookId>.txt`/`content.txt` if it would break generation
  reads (§6.6). Lifecycle MUST be compatible with deletion (no Object Lock).
- **FR-12 (deletion completeness preserved).** Every artifact and index row MUST be
  purgeable by account deletion: artifacts live under `users/<sub>/` (already swept by
  `delete_account._delete_s3_objects`); index rows are `USER#<sub>` items (already swept
  by `_delete_table_items`). The S3 `books/<bookId>/…` shared artifacts are **not**
  user-scoped (correct — they are content, not personal data). A test MUST assert a
  user's roadmap/transcript/answer/grading + index rows are gone after `DELETE /v1/me`.
- **FR-13 (offline/mock untouched).** The on-device `MockAIService` path and the inline
  local generation path (no worker configured) MUST keep working with **no S3 writes
  required** for correctness; artifact persistence is best-effort and absent locally.

### Non-functional

- **NFR-1 (best-effort, request-safe).** No artifact write, index write, or log line may
  throw to a handler, change a status code, or alter the grade/roadmap returned. A
  failed `put_object`/`update_item` is caught, logged, and swallowed (mirrors the
  `firehose.put_event`-returns-`False` contract in 0006/0015).
- **NFR-2 (float-free DDB).** Cost is stored as **int micro-USD** (`estCostMicroUsd`);
  tokens, latency are ints; scores that must persist (in `grading.json`, an S3 doc) are
  fine as JSON numbers because **S3 is not DynamoDB** — but any score written to a DDB
  index attribute MUST be a scaled int (basis-points) or omitted (invariant).
- **NFR-3 (least-privilege IAM).** `grade_fn` gets a **write-only** `s3:PutObject` on
  `arn:…:<bucket>/users/*` and nothing else new (no `GetObject`, no `ListBucket`, no
  table grant). The worker keeps its existing grants + needs **write** to the bucket
  (it currently only has `grant_read`) scoped to `users/*` for artifacts. `content_parse`
  already has read-write. The Bedrock policy is unchanged.
- **NFR-4 (privacy).** Transcripts/answers/grading contain user text (answers) and book
  excerpts → strictly **user-scoped** under `users/<sub>/`, lifecycle to IA/Glacier,
  **never** copied into analytics `props` (0015), and purged on delete. SSE-S3 +
  `enforce_ssl` (already on the bucket) protect at rest/in transit.
- **NFR-5 (no DDB item bloat).** The roadmap body moves **out** of the job row into S3
  (FR-1), so the job item stays small (well under 400 KB) even as roadmaps grow richer
  (0038/0039). Index rows are tiny.
- **NFR-6 (stdlib + boto3, synth/test offline).** New shared module(s) use stdlib +
  boto3 only. `cdk synth -c stage=beta` (new lifecycle rules, metric filters, alarms,
  grant) + `pytest` (moto for S3/DDB; Bedrock monkeypatched) MUST pass **offline**.
  black (100) + flake8 (120) clean.
- **NFR-7 (forward-compatible layout).** The path convention MUST accommodate (a)
  0038's per-stage artifacts (`…/roadmaps/<roadmapId>/<stage>.json` +
  `…/transcripts/<stage>.json`), (b) 0028's shared templates
  (`books/<bookId>/templates/<ver>.json`), and (c) 0039's submission media
  (`submissions/<sub>/<activityId>/<submissionId>.<ext>`) — defined here as **reserved
  prefixes** so those specs slot in without renaming.
- **NFR-8 (cost-estimation accuracy is best-effort).** `estCostMicroUsd` is computed
  from token counts × a **config-driven per-1k-token price table** (input/output) keyed
  by model id; it is an estimate for alarms/trends, not billing-grade. Unknown model →
  cost omitted (not zero).

## 6. Design

### 6.1 S3 layout (the path convention)

All paths are in the **existing product/content bucket** (`data_stack.bucket`,
`BUCKET_NAME`). Everything personal is under `users/<sub>/` so `DELETE /v1/me` purges it.

```
books/<bookId>/
  content.txt                     # full normalized text (today: books/<bookId>.txt — D-4)
  provenance.json                 # NEW (content_parse): source, fetchedAt, parser, hashes
  templates/<ver>.json            # RESERVED for 0028 (shared per-book base track)
  provenance is content, NOT user data → not under users/, not purged per-user

users/<sub>/roadmaps/<roadmapId>/
  roadmap.json                    # NEW: the generated roadmap body (DDB holds a pointer)
  generation.json                 # NEW: the generation transcript (prompt/raw/stop/usage/latency)
  lessons/<lessonId>/<exerciseId>/
    answer.json                   # NEW (grade): the user's submission for this attempt
    grading.json                  # NEW (grade): the grading result + (model-graded) raw envelope
  # RESERVED for 0038 staged pipeline:
  #   research.json plan.json activities.json overlay.json verdict.json
  #   transcripts/<stage>.json

submissions/<sub>/<activityId>/<submissionId>.<ext>   # RESERVED for 0039 media submissions
```

- `<roadmapId>` is the generation's id. For the as-built single-call path it **equals
  the `jobId`** (one job → one roadmap), which keeps the worker write trivial and the
  correlation id and the artifact id the same. (D-1 discusses a distinct id for 0038.)
- `<lessonId>`/`<exerciseId>` come from the roadmap the client is acting on; the client
  already holds them (the journey graph). The grade request carries them (FR-4).
- Multiple grade attempts on the same exercise are disambiguated by `attemptId` inside
  the doc and (optionally) the index SK; the **latest** answer/grading overwrite the
  per-exercise files (last-write-wins) while the index can retain attempt history (D-2).

### 6.2 Write paths (who writes what, when)

| Artifact | Writer | Trigger | Path | Notes |
|---|---|---|---|---|
| `provenance.json` | `content_parse` | after `put_object(content)` + `META` put | `books/<bookId>/provenance.json` | content, not user-scoped; best-effort |
| `roadmap.json` | `roadmap_worker` (+ inline path in `generate_roadmap`) | on `mark_complete` | `users/<uid>/roadmaps/<jobId>/roadmap.json` | DDB stores `roadmapRef` pointer (FR-1) |
| `generation.json` | `roadmap_worker` (+ inline) | on success **and** failure | `users/<uid>/roadmaps/<jobId>/generation.json` | the transcript (FR-2) |
| `answer.json` | `grade_exercise` | on each grade request | `users/<uid>/roadmaps/<roadmapId>/lessons/<lessonId>/<exerciseId>/answer.json` | needs `user_id` + write grant (FR-4) |
| `grading.json` | `grade_exercise` | on each grade request | `…/<exerciseId>/grading.json` | model-graded incl. raw envelope (FR-3) |
| `ARTIFACT#…` index rows | the writer that has table access | alongside each S3 write | DDB | grade's index row written via the table-capable path (D-3) |

**The `agent.py` capture (FR-6).** `_invoke` currently returns a string. Refactor it to
return a small result object so the envelope is not lost:

```python
# shared/agent.py — sketch (stdlib + boto3, no new deps)
class InvokeResult:                      # or a plain dict; kept JSON-serializable
    text: str
    stop_reason: str | None
    input_tokens: int
    output_tokens: int
    latency_ms: int
    model_id: str

def _invoke(system, user, max_tokens=1500) -> "InvokeResult":
    model_id = os.environ["BEDROCK_MODEL_ID"]
    ...
    def _call(body):
        t0 = time.monotonic()
        resp = _runtime().invoke_model(modelId=model_id, ..., body=json.dumps(body))
        payload = json.loads(resp["body"].read())
        latency_ms = int((time.monotonic() - t0) * 1000)
        parts = payload.get("content", [])
        text = "".join(p.get("text", "") for p in parts if p.get("type") == "text")
        usage = payload.get("usage", {}) or {}
        return InvokeResult(
            text=text,
            stop_reason=payload.get("stop_reason"),
            input_tokens=int(usage.get("input_tokens", 0)),
            output_tokens=int(usage.get("output_tokens", 0)),
            latency_ms=latency_ms,
            model_id=model_id,
        )
    # max-effort + retry-on-thinking-rejection unchanged; both branches return InvokeResult
```

`generate_roadmap` / `grade` then return **both** the parsed object and the meta:

```python
def generate_roadmap(book, profile, excerpt_text):
    res = _invoke(prompts.roadmap_system(), prompts.roadmap_user(book, profile, excerpt_text), max_tokens=3000)
    return extract_json(res.text), res          # (roadmap, InvokeResult)

def grade(kind, prompt, answer):
    res = _invoke(prompts.grade_system(), prompts.grade_user(kind, prompt, answer), max_tokens=600)
    return extract_json(res.text), res          # (grading, InvokeResult)
```

Callers that don't care about meta (tests, the offline inline path) can ignore the
second element. This is the single change that makes **everything else** (transcript,
logging, cost) possible — the data already comes back from Bedrock; we simply stop
throwing it away.

**New shared module `shared/artifacts.py`** (the store + index + logging helpers, all
best-effort):

```python
# put_artifact(uid, roadmap_id, name, body_dict) -> s3_key | None
# put_exercise_artifact(uid, roadmap_id, lesson_id, exercise_id, name, body) -> key | None
# put_provenance(book_id, body) -> key | None
# index_artifact(uid, roadmap_id, kind, s3_key, meta) -> None     # writes ARTIFACT# row
# transcript_from_invoke(system, user, res) -> dict                # builds generation.json body
# log_generation(job_id, uid, stage, res, outcome)                # one-line JSON to stdout
# est_cost_micro_usd(model_id, in_tok, out_tok) -> int | None      # config price table
# Every function swallows its own exceptions and returns None/False — never raises.
```

**Decisions (recommendations).**
- **D-1 (recommend: `roadmapId == jobId` for the single-call path; reserve a distinct
  `trackId` for 0038).** One generation = one job today, so reusing `jobId` keeps the
  correlation id, the artifact prefix, and the pointer all aligned with zero new id
  plumbing. 0038 already plans a `trackId` for the cached shared base; this spec's
  per-user prefix can adopt it later without moving files (the per-user artifacts are
  keyed by the **job**, which is correct — they're that user's run).
- **D-2 (recommend: last-write-wins per-exercise files + an `attemptId` field; index may
  keep attempts).** The common need ("show the latest answer + grade") is satisfied by
  overwriting `answer.json`/`grading.json`. Keeping every attempt as a separate object
  is possible (`…/<exerciseId>/attempts/<attemptId>.json`) but adds enumeration cost;
  defer to a flag. The `attemptId` in the doc + the events lake (0015) preserve the full
  history for analytics.
- **D-3 (recommend: grade stays table-less; its index row is written best-effort by a
  table-capable path).** Two clean options: **(a)** `grade_fn` writes only the S3
  artifacts (write-only `users/*` grant) and the **index row is written when the client
  reports the completed lesson** (the `LESSONDONE#`/progress write in [`0026`], which
  has table access) — keeping `grade_fn` exactly as least-privilege as today; **(b)**
  give `grade_fn` a narrowly-scoped `PutItem` on the table for `ARTIFACT#` rows only.
  Recommend **(a)**: it preserves the `api_stack.py` comment "grade_fn never touches the
  table," and the grading.json artifact is independently inspectable even without the
  index. (The roadmap/generation index rows are written by the worker, which already has
  `grant_read_write_data`.)
- **D-4 (recommend: keep `books/<bookId>.txt` for back-compat; add `provenance.json`
  beside it; treat `books/<bookId>/content.txt` as an optional future move).** Changing
  the content key touches `content_parse`, `META.contentRef`, and `roadmap_jobs.resolve_book`
  read path; not worth it for v1. `provenance.json` is purely additive.

### 6.3 Data — DynamoDB items (single-table, float-free)

Coordinated with [`0026`] (which owns `ACTIVITY#`/`ACHV#`/`LESSONDONE#`) and `docs/DATA_MODEL.md`.

| Item | PK | SK | Attributes |
|---|---|---|---|
| Roadmap job (modified) | `USER#<sub>` | `ROADMAPJOB#<jobId>` | **`roadmapRef`** (S3 key, replaces inlined `roadmap`), `roadmapMeta` (JSON string: title, milestoneCount, lessonCount), `status`, `createdAt`, `completedAt`, … |
| Artifact index — roadmap/gen | `USER#<sub>` | `ARTIFACT#<roadmapId>#<kind>` (`kind∈roadmap\|generation`) | `s3Key`, `createdAt`, `modelId?`, `inputTokens?`, `outputTokens?`, `latencyMs?`, `estCostMicroUsd?`, `stopReason?`, `outcome?` |
| Artifact index — answer/grading | `USER#<sub>` | `ARTIFACT#<roadmapId>#<lessonId>#<exerciseId>#<kind>` (`kind∈answer\|grading`) | `s3Key`, `createdAt`, `attemptId?`, plus grading meta (model-graded): `modelId?`, tokens?, `latencyMs?`, `estCostMicroUsd?`, `scoreBp?` (score×10000, int) |

Notes:
- **No floats.** `estCostMicroUsd` is int micro-USD; `scoreBp` (if stored on the index)
  is basis-points (`int(score*10000)`); the *float* score lives only in the S3
  `grading.json` doc, which is fine (S3 is not DynamoDB).
- The job row no longer carries the full roadmap → stays small (NFR-5). `get_job`
  resolves `roadmapRef` from S3 for the poll response (FR-1).
- `BOOK#<id>/ROADMAP` (the documented-but-dead per-book cache row) is **owned by 0028**;
  this spec only provides the S3 `templates/` prefix it will point at.

### 6.4 Observability

**Correlation id.** `jobId` is the spine: minted in `POST /v1/roadmaps/generate`
(`roadmap_jobs.new_job_id`), passed to the worker in the existing `{uid,jobId}` event,
written on the job row the poll reads, used as `<roadmapId>` in the S3 prefix, and
stamped on every log line. A support/ops question starts from a `jobId` (or a `uid` +
the `ARTIFACT#` index) and reaches the exact prompt, raw output, and cost.

**Structured logs (FR-8).** One JSON line per model call (stdout → CloudWatch Logs):

```json
{"evt":"llm_call","jobId":"<hex>","uid":"<sub>","stage":"roadmap",
 "modelId":"us.anthropic.claude-opus-4-8","latencyMs":26840,
 "inputTokens":4120,"outputTokens":2310,"estCostMicroUsd":78450,
 "promptHash":"sha256:ab12…","stopReason":"end_turn","outcome":"complete"}
```

and one per artifact write (`{"evt":"artifact_put","jobId":…,"key":…,"ok":true}`).
`promptHash = sha256(system + "\n" + user)` (hex, truncated for the log) lets us
group runs by identical prompt without storing the prompt in the log.

**Metric filters + alarms (FR-9), namespaced with [`0032`]** (`Mango/Generation`):

| Metric | Filter pattern (over worker/grade log group) | Alarm |
|---|---|---|
| `GenerationFailures` | `{ $.evt = "llm_call" && $.stage = "roadmap" && $.outcome = "failed" }` | failure **rate** > X% over 15 min |
| `Truncations` | `{ $.evt = "llm_call" && $.stopReason = "max_tokens" }` | any sustained (>N in 15 min) — silent quality loss |
| `GenerationLatencyMs` | `{ $.evt = "llm_call" && $.stage = "roadmap" }` → metric value `$.latencyMs` | **p99** > 55 s (approaching the 60 s worker budget) |
| `GradeFailures` | `{ $.evt = "llm_call" && $.stage = "grade" && $.outcome = "failed" }` | (optional) rate alarm |
| `GenerationCostMicroUsd` | metric value `$.estCostMicroUsd` | consumed by 0032 Budgets/dashboard (not alarmed here) |

This spec **emits + defines** these; [`0032`] builds the **dashboard** that graphs them
and the **AWS Budgets** alert on Bedrock spend, and owns the **worker DLQ/retry**. The
boundary: *0027 = per-generation evidence + the three quality/latency alarms; 0032 =
fleet dashboards, budgets, reliability plumbing.* Cross-linked both ways.

**X-Ray (FR-10, optional).** `tracing=Active` on `roadmap_fn` + `roadmap_worker_fn`
(behind a `config["xray"]` flag) gives the POST→worker async hop a trace; a subsegment
around `invoke_model` isolates Bedrock latency from Lambda overhead. Off by default to
avoid cost where not wanted.

### 6.5 API / contract

**No new endpoints** are required for v1 (the artifacts are written server-side; the
index is read by future 0033/0034). The **contract deltas** to keep
`shared/api/openapi.yaml` ⇄ `DTOs.swift` ⇄ handlers in lockstep:

- **`POST /v1/exercises/grade`** — request gains optional `roadmapId`, `lessonId`,
  `exerciseId`, `attemptId` (so the artifact can be keyed). They are **optional + additive**:
  when absent, grading works exactly as today and simply **skips** artifact persistence
  (logged as `outcome=…,persisted=false`). Response **unchanged** (`{correct,score,
  feedback,xpAwarded}`). The iOS client (which holds the journey graph) starts sending
  the ids; older clients keep working.
- **`GET /v1/roadmaps/jobs/{jobId}`** — response **unchanged** in shape; internally it
  now resolves `roadmapRef`→S3 instead of reading an inlined `roadmap` attribute (FR-1).
  A `complete` job still returns `{jobId,status:"complete",roadmap:{…}}`.
- **(Reserved, not built here)** a future `GET /v1/me/artifacts` (list the `ARTIFACT#`
  index) for the admin/DSAR work ([`0034`]/[`0033`]).

iOS impact is minimal: `GradeRequestDTO` gains the optional id fields (encode when
known); no decode change. `RoadmapGenerator`'s POST→poll loop is untouched.

### 6.6 Lifecycle (FR-11)

Add S3 lifecycle rules to `data_stack.bucket`:

- **Rule `transcripts-and-answers`** — prefix `users/` (or, more precisely, a tag/prefix
  scheme that targets `generation.json`/`answer.json`/`grading.json`): transition to
  **STANDARD_IA at 30 days**, **GLACIER at 90 days**. (Mirrors the analytics-lake
  lifecycle in `docs/DATA_MODEL.md` and `analytics_stack`.)
- **Keep `roadmap.json` readily readable.** Because a user can poll a `complete` job (and
  re-open a journey) well after creation, either (a) exclude `roadmap.json` from the
  aggressive tier (rule scoped to the transcript/answer file names via object tags set at
  `put_object`), or (b) accept IA for `roadmap.json` too (IA still supports immediate
  GET; only Glacier needs restore). **Recommend tagging** artifacts at write time
  (`artifact-class=transcript|answer|grading|roadmap`) and scoping the Glacier transition
  to `transcript|answer|grading` so `roadmap.json` never needs a restore (D-5).
- **Do not Object-Lock anything.** Object Lock (WORM) would make `users/<sub>/` objects
  **undeletable** for the retention period, breaking `DELETE /v1/me` and GDPR/CCPA
  erasure. Explicitly **out** (a stated invariant of this spec).
- **`books/<bookId>.txt`/`content.txt` + `provenance.json`** are content, read by every
  generation; **do not** transition them to Glacier (they'd need a restore mid-generation).
  Either leave them Standard or IA-only.

### 6.7 Diagrams

```
POST /v1/roadmaps/generate ──persist pending job (USER#sub / ROADMAPJOB#jobId)──▶ DDB
        │  async invoke {uid, jobId}                                jobId = correlation id
        ▼
   roadmap_worker ──agent.generate_roadmap()──▶ Bedrock InvokeModel
        │                                   (agent.py now returns InvokeResult:
        │                                    text, stopReason, usage, latencyMs)
        ├─ put roadmap.json     ─▶ S3 users/<sub>/roadmaps/<jobId>/roadmap.json
        ├─ put generation.json  ─▶ S3 users/<sub>/roadmaps/<jobId>/generation.json
        ├─ mark_complete: SET roadmapRef=<key>, roadmapMeta=…  (NO inlined roadmap) ─▶ DDB
        ├─ index ARTIFACT#<jobId>#roadmap / #generation  ─▶ DDB
        └─ log {"evt":"llm_call", jobId, tokens, latency, stopReason, cost, outcome}
                                                  │
GET /v1/roadmaps/jobs/{jobId} ──resolve roadmapRef → read S3──▶ {status, roadmap}

POST /v1/exercises/grade {roadmapId,lessonId,exerciseId,answer}
        │  user_id(event)  ── write-only users/* grant
        ├─ (model-graded) agent.grade() ─▶ Bedrock (InvokeResult captured)
        ├─ put answer.json   ─▶ S3 …/lessons/<lessonId>/<exerciseId>/answer.json
        ├─ put grading.json  ─▶ S3 …/<exerciseId>/grading.json
        └─ log {"evt":"llm_call", stage:"grade", …}     (index row via 0026 lesson-done path — D-3)

CloudWatch metric filters ─▶ GenerationFailures · Truncations · GenerationLatencyMs(p99) ─▶ alarms
                                                  (dashboard + Budgets = 0032)

DELETE /v1/me ──sweep USER#<sub> items (incl. ARTIFACT#) + users/<sub>/ objects──▶ all purged
```

## 7. Acceptance criteria

- [ ] **AC-1 (roadmap in S3 + pointer).** After a successful generation,
      `users/<sub>/roadmaps/<jobId>/roadmap.json` exists with the roadmap body, the job
      row has `roadmapRef` (and **no** large inlined `roadmap` attribute), and
      `GET /v1/roadmaps/jobs/{jobId}` still returns `{status:"complete",roadmap:{…}}` by
      resolving the pointer. *(`test_worker_writes_roadmap_to_s3_and_pointer`,
      `test_get_job_resolves_pointer` — moto S3+DDB.)*
- [ ] **AC-2 (transcript captured).** Both a successful and a failed generation write
      `generation.json` containing `system`, `user`, `modelId`, `promptHash`, raw model
      text, `stopReason`, `inputTokens`, `outputTokens`, `latencyMs`, `outcome`.
      *(`test_generation_transcript_success`, `test_generation_transcript_failure`.)*
- [ ] **AC-3 (agent.py boundary).** `agent._invoke` returns an `InvokeResult` with
      `stop_reason`/`usage`/`latencyMs`/`modelId`; `generate_roadmap`/`grade` return
      `(parsed, meta)`; the adaptive-thinking call + single plain-body retry +
      `extract_json` behavior is preserved. *(`test_invoke_returns_meta`,
      `test_invoke_retries_on_thinking_rejection`.)*
- [ ] **AC-4 (grade identity + grant).** `grade_exercise.handler` calls `user_id`
      (returns 401 on `PermissionError`); `cdk synth` shows `grade_fn` has a **write-only**
      `s3:PutObject` on `…/users/*` and **no** `GetObject`/`ListBucket`/table grant.
      *(`test_grade_requires_user_id`, IAM assertion in
      `test_grade_grant_is_write_only_prefix_scoped` over the synthesized template.)*
- [ ] **AC-5 (answer + grading persisted).** A reflection grade writes `answer.json`
      (the submitted text + kind + prompt) and `grading.json` (score, feedback,
      xpAwarded, and the raw model envelope incl. tokens/latency/stopReason); a quiz
      grade writes both with the deterministic result and no model envelope.
      *(`test_grade_persists_answer_and_grading_reflection`,
      `test_grade_persists_quiz`.)*
- [ ] **AC-6 (provenance).** `content_parse` writes `books/<bookId>/provenance.json`
      with source/type/fetchedAt/parser/wordCount/contentHash/contentKey. *(`test_content_parse_writes_provenance`.)*
- [ ] **AC-7 (artifact index).** Roadmap + generation index rows
      (`ARTIFACT#<jobId>#roadmap|generation`) are written with `s3Key` + int metadata
      (tokens/latency/`estCostMicroUsd`/`stopReason`); a query
      `PK=USER#<sub> AND begins_with(SK,"ARTIFACT#")` enumerates them. No float
      attributes. *(`test_artifact_index_rows`, `test_index_no_floats`.)*
- [ ] **AC-8 (best-effort).** With S3 (and/or the index write) made to fail, generation
      still returns `complete` and grading still returns the correct score — the request
      never fails because of artifact/index/log errors. *(`test_artifact_write_failure_is_swallowed`,
      `test_grade_unaffected_by_s3_failure`.)*
- [ ] **AC-9 (structured logs + correlation id).** Each model call emits a single JSON
      log line carrying `jobId`, `modelId`, `latencyMs`, token counts, `estCostMicroUsd`,
      `promptHash`, `stopReason`, `outcome`; `jobId` matches POST→worker→job row.
      *(`test_log_line_shape`, captured via caplog/stdout.)*
- [ ] **AC-10 (metric filters + alarms synth).** `cdk synth -c stage=beta` produces the
      `Mango/Generation` metric filters (`GenerationFailures`, `Truncations`,
      `GenerationLatencyMs`) and alarms (failure-rate, truncation, p99). *(Synth
      assertion `test_generation_metrics_and_alarms_synthesized`.)*
- [ ] **AC-11 (lifecycle, no Object Lock).** The bucket has a lifecycle rule
      transitioning transcript/answer/grading artifacts to IA@30d/Glacier@90d;
      `roadmap.json` (or its tag class) is **not** sent to Glacier; **no** Object-Lock
      configuration exists. *(Synth assertion `test_lifecycle_rules_and_no_object_lock`.)*
- [ ] **AC-12 (deletion completeness).** After `DELETE /v1/me`, the user's
      `roadmap.json`/`generation.json`/`answer.json`/`grading.json` and all `ARTIFACT#`
      index rows are gone (shared `books/<id>/…` remain). *(`test_delete_purges_all_artifacts`.)*
- [ ] **AC-13 (offline/mock + invariants).** Fresh install, Mock AI, no network: a
      journey is built with no S3 writes required; `make ios-test` green; backend
      `pytest` + `cdk synth -c stage=beta` green; black/flake8 clean. *(CI + offline run.)*

## 8. Test plan

- **Unit (backend, pytest + moto for S3/DDB, Bedrock monkeypatched):**
  - `agent.py` boundary (AC-3): `test_invoke_returns_meta` (asserts `stop_reason`/`usage`/
    `latencyMs`/`modelId` populated from a stubbed Bedrock payload incl. a `usage` block),
    `test_invoke_retries_on_thinking_rejection` (a `ClientError` on the thinking body →
    one plain-body retry, meta still returned), `test_generate_roadmap_returns_tuple`,
    `test_grade_returns_tuple`.
  - `shared/artifacts.py` (AC-1/2/5/6/7/8): `put_artifact`/`put_exercise_artifact`/
    `put_provenance` write the expected keys + bodies (moto); `index_artifact` writes a
    float-free row; `est_cost_micro_usd` returns an int for a known model and `None` for
    an unknown one; **every** helper swallows an injected `ClientError` and returns
    `None`/`False` without raising.
  - `roadmap_worker`/`generate_roadmap` (AC-1/2/8): success writes roadmap+generation+
    pointer+index and logs `outcome=complete`; a generation exception writes the failure
    transcript, calls `mark_failed`, and logs `outcome=failed`; an S3 failure does not
    change the job outcome.
  - `roadmap_jobs.get_job` (AC-1): resolves `roadmapRef`→S3 for a `complete` job; returns
    the same public view shape; handles a missing/unreadable object gracefully (falls
    back to status-only, logged).
  - `grade_exercise` (AC-4/5/8): `user_id` enforced (401 path); reflection path writes
    answer+grading with the model envelope; quiz path writes both deterministically;
    absent `roadmapId`/ids → grading still returns the correct score and **skips**
    persistence; an S3 PutObject failure is swallowed.
  - `content_parse` (AC-6): provenance written with hashes; content write path unchanged.
  - `delete_account` (AC-12): seed a user's artifacts + `ARTIFACT#` rows + a shared
    `books/<id>/…` object → after delete, user artifacts + rows gone, shared object
    remains.
- **CDK synth assertions (AC-4/10/11, `tests/` over the synthesized template):**
  `grade_fn`'s policy is write-only `PutObject` on `…/users/*` with no read/list/table;
  the `Mango/Generation` metric filters + alarms exist; the lifecycle rule
  (IA@30/Glacier@90 for transcript/answer/grading) exists and **no**
  `ObjectLockConfiguration` is present; the worker has bucket **write** scoped to
  `users/*`.
- **Logging (AC-9):** capture stdout/`caplog`; assert one `llm_call` JSON line per model
  call with the required keys and the `jobId` matching the job row.
- **iOS (unit, minimal):** `GradeRequestDTO` encodes the new optional id fields when
  present and omits them when nil (lenient, mirrors existing DTO tests); no decode change
  for the grade response or the job poll.
- **Manual (beta):** run a real generation + a reflection grade signed-in on beta;
  confirm the four artifacts land in S3 under `users/<sub>/roadmaps/<jobId>/…`; confirm a
  forced `max_tokens` truncation (tiny `max_tokens`) trips the `Truncations` alarm; pull a
  `generation.json` and read the raw output; run `DELETE /v1/me` and confirm the prefix is
  empty.
- **Regression:** existing 29 backend tests + `cdk synth ×stages` + `make ios-test` stay
  green; the grade/generate/poll/delete contracts are behavior-preserving (only additive
  request fields + an internal pointer resolve).

## 9. Rollout & migration

- **Flags / config.** `ARTIFACTS_ENABLED` (default **on** in deployed stages; the inline/
  offline path no-ops regardless), `XRAY_ENABLED` (default **off**), and a
  `BEDROCK_PRICE_TABLE` config (per-model input/output per-1k-token micro-USD) for cost
  estimation. New env: none beyond these (reuses `BUCKET_NAME`/`TABLE_NAME`).
- **Backward compatibility.**
  - **Contract:** grade request fields are **additive + optional**; the grade response
    and the job-poll response are **unchanged**. Old iOS builds keep working (they just
    don't send the ids → no per-exercise artifact, which is fine).
  - **Data — the pointer cutover.** Existing `complete` job rows carry an inlined
    `roadmap` string. `get_job` MUST read **either** `roadmapRef` (new) **or** the legacy
    inlined `roadmap` (old) so in-flight jobs created before deploy still resolve. New
    completions write the pointer only. No backfill of historical rows is required (they
    age out via the job TTL that [`0026`]/[`0032`] add); optionally a one-off migration
    can move inlined roadmaps to S3, but it is **not** required.
  - **Offline/mock:** untouched — no S3, no Bedrock, no index on that path.
- **Stages of rollout.** (1) Land `agent.py` capture + `shared/artifacts.py` + the
  worker/grade/content_parse writes + the `grade_fn` grant + `get_job` dual-read, behind
  `ARTIFACTS_ENABLED`, dark in **beta**. (2) Add the metric filters + alarms + lifecycle
  (synth-verified). (3) Watch the alarms + read a few `generation.json` on beta. (4)
  Promote to prod. (5) Enable X-Ray only if/when the async-hop latency needs tracing.
- **Coordination.** Land **before/with** [`0038`] (which writes its per-stage artifacts
  through this store) and alongside [`0028`] (whose `templates/` prefix is reserved here)
  and [`0026`] (which adds the job **TTL** and may own the grade **index** write per D-3).
  [`0032`] builds the dashboard/Budgets/DLQ on top of these metrics; sequence its
  dashboard work after this spec emits the metrics.
- **Teardown / cost control.** Lifecycle ages transcripts to IA/Glacier; the job TTL
  reaps old job rows (and the resolve falls back gracefully if an artifact is gone); the
  whole feature can be turned off with `ARTIFACTS_ENABLED=false` if a problem appears,
  with **no** effect on the user-facing grade/roadmap responses.

## 10. Risks & open decisions

- **R-1 (the pointer cutover could break the poll for in-flight jobs).** *Mitigation:*
  `get_job` dual-reads `roadmapRef` **or** the legacy inlined `roadmap` (§9); covered by
  a test seeding a legacy row. No historical backfill needed.
- **R-2 (best-effort writes hide failures).** *Risk:* an artifact silently fails to
  persist and we don't notice. *Mitigation:* each write logs `{"evt":"artifact_put",
  ok:false}` and a CloudWatch metric filter can alarm on a sustained artifact-write
  failure rate (a cheap add to the 0032 dashboard); the *user-facing* path is
  intentionally unaffected (NFR-1).
- **R-3 (cost estimate drift).** Token-based estimation diverges from the real Bedrock
  bill (provisioned throughput, regional pricing, thinking tokens). *Mitigation:* it is
  explicitly **best-effort for trends/alarms** (NFR-8); the authoritative spend signal is
  AWS Cost Explorer / Budgets in [`0032`]. Price table is config-driven so it can be
  corrected without code.
- **R-4 (S3 write latency on the grade path).** Two `put_object`s per grade add latency.
  *Mitigation:* the grade Lambda has a 60 s budget and the model call dominates; the
  deterministic-quiz path's writes are tiny; if it ever matters, the writes can be made
  fire-and-forget (the handler returns before the puts complete) — but simplest is
  synchronous best-effort first.
- **R-5 (grade grant scope creep).** Giving `grade_fn` `users/*` write means it could
  write under *any* `users/<sub>/` prefix, not only the caller's. *Mitigation:* the
  handler always derives the prefix from `user_id(event)` (the JWT `sub`), so it can only
  write the caller's own prefix in practice; a tighter IAM condition keyed to the JWT sub
  isn't expressible for an HTTP-API JWT authorizer, so the **handler** enforces it. The
  grant is still **write-only** (no read of others' data) — strictly better than the
  full `grant_read_write` the worker has.
- **R-6 (lifecycle vs. re-open).** If `roadmap.json` were Glaciered, re-opening an old
  journey would need a restore. *Mitigation:* tag artifacts at write and scope the
  Glacier transition to `transcript|answer|grading` only (D-5), or accept IA (immediate
  GET) for `roadmap.json`.
- **R-7 (Object Lock temptation).** Someone may later "harden" the bucket with Object
  Lock for audit immutability. *Mitigation:* this spec **forbids** it (breaks GDPR/CCPA
  erasure via `DELETE /v1/me`); the deletion-completeness test (AC-12) would also fail.
- **R-8 (0038 reshapes the writer).** When the Step Functions pipeline lands, the
  *single* worker write becomes *per-stage* writes. *Mitigation:* the layout already
  reserves `…/roadmaps/<roadmapId>/<stage>.json` + `transcripts/<stage>.json` and the
  `agent.py` capture is per-call, so 0038 reuses `shared/artifacts.py` unchanged; this
  spec ships the single-call path and the seam.
- **Decisions needed (with recommendations):**
  - **D-1 (recommend `roadmapId == jobId` now; reserve `trackId` for 0038).**
  - **D-2 (recommend last-write-wins per-exercise files + `attemptId`; per-attempt
    objects behind a flag).**
  - **D-3 (recommend grade stays table-less; its index row written by the 0026
    lesson-done path; fallback (b) = a narrow `ARTIFACT#`-only `PutItem` grant).**
  - **D-4 (recommend keep `books/<bookId>.txt`; add `provenance.json`; `content.txt`
    rename optional/future).**
  - **D-5 (recommend tag artifacts `artifact-class=…` at write; scope Glacier to
    transcript/answer/grading so `roadmap.json` needs no restore).**
  - **D-6 (recommend X-Ray off by default, flag-gated).**

## 11. Tasks & estimate

1. **`agent.py` model-boundary capture** — `_invoke` returns `InvokeResult`
   (text/stop_reason/usage/latencyMs/modelId); `generate_roadmap`/`grade` return
   `(parsed, meta)`; preserve thinking-retry + `extract_json`; update existing tests to
   the tuple shape. **(S)**
2. **`shared/artifacts.py`** — `put_artifact`/`put_exercise_artifact`/`put_provenance`/
   `index_artifact`/`transcript_from_invoke`/`log_generation`/`est_cost_micro_usd`, all
   best-effort (swallow + log). **(M)**
3. **Worker + inline path writes** — write `roadmap.json` + `generation.json`, index
   rows; change `roadmap_jobs.mark_complete` to store `roadmapRef`+`roadmapMeta` (drop the
   inlined body); `mark_failed` writes the failure transcript. **(M)**
4. **`roadmap_jobs.get_job` pointer resolve** — read `roadmapRef`→S3 (dual-read legacy
   inlined `roadmap`); graceful fallback + log on a missing object. **(S)**
5. **`grade_exercise` rewrite** — call `user_id` (401 path); accept `roadmapId`/`lessonId`/
   `exerciseId`/`attemptId`; write `answer.json`+`grading.json` (model envelope on the
   model-graded path); skip persistence when ids absent; never let a write change the
   grade. **(M)**
6. **`content_parse` provenance** — write `books/<bookId>/provenance.json` after the
   content + META writes. **(S)**
7. **`api_stack.py` grants** — `grade_fn`: **write-only** `s3:PutObject` on `…/users/*`
   (new `PolicyStatement`, not `grant_read_write`); `roadmap_worker_fn`: add bucket
   **write** scoped to `users/*` (it currently only has `grant_read`). No table grant for
   grade. **(S)**
8. **CloudWatch metric filters + alarms** (CDK) — `Mango/Generation` namespace:
   `GenerationFailures`, `Truncations`, `GenerationLatencyMs`; alarms (failure-rate,
   truncation, p99). Shared names with [`0032`]. **(M)**
9. **S3 lifecycle** (CDK) — IA@30d/Glacier@90d for transcript/answer/grading (tag-scoped
   so `roadmap.json` stays Standard/IA); **no** Object Lock; leave `books/…` content out
   of Glacier. **(S)**
10. **X-Ray (optional, flag-gated)** — `tracing=Active` on roadmap + worker fns behind
    `XRAY_ENABLED`. **(S)**
11. **openapi.yaml + `DTOs.swift`** — add the optional grade-request id fields; note the
    pointer resolve on the job poll (no shape change); reserve a `GET /v1/me/artifacts`
    note for 0033/0034. **(S)**
12. **Tests** — unit (agent capture, artifacts helpers, worker, get_job resolve, grade,
    content_parse, delete completeness) + synth assertions (grade grant, metrics/alarms,
    lifecycle/no-Object-Lock, worker write scope) + logging assertion + iOS DTO encode.
    **(M)**
13. **Docs** — update `docs/DATA_MODEL.md` (the `users/<sub>/roadmaps/…` S3 layout, the
    `ARTIFACT#` index item, the `roadmapRef` pointer) and `working/INDEX.md` (flip 0027 to
    drafted). **(S)**

*Total: roughly 5 M + 7 S backend/CDK + a thin iOS DTO change, landable behind
`ARTIFACTS_ENABLED` with no user-facing contract change.*

## 12. References

**Repo (read for accuracy):**
- `CLAUDE.md` (invariants: Bedrock/IAM, stdlib+boto3, no DDB floats, least-privilege,
  offline-first); `docs/DATA_MODEL.md` (single-table keys, S3 zones, deletion cascade,
  the IA@30/Glacier@90 lifecycle precedent); `working/ARCHITECTURE_REVIEW.md` (**§2.2**
  the proposed design this spec expands; §1 as-built; §3 G5/G6/G7 observability gaps).
- Backend: `backend/mango_backend/data_stack.py` (the content bucket — no lifecycle
  today; SSE-S3/`enforce_ssl`/`BLOCK_ALL`), `backend/mango_backend/api_stack.py` (the
  grant loop **excluding `grade_fn`**; bucket grants; Bedrock policy; the async worker
  invoke), `backend/src/shared/roadmap_jobs.py` (`mark_complete` inlines `roadmap`;
  `get_job`; `create_pending`/`load_inputs`), `backend/src/shared/agent.py` (`_invoke`
  **discards** stop_reason/usage/latency; the adaptive-thinking + retry), `backend/src/
  shared/prompts.py`, `backend/src/shared/storage.py` (`table`/`s3_client`/`bucket_name`),
  `backend/src/handlers/generate_roadmap.py` (inline fallback path), `backend/src/
  handlers/roadmap_worker.py`, `backend/src/handlers/roadmap_status.py`, `backend/src/
  handlers/grade_exercise.py` (**no `user_id`, no grant**), `backend/src/handlers/
  content_parse.py` (writes `books/<id>.txt` + META), `backend/src/handlers/
  delete_account.py` (`users/<sub>/` + `USER#<sub>` cascade), `backend/src/shared/
  response.py` (`user_id` JWT/dev fallback). Contract: `shared/api/openapi.yaml`
  (`GradeRequest`, `RoadmapJob`).
- **Sibling specs:** `working/0026-server-side-activity-achievement-tracking.md` (DDB
  tracking + events-lake routing; job TTL; the grade index-write path, D-3),
  `working/0028-shared-book-roadmap-cache.md` (`templates/<bookId>/<ver>.json` in this
  layout; `BOOK#<id>/ROADMAP`), `working/0032-observability-cost-reliability.md`
  (dashboards + AWS Budgets + worker DLQ/retry — consumes these metrics/logs),
  `working/0038-agentic-roadmap-engine.md` (writes per-stage artifacts + transcripts
  through this store; reserved `…/<stage>.json` paths), `working/0039-activity-type-framework.md`
  (`submissions/<sub>/<activityId>/…` media prefix; the richer Activity/submission schema),
  `working/0015-analytics-events-ios.md` (the *other* substrate — aggregate analytics, not
  inspectable artifacts).

**Research (web):**
- AWS — *Organizing objects using prefixes* (key-naming conventions; prefixes are the unit
  of lifecycle scoping, IAM resource scoping, and listing) —
  https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-prefixes.html
- AWS — *Managing the lifecycle of objects* (transition to STANDARD_IA / GLACIER by
  prefix or tag; the IA@30/Glacier@90 pattern; restore semantics for archived tiers) —
  https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lifecycle-mgmt.html
- AWS — *S3 Object Lock overview* (WORM retention makes objects undeletable for the
  retention period — why it is incompatible with GDPR/CCPA per-user erasure here) —
  https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock-overview.html
- AWS — *Analyze metrics with CloudWatch Logs metric filters* (extract numeric/structured
  values from JSON logs into metrics; alarm on them — the failure-rate/truncation/p99
  alarms) — https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/MonitoringLogData.html
- AWS — *Logging best practices: structured JSON + a correlation id across services* (one
  id threaded end-to-end for trace-by-id; the `jobId` spine) —
  https://docs.aws.amazon.com/prescriptive-guidance/latest/logging-monitoring-for-application-owners/structured-logging.html
- AWS — *Amazon Bedrock InvokeModel response* (`stopReason`, the `usage` input/output
  token block — the fields `agent.py` must capture for cost + truncation observability) —
  https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_InvokeModel.html
- AWS — *Using AWS X-Ray with Lambda* (active tracing across an async invoke; subsegments
  around a downstream call — the optional POST→worker→Bedrock trace) —
  https://docs.aws.amazon.com/lambda/latest/dg/services-xray.html
