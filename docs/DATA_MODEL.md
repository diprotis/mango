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
