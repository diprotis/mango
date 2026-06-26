# 0006 — Analytics data lake + feature store + events ingestion

- **Epic:** M11 · **Status:** Draft · **Owner:** platform · **Updated:** 2026-06-25
- **Reviewers:** backend, analytics

## 1. Summary
Stand up the storage and ingestion backbone for Mango analytics: an **analytics S3
data lake** (zoned by key prefix), a **Kinesis Firehose** events pipeline fed by a
new `POST /v1/events` endpoint, a **Glue/Athena** catalog over the event log, and an
online **feature-store DynamoDB table** for per-user/book aggregates. This is the
infrastructure half of the analytics platform sketched in spec
[`0004-data-model-and-lake.md`](0004-data-model-and-lake.md) §S3 lake / FR-3; the
dashboards and feature pipelines that consume it are separate, later work.

## 2. Goals / Non-goals
- **Goals:**
  - A durable, lifecycle-managed analytics bucket with clear zones (`raw/`,
    `events/`, `curated/`, `feature-store/`).
  - App → API → Firehose → S3 events ingestion that is **best-effort** and never
    degrades a user request.
  - Athena-queryable event log via a Glue database + table.
  - An online feature store (DynamoDB) keyed by entity + feature name.
  - Least-privilege IAM throughout (Firehose role; only `events_fn` may
    `PutRecord`).
- **Non-goals:** analytics dashboards (M11 reporting); the batch/stream jobs that
  populate `curated/` and `feature-store/`; parquet conversion / Glue crawlers
  (event log starts as JSON, partition registration is a follow-up); consuming
  features at inference time; PII minimization policy beyond what's noted here.

## 3. Background & context
The product bucket (`DataStack`) holds book text + per-user artifacts and is the
deletion target for `DELETE /v1/me`. Spec 0004 deliberately deferred the **analytics**
lake (a *separate* bucket) and the events pipeline. The app already produces
gamification signals (XP, lessons, exercises, streaks) that are valuable for product
analytics and, later, personalization — but there is nowhere to land them. This spec
adds that substrate without touching the product data path.

## 4. User stories
- As a **product analyst**, I want lesson/exercise/progress events in a queryable
  lake, so that I can measure activation, retention, and funnel drop-off in Athena.
- As a **personalization engineer**, I want an online store of per-user aggregates,
  so that future features (recommendations, difficulty tuning) can read them with
  single-digit-ms latency.
- As an **app developer**, I want a single fire-and-forget `POST /v1/events`, so that
  instrumenting a new event is one call and a flaky pipeline never breaks the app.

## 5. Requirements
**Functional**
- **FR-1** A `POST /v1/events` endpoint accepts `{ "type": string, "props"?: object }`,
  resolves the caller id from the JWT (`shared.response.user_id`), and returns
  `{ "accepted": true }`. Missing/blank `type` → 400; non-object `props` → 400; missing
  identity → 401.
- **FR-2** Accepted events are written to a **Kinesis Firehose** delivery stream as one
  newline-delimited JSON record `{ ts, type, userId, props }`.
- **FR-3** Firehose lands records in the analytics bucket under
  `events/dt=YYYY-MM-DD/` (GZIP), with delivery failures routed to `events-errors/`.
- **FR-4** A **Glue** database `mango_<stage>` + `events` table (JSON SerDe, partitioned
  by `dt`, columns `ts,type,userId,props`) makes the log queryable in Athena.
- **FR-5** A **feature-store** DynamoDB table `MangoFeatures-<stage>` (PK `entityId`,
  SK `featureName`, PAY_PER_REQUEST) provides the online store for aggregates.

**Non-functional**
- **NFR-1 (resilience):** event emission is best-effort — if the stream env var is
  absent or the put fails, `put_event` is a no-op returning `False`; the request still
  succeeds. The app must keep working fully offline (Mock path emits nothing).
- **NFR-2 (security):** bucket blocks public access, SSE-S3, `enforce_ssl`; Firehose
  role is scoped to the analytics bucket; only `events_fn` is granted
  `firehose:PutRecord`/`PutRecordBatch` on the stream ARN. Handlers stay
  stdlib+boto3.
- **NFR-3 (cost):** lifecycle ages objects raw→IA@30d→Glacier@90d; Firehose buffers
  64 MB / 60 s to keep object counts and request costs low; both tables are
  on-demand.
- **NFR-4 (durability/compliance):** prod bucket + feature table use
  `RemovalPolicy.RETAIN` and PITR; non-prod uses `DESTROY` (+ `auto_delete_objects`).
- **NFR-5 (privacy):** events carry `userId` (the Cognito sub) and arbitrary `props`
  — emit only non-sensitive product signals; user-erasure of the event lake is a
  documented follow-up (see §9).

## 6. Design
- **API / contract:** add `POST /v1/events` (secured) to the HTTP API. Request
  `{ "type": "lesson_completed", "props": { "bookId": "…", "xp": 10 } }` → `200
  { "accepted": true }`. Keep `shared/api/openapi.yaml` ⇄ iOS DTOs in sync when the
  client starts emitting (client wiring is out of scope here).
- **Lambda:** `handlers/events.py` (thin) validates and calls
  `shared/firehose.put_event(type, user_id, props)`. `shared/firehose.py` owns the
  boto3 client (lazily created + memoized) and the record shape; tolerant of a missing
  `EVENTS_STREAM_NAME`.
