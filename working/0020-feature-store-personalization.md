# 0020 — Feature store — population + personalization

- **Epic:** M9 · **Status:** Draft · **Owner:** unassigned · **Updated:** 2026-06-26
- **Reviewers:** Principal, SD, QA

## 1. Summary
Spec [`0006-data-lake.md`](../docs/specs/0006-data-lake.md) provisioned the online
feature store — DynamoDB `MangoFeatures-<stage>` (PK `entityId`, SK `featureName`,
PAY_PER_REQUEST, prod PITR) — but **nothing populates it and nothing reads it**.
`ApiStack` even receives `features_table` and currently `del`s it ("reserved for
future producers", see `backend/mango_backend/api_stack.py`). This spec defines the
**producer pipeline** (compute per-user features from the analytics events lake and/or
from the live `/v1/events` stream) and the **consumers** that make the features
*visibly* change behavior: (1) **roadmap personalization** — inject features into the
Bedrock prompt in `generate_roadmap.py` / `prompts.py`; (2) **reminder timing** — pick
the daily notification hour from the user's best time-of-day; (3) **difficulty
adaptation** of generated exercises. It also adds an internal read endpoint
`GET /v1/me/features`. The outcome: for an active user, features are populated and
two behaviors (roadmap prompt + reminder hour) demonstrably differ from the
cold-start defaults.

## 2. Goals / Non-goals
- **Goals:**
  - **Produce** a defined set of per-user features into `MangoFeatures-<stage>`,
    keyed `entityId=USER#<sub>`, `featureName=<name>`, value + `updatedAt`, with **no
    floats** (scaled ints or JSON strings — DynamoDB-resource-API safe, per CLAUDE.md).
  - Support **two producer paths**, gated by config: **(A) batch** — a scheduled
    Lambda (EventBridge) querying the events lake via Athena over a rolling window;
    **(B) online** — a Lambda updating cheap counters/recency features straight from
    `/v1/events`. Ship A as the source of truth; B as a low-latency complement for a
    couple of features.
  - **Consume** features in: roadmap generation (prompt), reminder scheduling (hour),
    and difficulty (exercise XP/format hints).
  - A read path `GET /v1/me/features` (internal/debug) returning the caller's features.
  - **Cold-start defaults**, **freshness/TTL**, and a **privacy** posture consistent
    with spec 0006 (non-sensitive aggregates only; documented deletion gap).
- **Non-goals:**
  - ML models / embeddings / collaborative filtering / a real-time recommender.
  - Book/global features beyond what the consumers need (the table supports
    `entityId=BOOK#<id>`, but populating book-level aggregates is out of scope here).
  - A user-facing "your stats" surface (the read endpoint is internal/debug only).
  - The analytics **dashboards**, and the iOS analytics **producer** (sibling spec
    `feature-analytics-events-ios`, which this depends on for data).
  - Backfill of historical events beyond the rolling window; Athena partition
    projection setup if not already done (tracked in spec 0006 §9 as a follow-up — a
    **prerequisite** for path A).

## 3. Background & context
- **Store:** `backend/mango_backend/analytics_stack.py` →
  `self.features_table = ddb.Table("MangoFeatures-<stage>", PK entityId, SK
  featureName, PAY_PER_REQUEST, PITR in prod)`. Documented in
  [`../docs/DATA_MODEL.md`](../docs/DATA_MODEL.md) §"Online feature store" with example
  features (`xp_7d`, `completion_rate`, `streak_len`) and value/`updatedAt` attributes.
- **Data source:** the events lake — Firehose → `s3://<analytics>/events/dt=…/` (GZIP
  JSON) with Glue table `mango_<stage>.events` (columns `ts,type,userId,props`). Events
  are produced by the iOS `AnalyticsService` (sibling spec). `props` is a JSON string,
  queried in Athena via `json_extract`.
- **Consumer seams that already exist:**
  - **Roadmap:** `backend/src/handlers/generate_roadmap.py` calls
    `claude.generate_roadmap(book, profile, full_text[:12000])`
    (`backend/src/shared/claude.py`), which builds the prompt with
    `prompts.roadmap_user(book, profile, excerpt_text)`
    (`backend/src/shared/prompts.py`). The user id is available via
    `shared.response.user_id(event)` — currently **not** read in this handler; adding
    it is the personalization hook.
  - **Reminders:** iOS `NotificationService.scheduleDailyReminder(hour:minute:body:)`
    (`ios/Mango/Services/Notifications/NotificationService.swift`) already takes an
    hour; today the hour comes from user settings. A `bestHour` feature can drive it.
  - **Difficulty:** the roadmap prompt assigns exercise XP/format; a
    `difficulty_tolerance` feature can bias it (and/or the grade flow).
- **Wiring seam:** `ApiStack.__init__` already accepts `features_table` and
  `events_stream_name`; the producers/consumers attach here (grant + env).
- **Why now:** M9 closes the analytics loop — once the iOS producer lands, an empty
  feature store is the missing half between "we collect events" and "the app adapts".

## 4. User stories
- As a **reader**, I want my roadmap and reminders to fit how I actually read (pace,
  topics, when I'm active), so that the journey feels personal and the nudge lands at a
  useful time.
- As a **personalization engineer**, I want per-user features computed on a schedule
  and readable with single-digit-ms latency, so that consumers can personalize without
  scanning the lake at request time.
- As a **backend engineer**, I want a single `features.get(entityId)` /
  `features.put(...)` module (stdlib+boto3, no floats), so that producing/consuming a
  feature is a couple of lines and DynamoDB type rules are handled in one place.
- As **privacy/legal**, I want only non-sensitive aggregates stored, with a documented
  TTL/deletion path, so that the feature store doesn't become a PII liability.

## 5. Requirements
**Functional**
- **FR-1 (feature module):** a `shared/features.py` (stdlib + boto3) with
  `get_features(entity_id) -> dict[name -> value]`,
  `put_feature(entity_id, name, value, scale=…)`,
  `put_features(entity_id, mapping)` — all **float-safe**: numeric values are stored as
  **scaled integers** (e.g. `value_scaled` = round(x·1000), `scale=1000`) or JSON
  strings; reads normalize `Decimal`→`int`/`float` and unscale. Each item carries
  `updatedAt` (ISO-8601) and `ttlAt` (epoch, optional). Reads tolerate a missing table
  (`FEATURES_TABLE_NAME` unset → empty dict), mirroring the best-effort posture.
- **FR-2 (feature set v1):** compute & store, keyed `USER#<sub>`:

  | featureName | meaning | encoding | producer |
  |---|---|---|---|
  | `reading_pace_wpm` | est. words/min | int | batch |
  | `pref_topics` | top genres/interests | JSON string (≤5 strings, from onboarding enums + import sources) | batch |
  | `best_hour_local` | best time-of-day (0–23) | int | batch (+online recency) |
  | `avg_session_min` | avg session length | int (minutes) | batch |
  | `difficulty_tolerance` | 0–1 tolerance | scaled int (×1000) | batch |
  | `days_active_28` | active days in 28d | int | batch |
  | `lessons_7d` | lessons completed last 7d | int | online + batch |
  | `last_active_ts` | recency | ISO string | online |

  (Feature names are stable; new ones are additive. `pref_topics` stores **interest
  enums / source kinds**, never book titles or free text.)
- **FR-3 (batch producer):** an EventBridge-scheduled Lambda
  (`handlers/features_batch.handler`, default daily) runs Athena queries over
  `mango_<stage>.events` for a rolling window (e.g. 28 days), computes the per-user
  features above, and upserts them via `shared/features.py`. It is **idempotent**
  (recomputes from the window each run) and bounded (paginates Athena results;
  `batch_writer` upserts). It must **not** require any float write.
- **FR-4 (online producer):** the existing `events_fn`
  (`handlers/events.py`) optionally updates a small set of cheap features on each
  accepted event **best-effort** (e.g. bump `lessons_7d` on `lesson_completed`, set
  `last_active_ts`, nudge an `hour_histogram_*` used to derive `best_hour_local`).
  Gated by a `FEATURES_TABLE_NAME` env; failure never affects the 200 response (same
  contract as Firehose emission). Recommendation: keep online updates to **counters +
  recency** only; `best_hour_local` is finalized by the batch job.
- **FR-5 (read endpoint):** `GET /v1/me/features` (secured) returns
  `{ "features": { name: value, … }, "updatedAt": "<max updatedAt>" }` for the caller
  (`USER#<sub>`), applying cold-start defaults (FR-7) for any missing feature. Internal
  /debug use; documented as non-public.
- **FR-6 (consumers):**
  - **Roadmap:** `generate_roadmap.handler` resolves `uid = user_id(event)`, loads
    `get_features("USER#"+uid)`, and passes a compact, **allow-listed** feature subset
    into `prompts.roadmap_user(book, profile, excerpt_text, features=…)`, which adds a
    short `READER FEATURES: {…}` block instructing pacing/topic/difficulty adaptation.
    The roadmap **cache** key must account for personalization (see §9 / §10).
  - **Reminder timing:** the iOS app reads `best_hour_local` (via `GET /v1/me/features`
    on a configured backend) and passes it to
    `NotificationService.scheduleDailyReminder(hour:…)`; falls back to the user's
    chosen hour / a sane default when absent.
  - **Difficulty:** the same feature block lets the model bias exercise mix/XP toward
    `difficulty_tolerance` (more application/quiz rigor for high tolerance, gentler for
    low). No separate endpoint; it rides the roadmap prompt.
- **FR-7 (cold-start defaults):** when a feature is absent, consumers use defaults:
  `reading_pace_wpm=200`, `pref_topics=[]` (fall back to onboarding `interests`),
  `best_hour_local=20` (8pm), `avg_session_min=10`, `difficulty_tolerance=0.5`,
  `days_active_28=0`, `lessons_7d=0`. Defaults live in one place (`shared/features.py`
  `DEFAULTS`) and are mirrored on iOS for reminder fallback.
- **FR-8 (freshness/TTL):** items carry `updatedAt`; batch features get `ttlAt` =
  now+`FEATURE_TTL_DAYS` (default 60) and the table has a DynamoDB **TTL attribute**
  (`ttlAt`) enabled (analytics_stack change) so stale rows self-expire. Consumers may
  treat features older than `FRESHNESS_DAYS` (default 35) as cold-start.

**Non-functional**
- **NFR-1 (no floats):** every DynamoDB write goes through `shared/features.py`, which
  stores scaled ints / JSON strings only — verified by a unit test that asserts no
  `float` reaches the resource API (mirrors `progress.py`/`generate_roadmap.py`).
- **NFR-2 (least privilege):** the batch Lambda gets read/write on
  `MangoFeatures-<stage>`, Athena `StartQueryExecution`/`GetQueryResults`, read on the
  analytics bucket + the Athena results prefix, and Glue read; `events_fn` gets
  **write** on the features table (only if online producer enabled). Roadmap/read
  Lambdas get **read** on the features table. The grade Lambda stays table-less
  (CLAUDE.md invariant).
- **NFR-3 (best-effort consumption):** missing/empty features must never fail roadmap
  generation, the events endpoint, or reminder scheduling — all degrade to cold-start.
- **NFR-4 (privacy):** store only non-sensitive aggregates/enums; **no** titles, text,
  emails, precise location. Same deletion gap as the event lake — `DELETE /v1/me` does
  **not** yet purge `MangoFeatures-<stage>` rows (documented; TTL bounds retention).
  Adding feature-store purge to account deletion is a tracked follow-up.
- **NFR-5 (cost):** batch runs once/day over a pruned partition range; on-demand
  tables; Athena scans are partition-pruned by `dt`. No per-request lake scans.
- **NFR-6 (stdlib+boto3):** all handlers/modules use stdlib + boto3 only (no packaging).
- **NFR-7 (style):** black (line-length 100) + flake8 (max 120); `make backend-lint`
  clean.

## 6. Design
**API / contract** — add to [`shared/api/openapi.yaml`](../shared/api/openapi.yaml):
```
/v1/me/features:
  get:
    summary: Read the caller's personalization features (internal/debug)
    responses:
      "200":
        content: application/json:
          schema:
            type: object
            properties:
              features: { type: object, additionalProperties: true }
              updatedAt: { type: string, format: date-time, nullable: true }
```
Keep it `bearerAuth`-secured. `RoadmapRequest` is unchanged on the wire — features are
fetched **server-side** from the caller's JWT, not sent by the client (the iOS app may
also send a hint, but the source of truth is the store). No change to iOS request DTOs
needed for roadmap; iOS gains a tiny `FeaturesDTO` for the read endpoint to drive
reminders.

**Data — `MangoFeatures-<stage>` item shape** (no floats):
```
PK entityId   = "USER#<sub>"          # or "BOOK#<bookId>" (future)
SK featureName = "reading_pace_wpm"
value          = 210                    # int
# or, for scaled/decimal features:
value_scaled   = 500   ; scale = 1000   # difficulty_tolerance = 0.5
# or, for structured features:
valueJson      = "[\"stoicism\",\"habits\"]"   # pref_topics
updatedAt      = "2026-06-26T08:00:00Z"
ttlAt          = 1719560000             # epoch seconds (batch features)
producer       = "batch" | "online"
```
`analytics_stack.py` change: enable **TTL** on the table
(`time_to_live_attribute="ttlAt"`).

**Producers**
- **Batch (`handlers/features_batch.py` + EventBridge rule in a CDK stack):**
  1. For the window `[today-28, today]`, run parameterized Athena SQL against
     `mango_<stage>.events`, e.g.:
     - active days / lessons: `SELECT userId, COUNT(DISTINCT dt) days, ` …
       `SUM(CASE WHEN type='lesson_completed' THEN 1 END) lessons …`
     - best hour: `… GROUP BY userId, hour(from_iso8601_timestamp(ts))` → argmax.
     - pace/session: from `lesson_completed.props.minutesEstimated`,
       `book_imported.props.wordCount`, and event timestamps (session = gap-based).
     - topics: most frequent `onboarding_completed`/`book_imported` enums.
     - difficulty: from `exercise_graded.props.score`/`correct` distribution.
  2. Normalize, scale, and `put_features(USER#<userId>, mapping)` via
     `shared/features.py` (idempotent upsert; sets `updatedAt`, `ttlAt`,
     `producer="batch"`).
  3. Output query results to an Athena results prefix in the analytics bucket
     (`athena-results/`).
  *(Prerequisite: Athena partitions registered — projection on `dt` per spec 0006 §9.)*
- **Online (`handlers/events.py` augmentation, opt-in via `FEATURES_TABLE_NAME`):**
  after `firehose.put_event(...)`, best-effort `features.bump(...)`/`features.set(...)`
  for counters + recency on a small allow-list of event types. Never raises.

**Consumers**
- **Roadmap prompt:** extend `prompts.roadmap_user(book, profile, excerpt_text,
  features: dict | None = None)` to append (when present):
  `READER FEATURES (use to tune pace, topic emphasis, and difficulty): {compact json}`
  with an instruction line. `generate_roadmap.handler` reads `uid = user_id(event)`
  (already imported pattern via `shared.response`), loads features, allow-lists the
  subset (`reading_pace_wpm`, `pref_topics`, `avg_session_min`, `difficulty_tolerance`,
  `best_hour_local` not needed here), and passes it through `claude.generate_roadmap`
  (add a `features` param threaded to `prompts.roadmap_user`).
- **Reminder timing (iOS):** on launch/settings open with a real backend + session,
  fetch `GET /v1/me/features`, read `best_hour_local`, and call
  `NotificationService.scheduleDailyReminder(hour: bestHour, minute: 0, body:…)`;
  fall back to the user's chosen hour / default 20:00 when absent or offline.
- **Difficulty:** carried by the roadmap prompt's feature block (no extra surface).

**Diagram**
```
events lake (S3/Glue)  ──Athena (daily, EventBridge)──► features_batch Lambda
        ▲                                                   │ put_features (scaled int/json)
        │ Firehose                                          ▼
   POST /v1/events ──► events_fn ──(online, best-effort)──► MangoFeatures-<stage>
                                                            │  ▲
                       generate_roadmap.handler ◄───get_features│  │get_features
                         → prompts.roadmap_user(…, features) ──► Bedrock
                       GET /v1/me/features ◄──────────────────┘  │
   iOS NotificationService.scheduleDailyReminder(hour=best_hour) ┘
```

## 7. Acceptance criteria
- [ ] **AC-1** `shared/features.py` round-trips every feature type with **no float**
      reaching the DynamoDB resource API: ints, scaled decimals (`difficulty_tolerance`
      0.5 ↔ stored `value_scaled=500,scale=1000`), and JSON-string lists
      (`pref_topics`). Reads unscale and normalize `Decimal`. Missing table → `{}`.
      *(pytest: `tests/test_features.py`)*
- [ ] **AC-2** The batch producer, run against a seeded fake Athena result set,
      computes the expected `reading_pace_wpm`, `best_hour_local`, `avg_session_min`,
      `difficulty_tolerance`, `days_active_28`, `lessons_7d`, `pref_topics` for a
      sample user and upserts them with `updatedAt`+`ttlAt`+`producer="batch"`.
      *(pytest: `tests/test_features_batch.py`, Athena client monkeypatched.)*
- [ ] **AC-3** The online producer bumps `lessons_7d` and sets `last_active_ts` on a
      `lesson_completed` event, and is a no-op (still 200) when `FEATURES_TABLE_NAME`
      is unset or the write fails. *(pytest: extend `tests/test_events.py`.)*
- [ ] **AC-4** `GET /v1/me/features` returns the caller's stored features merged with
      cold-start defaults, resolves identity from the JWT (`401` without it in
      prod/beta), and applies the dev `x-mango-user` fallback outside prod/beta.
      *(pytest: `tests/test_features_endpoint.py`.)*
- [ ] **AC-5 (roadmap uses features):** when features exist, the prompt produced by
      `prompts.roadmap_user(..., features=…)` contains a `READER FEATURES` block with
      the allow-listed values; when absent, the prompt is byte-identical to today's
      (cold-start path unchanged). *(pytest: `tests/test_prompts.py` +
      `tests/test_generate_roadmap.py` asserting the prompt string passed to the
      monkeypatched `claude._invoke`.)*
- [ ] **AC-6 (reminder hour changes):** given a stubbed `GET /v1/me/features` returning
      `best_hour_local=7`, the iOS reminder scheduler calls `scheduleDailyReminder` with
      `hour: 7`; with no feature it uses the configured default. *(XCTest:
      `MangoTests/ReminderTimingTests.swift` with a fake features client +
      `NotificationService` seam — extract an injectable `hourProvider`.)*
- [ ] **AC-7 (no-float guarantee):** a unit test asserts that for the full feature set,
      every value handed to `Table.put_item`/`batch_writer` is `int`/`str`/`Decimal`
      and never `float`. *(pytest, part of `tests/test_features.py`.)*
- [ ] **AC-8 (synth):** the new EventBridge rule + features-batch Lambda + table TTL +
      IAM grants synthesize for beta and prod (`cdk synth -c stage=beta` /`prod`).
- [ ] **AC-9 (end-to-end, manual, beta):** for an active dogfood user, after the iOS
      producer (sibling spec) emits events and the batch job runs, `GET /v1/me/features`
      returns non-default values; a freshly generated roadmap's prompt includes the
      feature block (verifiable via a debug log / temporary echo); the scheduled
      reminder hour matches `best_hour_local`.

## 8. Test plan
- **Unit (pytest, offline — moto for DynamoDB, monkeypatch Athena + Bedrock):**
  AC-1…AC-5, AC-7. Seed a synthetic Athena result set; assert feature math, encoding,
  endpoint behavior, and prompt augmentation. Reuse the repo's existing
  moto/monkeypatch style (29-test suite).
- **Unit (XCTest):** AC-6 — reminder hour selection from a fake features client;
  cold-start fallback.
- **Synth:** AC-8 — in-process `app.synth()` template assertions for the rule/Lambda/
  TTL/grants; `cdk synth -c stage=beta` and `-c stage=prod` pass.
- **Manual (beta):** AC-9 — requires the iOS analytics producer deployed, partitions
  registered, and the batch job triggered once; verify store values, roadmap prompt
  block (temporary echo), and reminder hour.
- **Automated vs manual:** feature math, encoding, endpoint, prompt augmentation,
  reminder selection, and synth are automated; the cross-system end-to-end (lake →
  Athena → store → prompt/reminder) is manual on a deployed stage.

## 9. Rollout & migration
- **Order:** (1) `shared/features.py` + `tests`; (2) read endpoint
  `GET /v1/me/features` + grant; (3) consumers (roadmap prompt + reminder hook) behind
  cold-start defaults so they're safe with an empty store; (4) batch producer +
  EventBridge (off until partitions exist); (5) optional online producer. Each step is
  independently shippable and inert without data.
- **Roadmap cache:** today `generate_roadmap` caches the roadmap at
  `BOOK#<bookId>/ROADMAP` (book-scoped, not user-scoped). Personalized roadmaps must
  **not** be served cross-user from that key. **Decision (recommend):** when features
  are applied, either (a) skip the cache write/read for personalized generations, or
  (b) move the cache to a user+book key (`USER#<sub>` / `ROADMAP#<bookId>`). Recommend
  **(a)** for v1 (simplest; personalization is the differentiator), with (b) as a
  follow-up if cost requires. Until decided, gate personalization behind a config flag
  (`PERSONALIZE_ROADMAP`, default off in prod) so the cache contract is unchanged by
  default.
- **Backward compatibility:** with no features, every consumer is byte-for-byte the
  current behavior (AC-5 asserts the prompt is unchanged on the cold-start path).
- **Privacy/deletion:** features are non-sensitive aggregates with a TTL; `DELETE
  /v1/me` does not yet purge them — add a feature-store purge step (`Query entityId =
  USER#<sub>` → `batch_writer` delete) to `delete_account` as a tracked follow-up
  (cheap, low-risk).
- **Teardown:** disable the EventBridge rule + `PERSONALIZE_ROADMAP` flag to fully
  revert; TTL drains the table.

## 10. Risks & open decisions
- **Decision — roadmap cache vs personalization** (see §9): *recommend skip-cache for
  personalized generations in v1 behind `PERSONALIZE_ROADMAP`.*
- **Decision — best_hour source:** batch-only vs online histogram. *Recommend batch
  finalizes `best_hour_local`; online only maintains a recency/counters complement.*
- **Decision — feature freshness when partitions/backfill are thin:** treat
  stale/sparse features as cold-start (`FRESHNESS_DAYS`). *Recommend conservative
  defaults so a half-populated store never produces worse output than today.*
- **Risk — Athena partitions not registered** → batch returns nothing. *Mitigation:*
  land partition projection (spec 0006 §9) first; AC-8/AC-2 don't depend on real
  Athena (monkeypatched).
- **Risk — DynamoDB float rejection.** *Mitigation:* single `shared/features.py`
  choke point + AC-1/AC-7.
- **Risk — privacy creep in `pref_topics`.** *Mitigation:* store interest **enums** /
  source kinds only; never titles/text; deletion follow-up + TTL.
- **Risk — personalization makes roadmaps non-reproducible / harder to test.**
  *Mitigation:* AC-5 pins the cold-start prompt; feature block is additive and
  allow-listed; temperature already non-zero, so this doesn't change determinism
  guarantees.
- **Risk — reminder hour fetch adds a launch network call.** *Mitigation:* best-effort,
  cached, off the critical path; falls back to the user's setting instantly when
  offline.

## 11. Tasks & estimate
1. `shared/features.py` (get/put/bump, scaling, JSON, defaults, missing-table-safe) +
   `tests/test_features.py` (AC-1, AC-7) (**M**).
2. Enable TTL (`ttlAt`) on `MangoFeatures-<stage>` in `analytics_stack.py` (**S**).
3. `GET /v1/me/features` handler + route + read grant + openapi + iOS `FeaturesDTO`
   (`tests/test_features_endpoint.py`, AC-4) (**M**).
4. Roadmap consumer: thread `features` through `generate_roadmap.handler` →
   `claude.generate_roadmap` → `prompts.roadmap_user`; allow-list + `PERSONALIZE_ROADMAP`
   flag + cache decision; tests (AC-5) (**M**).
5. Reminder consumer (iOS): inject `hourProvider`/features client into the reminder
   scheduling path; fallback; XCTest (AC-6) (**M**).
6. Batch producer `handlers/features_batch.py` + Athena SQL + EventBridge rule (new/
   extended CDK stack) + IAM (Athena/Glue/S3/table) + `tests/test_features_batch.py`
   (AC-2, AC-8) (**L**).
7. Online producer augmentation in `handlers/events.py` (counters/recency,
   best-effort) + tests (AC-3) (**S**).
8. Account-deletion follow-up: purge `USER#<sub>` feature rows in `delete_account`
   (**S**, follow-up).
9. Docs: promote this spec to `docs/specs/NNNN-…`; update
   [`../docs/DATA_MODEL.md`](../docs/DATA_MODEL.md) feature-store section (final feature
   names + TTL) and spec 0006 cross-link (**S**).

## 12. References
- Store/infra: `backend/mango_backend/analytics_stack.py` (`MangoFeatures-<stage>`),
  `backend/mango_backend/api_stack.py` (receives `features_table`, currently `del`'d),
  `backend/mango_backend/stage.py` (passes `features_table`/`events_stream_name`).
- Consumers: `backend/src/handlers/generate_roadmap.py`, `backend/src/shared/claude.py`,
  `backend/src/shared/prompts.py`, `backend/src/shared/response.py` (`user_id`),
  `ios/Mango/Services/Notifications/NotificationService.swift`,
  `ios/Mango/App/AppModel.swift`, `ios/Mango/Services/Networking/APIClient.swift`.
- Source data: `backend/src/handlers/events.py`, `backend/src/shared/firehose.py`,
  Glue `mango_<stage>.events`.
- Contract/docs: [`shared/api/openapi.yaml`](../shared/api/openapi.yaml),
  [`../docs/DATA_MODEL.md`](../docs/DATA_MODEL.md),
  [`0006-data-lake.md`](../docs/specs/0006-data-lake.md),
  [`SPEC_TEMPLATE.md`](../docs/specs/SPEC_TEMPLATE.md).
- Sibling specs: `0015-analytics-events-ios.md` (the producer of the events this
  consumes), `0022-app-store-prep.md` (privacy labels covering this data).
