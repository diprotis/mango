# 0033 — Data export (DSAR) & deletion completeness

- **Epic:** M14 · **Status:** Draft · **Owner:** unassigned · **Updated:** 2026-06-28
- **Reviewers:** Principal / SD / QA / Legal

## 1. Summary
Mango can **delete** a user but cannot **export** one, and its deletion is **incomplete**.
`DELETE /v1/me` (`backend/src/handlers/delete_account.py`) purges every `USER#<sub>`
single-table item and every `users/<sub>/` object in the product bucket and best-effort
deletes the Cognito user — but it **does not** touch the *separate analytics lake*: the
date-partitioned Firehose events under `events/dt=YYYY-MM-DD/` and the per-entity rows in
`MangoFeatures-<stage>` survive a user delete (a privacy gap explicitly flagged in
`docs/DATA_MODEL.md` §"Deletion note" and `ARCHITECTURE_REVIEW.md` §3 **G9**). And there
is **no data export at all** — even though `docs/GAMIFICATION.md` §2(j) promises "the
journal belongs to the user — easy export," and **G8** calls out the missing GDPR/CCPA
access-and-portability path. This spec completes the privacy story in one coherent unit
of work:

1. **Data export (DSAR access + portability).** A new async, user-scoped
   `GET /v1/me/export` assembles **everything we hold about the caller** — their
   `USER#<sub>` items (profile, progress, library + journey state, reflections, activity
   rollups, achievements, lesson/roadmap completions, ledgers), a manifest of their S3
   artifacts (`users/<sub>/…`), and (best-effort) their `MangoFeatures` rows — into a
   single downloadable **JSON bundle (zipped)** delivered via a **short-lived presigned
   URL**, reusing the **same async-job pattern** as roadmap generation
   (`POST → 202 {jobId} → poll`). The export object itself is written under
   `users/<sub>/exports/<jobId>/` (so it is itself purged by deletion) and **TTL-expired**.
2. **Deletion completeness.** `delete_account` is extended to (a) **delete the user's
   `MangoFeatures-<stage>` rows** (`entityId = USER#<sub>`) and (b) handle the
   **analytics-lake events**, for which we adopt a **realistic, layered mechanism**
   (recommended: **per-user deletion request → tombstone marker + a scheduled
   compaction/partition-rewrite job**, backed by a documented **retention-TTL** as the
   safety net), plus a **hard, enforced rule** that until lake-erase ships **`props`
   carries only non-sensitive ids/enums/scalars** (promoting the soft rule in
   `0015`/`docs/DATA_MODEL.md` to a *requirement* with a test). The `DELETE /v1/me`
   response is extended to **report analytics handling** so the contract is honest about
   what was erased synchronously vs. scheduled.
3. **Verification + audit.** Every DSAR (export or delete) is recorded in an **append-only
   audit log** (`USER#<sub>/DSAR#<ts>` + a structured log line) capturing request type,
   timestamp, actor, and outcome — the evidence trail a regulator expects — and a test
   asserts an exported/deleted user's data is actually gone.

All of it stays **float-free** DynamoDB, **stdlib + boto3** Lambdas, **single product
table** (the lake + `MangoFeatures` stay separate substrates), **offline-first**
(unaffected — export/delete require a real backend + session), keeps
`shared/api/openapi.yaml` ⇄ `ios/.../Services/Networking/DTOs.swift` ⇄ handlers in
lockstep, and explicitly avoids **S3 Object Lock** (which would make `users/<sub>/`
undeletable and break erasure).

This spec **owns the DSAR export + the cross-substrate deletion completeness**. It
**reads** the artifact-index surface defined by [`0027`] (the `USER#<sub>/ARTIFACT#…`
rows enumerate S3 artifacts for the export manifest), **reuses** the async worker idiom
of `roadmap_jobs`, **consumes** the events-lake schema from [`0015`]/0006, and
**coordinates** with [`0026`] (which adds the table **TTL attribute** this spec stamps on
export jobs and which owns the new tracking SKs that delete must cascade). It does **not**
build dashboards/Budgets ([`0032`]), Guardrails ([`0030`]), or COPPA/age handling
([`0031`]); it does the export + the erasure + the audit.

