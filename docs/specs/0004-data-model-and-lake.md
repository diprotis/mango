# 0004 — Data model + S3 data lake

- **Epic:** M4 · **Status:** Draft · **Updated:** 2026-06-25

## 1. Summary
Durable per-user storage in the DynamoDB single table (profile, library, roadmaps,
progress, reflections, activity, achievements) plus an S3 **data lake** (raw content +
curated analytics events) with a complete deletion path.

## 2. Goals / Non-goals
- **Goals:** finalized access patterns + entity model; persist/sync user data;
  analytics-ready event lake; account-deletion completeness; `openapi.yaml` ⇄ DTOs in sync.
- **Non-goals:** the dashboards themselves (M11); social (M8); the device↔cloud sync
  client (M5 consumes this).

## 3. Background
Single table (`PK`/`SK` + `GSI1`) and a content S3 bucket exist; `/v1/me/progress`
exists. This epic expands to the full per-user model and needs identity from 0003.

## 4. Entities & keys (single table)

| Entity | PK | SK | GSI1PK / GSI1SK | Notes |
|---|---|---|---|---|
| Profile | `USER#<sub>` | `PROFILE` | — | goals, interests, settings |
| Progress | `USER#<sub>` | `PROGRESS` | — | XP, streak (exists) |
| Library item | `USER#<sub>` | `BOOK#<bookId>` | `USER#<sub>` / `ADDED#<ts>` | per-user book + progress |
| Book meta | `BOOK#<bookId>` | `META` | — | exists |
| Roadmap | `BOOK#<bookId>` | `ROADMAP` | — | cache (exists) |
| Reflection | `USER#<sub>` | `REFLECTION#<ts>` | — | journal |
| Activity | `USER#<sub>` | `ACTIVITY#<date>` | — | daily totals |
| Achievement | `USER#<sub>` | `ACHV#<key>` | — | unlocked |

## 5. Requirements
- **FR-1** Endpoints (new): `GET/PUT /v1/me/profile`; `GET/POST /v1/me/library`,
  `DELETE /v1/me/library/{bookId}`; `GET/POST /v1/reflections`; `DELETE /v1/me`.
- **FR-2** Reuse existing `/v1/me/progress`, `/v1/content/parse`,
  `/v1/roadmaps/generate`, `/v1/exercises/grade`.
- **FR-3** **Event lake:** progress/lesson/exercise events → API → **Firehose** →
  `s3://<analytics>/events/dt=YYYY-MM-DD/` as parquet; Glue catalog + Athena.
- **FR-4** Raw zone: book text + source metadata under `raw/…`, partitioned.
- **FR-5** `DELETE /v1/me` removes all `USER#<sub>` items **and** the user's S3 objects.
- **NFR:** idempotency keys on writes; optimistic concurrency (version attr) on
  progress; `float`→`int`/Decimal-safe; SSE-KMS; prod PITR; S3 lifecycle raw→IA→Glacier;
  least-privilege IAM.

## 6. Design
New Lambda handlers: `profile`, `library`, `reflections`, `delete_account` (thin;
logic in `src/shared/`). New CDK: a Firehose delivery stream + Glue database + a
separate **analytics** S3 bucket (distinct from the content bucket), wired in
`data_stack.py` or a new `analytics_stack.py`; least-privilege grants. Document the
schema + access patterns in a new `docs/DATA_MODEL.md`; update `openapi.yaml` + iOS DTOs.

## 7. Acceptance criteria
- [ ] A user's books/roadmaps/progress survive reinstall (read back from DDB) — pairs with M5.
- [ ] Reflections persist and list in order.
- [ ] Events land as parquet in the analytics bucket and are queryable in Athena.
- [ ] `DELETE /v1/me` removes every `USER#<sub>` item and the user's S3 objects (verified).
- [ ] `openapi.yaml` ⇄ DTOs ⇄ handlers in sync; pytest covers each new handler.

## 8. Test plan
pytest (moto) for profile/library/reflections + the deletion cascade; `cdk synth` for
Firehose/Glue/bucket; manual Athena query after a beta deploy.

## 9. Rollout & migration
Deploy to dev/beta; existing `PROGRESS` rows remain compatible (no migration). Add
`DATA_MODEL.md`. Cost guardrails + lifecycle on the analytics bucket.

## 10. Risks & open decisions
- **Decision:** keep **single-table** (recommended) vs multi-table.
- **Decision:** analytics via **Firehose→parquet→Athena** (recommended) vs a lighter
  "write JSON to S3" first, Athena later.
- Risk: deletion completeness across S3 prefixes — enumerate by `user/<sub>/` prefix.

## 11. Tasks
1. Finalize access patterns + `DATA_MODEL.md` (M). 2. `profile`/`library`/`reflections`
handlers + tests (M). 3. `delete_account` cascade + tests (M). 4. Analytics stack
(Firehose/Glue/bucket) + synth (L). 5. openapi + DTO sync (S).

## 12. References
`backend/mango_backend/data_stack.py`, `backend/src/handlers/progress.py`,
`shared/api/openapi.yaml`, [../ROADMAP.md](../ROADMAP.md) M4/M5/M11.
