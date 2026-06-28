# 0016 — Insight Review — daily ~60-second spaced-repetition review

- **Epic:** M6 · **Status:** Draft · **Owner:** unassigned · **Updated:** 2026-06-26
- **Reviewers:** Principal, SD, QA

## 1. Summary
Add a daily ~60-second **Insight Review**: a small spaced-repetition flashcard set drawn from
the user's completed lessons — missed quiz items and key ideas (reading summaries / saved
reflections) — where review intervals **expand on correct recall** and contract on a lapse.
Retrieval practice beats re-reading for long-term retention (`docs/GAMIFICATION.md` §4, §1
"retrieval practice / spacing"), and a light daily review **keeps the streak alive on a busy
day** — turning the loss-aversion mechanic into a learning win rather than a chore
(`docs/PRODUCT_ROADMAP.md` item 4). The scheduler is a **pure, exhaustively unit-testable
SM-2-lite** function in the spirit of `LevelCurve`/`StreakCalculator`, and review **feeds the
daily goal, streak, and XP without double-awarding the original lesson's XP**. v1 is fully
on-device (offline-capable); optional backend sync of due cards is a future add.

## 2. Goals / Non-goals
- **Goals:**
  - Generate `ReviewCard`s from completed lessons: missed quiz items + key ideas (and saved
    reflections as light recall prompts).
  - A pure SM-2-lite scheduler: per-card `ease`, `interval`, `dueDate`, `lapses`; correct →
    interval grows, lapse → interval resets and ease drops (floored).
  - A daily review session UI (one card at a time, ~60 s) using DesignSystem tokens.
  - Reviewing counts toward the **daily goal** and can **keep the streak alive**, awarding a
    small, separate review XP — **never** re-awarding the source lesson's XP.
  - Fully offline; deterministic; no network or key required.
- **Non-goals:**
  - A full Anki-grade algorithm (SM-2+/FSRS), per-card sub-decks, or manual card authoring.
  - AI-generated cards in v1 (cards come from existing lesson content; Bedrock generation is a
    future option).
  - Backend persistence/sync of cards in v1 (designed-for, not built — §6/§9).
  - Changing existing lesson XP values or the gamification curves.

## 3. Background & context
`docs/GAMIFICATION.md` §4 already specifies the feature: "**Spaced 'Insight Review':** a daily
60-second flashcard set drawn from past chapters; interval expands on correct recall. Keeps the
streak alive on a busy day," and §1 ties it to the testing effect and spacing research. The
retention-loop design (§3) places "first spaced review of yesterday's insight" on Day 1.

The app already has the raw material on-device (SwiftData): completed `Lesson`s with
`readingSummary`, `Exercise`s carrying `kind`, `prompt`, `options`, `answerIndex`, and the
user's `chosenIndex`/`score` (so we know which quiz items were **missed**), plus reflections.
Gamification is centralized: `GamificationEngine` mutates the single `UserProfile` and the
per-day `ActivityDay` (`lessonsCompleted`, `xpEarned`, `exercisesCompleted`), advances the
streak via the pure `StreakCalculator`, and derives level via `LevelCurve`. Insight Review
plugs into exactly these seams.

## Pivot impact (see 0008)
`0008-product-reframe-activity-first.md` removes the in-app Reader and reframes Mango as an
activities-first product (users read on their own; Mango runs the active-learning loop). Insight
Review is **reinforced, not broken** by this: its `ReviewCard`s are generated from **completed
activities** — missed quiz items, the lesson's `readingSummary` recap, and saved reflections — all
of which already exist on-device **independent of any in-app reading**. The factory hooks
`GamificationEngine.recordLessonCompletion` (the activity-completion seam, not a reading signal), so
nothing here depends on the deleted Reader or on `Book.fullText`/`readProgress` (which `0008`
removes). The "key idea" card draws from `Lesson.readingSummary` — a generated recap/orientation,
**not** book body text — so it stays valid post-pivot. Net effect: review simply becomes one of the
several "engaging activities" the reframed product is built around; no `ReviewCard`/scheduler change
is required by `0008`.

## 4. User stories
- As a daily learner, I open Mango and do a ~60-second review of past ideas before anything
  else, reinforcing what I learned.
- As a busy user, on a day I have no time for a full lesson, completing the quick review **keeps
  my streak alive** and closes (part of) my daily goal.
