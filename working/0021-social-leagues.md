# 0021 — Social Leagues — weekly XP leagues, friends & buddies

- **Epic:** M8 · **Status:** Draft · **Owner:** unassigned · **Updated:** 2026-06-26
- **Reviewers:** Principal, SD, QA

## 1. Summary
Add the **Relatedness** pillar of Self-Determination Theory to Mango with an opt-in social
layer: weekly XP **leagues** (tiered, with gentle promotion/relegation), **friends** (mutual,
request-based) with friend streaks, and **reading buddies** (a 1:1 accountability pairing).
The server becomes the source of truth for the XP that ranks people, so this requires new
backend access patterns, endpoints, and **anti-cheat** — clients can never self-report
arbitrary XP. Everything is **opt-in**, ships a **non-competitive mode**, and has **no public
shaming** (demotion is private and gentle), per `docs/GAMIFICATION.md` §2h and the roadmap's
ethical guardrails. It builds on Cognito sign-in (spec 0003) and Progress Sync (Epic M5,
`working/feature-progress-sync.md`), and is phased **friends → leagues → buddies**.

## 2. Goals / Non-goals
- **Goals:**
  - A weekly XP league a user is bucketed into, with a leaderboard of ~20–30 peers and
    promotion/relegation at week close.
  - Mutual friends via request/accept; a friends list; friend streaks (consecutive days both
    active).
  - 1:1 reading buddies for accountability (later phase).
  - Server-authoritative weekly XP, validated against an **awarded-XP ledger** so ranks can't
    be gamed by a hacked client.
  - Strong privacy + safety: opt-in, display-name/handle (not email), block & report,
    non-competitive mode, gentle/private demotion.
- **Non-goals:**
  - A full social graph / follower model, DMs/chat, or public profiles.
  - Real-time live leaderboards (periodic refresh is fine; no websockets in v1).
  - Cross-platform (Android/web) social — iOS-only for now.
  - Monetized or pay-to-win league mechanics (explicitly banned by the manifesto).
  - Importing contacts / address book in v1 (friend-by-handle / invite link only).

## 3. Background & context
`docs/GAMIFICATION.md` §2h scopes social as **Phase 2 (needs backend)**: "Weekly XP leagues,
friend streaks, reading buddies… Relatedness (SDT) + social comparison drove large engagement
lifts at Duolingo," guard-railed as "Opt-in, with a non-competitive mode. No public shaming;
demotion is private and gentle." The roadmap (item 3) sequences it **after** auth and sync
precisely because it needs "server-side leaderboards, identity, and anti-cheat."

Today the backend is a single DynamoDB table (`PK`/`SK` + `GSI1`), HTTP API v2 + Lambda
(py3.12, stdlib+boto3 only, no DynamoDB `float`), Cognito (JWT authorizer; `response.user_id`
→ `USER#<sub>`), S3, Bedrock. Progress today is a per-user aggregate (`USER#<sub>/PROGRESS`)
that the client can PUT — **not yet trustworthy enough to rank strangers by**, which is the
core problem this spec solves with a ledger.

## 4. User stories
- As a user, I opt into social, pick a public **handle**, and join this week's league.
- As a user, I see a weekly leaderboard of ~25 peers and where I stand, refreshed through the
  week, and at week's end I'm promoted/held/relegated *privately*.
- As a competition-averse user, I turn on **non-competitive mode** and see only my own progress
  and encouraging copy — never a rank or anyone below me.
- As a user, I send a friend request by handle (or invite link), accept incoming ones, see my
  friends, and keep a **friend streak** going with a buddy.
- As a user who feels harassed, I **block** and **report** someone and never see them again.
- As any user, I can leave social entirely and my handle/league membership disappears.

