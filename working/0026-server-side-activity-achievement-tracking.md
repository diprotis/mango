# 0026 — Server-side activity & achievement tracking

- **Epic:** M9 · **Status:** Draft · **Owner:** unassigned · **Updated:** 2026-06-28
- **Reviewers:** Principal / SD / QA

## 1. Summary
Today Mango's server-side tracking is **aggregate-only**: `USER#<sub>/PROGRESS` holds six rollup
integers and nothing else. *Which* lessons and activities a user finished, *what* they answered,
*what* they scored, their per-day activity, their unlocked achievements, and each book's journey
state all live **only in on-device SwiftData** — a reinstall wipes them and a second device starts
blank. `grade_exercise` computes a score and **persists nothing**; the documented
`USER#<sub>/ACTIVITY#<date>` and `USER#<sub>/ACHV#<key>` items are named in `docs/DATA_MODEL.md` but
**never written**; the `BOOK#<id>/ROADMAP` cache is dead; and the async roadmap **jobs leak forever**
(no TTL). This spec makes server-side tracking **real**. It introduces four new single-table item
families — `ACTIVITY#<date>` (atomic-`ADD` daily rollups), `ACHV#<key>` (idempotent unlock),
`LESSONDONE#<roadmapId>#<lessonId>` (the **trusted completion signal** that credits `0023` and
leagues `0021` both need), and a populated `BOOK#<id>/ROADMAP` cache — plus extends the per-user
**library item** with journey state (`0008`), adds an **optimistic-lock `version`** to `PROGRESS`,
adds a table-wide **TTL attribute** so jobs (and other ephemera) self-expire, and pre-provisions the
**three GSIs** the downstream specs need (`GSI_LEAGUE`, `GSI_CATALOG`, `GSI_DEVICE`). High-volume,
immutable per-answer history is routed to the **events lake** (`0015`), not hot DynamoDB. New write
paths land on either an extended `PUT /v1/me/progress` or two new endpoints
(`POST /v1/me/activity`, `POST /v1/roadmaps/{roadmapId}/complete`); a one-time **on-device→server
backfill** seeds existing users; `DELETE /v1/me` is verified to **cascade** every new SK. All of it
stays **float-free** (ints or JSON strings), stdlib + boto3, single-table, and keeps
`openapi.yaml` ⇄ `DTOs.swift` ⇄ handlers in lockstep.

## 2. Goals / Non-goals
- **Goals:**
  - Persist **per-day activity** server-side as `USER#<sub>/ACTIVITY#<date>` rollups, mutated by
    **atomic `ADD`** (XP, minutes, lessons, activities) so concurrent writes never lost-update and
    no read-modify-write is needed.
  - Persist **achievement unlocks** as `USER#<sub>/ACHV#<key>` items, written **idempotently**
    (conditional `attribute_not_exists`) so re-reporting an unlock is a no-op.
  - Persist a **trusted per-lesson completion signal** `USER#<sub>/LESSONDONE#<roadmapId>#<lessonId>`,
    validated against the cached roadmap, that `0023` (earn-credits-on-completion) and `0021`
    (league ledger) consume — the client cannot simply assert "done."
  - Extend the **library item** (`USER#<sub>/BOOK#<bookId>`) with `journeyState` +
    `confirmedMilestones` so per-book journey state (`0008`) survives reinstall and rides the
    library sync.
  - **Actually populate `BOOK#<id>/ROADMAP`** — the worker writes the generated roadmap to the
    book-scoped cache so it is inspectable and reusable (and so `LESSONDONE` validation has a
    server-side lesson set to count against).
  - Add **`version:int`** to `PROGRESS` (optimistic concurrency) and a **table TTL attribute**
    (`ttlAt`, epoch seconds) applied to ephemeral items (roadmap jobs first).
  - Pre-provision **3 GSIs** in `data_stack.py` — `GSI_LEAGUE` (leaderboards, `0021`), `GSI_CATALOG`
    (active rewards, `0024`), `GSI_DEVICE` (device registry / push, `0025`) — overloaded, generic
    `*PK`/`*SK`, ints zero-padded so string sort == numeric sort.
  - Route **raw per-answer history** (immutable, high-volume) to the **events lake** (`0015`), never
    hot DynamoDB.
  - **On-device→server backfill** on first authenticated launch, **idempotent** by `date` / `key` /
    `(roadmapId, lessonId)`, so existing users' history isn't lost and a re-run double-counts nothing.
  - Verify **`DELETE /v1/me`** cascades every new SK (it queries `PK=USER#<sub>` and batch-deletes —
    new SKs are swept automatically; this spec adds a regression test).
  - Preserve every invariant: **float-free** DynamoDB, **stdlib+boto3** Lambdas, **single table**
    (`MangoFeatures` stays separate), **offline-first**, and `openapi.yaml` ⇄ `DTOs.swift` ⇄ handlers
    in sync.
- **Non-goals:**
  - **The progress-aggregate sync client + merge** (`0014`) — that owns `GET`/`PUT /v1/me/progress`
    glue and the monotonic `max`-merge. Here we add the **server-side `version`** column and the new
    *granular* item families; the aggregate-six-fields merge stays `0014`'s.
  - **The credit ledger / earn-on-completion economics** (`0023`) and the **league ranking / rollover**
    (`0021`) — we provide the `LESSONDONE` signal and the `GSI_LEAGUE` index they consume; their
    handlers, idempotency, and anti-cheat are theirs.
  - **The activity-type framework / submission schema** (`0039`) — `ACTIVITY#<id>` *assignment*,
    `SUBMISSION#…`, and S3 submission-artifact items are defined and owned by `0039`. This spec adds
    the **per-day rollup** and the **lesson-level completion** items, and notes the seam so the two
    coexist on one table without collision.
  - **The generation-artifact store + LLM observability** (`0027`) — populating `BOOK#<id>/ROADMAP`
    here is the *functional cache* (a DDB pointer/JSON the worker writes); the full S3 transcript
    layout, lifecycle, and per-call cost logging are `0027`. **Shared cross-user caching + single-flight**
    is `0028`; here the worker simply writes the book's roadmap so it exists.
  - **Feature-store population** (`0020`) — `MangoFeatures-<stage>` stays a separate table; we do not
    write features here.
  - **Changing gamification math** — `LevelCurve`, `StreakCalculator`, XP amounts, and the
    `Roadmap → Milestone → Lesson → Exercise/Activity` graph are unchanged. We only **record** what
    the engine already computes.

## 3. Background & context
**Current state (verified).** One DynamoDB table (`PK`/`SK` strings + a single `GSI1`,
`PAY_PER_REQUEST`, PITR+`RETAIN` in prod — `backend/mango_backend/data_stack.py`) holds:
`USER#<sub>/PROFILE`, `USER#<sub>/PROGRESS` (six rollup ints + `updatedAt`, `progress.py`),
`USER#<sub>/BOOK#<bookId>` (library ref; `GSI1` by `ADDED#<ts>`, `library.py`),
`USER#<sub>/REFLECTION#<ts>` (`reflections.py`), `USER#<sub>/ROADMAPJOB#<jobId>` (the async job,
`roadmap_jobs.py`), and `BOOK#<bookId>/META` (`content_parse.py`). Per `docs/DATA_MODEL.md`,
`USER#<sub>/ACTIVITY#<date>` and `USER#<sub>/ACHV#<key>` are documented **"— planned"** and
`BOOK#<bookId>/ROADMAP` is documented as a cache but is **never written** (no `put_item` for it
exists anywhere in `backend/src` — confirmed by grep; `roadmap_jobs.mark_complete` writes the roadmap
only onto the *job* row, `ROADMAPJOB#<jobId>`).

`grade_exercise.py` is **stateless**: it grades (quiz deterministically, free-text via
`agent.grade`) and returns `{correct?, score, feedback, xpAwarded}` — it does **not** call `user_id`
and **persists nothing**, so the server has no record an activity was even attempted. The async job
row (`roadmap_jobs.create_pending`) has **no `ttlAt`**, so every generation leaves a permanent item
(a slow leak + a privacy footprint).