- As a learner who got a quiz wrong, that idea **comes back** in review until I reliably recall
  it, then shows up less often.
- As an offline user, review works with no connection and feels instant and deterministic.

## 5. Requirements
- **Functional:**
  - **FR-1** When a lesson is completed, generate `ReviewCard`s: one per **missed** quiz item
    (graded incorrect), plus one "key idea" recall card per lesson (from `readingSummary`), and
    optionally one per saved reflection — de-duplicated, idempotent (re-completion doesn't
    duplicate cards).
  - **FR-2** Each card has SM-2-lite state: `ease` (default 2.3, floor 1.3), `interval` (days,
    starts at 1), `dueDate`, `lapses`, `reps`, `lastReviewedAt`, and a stable `sourceRef`.
  - **FR-3** A review session surfaces cards with `dueDate <= today`, capped (default 10, ≈60 s),
    oldest-due first; the user self-grades each (Again / Hard / Good / Easy → score 0–3).
  - **FR-4** The pure scheduler maps `(card, grade, today) → updatedCard`: a correct grade
    multiplies `interval` by `ease` (Hard dampened, Easy boosted) and nudges `ease`; a lapse
    (Again) resets `interval` to 1, increments `lapses`, and drops `ease` by 0.2 (floored 1.3).
  - **FR-5** Completing a review session **records activity**: it advances the streak via the
    **existing** `StreakCalculator` path and counts toward the **daily goal** ring, exactly like
    a tiny lesson — so a review-only day keeps the streak.
  - **FR-6** Review awards a small **separate** XP (`reviewXP`, default ~5/card capped per day),
    tracked distinctly; it **must not** re-award the source lesson/exercise XP (no
    double-counting against `totalXP`).
  - **FR-7** If there are no due cards, the review entry shows a calm "all caught up" state and
    can still let the user opt to keep their streak via a normal lesson (no forced busywork).
  - **FR-8** A daily reminder (existing single-notification budget) may point at the review when
    it's the lightest way to keep a streak — **no** extra notifications beyond the ~1/day cap.
- **Non-functional:**
  - **Performance:** card selection is a single indexed SwiftData `@Query`/`FetchDescriptor`
    on `dueDate`; the scheduler is O(1) per card; session opens instantly.
  - **Offline/deterministic:** no network; same inputs → same schedule (testable).
  - **Ethics:** keep it ~60 s and *stop* (no endless decks); "all caught up" celebrates and
    ends; reviewing is white-hat reinforcement, never a compulsion loop (`docs/GAMIFICATION.md`
    §6).
  - **Accessibility:** large tap targets for the 4 grades; Dynamic Type via `Typo`; tints from
    `Palette`.

## 6. Design

### Data (iOS — new SwiftData `@Model`, picked up automatically by Xcode 16 sync groups)
`ios/Mango/Models/ReviewCard.swift`:
```swift
@Model
final class ReviewCard {
    @Attribute(.unique) var id: String      // stable, derived from sourceRef (dedupe)
    var kindRaw: String                     // "quiz" | "idea" | "reflection"
    var front: String                       // prompt / question
    var back: String                        // answer / key idea / reflection echo
    var sourceRef: String                   // e.g. "lesson:<id>" / "exercise:<id>"
    // SM-2-lite scheduler state
    var ease: Double                        // default 2.3, floor 1.3
    var interval: Int                       // days, starts 1
    var dueDate: Date                       // start-of-day; selection key
    var reps: Int                           // successful reps in a row
    var lapses: Int
    var lastReviewedAt: Date?
    var createdAt: Date
}
```
- `sourceRef`-derived `id` makes generation **idempotent** (re-completing a lesson upserts, not
  duplicates). `ReviewCardKind` enum (`quiz`/`idea`/`reflection`) added to `Models/Enums.swift`
  with `Palette` tints, mirroring `ExerciseKind`.
- Note: `interval`/`reps`/`lapses` are `Int` and `ease` is on-device `Double` — only relevant to
  the float-free rule **if** future backend sync (below) serializes them; sync would store `ease`
  as a string or scaled `int` to honor the DynamoDB-no-float invariant.