## 2. Goals / Non-goals
- **Goals:**
  - **`GET /v1/me/export` — async DSAR export.** Mint an export job
    (`USER#<sub>/EXPORTJOB#<jobId>`), async-invoke an **export worker** that assembles a
    bundle, and return `202 {jobId,status:"pending"}`; `GET /v1/me/export/jobs/{jobId}`
    polls and, when `complete`, returns a **presigned download URL** (short TTL) to the
    zipped JSON bundle in S3. Reuses the `roadmap_jobs` POST→worker→poll shape exactly.
  - **Complete, user-scoped bundle.** The export contains a structured JSON document of
    **all** of the caller's `USER#<sub>` items — `PROFILE`, `PROGRESS` (incl. `version`),
    library items (incl. `journeyState`/`confirmedMilestones`), `REFLECTION#…`,
    `ACTIVITY#<date>`, `ACHV#<key>`, `LESSONDONE#…`, `ROADMAPDONE#…`, any credit/ledger
    items ([`0023`]), and roadmap-job rows — **plus** a **manifest of S3 artifacts**
    (`users/<sub>/…`: roadmaps, transcripts, answers, grading from [`0027`]) listing
    `key`, `size`, `lastModified`, **plus** (best-effort) the user's `MangoFeatures` rows.
    The journal (reflections) is included in full (the `GAMIFICATION.md` promise).
  - **Self-purging, TTL'd export artifact.** The bundle is written to
    `users/<sub>/exports/<jobId>/export.zip` (so `DELETE /v1/me` already sweeps it) **and**
    expired by an **S3 lifecycle rule** on the `users/*/exports/` prefix (e.g. 7 days) **and**
    a DDB `ttlAt` on the export-job row — defence-in-depth so a download link never
    outlives its purpose.
  - **`MangoFeatures` deletion in `delete_account`.** On account delete, **also** delete
    every `MangoFeatures-<stage>` row with `entityId = USER#<sub>` (query by PK,
    batch-delete), behind a new least-privilege grant. Best-effort, reported in the
    response.
  - **Analytics-lake per-user erasure mechanism (design + initial implementation).** On
    delete, **record a per-user erasure request** (a **tombstone** marker:
    `USER#<sub>/LAKEERASE#requested` *before* the user row is purged → a durable
    `erasures/<sub>.json` object in the analytics bucket so the scheduled job can act after
    the user's table items are gone), and ship a **scheduled compaction/partition-rewrite
    job** (an EventBridge-scheduled Lambda) that periodically rewrites affected `events/`
    partitions to drop tombstoned `userId`s. Back this with a **documented retention-TTL**
    on `events/` as the guaranteed-erasure floor. (Three candidate mechanisms are
    evaluated in §6/§10; this is the recommendation.)
  - **Hard "non-sensitive `props`" requirement until lake-erase is real-time.** Promote the
    soft guidance to **FR + test**: the events `props` column MUST contain only ids, enums,
    dates, and small scalars — **never** reflection/answer/book text, emails, names, or
    tokens. This bounds the privacy blast radius of the eventually-consistent lake erasure.
  - **`DELETE /v1/me` reports analytics handling.** Extend the response to include
    `featuresDeleted:int`, `lakeErasureScheduled:bool` (and the request id), so the
    contract states honestly what was erased synchronously vs. scheduled.
  - **Audit log of DSAR requests.** Append `USER#<sub>/DSAR#<ts>` items
    (`{ type: export|delete, requestedAt, completedAt?, outcome, actor }`) **and** a
    structured JSON log line for every export/delete, for compliance evidence. (Delete's
    own audit row is necessarily written to a **separate** audit store, since the user row
    is being erased — see §6.6.)
  - **Verification.** Tests assert an exported bundle contains every item family, that the
    presigned URL downloads the object, that `MangoFeatures` rows are deleted, and that the
    tombstone/retention path erases (or schedules erasure of) lake events.
  - **Invariants preserved:** float-free DDB, stdlib + boto3, single product table,
    offline-first untouched, least-privilege IAM, best-effort writes never fail a request,
    **no S3 Object Lock**, contract lockstep.
- **Non-goals:**
  - **A self-service in-app "download my data / delete my account" UI flow** beyond the
    minimal client wiring to call the endpoints and present the download link. The full
    Settings → Privacy screen polish, confirmations, and copy are an **iOS task** folded
    into [`0022`] (App Store prep) / a Settings spec; here we ship the endpoints + DTOs +
    a thin call path and a manual verification.
  - **The artifact store + per-call LLM observability** — [`0027`] (this spec *reads* its
    `ARTIFACT#` index to build the export manifest; it does not define artifacts).
  - **The new tracking item families themselves** (`ACTIVITY#`/`ACHV#`/`LESSONDONE#`/
    `ROADMAPDONE#`, the table **TTL attribute**, the optimistic-lock `version`) — [`0026`]
    owns those; this spec **exports** and **deletes** them and **reuses** the TTL attribute.
  - **The credit ledger economics** — [`0023`]; this spec exports/deletes whatever ledger
    items exist and notes any **legal retention** exception (financial records) in §10.
  - **The analytics *producers/consumers*** (the iOS emitter, feature-store population) —
    [`0015`]/[`0020`]; this spec only adds the **erasure** side + the hardened `props` rule.
  - **Dashboards, Budgets, worker DLQ/retry** — [`0032`]; this spec emits audit logs +
    metrics it can chart, and the export/erasure workers reuse the existing async pattern
    without bespoke reliability plumbing (DLQ for the erasure job is a [`0032`] add-on).
  - **AI moderation / Guardrails** ([`0030`]) and **age assurance / COPPA** ([`0031`]).
  - **Converting `events/` to Iceberg** as the *only* erasure mechanism — evaluated and
    **deferred** (§10 D-3): it is the cleanest long-term answer but a larger lake migration
    than this spec scopes; the tombstone+rewrite+TTL design is forward-compatible with an
    Iceberg cutover.

## 3. Background & context

**As-built deletion (verified by reading the code).**
- `backend/src/handlers/delete_account.py` does exactly three things on `DELETE /v1/me`:
  `_delete_table_items(uid)` (`Query PK=USER#<uid>` paginated → `batch_writer` delete,
  returns `itemsDeleted`), `_delete_s3_objects(uid)` (`list_objects_v2` under
  `users/<uid>/` paginated → `delete_objects` in ≤1000 batches, returns `objectsDeleted`),
  and `_delete_cognito_user(uid)` (best-effort `admin_delete_user`, no-op without
  `COGNITO_USER_POOL_ID`). It returns `{deleted, itemsDeleted, objectsDeleted,
  cognitoDeleted}`. **It never references the analytics bucket, the Firehose stream, or
  `MangoFeatures-<stage>`.**
- `api_stack.py` constructs `delete_fn` with `table.grant_read_write_data` +
  `bucket.grant_read_write` (the **product** bucket) + a scoped `cognito-idp:AdminDeleteUser`
  grant. **`analytics_bucket` and `features_table` are passed into `ApiStack` but
  explicitly discarded** (`del analytics_bucket, features_table  # reserved for future
  producers`, `api_stack.py:33`). So today no API Lambda can touch either analytics
  substrate — wiring that grant is part of this spec.
- `docs/DATA_MODEL.md` §"Deletion note" states it plainly: *"`DELETE /v1/me` currently
  erases the product bucket … and all `USER#<sub>` DynamoDB items — it does **not** yet
  purge analytics **events** … or `MangoFeatures-<stage>` rows. Erasing the event lake per
  user (partition rewrite, TTL, or per-user prefixes) is a tracked follow-up and a privacy
  prerequisite before any sensitive data is placed in `props`. Keep `props` to
  non-sensitive product signals until then."* This spec is that follow-up.

**As-built analytics substrate (verified).**
- `AnalyticsStack` (`backend/mango_backend/analytics_stack.py`): a **separate** S3 bucket
  with zones `raw/ events/ curated/ feature-store/` and a whole-bucket lifecycle
  (Standard→IA@30d→Glacier@90d, **no expiration**); a **Firehose** `mango-events-<stage>`
  landing `POST /v1/events` records as **GZIP** under `events/dt=!{timestamp:yyyy-MM-dd}/`;
  a **Glue** db `mango_<stage>` + external `events` table (cols `ts,type,userId,props`,
  partitioned by `dt`, OpenX JSON SerDe); and the online **`MangoFeatures-<stage>`**
  DynamoDB table (PK `entityId` e.g. `USER#<sub>`/`BOOK#<id>`, SK `featureName`).
- `shared/firehose.py.put_event(type, user_id, props)` writes
  `{"ts","type","userId","props": json.dumps(props)}` + `"\n"`; **`userId` is the Cognito
  `sub`** — so the lake **already keys every event by `sub`**, which is exactly the dimension
  a per-user erasure needs (no schema change required to *find* a user's events; the
  challenge is *rewriting* the immutable GZIP partitions to remove them).
- `0015` §9 + `docs/DATA_MODEL.md` already commit to "keep `props` non-sensitive until the
  event-lake erasure follow-up lands" — soft today; this spec makes it enforced.

**As-built async pattern to reuse (verified).** `roadmap_jobs.py` + `generate_roadmap.py`
+ `roadmap_worker` + `roadmap_status` are the template: `POST` persists a pending job
(`USER#<sub>/ROADMAPJOB#<jobId>` carrying inputs), async-invokes the worker via
`lambda_client().invoke(InvocationType="Event", Payload={uid,jobId})` (granted via
`worker_fn.grant_invoke(poster_fn)` + `ROADMAP_WORKER_FUNCTION` env), and returns
`202 {jobId,status:"pending"}`; the worker does the slow work and `mark_complete`/
`mark_failed`; `GET …/jobs/{jobId}` (`get_job`) serves the poll. The **export job reuses
this verbatim** (a parallel `export_jobs.py` + `export_worker` + `export_status`), so the
client's POST→poll loop and the operational shape are identical and already tested.

**Invariants in play (`CLAUDE.md`).** Backend AI on Bedrock (irrelevant here — no model
calls). **Offline-first**: export/delete are server features requiring a real backend +
session; the Mock/offline first-run path is untouched. **No third-party iOS deps.**
**stdlib + boto3 only**; **DynamoDB rejects `float`** (export reads only — no new floats
written; `MangoFeatures` may hold non-int `value`s that we read and serialize to the JSON
bundle, which is fine — **S3 is not DynamoDB**). **`response.user_id`** trusts the JWT
`sub` in prod/beta. **`shared/http.py` SSRF guard** is unrelated (no outbound fetch here).

**Legal frame (see §12).** **GDPR Art. 15** (right of access — a copy of all personal data,
in a commonly used electronic form) and **Art. 20** (portability — machine-readable, the
data the subject provided) ⇒ the export bundle; **Art. 17** (erasure) ⇒ deletion
completeness; the response deadline is **one month** (extendable +2 months). **CCPA/CPRA**
adds the **right to know / access / portability** (a "portable, readily usable format")
and **right to delete**, with a **45-day** response window (+45). Both regimes accept an
**async, self-service, authenticated** export delivered as a downloadable file. Mango's
synchronous-ish (minutes) async job comfortably beats both deadlines; the audit log is the
evidence of timely fulfilment.

**Why now.** This is recommendation **§3 G8/G9** of `ARCHITECTURE_REVIEW.md` ("No
GDPR/CCPA data export (only deletion)" + "Analytics-lake per-user deletion gap"), folded
into one spec (`0033`). It is a launch-blocking compliance item for any real user data,
and it is the precondition that lets [`0015`]/[`0020`] eventually place richer signals in
the lake (because erasure will finally cover it). It depends on [`0027`]'s artifact index
(for a complete export manifest) and [`0026`]'s TTL attribute, and it hardens a rule
[`0015`] already half-committed to.

## 4. User stories
- As a **user exercising my GDPR Art. 15 / CCPA right to know**, I tap "Download my data,"
  and within a few minutes I get a single file containing **everything Mango holds about
  me** — my profile, progress, my **reflections journal**, my library and journey state,
  my daily activity and achievements, which lessons/roadmaps I completed, and a list of the
  AI artifacts generated for me — in a readable, machine-parseable JSON form I can keep or
  move elsewhere (Art. 20 portability).
- As a **user exercising my right to erasure (GDPR Art. 17 / CCPA delete)**, when I delete
  my account, **everything** is gone — not just the product database and my files, but also
  my **analytics events** and my **feature-store rows** — and the app tells me honestly what
  was erased immediately and what is scheduled to be purged from the analytics lake.
- As a **privacy-conscious user**, the download link I'm given **expires quickly** and the
  exported copy is **deleted** from Mango's storage shortly after, so a leaked link can't be
  replayed and a copy of all my data doesn't linger.
- As **Mango's DPO / Legal**, every access and deletion request is **logged with a
  timestamp and outcome**, so I can demonstrate to a regulator that requests were fulfilled
  within the statutory window, and I can prove the analytics lake is covered (or on a
  documented retention floor).
- As a **backend engineer**, the export reuses the **exact** async job pattern we already
  run for roadmaps (POST→202→poll), and the deletion extension is a small, least-privilege
  addition to one handler plus one scheduled erasure Lambda — no new substrate, no new
  framework.
- As an **on-call engineer**, a user-deletion that fails to reach the lake **never blocks**
  the synchronous erasure of the product data (best-effort, reported), and the **retention
  TTL** guarantees lake events age out even if the rewrite job is wedged.
- As an **offline / signed-out user**, none of this is on my critical path: export/delete
  need a real backend + Cognito session; the bundled-sample + Mock first run is unchanged
  (`CLAUDE.md` offline invariant).

## 5. Requirements

### 5.1 Functional

- **FR-1 (export endpoint — async).** `GET /v1/me/export` (authenticated) mints an
  **export job** `USER#<sub>/EXPORTJOB#<jobId>` (`status:"pending"`, `createdAt`,
  `ttlAt = now + EXPORT_JOB_TTL_SECONDS`), async-invokes the **export worker**
  (`InvocationType="Event"`, payload `{uid,jobId}`), and returns
  `202 {jobId,status:"pending"}`. If no worker is configured (local/offline e2e), the
  assembly runs **inline** and the job is created already-`complete` (mirrors
  `generate_roadmap`'s inline fallback) so the poll contract still resolves. *(Recommend
  `GET` for idempotent "create-or-get my latest export"; an alternative `POST` is fine —
  D-1.)*
- **FR-2 (export assembly — complete bundle).** The export worker assembles a
  **single JSON document** for the caller and writes it (zipped) to
  `users/<sub>/exports/<jobId>/export.zip`. The JSON MUST include, each in its own section
  with a stable schema:
  - `profile` (`PROFILE` item), `progress` (`PROGRESS` incl. `version`),
  - `library[]` (each `BOOK#<bookId>` incl. `journeyState`, `confirmedMilestones`),
  - `reflections[]` (every `REFLECTION#<ts>`, **full text** — the journal),
  - `activity[]` (`ACTIVITY#<date>` rollups), `achievements[]` (`ACHV#<key>`),
  - `lessonsDone[]` (`LESSONDONE#…`), `roadmapsDone[]` (`ROADMAPDONE#…`),
  - `ledger[]`/`credits` (any [`0023`] items, if present),
  - `roadmapJobs[]` (`ROADMAPJOB#<jobId>` rows — status + `roadmapRef`/meta, not necessarily
    the full body),
  - `artifacts[]` — a **manifest** built from the [`0027`] `USER#<sub>/ARTIFACT#…` index
    (and/or an `list_objects_v2` under `users/<sub>/`) listing `key`, `kind`, `size`,
    `lastModified` (the export **references** large S3 artifacts by key/manifest rather than
    inlining megabytes; a `includeArtifactBodies` flag MAY inline small JSON artifacts — D-2),
  - `features[]` — best-effort `MangoFeatures` rows (`entityId=USER#<sub>`),
  - `meta` — `{ exportedAt, sub (hashed?), schemaVersion, regime: "gdpr_art15_20/ccpa",
    counts:{…} }`.
  All numeric values are serialized from the stored representation (Decimal→int via the
  `progress.py` `_to_plain` pattern) so the JSON is clean. The worker `mark_complete`s the
  job with the **S3 key** (not the body).
- **FR-3 (export download — presigned, short-lived).** `GET /v1/me/export/jobs/{jobId}`
  (authenticated) returns `{jobId, status}` and, when `complete`, a **presigned GET URL**
  (`s3.generate_presigned_url`, `ExpiresIn = EXPORT_URL_TTL_SECONDS`, default **900 s**)
  for `users/<sub>/exports/<jobId>/export.zip`, plus `bytes`/`expiresAt`. The URL is minted
  **at poll time** (so it is always fresh) and is scoped to the single object. A user may
  only poll **their own** job (the SK is under their `USER#<sub>` PK; a foreign `jobId`
  → 404). On `failed`, returns `{status:"failed", error}`.
- **FR-4 (export artifact lifecycle + TTL).** The export object MUST be auto-expired by an
  **S3 lifecycle expiration rule** on the `users/*/exports/` prefix (default **7 days** —
  `EXPORT_RETENTION_DAYS`); the export-job row carries `ttlAt` (epoch s) so it self-reaps
  via the table TTL ([`0026`]). Because the object lives under `users/<sub>/`, it is **also**
  swept by `DELETE /v1/me`. (Defence-in-depth: lifecycle + TTL + delete-cascade.)
- **FR-5 (delete `MangoFeatures` rows).** `DELETE /v1/me` MUST, best-effort, delete every
  `MangoFeatures-<stage>` row with `entityId = USER#<sub>`: `Query` by PK (paginated) →
  `batch_writer` delete (the same idiom as `_delete_table_items`, against the features
  table). It MUST return `featuresDeleted:int`. A failure here MUST NOT fail the overall
  delete (the product-data erasure is the hard contract); it is logged + reported as
  `featuresDeleted: <partial>` / a `warnings[]` entry.
- **FR-6 (analytics-lake per-user erasure — tombstone + scheduled rewrite + retention
  floor).** On `DELETE /v1/me`, the handler MUST **record a durable per-user erasure
  request** that survives the deletion of the user's table items:
  - write an object `erasures/<sub>.json` into the **analytics** bucket
    (`{ sub, requestedAt, stage }`) — this is the **tombstone** the scheduled job reads;
    best-effort, reported as `lakeErasureScheduled:bool`.
  - A new **scheduled erasure Lambda** (`lake_erase_worker`, EventBridge rule, e.g. daily)
    MUST: list pending `erasures/`; for each, find affected `events/dt=…` partitions and
    **rewrite them to drop matching `userId`s** (read GZIP-JSON objects, filter out the
    tombstoned `sub`(s), write back the cleaned object / replacement, delete the original) —
    a **partition-rewrite/compaction** approach (the immutable-log analogue of an Athena
    CTAS rewrite); on success, move the tombstone to `erasures-done/`. (Batching multiple
    pending erasures into one rewrite pass is the efficient default — D-4.)
  - **Retention floor:** add an **S3 lifecycle expiration** on `events/` (default **395
    days** — `LAKE_EVENTS_RETENTION_DAYS`, configurable; chosen ≥ the analytics window the
    business needs and ≤ a defensible max) so that **even if the rewrite job never runs**,
    no user's events persist beyond the retention floor. This makes erasure **guaranteed
    eventually** by construction and bounds liability.
  This three-part mechanism (tombstone → scheduled rewrite → retention TTL) is the
  **recommended** design; §6.4/§10 evaluate the alternatives (per-user `events/userhash=…/`
  prefixes; Iceberg row-level delete).
- **FR-7 (hard non-sensitive-`props` requirement).** It is a **requirement** (not guidance)
  that records emitted to the events lake carry, in `props`, **only** ids, enums, dates, and
  small scalar counts — **never** reflection/answer/book text, prompts, model output,
  emails, names, or tokens. Enforced by: the typed `0015` client taxonomy (no free-text
  payloads), a **backend assertion** in `events.py` (reject/strip a `props` whose serialized
  size exceeds a cap or that contains a denylisted key — D-5), and a **test**. Rationale: the
  lake erasure (FR-6) is **eventually consistent** (up to the rewrite cadence / retention
  floor), so the lake must never hold data whose lingering for that window is unacceptable.
- **FR-8 (`DELETE /v1/me` reports analytics handling).** The delete response MUST be
  extended to: `{ deleted:true, itemsDeleted, objectsDeleted, cognitoDeleted,
  featuresDeleted:int, lakeErasureScheduled:bool, requestId, warnings:[…] }`. Existing
  fields are **unchanged** (additive), so older clients keep working.
- **FR-9 (DSAR audit log).** Every export and delete MUST be recorded:
  - **Export:** an item `USER#<sub>/DSAR#<ts>` `{ type:"export", requestedAt, completedAt,
    jobId, outcome }` (written by the export flow; survives until the user is deleted) **and**
    a structured JSON log line `{"evt":"dsar","type":"export","sub":<sub>,"jobId":…,
    "outcome":…}`.
  - **Delete:** because the user's `USER#<sub>` items are being erased, the delete audit
    record MUST be written to a **separate, durable audit sink** that is *not* under the
    user PK — recommended: a structured **CloudWatch log line**
    `{"evt":"dsar","type":"delete","sub":<sub or salted hash>,"itemsDeleted":…,
    "featuresDeleted":…,"lakeErasureScheduled":…,"at":…}` (queryable via Logs Insights),
    and/or an append to an **`audit/dsar/dt=…/` prefix in the analytics bucket** (D-6).
    Storing a **salted hash** of the `sub` (not the raw `sub`) in the retained delete-audit
    keeps the evidence without re-introducing the personal identifier we just erased
    (privacy-by-design; recommend hashing — D-7).
- **FR-10 (least-privilege grants).** `api_stack.py` MUST grant:
  - the **export worker**: `table.grant_read_data` (read all `USER#<sub>` items),
    `bucket.grant_read` (list/read `users/<sub>/` artifacts to build the manifest / inline
    small bodies) **+** `bucket.grant_put` scoped to `users/*` (write the export object),
    and `features_table.grant_read_data`;
  - the **export status** Lambda: `table.grant_read_data` + `bucket` **read** (to mint the
    presigned GET; presigning needs no call but the grant authorizes the eventual GET on the
    user's behalf via their browser — the URL is signed with the Lambda role's creds, so the
    role needs `s3:GetObject` on `users/*`);
  - `delete_fn`: **add** `features_table.grant_read_write_data` (query+delete its rows) and
    `analytics_bucket.grant_put` scoped to `erasures/*` (write the tombstone) — and nothing
    more (no read of others' data, no broad lake access);
  - the **`lake_erase_worker`**: `analytics_bucket.grant_read_write` scoped to `events/*` +
    `erasures/*` + `erasures-done/*` (rewrite partitions, move tombstones).
  `grade_fn` and unrelated Lambdas gain **nothing**. `analytics_bucket`/`features_table`
  (currently `del`'d in `ApiStack`) are now **used** for these specific grants.
- **FR-11 (delete still cascades all `USER#<sub>` items, incl. new SKs + export jobs +
  DSAR rows).** The existing `_delete_table_items` already sweeps **every** `PK=USER#<sub>`
  SK; this spec adds a **regression test** that an `EXPORTJOB#`, a `DSAR#`, and one of each
  [`0026`] tracking SK are all removed. The export **object** under `users/<sub>/exports/`
  is removed by `_delete_s3_objects`. (Self-consistency: deleting a user also deletes their
  past exports + export audit rows.)
- **FR-12 (offline/mock unaffected).** Export/delete require a real backend + session; the
  on-device Mock/offline first-run path makes **no** export/delete call and is unchanged.

### 5.2 Non-functional
- **NFR-1 (privacy & data minimisation).** The export bundle is written **only** under the
  caller's `users/<sub>/` prefix; the presigned URL is **single-object, short-TTL**; the
  object is **lifecycle-expired** and **delete-cascaded**. The retained **delete** audit
  record uses a **salted hash** of `sub`, not the raw identifier. **No S3 Object Lock**
  anywhere (it would block erasure). SSE-S3 + `enforce_ssl` (already on both buckets) protect
  at rest/in transit.
- **NFR-2 (compliance timeliness).** The async export completes in **minutes**, far inside
  GDPR's **1-month** and CCPA's **45-day** windows; the audit log evidences the timestamp.
  The lake erasure is **eventually** complete (scheduled cadence) with a **hard retention
  floor** as the guaranteed-by-construction backstop — designed to satisfy "erased without
  undue delay" given the immutable-log substrate, **conditioned** on FR-7 keeping `props`
  non-sensitive.
- **NFR-3 (best-effort, request-safe).** The `MangoFeatures` delete, the lake tombstone
  write, the DSAR audit write, and the export-artifact write are **best-effort**: a failure
  is caught, logged, reported in `warnings[]`, and **never** fails the synchronous
  product-data erasure or the export-job creation (mirrors `firehose.put_event`-returns-False).
- **NFR-4 (float-free DDB).** No new `float` reaches DynamoDB. The export **reads** items and
  serializes to **S3 JSON** (not a DDB write), so non-int values from `MangoFeatures.value`
  are fine in the bundle. Any new DDB attribute this spec writes (`ttlAt`, audit timestamps,
  `bytes`) is an `int`/string. Decimal→int coercion reuses `progress.py._to_plain`.
- **NFR-5 (single product table; lake + features separate).** Export jobs, DSAR audit rows,
  and the lake-erase tombstone marker live on the **product** table as `USER#<sub>` SKs
  (export job, DSAR) or in the **analytics** bucket (tombstone) — no new table. The
  `MangoFeatures` and events lake stay separate substrates (`docs/DATA_MODEL.md`).
- **NFR-6 (least privilege).** Per FR-10: every new grant is the **minimum** (read for the
  export; scoped `users/*` put for the export object; features read-write only for delete;
  `events/*`+`erasures/*` only for the erase worker). The presigned-URL role surface is the
  narrowest that can sign a GET for the user's own object.
- **NFR-7 (stdlib + boto3; offline synth/test).** New shared modules (`export_jobs.py`,
  `dsar.py`, `lake_erase.py`) use **stdlib + boto3 only** (`zipfile`/`io`/`json`/`gzip` are
  stdlib). `cdk synth -c stage=beta` (export routes + workers + the EventBridge rule + new
  grants + lifecycle rules + features-table TTL-irrelevant) **and** `pytest` (moto for
  S3/DDB; no Bedrock) MUST pass **offline**. black (100) + flake8 (120) clean.
- **NFR-8 (contract lockstep).** `shared/api/openapi.yaml` ⇄ `DTOs.swift` ⇄ handlers stay in
  sync for the two new export paths + the extended delete response; new DTOs decode
  **leniently** (absent fields → safe defaults), mirroring `CatalogBook.init(from:)`.
- **NFR-9 (cost).** Export assembly is a per-request `Query` + a few `list_objects_v2`
  pages + a zip → one S3 PUT; trivial. The lake-erase rewrite is the only non-trivial cost
  (rewriting GZIP partitions) — bounded by running it **scheduled + batched** over pending
  tombstones, and by the retention TTL capping the data volume ever scanned. `PAY_PER_REQUEST`
  absorbs the modest extra DDB read/delete volume.
- **NFR-10 (idempotency).** Re-requesting an export is safe (a new `jobId` each time; old
  exports expire). The delete is idempotent (a second `DELETE /v1/me` finds nothing and
  returns zero counts). The lake-erase worker is idempotent per tombstone (moving it to
  `erasures-done/` after a successful pass; a re-run over already-clean partitions is a no-op).

## 6. Design

### 6.1 API / contract (add to `shared/api/openapi.yaml`)
Two new paths + an extended delete response. Keep `DTOs.swift` and handlers in lockstep.

```yaml
  /v1/me/export:
    get:
      summary: Request (or get the latest) async export of all my data (GDPR Art.15/20, CCPA)
      security: [{ bearerAuth: [] }]
      responses:
        "202": { description: Export job accepted,
                 content: { application/json: { schema: { $ref: "#/components/schemas/ExportJob" } } } }
        "401": { description: Unauthenticated }
  /v1/me/export/jobs/{jobId}:
    get:
      summary: Poll an export job; when complete, returns a short-lived presigned download URL
      security: [{ bearerAuth: [] }]
      parameters: [{ name: jobId, in: path, required: true, schema: { type: string } }]
      responses:
        "200": { description: Job status (+ download URL when complete),
                 content: { application/json: { schema: { $ref: "#/components/schemas/ExportJobStatus" } } } }
        "404": { description: No such job for this user }
        "401": { description: Unauthenticated }
  # /v1/me (DELETE) — response schema extended (additive):
components:
  schemas:
    ExportJob:
      type: object
      properties:
        jobId:  { type: string }
        status: { type: string, enum: [pending, complete, failed] }
    ExportJobStatus:
      type: object
      properties:
        jobId:       { type: string }
        status:      { type: string, enum: [pending, complete, failed] }
        downloadUrl: { type: string, nullable: true, description: "presigned GET, short TTL; present iff complete" }
        bytes:       { type: integer, nullable: true }
        expiresAt:   { type: string,  nullable: true, format: date-time }
        error:       { type: string,  nullable: true }
    DeleteAccountResult:   # extend the existing DELETE /v1/me response
      type: object
      properties:
        deleted:              { type: boolean }
        itemsDeleted:         { type: integer }
        objectsDeleted:       { type: integer }
        cognitoDeleted:       { type: boolean }
        featuresDeleted:      { type: integer }   # NEW
        lakeErasureScheduled: { type: boolean }   # NEW
        requestId:            { type: string }    # NEW (audit correlation)
        warnings:             { type: array, items: { type: string } }  # NEW (best-effort failures)
```

**openapi ⇄ DTO ⇄ handler sync.** Add Swift mirrors to `DTOs.swift`: `ExportJobDTO`
(`jobId`, `status`), `ExportJobStatusDTO` (`status`, optional `downloadUrl`, `bytes`,
`expiresAt`, `error`), and **extend** the delete-response DTO with the four new optional
fields (lenient decode → defaults). No request bodies (export is a parameterless `GET`).

### 6.2 Export job — reuse the async pattern (`shared/export_jobs.py`, new)
A near-copy of `roadmap_jobs.py`, scoped to `EXPORTJOB#<jobId>` and stamping `ttlAt`:

```python
# shared/export_jobs.py — sketch (stdlib + boto3)
PENDING, COMPLETE, FAILED = "pending", "complete", "failed"
_SK = "EXPORTJOB#"

def new_job_id() -> str: return uuid.uuid4().hex

def create_pending(uid, job_id):
    table().put_item(Item={
        "PK": f"USER#{uid}", "SK": f"{_SK}{job_id}",
        "status": PENDING, "createdAt": _now_iso(),
        "ttlAt": int(time.time()) + EXPORT_JOB_TTL_SECONDS,   # 0026 TTL attribute (int seconds)
    })

def mark_complete(uid, job_id, s3_key, byte_len):
    table().update_item(Key=_key(uid, job_id),
        UpdateExpression="SET #s=:s, s3Key=:k, bytes=:b, completedAt=:t",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={":s": COMPLETE, ":k": s3_key, ":b": int(byte_len), ":t": _now_iso()})

def get_status(uid, job_id):
    item = table().get_item(Key=_key(uid, job_id)).get("Item")
    if not item: return None
    view = {"jobId": job_id, "status": item.get("status", PENDING)}
    if item.get("status") == COMPLETE:
        key = item["s3Key"]
        view["downloadUrl"] = s3_client().generate_presigned_url(
            "get_object", Params={"Bucket": bucket_name(), "Key": key},
            ExpiresIn=EXPORT_URL_TTL_SECONDS)              # fresh URL each poll (FR-3)
        view["bytes"] = int(item.get("bytes", 0))
        view["expiresAt"] = _iso(time.time() + EXPORT_URL_TTL_SECONDS)
    if item.get("status") == FAILED:
        view["error"] = item.get("error", "export failed")
    return view
```

**`export_worker`** (new handler) assembles the bundle (§6.3) and `mark_complete`s with the
S3 key + byte length. **`export_status`** (new handler) serves `get_status`. **`me_export`
POST/GET handler** mints the job + async-invokes the worker (granting
`export_worker_fn.grant_invoke(me_export_fn)` + `EXPORT_WORKER_FUNCTION` env), with the
**inline fallback** when no worker is configured (assemble synchronously, create the job
`complete`).

### 6.3 Export assembly (`shared/dsar.py`, new — best-effort, read-only)
```python
# shared/dsar.py — assemble_export(uid) -> (zip_bytes, byte_len)
def assemble_export(uid):
    items = _query_all_user_items(uid)            # Query PK=USER#<uid>, paginated
    doc = {
        "meta": {"exportedAt": _now_iso(), "schemaVersion": 1, "regime": "gdpr_art15_20/ccpa"},
        "profile":      _pick(items, "PROFILE"),
        "progress":     _pick(items, "PROGRESS"),
        "library":      _collect(items, "BOOK#"),
        "reflections":  _collect(items, "REFLECTION#"),   # full journal text (the promise)
        "activity":     _collect(items, "ACTIVITY#"),
        "achievements": _collect(items, "ACHV#"),
        "lessonsDone":  _collect(items, "LESSONDONE#"),
        "roadmapsDone": _collect(items, "ROADMAPDONE#"),
        "ledger":       _collect(items, "LEDGER#"),        # 0023, if present
        "roadmapJobs":  _collect(items, "ROADMAPJOB#"),    # status + roadmapRef/meta
        "artifacts":    _artifact_manifest(uid),           # from 0027 ARTIFACT# index + list_objects_v2
        "features":     _features_rows(uid),               # best-effort MangoFeatures(entityId=USER#<uid>)
        "dsarHistory":  _collect(items, "DSAR#"),
    }
    doc = _to_plain(doc)                          # Decimal->int throughout (progress.py pattern)
    raw = json.dumps(doc, indent=2).encode()
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("mango-export.json", raw)
        # optionally also write a README.txt explaining the schema (human-readable)
    return buf.getvalue(), buf.getbuffer().nbytes
```
- `_artifact_manifest` prefers the [`0027`] `USER#<sub>/ARTIFACT#…` index (fast, typed:
  `key`, `kind`, `createdAt`, model/token meta) and falls back to `list_objects_v2` under
  `users/<sub>/` (`key`, `size`, `lastModified`) so the manifest is complete even pre-0027.
  Large artifact **bodies** are **referenced**, not inlined (D-2); a future flag may inline
  small JSON.
- `_features_rows` is best-effort (table may be empty); a read failure → `features: []` +
  a `meta.warnings` note (never fails the export).
- The worker writes `buf` to `users/<sub>/exports/<jobId>/export.zip` (`put_object`,
  `ContentType=application/zip`), then `mark_complete`.

### 6.4 Analytics-lake erasure (the mechanism — FR-6)
The lake is **append-only, immutable, date-partitioned GZIP** keyed by `userId=<sub>`. Three
mechanisms were evaluated (full trade-offs in §10):

| Mechanism | How per-user delete works | Pros | Cons |
|---|---|---|---|
| **A — Tombstone + scheduled partition-rewrite + retention TTL** *(recommend)* | On delete, drop a `erasures/<sub>.json` tombstone; a scheduled Lambda rewrites affected `events/dt=…` objects to drop that `userId`; `events/` lifecycle-expires at a retention floor as the guaranteed backstop | No lake re-architecture; works on today's Firehose+GZIP+Glue as-is; `userId` already present; TTL guarantees eventual erasure even if rewrite lags; cheap (scheduled+batched) | Erasure is **eventually consistent** (cadence/retention), so requires FR-7 (non-sensitive `props`); rewrite must scan partitions |
| **B — Per-user prefix** (`events/userhash=<h>/dt=…/`) | Delete = `delete_objects` under the user's prefix | Targeted, cheap delete | Requires **changing the Firehose prefix** to a per-user dimension (dynamic partitioning), **explodes partition count** (one per user), hurts Athena scans + Firehose buffering; a big producer-side change to [`0015`]/0006 |
| **C — Iceberg `events` table + row-level `DELETE` + `OPTIMIZE`** | `DELETE FROM events WHERE userId=…` then compaction | Clean SQL erasure, ACID | A **lake migration** (Firehose→Iceberg, Glue table format change, compaction/VACUUM ops) far beyond this spec; best **long-term** target |

**Recommended: A.** It ships on the **current** substrate with the smallest change, and its
**retention TTL** makes erasure *guaranteed by construction* (the rewrite job is an
optimisation that erases *sooner*; the TTL is the floor). The tombstone is written **before**
the user's table rows are purged (so we still know the `sub`), to a durable object the
scheduled job consumes asynchronously. The design is **forward-compatible** with a later
Iceberg cutover (C): the tombstone/erasure-request abstraction stays; only the "rewrite a
partition" implementation is swapped for a `DELETE`+`OPTIMIZE`.

```python
# delete_account.py (added) — best-effort tombstone, before purging the user row
def _schedule_lake_erase(uid: str) -> bool:
    ab = os.environ.get("ANALYTICS_BUCKET")
    if not ab: return False
    try:
        s3_client().put_object(Bucket=ab, Key=f"erasures/{uid}.json",
            Body=json.dumps({"sub": uid, "requestedAt": _now_iso(),
                             "stage": os.environ.get("STAGE","")}).encode())
        return True
    except Exception:
        return False
```

```python
# handlers/lake_erase_worker.py (new) — EventBridge-scheduled, idempotent, batched
def handler(event, context):
    pending = _list("erasures/")                         # tombstones to process
    subs = {_load(k)["sub"] for k in pending}
    for key in _list_event_objects():                    # events/dt=.../*.gz (optionally only recent partitions)
        rewrite_if_needed(key, drop_user_ids=subs)       # read gz-json lines, filter out subs, write back/delete
    for k in pending:
        _move(k, k.replace("erasures/", "erasures-done/"))   # mark done (idempotent)
```
- **Scope/cost control:** the worker may scan only partitions newer than the retention floor
  (older ones expire anyway) and **batch all pending tombstones** into one pass (D-4). It
  runs on a schedule (e.g. daily), not on the delete request path.
- **Retention floor (CDK):** add an **expiration** to the `events/` lifecycle in
  `analytics_stack.py` (`LAKE_EVENTS_RETENTION_DAYS`, default 395) — the existing rule only
  *tiers* (IA/Glacier) and never expires; this adds the deletion floor.

### 6.5 `delete_account.py` — extension (sketch)
```python
def handler(event, context):
    uid = user_id(event)                                  # 401 on PermissionError (unchanged)
    ...
    lake_scheduled = _schedule_lake_erase(uid)            # FR-6 tombstone (before purge), best-effort
    items_deleted   = _delete_table_items(uid)            # unchanged (sweeps EXPORTJOB#, DSAR#, tracking SKs)
    objects_deleted = _delete_s3_objects(uid)             # unchanged (sweeps users/<uid>/exports/ too)
    features_deleted, fwarn = _delete_features(uid)       # FR-5 best-effort
    cognito_deleted = _delete_cognito_user(uid)           # unchanged
    request_id = uuid.uuid4().hex
    _audit_delete(uid, request_id, items_deleted, features_deleted, lake_scheduled)  # FR-9 (salted-hash sub)
    return ok({"deleted": True, "itemsDeleted": items_deleted, "objectsDeleted": objects_deleted,
               "cognitoDeleted": cognito_deleted, "featuresDeleted": features_deleted,
               "lakeErasureScheduled": lake_scheduled, "requestId": request_id,
               "warnings": fwarn})
```
`_delete_features(uid)` mirrors `_delete_table_items` against `MangoFeatures-<stage>`
(`Query entityId=USER#<uid>` → `batch_writer` delete), wrapped in try/except → returns
`(count, warnings)`.

### 6.6 Audit log (FR-9) — durable evidence
- **Export audit** rides the product table: `USER#<sub>/DSAR#<ts>` `{ type:"export",
  requestedAt, completedAt, jobId, outcome }` (and is itself included in the export's
  `dsarHistory` + erased on delete — acceptable: the *retained* compliance evidence for a
  *deletion* is the separate sink below).
- **Delete audit** cannot live under the user PK (it's being erased), so it is written to a
  **retained** sink: a structured CloudWatch log line `{"evt":"dsar","type":"delete",
  "subHash":sha256(salt+sub),"itemsDeleted":…,"featuresDeleted":…,
  "lakeErasureScheduled":…,"at":…,"requestId":…}` (queryable in Logs Insights) and/or an
  append-only object under `audit/dsar/dt=YYYY-MM-DD/` in the analytics bucket. **Recommend
  hashing the `sub`** (salted) so the retained evidence proves "a deletion happened for this
  account" without storing the personal identifier we just erased (D-7). Legal can correlate
  via the `requestId` returned to the user.

### 6.7 iOS (thin wiring — full UI is a [`0022`]/Settings task)
- **`PrivacyService`** (or fold into the existing settings/account service): `requestExport()`
  → `GET /v1/me/export` then poll `GET /v1/me/export/jobs/{jobId}` (reusing the
  `RoadmapGenerator` poll idiom) until `complete`, then hand the `downloadUrl` to a
  `ShareLink`/`SFSafariViewController` so the user saves the zip; `deleteAccount()` →
  `DELETE /v1/me` (already wired by task #28) now surfaces the richer result. Gated on
  `AuthService.isSignedIn` + a real backend; **no-op/absent** offline/Mock.
- **DTOs:** `ExportJobDTO`, `ExportJobStatusDTO`, extended delete-result DTO (lenient
  decode). No new SwiftData models (export is server-assembled; the client just triggers +
  downloads). Design tokens / screen polish deferred.

### 6.8 Diagrams
```
GET /v1/me/export ──persist EXPORTJOB#<jobId> (+ttlAt)──▶ DDB
        │  async invoke {uid, jobId}
        ▼
   export_worker ── Query PK=USER#<sub> (all items) ─┐
        │           list users/<sub>/ + ARTIFACT# idx ├─ assemble JSON ─▶ zip
        │           read MangoFeatures(entityId=USER#)┘
        ├─ put users/<sub>/exports/<jobId>/export.zip ─▶ S3 (product bucket)
        ├─ mark_complete: SET s3Key, bytes ─▶ DDB
        └─ DSAR#<ts> {type:export} + log {"evt":"dsar",...}
GET /v1/me/export/jobs/{jobId} ── status + presigned GET (TTL 15m) ──▶ {downloadUrl,bytes,expiresAt}
   lifecycle: users/*/exports/ expire @7d · DELETE /v1/me also sweeps it · job row ttlAt reaps

DELETE /v1/me
   ├─ tombstone erasures/<sub>.json ─▶ analytics bucket   (lakeErasureScheduled)
   ├─ _delete_table_items  (USER#<sub>: PROFILE..EXPORTJOB#..DSAR#..tracking)  ─▶ DDB
   ├─ _delete_s3_objects   (users/<sub>/ incl. exports)                         ─▶ product S3
   ├─ _delete_features     (MangoFeatures entityId=USER#<sub>)                  ─▶ features DDB
   ├─ _delete_cognito_user
   └─ _audit_delete (CloudWatch line / audit/ object; salted-hash sub)
        ▼  (returns {…, featuresDeleted, lakeErasureScheduled, requestId, warnings})

EventBridge (daily) ─▶ lake_erase_worker: read erasures/ → rewrite events/dt=…/*.gz dropping userId ∈ tombstones → erasures-done/
analytics events/ lifecycle: tier IA@30/Glacier@90 (existing) + EXPIRE @ retention floor (NEW, guaranteed backstop)
```

## 7. Acceptance criteria
- [ ] **AC-1 (export job lifecycle).** `GET /v1/me/export` returns `202 {jobId,
      status:"pending"}` and persists `USER#<sub>/EXPORTJOB#<jobId>` with `ttlAt`; with no
      worker configured it instead completes inline. *(`test_export_post_creates_job`,
      `test_export_inline_fallback_completes` — moto.)*
- [ ] **AC-2 (export contents — complete bundle).** A seeded user with profile, progress,
      library (+journeyState), reflections, an `ACTIVITY#`, an `ACHV#`, a `LESSONDONE#`, a
      `ROADMAPDONE#`, a roadmap job, an `ARTIFACT#` row, and a `MangoFeatures` row produces a
      zip whose `mango-export.json` contains **every** section populated (reflections in full
      text; artifacts as a manifest with `key`; features present). *(`test_export_bundle_contains_all_sections`.)*
- [ ] **AC-3 (presigned download).** `GET /v1/me/export/jobs/{jobId}` on a `complete` job
      returns `status:"complete"` + a `downloadUrl` (presigned GET for
      `users/<sub>/exports/<jobId>/export.zip`) + `bytes` + `expiresAt`; fetching the URL
      yields the zip bytes; a **foreign** user's `jobId` → 404. *(`test_export_status_returns_presigned_url`,
      `test_export_download_roundtrip` (moto presign+get), `test_export_status_foreign_job_404`.)*
- [ ] **AC-4 (export artifact lifecycle + TTL, no Object Lock).** `cdk synth` shows an S3
      **expiration** lifecycle rule on `users/*/exports/` (≈7d); the export-job row carries an
      int `ttlAt`; **no** `ObjectLockConfiguration` on either bucket. *(`test_synth_export_lifecycle_and_no_object_lock`,
      `test_export_job_has_ttl`.)*
- [ ] **AC-5 (MangoFeatures deletion).** After `DELETE /v1/me` for a user with several
      `MangoFeatures-<stage>` rows (`entityId=USER#<sub>`), **all** are gone, the response
      reports `featuresDeleted == N`, and a **different** entity's rows
      (`entityId=BOOK#<id>`) are untouched. *(`test_delete_removes_user_feature_rows`,
      `test_delete_preserves_other_feature_entities`.)*
- [ ] **AC-6 (delete reports analytics handling).** The delete response includes
      `featuresDeleted`, `lakeErasureScheduled`, `requestId`, and `warnings` (existing fields
      unchanged/additive). *(`test_delete_response_shape_extended`.)*
- [ ] **AC-7 (lake tombstone + retention floor).** `DELETE /v1/me` writes
      `erasures/<sub>.json` to the analytics bucket (when configured) and sets
      `lakeErasureScheduled:true`; `cdk synth` shows an **expiration** on the `events/`
      lifecycle (retention floor) in addition to the IA/Glacier transitions.
      *(`test_delete_writes_lake_tombstone`, `test_synth_events_retention_expiration`.)*
- [ ] **AC-8 (lake-erase worker rewrites partitions).** Given seeded `events/dt=…/*.gz`
      containing lines for users A and B and a tombstone for A, the `lake_erase_worker`
      rewrites the partition so **no** line has `userId==A`, **all** B lines remain, and the
      tombstone is moved to `erasures-done/`; a re-run is a no-op. *(`test_lake_erase_drops_user_lines`,
      `test_lake_erase_idempotent`.)*
- [ ] **AC-9 (non-sensitive props enforced).** `POST /v1/events` with a `props` containing a
      denylisted key (e.g. `reflectionText`) or an over-cap string is **rejected/stripped**
      per the FR-7 guard; a clean ids/enums/scalars `props` is accepted. *(`test_events_rejects_sensitive_props`,
      `test_events_accepts_clean_props`.)*
- [ ] **AC-10 (DSAR audit).** An export writes a `USER#<sub>/DSAR#<ts>` `{type:"export",…}`
      row and logs a `{"evt":"dsar","type":"export",…}` line; a delete logs a
      `{"evt":"dsar","type":"delete",...}` line carrying a **salted hash** of the sub (not the
      raw sub) and the counts. *(`test_export_writes_dsar_row`, `test_delete_audit_logs_hashed_sub`.)*
- [ ] **AC-11 (delete cascades export jobs + DSAR + tracking SKs; export object purged).**
      Seeding an `EXPORTJOB#`, a `DSAR#`, [`0026`] tracking SKs, and a
      `users/<sub>/exports/<jobId>/export.zip`, `DELETE /v1/me` removes **all** of them.
      *(`test_delete_cascades_export_and_dsar`, `test_delete_removes_export_objects`.)*
- [ ] **AC-12 (least privilege synth).** `cdk synth -c stage=beta` shows: export worker =
      table **read**, bucket read + `users/*` put, features **read**; `delete_fn` gains
      features **read-write** + analytics `erasures/*` put; `lake_erase_worker` = analytics
      `events/*`+`erasures*/*` read-write; **no** new grant to `grade_fn`/unrelated Lambdas.
      *(`test_synth_dsar_grants_least_privilege`.)*
- [ ] **AC-13 (float-free + best-effort).** The export reads `Decimal`s and serializes ints
      in the JSON; with `MangoFeatures` read, the lake tombstone, or the export PUT forced to
      fail, the export still completes (or the delete still erases product data) and the
      failure is reported in `warnings`/`meta`, never raised. *(`test_export_decimal_to_int`,
      `test_delete_best_effort_on_features_failure`, `test_export_best_effort_on_features_failure`.)*
- [ ] **AC-14 (contract sync).** `openapi.yaml` defines the two export paths + the extended
      delete response; `DTOs.swift` mirrors them and decodes leniently; `cdk synth -c
      stage=beta` passes. *(openapi lint + `ExportDTOTests` + synth.)*
- [ ] **AC-15 (offline-first + invariants).** Fresh install, Mock AI, no network/session:
      no export/delete call is made; `make ios-test` green; backend `pytest` (incl. the new
      suites) + `cdk synth -c stage=beta`/`prod` green; black/flake8 clean. *(CI + offline run.)*
- [ ] **AC-16 (DSAR e2e, manual/beta).** Signed-in on beta: request an export, download the
      zip from the presigned URL, confirm it contains the reflections + all sections; then
      `DELETE /v1/me`, confirm the product items/objects + `MangoFeatures` rows are gone and a
      `erasures/<sub>.json` tombstone exists; run the erase worker and confirm the user's lines
      leave `events/`. *(Beta e2e, manual.)*

## 8. Test plan
- **Backend (`pytest`, moto for S3/DDB — offline; no Bedrock; primary):** new `backend/tests/`:
  - `test_export_jobs.py` — `create_pending` stamps `ttlAt` (int s); `mark_complete` sets
    `s3Key`/`bytes`; `get_status` returns a presigned URL only when `complete` and 404s a
    foreign job (AC-1/3/4).
  - `test_dsar_export.py` — `assemble_export` over a fully-seeded user yields a zip whose
    `mango-export.json` has every section (AC-2), reflections in full, the artifact manifest
    from a seeded `ARTIFACT#` index + `list_objects_v2`, `MangoFeatures` rows; `Decimal`→`int`
    (AC-13); best-effort when the features read / S3 put fails.
  - `test_export_handlers.py` — `GET /v1/me/export` 202 + job row + async-invoke (monkeypatch
    `lambda_client`), inline fallback completes (AC-1); `GET …/jobs/{id}` poll shape; auth
    required in prod/beta (mirror `test_progress_requires_auth_in_prod`).
  - `test_delete_account.py` (extend) — `featuresDeleted` count + other-entity preservation
    (AC-5); extended response shape (AC-6); lake tombstone written (AC-7); cascade of
    `EXPORTJOB#`/`DSAR#`/tracking SKs + export objects (AC-11); best-effort on a features
    failure (AC-13); delete audit logs a **hashed** sub (AC-10).
  - `test_lake_erase.py` — seed `events/dt=…/*.gz` (two users) + a tombstone; worker rewrites
    to drop user A, keeps B, moves the tombstone, idempotent re-run (AC-8).
  - `test_events_props_guard.py` — `events.py` rejects/strips denylisted/over-cap `props`,
    accepts clean (AC-9).
  - **Synth** (`test_synth.py`, over the synthesized template): export routes + workers +
    EventBridge schedule exist; `users/*/exports/` expiration + `events/` expiration (retention
    floor) + **no** Object Lock (AC-4/7); least-privilege grants (AC-12); both stages synth (AC-14/15).
- **iOS (XCTest):** `ExportDTOTests` (lenient decode of job/status + extended delete result,
  AC-14); a `FakeAPIClient` test driving `requestExport()` through POST→poll→`downloadUrl`;
  `PrivacyServiceOfflineTests` (no-op without session, AC-15). No GamificationEngine changes.
- **Manual (Beta e2e):** AC-16 — full export download + content check + delete + features/
  tombstone verification + run the erase worker (or wait for the schedule) and confirm the
  user's events are gone; spot-check that `audit/`/Logs Insights shows the deletion with a
  hashed sub and no raw PII.
- **Regression:** existing **29** backend tests + `cdk synth ×stages` + `make ios-test` stay
  green; the `DELETE /v1/me` contract is **behaviour-preserving** (additive response fields
  only); generation/grading/tracking paths untouched.

## 9. Rollout & migration
- **Flags / config (env):** `EXPORT_WORKER_FUNCTION` (async vs inline), `EXPORT_JOB_TTL_SECONDS`
  (default 7d), `EXPORT_URL_TTL_SECONDS` (default 900s), `EXPORT_RETENTION_DAYS` (default 7),
  `ANALYTICS_BUCKET` (passed to `delete_fn` + the erase worker; absent → lake steps no-op),
  `LAKE_EVENTS_RETENTION_DAYS` (default 395), `DSAR_AUDIT_SALT` (for the hashed sub),
  `LAKE_ERASE_SCHEDULE` (cron). New env only; reuses `TABLE_NAME`/`BUCKET_NAME`.
- **Backward compatibility.** The **delete response is additive** (old clients ignore the new
  fields); the two **export endpoints are new** (no impact on existing routes). No table
  schema migration (export jobs + DSAR rows are new SKs; `ttlAt` is the [`0026`] attribute).
  The **`events/` retention-expiration** is a new lifecycle action — confirm the chosen floor
  is ≥ the analytics window the business relies on **before** enabling in prod (D-8).
- **Stages of rollout.** (1) Land `export_jobs.py`/`dsar.py` + the export worker/status +
  routes + grants, dark in **beta**; verify a real export download. (2) Extend `delete_account`
  (features delete + tombstone + extended response + audit) in beta; verify `featuresDeleted`
  + tombstone. (3) Add the `events/` retention expiration + the `lake_erase_worker` +
  EventBridge schedule; run it manually once, confirm rewrite, then enable the schedule. (4)
  Enforce the FR-7 `props` guard in `events.py` (it is safe — current `0015` payloads are
  already clean). (5) Promote to prod after Legal signs off on the bundle contents + the
  deletion-completeness statement + the retention floor.
- **Coordination.** Lands **after/with** [`0026`] (TTL attribute; the tracking SKs the export
  serializes + delete cascades) and **after** [`0027`] (the `ARTIFACT#` index the manifest
  reads — degrade gracefully to `list_objects_v2` if 0027 isn't shipped). [`0032`] later adds a
  **DLQ + alarms** for the export/erase workers and charts the DSAR metrics; [`0015`]/[`0020`]
  may only place richer signals in the lake **after** this erasure path is live (and still
  within FR-7).
- **Teardown / kill-switch.** Unset `EXPORT_WORKER_FUNCTION` → export runs inline (or disable
  the routes) with no user-facing breakage of delete. The lake-erase schedule can be paused
  (the retention TTL still guarantees the floor). Removing `ANALYTICS_BUCKET` from `delete_fn`
  cleanly disables the lake steps (delete of product data is unaffected).

## 10. Risks & open decisions
- **Risk — a leaked presigned URL exposes the full export.** *Mitigation:* short TTL (15 min),
  single-object scope, minted fresh per poll, object lifecycle-expired at 7d **and**
  delete-cascaded; the URL is only ever returned to the authenticated owner over TLS. *(Accept
  the residual: a TTL window is inherent to any download link; 15 min is industry-standard.)*
- **Risk — lake erasure is eventually consistent** (scheduled cadence + retention floor), not
  instantaneous. *Mitigation:* **FR-7** keeps `props` non-sensitive so the lingering window is
  low-risk; the **retention TTL** guarantees an upper bound; the scheduled rewrite shortens it;
  the response is **honest** (`lakeErasureScheduled`, not `lakeErased`). *Legal sign-off
  required* that "scheduled erasure + a documented retention floor over a non-sensitive,
  id/enum/scalar event log" satisfies Art. 17 "without undue delay" for this substrate.
- **Risk — partition rewrite is heavy / racy with live Firehose writes.** *Mitigation:* run
  **scheduled + batched**, prefer rewriting **closed** (older-than-buffer) partitions, and rely
  on the retention TTL for the tail; never on the request path. A wedged worker degrades to "TTL
  guarantees erasure," not "data leaks."
- **Risk — legal-retention conflicts** (e.g. financial/credit-ledger records under [`0023`],
  fraud, tax). *Mitigation:* the erasure **may exempt** specifically-justified records;
  document any exception in the bundle `meta` + the deletion statement; default is "erase all"
  unless a named exception applies. *(Decision deferred to Legal — D-9.)*
- **Risk — exporting the journal (reflections) is sensitive content leaving our control.**
  *Accepted/Intended:* it is the user's own data and the `GAMIFICATION.md` promise; the bundle
  is delivered only to the authenticated owner via a short-TTL link.
- **Decision — D-1 (export verb):** `GET /v1/me/export` (idempotent "request/get latest") vs
  `POST`. *Recommend `GET`* (no body; safe to retry; matches "request my data") — but ensure it
  always mints a **fresh** job so a stale cached export is never returned.
- **Decision — D-2 (inline artifact bodies?):** reference large S3 artifacts by manifest vs
  inline them. *Recommend reference-by-manifest* for v1 (keeps the bundle small; the user can
  request specific artifacts later); a flag may inline small JSON.
- **Decision — D-3 (lake erasure mechanism):** A (tombstone+rewrite+TTL) vs B (per-user prefix)
  vs C (Iceberg). *Recommend A now*, with C as the documented long-term target; A is
  forward-compatible with C.
- **Decision — D-4 (erase worker batching/scope):** batch all pending tombstones per pass and
  scan only non-expired partitions. *Recommend yes* (cost).
- **Decision — D-5 (`props` guard strictness):** **reject** (400) vs **strip** offending keys in
  `events.py`. *Recommend strip + log* (telemetry must never break a request — matches the
  best-effort ethos), plus the client-side typed taxonomy as the real guarantee.
- **Decision — D-6 (delete-audit sink):** CloudWatch Logs Insights vs an `audit/` S3 prefix vs
  both. *Recommend the CloudWatch line for v1* (queryable, cheap), with the S3 append as an
  optional durable add-on.
- **Decision — D-7 (hash the sub in retained delete audit):** *Recommend salted SHA-256* — keep
  the evidence, drop the identifier.
- **Decision — D-8 (events retention floor value):** default **395 days**; *confirm with the
  business analytics needs + a defensible max before prod*.
- **Decision — D-9 (legal-retention exceptions):** which record classes (if any) survive an
  erasure. *Defer to Legal*; default erase-all.

## 11. Tasks & estimate
1. **`shared/export_jobs.py`** — async export-job CRUD (`create_pending`+`ttlAt`,
   `mark_complete/failed`, `get_status` with presigned URL), mirroring `roadmap_jobs` (**M**).
2. **`shared/dsar.py`** — `assemble_export(uid)`: query all `USER#<sub>` items, build the
   sectioned JSON (incl. reflections/journal), artifact manifest (from `ARTIFACT#` idx +
   `list_objects_v2`), best-effort `MangoFeatures` rows, `Decimal`→int, zip (**L**).
3. **`handlers/export.py`** (POST/GET `me_export`) + **`handlers/export_worker.py`** +
   **`handlers/export_status.py`** — async invoke + inline fallback + poll (**M**).
4. **`delete_account.py`** — add `_delete_features` (MangoFeatures cascade), `_schedule_lake_erase`
   (tombstone), extended response, `_audit_delete` (hashed sub) (**M**).
5. **`handlers/lake_erase_worker.py`** + EventBridge schedule — read tombstones, rewrite
   `events/` partitions dropping tombstoned `userId`s, move to `erasures-done/`, idempotent (**L**).
6. **`events.py`** — FR-7 `props` guard (strip/deny sensitive keys + size cap); keep best-effort (**S**).
7. **`api_stack.py`** — new routes (`/v1/me/export`, `/v1/me/export/jobs/{jobId}`), export
   worker/status Lambdas + `grant_invoke` + env; **stop `del`-ing** `analytics_bucket`/
   `features_table` and wire the FR-10 least-privilege grants; the EventBridge-scheduled
   `lake_erase_worker` (**M**).
8. **`analytics_stack.py`** — add `events/` **expiration** (retention floor); export-prefix
   lifecycle lives on the product bucket (`data_stack.py`): `users/*/exports/` expiration; **no**
   Object Lock anywhere (**S**).
9. **Contract** — `shared/api/openapi.yaml` (two export paths + extended delete response);
   `DTOs.swift` mirrors (`ExportJobDTO`, `ExportJobStatusDTO`, extended delete result) (**S**).
10. **iOS thin wiring** — `PrivacyService.requestExport()` (POST→poll→`ShareLink(downloadUrl)`)
    + surface the richer delete result; gated/no-op offline (full Settings UI deferred to 0022) (**M**).
11. **Tests** — backend suites (export jobs/assembly/handlers, delete extension, lake-erase,
    props guard, synth least-privilege + lifecycle + no-Object-Lock) + iOS DTO/offline tests (**L**).
12. **Docs** — update `docs/DATA_MODEL.md` §"Deletion note" (now *covered*: MangoFeatures
    deleted, lake tombstone+rewrite+retention, export added) + a short DSAR runbook
    (how Legal fulfils/evidences a request); promote this spec to `docs/specs/NNNN-…` (**S**).

## 12. References
- **Code (as-built):** `backend/src/handlers/delete_account.py`;
  `backend/mango_backend/analytics_stack.py`, `data_stack.py`, `api_stack.py`;
  `backend/src/shared/firehose.py`, `roadmap_jobs.py`, `generate_roadmap.py`, `storage.py`,
  `response.py`; `backend/src/handlers/events.py`.
- **Docs/specs:** `docs/DATA_MODEL.md` (§"Deletion note", §"Data lake & feature store"),
  `docs/GAMIFICATION.md` (§2(j) "the journal belongs to the user — easy export"),
  `working/ARCHITECTURE_REVIEW.md` (§3 **G8/G9**), `docs/specs/SPEC_TEMPLATE.md`.
  Sibling specs: [`0015`-analytics-events-ios] (events lake + the soft `props` rule this
  hardens), [`0026`-server-side-activity-achievement-tracking] (TTL attribute + tracking SKs
  exported/cascaded), [`0027`-generation-artifact-store-observability] (the `ARTIFACT#` index
  the export manifest reads), [`0023`-payments-and-credits] (ledger items + retention
  exceptions), [`0032`-observability-cost-reliability] (DLQ/alarms for the new workers),
  [`0022`-app-store-prep] (privacy label + the Settings UI that hosts these endpoints).
- **GDPR — access & portability:**
  - Art. 15 (right of access — a copy of all personal data, intelligible form):
    https://gdpr-info.eu/art-15-gdpr/
  - Art. 20 (right to data portability — machine-readable, data the subject provided;
    controller-to-controller transfer): https://gdpr-info.eu/art-20-gdpr/
  - DSAR response timeline (1 month, +2 for complex; fines up to €20M / 4% turnover):
    https://gdprlocal.com/dsar-rules-and-deadlines/
- **CCPA/CPRA — know/access/portability + delete (45-day window; 2026 updates):**
  - California AG CCPA overview: https://oag.ca.gov/privacy/ccpa
  - CPPA FAQ (consumer rights, response timing): https://cppa.ca.gov/faq.html
  - CCPA vs CPRA (rights incl. portability "portable, readily usable format"):
    https://transcend.io/blog/cpra-vs-ccpa
- **Per-user deletion in a date-partitioned S3 lake (tombstone / rewrite / TTL / Iceberg):**
  - AWS Big Data: *How to delete user data in an AWS data lake* (metadata-index + purge report;
    `userId` as the index key): https://aws.amazon.com/blogs/big-data/how-to-delete-user-data-in-an-aws-data-lake/
  - AWS Big Data: *Keeping your data lake clean and compliant with Amazon Athena* (CTAS/Iceberg
    DELETE + compaction for compliant deletion):
    https://aws.amazon.com/blogs/big-data/keeping-your-data-lake-clean-and-compliant-with-amazon-athena/
- **DynamoDB per-user deletion (query PK → batch-delete; the `delete_account` idiom, applied to
  `MangoFeatures`):**
  - PartiQL/DeleteItem & BatchWriteItem semantics:
    https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/SQLtoNoSQL.DeleteData.html
- **S3 presigned URLs (short-TTL DSAR download) & lifecycle expiration (export + lake retention
  floor):**
  - Presigned URLs (private bucket, short expiry, offloaded transfer):
    https://oneuptime.com/blog/post/2026-02-12-generate-presigned-urls-temporary-s3-access/view
  - S3 Lifecycle expiration / retention (per-prefix object expiry for data minimisation):
    https://docs.aws.amazon.com/AmazonS3/latest/userguide/lifecycle-configuration-examples.html