**Why now.** Three downstream specs are blocked on real server-side state:
- **`0014` progress-sync** syncs only the six-field aggregate and explicitly leaves
  "per-`ActivityDay` history… device-local" — so a reinstall keeps XP but loses the contribution
  graph, achievements, and which lessons were done.
- **`0023` payments & credits** must grant credits **once per completed roadmap** and needs a
  **server-validated** completion signal (its §6.6 "trusted completion signal" / `D-5` proposes
  exactly `POST /v1/roadmaps/{roadmapId}/complete` validated against the cached roadmap). That signal
  is **this** spec's `LESSONDONE` + `BOOK#<id>/ROADMAP`.
- **`0021` social leagues** ranks users by a **server-written awarded-XP ledger** and reads a
  leaderboard via a GSI (`GSI1PK = LEAGUE#<weekId>#<tier>#<no>`, `GSI1SK = XP#<padded>#<sub>`). That
  index is **this** spec's `GSI_LEAGUE`, pre-provisioned so `0021` adds handlers, not infra.

**The architecture-review design this expands.** `working/ARCHITECTURE_REVIEW.md` §2.1 ("User data +
progress need real DDB tracking → propose 0026") specifies the exact item set, the events-lake split,
the `version` + TTL additions, and the three GSIs. This spec turns that paragraph into an
implementation-ready plan at the grade of `0008`/`0023`.

**Key idioms reused (verified in-repo):**
- **Float-free.** `progress.py` coerces every numeric to `int` and decodes `Decimal`→`int`; this spec
  reuses that `_to_plain` choke point and stores scores as **basis points** (`int` 0–10000) and
  rollups as `int`s. (`CLAUDE.md` invariant: the DynamoDB resource API rejects Python `float`.)
- **Conditional/atomic writes.** `0023` §6.2 shows the exact `update_item` idioms this spec uses:
  **atomic `ADD`** for rollups, **conditional `attribute_not_exists`** for idempotent grants, and
  **`ConditionExpression` on `version`** for optimistic locking.
- **Per-user listing + cascade.** `library.py` shows the `USER#<sub>` + `begins_with(SK,…)` listing
  and `GSI1` add-order; `delete_account.py` already queries **all** `PK=USER#<sub>` items and
  batch-deletes — new SKs cascade for free.
- **Best-effort telemetry.** `0015`/`shared/firehose.py` `put_event(...)` returns `False` (never
  raises) when the stream is unset — the model for routing raw answers to the lake without ever
  failing a request.

## 4. User stories
- As a **returning user**, I reinstall Mango, sign in, and my **contribution graph, achievements, and
  which lessons I've completed** come back — not just my XP total — so the app remembers everything I
  did, not a summary of it.
- As a **two-device user**, lessons I complete on my iPhone are recorded server-side, so my iPad sees
  the same journey progress and my streak/contribution history is consistent.
- As an **engaged learner**, when I **finish a journey** the server *knows* I finished it (validated
  against the real roadmap), so I'm credited exactly once (`0023`) and it counts toward my weekly
  league XP (`0021`) — and I can't be cheated out of it by a flaky network or a reinstall.
- As **Mango (the business)**, every daily rollup, achievement unlock, and lesson completion is
  **idempotent and auditable**, so retries, backfills, and duplicate posts never double-count.
- As a **backend engineer**, roadmap **jobs expire on their own** (TTL) instead of accumulating
  forever, and the **leaderboard / rewards / device** access patterns already have their indexes, so
  `0021`/`0024`/`0025` are pure feature work.
- As an **offline / signed-out user**, none of this changes my first run: the bundled sample + Mock AI
  still work with **no network and no key**; server tracking is a no-op without a session, and the app
  never blocks on it (`CLAUDE.md` offline-first invariant).
- As a **privacy-conscious user**, deleting my account erases **all** of this granular history (the
  new SKs) along with everything else.

## 5. Requirements

### 5.1 Functional
- **FR-1 (daily activity rollups, atomic).** A `USER#<sub>/ACTIVITY#<date>` item (`<date>` =
  `YYYY-MM-DD`, the user's **local** calendar day, matching `StreakCalculator`) accumulates the day's
  totals via **atomic `ADD`**: `xp:int`, `minutes:int`, `lessons:int`, `activities:int` (and reserves
  `freezesUsed:int`). Each contribution is `update_item(... UpdateExpression="ADD xp :x, ...")` — no
  read-modify-write, so concurrent device writes converge. The item also stamps `updatedAt` (`SET`).
- **FR-2 (achievement unlock, idempotent).** A `USER#<sub>/ACHV#<key>` item (`<key>` = an
  `AchievementCatalog` id, e.g. `first_lesson`, `streak_7`) records `{ unlockedAt }`, written with
  `ConditionExpression="attribute_not_exists(PK)"`. Re-reporting an already-unlocked achievement
  returns success (no-op) and **never** rewrites `unlockedAt` (the original unlock time is preserved).
- **FR-3 (trusted lesson completion).** A `USER#<sub>/LESSONDONE#<roadmapId>#<lessonId>` item records
  `{ completedAt, scoreBp?:int }`, written **only** after the server validates that `lessonId` is a
  real lesson of `roadmapId` (looked up from the cached `BOOK#<bookId>/ROADMAP`, FR-5). Idempotent by
  the composite SK. This item is the **single source of truth** for "lesson done" that `0023`/`0021`
  read; the client cannot fabricate a completion for a lesson the roadmap doesn't contain.
- **FR-4 (roadmap-complete signal).** When **all** lessons of a roadmap have `LESSONDONE` items, the
  roadmap is "complete." `POST /v1/roadmaps/{roadmapId}/complete` (or the FR-9 `activity` batch)
  validates the reported completed-lesson set **covers every lesson** of the cached roadmap and, if so,
  writes a `USER#<sub>/ROADMAPDONE#<roadmapId>` marker (`{ completedAt }`, idempotent by SK). This
  marker is the exactly-once hook `0023` `grant_completion` keys off and the event `0021` counts. The
  reward/credit grant itself is **not** issued here (that's `0023`); this spec only establishes the
  validated signal + marker.
- **FR-5 (populate `BOOK#<id>/ROADMAP`).** The roadmap **worker** (and the inline fallback in
  `generate_roadmap.py`), on successful generation **for a `bookId`** (catalog or imported, not a
  purely-inline book), writes `BOOK#<bookId>/ROADMAP` = `{ roadmap: <JSON string>, lessonIds: [..],
  promptVersion, modelId, updatedAt }` (best-effort, idempotent overwrite). `lessonIds` is the flat
  ordered list of the roadmap's lesson ids, so FR-3/FR-4 validation is an O(1) membership/coverage
  check without re-parsing the whole roadmap. Inline-only books (no `bookId`) skip this (nothing to key
  on). **Item-size guard:** if the serialized roadmap risks the 400 KB DynamoDB item limit, store only
  `lessonIds` + a pointer and defer the full body to S3 (the `0027`/`0028` layout) — see D-4.
- **FR-6 (library journey state).** The per-user library item (`USER#<sub>/BOOK#<bookId>`,
  `library.py`) gains string attributes `journeyState` (`notStarted|reading|finished`, default
  `notStarted`) and `confirmedMilestones` (a DynamoDB **list of strings** — milestone ids the user
  read-confirmed). `GET /v1/me/library` returns them; `POST`/a new `PUT` upserts them. This is the
  server side of `0008` FR-12 (no numeric fields → float-free). Reconciliation across devices is
  "latest write of the per-book item" (journey state is low-frequency, user-driven; not XP-sensitive).
- **FR-7 (progress optimistic lock).** `USER#<sub>/PROGRESS` gains `version:int` (default 0). `PUT
  /v1/me/progress` increments `version` and **may** be guarded by
  `ConditionExpression="attribute_not_exists(version) OR version = :expected"` when the client supplies
  the version it last read; a mismatch returns **409 Conflict** (`{ "error": "version_conflict",
  "current": <serverProgress> }`) so the client re-pulls and re-merges (`0014`'s `max`-merge). When the
  client omits the version (legacy/`0014`-not-yet-shipped), the write is unconditional (back-compat) —
  D-2.
- **FR-8 (route raw answers to the events lake).** Per-answer detail (the prompt, the user's text/choice,
  the model feedback) is **high-volume + immutable + potentially sensitive** and is **not** stored in
  the product table. `grade_exercise.py` (and the on-device path via `0015`'s `AnalyticsService`) emits
  an `exercise_graded` event (`{ activityId, kind, scoreBp, xpAwarded, correct? }` — **ids/enums/scalars
  only**, never the answer text) to `POST /v1/events`. The lake (`0015`/`0006`) is the durable home for
  raw history; the product table holds only the **scalar outcome** roll-ups (FR-1) and the
  **completion** facts (FR-3/FR-4).
- **FR-9 (batch activity endpoint).** `POST /v1/me/activity` accepts a small batch of tracking deltas
  for one or more dates — `{ days: [{ date, xp, minutes, lessons, activities }], achievements:
  [{ key, unlockedAt }], lessonsDone: [{ roadmapId, lessonId, scoreBp? }] }` — and applies FR-1/FR-2/FR-3
  idempotently in one call (used by the live engine to push the day's increments and by the FR-11
  backfill). `ADD` makes day rollups commutative; achievements/lessons are conditional. Returns a
  per-item applied/skipped summary.
- **FR-10 (three GSIs pre-provisioned).** `data_stack.py` adds three **overloaded** GSIs (generic key
  names; no items written by *this* spec except where noted — they exist so downstream specs need no
  infra change):
  - **`GSI_LEAGUE`** — `GSI_LEAGUE_PK` / `GSI_LEAGUE_SK`. `0021` writes
    `LEAGUE#<weekId>#<tier>#<no>` / `XP#<zeroPaddedWeeklyXP>#<sub>`; a single
    `Query(ScanIndexForward=False, Limit≈30)` returns a leaderboard already sorted by weekly XP.
  - **`GSI_CATALOG`** — `GSI_CATALOG_PK` / `GSI_CATALOG_SK`. `0024` writes `REWARD#ACTIVE` /
    `<activeFrom>#<rewardId>` to list active rewards/coupons by start date.
  - **`GSI_DEVICE`** — `GSI_DEVICE_PK` / `GSI_DEVICE_SK`. `0025` writes `DEVICE#ACTIVE` /
    `<lastSeen>#<sub>` to enumerate active push-token devices for broadcast/cleanup.
  All numeric components are **zero-padded** so lexical sort == numeric sort (float-free). Projection
  `ALL` for v1 simplicity (revisit to `KEYS_ONLY`/`INCLUDE` if cost warrants — D-5).
- **FR-11 (on-device→server backfill).** On the first **authenticated** launch after this ships (and
  after any sign-in on a device with local history), the app performs a **one-time idempotent backfill**:
  it reads local `ActivityDay` rows, unlocked `Achievement`s, and completed `Lesson`s and posts them via
  `POST /v1/me/activity` (FR-9). Guarded by a `UserDefaults` flag (sub-scoped) so it runs once per
  account-per-device; safe to re-run because day rollups would double-`ADD` **unless** keyed — therefore
  backfilled days are sent as an **absolute set** with a `backfill:true` flag that the server applies
  with `SET` (not `ADD`) **iff** the day item is absent or carries `source:"backfill"` (so a real
  same-day increment from the live engine is never clobbered) — see D-3.
- **FR-12 (job TTL).** `roadmap_jobs.create_pending` stamps `ttlAt = now + JOB_TTL_SECONDS` (default
  30 days) so completed/abandoned jobs self-expire. The table enables TTL on attribute `ttlAt`
  (`data_stack.py`). Reads of a job must tolerate (ignore) an item past `ttlAt` that DynamoDB hasn't
  swept yet (up to 48 h lag) — the `get_job` path treats an expired/absent job identically (404-ish).
- **FR-13 (delete cascade verified).** `DELETE /v1/me` already deletes every `PK=USER#<sub>` item; this
  spec adds a **regression test** seeding one of each new SK (`ACTIVITY#`, `ACHV#`, `LESSONDONE#`,
  `ROADMAPDONE#`, library item with journey state, `PROGRESS` with `version`) and asserting all are
  gone. Book-scoped `BOOK#<id>/ROADMAP` is **not** user-owned (it's shared/catalog data) and is
  intentionally **not** deleted by a user delete — documented.

### 5.2 Non-functional
- **NFR-1 (float-free).** No `float` ever reaches DynamoDB. Rollups and counts are `int`; scores are
  **basis points** `int` (0–10000); structured values (`confirmedMilestones`, `lessonIds`) are a
  DynamoDB string-list or a JSON string. Reads coerce `Decimal`→`int` via the `progress.py` `_to_plain`
  pattern. (Invariant, `CLAUDE.md`.)
- **NFR-2 (atomicity & idempotency).** Day rollups use **atomic `ADD`** (commutative, no lost update);
  achievement/lesson/roadmap-done writes use **conditional `attribute_not_exists`**; progress uses an
  **optimistic-lock `version`** condition. Re-posting any tracking payload (retry, backfill, duplicate)
  changes the result **at most once**.
- **NFR-3 (single table; `MangoFeatures` separate).** Everything new is a new SK shape (or attribute)
  on the **existing** table; the three GSIs are added to it. The analytics **events lake** and
  **`MangoFeatures-<stage>`** stay separate substrates (`docs/DATA_MODEL.md`). No new table.
- **NFR-4 (least privilege).** Only the Lambdas that need the new items get the grant: the
  **activity/progress** Lambda gets table read/write; `grade_fn` stays **table-less** (it only emits an
  event) — preserving `api_stack.py`'s least-privilege posture (`grade_fn` has no table access today).
  The roadmap **worker** already has table read/write (it writes the job) — writing `BOOK#<id>/ROADMAP`
  is the same grant.
- **NFR-5 (offline-first preserved).** First launch (Mock AI, bundled sample, no network/auth) needs
  **none** of this: the on-device engine remains the source of truth offline, and server tracking is a
  no-op without a session (gracefully deferred, never blocking) — exactly as `0014`/`0015` behave.
- **NFR-6 (best-effort, request-safe).** Posting tracking deltas or routing answers to the lake is
  **best-effort**: a failure is enqueued/retried client-side (reusing `0014`'s offline queue pattern)
  and **never** blocks UI or surfaces an error. Server-side, a failed `BOOK#<id>/ROADMAP` cache write
  **never** fails generation (best-effort, like `0023`'s refund/ledger split).
- **NFR-7 (backend style/runtime).** stdlib + boto3 only (no packaging step); `black` (line-length 100)
  + `flake8` (max 120); `pytest` (moto) + `cdk synth -c stage=beta` both pass **offline** (Claude
  monkeypatched, moto mocks AWS).
- **NFR-8 (contract lockstep).** `shared/api/openapi.yaml` ⇄ `ios/.../Services/Networking/DTOs.swift` ⇄
  `backend/src/handlers` stay in sync; new schemas decode **leniently** (absent ints → 0, unknown enum
  → safe default) mirroring `CatalogBook.init(from:)`.
- **NFR-9 (privacy).** The product table stores **no answer text, prompts, or model output** — only
  ids, enums, dates, and scalar counts/scores. Raw answers live in the events lake under the lake's
  existing privacy posture (`0015`: ids/enums/scalars only in `props`; deletion gap documented there).
- **NFR-10 (performance/cost).** Day rollups are O(1) `ADD`s; the leaderboard/rewards/device reads are
  single GSI queries; `LESSONDONE`/`ROADMAPDONE` validation is an O(1) membership check against the
  cached `lessonIds`. No table scans on the request path. `PAY_PER_REQUEST` absorbs the modest extra
  write volume; the three GSIs add write-amplification only for the items their owning specs write.

## 6. Design

### 6.1 Data model (single table — extends `0004`/`docs/DATA_MODEL.md`)
All new items are SK shapes (or attributes) on the **existing** table (`PK`/`SK` strings).
**`<date>` = `YYYY-MM-DD` (user-local day); `<ts>` = ISO-8601 UTC; all numerics `int`.**

| Entity | PK | SK | Key attributes | Write idiom |
|---|---|---|---|---|
| **Daily activity** | `USER#<sub>` | `ACTIVITY#<date>` | `xp:int`, `minutes:int`, `lessons:int`, `activities:int`, `freezesUsed:int`, `source?:str`, `updatedAt` | **atomic `ADD`** (or `SET` for backfill, FR-11/D-3) |
| **Achievement** | `USER#<sub>` | `ACHV#<key>` | `unlockedAt:str` | conditional `attribute_not_exists` |
| **Lesson done** | `USER#<sub>` | `LESSONDONE#<roadmapId>#<lessonId>` | `completedAt:str`, `scoreBp?:int` | conditional `attribute_not_exists`, **validated** vs cached roadmap |
| **Roadmap done** | `USER#<sub>` | `ROADMAPDONE#<roadmapId>` | `completedAt:str` | conditional `attribute_not_exists`, **validated** all-lessons-covered |
| **Library item** *(extended)* | `USER#<sub>` | `BOOK#<bookId>` | + `journeyState:str`, `confirmedMilestones:[str]` | upsert (existing path + new attrs) |
| **Progress** *(extended)* | `USER#<sub>` | `PROGRESS` | + `version:int` | optimistic-lock condition (FR-7) |
| **Roadmap cache** *(populated)* | `BOOK#<bookId>` | `ROADMAP` | `roadmap:str(JSON)`, `lessonIds:[str]`, `promptVersion`, `modelId`, `updatedAt` | best-effort overwrite by worker (FR-5) |
| **Roadmap job** *(+TTL)* | `USER#<sub>` | `ROADMAPJOB#<jobId>` | + `ttlAt:int(epoch s)` | existing put + TTL stamp (FR-12) |

> **Coordination with `0039`** (activity-type framework): `0039` owns
> `USER#<sub>/ACTIVITY#<activityId>` *assignment/state* and `USER#<sub>/SUBMISSION#<activityId>#<id>`
> rows. Note the **SK-prefix discriminator**: this spec's per-day rollup is `ACTIVITY#<date>` (a
> `YYYY-MM-DD`), whereas `0039`'s assignment is `ACTIVITY#<activityId>` (a `act_…` id). They share the
> `ACTIVITY#` prefix but never collide (date vs opaque id); a `begins_with(SK,"ACTIVITY#")` query that
> needs only one must filter on the trailing token shape, **or** — recommended (D-6) — `0039` adopts
> a distinct prefix (`ACTSTATE#<activityId>`) to keep the two cleanly separable. Flagged for the
> `0039` implementer; this spec keeps `ACTIVITY#<date>` for the day rollup (it matches
> `docs/DATA_MODEL.md`).

**GSIs (new in `data_stack.py`) — overloaded, generic keys, written by downstream specs:**

| Index | PK / SK (generic) | First writer | Example PK / SK |
|---|---|---|---|
| `GSI_LEAGUE` | `GSI_LEAGUE_PK` / `GSI_LEAGUE_SK` | `0021` | `LEAGUE#2026-W26#gold#3` / `XP#0000004210#<sub>` |
| `GSI_CATALOG` | `GSI_CATALOG_PK` / `GSI_CATALOG_SK` | `0024` | `REWARD#ACTIVE` / `2026-06-01#rwd_trip` |
| `GSI_DEVICE` | `GSI_DEVICE_PK` / `GSI_DEVICE_SK` | `0025` | `DEVICE#ACTIVE` / `2026-06-28T12:00:00Z#<sub>` |

Zero-pad every numeric sort component (XP to a fixed width) so the lexical GSI sort equals the numeric
sort — the standard leaderboard pattern, and float-free by construction (AWS:
[Overloading GSIs](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/bp-gsi-overloading.html)).
**A GSI sort key cannot be mutated in place** — when an item's GSI sort value changes (e.g. weekly XP
rises), the writer must overwrite the base item's `GSI_*SK` attribute (a normal `UpdateItem` that
re-projects), which `0021`'s `WEEKXP` rollup already does on each ledger write.

### 6.2 Atomic / conditional write recipes (`shared/tracking.py`, new — handlers stay thin)
Mirrors `0023` §6.2 idioms; `progress.py` `_to_plain`/`int`-coercion reused.

**Daily rollup — atomic `ADD` (commutative, no read-modify-write):**
```python
# shared/tracking.py
def add_activity(uid: str, date: str, *, xp=0, minutes=0, lessons=0, activities=0):
    table().update_item(
        Key={"PK": f"USER#{uid}", "SK": f"ACTIVITY#{date}"},
        UpdateExpression=("ADD xp :xp, minutes :min, lessons :les, activities :act "
                          "SET updatedAt = :now"),
        ExpressionAttributeValues={":xp": int(xp), ":min": int(minutes),
                                   ":les": int(lessons), ":act": int(activities),
                                   ":now": _now_iso()},
    )  # ADD creates the item if absent; ints only (float-free)
```

**Backfill day — absolute `SET`, only if not a live-engine row (D-3):**
```python
def set_activity_backfill(uid, date, *, xp, minutes, lessons, activities):
    try:
        table().update_item(
            Key={"PK": f"USER#{uid}", "SK": f"ACTIVITY#{date}"},
            UpdateExpression=("SET xp=:xp, minutes=:m, lessons=:l, activities=:a, "
                              "#src=:src, updatedAt=:now"),
            ConditionExpression="attribute_not_exists(PK) OR #src = :src",
            ExpressionAttributeNames={"#src": "source"},
            ExpressionAttributeValues={":xp": int(xp), ":m": int(minutes), ":l": int(lessons),
                                       ":a": int(activities), ":src": "backfill", ":now": _now_iso()},
        )
    except ConditionalCheckFailed:
        pass   # a real same-day increment already owns this day; don't clobber it
```

**Achievement unlock — idempotent:**
```python
def unlock_achievement(uid, key) -> bool:
    try:
        table().put_item(Item={"PK": f"USER#{uid}", "SK": f"ACHV#{key}", "unlockedAt": _now_iso()},
                         ConditionExpression="attribute_not_exists(PK)")
        return True   # newly unlocked
    except ConditionalCheckFailed:
        return False  # already unlocked — no-op, original unlockedAt preserved
```

**Lesson done — validated + idempotent:**
```python
def mark_lesson_done(uid, roadmap_id, lesson_id, *, score_bp=None) -> bool:
    if lesson_id not in roadmap_lesson_ids(roadmap_id):      # from BOOK#<id>/ROADMAP.lessonIds
        raise InvalidLesson(roadmap_id, lesson_id)           # 400 — cannot fabricate a completion
    item = {"PK": f"USER#{uid}", "SK": f"LESSONDONE#{roadmap_id}#{lesson_id}",
            "completedAt": _now_iso()}
    if score_bp is not None:
        item["scoreBp"] = int(score_bp)
    try:
        table().put_item(Item=item, ConditionExpression="attribute_not_exists(PK)")
        return True
    except ConditionalCheckFailed:
        return False
```

**Progress optimistic lock (FR-7) — extends `progress.py` PUT:**
```python
expected = body.get("version")
expr_kwargs = {}
if expected is not None:
    expr_kwargs = {
        "ConditionExpression": "attribute_not_exists(version) OR version = :v",
        "ExpressionAttributeValues": {":v": int(expected)},
    }
try:
    progress["version"] = int(item_version) + 1     # increment on every successful write
    table().put_item(Item={**_key(uid), **progress}, **expr_kwargs)
except ConditionalCheckFailed:
    return json_response(409, {"error": "version_conflict",
                              "current": _read_progress(uid)})   # client re-pulls + re-merges (0014)
```
(AWS guidance:
[optimistic locking with a version attribute](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/DynamoDBMapper.OptimisticLocking.html);
[handling concurrent updates](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/BestPractices_ImplementingVersionControl.html).)

### 6.3 Populating `BOOK#<id>/ROADMAP` (FR-5)
`roadmap_jobs.mark_complete` (called by the worker and the inline fallback) gains a best-effort
cache write when the job carries a `bookId`:
```python
def mark_complete(uid, job_id, roadmap, *, book_id=None):
    table().update_item(... existing job update ...)              # unchanged
    if book_id:
        try:
            lesson_ids = _flatten_lesson_ids(roadmap)             # ordered [lessonId, …]
            table().put_item(Item={
                "PK": f"BOOK#{book_id}", "SK": "ROADMAP",
                "roadmap": json.dumps(roadmap),                   # JSON string (float-free)
                "lessonIds": lesson_ids,                          # DDB string-list
                "promptVersion": prompts.VERSION, "modelId": agent.MODEL_ID,
                "updatedAt": _now_iso(),
            })
        except Exception:                                          # best-effort: never fail the job
            log.warning("roadmap cache write failed for %s", book_id)
```
- The roadmap JSON the app already builds carries lesson ids (the `Roadmap → Milestone → Lesson` graph;
  iOS `RoadmapModels`); `_flatten_lesson_ids` walks milestones→lessons in order. If lesson ids aren't
  present in the generated JSON, the worker **assigns** stable ids (e.g. `l<milestoneIdx>_<lessonIdx>`)
  before caching **and** returns them to the client so both sides agree (the client persists the
  server-assigned ids; this is the contract `LESSONDONE` depends on) — D-1.
- **Size guard (D-4):** if `len(json.dumps(roadmap))` approaches the 400 KB item limit, write
  `lessonIds` + a `roadmapRef` (S3 key) instead of the inline `roadmap`, deferring the body to the
  `0027`/`0028` S3 layout. v1 inline is fine (current roadmaps are a few KB).
- **Relationship to `0028`:** this spec writes a **per-book** cache as a side effect of one user's
  generation. `0028` makes it a **shared, versioned, single-flight** cache reused across users; this
  spec's write is forward-compatible (same key, `0028` adds `#latest`/`#v<n>` versioning + a lock).

### 6.4 API / contract (add to `shared/api/openapi.yaml`)
Two new paths + extensions to two existing ones. Keep `DTOs.swift` and the handlers in lockstep.

```yaml
  /v1/me/activity:
    post:
      summary: Apply a batch of tracking deltas (daily rollups, achievements, lesson completions)
      requestBody:
        required: true
        content: { application/json: { schema: { $ref: "#/components/schemas/ActivityBatch" } } }
      responses:
        "200": { description: Applied, content: { application/json: { schema: { $ref: "#/components/schemas/ActivityBatchResult" } } } }
        "401": { description: Unauthenticated }
  /v1/roadmaps/{roadmapId}/complete:
    post:
      summary: Report completed lessons; server validates vs the cached roadmap and marks completion
      parameters: [{ name: roadmapId, in: path, required: true, schema: { type: string } }]
      requestBody:
        required: true
        content: { application/json: { schema: { $ref: "#/components/schemas/RoadmapCompleteRequest" } } }
      responses:
        "200": { description: Completion state, content: { application/json: { schema: { $ref: "#/components/schemas/RoadmapCompleteResult" } } } }
        "400": { description: Lesson id not part of this roadmap }
        "404": { description: No cached roadmap for this id }
        "401": { description: Unauthenticated }
```
Extend the existing **`Progress`** schema and **`LibraryItem`** schema, and the **`PUT /v1/me/progress`**
responses (add `409`):
```yaml
    Progress:          # extend
      properties:
        # …existing six fields + updatedAt…
        version: { type: integer, description: "optimistic-lock counter; default 0" }
    LibraryItem:       # extend (per 0008 §6.7)
      properties:
        bookId:   { type: string }
        addedAt:  { type: string, format: date-time }
        journeyState: { type: string, enum: [notStarted, reading, finished] }   # NEW; default notStarted
        confirmedMilestones: { type: array, items: { type: string } }            # NEW; optional
    # new component schemas:
    ActivityBatch:
      type: object
      properties:
        days:
          type: array
          items:
            type: object
            properties:
              date:       { type: string, description: "YYYY-MM-DD (user-local)" }
              xp:         { type: integer }
              minutes:    { type: integer }
              lessons:    { type: integer }
              activities: { type: integer }
              backfill:   { type: boolean, description: "true → absolute SET, not ADD (FR-11)" }
        achievements:
          type: array
          items: { type: object, properties: { key: { type: string }, unlockedAt: { type: string } } }
        lessonsDone:
          type: array
          items:
            type: object
            properties:
              roadmapId: { type: string }
              lessonId:  { type: string }
              scoreBp:   { type: integer, nullable: true }
    ActivityBatchResult:
      type: object
      properties:
        daysApplied:         { type: integer }
        achievementsUnlocked: { type: integer }   # newly (not already) unlocked
        lessonsRecorded:     { type: integer }    # newly recorded
        rejected:            { type: array, items: { type: string } }  # e.g. "lesson m1_l9 not in roadmap"
    RoadmapCompleteRequest:
      type: object
      required: [completedLessonIds]
      properties:
        completedLessonIds: { type: array, items: { type: string } }
    RoadmapCompleteResult:
      type: object
      properties:
        complete:        { type: boolean }   # all lessons covered → ROADMAPDONE written
        lessonsTotal:    { type: integer }
        lessonsComplete: { type: integer }
        completedAt:     { type: string, nullable: true }
```
**openapi ⇄ DTO ⇄ handler sync.** Add Swift mirrors to `DTOs.swift`: `ActivityBatchDTO` /
`ActivityDayDeltaDTO` / `AchievementUnlockDTO` / `LessonDoneDTO` (encode for the push), and
`ActivityBatchResultDTO` / `RoadmapCompleteResultDTO` (decode leniently, absent ints → 0). Extend
`ProgressDTO` (from `0014`) with `version: Int = 0` and add `journeyState`/`confirmedMilestones` to a
`LibraryItemDTO` (the lenient-decode pattern from `0008` §6.7). The `409` body decodes from
`APIError.badStatus(409, body)`.

### 6.5 iOS — services, state (zero third-party deps, reuses `0014`/`0015` plumbing)
- **`TrackingService`** (`ios/Mango/Services/Gamification/TrackingService.swift`, `@Observable`, in
  `AppModel`): batches the day's deltas + new achievement unlocks + lesson completions and posts them
  via `POST /v1/me/activity` (debounced, then flushed on background — exactly like `0014`'s
  `ProgressSyncService`, sharing its **durable offline queue** so a failed push retries on reconnect).
  Gated on `AuthService.isSignedIn` + a real backend; a **no-op** offline / Mock / Direct (no identity
  to attach), so the on-device engine remains authoritative there (NFR-5).
- **Engine hooks (no engine math change).** `GamificationEngine.recordExercise` /
  `recordLessonCompletion` already mutate the local `UserProfile` + `ActivityDay`; add a single
  `onTrackingEvent` closure the engine calls (the engine stays networking-pure, mirroring `0014`'s
  `onProgressChanged`) → `TrackingService.recordDay(delta:)` / `.recordAchievement(key:)` /
  `.recordLessonDone(roadmapId:lessonId:scoreBp:)`. Completing the **last** lesson of a roadmap also
  calls `TrackingService.reportRoadmapComplete(roadmapId:completedLessonIds:)` →
  `POST /v1/roadmaps/{id}/complete` (the `0023` credit-earn + `0021` league count then key off the
  server `ROADMAPDONE` marker).
- **Journey state (FR-6).** When the user changes a book's `JourneyState` or confirms a milestone
  (`0008`), the per-book library item is upserted server-side via the library endpoint (a new
  `PUT /v1/me/library/{bookId}` or the existing `POST` carrying the new attrs) — wired by `0014`'s
  library-sync seam; this spec defines the field, `0008`/`0014` wire the call.
- **Backfill (FR-11).** A one-time `TrackingService.backfillIfNeeded()` (guarded by a sub-scoped
  `UserDefaults` flag) reads local `ActivityDay`/`Achievement`/completed-`Lesson` and posts them with
  `backfill:true`. Runs after `AuthService.restore()`/sign-in, off the main actor, best-effort.
- **Raw answers → lake (FR-8).** Already covered by `0015`'s `AnalyticsService.track(.exerciseGraded(…))`
  at `ExerciseRunnerView.submit()`; this spec only asserts the **product table** stores the scalar
  outcome (via the day rollup + `LESSONDONE`) and the **answer text** goes to the lake, never the table.

### 6.6 Diagrams
```
ENGINE (unchanged math) ── records ──▶ TrackingService (debounced, offline-queued; 0014 plumbing)
   recordExercise/recordLessonCompletion          │
                                                   ├─ POST /v1/me/activity { days[ADD], achv[cond], lessonsDone[cond+validate] }
                                                   └─ last lesson? ─▶ POST /v1/roadmaps/{id}/complete  (validate coverage → ROADMAPDONE)
                                                                                   │
   grade_exercise (table-less) ── exercise_graded event (ids/scalars only) ──▶ /v1/events ──▶ events lake (0015)
                                                                                   │
   roadmap worker ── generate ──▶ ROADMAPJOB#<id> (+ttlAt) ── best-effort ──▶ BOOK#<id>/ROADMAP { roadmap, lessonIds }
                                                                                   ▲
                                            POST /v1/roadmaps/{id}/complete validates lessonIds coverage ┘

DELETE /v1/me ──Query PK=USER#<sub>──▶ batch delete (ACTIVITY#, ACHV#, LESSONDONE#, ROADMAPDONE#, BOOK#, PROGRESS, JOB#)
GSIs pre-provisioned (empty until owners write): GSI_LEAGUE (0021) · GSI_CATALOG (0024) · GSI_DEVICE (0025)
TTL: ttlAt (epoch s) on ROADMAPJOB# (and future ephemera) → DynamoDB auto-expire (≤48h lag; reads ignore expired)
```

## 7. Acceptance criteria
- [ ] **AC-1 (daily rollup is atomic):** two concurrent `add_activity(uid, "2026-06-28", xp=15)` and
  `add_activity(uid, "2026-06-28", xp=40)` yield `ACTIVITY#2026-06-28.xp == 55` (no lost update);
  the item is created on first `ADD`; all values are `int`. → `test_activity_rollup_atomic_add`.
- [ ] **AC-2 (achievement idempotent):** `unlock_achievement(uid,"streak_7")` twice writes the item
  once, returns `True` then `False`, and the second call **does not** change `unlockedAt`. →
  `test_achievement_unlock_idempotent`.
- [ ] **AC-3 (lesson completion validated + idempotent):** with `BOOK#b/ROADMAP.lessonIds=["l1","l2"]`,
  `mark_lesson_done(uid,"b","l1")` succeeds once (no-op on repeat); `mark_lesson_done(uid,"b","l9")`
  raises `InvalidLesson` → the endpoint returns **400** and writes nothing. →
  `test_lesson_done_validated_against_roadmap`, `test_lesson_done_rejects_unknown_lesson`.
- [ ] **AC-4 (roadmap-complete signal):** posting all of a roadmap's lesson ids to
  `POST /v1/roadmaps/{id}/complete` writes `ROADMAPDONE#{id}` once and returns `complete:true`;
  posting a strict subset returns `complete:false` and writes no marker; re-posting the full set is a
  no-op. → `test_roadmap_complete_requires_full_coverage`, `test_roadmap_complete_idempotent`.
- [ ] **AC-5 (roadmap cache populated):** a completed generation for a `bookId` writes
  `BOOK#<id>/ROADMAP` with a JSON `roadmap` + the flat `lessonIds`; a cache-write failure does **not**
  fail the generation/job. → `test_worker_populates_roadmap_cache`, `test_cache_write_best_effort`.
- [ ] **AC-6 (library journey state round-trips):** `POST`/`PUT /v1/me/library` persists
  `journeyState`+`confirmedMilestones`; `GET /v1/me/library` returns them; absent → `journeyState`
  defaults `notStarted`; all values are strings (float-free). → `test_library_journey_state_roundtrip`.
- [ ] **AC-7 (progress optimistic lock):** a `PUT /v1/me/progress` with a **stale** `version` returns
  **409** `version_conflict` carrying the current server progress and **does not** overwrite; a write
  with the matching (or omitted) version succeeds and increments `version`. →
  `test_progress_version_conflict_409`, `test_progress_put_increments_version`,
  `test_progress_put_without_version_backcompat`.
- [ ] **AC-8 (raw answers not in the product table):** `grade_exercise` persists **nothing** to the
  table (still table-less) and the scalar outcome is recorded only via the rollup / `LESSONDONE`;
  answer text never appears in any table item. → `test_grade_exercise_persists_nothing`,
  `test_no_answer_text_in_table_items`.
- [ ] **AC-9 (backfill idempotent, non-clobbering):** posting a `backfill:true` day for `2026-06-20`
  twice yields the same totals (absolute `SET`); a live `ADD` increment for the **same** day made
  after backfill is **not** clobbered by a later backfill of that day. →
  `test_backfill_set_idempotent`, `test_backfill_does_not_clobber_live_increment`.
- [ ] **AC-10 (job TTL):** `create_pending` stamps `ttlAt ≈ now + JOB_TTL_SECONDS` (epoch **seconds**,
  `int`); the table has TTL enabled on `ttlAt`; `get_job` treats an item past `ttlAt` as absent. →
  `test_job_has_ttl`, `test_get_job_ignores_expired`; TTL-enabled asserted in synth (AC-13).
- [ ] **AC-11 (delete cascades new SKs):** seeding one of each new SK + an extended library/progress
  item, `DELETE /v1/me` removes **all** `USER#<sub>` items (incl. `ACTIVITY#`, `ACHV#`, `LESSONDONE#`,
  `ROADMAPDONE#`); `BOOK#<id>/ROADMAP` (not user-owned) is **not** deleted. →
  `test_delete_cascades_tracking_items`, `test_delete_preserves_book_roadmap`.
- [ ] **AC-12 (float-free + Decimal-safe):** every persisted numeric is `int`; a `Decimal` read
  round-trips to `int`; no `float` reaches `put_item`/`update_item` for any new write. →
  `test_tracking_is_float_free` (mirrors `test_progress_coerces_float_to_int`).
- [ ] **AC-13 (GSIs + TTL synthesize):** `data_stack.py` defines `GSI_LEAGUE`, `GSI_CATALOG`,
  `GSI_DEVICE` (generic keys) and TTL on `ttlAt`; `cdk synth -c stage=beta` and `-c stage=prod`
  produce the three GSIs + the TTL spec; least-privilege grants unchanged (`grade_fn` table-less). →
  `test_synth_has_three_gsis_and_ttl`.
- [ ] **AC-14 (contract sync):** `openapi.yaml` defines the two new paths + the `Progress`/`LibraryItem`
  extensions + the `409`; `DTOs.swift` mirrors them and decodes leniently; `cdk synth -c stage=beta`
  passes. → openapi lint + `ActivityBatchDTOTests` (decode/encode round-trip) + synth.
- [ ] **AC-15 (offline-first preserved):** fresh install, Mock AI, no network/auth: the engine records
  locally, `TrackingService` is a **no-op**, no tracking call is made, first journey/activities run
  unchanged. → `MangoTests/TrackingServiceOfflineTests.swift` (short-circuits when `!isSignedIn`).
- [ ] **AC-16 (two-device journey consistency, manual):** device A completes a lesson; device B (same
  account) sees the `LESSONDONE`/journey reflected after a pull. *(Beta e2e, manual.)*

## 8. Test plan
- **Backend (`pytest`, moto — offline; Claude monkeypatched; primary):** new `backend/tests/`:
  - `test_tracking.py` — `add_activity` atomic `ADD` (AC-1), `set_activity_backfill` idempotent +
    non-clobber (AC-9), `unlock_achievement` idempotent (AC-2), `mark_lesson_done` validate + idempotent
    (AC-3), float-free (AC-12), Decimal→int. Uses the `aws` moto fixture + the `_event(...)` helper
    idiom from `test_progress.py`.
  - `test_activity_endpoint.py` — `POST /v1/me/activity` batch applies days/achievements/lessonsDone,
    returns the summary, rejects unknown lessons (AC-3), requires auth in prod/beta (mirrors
    `test_progress_requires_auth_in_prod`).
  - `test_roadmap_complete.py` — coverage gate + idempotent marker (AC-4); 404 when no cached roadmap;
    400 on a foreign lesson id.
  - `test_roadmap_cache.py` — worker/inline populates `BOOK#<id>/ROADMAP` with `lessonIds` (AC-5);
    best-effort on cache-write failure; inline-only book skips the cache.
  - `test_library.py` (extend) — journey-state round-trip + default (AC-6); float-free strings.
  - `test_progress.py` (extend) — `version` increment, 409 on stale, back-compat when omitted (AC-7).
  - `test_grade_exercise.py` (extend) — still persists nothing / table-less (AC-8); event emitted
    (monkeypatch `firehose.put_event`).
  - `test_delete_account.py` (extend) — cascade of all new SKs; preserves `BOOK#<id>/ROADMAP` (AC-11).
  - `test_roadmap_jobs.py` (extend) — `ttlAt` stamped in epoch seconds; `get_job` ignores expired (AC-10).
  - **Synth** — `test_synth.py` asserts the three GSIs + TTL attribute + unchanged least-privilege
    grants (AC-13); `cdk synth -c stage=beta`/`prod` pass.
- **iOS (XCTest):** `ActivityBatchDTOTests` (lenient decode/encode, AC-14); `TrackingServiceOfflineTests`
  (no-op without session, AC-15); a `FakeAPIClient` integration driving `TrackingService` through
  debounce→post, offline-enqueue→replay (reusing `0014`'s queue), and the backfill path.
- **Manual (Beta e2e):** reinstall→sign-in restores the contribution graph + achievements + completed
  lessons (not just XP); two-device journey consistency (AC-16); confirm no answer text in any table
  item (spot-check via console) and that jobs disappear after TTL.
- **Regression:** `make ios-test` + backend `pytest` (existing 29) + `cdk synth ×stages` stay green —
  the generation/grading/gamification graph paths are untouched (we only **record**).

## 9. Rollout & migration
- **Order (each step independently shippable; inert without data/clients):**
  1. `data_stack.py`: add the 3 GSIs + enable TTL on `ttlAt` (pure infra; no behavior change). Deploy
     first so the indexes exist when owners (`0021`/`0024`/`0025`) ship.
  2. `roadmap_jobs`: stamp `ttlAt` on new jobs + populate `BOOK#<id>/ROADMAP` (best-effort). Existing
     jobs without `ttlAt` simply never auto-expire (acceptable; or a one-off backfill stamps them).
  3. `shared/tracking.py` + `POST /v1/me/activity` + `POST /v1/roadmaps/{id}/complete` handlers +
     routes + least-privilege grant + openapi + DTOs.
  4. `progress.py`: add `version` (back-compat: unconditional when the client omits it).
  5. `library.py`: persist/return `journeyState`+`confirmedMilestones`.
  6. iOS `TrackingService` + engine hooks + journey-state upsert, behind `serverTrackingEnabled`
     (default **on** once the AC suite is green; no auth → no-op).
  7. iOS one-time **backfill** on first authenticated launch.
- **Data migration:**
  - **DynamoDB:** purely **additive** — new SKs and new attributes on existing items; no rewrite of
    existing rows. `PROGRESS.version` defaults to 0 (absent → treated as 0); the optimistic-lock
    condition tolerates `attribute_not_exists(version)`. GSIs backfill automatically as items gain the
    `GSI_*` attributes (none until owners write them).
  - **On-device → server (FR-11):** the one-time backfill seeds each existing user's server history
    from local SwiftData, idempotently (days as absolute `SET` w/ `source:"backfill"`,
    achievements/lessons conditional). A user who never signs in keeps everything local (offline-first).
- **Backward compatibility / teardown:** the wire is additive; a client that doesn't send `version`
  still writes progress (unconditional); a stage without the new handlers just doesn't track granularly
  (the aggregate path is unchanged). Flag-off (`serverTrackingEnabled=false`) disables the client
  cleanly. Removing the feature leaves harmless extra items (swept by `DELETE /v1/me`); TTL drains jobs.
- **Sequencing vs other specs:** ship **after** sign-in (`0019`) — granular tracking needs identity
  (like `0014`). Land **before/with** `0023` (needs the `ROADMAPDONE` signal) and `0021` (needs
  `GSI_LEAGUE`); pairs with `0014` (same offline-queue + the `version` it merges against). `0028` later
  upgrades `BOOK#<id>/ROADMAP` to a shared single-flight cache (this write is forward-compatible).

## 10. Risks & open decisions
- **R-1 Double-counting day rollups.** Atomic `ADD` is commutative but a **client retry** of the *same*
  increment would `ADD` twice. *Mitigation:* the live engine pushes a day's **delta once** per logical
  event (the `0014` debounce/collapse pattern guards bursts); the **backfill** path uses absolute `SET`
  (not `ADD`) so re-runs are idempotent (AC-9); if stronger guarantees are needed later, attach a
  per-event id to a `begins_with` de-dupe set. Accept the small risk for v1 (rollups are a contribution
  graph, not money — money/credits go through `0023`'s idempotent ledger, which keys off the
  **validated** `ROADMAPDONE` marker, not the rollup).
- **R-2 `LESSONDONE` validation depends on a populated cache.** If `BOOK#<id>/ROADMAP` wasn't written
  (e.g. an inline-only book, or a pre-rollout roadmap), validation can't find `lessonIds`. *Mitigation:*
  FR-5 writes the cache on every `bookId` generation going forward; for inline-only books, completion is
  recorded against the **client-supplied lesson set echoed by the server at generation** (the roadmap
  the client holds) — or `complete` falls back to "trust the reported set but mark provisional" for
  inline books (D-1 ties lesson ids to the generation response so this is rare). Document that
  credits/leagues only count completions for cached (catalog/imported) roadmaps in v1.
- **R-3 GSI sort key immutability.** A `GSI_LEAGUE_SK` embedding XP can't be edited in place; the owning
  spec must overwrite the projected attribute when XP changes. *Mitigation:* documented in §6.1; `0021`
  already re-writes the `WEEKXP` rollup on each ledger write. Zero-pad widths are fixed up front to avoid
  re-keying.
- **R-4 TTL lag exposes expired items.** DynamoDB can take up to **48 h** to delete expired items, and
  they still appear in reads until then. *Mitigation:* `get_job` (and any reader of TTL'd items) **filters
  on `ttlAt`** and treats expired-but-present as absent (AC-10); never rely on TTL for correctness, only
  for cleanup (AWS:
  [TTL behavior](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/TTL.html)).
- **R-5 Item-size limit on the cached roadmap.** A very large roadmap could approach 400 KB. *Mitigation:*
  D-4 size guard → defer the body to S3, keep `lessonIds` inline. Current roadmaps are a few KB.
- **R-6 Privacy of granular history.** More server-side per-user data = more to protect/erase.
  *Mitigation:* product table holds **no** answer text (NFR-9); raw answers ride the lake under `0015`'s
  posture; `DELETE /v1/me` cascades all new SKs (AC-11); the lake's per-user deletion gap is `0015`/
  `0033`'s tracked follow-up, not introduced here.
- **R-7 Coordination collision with `0039` on the `ACTIVITY#` prefix.** *Mitigation:* D-6 — `0039`
  uses a distinct `ACTSTATE#<activityId>` prefix for assignment/state; this spec keeps `ACTIVITY#<date>`
  for the day rollup (matches `docs/DATA_MODEL.md`). Flagged in §6.1.
- **Decisions needed (with recommendations):**
  - **D-1 (recommended: server assigns + returns stable lesson ids at generation).** Guarantee both
    sides agree on lesson ids so `LESSONDONE`/coverage validation is exact (vs trusting client ids).
  - **D-2 (recommended: optional `version`, unconditional when omitted).** Make the optimistic lock
    opt-in so it lands before `0014`'s client sends a version, without breaking current clients.
  - **D-3 (recommended: backfill via absolute `SET` guarded by `source:"backfill"`).** Avoid the
    double-`ADD` hazard while never clobbering a live same-day increment.
  - **D-4 (recommended: inline roadmap in DDB now; S3 pointer when near 400 KB).** Simple now,
    forward-compatible with `0027`/`0028`.
  - **D-5 (recommended: projection `ALL` on the 3 GSIs for v1).** Simplest; revisit to
    `KEYS_ONLY`/`INCLUDE` if write-amplification cost shows up.
  - **D-6 (recommended: `0039` adopts `ACTSTATE#` prefix).** Keep the two `ACTIVITY#`-family meanings
    cleanly separable.
  - **D-7 (recommended: endpoints — add `POST /v1/me/activity` + `POST /v1/roadmaps/{id}/complete`).**
    Vs folding into `PUT /v1/me/progress`. The dedicated endpoints keep `progress` focused on the
    aggregate (`0014`) and give `0023`/`0021` a clean completion signal.

## 11. Tasks & estimate
1. `data_stack.py`: add `GSI_LEAGUE`/`GSI_CATALOG`/`GSI_DEVICE` (generic keys) + enable TTL on `ttlAt`;
   synth assertions for beta+prod (AC-13). **(S)**
2. `roadmap_jobs.py`: stamp `ttlAt` on new jobs (epoch seconds) + `get_job` ignores expired (AC-10).
   **(S)**
3. `roadmap_jobs.mark_complete` (+ inline fallback): populate `BOOK#<id>/ROADMAP` with `roadmap` +
   flat `lessonIds`, best-effort; `_flatten_lesson_ids` + D-1 stable-id assignment + return ids to the
   client (AC-5). **(M)**
4. `shared/tracking.py`: `add_activity` (`ADD`), `set_activity_backfill` (`SET`+cond),
   `unlock_achievement`, `mark_lesson_done` (validate vs cache), `mark_roadmap_done` (coverage),
   `roadmap_lesson_ids`; float-free helpers; `pytest` (AC-1/2/3/9/12). **(M)**
5. `handlers/activity.py` (`POST /v1/me/activity`) + `handlers/roadmap_complete.py`
   (`POST /v1/roadmaps/{id}/complete`) — thin; `api_stack.py` routes + least-privilege grant
   (table read/write; `grade_fn` stays table-less); `pytest` (AC-3/4/8). **(M)**
6. `progress.py`: add `version` + optimistic-lock condition + 409 + back-compat; openapi `Progress`
   extension; `pytest` (AC-7). **(M)**
7. `library.py`: persist/return `journeyState`+`confirmedMilestones`; openapi `LibraryItem` extension;
   `pytest` (AC-6). **(S)**
8. `delete_account.py`: verify cascade (no code change expected) + regression test for all new SKs +
   `BOOK#<id>/ROADMAP` preserved (AC-11). **(S)**
9. openapi: add the two paths + schemas + `409`; `DTOs.swift` mirrors (`ActivityBatch*`,
   `RoadmapComplete*`, extended `Progress`/`LibraryItem`); `ActivityBatchDTOTests` (AC-14). **(M)**
10. iOS `TrackingService` (`@Observable`) reusing `0014`'s offline queue + engine `onTrackingEvent`
    hooks + `reportRoadmapComplete`; `serverTrackingEnabled` flag (default on); `FakeAPIClient`
    integration + `TrackingServiceOfflineTests` (AC-15). **(M)**
11. iOS one-time **backfill** on first authenticated launch (sub-scoped `UserDefaults` flag),
    best-effort, `backfill:true` (FR-11/AC-9). **(M)**
12. iOS journey-state upsert on `JourneyState`/milestone change (wire into `0008`/`0014` library sync)
    + manual two-device check (AC-16). **(S)**
13. Docs: update `docs/DATA_MODEL.md` (promote `ACTIVITY#`/`ACHV#` from "planned"; add `LESSONDONE#`/
    `ROADMAPDONE#`, the `version`/`ttlAt`/journey-state attrs, the 3 GSIs); update `INDEX.md` row +
    promote to `docs/specs/` on ship. **(S)**

## 12. References
- **Repo (read for accuracy):** `CLAUDE.md` (invariants: float-free, stdlib+boto3, single-table,
  offline-first, contract-in-sync); `working/ARCHITECTURE_REVIEW.md` §2.1 (the design this expands);
  `docs/DATA_MODEL.md` (entity/key layout, the "planned" `ACTIVITY#`/`ACHV#`, the unwritten
  `BOOK#<id>/ROADMAP`, the deletion-cascade contract).
  Backend: `backend/mango_backend/data_stack.py` (table + `GSI1`; where the 3 GSIs + TTL go),
  `backend/src/handlers/{progress,library,reflections,grade_exercise,delete_account,generate_roadmap}.py`,
  `backend/src/shared/roadmap_jobs.py` (job rows; `mark_complete`; TTL + cache-write seam),
  `backend/src/shared/{firehose,response,storage}.py`.
  Contract: `shared/api/openapi.yaml` (`Progress`, `LibraryItem`, roadmap generation 202/poll); iOS:
  `ios/Mango/Services/Networking/DTOs.swift`, `ios/Mango/Services/Gamification/{GamificationEngine,
  StreakCalculator,LevelCurve}.swift`, `ios/Mango/Models/{ActivityDay,UserProfile,RoadmapModels,
  AchievementCatalog}.swift`.
- **Cross-spec:** `working/0014-progress-sync.md` (aggregate sync + the `version` it merges; shared
  offline queue), `working/0008-product-reframe-activity-first.md` (journey state + `LibraryItem`
  delta, §6.7), `working/0021-social-leagues.md` (`GSI_LEAGUE` leaderboard + the awarded-XP ledger that
  consumes `ROADMAPDONE`), `working/0023-payments-and-credits.md` (earn-on-completion keyed off the
  trusted signal, §6.6/D-5; the conditional/atomic idioms in §6.2), `working/0024-rewards-and-coupons.md`
  (`GSI_CATALOG`), `working/0025-notifications.md` (`GSI_DEVICE`),
  `working/0039-activity-type-framework.md` (activity assignment/submission items — `ACTIVITY#`-prefix
  coordination, §6.7), `working/0020-feature-store-personalization.md` (`MangoFeatures` stays separate),
  `working/0015-analytics-events-ios.md` / `docs/specs/0006-data-lake.md` (the events lake that hosts
  raw per-answer history), `working/0027`/`0028` (proposed — generation-artifact store + shared cache
  that supersede the functional `BOOK#<id>/ROADMAP` write here).
- **Research (web) — DynamoDB best practices that ground §6:**
  - GSI **overloading** with generic keys is the recommended single-table pattern; sort keys can't be
    updated in place; zero-pad numeric sort keys for leaderboards —
    https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/bp-gsi-overloading.html
  - Using GSIs (limits, projection choices) —
    https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/GSI.html
  - **TTL** must be a Number attribute in **Unix epoch seconds**; deletes are free (no WCU); expired
    items can linger up to ~48 h so reads must filter them —
    https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/TTL.html
  - **Optimistic locking** via a `version` attribute + condition expression on write —
    https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/DynamoDBMapper.OptimisticLocking.html
  - Best practices for handling **concurrent updates** (version control; atomic `ADD` for counters) —
    https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/BestPractices_ImplementingVersionControl.html
- **Template:** `docs/specs/SPEC_TEMPLATE.md` (12-section structure followed here).
