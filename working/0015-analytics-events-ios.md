# 0015 — iOS analytics events — client emission to /v1/events

- **Epic:** M9 · **Status:** Draft · **Owner:** unassigned · **Updated:** 2026-06-26
- **Reviewers:** Principal, SD, QA

## 1. Summary
The backend analytics substrate is live — `POST /v1/events` lands records on a
Kinesis Firehose delivery stream (`mango-events-<stage>`) that GZIPs them into the
analytics S3 lake under `events/dt=YYYY-MM-DD/`, queryable in Athena via the Glue
`mango_<stage>.events` table (see spec
[`0006-data-lake.md`](../docs/specs/0006-data-lake.md)). But **the iOS app emits
nothing** — there is no `AnalyticsService`, and no call site posts to `/v1/events`.
This spec adds a privacy-first, typed `AnalyticsService` on iOS: a closed event
taxonomy, a batching + offline queue that flushes to `/v1/events` with the user's
bearer token, a hard opt-out, and wiring at the key product moments (onboarding,
import, roadmap, lesson, exercise, gamification). The outcome is a populated event
lake we can query for activation, retention, and funnel analysis.

## 2. Goals / Non-goals
- **Goals:**
  - A single `AnalyticsService` (in `AppModel`) with a **typed, closed event
    taxonomy** — callers emit an enum case, never a free-form string.
  - **Batching + an offline queue** (persisted) that POSTs newline/array batches to
    `/v1/events`, survives app restarts, and **flushes on reconnect / foreground**.
  - **Privacy by construction:** only ids + enums + small scalar counts in `props`;
    **never** book text, reflection text, prompts, answers, emails, or tokens. A
    user-facing **opt-out** that suppresses all emission. **No ATT prompt, no IDFA,
    no third-party SDK.**
  - **Best-effort, request-safe:** analytics never blocks UI, never surfaces an
    error, never retries hard enough to matter; mirrors the backend's
    `put_event`-returns-`False` contract.
  - Per-event **`props` schemas** documented and consistent with the Glue `events`
    table (one event = one JSON line; `props` is a nested JSON object the SerDe reads
    as a string and Athena queries via `json_extract`).
  - Wiring at: app open, onboarding complete, book imported, roadmap created, lesson
    completed, exercise graded, streak extended, streak frozen, achievement unlocked.
- **Non-goals:**
  - Dashboards / Athena saved queries / QuickSight (separate analytics-reporting
    work).
  - Server-side schema validation or an event allow-list on the backend (the handler
    stays permissive; the **client** is the allow-list).
  - Consuming events for personalization (that is the sibling spec
    `feature-feature-store-personalization`).
  - Crash/perf telemetry (MetricKit, os_signpost), screen-view auto-capture, A/B
    experimentation, or a consent banner beyond the single opt-out toggle.
  - Emission from the **Mock/offline** path (no backend, no identity → nothing to
    send). Direct-Claude path also does not emit (no Cognito identity; see §10).

## 3. Background & context
- The backend half shipped in spec [`0006-data-lake.md`](../docs/specs/0006-data-lake.md):
  `backend/src/handlers/events.py` validates `{type, props?}` and calls
  `backend/src/shared/firehose.py` → `put_event(type, user_id, props)`, which writes
  `{"ts","type","userId","props": "<json string>"}` + `\n` to the stream named by
  `EVENTS_STREAM_NAME`. The Glue table columns are `ts, type, userId, props` (all
  `string`); see `backend/mango_backend/analytics_stack.py` and
  [`../docs/DATA_MODEL.md`](../docs/DATA_MODEL.md) §"Data lake & feature store".
- The contract already exists: `POST /v1/events` in
  [`shared/api/openapi.yaml`](../shared/api/openapi.yaml) (request
  `{ type: string (required), props: object }`, `200` Accepted, secured by
  `bearerAuth`).
- iOS has the plumbing to call it: `APIClient`
  (`ios/Mango/Services/Networking/APIClient.swift`) already sets `x-mango-user` and
  `Authorization: Bearer <idToken>`; `AppModel.apiClient()`
  (`ios/Mango/App/AppModel.swift`) returns a configured client (or `nil` when
  offline/Mock). `AppSettings`
  (`ios/Mango/Services/Persistence/AppSettings.swift`) is the home for a new
  `analyticsEnabled` toggle and already persists to `UserDefaults`; `deviceUserId` is
  a stable per-install UUID. Auth/identity is `AuthService`
  (`ios/Mango/Services/Auth/AuthService.swift`).