## 5. Requirements
- **Functional:**
  - **FR-1** Opt-in: a user is not in any league or discoverable until they enable social and
    set a handle (unique, validated, non-PII).
  - **FR-2** `GET /v1/leagues/me` returns the caller's current-week league id, tier, their
    weekly XP, and their rank (or, in non-competitive mode, rank omitted).
  - **FR-3** `GET /v1/leagues/{id}/leaderboard` returns the ranked membership (handle, weekly
    XP, rank, tier) for a league the caller belongs to.
  - **FR-4** Weekly bucketing: at the **week boundary (Mon 00:00 UTC)** a new league period
    begins; users are assigned to a league of their tier (~25 members), filling new leagues as
    needed.
  - **FR-5** Promotion/relegation at week close: top *N* promote a tier, bottom *M* relegate
    (never below the lowest tier), middle hold — applied to the **next** week's assignment.
  - **FR-6** Weekly XP is the **sum of server-validated awarded-XP ledger entries within the
    week window** for that user — **never** a client-reported number.
  - **FR-7** Friends: `POST /v1/friends/requests` (by handle), accept/decline, `GET /v1/friends`
    (mutual only), remove a friend; friend streak = consecutive UTC days both were active
    (derived from ledger activity).
  - **FR-8** `POST /v1/friends/{id}/block` and `POST /v1/reports` (report a handle with a
    reason); blocked users never appear in each other's leaderboards/lists and can't friend.
  - **FR-9** Non-competitive mode: a per-user setting that hides ranks/positions everywhere and
    swaps competitive copy for self-referential encouragement.
  - **FR-10** Leaving social removes the handle, league membership, friends, and discoverability;
    `DELETE /v1/me` (spec 0003/0004) also cascades all social items.
- **Non-functional:**
  - **Security/anti-cheat:** the server alone computes weekly XP from the ledger; XP deltas are
    written **only** by trusted server paths (grading + sync reconciliation, §6), never accepted
    verbatim from a `PUT`. Per-user write-rate/anomaly caps; least-privilege IAM
    (`api_stack.py` keeps grants minimal).
  - **Privacy:** display handle only — never email or Cognito `sub` over the wire to peers;
    opt-in discoverability; block/report; GDPR-style erase via `DELETE /v1/me`.
  - **Safety:** no public shaming; demotion copy is private and gentle; harassment surfaces
    (block/report) are first-class, not afterthoughts.
  - **Performance/cost:** leaderboard reads are a single `GSI1` query (≤30 items); weekly
    rollover is a scheduled batch; stay within single-table + HTTP-API budget (watch hot
    partitions — §10 R-3).
  - **Accessibility:** rank/medal states have text equivalents; non-competitive mode is a
    one-tap, reversible toggle.

## 6. Design

### Phasing
- **Phase A — Friends** (smallest, proves identity/handles/block-report): handles,
  requests/accept, friends list, block/report. No leagues yet.
- **Phase B — Leagues** (the engagement core): weekly bucketing, leaderboard, promotion/
  relegation, the awarded-XP ledger + weekly aggregation, non-competitive mode.
- **Phase C — Reading buddies** (1:1 accountability): pair two friends, shared buddy streak +
  a light shared goal; reuses friends + ledger.

