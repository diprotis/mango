# 0008 — Activity-first product reframe (remove in-app reader)

- **Epic:** M11 · **Status:** Draft · **Owner:** unassigned · **Updated:** 2026-06-26
- **Reviewers:** Principal/SD/QA

## 1. Summary
Mango is **not a reading app**. This spec makes that real: it **removes the in-app book Reader**
(`ios/Mango/Features/Reader/ReaderView.swift`) and every reading-dependent affordance, and
reframes the product as an **engaging-activities + reading-journey tracker**. Users read the
actual book wherever they already read (print, Kindle, library copy); inside Mango they do the
**active-learning loop** — quizzes, reflections, real-world application tasks — and **manually
update their reading status** as they go. A `Book` gains a small, user-driven **journey state**
machine (`notStarted → reading → finished`) plus per-milestone "have you read up to here?"
self-confirmed **checkpoints**, and even **"what to read next" becomes an activity** (a guided
checkpoint/choice card), never in-app reading. The **Catalog** is where you discover a book and
**start a journey** (not read). This is the **keystone** of a deliberate batch of specs; it sets
the model the others (`0009`, `0011`, `0016`, `0017`, `0018`) build on or must adapt to. The
detailed activity types and reward mechanics are **specced separately** (future
`[activities-and-rewards]`); this spec defines the reframe, the state machine, the lesson-loop
mapping, the content-for-generation decision, and the migration — not the new activity catalog.
We keep the minimalist Claude-inspired warm aesthetic (cream + terracotta, `DesignSystem/`
tokens) but lean **more gamified and engaging**.

## 2. Goals / Non-goals
- **Goals:**
  - **Remove the in-app Reader** and all reading-dependent UI/flows; replace every "open to read"
    affordance with a journey/activity affordance or an out-of-app "read on your own" cue.
  - Add a **user-updated journey state** to `Book` (`notStarted → reading → finished`) with a clean,
    pure, unit-testable transition function, stored in SwiftData and designed to sync via the
    existing progress/library plumbing (`0014`).
  - Add **self-confirmed reading checkpoints** ("Have you read up to *X*?") gating progression
    through the journey, replacing the implicit "you read it in-app, so it's unlocked" assumption.
  - Reframe the **lesson/activity loop** so it **never requires in-app reading**: a lesson reads as
    "read this section in your book, then do these activities," and **"what to read next" is itself
    an activity card** (a guided checkpoint/choice), not a reader.
  - **Decide the content/text question:** how the AI still generates good activities without a
    reader. (Recommendation in §6 / §10: keep ingesting an **excerpt/summary server-side for
    generation only** — no reader UI — exactly as today.)
  - Make the **Catalog** a "discover → **Start journey**" surface (not "Create roadmap" / "read").
  - Define **migration** for existing reading-centric code and data, behind a flag, with backward
    compatibility, plus the **cross-spec impact** on the rest of the batch.
- **Non-goals:**
  - **Designing the new activity types or reward mechanics** — XP curves, surprise rewards, the
    "what to read next" decision logic, streaks-for-reading, etc. Those are the future
    `[activities-and-rewards]` spec; here we only reserve the seams.
  - Building **progress sync** itself (that is `0014-progress-sync.md`); we only *design the field
    so it can sync* and note the contract delta.
  - Changing the **gamification engine math** (`LevelCurve`, `StreakCalculator`, XP amounts) or the
    `Roadmap → Milestone → Lesson → Exercise` graph shape.
  - Adding social, EPUB, or background-parsing features (separate specs); we only note their
    relationship to the reframe.
  - Keeping any "read the full text inside Mango" capability, even as a hidden/optional mode — the
    Reader is **gone**, not demoted.

## 3. Background & context
**Current state (reading-centric).** The shipped v0.1 (`docs/PRODUCT_ROADMAP.md` §"v0.1 — shipped")
describes "an immersive reader plus an active-learning loop." Concretely:
- `Features/Reader/ReaderView.swift` renders `book.fullText` in a scrollable serif view with
  font-size controls and a `markReadToEnd()` that sets `book.readProgress = 1`.
- `App/Route.swift` has a `case reader(Book)` wired through `.mangoDestinations()`.
- Reader is reachable from **BookDetail** ("Read the book", `BookDetailView.swift:93`) and **Today**
  ("Open reader" / "Read the book", `TodayView.swift:105,112`).
- `Models/Book.swift` carries reading state: `fullText`, `readProgress: Double`, `lastReadOffset:
  Int`.
- The **Journey** unlocks the next lesson purely from `Lesson.isCompleted` — it never checks
  whether the user has *read* the corresponding section, because the implicit assumption is they
  read it in the in-app Reader first (`JourneyView.swift` `status(_:)`).