- **Why now:** the lake is provisioned and costing nothing useful while empty. M9
  ("close the analytics loop") needs the producer to validate ingestion end-to-end
  and to unlock personalization.

## 4. User stories
- As a **product analyst**, I want lesson/exercise/streak events in Athena, so that I
  can measure D1/D7 retention, onboarding completion, and lesson-funnel drop-off.
- As a **user**, I want a clear toggle to turn analytics off, so that I control
  whether my activity is collected — and I want to know no reading content or
  personal text ever leaves my device as analytics.
- As an **iOS engineer**, I want to instrument a new event with one typed call
  (`analytics.track(.lessonCompleted(...))`), so that adding telemetry is trivial and
  can't accidentally leak free-form/PII data.
- As an **on-call engineer**, I want analytics to be strictly best-effort, so that a
  Firehose/API outage or airplane mode never degrades the app.

## 5. Requirements
**Functional**
- **FR-1 (taxonomy):** `AnalyticsService` exposes a closed `AnalyticsEvent` enum.
  v1 cases and their `type` wire strings (snake_case, matching the backend `type`
  column):
  `app_opened`, `onboarding_completed`, `book_imported`, `roadmap_created`,
  `lesson_completed`, `exercise_graded`, `streak_extended`, `streak_frozen`,
  `achievement_unlocked`. Unknown/free-form types are **not representable**.
- **FR-2 (props):** each case carries a typed payload serialized to a `props`
  dictionary of **only** ids and enums and small integer/bool/double scalars (exact
  schemas in §6). Plus common props attached to every event (`appVersion`, `build`,
  `platform`, `os`, `locale`, `sessionId`, `env`). No string longer than an id/enum
  is permitted (lint rule + code review; see §6 "Encoding").
- **FR-3 (track):** `track(_ event: AnalyticsEvent)` is non-throwing, returns
  immediately (enqueue + return), and is safe to call from `@MainActor` and from
  background contexts.
- **FR-4 (batching):** events are buffered and flushed when **any** of: buffer
  reaches `maxBatch` (default 20), `flushInterval` elapses (default 30 s),
  app goes to background, or `flush()` is called explicitly. A flush POSTs each event
  in the batch to `/v1/events` (see §6 transport options A/B).
- **FR-5 (offline queue):** unsent events are **persisted** (survive process death)
  and re-attempted on next launch, on network-reachable, and on foreground. Delivered
  events are removed from the queue only after a 2xx.
- **FR-6 (opt-out):** when `AppSettings.analyticsEnabled == false`, `track` is a
  no-op **and** the persisted queue is purged. Default value is decided in §10
  (recommend **opt-in for first build → opt-out/on-by-default once the privacy label
  is approved**); ship behind a single Settings toggle either way.
- **FR-7 (identity gating):** emission only happens when a real backend is selected
  **and** a Cognito session exists (`AppModel.apiClient() != nil` and
  `auth.session != nil`). In Mock/offline or Direct-Claude (no JWT) the service
  **drops** events (does not queue them) — there is no authenticated endpoint to send
  to. `userId` is **not** set client-side; the backend derives it from the JWT `sub`.
- **FR-8 (wiring):** the listed events are emitted at the correct call sites
  (§6 "Wiring points") exactly once per logical occurrence (no double-counting on
  view re-render).
- **FR-9 (rate-limit / sampling):** a per-process cap of `maxEventsPerMinute`
  (default 120) drops excess events (counted as `dropped` locally, not sent);
  optional per-type sampling rate (default 1.0 = keep all) is configurable in code
  for high-volume types. No high-volume types exist in v1; the knob is for future
  `reader_page_turn`-style events.

**Non-functional**
- **NFR-1 (privacy):** `props` is restricted to non-sensitive product signals.
  Forbidden, enforced by construction (typed payloads only) + a review checklist:
  book/reflection/prompt/answer **text**, titles*, emails, names, tokens, precise
  geolocation. (*Book/journey **titles** are PII-adjacent free text → use `bookId` /
  `roadmapId` instead, never the title string.) No IDFA; **no `ATTrackingManager`
  call**; `NSUserTrackingUsageDescription` is intentionally absent.