### API / contract (new — add to `shared/api/openapi.yaml`)
All routes are JWT-authorized (Cognito authorizer; `response.user_id` → `USER#<sub>`).
- `GET  /v1/social/me` → `{ enabled, handle, nonCompetitive, blockedCount }` (social profile).
- `PUT  /v1/social/me` → set `{ handle, enabled, nonCompetitive }` (handle uniqueness enforced).
- `GET  /v1/leagues/me` → `{ leagueId, weekId, tier, weeklyXP, rank|null, size }`.
- `GET  /v1/leagues/{id}/leaderboard` → `{ weekId, tier, entries: [{ handle, weeklyXP, rank }] }`
  (caller must be a member; ranks omitted for the caller if they're non-competitive — peers
  still ranked, the caller just doesn't get a "you're #k below them" framing).
- `POST /v1/friends/requests` body `{ handle }` → `{ requestId, status: pending }`.
- `POST /v1/friends/requests/{id}` body `{ action: accept|decline }` → updated status.
- `GET  /v1/friends` → `{ friends: [{ handle, friendStreak, lastActiveDay }], incoming: [...],
  outgoing: [...] }`.
- `DELETE /v1/friends/{handle}` → removes the mutual friendship.
- `POST /v1/friends/{handle}/block` → blocks (also drops any friendship/requests).
- `POST /v1/reports` body `{ handle, reason }` → `{ reported: true }` (queued for review).
- `POST /v1/buddies` / `GET /v1/buddies` *(Phase C)* → propose/list a 1:1 buddy pairing.
Keep these in lockstep with `DTOs.swift` and the handlers (CLAUDE.md contract invariant).

### Data — new single-table access patterns (single table, `PK`/`SK` + `GSI1`)
Identity & social profile:
- `PK=USER#<sub>  SK=SOCIAL`        → `{ handle, enabled, nonCompetitive }`.
- `PK=HANDLE#<handle>  SK=OWNER`    → `{ sub }` (uniqueness + handle→user lookup; conditional
  `PutItem(attribute_not_exists)` reserves a handle atomically).

League membership & ranking (the GSI does the leaderboard sort):
- `PK=LEAGUE#<weekId>#<tier>#<leagueNo>  SK=MEMBER#<sub>` → `{ handle, weeklyXP, joinedAt }`.
- **GSI1 for ranking:** `GSI1PK = LEAGUE#<weekId>#<tier>#<leagueNo>`,
  `GSI1SK = XP#<zeroPaddedWeeklyXP>#<sub>` → a single `Query(ScanIndexForward=False, Limit=30)`
  returns the leaderboard already sorted by weekly XP (zero-pad XP to fixed width so string sort
  == numeric sort; all ints — float-free invariant honored).
- `PK=USER#<sub>  SK=LEAGUE#<weekId>` → `{ leagueId, tier, leagueNo }` (fast "which league am I
  in this week").

Awarded-XP ledger (source of truth for weekly XP & anti-cheat):
- `PK=USER#<sub>  SK=XPLEDGER#<isoTimestamp>#<eventId>` → `{ amount, source, weekId }`, written
  **only** by trusted server paths:
  1. `grade_exercise` (existing Bedrock-graded path) emits the awarded XP it computed.
  2. Progress-sync reconciliation (M5): the ledger sum becomes the authoritative `totalXP` the
     `max`-merge maxes against — so sync and leagues agree and the client can't inflate either.
  - Weekly XP = `Query` of `USER#<sub>` ledger entries where `weekId == currentWeek`, summed
    server-side. (Maintain a per-week rollup item `PK=USER#<sub> SK=WEEKXP#<weekId>` updated on
    each ledger write via an atomic `ADD`, so reads are O(1) and the GSI XP stays current.)

Friends / blocks / reports:
- `PK=USER#<sub>  SK=FRIEND#<otherSub>`   → `{ handle, status: pending|accepted, dir: out|in }`
  (mirrored rows for both users keep each side's list a single `Query`).
- `PK=USER#<sub>  SK=BLOCK#<otherSub>`    → `{ at }`.
- `PK=REPORT#<id>  SK=META`               → `{ reporterSub, targetHandle, reason, at }`.
- *(Phase C)* `PK=BUDDY#<pairId>  SK=META` + `PK=USER#<sub> SK=BUDDY#<pairId>`.

### Weekly bucketing, promotion/relegation
- **weekId** = ISO week key `YYYY-Www`, boundary **Mon 00:00 UTC** (documented; matches the
  ledger `weekId` stamp).
- **Assignment:** on first qualifying activity in a new week (or via a scheduled rollover
  Lambda on EventBridge, Mon 00:05 UTC), place the user into an open league of their carried
  tier (`USER#<sub> SK=TIER` holds current tier, default lowest). Fill leagues to ~25 before
  opening a new `leagueNo`.
- **Tiers:** e.g. Bronze → Silver → Gold → Sapphire → Ruby (5 tiers; tune later). Promotion =
  top 5, relegation = bottom 5, applied to **next** week's `TIER`. Never relegate below Bronze;
  never promote above Ruby.
- **Rollover Lambda** reads each closed league via GSI1, computes promote/hold/relegate, writes
  next-week `TIER`, and (gently, privately) prepares the result the client shows on next open.
  Idempotent (keyed by `weekId`), stdlib+boto3 only.

### Anti-cheat (the load-bearing requirement)
- **Clients cannot self-report ranking XP.** No social endpoint accepts a weekly-XP value. The
  only XP that counts is in the server-written ledger, populated by `grade_exercise` and the
  sync reconciler — paths the client can't forge because grading runs server-side (Bedrock) and
  the sync merge is monotonic/validated.
- **Validation against the ledger:** weekly XP is recomputed/aggregated from ledger rows; a
  client PUTting a wild `totalXP` (M5) can at most raise its own *aggregate* via `max`, but
  **league XP ignores the aggregate entirely** and uses the ledger sum — so a hacked aggregate
  doesn't move ranks.
- **Rate/anomaly caps:** per-user ledger write rate and per-event XP ceilings (sourced from the
  known exercise XP table — quiz 15 / reflection 25 / application 40, see `Models/Enums.swift`)
  reject implausible deltas; flagged users are shadow-frozen from leaderboards pending review.
- **Least-privilege IAM:** the leaderboard-read Lambda gets `Query` on the table/GSI only; the
  ledger-write path is the only one with `PutItem`/`UpdateItem` on `XPLEDGER`/`WEEKXP`
  (mirrors `api_stack.py` least-privilege, e.g. grade Lambda having no table access today).

### Privacy & safety
- Peers see **handle only**; `sub`/email never cross to other users. Discoverability is opt-in
  (FR-1). Block is symmetric and final-in-effect; report is logged for human review. Demotion
  is shown privately on the user's own screen with gentle copy ("New week, fresh start"), never
  broadcast. Non-competitive mode (FR-9) hides all comparative framing.

### iOS — screens, state, services (zero third-party deps, DesignSystem tokens)
- **New feature module** `ios/Mango/Features/Social/` (Xcode 16 file-system-synchronized — no
  `project.pbxproj` editing): `LeagueView` (leaderboard list with the user's row highlighted via
  `Palette.accent`; medal/tier chips), `FriendsView` (list + request inbox), `SocialOnboarding`
  (handle pick + opt-in + non-competitive toggle), `BuddyView` *(Phase C)*. A new `Route` case
  + `.mangoDestinations()` entries.
- **New DTOs** in `Services/Networking/DTOs.swift` for each response above; new `APIClient`
  verbs reuse the existing auth header path (and the `.put` added in M5).
- **`SocialService`** (`@Observable`, in `AppModel`): wraps the endpoints; polls
  `GET /v1/leagues/me` + leaderboard on appear / pull-to-refresh (no websockets). Gated on
  `AuthService.isSignedIn` and the opt-in flag; a no-op offline (shows a friendly "connect to
  join" state, never blocks the rest of the app).
- **Profile** gains a "Social" entry; **non-competitive mode** lives in Settings/AppSettings and
  is honored by the views (hide rank, swap copy). All spacing/type/color from `Metrics`/`Typo`/
  `Palette`.

### Diagrams
```
weekly XP rank source:  grade_exercise ─▶ XPLEDGER row (amount, weekId) ─▶ WEEKXP rollup (ADD)
                                                                          └▶ GSI1 (XP#padded) ─▶ leaderboard Query(Limit=30)
rollover (EventBridge Mon 00:05 UTC): for each league → top5 promote / bottom5 relegate → next-week TIER
friend request: POST /v1/friends/requests{handle} → mirrored FRIEND# rows (out/in) → accept → both accepted
safety: block → drop friendship + hide both ways;  report → REPORT# item for review
```

## 7. Acceptance criteria
- [ ] **AC-1 (opt-in gate):** a user with social disabled appears in no leaderboard and is not
      discoverable; enabling + setting a unique handle joins them to the current week's league.
      *(pytest on the handle-reserve conditional + membership write; manual.)*
- [ ] **AC-2 (leaderboard correctness):** `GET /v1/leagues/{id}/leaderboard` returns members
      sorted by weekly XP via the GSI, ≤30 entries, with correct ranks. *(pytest with moto
      seeding ledger/GSI rows; integration.)*
- [ ] **AC-3 (anti-cheat):** a client that PUTs an inflated aggregate `totalXP` does **not**
      change its league rank — rank reflects only ledger-sourced weekly XP. *(pytest: inflate
      aggregate, assert leaderboard XP unchanged; this is the headline test.)*
- [ ] **AC-4 (XP only from trusted paths):** no social/league endpoint writes or accepts a
      weekly-XP value; ledger rows are written solely by `grade_exercise`/sync. *(Code + pytest
      asserting the social handlers have no XP-write path.)*
- [ ] **AC-5 (promotion/relegation):** given a closed league, the rollover assigns top-5 up,
      bottom-5 down (clamped at tier bounds), middle hold, into next week. *(pytest of the pure
      rollover ranking function — unit-testable like `LevelCurve`.)*
- [ ] **AC-6 (friends mutual + streak):** request→accept yields a mutual friendship on both
      sides; friend streak counts consecutive UTC days both active. *(pytest of mirrored rows +
      a pure friend-streak function.)*
- [ ] **AC-7 (block/report):** blocking removes the friendship and hides both users from each
      other's leaderboards/lists; report writes a `REPORT#` item. *(pytest; manual.)*
- [ ] **AC-8 (non-competitive mode):** with the toggle on, no rank/position is shown anywhere
      and demotion copy stays gentle/private. *(iOS view test/manual.)*
- [ ] **AC-9 (erase cascades):** `DELETE /v1/me` removes handle, league membership, friends,
      blocks, and ledger social-visibility. *(pytest of the delete cascade — extends 0004.)*

## 8. Test plan
- **Backend (pytest, moto — offline; primary):** handle uniqueness (conditional put),
  membership writes, GSI-sorted leaderboard, weekly-XP aggregation from ledger, the pure
  promotion/relegation function, friend mirror rows + streak, block/report, delete cascade,
  and the anti-cheat assertion (inflated aggregate ≠ rank change). `cdk synth -c stage=beta`
  must pass for the new routes/GSI usage; keep all numerics `int`.
- **iOS:** unit tests for any pure client-side logic (e.g. leaderboard row view-model, friend
  streak formatting); a `FakeAPIClient` integration for `SocialService` flows; manual on Beta
  for the end-to-end opt-in → join → friend → block path and non-competitive mode.
- **Manual/operational:** two accounts on Beta — friend each other, both earn XP, verify ranks
  and friend streak; trigger a (test) rollover and confirm gentle private demotion copy.

## 9. Rollout & migration
- **Phased flags:** `socialFriendsEnabled` (Phase A) → `socialLeaguesEnabled` (Phase B) →
  `socialBuddiesEnabled` (Phase C), default off; enable on Beta per phase, soak, then Prod.
- **Dependencies:** requires sign-in (0003) and benefits from sync (M5) for a trustworthy
  ledger-backed `totalXP`; gate the UI entry on a live session.
- **Backfill:** the ledger starts empty; the first week of leagues simply has lower weekly XP
  for everyone (no historical backfill needed). Existing users opt in fresh.
- **Backward-compat / teardown:** new routes are additive; the existing `Progress` endpoint is
  untouched. Disabling a phase flag hides its UI and stops its writes; social items can be
  swept by the `DELETE /v1/me` cascade.

## 10. Risks & open decisions
- **R-1 Cheating (headline).** A hacked client tries to top the leaderboard. *Mitigation:*
  server-only ledger XP, rate/anomaly caps, shadow-freeze, least-privilege IAM (AC-3/AC-4).
- **R-2 Harassment / safety.** Social invites abuse. *Mitigation:* opt-in, handle-only (no PII),
  block/report first-class, no public shaming, gentle private demotion, human report review;
  add a code-of-conduct gate at opt-in.
- **R-3 Hot partitions / cost.** A popular league partition or the rollover batch could hot-spot.
  *Mitigation:* cap league size ~25–30, shard by `leagueNo`, zero-padded GSI XP, O(1) `WEEKXP`
  rollup to avoid scatter reads, scheduled (not request-path) rollover; monitor RCU/WCU and HTTP
  cost. *Open:* exact tier sizes/thresholds.
- **R-4 Engagement-vs-ethics tension.** Leagues are a strong (potentially compulsive) lever.
  *Mitigation:* non-competitive mode, no shaming, celebrate consistency not volume, and instrument
  opt-out/disable rate as a coercion alarm (`docs/GAMIFICATION.md` §5/§6).
- **R-5 Timezone fairness.** A UTC week boundary advantages some zones. *Mitigation:* document
  Mon 00:00 UTC; reconsider per-region buckets only if data shows unfairness.
- **Decisions needed:**
  - **D-1 (recommended: ledger-as-truth)** Confirm weekly XP = ledger sum, never the aggregate.
  - **D-2 (recommended: 5 tiers / top-5 / bottom-5 / size ~25)** Tier count + promo thresholds.
  - **D-3 (recommended: scheduled EventBridge rollover)** Rollover via schedule vs lazy-on-read.
  - **D-4 (recommended: handle-only, invite link; no contacts in v1)** Friend-discovery method.

## 11. Tasks & estimate
1. OpenAPI additions for all new routes + matching `DTOs.swift`. **(M)**
2. *(Phase A)* Handle reserve (`HANDLE#`) + `PUT /v1/social/me` + `GET /v1/social/me` handler +
   pytest. **(M)**
3. *(Phase A)* Friends mirror rows + requests/accept/decline/list + pure friend-streak fn +
   pytest. **(M)**
4. *(Phase A)* Block + report handlers + pytest; wire `DELETE /v1/me` cascade (with 0004). **(M)**
5. *(Phase A)* iOS `Features/Social/FriendsView` + `SocialOnboarding` + `SocialService` +
   `Route`. **(M)**
6. *(Phase B)* Awarded-XP **ledger** writes from `grade_exercise` + `WEEKXP` rollup; wire sync
   reconciler to ledger sum (with M5). **(L)**
7. *(Phase B)* League membership + GSI1 ranking + `GET /v1/leagues/me` + `/leaderboard` handlers +
   pytest (GSI sort, aggregation, anti-cheat AC-3). **(L)**
8. *(Phase B)* Weekly bucketing + EventBridge **rollover** Lambda + pure promotion/relegation fn +
   pytest (AC-5); `cdk synth ×stages`. **(L)**
9. *(Phase B)* iOS `LeagueView` (leaderboard, tier/medal chips, self-row highlight) +
   non-competitive mode honoring (DesignSystem tokens). **(M)**
10. *(Phase C)* Reading buddies: pairing + buddy streak + `BuddyView`. **(M)**
11. Anti-cheat rate/anomaly caps + shadow-freeze + least-privilege IAM in `api_stack.py` +
    pytest. **(M)**
12. Manual Beta e2e per phase (friend → league → buddy, block/report, non-competitive). **(M)**

## 12. References
- `docs/PRODUCT_ROADMAP.md` item 3 (Social leagues — phase 2); `docs/GAMIFICATION.md` §2h
  (social, guardrails), §1 (SDT Relatedness), §5/§6 (metrics, ethics manifesto).
- `backend/src/handlers/` (`grade_exercise`, `progress.py`), `backend/src/shared/response.py`
  (`user_id` → `USER#<sub>`); `backend/mango_backend/api_stack.py` (least-privilege IAM);
  single-table `PK`/`SK` + `GSI1` patterns from `docs/specs/0004-data-model-and-lake.md`.
- `shared/api/openapi.yaml` (extend); `ios/Mango/Models/Enums.swift` (`ExerciseKind.baseXP`
  ceilings); `ios/Mango/Services/Auth/AuthService.swift`.
- Depends on `docs/specs/0003-authentication.md` (sign-in) and
  `working/feature-progress-sync.md` (Epic M5 — ledger-backed trustworthy XP).
