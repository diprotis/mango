# 0014 — Progress Sync — gamification state across reinstalls & devices

- **Epic:** M5 · **Status:** Draft · **Owner:** unassigned · **Updated:** 2026-06-26
- **Reviewers:** Principal, SD, QA

## 1. Summary
Make a signed-in user's gamification state — `totalXP`, `level`, `currentStreak`,
`longestStreak`, `freezesAvailable`, `lastActiveDay` — survive reinstalls and follow
them across devices, by pushing and pulling it through the **existing**
`GET`/`PUT /v1/me/progress` endpoint (`backend/src/handlers/progress.py`,
`Progress` schema in `shared/api/openapi.yaml`). The contract and the DynamoDB item
(`PK=USER#<sub>`, `SK=PROGRESS`) already exist; this spec adds the iOS sync client, a
**deterministic server-reconciliation merge** so XP is never double-counted, an offline
write queue, and the failure handling that guarantees local progress is never lost. This
is the first feature to depend on the now-built Cognito sign-in (spec 0003) and is the
gate for Social Leagues (Epic M8) — leagues need a trustworthy server XP figure.

## 2. Goals / Non-goals
- **Goals:**
  - Restore full gamification state on a fresh install after sign-in (reinstall → state back).
  - Converge two devices signed into the same account to one consistent state.
  - Sync airplane-mode edits once connectivity returns (durable offline write queue).
  - A merge policy that is **monotonic** for earned progress and **never double-counts XP**.
  - Never lose or regress local progress because of a failed, slow, or partial sync.
  - Keep the app fully usable offline and signed-out (sync is a no-op without a session).
- **Non-goals:**
  - Syncing the library, roadmaps, reflections, or per-`ActivityDay` history (separate epics;
    `ActivityDay` rows stay device-local for now — only the `UserProfile` aggregate syncs).
  - Real-time/live multi-device updates (push, websockets). Sync is poll/event-driven.
  - A server-authoritative XP **ledger** (that arrives with M8 anti-cheat; see §10).
  - Changing the gamification rules themselves (`GamificationEngine`, `LevelCurve`,
    `StreakCalculator` are reused unchanged).

## 3. Background & context
Today all gamification state lives only on-device in the single `UserProfile`
(`ios/Mango/Models/UserProfile.swift`) and `ActivityDay` rows, mutated by
`GamificationEngine` (`ios/Mango/Services/Gamification/GamificationEngine.swift`). A
reinstall wipes it; a second device starts from zero. Losing a hard-won streak to a new
phone is exactly the loss-aversion the streak mechanic exists to *protect*
(`docs/GAMIFICATION.md` §2b), so persistence directly defends retention
(`docs/PRODUCT_ROADMAP.md` item 2).

The server side is already built and offline-tested: `progress.py` GETs/upserts the six
fields plus a server `updatedAt`, coercing every numeric to `int` (the DynamoDB resource
API rejects Python `float` — a repo invariant). `response.user_id` maps the Cognito JWT
`sub` to `USER#<sub>`. What's missing is purely the iOS client glue and the merge logic —
**no new endpoint and no schema change are required.** `APIClient`
(`ios/Mango/Services/Networking/APIClient.swift`) already attaches
`Authorization: Bearer <idToken>` from the live `AuthService` session but currently
exposes only `getJSON`/`postJSON`/`delete` — it has **no `PUT`**, which this spec adds.

## 4. User stories
- As a returning user, I reinstall Mango, sign in, and my XP / level / streak / freezes
  are exactly where I left them, so I don't feel punished for switching phones.
- As a two-device user (iPhone + iPad), I earn XP on one and see it reflected on the other
  after a launch/refresh, with no double-counting and no streak regression.
- As a commuter, I complete a lesson in airplane mode; when I land, my progress syncs up
  without me doing anything.
- As an offline / signed-out user, the app works exactly as before and never blocks on the
  network or nags me to sign in.