- **NFR-2 (resilience):** zero analytics code path may throw to a caller, block the
  main thread, or change UI behavior. A flush failure leaves events queued (bounded);
  a malformed response is swallowed. Hard cap the queue at `maxQueue` (default 1000);
  oldest events are dropped past the cap.
- **NFR-3 (performance):** enqueue is O(1) and off the main thread for I/O; batch
  encode/flush runs on a background `Task`/actor. Persistence writes are debounced.
- **NFR-4 (cost/efficiency):** batching keeps request count low; each event is a tiny
  JSON body. No background-fetch budget is used; flush opportunistically on foreground
  and natural network calls.
- **NFR-5 (no new deps):** pure Foundation/SwiftData/`Network` framework only — **no
  third-party iOS dependencies** (CLAUDE.md invariant).
- **NFR-6 (testability):** queue, batching, sampling, opt-out gating, and `props`
  encoding are unit-testable without a live network (inject a fake transport +
  in-memory store).

## 6. Design
**API / contract** — no contract change; uses the existing
[`shared/api/openapi.yaml`](../shared/api/openapi.yaml) `POST /v1/events`:
`{ "type": "<snake_case>", "props": { … } }` → `200 { }` (backend returns
`{"accepted": true}`; client ignores the body). The backend stamps `ts` and
`userId`; the client sends only `type` + `props`.

**Transport — decision (recommend A):**
- **Option A (one event per request, batched concurrently):** for each event in a
  flushed batch, `POST /v1/events` with `{type, props}`. Matches the current handler
  exactly (it accepts a single event); no backend change. Slightly more requests.
- **Option B (array endpoint):** add `POST /v1/events:batch` accepting `{events:[…]}`.
  Fewer requests, but needs a new handler + contract + tests. **Deferred** (tracked as
  a follow-up if request volume warrants).
  Recommendation: **A** for v1 — keep the backend untouched; rely on client batching
  to bound flush frequency, and bound concurrency (e.g. send a batch with a small
  `TaskGroup`, max 4 in flight).

**iOS — new files (placed under `ios/Mango/Services/Analytics/`; picked up
automatically by the Xcode 16 file-system-synchronized group — do not edit
`project.pbxproj`):**
- `AnalyticsEvent.swift` — the closed `enum AnalyticsEvent` + typed payloads; each
  case computes `wireType: String` and `props: [String: AnalyticsValue]`.
  `AnalyticsValue` is a small `Codable` scalar union (`.string/.int/.double/.bool`)
  so encoding can't smuggle arbitrary nested objects/strings.
- `AnalyticsService.swift` — `@Observable final class AnalyticsService`. Public API:
  `track(_:)`, `flush() async`, `setEnabled(_:)`, `onForeground()`,
  `onBackground()`. Owns an internal **serial actor** (`AnalyticsQueueActor`) that
  holds the in-memory ring + drives persistence + flush. Depends on an
  `AnalyticsTransport` protocol (prod impl wraps `AppModel.apiClient()`), an
  `AnalyticsStore` protocol (persistence), a `clock`, and a `reachability` source
  (`NWPathMonitor`).
- `AnalyticsStore.swift` — persistence behind a protocol. **Decision (recommend a
  file buffer):** a single append-mostly JSON file in Application Support
  (`analytics-queue.json`), rewritten on dequeue, is simpler and avoids polluting the
  SwiftData store / the single `UserProfile` model. Alternative: a SwiftData
  `@Model QueuedEvent`. Recommend the **file buffer** (smaller surface, no schema
  migration, trivially purgeable on opt-out). Store on disk holds
  `{wireType, propsJSON, enqueuedAt, attempts}` — note **no userId** is persisted.
- `AnalyticsValue.swift` — the scalar union + `Encodable` conformance and a
  `props([String: AnalyticsValue]) -> [String: Any]`/`Data` helper used by the
  transport.

**Common props (attached to every event):**

| key | type | source |
|---|---|---|
| `appVersion` | string | `CFBundleShortVersionString` |
| `build` | string | `CFBundleVersion` |
| `platform` | string | `"ios"` |
| `os` | string | `UIDevice.current.systemVersion` (major.minor only) |
| `locale` | string | `Locale.current.identifier` (region-coarse) |
| `sessionId` | string | random UUID minted on app launch (process-scoped; **not** persisted, not the deviceUserId) |
| `env` | string | `settings.apiEnvironment.rawValue` (e.g. `beta`/`prod`/`personal`) |