### Scheduler — pure SM-2-lite (`Services/Gamification/ReviewScheduler.swift`, unit-tested like `LevelCurve`)
A free function with **no SwiftData dependency** so it can be tested exhaustively:
```swift
enum ReviewGrade: Int { case again = 0, hard = 1, good = 2, easy = 3 }

enum ReviewScheduler {
    static let minimumEase = 1.3
    static let defaultEase = 2.3
    /// Pure: given a card's scheduler fields and a grade on `today`, return the next fields.
    static func schedule(ease: Double, interval: Int, reps: Int, lapses: Int,
                         grade: ReviewGrade, today: Date, calendar: Calendar = .current)
        -> (ease: Double, interval: Int, reps: Int, lapses: Int, dueDate: Date)
}
```
Rules (SM-2-lite):
- **Again (lapse):** `interval = 1`, `reps = 0`, `lapses += 1`, `ease = max(minimumEase, ease - 0.2)`.
- **Hard:** `interval = max(1, round(interval * 1.2))`, `ease = max(minimumEase, ease - 0.15)`,
  `reps += 1`.
- **Good:** first success `interval = 1`, second `= 6`, thereafter `= round(interval * ease)`;
  `ease` unchanged; `reps += 1`. *(Classic SM-2 1→6→×ease ladder, simplified.)*
- **Easy:** like Good but `interval = round(interval * ease * 1.3)` and `ease += 0.15`.
- `dueDate = startOfDay(today) + interval days`. All branches floor `interval >= 1` and
  `ease >= 1.3`. Deterministic; no randomness.

### Card generation (`Services/Gamification/ReviewCardFactory.swift`)
- Hook into `GamificationEngine.recordLessonCompletion(_:profile:)` (and/or the lesson-complete
  view path): for the lesson's `Exercise`s, create/upsert:
  - **Missed quiz** → `quiz` card: `front = prompt` (+ options), `back = options[answerIndex]`,
    only when `kind == .quiz` and the user's `chosenIndex != answerIndex` (i.e. graded wrong).
  - **Key idea** → `idea` card: `front = "Recall: <lesson.title>"`, `back = readingSummary`
    (trimmed) — one per lesson.
  - **Reflection** → optional `reflection` card: `front = "You reflected on: <prompt>"`,
    `back =` the saved reflection text (light, self-referential recall).
- New cards start `ease=2.3, interval=1, dueDate=tomorrow(startOfDay)` (first review next day,
  matching the Day-1 loop in `GAMIFICATION.md` §3). Generation is idempotent via `sourceRef` id.

### Gamification integration (no double-award)
- **Streak + daily goal:** add `GamificationEngine.recordReviewSession(cardsReviewed:profile:)`
  that (a) calls the same `advanceStreak(profile:)` used by lessons (reusing
  `StreakCalculator`), and (b) increments the daily-goal counter. To count toward the existing
  ring without conflating with lessons, increment `ActivityDay.lessonsCompleted` by 1 for a
  completed review session **or** (recommended) add `ActivityDay.reviewsCompleted` and have
  `dailyProgress` count `lessonsCompleted + min(1, reviewsCompleted)` — a review-only day closes
  the ring and keeps the streak, but stacking many reviews can't farm the ring. *(Decision D-2.)*
- **XP without double-counting:** award a **separate** small `reviewXP` (default 5/card, daily
  cap e.g. 25) into `profile.totalXP` and `ActivityDay.xpEarned`, sourced as `"review"` —
  **never** re-adding the originating exercise's `xp`. The source lesson already awarded its XP
  at completion time; review XP is new, capped, and tagged, so `totalXP` stays honest and the
  M5 sync `max`-merge (which trusts `totalXP`) isn't corrupted. Cards themselves carry no XP
  field to avoid any path that re-emits lesson XP.
- **Achievements:** reuse the catalog; no new keys required for v1 (optionally a future
  "Review Habit" badge), keeping `AchievementCatalog` stable.

### iOS — screens & state (`ios/Mango/Features/Review/`, DesignSystem tokens)
- **`ReviewService`** (`@Observable`, in `AppModel`): `dueCards(limit:)` via `FetchDescriptor`
  sorted by `dueDate`; `grade(_:card:)` → calls `ReviewScheduler.schedule(...)`, writes the
  card, and on session end calls `GamificationEngine.recordReviewSession`.
- **`ReviewSessionView`**: one card at a time — front, tap to reveal back, then 4 grade buttons
  (Again/Hard/Good/Easy) tinted from `Palette`; a slim progress indicator; a celebratory close
  that **stops** (no auto-next-deck). "All caught up" empty state (FR-7).