**Why now.** This is a product-direction pivot, not a refinement: Mango competes on **doing**, not
on **summarizing or in-app reading**. The market split is clear — summary apps (Blinkist/Shortform)
trade depth for speed and users forget most of it within days
([keithjlang.com](https://keithjlang.com/book-summary-apps/),
[transcript.study](https://transcript.study/blog/best-book-summary-apps)); the durable model is
**read the real book on your own + engage in a companion app** (Fable lets you "read … at your own
pace or follow the club's suggested milestones",
[apps.apple.com/Fable](https://apps.apple.com/us/app/fable-track-discuss-books/id1488170618);
Readwise frames itself as "an external system for transforming reading into meaningful action,"
[blog.readwise.io](https://blog.readwise.io/reading-workflow-part-1/amp/)). Active learning beats
passive reading on retention by a wide margin (≈90% vs ≈20% retention for doing vs listening;
70:20:10 puts ~70% of learning in *application*,
[anshadameenza.com](https://anshadameenza.com/blog/human-development/active-learning-principle/),
[cloudassess.com](https://cloudassess.com/blog/70-20-10-model/)). Mango's own design rationale
already says this — `docs/GAMIFICATION.md` §4 ("**turning reading into doing**… reading alone is
passive and forgettable; active recall beats re-reading") — so the reframe **aligns the product
with its stated thesis** and removes the contradiction of shipping a reader at all.

**Crucial enabling fact (content).** Roadmap/activity generation **already does not need the full
book in-app**. The backend prompt (`backend/src/shared/prompts.py` `roadmap_user`) sends only
`{title, author, wordCount}` + an **excerpt** capped at `excerpt_text[:12000]`, and the inline
generation path caps `full_text[:12000]` (`generate_roadmap.py`); the iOS direct path likewise
truncates `book.fullText.prefix(12000)` (`AIPrompts.swift:60`, `RemoteAIService.swift:19`). So
generation is **already grounded in an excerpt/summary, not the whole text** — removing the Reader
changes *nothing* about generation quality. This is the linchpin of the §6/§10 recommendation.

**Related specs (the batch).** `0009-catalog-expansion-100-books` (Catalog becomes the primary
"start a journey" surface), `0011-navigation-and-activity-interaction` (tab/nav + activity UX on top
of this model), `0016-insight-review` (review activities — reinforced, not reading-dependent),
`0017-pdf-background-parsing` and `0018-epub-import` (ingestion connectors — must be repositioned as
"ingest for generation only, no reader"). `0014-progress-sync` owns the sync this field will ride.

## 4. User stories
- As a **reader**, I read *Atomic Habits* on my Kindle and open Mango to *do the work* — quizzes,
  reflections, and a real-world task — without Mango trying to make me read inside the app.
- As a **learner**, after I finish a chapter on paper I tap **"I've read up to here"** in Mango and
  the next set of activities unlocks — Mango tracks my journey, I control the truth of where I am.
- As a **busy user**, I set a book to **Reading** when I start and **Finished** when I'm done; my
  shelf reflects reality and my streak/goal come from the *activities I complete*, not minutes
  in-app.
- As someone **between books**, I hit a **"What to read next?"** activity — a guided checkpoint that
  helps me pick my next journey from the Catalog — which *feels* like part of the game, not a
  detour into reading.
- As a **discoverer**, I browse the Catalog, find a book, and tap **Start journey** (not "read"); it
  builds my activity roadmap and drops me into the journey.
- As an **offline, first-run user**, none of this needs the network or a key: the bundled sample
  book starts in `notStarted`, I can move it to `Reading`, and the first activities work fully
  offline (preserving the offline-first invariant in `CLAUDE.md`).

## 5. Requirements
- **Functional:**
  - **FR-1 (remove Reader).** Delete `Features/Reader/ReaderView.swift` and the `Route.reader(Book)`
    case (and its `.mangoDestinations()` arm). No screen may navigate to a full-text reader. Build
    must not reference `ReaderView` anywhere.
  - **FR-2 (replace reader affordances).** Every former "Read the book / Open reader" entry point is
    replaced:
    - **BookDetail** "Read the book" → **"Open journey"** when a roadmap exists, else **"Start
      journey"**; plus a calm, non-actionable **"Read this book on your own"** hint (Kindle/print)
      — *no* in-app reader.
    - **Today** "Open reader" / "Read the book" → the **continue-activity** CTA (next lesson /
      checkpoint) and a small **journey-state control** (see FR-4); never a reader link.
  - **FR-3 (journey state machine on `Book`).** A `Book` has a user-updated **`JourneyState`**
    (`notStarted`, `reading`, `finished`) with a **pure** transition function
    `JourneyStateMachine.apply(_:to:)` over an explicit event set
    (`start`, `markFinished`, `reopen`, and an automatic `firstActivityCompleted` nudge
    notStarted→reading). Illegal transitions are no-ops. Default `notStarted`. Setting `finished`
    is always user-allowed (you can finish a book you never marked reading).
  - **FR-4 (manual status control, no inference from in-app reading).** The user can change journey
    state from **BookDetail** and a compact control on **Today**; state is **never** derived from
    `readProgress` or any in-app reading signal (those signals are gone). Completing the *first*
    activity may auto-advance `notStarted → reading` (FR-3) as a convenience, but nothing
    auto-marks `finished`.
  - **FR-5 (self-confirmed reading checkpoints).** Each **Milestone** gains an optional, user-toggled
    **`readingConfirmed: Bool`** ("Have you read up to *‹milestone›*?"). The Journey gates a
    milestone's lessons on `readingConfirmed` (in addition to the existing prior-lesson-complete
    rule): a milestone shows a **"I've read up to here"** checkpoint card; until confirmed, its
    lessons render as a **read-gated** state (visually distinct from the existing `locked`), and
    confirming unlocks them. Confirmation is reversible and self-attested (honor system — matches
    the self-attested application-task pattern in `GAMIFICATION.md` §4).
  - **FR-6 (lesson loop never requires in-app reading).** `LessonView`'s reading phase is reframed
    from "here is the text" to **"read this section in your book"**: it shows the lesson's
    `readingSummary` as a **recap/orientation** (explicitly *not* the source text) plus a **"I've
    read this section"** affordance, then proceeds to the activities exactly as today. No lesson
    step renders `book.fullText`.
  - **FR-7 ("what to read next" is an activity).** Introduce a **checkpoint/choice activity** —
    a **"What to read next?"** card — surfaced at journey/book completion (and optionally on Today
    when no active journey has remaining lessons). It is a guided choice that routes into the
    **Catalog** to start the next journey. It is modeled as an activity surface (reserving the
    `[activities-and-rewards]` seam), **not** a reader. v1 may implement it as a simple guided card
    that deep-links to Catalog; the *recommendation logic* is deferred to `[activities-and-rewards]`.
  - **FR-8 (Catalog = discover + start journey).** Catalog's primary action is relabeled
    **"Start journey"** (from "Create roadmap"), and its copy drops "read"/"reading classic" framing
    in favor of "start a guided journey." Behavior is unchanged (fetch text for generation, build
    roadmap, route to Journey) — only the framing and the fact that it ingests text **solely for
    generation** (FR-11).
  - **FR-9 (retire in-app reading data).** `Book.readProgress` and `Book.lastReadOffset` are
    **removed** from the model (or formally deprecated/ignored — Decision D-4); no UI reads or writes
    them. `markReadToEnd()` is deleted with the Reader.
  - **FR-10 (book "active" semantics preserved).** The existing single-active-`Book` concept and the
    Today "continue" surface remain; only their reader links are replaced. Journey/Today continue to
    pick the active book.
  - **FR-11 (content for generation only — no reader).** The app/back end **continues to ingest an
    excerpt/summary of the book text purely to ground activity generation** (no reader UI). The full
    text is **not** retained for display; only what generation needs (an excerpt ≤12k chars, already
    the cap) is used, and it is never surfaced to the user as readable content. (See D-1.)
  - **FR-12 (state designed to sync).** `JourneyState` (and, if cheap, per-book `readingConfirmed`
    flags) are stored on-device now and **shaped to ride the existing `0014` progress/library sync**
    — either as a field on the per-user library reference (`LibraryItem`) or folded into the future
    `/v1/me/sync`. v1 is offline/on-device; the contract delta is specified (§6) but wiring is
    `0014`'s job.
- **Non-functional:**
  - **Offline-first (invariant).** First launch with the bundled sample, Mock AI, no network/key
    must fully work: sample starts `notStarted`, can go `reading`, first activities run offline
    (`CLAUDE.md` invariant).
  - **Determinism / testability.** `JourneyStateMachine` is a **pure** function with no SwiftData
    dependency, unit-tested exhaustively in the spirit of `LevelCurve`/`StreakCalculator`.
  - **Design system.** All new/edited UI uses `Palette`/`Typo`/`Metrics`/`Haptics` tokens — no
    hardcoded hex or magic numbers (`CLAUDE.md` style). Warm cream+terracotta retained; checkpoints
    and state controls should feel **gamified and celebratory** (e.g. a satisfying confirm
    animation), not utilitarian.
  - **No third-party deps; Xcode 16 sync groups.** New Swift files dropped under `ios/Mango/` are
    auto-registered; do not hand-edit `project.pbxproj` (`CLAUDE.md` invariants).
  - **Accessibility.** Journey-state control and checkpoints are large tap targets, Dynamic Type via
    `Typo`, VoiceOver labels ("Mark as reading", "I've read up to chapter 3").
  - **Privacy/cost.** Removing the reader *reduces* what we display/store; generation cost is
    unchanged (same ≤12k-char excerpt).

## 6. Design

### 6.1 Removals & affordance replacements (iOS)
| Removed / changed | File (verified loc.) | Replacement |
|---|---|---|
| `ReaderView` screen | `Features/Reader/ReaderView.swift` (delete) | — (no reader) |
| `Route.reader(Book)` case | `App/Route.swift:7` | remove case + its `.mangoDestinations()` arm (`Route.swift:17`); add `Route.readingCheckpoint(Book)` for the "what to read next"/checkpoint surface (optional, see FR-7) |
| `case let .reader(book): ReaderView(book: book)` arm | `App/Route.swift:17` | delete arm; add `case let .readingCheckpoint(book): ReadingCheckpointView(book: book)` |
| "Read the book" `NavigationLink(value: Route.reader(book))` | `Features/Library/BookDetailView.swift:93–96` | "Open/Start journey" + passive "Read on your own" hint + journey-state control |
| "Open reader" `NavigationLink(value: Route.reader(book))` | `Features/Home/TodayView.swift:105–108` (the `book.roadmap == nil` arm) | replace with **"Start journey"** → `Route.bookDetail(book)` (where generation lives) |
| "Read the book" secondary `NavigationLink(value: Route.reader(book))` | `Features/Home/TodayView.swift:112–115` | remove; add compact journey-state control |
| `readProgress`, `lastReadOffset` | `Models/Book.swift:22–23,54–55` | removed (D-4) |
| `markReadToEnd()` | `Features/Reader/ReaderView.swift` (in the deleted file) | removed with the Reader (D-4) |

> **Stale comment cleanup:** `CatalogView.swift:71–73` has a comment "Reader/Lesson destinations
> reachable from here are already registered…" — update it (no reader). Also grep `docs/` for
> "reader" wording (`ARCHITECTURE.md`, `PRODUCT_ROADMAP.md`) per Task 13.

### 6.1.1 Files to add / change (authoritative)
**Add** (auto-registered by Xcode 16 file-system-synchronized groups — do **not** edit `project.pbxproj`):
- `ios/Mango/Services/Gamification/JourneyStateMachine.swift` — pure transition fn (§6.3).
- `ios/Mango/Features/Journey/ReadingCheckpointView.swift` — "What to read next?" activity (FR-7).
- `ios/Mango/Features/Library/JourneyStateControl.swift` — reusable segmented/menu control (FR-4),
  used by both `BookDetailView` and `TodayView`.
- `ios/MangoTests/JourneyStateMachineTests.swift` — full transition table (§8).
- `ios/MangoTests/JourneyMigrationTests.swift` — D-2 backfill on a seeded in-memory container (§8).
- `ios/MangoTests/JourneyGatingTests.swift` — read-gated/available/locked predicate (§8).
- `ios/MangoTests/LibraryItemDTOTests.swift` — lenient `journeyState` decode (§8, mirrors
  `CatalogBookTests`).

**Change:**
- `ios/Mango/Models/Book.swift`, `ios/Mango/Models/RoadmapModels.swift`, `ios/Mango/Models/Enums.swift` (§6.2).
- `ios/Mango/App/Route.swift` (remove reader, add checkpoint).
- `ios/Mango/Features/Library/BookDetailView.swift`, `ios/Mango/Features/Home/TodayView.swift` (FR-2/4).
- `ios/Mango/Features/Journey/JourneyView.swift` (read-gated gating + checkpoint card, FR-5).
- `ios/Mango/Features/Lesson/LessonView.swift` (reframe reading phase, FR-6).
- `ios/Mango/Features/Catalog/CatalogView.swift` + `CatalogSamples.swift` (FR-8 copy/CTA).
- `ios/Mango/Services/Persistence/SeedData.swift` + a new `MangoMigration.backfillJourneyState(_:)`
  one-time pass invoked from `RootView.task` after `ensureSeeded` (§9).
- `ios/Mango/Services/Networking/DTOs.swift` + `shared/api/openapi.yaml` (`LibraryItem`, §6.7).

**Delete:** `ios/Mango/Features/Reader/ReaderView.swift` (and the empty `Features/Reader/` group).

### 6.2 Data (iOS — SwiftData; auto-picked-up by Xcode 16 sync groups)

**Migration mechanism (verified).** `Services/Persistence/MangoModelContainer.swift` builds the
store with an **un-versioned** `Schema(MangoSchema.models)` and no `SchemaMigrationPlan`. SwiftData
therefore applies **automatic lightweight migration**: adding a defaulted stored property and
removing a stored property both succeed without a plan, so the model edits below are safe; the
data *backfill* in §9 is a separate runtime pass (lightweight migration only zero-fills new
fields, it cannot infer `finished` from completion). `Book`/`Milestone` are already registered in
`MangoSchema.models` (lines 4–13) — no registration change needed.

**`Book` (modified)** — `Models/Book.swift` (currently lines 22–23 hold the reading fields):
```swift
// ADD (mirrors the existing sourceKindRaw/sourceKind pattern at Book.swift:50,59–62):
var journeyStateRaw: String = JourneyState.notStarted.rawValue
var journeyState: JourneyState {
    get { JourneyState(rawValue: journeyStateRaw) ?? .notStarted }
    set { journeyStateRaw = newValue.rawValue }
}
// REMOVE (Book.swift:22–23 + their init assignments at :54–55):
//   var readProgress: Double          (was "/// Fraction of the text read, 0...1.")
//   var lastReadOffset: Int           (was "/// Character offset for resume.")
```
- Add `journeyStateRaw` to `init(...)` defaulting to `JourneyState.notStarted.rawValue` (keep the
  designated initializer's other params unchanged so existing call sites in `CatalogView`,
  `AddBookView`, `SeedData` still compile).
- `fullText` is **retained on the model** only as the generation input cache (FR-11) and is **never
  rendered**; alternatively trimmed to an `excerpt` only (Decision D-1).

**`Milestone` (modified)** — `Models/RoadmapModels.swift` (the `@Model` at lines 40–60):
```swift
var readingConfirmed: Bool = false   // self-confirmed checkpoint (FR-5)
```
Set `self.readingConfirmed = false` in `init(title:subtitle:order:)` (RoadmapModels.swift:50–55).
Additive, defaulted → lightweight migration; no plan required.

**`JourneyState` enum** — `Models/Enums.swift` (append after `LessonStatus` at line 84):
```swift
enum JourneyState: String, CaseIterable, Codable, Identifiable {
    case notStarted, reading, finished
    var id: String { rawValue }
    var title: String {
        switch self {
        case .notStarted: return "Not started"
        case .reading:    return "Reading"
        case .finished:   return "Finished"
        }
    }
    var symbol: String {           // SF Symbols, matching the ExerciseKind.symbol idiom
        switch self {
        case .notStarted: return "bookmark"
        case .reading:    return "book"
        case .finished:   return "checkmark.seal.fill"
        }
    }
    var tint: Color {              // Palette tokens only (Theme.swift) — no raw hex
        switch self {
        case .notStarted: return Palette.textTertiary
        case .reading:    return Palette.accent
        case .finished:   return Palette.success
        }
    }
}
```

**`LessonStatus` (modified)** — `Models/Enums.swift:83–85` currently
`enum LessonStatus { case locked, available, completed }`. Add a **`readGated`** case (Decision
D-3) so the Journey distinguishes "locked because reading not confirmed" from "locked because a
prior lesson isn't done":
```swift
enum LessonStatus { case locked, readGated, available, completed }
```
`JourneyRow` (`JourneyView.swift:84–137`) must add `readGated` arms to its `switch`es:
`indicatorColor → Palette.warning`, `indicatorSymbol → "lock.open"` (or `"hand.raised"`), and treat
it like `locked` for tap-gating (no `NavigationLink`) but render at full opacity with the checkpoint
card above it (§6.4). This is a non-exhaustive-switch compile break if the case is added without
updating `JourneyRow` — call it out in the task list (Task 2/7).

### 6.3 Pure state machine (`Services/Gamification/JourneyStateMachine.swift`, unit-tested like `LevelCurve`)
A free, SwiftData-free function:
```swift
enum JourneyEvent { case start, markFinished, reopen, firstActivityCompleted }

enum JourneyStateMachine {
    /// Pure: given current state + an event, return the next state (illegal → unchanged).
    static func apply(_ event: JourneyEvent, to state: JourneyState) -> JourneyState
}
```
Transition table (illegal transitions are no-ops):

| from \ event | `start` | `firstActivityCompleted` | `markFinished` | `reopen` |
|---|---|---|---|---|
| `notStarted` | `reading` | `reading` | `finished` | `notStarted` |
| `reading` | `reading` | `reading` | `finished` | `reading` |
| `finished` | `finished` | `finished` | `finished` | `reading` |

Notes: `markFinished` is always allowed from any state (you can finish a book you never marked
reading). `firstActivityCompleted` only ever nudges `notStarted → reading` (never touches
`finished`). `reopen` moves `finished → reading` (re-engage a finished book), otherwise no-op.

### 6.4 Lesson/activity loop mapping (the core reframe)
The graph (`Roadmap → Milestone → Lesson → Exercise`) and `GamificationEngine` are **unchanged**.
Only the **framing and gating** change:

```
OLD:  open Reader (read fullText in-app) ─▶ Journey unlocks next lesson by isCompleted ─▶ Lesson:
      reading phase shows fullText/summary ─▶ exercises ─▶ XP

NEW:  read the real book on your own ─▶ confirm "read up to milestone" checkpoint (FR-5)
      ─▶ Journey unlocks that milestone's lessons (read-gated → available) ─▶ Lesson:
      reading phase = "read this section in your book" + recap(readingSummary) + "I've read this"
      ─▶ exercises (quiz/reflection/application) ─▶ XP (engine unchanged)
      ─▶ at journey end: "What to read next?" activity card ─▶ Catalog → start next journey
```

- **`LessonView` reading phase (FR-6):** keep the `Lesson.readingSummary` card
  (`RoadmapModels.swift:64`) but relabel from "Read" (in-app) to a **recap/orientation** ("In this
  section …") with an explicit cue to read the section in the user's own copy and an **"I've read
  this section"** button before practice. Never renders `book.fullText`. Concretely, add a local
  `@State private var readConfirmed = false`; the practice/exercise CTA is gated on it (button
  disabled until tapped), and the copy reads e.g. *"Read **‹lesson.title›** in your own copy, then
  come back to practice."* This is orientation-only state (not persisted) — it just paces the user;
  the persisted gate is the milestone `readingConfirmed` checkpoint.
- **`JourneyView` gating (FR-5):** the current predicate is `status(_:)` at `JourneyView.swift:47–50`
  (`isCompleted → .completed`; first-incomplete → `.available`; else `.locked`). Replace with a
  read-gate-aware version:
  ```swift
  func status(_ lesson: Lesson) -> LessonStatus {
      if lesson.isCompleted { return .completed }
      // read-gate first: a milestone whose reading isn't confirmed gates ALL its lessons
      if lesson.milestone?.readingConfirmed == false { return .readGated }
      return lesson.persistentModelID == firstIncompleteID ? .available : .locked
  }
  ```
  Render one **checkpoint card** per unconfirmed milestone (above its lessons): *"Have you read up to
  ‹milestone.title›?"* with an **"I've read up to here"** primary button. Confirming flips
  `milestone.readingConfirmed = true`, `try? context.save()`, fires `Haptics.success()`, and animates
  the lessons from `.readGated` → `.available` with `Animation.spring` (gated on
  `@Environment(\.accessibilityReduceMotion)` → `nil` when on, per the existing `ProgressRing`/`XPBar`
  idiom). Confirmation is reversible (a small "Undo / not yet" affordance flips it back).
- **"What to read next" activity (FR-7):** a `ReadingCheckpointView(book:)` shown when the active
  book's journey is complete (`roadmap.progress == 1`), routed via the new `Route.readingCheckpoint`.
  v1 body: a celebratory card (`Card`, `Typo.title3`, `Palette.success` accent) + a **"Find my next
  book"** button → deep-links into the **Catalog** tab. It is an **activity surface**, reserving the
  `[activities-and-rewards]` hook for richer recommendation/choice logic later. Also surfaced as the
  `TodayView` "you've finished every lesson" arm (`TodayView.swift:109–111`), replacing the static
  "🌱" text with a tappable card.

### 6.5 Catalog reframing (FR-8)
`Features/Catalog/CatalogView.swift` + `CatalogSamples`: relabel the primary button **"Create
roadmap" → "Start journey"**, update intro copy ("Discover a book and start a guided journey of
activities" — drop "read"/"classic to read"), and on success keep routing to `JourneyView`. The
ingested `text` is used **only** to build the roadmap (FR-11) and seeds the `Book` in `notStarted`
(then `start` is dispatched as the journey opens, moving it to `reading`).

### 6.6 Content / text question — **decision and tradeoffs** (FR-11, D-1)
The AI needs *something* to generate good activities. Options:

- **(A) Recommended — keep ingesting an excerpt/summary server-side *for generation only* (no reader
  UI).** This is the **smallest, safest change**: generation already runs on a ≤12k-char excerpt
  (`prompts.py`/`generate_roadmap.py`/`AIPrompts.swift`), so we change *nothing* in the generation
  path — we only stop *displaying* the text. Keep the full/excerpt text as an **opaque generation
  input** (server-side via the existing `contentRef`/S3 path for backend mode; on-device as a
  non-displayed cache or trimmed to `excerpt`).
  - *Pros:* zero generation-quality regression; reuses the entire existing connectors + prompt
    pipeline; offline path keeps working; minimal code churn; honors the float-free + stdlib backend
    invariants (no new server logic). *Cons:* we still *ingest* copyrighted text the user provides
    (already true today; mitigated because we never display it and only send an excerpt to the
    model); a content cache exists on-device (mitigated by trimming to excerpt — D-1).
- **(B) Generate from metadata + known public summaries only** (title/author + a curated synopsis;
  no user-provided full text). *Pros:* no full-text ingestion at all; lighter storage. *Cons:*
  **worse, less book-specific activities** (the prompt explicitly says "keep it specific to THIS
  book's ideas… ground the content" — `prompts.py`), depends on having a quality summary per title
  (fine for the curated Catalog, **bad for user-imported** URL/PDF/EPUB where no summary exists),
  and it would *regress* the import connectors' reason to exist (`0017`/`0018`).
- **(C) Hybrid:** Catalog/curated books generate from a stored synopsis (B); user-imported books
  generate from an excerpt of their text (A). *Pros:* minimizes ingestion for the common Catalog
  path. *Cons:* two code paths and prompt variants to maintain; more complexity than the reframe
  needs right now.

**Recommendation: (A)** for v1 (optionally trimming the on-device cache to `excerpt` per D-1), with
**(C)** noted as a future optimization once the Catalog has curated synopses (`0009`). Rationale:
generation quality is load-bearing for the whole product, (A) preserves it at near-zero risk, and it
keeps `0017`/`0018` meaningful (they ingest **for generation, not for reading**).

### 6.7 API / contract (design-for-sync; wiring is `0014`)
No endpoint is *required* for v1 (state is on-device). The **contract delta** to reserve so `0014`
can sync cleanly, keeping `shared/api/openapi.yaml` ⇄ `DTOs.swift` ⇄ handlers in lockstep.

**`LibraryItem` schema** — extend the existing block at `openapi.yaml:300–304` (currently just
`bookId` + `addedAt`). The per-user library reference (`PK=USER#<sub>`, `SK=BOOK#<bookId>`,
`library.py:67–75`) is exactly "this user's relationship to this book," so journey state belongs
here, **not** on the shared catalog record:
```yaml
LibraryItem:
  type: object
  properties:
    bookId:            { type: string }
    addedAt:           { type: string, format: date-time }
    journeyState:      { type: string, enum: [notStarted, reading, finished] }   # NEW; default notStarted
    confirmedMilestones:                                                          # NEW; optional
      type: array
      items: { type: string }      # milestone ids the user has read-confirmed
```
Example `GET /v1/me/library` item once `0014` wires it:
```json
{ "bookId": "pg-2680", "addedAt": "2026-06-27T12:00:00Z",
  "journeyState": "reading", "confirmedMilestones": ["m1", "m2"] }
```
- **DynamoDB shape (float-free invariant):** persist on the same item `library.py` already writes —
  add string attributes `journeyState` (the enum raw value) and `confirmedMilestones` (a DynamoDB
  **list of strings**, or a JSON string if `0014` prefers). No numeric fields → no `float` concern;
  `addedAt`/keys are unchanged. `_item_to_ref` (`library.py:32–35`) gains
  `"journeyState": item.get("journeyState", "notStarted")` and the confirmed-milestones list.
- **`DTOs.swift`:** add a `LibraryItemDTO` (currently the app has no library DTO — it reads the raw
  `items` array) with `journeyState: String` defaulting to `"notStarted"` on absent, decoded
  leniently exactly like `CatalogBook.init(from:)` (`CatalogBook.swift:40–49`).
- Alternatively fold into a future unified `/v1/me/sync`. Either way, journey state is **per-user,
  per-book**.
- **No change** to the `Progress` schema (gamification stays as-is) or the roadmap/grade contracts.

**Note — roadmap generation is async (don't regress it).** `openapi.yaml:49–81` defines roadmap
generation as **POST `/v1/roadmaps/generate` → 202 `{jobId}`**, polled via
`GET /v1/roadmaps/jobs/{jobId}`. The reframe touches none of this; `RoadmapGenerator.generate`
(called from `CatalogView`/`BookDetailView`) and its job polling are unchanged — we only relabel the
CTA and gate lessons. Listed here so an implementer doesn't "simplify" the journey-start path.

### 6.8 Diagrams
```
Book.journeyState (per user):   notStarted ──start/firstActivity──▶ reading ──markFinished──▶ finished
                                     ▲                                  ▲                         │
                                     └────────────── (no-op) ───────────┴────────── reopen ───────┘

Journey gating (per milestone):  prior lessons done? ──┐
                                                        ├─▶ AND readingConfirmed? ─▶ lesson .available
                 "Have you read up to X?" checkpoint ───┘        else ─▶ lesson .readGated
```

## 7. Acceptance criteria
- [ ] **AC-1 (Reader removed):** `ReaderView.swift` and `Route.reader` no longer exist; a repo-wide
      search for `ReaderView`/`Route.reader`/`.reader(` returns no references; the app builds and
      `make ios-test` is green. *(Build + grep check.)*
- [ ] **AC-2 (no reader affordances):** BookDetail and Today expose **no** path to a full-text
      reader; former reader buttons are replaced per FR-2 (journey CTA + "read on your own" hint +
      state control). *(Manual UI review + snapshot/inspection of the two views.)*
- [ ] **AC-3 (state machine correctness):** `JourneyStateMachine.apply` matches the §6.3 table for
      **every** (state × event) pair, including illegal-transition no-ops and `markFinished` from
      any state. *(Pure `JourneyStateMachineTests`, like `LevelCurveTests`.)*
- [ ] **AC-4 (manual status, no inference):** changing journey state from BookDetail/Today persists
      and reflects in the shelf; state is **never** set from any reading signal; first-activity
      completion auto-advances `notStarted → reading` but nothing auto-sets `finished`. *(Unit test
      on the engine/path + manual.)*
- [ ] **AC-5 (read-gated checkpoints):** a milestone with `readingConfirmed == false` read-gates its
      lessons and shows the "Have you read up to *X*?" checkpoint; confirming unlocks them; the gate
      is independent of and additional to the prior-lesson-complete rule. *(JourneyView state test +
      manual.)*
- [ ] **AC-6 (lesson loop needs no in-app reading):** the lesson reading phase shows a recap +
      "read in your book" cue and **never** renders `book.fullText`; activities run unchanged and
      award XP via the existing engine. *(Manual + assert `fullText` is not referenced by any
      lesson/journey view.)*
- [ ] **AC-7 ("what to read next" is an activity):** completing a journey surfaces a "What to read
      next?" activity card that routes into the Catalog to start a new journey — not a reader.
      *(Manual flow check.)*
- [ ] **AC-8 (Catalog framing):** Catalog's primary CTA reads "Start journey," copy contains no
      in-app-reading framing, and starting still builds a roadmap and opens the Journey. *(Manual +
      copy check.)*
- [ ] **AC-9 (offline-first preserved):** fresh install, Mock AI, no network/key: sample book starts
      `notStarted`, can be set `reading`, first activities complete offline. *(Manual offline run.)*
- [ ] **AC-10 (data retired safely):** `readProgress`/`lastReadOffset` are gone (or provably unused);
      SwiftData migration succeeds from a pre-reframe store with existing books (they map to
      `notStarted`, or `finished` if all lessons were complete — D-2). *(Migration test on a seeded
      container.)*
- [ ] **AC-11 (sync-ready contract):** the `LibraryItem` (or `/v1/me/sync`) delta for `journeyState`
      is reflected in `openapi.yaml` and `DTOs.swift` (decodes leniently; absent → `notStarted`),
      with all-string/int values — even though wiring is `0014`. *(DTO decode test + `openapi` lint.)*

## 8. Test plan
- **Unit (automated, primary — pure logic like `LevelCurve`/`StreakCalculator`):** named methods,
  mirroring `LevelCurveTests.swift`'s style (`XCTAssertEqual`, no async):
  - `JourneyStateMachineTests` (→ AC-3): `testStartFromNotStartedReads`, `testStartFromReadingIsNoOp`,
    `testMarkFinishedFromAnyState` (parametrize all 3 froms), `testFirstActivityNudgesOnlyNotStarted`
    (asserts `finished` untouched), `testReopenFinishedToReading`, `testReopenNonFinishedNoOp`, and a
    `testExhaustiveTable` looping every (state × event) against the §6.3 matrix.
  - `JourneyMigrationTests` (→ AC-10): on an in-memory `ModelContainer` (`MangoModelContainer`-style,
    `isStoredInMemoryOnly: true`), seed a pre-reframe `Book` + roadmap and assert
    `backfillJourneyState` sets `.finished` when **all** lessons complete, `.reading` when **some**,
    `.notStarted` when none; and `Milestone.readingConfirmed == true` for fully-completed milestones.
  - `JourneyGatingTests` (→ AC-5): the §6.4 `status(_:)` predicate as a pure helper — returns
    `.readGated` when `readingConfirmed == false`, `.available` for the first-incomplete in a
    confirmed milestone, `.locked` for later ones, `.completed` when done.
  - `LibraryItemDTOTests` (→ AC-11): decode JSON with and without `journeyState`; absent →
    `"notStarted"`; unknown enum string → `"notStarted"` (lenient), mirroring
    `CatalogBookTests.swift` exactly.
- **iOS UI (manual):** BookDetail/Today affordance review (no reader); journey-state control;
  milestone checkpoint confirm + unlock animation; lesson reading-phase copy ("read in your book",
  no full text); "What to read next?" → Catalog; Dynamic Type + VoiceOver labels; warm-theme tint
  check.
- **Backend:** **none required for v1** (state is on-device; generation path unchanged). If the
  `LibraryItem.journeyState` field is added server-side under `0014`, add `pytest` (moto) for
  `library.py` round-tripping the string field and `cdk synth -c stage=beta` must pass (float-free,
  stdlib-only invariants).
- **Regression:** `make ios-test` + (unchanged) backend `pytest`/`cdk synth` stay green — the
  generation, grading, gamification, and roadmap-graph paths are untouched.

## 9. Rollout & migration
- **Flag:** `activityFirstEnabled` (default **on** once the AC suite is green) gates the reframed UI.
  Because the Reader is **deleted** (not hidden), the flag mainly guards the new journey-state /
  checkpoint UI and copy; a kill-switch reverts to the pre-reframe navigation only if the build
  still contains it during the transition release (Decision D-5: ship behind flag for one release,
  then remove the flag and the dead reader code).
- **Data migration (SwiftData, lightweight + a one-time pass):**
  - Additive `Book.journeyStateRaw` (default `notStarted`) and `Milestone.readingConfirmed`
    (default `false`) are lightweight migrations.
  - **One-time backfill** on first launch post-update (Decision D-2). Add
    `enum MangoMigration { static func backfillJourneyState(_ context: ModelContext) }` invoked from
    `RootView.task` (`RootView.swift:23–29`) **after** `SeedData.ensureSeeded`, guarded by a
    `UserDefaults` flag (e.g. `mango.didBackfillJourneyState`) so it runs exactly once. Logic per
    existing `Book` (fetched via `FetchDescriptor<Book>()`):
    ```swift
    let lessons = book.roadmap?.allLessons ?? []          // Roadmap.allLessons exists (RoadmapModels.swift:25)
    if !lessons.isEmpty && lessons.allSatisfy(\.isCompleted) { book.journeyState = .finished }
    else if lessons.contains(where: \.isCompleted)          { book.journeyState = .reading }
    else                                                    { book.journeyState = .notStarted }
    for m in book.roadmap?.orderedMilestones ?? [] {
        if !m.orderedLessons.isEmpty && m.orderedLessons.allSatisfy(\.isCompleted) { m.readingConfirmed = true }
    }
    ```
    Then `try? context.save()` and set the flag. (So existing users aren't re-gated behind
    checkpoints for work they've already done.)
  - **Dropping `readProgress`/`lastReadOffset`:** SwiftData ignores removed properties on
    lightweight migration; no data action needed (Decision D-4). If we instead keep them
    deprecated, they are simply never read/written.
- **Backward compatibility / teardown:** with the flag off (transition release), the app still
  functions on the existing graph; turning it on swaps framing + gating. After the flag is removed,
  the reader code and reading-progress fields are deleted for good. The `0014` sync of
  `journeyState` layers on later without further migration (field already present + defaulted).
- **Sequencing:** land this **before** `0009` and `0011` (they assume this model). `0017`/`0018`
  must adopt the "ingest for generation only" framing (no reader) — coordinate copy/positioning, but
  they are not blocked by this spec's code.

## 10. Risks & open decisions
- **R-1 Generation quality without a reader.** *Risk:* fear that removing the reader weakens
  activities. *Reality/mitigation:* generation already uses only a ≤12k-char excerpt + metadata
  (`prompts.py`/`AIPrompts.swift`), so quality is unaffected; **Recommendation (A)** keeps that path
  intact. Headline reassurance, surfaced in §3/§6.6.
- **R-2 Self-attested checkpoints can be gamed / skipped.** *Mitigation:* the honor system matches
  the existing self-attested application task (`GAMIFICATION.md` §4); checkpoints are reversible and
  gate *activities*, not rewards-for-reading, so there's little incentive to cheat. Keep copy
  supportive, never punitive.
- **R-3 Users expect to read in-app and feel something's missing.** *Mitigation:* clear "read on your
  own (Kindle/print)" framing and onboarding copy; lean into the *doing* value prop; this is the
  deliberate product bet (§3). Track activation/retention to validate.
- **R-4 Losing per-book reading progress on migration.** *Mitigation:* the D-2 backfill maps existing
  completion to a sensible `journeyState` and pre-confirms already-done milestones so no one is
  re-gated; `readProgress` was display-only and is intentionally retired (D-4).
- **R-5 Copyright/ingestion of user text.** *Mitigation:* we **never display** the text and only send
  an excerpt to the model; D-1 (trim on-device cache to `excerpt`) further reduces retention. Import
  copy already says "import material you have the rights to read" (`AddBookView.swift`).
- **R-6 Cross-spec drift.** *Risk:* `0009`/`0011`/`0017`/`0018` assume reading/ingestion. *Mitigation:*
  this spec is the keystone and is sequenced first; §"Cross-spec impact" (below) is explicit and the
  specs link back here.
- **Decisions needed (with recommendations):**
  - **D-1 (recommended: keep full text as a non-displayed generation cache for v1; trim to `excerpt`
    if storage/privacy review prefers).** What to retain of `Book.fullText` once the reader is gone.
  - **D-2 (recommended: backfill journey state + pre-confirm completed milestones).** Migrate
    existing books' reading-centric progress into the new state vs start everyone at `notStarted`.
  - **D-3 (recommended: add a distinct `readGated` lesson state).** Represent "locked because reading
    not confirmed" separately from "locked because prior lesson incomplete," vs reuse `locked`.
  - **D-4 (recommended: hard-remove `readProgress`/`lastReadOffset`).** Remove vs deprecate-and-ignore
    the reading-progress fields.
  - **D-5 (recommended: ship behind `activityFirstEnabled` for one release, then delete the flag +
    dead reader code).** Flagged transition vs straight cutover.
  - **D-6 (defer to `[activities-and-rewards]`):** the actual "what to read next" recommendation logic
    and any new reward tuning — explicitly **out of scope here** (FR-7 ships a simple guided card).

### Cross-spec impact (explicit)
- **`0009-catalog-expansion-100-books.md`** — Catalog becomes the **primary "discover → Start
  journey"** surface (not "read"); its 100-book set should carry per-book **synopses** that enable
  the future hybrid generation (option C, §6.6). Adopt the "Start journey" CTA and no-reader framing.
- **`0011-navigation-and-activity-interaction.md`** — builds the tab/navigation and activity-card UX
  **on top of** this model (journey-state control, milestone checkpoints, "what to read next" as an
  activity). The removed `Route.reader` and any new `Route.readingCheckpoint` must be reflected
  there.
- **`0016-insight-review.md`** — **reinforced, not broken:** review draws from completed lessons and
  needs no in-app reading; the reframe makes review one of several "engaging activities." No change
  required beyond shared framing.
- **`0017-pdf-background-parsing.md`** — reposition: PDF parsing now exists to **ingest text for
  activity generation only** (no reader). The off-main-thread work and `ConnectorService` changes
  stand; just drop any "so the user can read it" rationale.
- **`0018-epub-import.md`** — same reposition: EPUB is a **generation-input connector**, not a
  bring-your-own-**reader**. Keep the connector; reframe its purpose to feed roadmap/activity
  generation.

## 11. Tasks & estimate
1. `JourneyState` enum (`Models/Enums.swift`) + `Book.journeyStateRaw`/`journeyState` accessor;
   remove `readProgress`/`lastReadOffset` (D-4). **(S)**
2. `Milestone.readingConfirmed` + `LessonStatus.readGated` (D-3). **(S)**
3. `JourneyStateMachine` pure transition function. **(S)**
4. `JourneyStateMachineTests` (full table, no-ops, `markFinished`-any, `reopen`). **(M)**
5. Delete `Features/Reader/ReaderView.swift`; remove `Route.reader` + nav arm; fix all references.
   **(S)**
6. `BookDetailView` + `TodayView`: replace reader affordances with journey CTA, "read on your own"
   hint, and a compact **journey-state control** (DesignSystem tokens, haptics). **(M)**
7. `JourneyView`: read-gated gating + milestone **checkpoint card** ("Have you read up to *X*?") with
   confirm → unlock animation. **(M)**
8. `LessonView`: reframe reading phase to recap + "read this section in your book" + "I've read this"
   (never render `fullText`). **(S)**
9. `ReadingCheckpointView` / Today card: **"What to read next?"** activity → routes to Catalog
   (simple guided card; logic deferred). **(M)**
10. `CatalogView`/`CatalogSamples`: relabel to **"Start journey"**, update copy, seed
    `notStarted` → `start` on open. **(S)**
11. One-time **migration backfill** (journey state + pre-confirm completed milestones) on first
    post-update launch (D-2) + migration test. **(M)**
12. Reserve the **sync contract**: add `journeyState` (+ optional confirmed-milestone ids) to
    `LibraryItem` in `openapi.yaml` and `DTOs.swift` (lenient decode) + a DTO decode test. **(S)**
13. Flag `activityFirstEnabled` in `AppSettings` (`Services/Persistence/AppSettings.swift` — follow
    the existing `@Observable` + `UserDefaults` `didSet`/`Keys` pattern at lines 27–28, 70–77;
    default `true`) + manual UX/offline/accessibility pass; update `docs/PRODUCT_ROADMAP.md` /
    `docs/ARCHITECTURE.md` wording away from "immersive reader." **(M)**
14. *(Future, separate)* `[activities-and-rewards]` — activity catalog, "what to read next"
    recommendation logic, reward tuning, and any backend sync of journey state (via `0014`). **(L)**

## 12. References
- **Repo (read for accuracy):** `CLAUDE.md`; `docs/PRODUCT_ROADMAP.md`; `docs/GAMIFICATION.md` (§4
  "turning reading into doing", §1 retrieval practice, §6 ethics); `docs/ARCHITECTURE.md`.
  iOS: `Features/Reader/ReaderView.swift`, `Features/Lesson/{LessonView,ExerciseRunnerView}.swift`,
  `Features/Journey/JourneyView.swift`, `Features/Library/{BookDetailView,LibraryView,AddBookView}.swift`,
  `Features/Catalog/{CatalogView,CatalogSamples}.swift`, `Features/Home/TodayView.swift`,
  `App/{MainTabView,Route,AppModel}.swift`,
  `Models/{Book,RoadmapModels,Enums,UserProfile,CatalogBook}.swift`,
  `Services/AI/{AIService,AIPrompts,RoadmapGenerator,MockAIService,RemoteAIService}.swift`,
  `Services/Gamification/{GamificationEngine,LevelCurve,StreakCalculator}.swift`,
  `Services/Networking/DTOs.swift`. Backend: `src/handlers/{generate_roadmap,library,progress}.py`,
  `src/shared/prompts.py`. Contract: `shared/api/openapi.yaml` (`LibraryItem`, `Progress`).
  **Finding:** generation is grounded in a ≤12k-char excerpt + `{title,author,wordCount}`, **not**
  the full book (`prompts.py` `roadmap_user`; `generate_roadmap.py`; `AIPrompts.swift:60`) — the
  basis for the §6.6 "ingest for generation only" recommendation.
- **Cross-spec (this batch):** `working/0009-catalog-expansion-100-books.md`,
  `working/0011-navigation-and-activity-interaction.md`, `working/0016-insight-review.md`,
  `working/0017-pdf-background-parsing.md`, `working/0018-epub-import.md`; `working/0014-progress-sync.md`
  (owns sync of `journeyState`). Future: `[activities-and-rewards]` (activity types + reward
  mechanics; not designed here).
- **Research (web):**
  - Active learning beats passive reading on retention (≈90% vs ≈20%); doing > watching/listening —
    https://anshadameenza.com/blog/human-development/active-learning-principle/
  - 70:20:10 — ~70% of learning comes from application/experience, ~10% from formal/passive content —
    https://cloudassess.com/blog/70-20-10-model/
  - Interactive > passive (randomized medical-education trial, +0.27 SD on learning) —
    https://www.ncbi.nlm.nih.gov/pmc/articles/PMC11933506/
  - "Read on your own pace, engage in the app" companion model (Fable: read at your own pace or
    follow suggested milestones) —
    https://apps.apple.com/us/app/fable-track-discuss-books/id1488170618
  - Readwise: "an external system for transforming reading into meaningful action and lasting
    insight" (act on what you read, don't re-read) —
    https://blog.readwise.io/reading-workflow-part-1/amp/
  - The contrast Mango is **not**: summary apps (Blinkist/Shortform) trade depth for speed and users
    forget most content within days —
    https://keithjlang.com/book-summary-apps/ ·
    https://transcript.study/blog/best-book-summary-apps