**Per-event `props` schemas (v1):** (all keys optional unless noted; values are ids,
enums, or small scalars — no free text)

| `type` | props |
|---|---|
| `app_opened` | `{ coldStart: bool, signedIn: bool }` |
| `onboarding_completed` | `{ goalsCount: int, interestsCount: int, readingLevel: string(enum casual|focused|deep), dailyGoalUnits: int }` |
| `book_imported` | `{ source: string(enum url|text|gutenberg|pdf|catalog), wordCount: int, estimatedMinutes: int, bookId: string? }` |
| `roadmap_created` | `{ bookId: string?, milestoneCount: int, lessonCount: int, aiMode: string(enum remote|direct|mock) }` |
| `lesson_completed` | `{ bookId: string?, lessonIndex: int, milestoneIndex: int, exerciseCount: int, minutesEstimated: int }` |
| `exercise_graded` | `{ kind: string(enum quiz|reflection|application), correct: bool?, score: double(0–1), xpAwarded: int }` |
| `streak_extended` | `{ current: int, longest: int }` |
| `streak_frozen` | `{ current: int, freezesRemaining: int }` |
| `achievement_unlocked` | `{ key: string(enum, AchievementCatalog key) }` |

**Encoding (the privacy guardrail):** `props` values are `AnalyticsValue` scalars
only. There is **no** code path that puts a `Book.title`, reflection/answer text, a
JWT, or an email into `props` — those types are never passed into a payload
initializer. A unit test asserts the encoded `props` of every case contains no key
named in a forbidden-key denylist and no string value exceeding `maxIdLength` (e.g.
64) except known enum values. `props` is serialized to a JSON **object** in the
request body (the backend re-serializes it to a JSON string for the `props` column).

**Wiring points (emit exactly once):**
- `app_opened` → `RootView`/`AppModel` on `ScenePhase.active` cold start
  (`ios/Mango/App/`).
- `onboarding_completed` → `OnboardingFlow.swift`
  (`ios/Mango/Features/Onboarding/OnboardingFlow.swift`) at the final "start"
  action, after the profile is saved.
- `book_imported` → `ConnectorService` completion / the Library import handler when a
  `ParsedBook` is added (Features/Library + `ios/Mango/Services/Content/`).
- `roadmap_created` → wherever a `RoadmapDTO` is first materialized into a journey
  (Features/Journey), reading milestone/lesson counts from the DTO and `aiMode` from
  `settings`.
- `lesson_completed` → `GamificationEngine.recordLessonCompletion(...)` caller in
  `LessonView.swift` (`ios/Mango/Features/Lesson/LessonView.swift`), once per lesson.
- `exercise_graded` → `ExerciseRunnerView.swift` /
  `GamificationEngine.recordExercise(...)` caller, mapping the `GradeResultDTO` /
  `Exercise.kind`.
- `streak_extended` / `streak_frozen` → derived from
  `GamificationEngine.recordExercise`'s `GamificationOutcome` (compare streak
  before/after; `usedFreeze` → `streak_frozen`, otherwise an advance →
  `streak_extended`). See `ios/Mango/Services/Gamification/GamificationEngine.swift`.