- **Entry points:** a Home card ("Today's Review · ~1 min, N due") and an optional Journey/Home
  banner; gentle, never blocking. A `Route.reviewSession` case added and applied via
  `.mangoDestinations()`.
- All spacing/type/color from `Metrics`/`Typo`/`Palette`; haptic on reveal/grade via the
  existing `Haptics` helper.

### Optional backend sync (future, not v1)
- Mirror cards as `PK=USER#<sub>  SK=REVIEWCARD#<id>` with `{ ease(int/str), interval, dueDate,
  lapses, reps, sourceRef }` and a `GET/PUT /v1/me/review-cards` (or fold into a future
  `/v1/me/sync`) — **all numerics int / ease as scaled int or string** to honor the float-free
  invariant; reuse the M5 sync plumbing (debounce/queue/merge). Out of scope for v1 acceptance.

### Diagrams
```
lesson complete ─▶ ReviewCardFactory ─▶ upsert ReviewCard{ease2.3, interval1, due=tomorrow}  (idempotent by sourceRef)
open review ─▶ dueCards(due<=today, limit10, oldest-first) ─▶ grade each ─▶ ReviewScheduler(pure) ─▶ write card
session end ─▶ recordReviewSession ─▶ advanceStreak(StreakCalculator) + daily-goal++ + reviewXP(capped, source="review")
```

## 7. Acceptance criteria
- [ ] **AC-1 (scheduling expands on recall):** consecutive **Good** grades grow `interval`
      along 1 → 6 → round(6×ease) → … with `ease` held; **Easy** grows faster and raises `ease`.
      *(Pure `ReviewSchedulerTests`, like `LevelCurveTests`.)*
- [ ] **AC-2 (lapse contracts):** an **Again** grade resets `interval` to 1, increments `lapses`,
      and drops `ease` by 0.2 floored at 1.3; **Hard** dampens growth and nudges `ease` down.
      *(Pure scheduler unit tests including the 1.3 floor.)*
- [ ] **AC-3 (due selection):** only cards with `dueDate <= today` are surfaced, capped at the
      session limit, oldest-due first. *(Unit test of the selection predicate/sort.)*
- [ ] **AC-4 (card generation + idempotency):** completing a lesson creates a card per missed
      quiz item + a key-idea card; re-completing the same lesson does **not** duplicate cards.
      *(Factory unit test on a seeded in-memory `ModelContainer`.)*
- [ ] **AC-5 (streak kept by review):** completing a review session on a new day advances the
      streak via `StreakCalculator` and closes (part of) the daily goal — a review-only day keeps
      the streak. *(Engine test asserting `currentStreak`/`ActivityDay` change.)*
- [ ] **AC-6 (no double-award):** a review session adds only the separate capped `reviewXP`
      (source `"review"`); the source lesson/exercise XP is never re-added to `totalXP`.
      *(Engine test comparing `totalXP` deltas; the headline correctness test.)*
- [ ] **AC-7 (empty state):** with no due cards the review entry shows "all caught up" and forces
      no busywork. *(View/state test or manual.)*
- [ ] **AC-8 (offline/deterministic):** the whole flow runs with no network and identical inputs
      yield identical schedules. *(Implied by pure scheduler tests + offline run.)*

## 8. Test plan
- **Unit (automated, primary — pure logic like `LevelCurve`/`StreakCalculator`):**
  `ReviewSchedulerTests` (Good/Hard/Easy growth ladders, Again lapse, ease floor, dueDate math),
  `ReviewCardFactoryTests` (missed-quiz detection via `chosenIndex != answerIndex`, key-idea
  card, idempotent upsert on an in-memory SwiftData container), due-selection predicate test,
  and a `GamificationEngine` test for `recordReviewSession` (streak advance, daily-goal count,
  separate-capped `reviewXP`, **no** lesson-XP re-award).
- **iOS UI:** manual run of `ReviewSessionView` (reveal, 4 grades, celebratory stop, empty
  state); Dynamic Type + tint check.
- **Backend:** none for v1 (on-device only). If/when sync is added, `pytest` (moto) for the
  card endpoints honoring the float-free rule + `cdk synth`.

## 9. Rollout & migration
- **Flag:** `insightReviewEnabled`, default on once the AC suite is green; ships in an app
  release (no backend deploy).