## 5. Requirements
- **Functional:**
  - **FR-1** On launch (post-restore) and immediately after a successful sign-in, the app
    **pulls** `GET /v1/me/progress` and reconciles it into the local `UserProfile` (§6 merge).
  - **FR-2** The app **pushes** `PUT /v1/me/progress` (debounced ~5 s) after any change to
    `totalXP`, `currentStreak`, `longestStreak`, `freezesAvailable`, or `lastActiveDay`,
    and an immediate flush on `scenePhase` → `.background`.
  - **FR-3** Every push is preceded by a pull-and-merge so concurrent device edits reconcile
    before the upsert (read-modify-write); the body sent is the **merged** state.
  - **FR-4** Writes that can't reach the server are enqueued in a **durable offline queue**
    and replayed (newest-wins-collapsed to a single pending push) when connectivity/auth returns.
  - **FR-5** Merge is **idempotent and monotonic** for earned progress: replaying the same
    push, or applying server state twice, never changes the result and never lowers
    `totalXP`/`longestStreak`.
  - **FR-6** A failed/timed-out sync **never** mutates local state destructively; the local
    value is preserved and the push re-queued.
  - **FR-7** Sign-out clears the pending queue + last-synced marker (next user starts clean);
    signed-out/unconfigured builds make sync a no-op.
  - **FR-8** `level` is **never trusted from the wire**; after merge it is **recomputed**
    from the merged `totalXP` via `LevelCurve.level(forXP:)` on the client (and the server
    already recomputes-by-storage independently — both must agree, see §6).
- **Non-functional:**
  - **Performance:** a sync round-trip is off the main actor; UI never blocks. Debounce
    coalesces bursts (a 3-exercise lesson = at most one push). Payload is ~150 bytes.
  - **Security/Privacy:** authenticated-only; `Authorization` bearer from `AuthService`;
    no progress sent without a valid session; no tokens or PII logged.
  - **Cost:** at most ~1 PUT per active session-burst + 1 GET per launch; well within the
    single-table + HTTP-API budget. No new infra.
  - **Reliability:** offline queue persisted across cold starts; survives crash mid-flush.
  - **Backward-compat:** the wire shape is unchanged; older app builds that only `PUT`
    naively still interoperate (server reconciliation tolerates them — see §10 R-2).

## 6. Design

### API / contract (unchanged — already in `shared/api/openapi.yaml`)
- `GET /v1/me/progress` → `Progress` (the six fields + server `updatedAt`).
- `PUT /v1/me/progress` body `Progress` → echoes the saved `Progress`.
- `Progress` fields: `totalXP:int`, `level:int`, `currentStreak:int`, `longestStreak:int`,
  `freezesAvailable:int`, `lastActiveDay:date|null` (YYYY-MM-DD), `updatedAt:date-time`.
- **No new routes; no new DynamoDB attributes.** `DEFAULT_PROGRESS` in `progress.py`
  already supplies zeros for a never-synced user.

### Merge / conflict policy — **server-reconciliation, monotonic** (the heart of this spec)
The hard rule: **XP is an accumulated earned total, not a counter to be summed.** Each side
holds its own running `totalXP`; we **reconcile by `max`**, never by addition — adding would
double-count every shared event. Reconciliation is the same pure function on both the
device merge and (recommended, §9) inside the Lambda, so two devices always converge:

Given `local` and `remote` (server) progress, produce `merged`:
1. `merged.totalXP   = max(local.totalXP, remote.totalXP)`  *(monotonic; never sums)*
2. `merged.longestStreak = max(local.longestStreak, remote.longestStreak)`
3. `merged.freezesAvailable = max(local.freezesAvailable, remote.freezesAvailable)`
   *(generous toward the user; a freeze "consumed" on one device isn't punished on the other.
   Acceptable because freezes are cheap, earnable, and white-hat — see §10 R-4.)*