- `achievement_unlocked` → for each `Achievement` in
  `GamificationOutcome.newlyUnlocked` (and `recordLessonCompletion`'s return), emit
  one event with the `key`.

**Lifecycle / flush triggers:** `AnalyticsService` observes `ScenePhase`
(active→`onForeground()`+flush opportunistically; background→`onBackground()`+flush)
and `NWPathMonitor` (`.satisfied` → flush). `AppModel` owns the instance and injects
it; a thin `.environment`/accessor exposes `analytics` to features.

**Diagram (client path):**
```
view/event site → analytics.track(.case(payload))
   → AnalyticsQueueActor.enqueue (ring + file buffer)         [O(1), returns]
   → flush trigger (size | timer | background | reconnect)
       → AnalyticsTransport.send(batch)  ── if enabled && apiClient != nil && signedIn
           → for each: APIClient.postJSON("/v1/events", {type, props})  (≤4 concurrent)
           → on 2xx: remove from buffer; else: keep (bounded), retry later
   (disabled OR not signed-in/Mock → drop, purge buffer on opt-out)
                                                  backend: events.py → firehose.put_event → S3 lake
```

## 7. Acceptance criteria
- [ ] **AC-1** `track(.case)` is non-throwing, returns synchronously, and enqueues
      without touching the network on the calling thread. *(unit:
      `AnalyticsServiceTests.test_track_enqueues_and_returns`)*
- [ ] **AC-2** A flush sends one `POST /v1/events` per queued event with body
      `{type, props}` where `type` is the case's snake_case wire string and `props`
      matches the §6 schema (verified against a fake transport capturing requests).
      *(unit: `test_flush_posts_each_event_with_expected_props`)*
- [ ] **AC-3** Events are buffered and flushed on size (`maxBatch`), interval
      (`flushInterval`), and background transition. *(unit:
      `test_flush_triggers_size_interval_background`)*
- [ ] **AC-4** **Offline → online:** events enqueued while the transport fails/offline
      persist across a simulated relaunch and are delivered after reachability becomes
      satisfied; delivered events are removed only after a 2xx. *(unit:
      `test_offline_persist_then_flush_on_reconnect`)*
- [ ] **AC-5** **Opt-out:** with `analyticsEnabled == false`, `track` is a no-op and
      any persisted queue is purged; flipping it back on resumes emission. *(unit:
      `test_optout_suppresses_and_purges`)*
- [ ] **AC-6** **Identity gating:** with no `apiClient` (Mock) or no session
      (Direct-Claude), events are dropped (not queued), and no request is attempted.
      *(unit: `test_drops_when_unauthenticated`)*
- [ ] **AC-7** **Privacy guardrail:** the encoded `props` of every `AnalyticsEvent`
      case contains no forbidden key and no over-length string value; no case
      initializer accepts book/reflection/answer text. *(unit:
      `test_props_contain_no_pii_or_freetext`)*
- [ ] **AC-8** **Rate-limit:** beyond `maxEventsPerMinute`, excess events are dropped
      and counted, never sent. *(unit: `test_rate_limit_drops_excess`)*
- [ ] **AC-9** **End-to-end (manual, beta):** instrumented flows produce objects under
      `s3://<analytics>/events/dt=YYYY-MM-DD/`, and an Athena query
      `SELECT type, COUNT(*) FROM mango_beta.events WHERE dt = '<today>' GROUP BY type`
      returns the expected `type`s with non-zero counts.
- [ ] **AC-10** **No tracking prompt (manual):** launching the app never shows an ATT
      prompt; `NSUserTrackingUsageDescription` is absent from Info.plist; no IDFA API
      is referenced (grep + `nm`/symbol check).

## 8. Test plan
- **Unit (XCTest, `MangoTests/AnalyticsServiceTests.swift` + `AnalyticsEventTests.swift`):**
  AC-1…AC-8 with a `FakeTransport` (records requests, can be told to fail/succeed), an
  in-memory `AnalyticsStore`, an injectable `clock`, and a controllable reachability
  signal. Pure-logic coverage is preferred per CLAUDE.md (mirror LevelCurve/
  StreakCalculator style). Add a `props` snapshot test per event case.
- **Integration (manual / TestFlight on beta):** AC-9, AC-10 — sign in, run
  onboarding → import → roadmap → a lesson, background the app, confirm S3 objects +
  Athena counts; confirm streak/achievement events appear; confirm no ATT prompt.
- **Regression:** existing `make ios-test` stays green (no changes to
  GamificationEngine semantics; only added emit calls at call sites).
- **What's automated vs manual:** queue/batching/opt-out/privacy/rate-limit are
  automated; actual S3/Athena delivery and the ATT-absence check are manual
  (require a deployed stage + device).

## 9. Rollout & migration
- **Additive, no migration:** new files + a new `analyticsEnabled` setting (defaults
  per §10) + emit calls. No DB/schema change; no contract change.
- **Staged enablement:** land behind the Settings toggle; dogfood on **beta** first
  (verify AC-9). Keep a compile-time/`AppConfig` kill-switch
  (`analyticsHardDisabled`) so a bad build can ship with emission fully off without a
  code change to call sites.
- **Backward compatibility:** older app versions simply don't emit; the lake tolerates
  new `type`s (schema-on-read). New event types are added by extending the enum +
  documenting the `props` row here — no backend deploy required.
- **Privacy prerequisite:** keep `props` to the §6 schemas until the App Privacy label
  (`feature-app-store-prep`) reflects "Usage Data – not linked / not used for
  tracking"; do not add sensitive props before the event-lake erasure follow-up in
  spec 0006 §9 lands.
- **Teardown:** opt-out purges the local queue; a future per-user event-lake erasure
  (spec 0006 follow-up) covers server-side deletion. `DELETE /v1/me` does **not** yet
  purge events (documented gap).

## 10. Risks & open decisions
- **Decision — transport shape:** one-event-per-request (A) vs a batch endpoint (B).
  *Recommend A* (no backend change); revisit if request volume is high.
- **Decision — persistence:** file buffer vs SwiftData `@Model`. *Recommend file
  buffer* (purgeable, no migration, keeps the single-`UserProfile` store clean).
- **Decision — default opt state:** opt-in vs on-by-default(opt-out). *Recommend
  ship opt-in for the first reviewed build, then flip to on-by-default once the
  privacy label is approved and an in-app disclosure exists.* Either way one toggle in
  Settings; the choice must match the App Store privacy label
  (`feature-app-store-prep`).
- **Risk — accidental PII in `props`.** *Mitigation:* typed payloads + `AnalyticsValue`
  scalar union + denylist unit test (AC-7) + code-review checklist; never pass
  title/text into a payload.
- **Risk — Direct-Claude users emit nothing** (no Cognito identity). *Accepted* for
  v1; revisit if/when Direct-Claude carries an identity.
- **Risk — double-counting** on SwiftUI re-render. *Mitigation:* emit from
  imperative mutation sites (engine callers / completion handlers), not from
  `body`/`onAppear` of re-entrant views; idempotency guarded by the same
  `completedAt`/outcome that gates the gamification write.
- **Risk — queue growth offline.** *Mitigation:* `maxQueue` cap with oldest-drop +
  `attempts` cap.
- **Risk — clock skew** for `enqueuedAt`/sampling. *Accepted;* `ts` is authoritative
  and stamped server-side.

## 11. Tasks & estimate
1. `AnalyticsEvent` + `AnalyticsValue` (closed enum, typed payloads, wire mapping,
   common props) (**M**).
2. `AnalyticsStore` file buffer (append/dequeue/purge, bounded) + protocol (**M**).
3. `AnalyticsService` actor: enqueue, batching/flush triggers, rate-limit, opt-out &
   identity gating, `NWPathMonitor` + `ScenePhase` hooks (**L**).
4. `AnalyticsTransport` prod impl over `AppModel.apiClient()` + `/v1/events`
   (bounded-concurrency batch send) (**S**).
5. Add `analyticsEnabled` (+ optional `analyticsHardDisabled` in `AppConfig`) to
   `AppSettings` and a Settings toggle with privacy copy (**S**).
6. Inject `analytics` into `AppModel` + environment; wire all 9 call sites (**M**).
7. Unit tests AC-1…AC-8 (fake transport, in-memory store, injectable clock) (**M**).
8. Manual beta verification AC-9/AC-10 + a short runbook note (**S**).
9. Docs: this spec → promote to `docs/specs/NNNN-…`; note the new `type`s in
   [`../docs/DATA_MODEL.md`](../docs/DATA_MODEL.md) (**S**).

## 12. References
- Backend: `backend/src/handlers/events.py`, `backend/src/shared/firehose.py`,
  `backend/mango_backend/analytics_stack.py`, `backend/mango_backend/api_stack.py`
  (`/v1/events` route, `events_fn`).
- Contract: [`shared/api/openapi.yaml`](../shared/api/openapi.yaml) `POST /v1/events`.
- iOS: `ios/Mango/App/AppModel.swift`,
  `ios/Mango/Services/Networking/APIClient.swift`,
  `ios/Mango/Services/Persistence/AppSettings.swift`,
  `ios/Mango/Services/Auth/AuthService.swift`,
  `ios/Mango/Services/Gamification/GamificationEngine.swift`,
  `ios/Mango/Features/Onboarding/OnboardingFlow.swift`,
  `ios/Mango/Features/Lesson/LessonView.swift`,
  `ios/Mango/Features/Lesson/ExerciseRunnerView.swift`.
- Specs/docs: [`0006-data-lake.md`](../docs/specs/0006-data-lake.md),
  [`../docs/DATA_MODEL.md`](../docs/DATA_MODEL.md) §"Data lake & feature store",
  [`SPEC_TEMPLATE.md`](../docs/specs/SPEC_TEMPLATE.md).
- Sibling specs: `feature-feature-store-personalization.md`,
  `feature-app-store-prep.md`.
