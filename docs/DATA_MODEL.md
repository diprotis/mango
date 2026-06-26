# Data model

Mango persists every user- and content-scoped entity in **one DynamoDB table**
(`PK`/`SK` + a `GSI1` index, pay-per-request) and keeps large/raw artifacts in S3.
This document is the source of truth for the entity/key layout and the access
patterns the API depends on. It pairs with spec
[`0004-data-model-and-lake.md`](specs/0004-data-model-and-lake.md), the contract
in [`shared/api/openapi.yaml`](../shared/api/openapi.yaml), and the handlers in
`backend/src/handlers/`.

## Single-table entities & keys

`<sub>` is the Cognito subject (the caller's id); `<ts>` is an ISO-8601 UTC
timestamp; `<date>` is `YYYY-MM-DD`.

| Entity | PK | SK | GSI1PK / GSI1SK | Attributes |
|---|---|---|---|---|
| Profile | `USER#<sub>` | `PROFILE` | — | `goals[]`, `interests[]`, `readingLevel`, `dailyGoalUnits`, `name`, `updatedAt` |
| Progress | `USER#<sub>` | `PROGRESS` | — | `totalXP`, `level`, `currentStreak`, `longestStreak`, `freezesAvailable`, `lastActiveDay`, `updatedAt` |
| Library item | `USER#<sub>` | `BOOK#<bookId>` | `USER#<sub>` / `ADDED#<ts>` | `addedAt` (per-user book reference + progress) |
| Reflection | `USER#<sub>` | `REFLECTION#<ts>` | — | `text`, `chapterRef?` |
| Activity | `USER#<sub>` | `ACTIVITY#<date>` | — | daily totals (XP, minutes) — *planned* |
| Achievement | `USER#<sub>` | `ACHV#<key>` | — | `unlockedAt` — *planned* |
| Book meta | `BOOK#<bookId>` | `META` | — | `title`, `author`, `wordCount`, `estimatedMinutes`, `coverHue`, `excerpt`, `contentRef` (S3 key) |
| Roadmap (cache) | `BOOK#<bookId>` | `ROADMAP` | — | `roadmap` (JSON string) |

Notes:

- **All numbers are stored as integers** (`dailyGoalUnits`, XP, streaks, …). The
  DynamoDB resource API rejects Python `float`; handlers coerce to `int` (or store
  JSON strings) before writing — see `progress.py` / `generate_roadmap.py`.
- DynamoDB returns numbers as `Decimal`; handlers normalize them back to `int`
  for JSON responses.
- Reflection SKs embed an ISO timestamp, so they sort chronologically and a
  reverse-ordered query (`ScanIndexForward=False`) yields newest-first with no
  extra index.

## Access patterns

| # | Need | Query |
|---|---|---|
| 1 | Read/write a profile | `GetItem` / `PutItem` on `USER#<sub>` / `PROFILE` |
| 2 | Read/write progress | `GetItem` / `PutItem` on `USER#<sub>` / `PROGRESS` |
| 3 | List a user's library | `Query PK = USER#<sub> AND begins_with(SK, "BOOK#")` (or GSI1 by `ADDED#` for add-order) |
| 4 | Add / remove a library book | `PutItem` / `DeleteItem` on `USER#<sub>` / `BOOK#<bookId>` |
| 5 | List reflections (newest first) | `Query PK = USER#<sub> AND begins_with(SK, "REFLECTION#")`, `ScanIndexForward=False` |
| 6 | Append a reflection | `PutItem` on `USER#<sub>` / `REFLECTION#<ts>` |
| 7 | Read book meta / cached roadmap | `GetItem` on `BOOK#<bookId>` / `META` \| `ROADMAP` |
| 8 | Delete a user (cascade) | `Query PK = USER#<sub>` (paginated) → `batch_writer` delete; then delete S3 under `users/<sub>/` |

## Endpoints (this epic)

All routes require a Cognito JWT (`Authorization: Bearer <token>`) except where
noted; identity is resolved from the JWT `sub` claim
(`shared.response.user_id`). Outside `prod`/`beta`, an `x-mango-user` header is
honored for local testing.

| Method & path | Lambda | Purpose |
|---|---|---|
| `GET /v1/me/profile` | `profile` | Read the caller's profile (defaults if absent) |
| `PUT /v1/me/profile` | `profile` | Upsert the caller's profile |
| `GET /v1/me/library` | `library` | List the caller's library books |
| `POST /v1/me/library` | `library` | Add a book reference (`{ "bookId": "…" }`) |
| `DELETE /v1/me/library/{bookId}` | `library` | Remove a book reference |
| `GET /v1/reflections` | `reflections` | List reflections, newest first |
| `POST /v1/reflections` | `reflections` | Append a reflection (`{ "text", "chapterRef?" }`) |
| `DELETE /v1/me` | `delete_account` | Erase all `USER#<sub>` items + S3 under `users/<sub>/` |

Reused (defined elsewhere): `GET/PUT /v1/me/progress`, `POST /v1/content/parse`,
`POST /v1/roadmaps/generate`, `POST /v1/exercises/grade`, `GET /health`.

## S3 data lake

| Zone | Prefix | Contents |
|---|---|---|
| Content | `books/<bookId>.txt` | Full normalized book text (referenced by `contentRef`) |
| Per-user | `users/<sub>/…` | User-scoped artifacts; **fully enumerated and deleted** by `DELETE /v1/me` |
| Raw (planned) | `raw/…` | Source text + metadata, partitioned |
| Events (planned) | `events/dt=YYYY-MM-DD/` | Curated analytics events (Firehose → parquet → Athena) |

## Account deletion

`DELETE /v1/me` is the completeness path required by spec 0004 (FR-5):

1. `Query` every item with `PK = USER#<sub>` (paginated via `LastEvaluatedKey`)
   and remove them with a `batch_writer`.
2. `list_objects_v2` under `users/<sub>/` (paginated) and `delete_objects` in
   batches of up to 1000.
3. Return a summary count (`itemsDeleted`, `objectsDeleted`).

Cognito user-pool deletion is performed by the app / Cognito, not this handler.

## Data lake & feature store

The **analytics** lake is a *separate* S3 bucket from the product/content bucket
above. It is provisioned by `AnalyticsStack`
(`backend/mango_backend/analytics_stack.py`) and pairs with spec
[`0006-data-lake.md`](specs/0006-data-lake.md). Nothing here is on the product
read/write path; it is an append-only analytics substrate.

### Zones (key prefixes in the analytics bucket)

| Zone | Prefix | Contents |
|---|---|---|
| Raw | `raw/` | Source/landing artifacts + metadata (partitioned) — *planned producers* |
| Events | `events/dt=YYYY-MM-DD/` | Newline-delimited JSON analytics events from Firehose (GZIP) |
| Events (errors) | `events-errors/` | Firehose delivery failures |
| Curated | `curated/` | Cleaned/joined datasets built from raw + events — *planned* |
| Feature store (offline) | `feature-store/` | Materialized feature sets for training/backfill — *planned* |

**Lifecycle:** objects transition **Standard → Infrequent-Access at 30 days →
Glacier at 90 days**. The bucket blocks public access, uses SSE-S3, enforces TLS,
and (in prod) is `RETAIN`ed; non-prod is `DESTROY` + `auto_delete_objects`.

### Events ingestion path

```
app → POST /v1/events → events Lambda → shared.firehose.put_event
    → Kinesis Firehose (mango-events-<stage>, DirectPut, GZIP, 64MB / 60s)
    → s3://<analytics>/events/dt=YYYY-MM-DD/
```

Each record is one line of JSON shaped to the Glue table columns:

```json
{ "ts": "<ISO-8601 UTC>", "type": "<event_type>", "userId": "<sub>", "props": { … } }
```

Emission is **best-effort**: if `EVENTS_STREAM_NAME` is unset (e.g. the offline /
Mock path or a stage without analytics wired) or the put fails, `put_event` is a
no-op returning `False` — a request never fails because of telemetry.

### Glue / Athena

A Glue database **`mango_<stage>`** holds an external **`events`** table over
`s3://<analytics>/events/` using the OpenX JSON SerDe, **partitioned by `dt`**, with
columns `ts string`, `type string`, `userId string`, `props string`. This makes the
event log queryable from Athena (e.g. `SELECT type, COUNT(*) FROM mango_<stage>.events
WHERE dt = '2026-06-25' GROUP BY type`). Partition registration (projection / crawler
/ `ALTER TABLE`) and any JSON→parquet conversion are follow-ups.

### Online feature store (DynamoDB)

`MangoFeatures-<stage>` is the **online** store for per-entity aggregates, separate
from the product table:

| PK (`entityId`) | SK (`featureName`) | Attributes |
|---|---|---|
| `USER#<sub>` \| `BOOK#<bookId>` | e.g. `xp_7d`, `completion_rate`, `streak_len` | `value`, `updatedAt` |

Pay-per-request; prod has PITR + `RETAIN`. The jobs that populate it (from the lake)
are out of scope of spec 0006.

### Deletion note

`DELETE /v1/me` currently erases the **product** bucket (`users/<sub>/`) and all
`USER#<sub>` DynamoDB items — it does **not** yet purge analytics **events** (which
are partitioned by date, not by user) or `MangoFeatures-<stage>` rows. Erasing the
event lake per user (partition rewrite, TTL, or per-user prefixes) is a tracked
follow-up and a privacy prerequisite before any sensitive data is placed in `props`.
Keep `props` to non-sensitive product signals until then.