- **CDK (`analytics_stack.py`, new `AnalyticsStack(Stack)` taking `*, config`):**
  - **S3 bucket** — block public, SSE-S3, `enforce_ssl`; lifecycle IA@30d→Glacier@90d;
    zones as key prefixes `raw/ events/ curated/ feature-store/`.
  - **Firehose** — L1 `CfnDeliveryStream` (DirectPut), extended-S3 destination → the
    bucket, prefix `events/dt=!{timestamp:yyyy-MM-dd}/`, `errorOutputPrefix`
    `events-errors/`, GZIP, 64 MB / 60 s buffering; dedicated IAM role with read/write
    on the bucket.
  - **Glue** — L1 `CfnDatabase` `mango_<stage>` + `CfnTable` `events` (external,
    JSON SerDe, partition key `dt`, S3 location `s3://<bucket>/events/`).
  - **Feature store** — DynamoDB `MangoFeatures-<stage>` (PK `entityId`, SK
    `featureName`, on-demand, prod PITR).
  - Exposes `analytics_bucket`, `delivery_stream_name` (the stream's `ref`),
    `features_table`.
- **Wiring (handled by the orchestrator, not this change):**
  - `stage.py`: `analytics = AnalyticsStack(self, "Analytics", config=config)`; pass
    `analytics_bucket`, `events_stream_name=analytics.delivery_stream_name`,
    `features_table` into `ApiStack`.
  - `api_stack.py`: accept the kwargs; `events_fn = make_fn("EventsFn",
    "handlers.events.handler", timeout=10)`; env `EVENTS_STREAM_NAME`; grant
    `firehose:PutRecord`/`PutRecordBatch` on the stream ARN to `events_fn`;
    `route("/v1/events", POST, events_fn)`.
- **Data layout / lifecycle:** see [`../DATA_MODEL.md`](../DATA_MODEL.md) §"Data lake &
  feature store".

## 7. Acceptance criteria
- [ ] `POST /v1/events` returns `200 {"accepted": true}` for a valid event and `400`
      for a missing/blank `type` or non-object `props`; `401` without identity.
- [ ] A valid event produces exactly one Firehose `put_record` with a newline-
      terminated JSON record `{ts,type,userId,props}` on the configured stream.
- [ ] With no `EVENTS_STREAM_NAME`, `put_event` returns `False` and the handler still
      returns `200` (no exception).
- [ ] `AnalyticsStack` synthesizes for beta + prod: bucket (lifecycle IA→Glacier),
      Firehose (GZIP, `events/dt=…/` prefix, 64 MB/60 s), Glue db+table, features
      table (prod PITR, RETAIN).
- [ ] Events land under `events/dt=YYYY-MM-DD/` and are queryable in Athena after a
      beta deploy (manual).

## 8. Test plan
- **Unit (pytest, `tests/test_events.py`):** monkeypatch the Firehose client to a fake
  capturing `put_record`; assert accept + record shape, `type`/`props` validation, and
  the no-op-without-stream behavior. (No moto Firehose; pure monkeypatch.)
- **Synth:** `cdk synth -c stage=beta` includes the bucket, Firehose, Glue db/table,
  and features table (verified here by in-process `app.synth()` template assembly).
- **Manual (post-deploy):** `POST /v1/events`, wait a buffer interval, confirm an
  object under `events/dt=…/`, run an Athena `SELECT` against `mango_<stage>.events`.

## 9. Rollout & migration
Deploy `AnalyticsStack` alongside the existing stacks (new resources, no migration of
existing data). The endpoint is additive; clients adopt it incrementally. Partition
registration for Athena (`MSCK REPAIR TABLE` / Glue crawler / partition projection) is
a follow-up. **Deletion:** the event lake is *not* yet covered by `DELETE /v1/me`
(which erases the product bucket + DDB) — user-erasure of analytics events (e.g.
partition rewrite, TTL, or moving to per-user prefixes) is a tracked follow-up and a
GDPR/CCPA prerequisite before storing anything sensitive in `props`.

## 10. Risks & open decisions
- **Decision (recommended):** start the event log as **JSON** (simplest, schema-on-read)
  and convert to **parquet** later via a Firehose format conversion or a curated job —
  vs. parquet from day one (needs a Glue schema in the delivery config). Recommend
  JSON-first.
- **Decision:** Athena partition strategy — **partition projection** on `dt`
  (recommended, no crawler) vs. a Glue crawler vs. manual `ALTER TABLE`.
- **Risk:** `props` is free-form — schema drift and accidental PII. Mitigate with an
  allow-list of event types/props in the client and the deletion follow-up above.
- **Risk:** event-lake erasure completeness (see §9) before any sensitive data lands.

## 11. Tasks & estimate
1. `AnalyticsStack` (bucket+lifecycle, Firehose+role, Glue db/table, features table) (L).
2. `shared/firehose.py` + `handlers/events.py` (S).
3. `tests/test_events.py` (S).
4. Wire `stage.py` + `api_stack.py` (route, env, grant) (S).
5. Docs: this spec + `DATA_MODEL.md` section (S).
6. *(Follow-up)* openapi + iOS DTO + client emission; Athena partition projection;
   event-lake deletion path (M).

## 12. References
`backend/mango_backend/analytics_stack.py`, `backend/src/shared/firehose.py`,
`backend/src/handlers/events.py`, `backend/tests/test_events.py`,
[`0004-data-model-and-lake.md`](0004-data-model-and-lake.md),
[`../DATA_MODEL.md`](../DATA_MODEL.md), [`../ROADMAP.md`](../ROADMAP.md) M11.