4. **Streak reconciliation by `lastActiveDay`** using the same day-granular rules as
   `StreakCalculator` (`ios/Mango/Services/Gamification/StreakCalculator.swift`):
   - `merged.lastActiveDay = max(local.lastActiveDay, remote.lastActiveDay)` (later calendar day).
   - Let `winner` = the side whose `lastActiveDay == merged.lastActiveDay`
     (ties → the side with the larger `currentStreak`).
   - `gap = days(otherSide.lastActiveDay → merged.lastActiveDay)` evaluated against "today":
     - If both sides share the same `lastActiveDay`: `merged.currentStreak =
       max(local.currentStreak, remote.currentStreak)` (same active day, take the longer run).
     - Else `merged.currentStreak = winner.currentStreak` (the more-recent active day already
       reflects that day's increment; we do **not** add the two streaks).
   - Then apply the **lapse check against the current date** exactly once: feed `merged`
     through the existing `StreakCalculator.register(...)`-style gap logic on next activity —
     i.e. the merge sets the *baseline*, and the normal engine handles "did today break it?"
     This keeps the freeze rules (gap==1 advances, gap==2 with a freeze advances, else reset)
     in one place and avoids re-implementing them.
5. `merged.level = LevelCurve.level(forXP: merged.totalXP)` — **always recomputed, never copied
   from either side's wire value.** (Server stores whatever level it's PUT, but since both the
   client and the recommended server-side reconciliation derive level from the same `totalXP`
   via the same curve, they agree. The float-free `int` rule is naturally satisfied — XP and
   level are ints.)