- **Migration:** additive SwiftData model (`ReviewCard`) + optional new `ActivityDay`
  property — SwiftData lightweight migration; no server change. Existing users' **already-completed
  lessons** can be backfilled into cards lazily on first launch after update (a one-time
  `ReviewCardFactory.backfill()` over completed lessons), or simply start generating from the
  next completion (Decision D-3).
- **Backward-compat / teardown:** disabling the flag hides the entry points and stops generation;
  orphan `ReviewCard`s are harmless and removable. Optional future sync layers on top via M5.

## 10. Risks & open decisions
- **R-1 Double-awarding lesson XP (headline).** Review must not re-pay the source XP.
  *Mitigation:* separate capped `reviewXP` tagged `"review"`, cards carry no XP field, explicit
  AC-6 test; keeps `totalXP` honest for the M5 `max`-merge.
- **R-2 Streak/goal farming.** Stacking reviews to inflate the ring. *Mitigation:* a review
  session counts as **one** goal unit (cap), and `reviewXP` has a daily cap; celebrate-and-stop
  UX.
- **R-3 Card quality.** Auto-extracted "key idea" cards may be weak. *Mitigation:* start with
  missed-quiz (high-signal) cards + a single concise key-idea card per lesson; defer AI-generated
  cards (future) behind their own spec.
- **R-4 Over-engagement.** Spaced repetition can become a grind. *Mitigation:* hard ~60 s / ~10
  card cap, "all caught up" stop state, single-notification budget respected
  (`docs/GAMIFICATION.md` §6).
- **R-5 Timezone "day".** `dueDate` is start-of-day local; must match the streak's day-granularity.
  *Mitigation:* use the same `Calendar.startOfDay` the engine uses; document.
- **Decisions needed:**
  - **D-1 (recommended: SM-2-lite as specified)** Scheduler algorithm + constants (ease 2.3/1.3,
    1→6 ladder).
  - **D-2 (recommended: dedicated `reviewsCompleted` counting as one goal unit)** How review feeds
    the daily-goal ring without farming.
  - **D-3 (recommended: lazy backfill on first post-update launch)** Backfill existing completed
    lessons vs only generate going forward.
  - **D-4 (recommended: ~5 XP/card, daily cap 25)** Review XP amount + cap.

## 11. Tasks & estimate
1. `ReviewCard` `@Model` + `ReviewCardKind` enum (tints in `Palette`). **(S)**
2. `ReviewScheduler` pure SM-2-lite. **(M)**
3. `ReviewSchedulerTests` (growth ladders, lapse, ease floor, dueDate). **(M)**
4. `ReviewCardFactory` (missed-quiz + key-idea + reflection cards, idempotent upsert). **(M)**
5. `ReviewCardFactoryTests` (in-memory container; dedupe; missed detection). **(M)**
6. `GamificationEngine.recordReviewSession` (streak + daily goal + separate capped `reviewXP`) +
   `ActivityDay` counter + tests (incl. **no double-award**). **(M)**
7. `ReviewService` (`@Observable`) + `AppModel` wiring + due-selection `FetchDescriptor`. **(S)**
8. `Features/Review/ReviewSessionView` + Home entry card + `Route.reviewSession` +
   `.mangoDestinations()` (DesignSystem tokens, haptics). **(M)**
9. Optional one-time backfill of completed lessons (D-3). **(S)**
10. Manual UX pass (reveal/grade/stop/empty, Dynamic Type) + flag flip. **(S)**
11. *(Future, separate)* Backend sync of due cards (float-free) + pytest + `cdk synth`. **(M)**

## 12. References
- `docs/PRODUCT_ROADMAP.md` item 4 (Insight Review); `docs/GAMIFICATION.md` §4 (spaced Insight
  Review, three exercise tiers), §1 (retrieval practice / spacing), §3 (Day-1 review), §6 (ethics).
- iOS: `Services/Gamification/{GamificationEngine,StreakCalculator,LevelCurve}.swift`,
  `Models/{RoadmapModels,UserProfile,ActivityDay,Enums,AchievementCatalog}.swift`,
  `DesignSystem/` (`Palette`/`Typo`/`Metrics`/`Haptics`), `App/Route`.
- Interacts with `working/0014-progress-sync.md` (Epic M5 — `reviewXP` must keep `totalXP`
  honest for the `max`-merge). Pure-scheduler pattern mirrors existing `LevelCurve`/
  `StreakCalculator` tests in `MangoTests/`.