6. `updatedAt` is server-owned; the client treats it as opaque and stores the server value
   from the last successful GET/PUT as `lastServerUpdatedAt` (used only for telemetry/debug,
   **not** as a merge tiebreaker — `max` on the values themselves is the source of truth, so
   clock skew between devices can't corrupt XP).

**Why `max`, not last-writer-wins:** LWW on `updatedAt` would let a stale device that synced
later silently erase a higher XP earned earlier elsewhere. `max` on each earned field is
conflict-free (a CRDT-style grow-only register) and immune to clock skew — the property the
roadmap calls out ("XP is never double-counted") and the gate-quality leagues need.

### Idempotency
- The merge is a pure function of `(local, remote)`; applying it twice yields the same result
  (max/derive are idempotent), so a retry/replay of the same PUT is safe.
- The offline queue collapses to **at most one pending push** (the latest merged snapshot),
  so replays after a crash can't accumulate.
- No client-generated request id is required because the operation is an idempotent upsert of
  an absolute snapshot, not a delta. (A future ledger-delta API *would* need one — §10 R-2.)

### Data (iOS)
- **Reuse** the existing `UserProfile` aggregate as the local source of truth — **no new
  SwiftData @Model for the synced fields.** Add lightweight sync bookkeeping persisted in
  `UserDefaults` (suite keyed by Cognito `sub`, so device-A/device-B and user-switch don't
  collide), not in SwiftData:
  - `pendingProgressPush: Data?` — JSON of the latest merged `ProgressDTO` awaiting upload.
  - `lastServerUpdatedAt: String?` — last server `updatedAt` seen (debug/telemetry only).
  - `lastSyncAt: Date?` — for a "Last synced …" line on the Account screen.
- DynamoDB item is unchanged: `{PK: USER#<sub>, SK: PROGRESS, totalXP, level, currentStreak,
  longestStreak, freezesAvailable, lastActiveDay, updatedAt}`.

### iOS — services, state, screens
- **New DTO** in `ios/Mango/Services/Networking/DTOs.swift`:
  ```swift
  struct ProgressDTO: Codable, Sendable {
      var totalXP: Int
      var level: Int
      var currentStreak: Int
      var longestStreak: Int
      var freezesAvailable: Int
      var lastActiveDay: String?   // "YYYY-MM-DD"
      var updatedAt: String?
  }
  ```
- **Extend `APIClient`** (`ios/Mango/Services/Networking/APIClient.swift`): add a `.put` case
  to `Method` and a `putJSON(_:body:as:)` verb mirroring `postJSON` (the only structural app
  change to the client; headers/auth path reused verbatim).
- **New `ProgressSyncService`** (`ios/Mango/Services/Gamification/ProgressSyncService.swift`,
  `@Observable`, injected via `AppModel`):
  - `pull()` → GET, `reconcile(local:remote:)`, write back into `UserProfile`, recompute level.
  - `pushDebounced()` → schedule a coalesced flush (~5 s) via a `Task` + timestamp guard.
  - `flushNow()` → pull-merge-PUT immediately (called on background + on queue replay).
  - `enqueue(_:)` / `replayPending()` → durable offline queue (UserDefaults blob) + a
    `NWPathMonitor` (Network.framework, **stdlib/system, no third-party dep**) trigger.
  - All network work `await`s off the main actor; mutations of the `@Model` hop to `@MainActor`.
- **`ProgressSyncMapper`** (pure, unit-tested like `LevelCurve`/`StreakCalculator`): the
  `reconcile(_:_:) -> ProgressDTO` merge from §6 and `UserProfile ⇄ ProgressDTO` mapping,
  including `lastActiveDay` ⇄ `YYYY-MM-DD` via a fixed `ISO8601`/`yyyy-MM-dd` UTC formatter.
- **Trigger points:**
  - `RootView`/`AppModel` startup (after `AuthService.restore()` + `refreshIfNeeded()`): `pull()`.
  - `AuthService.signIn` success: `pull()`.
  - `GamificationEngine.recordExercise`/`recordLessonCompletion` already mutate `UserProfile`;
    add a single `onProgressChanged` hook the engine calls (or observe in the view layer) →
    `pushDebounced()`. The engine stays pure of networking; only a closure is injected.
  - `scenePhase == .background`: `flushNow()`.
- **Account screen** (existing, from spec 0003): show "Last synced <relative time>" and a
  manual "Sync now" affordance; use `Typo`/`Palette`/`Metrics` tokens, no hardcoded values.
- **Failure handling:** any thrown `APIError` during pull/push is swallowed for the user
  (logged non-sensitively); on push failure the merged snapshot is re-enqueued; on pull
  failure the local state is untouched. A `401` triggers `AuthService.refreshIfNeeded()` and
  one retry; persistent `401` leaves local progress intact and silently defers (no nag).

### Diagrams
```
launch ─▶ restore() ─▶ refreshIfNeeded() ─▶ pull(GET) ─▶ reconcile ─▶ write UserProfile ─▶ recompute level
exercise graded ─▶ UserProfile mutated ─▶ onProgressChanged ─▶ pushDebounced(5s)
                                                              └▶ flushNow: pull ─▶ reconcile ─▶ PUT(merged)
offline write ─▶ enqueue(pendingProgressPush) ──(NWPathMonitor: online)──▶ replayPending ─▶ flushNow
background ─▶ flushNow
```

## 7. Acceptance criteria
- [ ] **AC-1 (reinstall restores state):** with state on the server, a fresh install + sign-in
      results in a `UserProfile` whose six fields equal the server's, and `level ==
      LevelCurve.level(forXP: totalXP)`. *(Manual e2e against Beta + unit test of the post-pull write.)*
- [ ] **AC-2 (second device converges):** device A earns XP and syncs; device B (signed into the
      same account) pulls and shows `totalXP == max(A, B)` with **no double-count** and
      `currentStreak` not regressed. *(Mapper unit tests + manual two-simulator check.)*
- [ ] **AC-3 (airplane-mode edits sync later):** edits made offline are persisted to the queue
      and `PUT` exactly once when connectivity returns, with the server reflecting the merged
      result. *(Integration test with a stubbed offline `APIClient` + queue replay; manual.)*
- [ ] **AC-4 (no double-count on repeated sync):** calling `reconcile` / pushing twice with
      unchanged inputs leaves `totalXP` unchanged. *(Mapper idempotency unit test.)*
- [ ] **AC-5 (monotonic):** for any `(local, remote)`, `merged.totalXP >= max(local.totalXP,
      remote.totalXP)` and `merged.longestStreak >= max(...)`. *(Property-style unit tests.)*
- [ ] **AC-6 (never lose local progress):** a forced pull/push failure (thrown `APIError`)
      leaves the `UserProfile` byte-for-byte unchanged and re-queues the push. *(Unit test
      with a failing `APIClient` test double.)*
- [ ] **AC-7 (streak reconciliation):** the documented `lastActiveDay`/gap cases (same-day,
      one-day-apart, two-days-apart-with-freeze, stale) produce the streak the table in §6
      specifies, consistent with `StreakCalculator`. *(Mapper unit tests mirroring
      `StreakCalculator` cases.)*
- [ ] **AC-8 (offline / signed-out unaffected):** with no session, sync is a no-op and the app
      behaves exactly as today. *(Unit test: sync service short-circuits when `!isSignedIn`.)*

## 8. Test plan
- **Unit (automated, primary — pure logic like `LevelCurve`/`StreakCalculator`):**
  `ProgressSyncMapperTests` in `MangoTests/` — reconcile cases (max XP, longest streak,
  freeze max, all streak/gap cases), idempotency, monotonicity, `UserProfile ⇄ ProgressDTO`
  round-trip, `lastActiveDay` date formatting. `ProgressDTO` decode/encode test (matches
  `Progress` schema). `APIClient.putJSON` covered by an existing-style request test.
- **Integration (iOS):** a `FakeAPIClient` driving `ProgressSyncService` through
  pull→merge→push, offline-enqueue→replay, and the failure/never-lose path.
- **Backend:** if the recommended server-side reconciliation (§9, Decision D-1) is adopted,
  add a `pytest` (moto) for `progress.py` covering `max`-merge on PUT and the float-free
  coercion; `cdk synth -c stage=beta` must still pass. If **not** adopted, no backend change
  and existing tests stand.
- **Manual:** Beta e2e — reinstall→sign-in restore (AC-1); two simulators converge (AC-2);
  airplane-mode edit then reconnect (AC-3); confirm "Last synced" updates and no tokens in logs.

## 9. Rollout & migration
- **Stages:** land behind a `progressSyncEnabled` flag (default on once AC suite is green);
  ship to Beta, soak, then Prod. Requires the deployed Cognito authorizer + a signed-in
  session (spec 0003) — no auth, no sync (gracefully no-op).
- **Server reconciliation (Decision D-1, recommended):** move the §6 `reconcile` into
  `progress.py` so the **PUT merges against the stored item** server-side (read-modify-write
  with a `max`-merge), making the server the convergence point even for naive/legacy clients.
  Keep all numerics `int` (float-free invariant). The client merge stays as a fast-path/offline
  convenience; the server is the backstop. If D-1 is deferred, the client-side read-modify-write
  (FR-3) still converges two well-behaved clients.
- **Migration:** none — a never-synced user reads `DEFAULT_PROGRESS` (zeros) and the first push
  seeds the item. First pull on an existing on-device profile reconciles up (server zeros lose
  to local via `max`), so existing users keep their state.
- **Backward-compat / teardown:** wire shape unchanged; flag-off disables the client cleanly;
  removing the feature leaves the harmless `PROGRESS` item in place.

## 10. Risks & open decisions
- **R-1 Double-counting XP (highest risk).** *Mitigation:* `max`-reconciliation (never sum) +
  idempotency tests (AC-4/AC-5). The single most important property in this spec.
- **R-2 Naive/legacy client clobber.** A client that PUTs a raw lower snapshot could regress the
  server. *Mitigation:* adopt server-side `max`-merge (D-1) so the server never accepts a
  regression; until then, the read-modify-write in FR-3 mitigates for current clients.
- **R-3 Streak edge cases / timezone.** Day-granularity must match `StreakCalculator` and the
  user's calendar. *Mitigation:* reuse the exact gap rules; store `lastActiveDay` as a UTC
  `YYYY-MM-DD`; test the same cases `StreakCalculator` tests. *Open:* device-timezone vs UTC for
  the "day" — recommend **device-local start-of-day** (matches the on-device engine) and store
  the resulting calendar date string; document so two devices in different zones reconcile by the
  later local day.
- **R-4 Freeze inflation via multi-device.** `max` on `freezesAvailable` is generous.
  *Mitigation:* acceptable (freezes are white-hat, cheap, earnable); revisit only if abused.
- **R-5 No server XP ledger yet.** Leagues (M8) need a trustworthy XP figure; absolute-snapshot
  sync trusts the client's `totalXP`. *Mitigation:* fine for personal sync; M8 introduces a
  server-validated awarded-XP ledger (see `feature-social-leagues.md` §6 anti-cheat) which this
  spec's `max`-merge is forward-compatible with (the ledger sum becomes the authoritative
  `totalXP` the merge maxes against).
- **Decisions needed:**
  - **D-1 (recommended: yes)** Put the `max`-reconciliation in `progress.py` server-side, not
    just the client?
  - **D-2 (recommended: device-local day)** Define "day" for `lastActiveDay` as device-local
    start-of-day vs UTC.
  - **D-3 (recommended: ~5 s)** Debounce window for pushes.

## 11. Tasks & estimate
1. Add `ProgressDTO` to `DTOs.swift`; confirm it matches the `Progress` schema. **(S)**
2. Add `.put` + `putJSON` to `APIClient`. **(S)**
3. `ProgressSyncMapper` (pure reconcile + `UserProfile ⇄ ProgressDTO` + date formatting). **(M)**
4. `ProgressSyncMapperTests` — reconcile/idempotency/monotonicity/streak/date cases. **(M)**
5. `ProgressSyncService` (pull/pushDebounced/flushNow) + `AppModel` wiring. **(M)**
6. Offline queue (UserDefaults blob, sub-scoped) + `NWPathMonitor` replay. **(M)**
7. Trigger wiring: launch + post-sign-in pull; engine `onProgressChanged` → debounced push;
   `scenePhase` background flush; sign-out clears queue. **(M)**
8. Account-screen "Last synced" + "Sync now" (DesignSystem tokens). **(S)**
9. *(If D-1)* Server-side `max`-merge in `progress.py` + `pytest` (moto) + `cdk synth`. **(M)**
10. iOS integration test (`FakeAPIClient`: pull→merge→push, offline replay, never-lose). **(M)**
11. Manual Beta e2e (reinstall restore, two-device converge, airplane-mode) + flag flip. **(S)**

## 12. References
- `docs/PRODUCT_ROADMAP.md` item 2 (Progress sync); `docs/GAMIFICATION.md` §2a/§2b.
- `backend/src/handlers/progress.py`; `backend/src/shared/response.py` (`user_id` → `USER#<sub>`).
- `shared/api/openapi.yaml` — `Progress` schema, `GET`/`PUT /v1/me/progress`.
- iOS: `Services/Networking/APIClient.swift`, `Services/Networking/DTOs.swift`,
  `Services/Auth/AuthService.swift`, `Models/UserProfile.swift`, `Models/ActivityDay.swift`,
  `Services/Gamification/{GamificationEngine,StreakCalculator,LevelCurve}.swift`.
- Spec `docs/specs/0003-authentication.md` (sign-in dependency); `docs/specs/0004-data-model-and-lake.md`
  (single-table patterns). Gate for `working/feature-social-leagues.md` (Epic M8).
