# 0011 — Navigation cleanup + swipe-based activity interaction

- **Epic:** M11 · **Status:** Draft · **Owner:** unassigned · **Updated:** 2026-06-28
- **Reviewers:** Principal/SD/QA

## 1. Summary
Two coupled changes that finish the activity-first reframe (`0008`) on the surface the
user actually touches. **(1) Navigation cleanup:** drop **Journey** as a top-level tab —
it is redundant now that a journey is *per-book* and already reachable from a book — leaving
a focused four-tab bar **Today · Catalog · Library · Profile**. `JourneyView` survives as a
per-book screen pushed via `Route.journey(Book)` (it already is one — `BookDetailView.swift:75`),
losing only its tab entry. **(2) Engaging activity loop:** replace the current vertically
scrolled, one-exercise-at-a-time `LessonView`/`ExerciseRunnerView` with a **horizontally paged,
card-based activity session** — a deck of full-screen cards (read-checkpoint → quiz → reflection →
application → completion) advanced by a **forward swipe** (or a Continue button), with a top
progress indicator, per-transition haptics, celebratory completion, and a fully equivalent
**non-swipe button path** plus VoiceOver labels and a Reduce-Motion fallback. The grading logic,
the `Roadmap → Milestone → Lesson → Exercise` graph, and `GamificationEngine` are **reused
unchanged**; only the *presentation and advance mechanics* change. We keep the warm,
minimalist Claude aesthetic (cream + terracotta, `DesignSystem/` tokens) and lean more gamified.

## 2. Goals / Non-goals
- **Goals:**
  - **Remove the Journey tab** from `MainTabView` and converge on **Today / Catalog / Library /
    Profile**; keep `JourneyView` reachable as a per-book screen with **no dead routes** and no
    orphaned navigation.
  - Make the per-lesson **activity experience a swipeable card deck**: one card per step, advance
    on **forward (right-to-left / trailing) swipe** with **commit semantics** (you can only advance
    once the current step is satisfied), an always-present **Continue button** doing the same thing,
    a slim **progress indicator**, and **haptics** on each transition and on completion.
  - Provide a **first-class accessibility path**: every swipe has an equivalent button; VoiceOver
    reads step position and exposes a custom "Next" action; **Reduce Motion** swaps the slide/spring
    transitions for a crossfade (or no animation) with identical state behavior.
  - Express the card flow as a **pure, unit-testable state machine** (`ActivitySession` /
    `ActivityStep`) decoupled from SwiftUI, in the spirit of `LevelCurve`/`StreakCalculator`, so the
    advance/commit/skip rules are tested without UI.
  - **Reuse** the existing grading (`ExerciseRunnerView` logic), the gamification calls
    (`GamificationEngine.recordExercise` / `recordLessonCompletion`), and the SwiftData graph — wrap
    them, don't rewrite them.
  - Stay on `DesignSystem/` tokens (`Palette`, `Typo`, `Metrics`, `Haptics`, `Card`, `Tag`,
    `ProgressRing`/a new segmented bar) — no hardcoded hex or magic numbers.
- **Non-goals:**
  - **Not** redefining activity *types* or reward math — XP amounts, new exercise kinds, "what to
    read next" recommendation logic are owned by `0008` (FR-7) and the future
    `[activities-and-rewards]` spec. Here we only render the card flow over the existing kinds
    (`quiz`, `reflection`, `application`) plus the read-checkpoint and completion cards.
  - **Not** building progress sync (`0014`), the Catalog expansion (`0009`), or onboarding redesign
    (`0010`). We only touch navigation + the lesson loop.
  - **Not** changing the **inter-lesson** Journey list UI (the milestone roadmap in `JourneyView`)
    beyond removing its tab and adopting `0008`'s read-gating — the *card deck is intra-lesson*.
  - **Not** removing the Reader or adding the journey-state machine — that is `0008`; this spec
    **depends on** `0008` having landed (or lands alongside it) and references its types.

## 3. Background & context
**Current navigation (`App/MainTabView.swift`).** Five tabs, each a `NavigationStack` with
`.mangoDestinations()`:
```swift
TabView {
    NavigationStack { TodayView().mangoDestinations() }
        .tabItem { Label("Today", systemImage: "sun.max.fill") }
    NavigationStack { CatalogView().mangoDestinations() }
        .tabItem { Label("Catalog", systemImage: "sparkles.rectangle.stack.fill") }
    NavigationStack { LibraryView().mangoDestinations() }
        .tabItem { Label("Library", systemImage: "books.vertical.fill") }
    NavigationStack { JourneyView().mangoDestinations() }     // ← the redundant tab
        .tabItem { Label("Journey", systemImage: "map.fill") }
    NavigationStack { ProfileView().mangoDestinations() }
        .tabItem { Label("Profile", systemImage: "person.fill") }
}
```
**Why Journey-as-tab is wrong now.** Post-`0008`, a "journey" is **a property of a book**, not a
global destination. Evidence in the code today:
- `JourneyView(book: Book? = nil)` already takes an **optional book**, and when used as a tab it
  *guesses* the book: `passedBook ?? books.first { $0.isActive } ?? books.first`
  (`JourneyView.swift:12`). That "guess the active book" behavior is exactly the smell of a screen
  that wants a parameter, not a tab.
- It is **already reachable per-book**: `BookDetailView.swift:75` pushes `Route.journey(book)`.
- The Today tab already surfaces the *continue-the-active-journey* CTA (`TodayView` `continueCard`),
  so the standalone Journey tab duplicates Today's job for the active book and is meaningless for
  any non-active book.

**Current activity loop (`Features/Lesson/`).** `LessonView` is a single `ScrollView` with a
three-value `enum Phase { reading, exercises, summary }`. The `exercises` phase shows **one**
`ExerciseRunnerView` at a time keyed by `index`, and `advance(awardedXP:)` does the gamification
write then `withAnimation { index += 1 }` (a state bump, not a spatial transition). `ExerciseRunnerView`
renders a `Tag` + prompt + (quiz options | free-text `TextEditor`), grades on a **Check/Submit**
button (quiz graded locally, reflection/application via `app.ai.grade(...)`), shows a `feedbackCard`,
then a **Continue** button calls back `onComplete(awardedXP)`. It works, but it reads like a form,
not a game: there is no spatial sense of progress, no swipe, and the "reading" step renders inline
above everything.

**Why now.** `0008` deletes the Reader and reframes the loop as "read on your own → do engaging
activities." The single most-touched screen in that loop is the lesson runner; making it a
**card deck** is the concrete "more gamified, more engaging" payoff the reframe promises, and is the
explicit charter of this spec in `0008` §"Cross-spec impact": *"`0011` builds the tab/navigation and
activity-card UX on top of this model."*

**Research backing the design choices** (full citations in §12):
- Cards are now the dominant unit for learning-loop UIs; Duolingo restructured lesson rewards,
  flashcards, and quest progress as cards/stacks — a validated metaphor for "one focused step at a
  time" [Duolingo card case study; 925studios].
- For SwiftUI the two viable engines are **`TabView(.page)`** (built-in paging, free swipe + a11y
  scroll handling) vs a **custom `ZStack` + `DragGesture`** deck (full control of rotation/throw,
  more a11y wiring to do) — we choose `TabView(.page)` for the linear flow and reserve the custom
  deck only if we later want a "throw the card away" feel [Hacking with Swift; Design+Code].
- **Swipe is undiscoverable on its own** — teams repeatedly find users miss swipe until a visible
  control/affordance + hint is added; the fix is "never rely on the gesture alone, pair it with a
  button and a one-time hint" [LogRocket; IxDF].
- **Accessibility is non-negotiable:** WCAG 2.5.1 requires single-pointer alternatives to path
  gestures; provide visible buttons, expose a VoiceOver custom action / adjustable action for paged
  content, and honor Reduce Motion by replacing motion-heavy transitions [Apple a11y docs;
  accessibilitychecker; Pope Tech].

## 4. User stories
- As a **learner**, I open a lesson and get a **stack of focused cards**; I **swipe forward** to move
  from "read this section" to a quick check to a reflection to an application task to a celebration —
  it feels like a game level, not a worksheet.
- As a **careful user**, I can't accidentally skip ahead: a card only lets me advance once I've
  answered (committed) it, and I always have a clear **Continue** button if I don't want to swipe.
- As a **VoiceOver user**, each card announces "Step 2 of 5, Quick Check," I hear the prompt and
  options, and I use the **"Next" rotor/swipe-up action** to advance — I never need a visual swipe.
- As a **motion-sensitive user** with **Reduce Motion** on, cards **crossfade** instead of sliding
  and nothing springs or rotates, but every step behaves identically.
- As a **returning user**, the bottom tab bar is **Today / Catalog / Library / Profile** — no stray
  "Journey" tab — and I still reach a book's journey by tapping the book.
- As a **first-time swiper**, the very first activity card shows a subtle **"swipe to continue"**
  hint (once), so I learn the gesture without a tutorial wall.

## 5. Requirements
### Functional
- **FR-1 (remove Journey tab).** `MainTabView` renders exactly four tabs — **Today, Catalog,
  Library, Profile** — in that order. The `JourneyView()`-as-tab `NavigationStack` and its
  `.tabItem` are deleted. No `map.fill` tab remains.
- **FR-2 (Journey still reachable, no dead routes).** `Route.journey(Book)` and its
  `.mangoDestinations()` arm **stay**; `JourneyView` keeps working when pushed with a concrete book
  (`BookDetailView.swift:75`). `JourneyView`'s no-arg initializer (`init(book: Book? = nil)`) may be
  kept for previews but is **never** used as a tab root. A repo-wide search confirms `JourneyView()`
  is not instantiated as a tab and there are no navigation links to a now-removed destination.
- **FR-3 (entry to a book's journey is obvious without the tab).** Because the tab is gone, the
  per-book journey must be reachable in ≤1 tap from the book and ≤2 from the active book on Today:
  - **Library → BookDetail** keeps its **"Open journey"** button (`Route.journey(book)`).
  - **Today** `continueCard` gains a secondary **"View journey"** affordance (`Route.journey(book)`)
    in addition to the existing "Start: ‹lesson›" CTA, so the active journey is still one tap from
    Today. (This replaces, in spirit, what the Journey tab did for the *active* book — see §6.2.)
- **FR-4 (card-deck activity session).** A lesson's activities are presented as an **ordered deck of
  full-bleed cards**, one per `ActivityStep`: a **read-checkpoint** card, then one card per ordered
  `Exercise` (`quiz` / `reflection` / `application`), then a **completion** card. The deck is the
  body of the lesson screen (replacing `LessonView`'s `ScrollView`/`Phase` switch).
- **FR-5 (advance-on-forward-swipe + commit semantics).** A **forward swipe** (trailing→leading,
  i.e. the natural "next page" direction; mirrored under RTL) advances to the next card **iff the
  current step is committed** (`step.canAdvance == true`). If not committed, the swipe **rubber-bands
  back** with a gentle `Haptics.warning()` and the card stays. **Backward swipe** returns to a
  previous, already-seen card (read-only review; you cannot un-commit a graded exercise). The
  completion card does not advance further.
- **FR-6 (commit = the existing grading).** "Committed" reuses today's grading exactly:
  - **read-checkpoint:** committed when the user taps **"I've read this section"** (mirrors `0008`
    FR-6).
  - **quiz:** committed after **Check answer** grades locally (correct/incorrect both commit; XP per
    existing rule).
  - **reflection / application:** committed after **Submit** runs `app.ai.grade(kind:prompt:answer:)`
    and feedback returns (mirrors `ExerciseRunnerView.submit()`); offline/Mock path still commits.
  - On commit, the **gamification write** runs once (`GamificationEngine.recordExercise`, guarded by
    the existing `completedAtOpen` "already done" set) exactly as `LessonView.advance` does today.
- **FR-7 (progress indicator).** A slim **segmented progress bar** (one segment per step) sits at the
  top of the deck; the current segment is `Palette.accent`, completed segments filled, upcoming
  segments `Palette.surfaceAlt`. It animates the fill on each advance (respecting Reduce Motion).
  Replaces the linear `ProgressView(value:total:)` currently in `LessonView.exercisePhase`.
- **FR-8 (haptics on transitions).** Forward advance fires `Haptics.tap()` (a light, satisfying
  "page" tick); a correct quiz keeps `Haptics.success()`, incorrect keeps `Haptics.warning()`
  (unchanged from `ExerciseRunnerView`); reaching the completion card fires `Haptics.success()` once;
  a blocked swipe fires `Haptics.warning()`.
- **FR-9 (non-swipe button path — mandatory).** Every card shows a **primary action button** that
  performs the *same* commit/advance the swipe does:
  - uncommitted card → the step's action button (**"I've read this section"** / **"Check answer"** /
    **"Submit"**), styled `.mangoPrimary`, disabled until inputs are valid (`canSubmit` logic reused);
  - committed card → a **"Continue"** button (`.mangoPrimary`) that advances exactly like a forward
    swipe; on the last exercise it reads **"Finish"**.
  The app is **100% operable with zero swipes**. (WCAG 2.5.1 single-pointer requirement.)
- **FR-10 (VoiceOver).** The deck container has `.accessibilityLabel("Activity, step \(i+1) of
  \(n)")` and exposes an `.accessibilityAction(named: "Next")` (and "Previous" when applicable) that
  drives the same advance; alternatively the deck is marked `.accessibilityRepresentation` as an
  **adjustable** element so swipe-up/down increments the step. Each card's prompt, options, and
  feedback are individual accessibility elements with sensible labels (quiz options expose
  `.isButton`; the chosen/correct/incorrect state is in the label, not color-only). The Continue
  button is the VoiceOver-default focus after grading.
- **FR-11 (Reduce-Motion fallback).** When `\.accessibilityReduceMotion` is true, card transitions
  use a **crossfade (opacity)** or **no animation**, never slide/spring/rotation; the segmented
  progress bar fills without spring; the completion celebration uses a static reveal (matches the
  existing `LessonView.summaryPhase` pattern that already gates its spring on `reduceMotion`).
- **FR-12 (one-time swipe hint).** On the **first** activity card of a user's **first** lesson, show
  a subtle, auto-dismissing **"Swipe to continue →"** hint (a `Tag`-styled chip with a gentle nudge
  animation, suppressed under Reduce Motion → static chip). Persist a `hasSeenSwipeHint` flag
  (`@AppStorage`) so it shows once. The hint never blocks input and never shows for VoiceOver users
  (the custom action is the affordance there).
- **FR-13 (completion card).** The final card is the **lesson-complete** celebration: reuses
  `LessonView.summaryPhase` content — checkmark seal, **+XP**, `StreakPill`, optional **Level N!**
  `Tag`, unlocked `AchievementBadgeView`s — with a **Continue** that calls `dismiss()`. Reaching it
  runs `finishLesson()` (the existing `GamificationEngine.recordLessonCompletion` path). If `0008`'s
  "What to read next?" card (FR-7) exists, the completion card may offer a secondary **"What's next"**
  button routing via `Route.readingCheckpoint(book)` — additive, behind the same flag.
- **FR-14 (empty / single-step lessons).** A lesson with **no exercises** is a two-card deck
  (read-checkpoint → completion); the read-checkpoint's button reads **"Mark as done"** (mirrors
  today's `LessonView.readingPhase` `exercises.isEmpty` branch). A deck always has ≥1 content card +
  the completion card.

### Non-functional
- **NFR-1 (no third-party deps; Xcode 16 sync groups).** Pure SwiftUI; new files dropped under
  `ios/Mango/` auto-register — do not hand-edit `project.pbxproj` (`CLAUDE.md` invariants).
- **NFR-2 (offline-first).** First launch with Mock AI + bundled sample must run the full card deck
  offline (reflection/application commit via `MockAIService.grade`). No card depends on a network/key.
- **NFR-3 (design tokens).** All sizes/colors/animations from `Palette`/`Typo`/`Metrics`/`Haptics`;
  reuse `Card`, `Tag`, `ProgressRing`, `MangoPrimaryButtonStyle`; the segmented bar is a new
  DesignSystem component using only tokens.
- **NFR-4 (determinism/testability).** `ActivitySession` advance/commit/back logic is a pure type
  with **no SwiftData and no SwiftUI imports**, unit-tested exhaustively (like `LevelCurveTests`).
- **NFR-5 (performance).** Card transitions hold 60fps on a base iPhone; the deck lazily realizes
  off-screen cards (`TabView` does this) and never re-runs grading on a backward swipe.
- **NFR-6 (touch targets & Dynamic Type).** Action buttons ≥44pt tall (the `.mangoPrimary` 15pt
  vertical padding already clears this); all text via `Typo` so it scales; cards scroll internally if
  content exceeds the viewport at large Dynamic Type sizes.

## 6. Design

### 6.1 Navigation — before / after (the load-bearing diff)
**`App/MainTabView.swift` — BEFORE (5 tabs):**
```swift
struct MainTabView: View {
    var body: some View {
        TabView {
            NavigationStack { TodayView().mangoDestinations() }
                .tabItem { Label("Today", systemImage: "sun.max.fill") }
            NavigationStack { CatalogView().mangoDestinations() }
                .tabItem { Label("Catalog", systemImage: "sparkles.rectangle.stack.fill") }
            NavigationStack { LibraryView().mangoDestinations() }
                .tabItem { Label("Library", systemImage: "books.vertical.fill") }
            NavigationStack { JourneyView().mangoDestinations() }            // ← remove
                .tabItem { Label("Journey", systemImage: "map.fill") }       // ← remove
            NavigationStack { ProfileView().mangoDestinations() }
                .tabItem { Label("Profile", systemImage: "person.fill") }
        }
    }
}
```
**`App/MainTabView.swift` — AFTER (4 tabs):**
```swift
struct MainTabView: View {
    var body: some View {
        TabView {
            NavigationStack { TodayView().mangoDestinations() }
                .tabItem { Label("Today", systemImage: "sun.max.fill") }
            NavigationStack { CatalogView().mangoDestinations() }
                .tabItem { Label("Catalog", systemImage: "sparkles.rectangle.stack.fill") }
            NavigationStack { LibraryView().mangoDestinations() }
                .tabItem { Label("Library", systemImage: "books.vertical.fill") }
            NavigationStack { ProfileView().mangoDestinations() }
                .tabItem { Label("Profile", systemImage: "person.fill") }
        }
    }
}
```
**Decision (D-1): fold journey-tracking into Today + Library rather than add a 5th replacement
surface.** The active journey lives on **Today** (continue CTA + a new "View journey" link); every
book's journey lives one tap deep under **Library → BookDetail → Open journey**. This is the
recommended tab set: **Today / Catalog / Library / Profile.** (Alternative considered: rename Journey
→ "Learn" and keep four content tabs — rejected because it re-introduces the "which book?" ambiguity
that made the tab wrong; see §10 D-1.)

### 6.2 `Route` — unchanged enum, audited links (no dead routes)
`App/Route.swift` is **not modified by this spec** for the Journey change — `Route.journey(Book)`
stays and remains wired:
```swift
enum Route: Hashable {
    case bookDetail(Book)
    case reader(Book)        // removed by 0008 (FR-1) — not by this spec
    case journey(Book)       // ← KEPT; now only reached per-book, never as a tab
    case lesson(Lesson)
}
```
Audit performed for FR-2 (current `Route.*` references):
| Reference | File:line | Action |
|---|---|---|
| `Route.journey(book)` | `BookDetailView.swift:75` | **keep** (primary journey entry) |
| `Route.journey(book)` | *new* on Today `continueCard` | **add** "View journey" (FR-3) |
| `Route.lesson(lesson)` | `JourneyView.swift:92`, `TodayView.swift:100` | unchanged (push lesson runner) |
| `Route.bookDetail(book)` | `JourneyView.swift:25`, `LibraryView.swift:26` | unchanged |
| `Route.reader(book)` | `BookDetailView.swift:93`, `TodayView.swift:105,112` | **removed by `0008`** (coordinate; this spec must not leave them dangling) |
| `JourneyView()` as tab root | `MainTabView.swift:12` | **removed** (FR-1) |

> Coordination note: `0008` removes `Route.reader` and the Today/BookDetail reader buttons. If `0008`
> lands first (recommended), this spec only does the tab deletion + Today "View journey" add. If they
> land together, do both edits to `TodayView`/`BookDetailView` in one pass.

### 6.3 The activity-session model (pure, SwiftData-free) — type sketches
New file `Features/Lesson/ActivitySession.swift` (no `import SwiftUI`, no `import SwiftData`; only
`Foundation`). It models the deck as data + transitions so it is unit-testable.

**Design note (the SwiftData seam).** The real `LessonView` tracks "already done at open" as
`completedAtOpen: Set<Int>` keyed by the **exercise *index*** in `lesson.orderedExercises`
(`LessonView.swift:18,41,123`), not by `PersistentIdentifier`. We keep that index convention so the
pure model never imports SwiftData and the bridge in the view stays a one-liner. `ExerciseRef`
therefore carries the **deck index of the exercise within `orderedExercises`** (`exerciseIndex`) plus
its `kind`; the view resolves `lesson.orderedExercises[ref.exerciseIndex]` back to the `@Model`
`Exercise` when it needs to grade or write. (Using the position is safe because the deck is built
once per open from an immutable ordering and never reorders.)

**Two pieces, separated on purpose.** `ActivityDeck` is a **pure value-type reducer** (a `struct`
with `mutating` transitions — trivially unit-testable like `LevelCurve`/`StreakCalculator`, no
reference identity, no observation). `ActivitySessionModel` is a **thin `@Observable` wrapper** the
SwiftUI view binds to; it holds one `ActivityDeck` and forwards mutations so the view re-renders.
**All advance/commit/back rules live in the pure `ActivityDeck`** and are what the tests exercise;
the wrapper has no logic of its own.

```swift
import Foundation   // ONLY Foundation — no SwiftUI, no SwiftData.

/// One step in a lesson's swipeable activity deck.
enum ActivityStepKind: Equatable {
    case readCheckpoint           // "read this section in your book" (0008 FR-6)
    case exercise(ExerciseRef)    // a quiz / reflection / application, by deck position + kind
    case completion               // the celebration card
}

/// Value-type reference to an exercise by its position in `lesson.orderedExercises`
/// (mirrors LessonView's index-keyed `completedAtOpen`), so the model stays @Model-free.
struct ExerciseRef: Equatable {
    let exerciseIndex: Int         // index into lesson.orderedExercises
    let kind: ExerciseKind         // .quiz / .reflection / .application (existing enum)
}

/// Per-step UI/commit state (separate from the immutable kind).
struct ActivityStep: Identifiable, Equatable {
    let id: Int                    // 0-based position in the deck (stable key for TabView .tag)
    let kind: ActivityStepKind
    var isCommitted: Bool = false  // satisfied → may advance past it
    var awardedXP: Int = 0         // captured at commit (0 if already completed at open)
    /// Forward swipe / Continue allowed only when committed (completion is terminal).
    var canAdvance: Bool { isCommitted && !isCompletionStep }
    var isCompletionStep: Bool { if case .completion = kind { return true } else { return false } }
}

/// PURE reducer over the deck — value type, no SwiftUI/SwiftData, no reference identity.
/// Owns position + commit bookkeeping only; the view owns the @Model writes. This is the
/// unit-tested core (see §8).
struct ActivityDeck: Equatable {
    private(set) var steps: [ActivityStep]
    private(set) var index: Int = 0

    init(steps: [ActivityStep]) {
        precondition(!steps.isEmpty, "a deck always has ≥1 content card + completion")
        self.steps = steps
    }

    var current: ActivityStep { steps[index] }
    var count: Int { steps.count }
    /// 0…1 fill for the segmented bar; a 1-card deck is trivially complete.
    var progress: Double { count <= 1 ? 1 : Double(index) / Double(count - 1) }
    var canGoForward: Bool { index < count - 1 && steps[index].canAdvance }
    var canGoBack: Bool { index > 0 }
    var totalAwardedXP: Int { steps.reduce(0) { $0 + $1.awardedXP } }
    var isAtCompletion: Bool { steps[index].isCompletionStep }

    /// Mark the current step committed (idempotent — a double-commit awards once).
    mutating func commitCurrent(awardedXP xp: Int) {
        guard !steps[index].isCommitted else { return }
        steps[index].isCommitted = true
        steps[index].awardedXP = xp
    }

    /// Forward iff allowed. Returns true if it moved (caller fires Haptics.tap()).
    @discardableResult mutating func advance() -> Bool {
        guard canGoForward else { return false }     // caller fires Haptics.warning() on false
        index += 1
        return true
    }

    /// Back to an already-seen card (read-only review; never un-commits). True if it moved.
    @discardableResult mutating func goBack() -> Bool {
        guard canGoBack else { return false }
        index -= 1
        return true
    }

    /// Pure factory: build a deck from an ordered list of exercise kinds + the set of
    /// already-completed exercise indices (no @Model touched — the view passes plain values).
    static func make(exerciseKinds: [ExerciseKind],
                     alreadyCompleted: Set<Int>) -> ActivityDeck {
        var steps: [ActivityStep] = [ActivityStep(id: 0, kind: .readCheckpoint)]
        for (i, kind) in exerciseKinds.enumerated() {
            let ref = ExerciseRef(exerciseIndex: i, kind: kind)
            // pre-commit steps the user already finished in a prior session (no re-grade/re-award)
            steps.append(ActivityStep(id: steps.count, kind: .exercise(ref),
                                      isCommitted: alreadyCompleted.contains(i)))
        }
        steps.append(ActivityStep(id: steps.count, kind: .completion))
        return ActivityDeck(steps: steps)
    }
}

/// Thin @Observable wrapper the SwiftUI view binds to. NO logic of its own — it forwards to
/// the pure `ActivityDeck` so the view re-renders on change. (Import SwiftUI here, not in the
/// reducer.) Kept in the same file but below an `import SwiftUI` is acceptable; or split into
/// `ActivitySessionModel.swift` to keep the reducer file Foundation-only for the test target.
@Observable final class ActivitySessionModel {
    private(set) var deck: ActivityDeck
    init(deck: ActivityDeck) { self.deck = deck }

    var current: ActivityStep { deck.current }
    var index: Int { deck.index }
    var count: Int { deck.count }
    var canGoForward: Bool { deck.canGoForward }
    var canGoBack: Bool { deck.canGoBack }
    var totalAwardedXP: Int { deck.totalAwardedXP }

    func commitCurrent(awardedXP xp: Int) { deck.commitCurrent(awardedXP: xp) }
    @discardableResult func advance() -> Bool { deck.advance() }
    @discardableResult func goBack() -> Bool { deck.goBack() }
}
```

**State machine (the transitions, in words — what `ActivityDeckTests` pins down).**

| From | Event | Guard | To / effect |
|---|---|---|---|
| step *i* (uncommitted) | `commitCurrent(xp)` | `!isCommitted` | step *i* `isCommitted=true`, `awardedXP=xp` |
| step *i* (committed) | `commitCurrent(xp)` | — (idempotent) | **no change** (award captured once) |
| step *i* | `advance()` | `i<count-1 && canAdvance` | step *i+1*; returns `true` |
| step *i* (uncommitted, non-completion) | `advance()` | guard fails | **no move**; returns `false` (caller warns) |
| completion step | `advance()` | `isCompletionStep` ⇒ `!canAdvance` | **no move**; terminal |
| step *i>0* | `goBack()` | `i>0` | step *i-1*; commit state preserved |
| step 0 | `goBack()` | guard fails | **no move**; returns `false` |

**Building the deck from a `Lesson`** (the only place that touches `@Model`; lives in the view, not
the reducer):
```swift
// In ActivityDeckView.configureSessionAndCelebration():
let kinds  = lesson.orderedExercises.map(\.kind)
let doneAt = Set(lesson.orderedExercises.indices.filter { lesson.orderedExercises[$0].isCompleted })
let session = ActivitySessionModel(deck: .make(exerciseKinds: kinds, alreadyCompleted: doneAt))
// `doneAt` is exactly LessonView's `completedAtOpen` set (LessonView.swift:41) — reused verbatim.
```

### 6.4 The view layer — `ActivityDeckView` (replaces `LessonView` body)
`Features/Lesson/ActivityDeckView.swift`. Recommended engine: **`TabView` with
`.tabViewStyle(.page(indexDisplayMode: .never))`** bound to `session.index`. Rationale (vs custom
`ZStack`+`DragGesture`): paging, lazy card realization, and the implicit VoiceOver scroll handling
come for free; we layer commit-gating on top. We **disable the user's free `TabView` swipe when the
current step can't advance** by intercepting it (see gating note) so commit semantics hold.

```swift
struct ActivityDeckView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver   // suppresses swipe hint (FR-12)
    @Environment(AppModel.self) private var app
    @Query private var profiles: [UserProfile]
    let lesson: Lesson

    @State private var session: ActivitySessionModel
    @State private var completedAtOpen: Set<Int> = []        // exercise indices (mirrors LessonView)
    // celebration/level/achievement state mirrors today's LessonView.summaryPhase 1:1:
    @State private var totalXP = 0
    @State private var unlocked: [Achievement] = []
    @State private var leveledTo: Int?
    @State private var lessonWasComplete = false

    private var profile: UserProfile? { profiles.first }
    private func exercise(_ ref: ExerciseRef) -> Exercise { lesson.orderedExercises[ref.exerciseIndex] }

    var body: some View {
        VStack(spacing: Metrics.gap) {
            SegmentedProgressBar(current: session.index, total: session.count)   // FR-7 (new component)
                .padding(.horizontal, Metrics.padL)
                .padding(.top, Metrics.pad)

            // selection is READ-ONLY (option A, §6.4 gating): setter ignores writes so the page
            // view only animates when WE move session.index via advanceForward()/goBack().
            TabView(selection: Binding(get: { session.index }, set: { _ in })) {
                ForEach(session.deck.steps) { step in
                    ActivityCardView(step: step, lesson: lesson,
                                     resolve: exercise,
                                     onCommit: { xp in commit(awardedXP: xp, for: step) },
                                     onAdvance: advanceForward)
                        .tag(step.id)
                        .padding(Metrics.padL)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85),
                       value: session.index)                  // FR-11: no spring under Reduce Motion
            .highPriorityGesture(forwardSwipeGesture)          // FR-5 commit-gated swipe (option A)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Activity, step \(session.index + 1) of \(session.count)")
            .accessibilityAction(named: "Next") { advanceForward() }     // FR-10
            .accessibilityAction(named: "Previous") { _ = session.goBack() }
        }
        .mangoBackground()
        .navigationTitle(lesson.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { configureSessionAndCelebration() }
    }

    // commit-gated forward swipe: only honor a leading-direction drag past threshold AND canGoForward.
    // `layoutDirection` flips the sign under RTL so "forward" is always the natural next-page direction.
    @Environment(\.layoutDirection) private var layoutDirection
    private var forwardSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let dx = layoutDirection == .rightToLeft ? -value.translation.width
                                                         :  value.translation.width
                if dx < -60 {                                  // forward (trailing→leading)
                    if session.canGoForward { advanceForward() }
                    else { Haptics.warning() }                 // rubber-band, stay (FR-5)
                } else if dx > 60 {                            // backward
                    if session.goBack() { Haptics.soft() }
                }
            }
    }

    private func advanceForward() {
        guard session.canGoForward else { Haptics.warning(); return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85)) {
            _ = session.advance()
        }
        Haptics.tap()                                          // FR-8
        if session.current.isCompletionStep { finishLesson() }  // FR-13
    }

    // called by a card when its step grades/commits; runs the SAME gamification write as
    // LessonView.advance(awardedXP:) (LessonView.swift:119) — guarded by completedAtOpen.
    private func commit(awardedXP: Int, for step: ActivityStep) {
        guard let profile else { return }
        if case let .exercise(ref) = step.kind, !completedAtOpen.contains(ref.exerciseIndex) {
            let outcome = GamificationEngine(context: context)
                .recordExercise(exercise(ref), awardedXP: awardedXP, profile: profile)
            totalXP += awardedXP
            unlocked += outcome.newlyUnlocked
            if let level = outcome.leveledUpTo { leveledTo = level }   // mirrors LessonView.advance
        }
        session.commitCurrent(awardedXP: awardedXP)
        try? context.save()
    }

    private func configureSessionAndCelebration() {
        lessonWasComplete = lesson.isCompleted
        completedAtOpen = Set(lesson.orderedExercises.indices
            .filter { lesson.orderedExercises[$0].isCompleted })       // == LessonView.swift:41
    }

    // verbatim port of LessonView.finishLesson() (LessonView.swift:138) minus the phase switch:
    private func finishLesson() {
        guard let profile else { return }
        let engine = GamificationEngine(context: context)
        if !lessonWasComplete {
            unlocked += engine.recordLessonCompletion(lesson, profile: profile)
        } else if lesson.completedAt == nil {
            lesson.completedAt = .now
        }
        try? context.save()
        Haptics.success()                                              // FR-8 reach-completion
    }
}
```
> `session` is initialized in `configureSessionAndCelebration()` is too late for `@State`; in
> practice build the deck in an `init(lesson:)` (`_session = State(initialValue: …)`) or a
> `@State private var session: ActivitySessionModel?` unwrapped after `.onAppear`. Either is fine —
> the deck is cheap and deterministic. The factory call is the four lines shown at the end of §6.3.
**Gating the built-in swipe (chosen: option A + a sentinel gesture).** `TabView(.page)`'s own
gesture would let the user skip uncommitted cards. We **make the `selection` binding read-only**
(setter ignores writes, see §6.4 body) so the page view only animates when *we* move `session.index`.
We additionally attach `forwardSwipeGesture` as a **`.highPriorityGesture`** so the drag is
interpreted by *our* commit-gated handler before `TabView`'s internal pager consumes it; on a blocked
forward swipe we play `Haptics.warning()` and stay put. (Alternative B — live binding + a
swipe-swallowing `.highPriorityGesture` only when `!canGoForward` — is more fragile across iOS
versions because the live binding still tries to animate; A is cleaner. **Decision D-2: ship A.**)
If A proves flaky under a specific iOS point release, the **reserve** is a custom
`ZStack`+`offset`+`DragGesture` deck (full control, more a11y wiring) — kept out of scope unless
needed.

**`ActivityCardView`** dispatches on `step.kind`, **reuses the existing grading UI** almost verbatim
(see §6.6), and owns the **button path (FR-9)** footer:
```swift
struct ActivityCardView: View {
    let step: ActivityStep
    let lesson: Lesson
    let resolve: (ExerciseRef) -> Exercise     // lesson.orderedExercises[ref.exerciseIndex]
    let onCommit: (Int) -> Void                // parent maps to commit(awardedXP:for: step)
    let onAdvance: () -> Void

    private var isLastExercise: Bool {
        // the next step after this one is the completion card
        if case .exercise = step.kind { return true && step.isCommitted } else { return false }
        // (parent passes the precise "is the following step .completion?" via the deck if preferred)
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 18) {
                switch step.kind {
                case .readCheckpoint:
                    ReadCheckpointCard(lesson: lesson, onRead: { onCommit(0) })   // read = 0 XP
                case let .exercise(ref):
                    ExerciseCard(exercise: resolve(ref), onGraded: { xp in onCommit(xp) })
                case .completion:
                    CompletionCard()       // reads parent's totalXP/streak/level/badges via env or init
                }
                // footer: button path (FR-9) — Continue/Finish when committed, else the card's own
                // action button (rendered INSIDE ReadCheckpointCard/ExerciseCard, disabled until valid).
                if step.isCommitted && !step.isCompletionStep {
                    Button(isLastExercise ? "Finish" : "Continue") { onAdvance() }
                        .buttonStyle(.mangoPrimary)
                        .accessibilitySortPriority(-1)   // visually after content, default VO focus
                }
            }
        }
        // card scrolls internally at large Dynamic Type so the footer button stays reachable (NFR-6)
    }
}
```

**The three sub-cards (where the reuse is concrete):**
```swift
// ReadCheckpointCard — reskin of LessonView.readingPhase (LessonView.swift:45). The recap text +
// "read in your book" framing comes from 0008 FR-6; the button commits the step (no XP).
struct ReadCheckpointCard: View {
    let lesson: Lesson
    let onRead: () -> Void
    var isEmptyLesson: Bool = false           // true → button reads "Mark as done" (FR-14)
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Tag("Read", systemImage: MangoSymbol.bookOutline.name, color: Palette.accent)  // 0013 token
            Text(lesson.readingSummary)
                .font(.system(.body, design: .serif))
                .foregroundStyle(Palette.textPrimary)
            Button(isEmptyLesson ? "Mark as done" : "I've read this section") {
                Haptics.tap(); onRead()
            }
            .buttonStyle(.mangoPrimary)
        }
    }
}

// ExerciseCard — ExerciseRunnerView (ExerciseRunnerView.swift) refactored: keep submit(),
// restoreIfCompleted(), canSubmit, quizOptions, freeText, feedbackCard, borderColor VERBATIM;
// the ONLY changes are (1) drop the in-card "Continue" button (the deck footer owns advance),
// and (2) rename the callback onComplete(Int) → onGraded(Int) fired from complete().
struct ExerciseCard: View {
    @Environment(AppModel.self) private var app
    let exercise: Exercise
    let onGraded: (Int) -> Void
    // …identical @State (chosen/answer/grading/graded/feedback/awardedXP/score)…
    // body: Tag + prompt + (quizOptions | freeText) + (graded ? feedbackCard : submitButton)
    //   — submit() unchanged; on `graded`, call complete() which persists fields and calls onGraded(xp).
}

// CompletionCard — verbatim move of LessonView.summaryPhase (LessonView.swift:79). Seal + "+XP"
// + StreakPill + optional "Level N!" Tag + AchievementBadgeViews + Continue → dismiss(). Under
// Reduce Motion the seal reveals statically (the `reduceMotion ? nil` guard already there).
struct CompletionCard: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let totalXP: Int; let streakDays: Int; let leveledTo: Int?; let unlocked: [Achievement]
    // …exactly the VStack from summaryPhase; Button("Continue") { dismiss() }…
    // Optional (behind 0008 FR-7 flag): secondary Button("What's next") → Route.readingCheckpoint(book)
}
```

### 6.5 New DesignSystem component — `SegmentedProgressBar`
Add to `DesignSystem/Components.swift` (tokens only; mirrors `XPBar`'s Reduce-Motion handling):
```swift
struct SegmentedProgressBar: View {
    let current: Int          // 0-based index of the active step
    let total: Int            // step count
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<max(1, total), id: \.self) { i in
                Capsule()
                    .fill(i <= current ? Palette.accent : Palette.surfaceAlt)
                    .frame(height: 6)
                    .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85),
                               value: current)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress")
        .accessibilityValue("Step \(current + 1) of \(total)")
    }
}
```

### 6.6 Mapping the current Lesson UI to the card loop — reused vs replaced
| Today (`Features/Lesson/`) | Fate | In the card loop |
|---|---|---|
| `LessonView` `enum Phase {reading, exercises, summary}` + `ScrollView` | **Replaced** | by `ActivityDeckView` + `ActivitySessionModel` (deck of cards) |
| `LessonView.readingPhase` (read card + "Practice"/"Mark as done") | **Reused (reskinned)** | becomes the **read-checkpoint card**; "I've read this section" commits it (`0008` FR-6) |
| `LessonView.exercisePhase` (`ProgressView` + one `ExerciseRunnerView` keyed by `index`) | **Replaced** | the paged deck; `ProgressView` → `SegmentedProgressBar` |
| `LessonView.summaryPhase` (seal, +XP, `StreakPill`, level `Tag`, badges, Continue→dismiss) | **Reused (moved)** | becomes the **completion card** (`CompletionCard`), verbatim content |
| `LessonView.advance(awardedXP:)` / `finishLesson()` / `completedAtOpen` guard | **Reused** | called by `commit(...)` / on reaching completion (same `GamificationEngine` calls) |
| `ExerciseRunnerView` (Tag + prompt + quiz/free-text + grade + feedback + Continue) | **Reused (refactored)** | extract its **grading body** into `ExerciseCard`; drop its own "Continue" (the deck owns advance) and call `onGraded(xp)` instead of `onComplete` |
| `ExerciseRunnerView.submit()` / `restoreIfCompleted()` / `canSubmit` / quiz vs `app.ai.grade` | **Reused verbatim** | unchanged grading; only the *callback name* and the *advance affordance* move out |
| `GamificationEngine`, `Roadmap/Milestone/Lesson/Exercise`, `app.ai.grade` | **Untouched** | wrapped, not modified |

Net: **logic is reused; only the container (scroll→deck) and the advance affordance (button→swipe+button)
change.** `ExerciseRunnerView` is refactored into `ExerciseCard` (a thin rename + callback change) so
the well-tested grading code is preserved.

### 6.7 Accessibility design (consolidated)
- **Buttons mirror swipes (FR-9):** every advance is reachable by a visible `.mangoPrimary` button;
  the app passes "operable without the gesture" (WCAG 2.5.1).
- **VoiceOver (FR-10):** deck announces step position; custom **"Next"/"Previous"** actions advance;
  quiz options are buttons whose label encodes selected/correct/incorrect (never color alone — the
  palette comment already mandates "always paired with an icon or label"); after grading, focus moves
  to the Continue button.
- **Reduce Motion (FR-11):** `.transition(.opacity)` and `nil` animations replace slide/spring;
  completion seal reveals statically (as `summaryPhase` already does).
- **One-time hint (FR-12):** non-VoiceOver, non-Reduce-Motion only; `@AppStorage("hasSeenSwipeHint")`.
  Concrete sketch (overlaid on the first content card only, auto-dismiss after ~3s):
  ```swift
  struct SwipeHintChip: View {
      @Environment(\.accessibilityReduceMotion) private var reduceMotion
      @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
      @AppStorage("hasSeenSwipeHint") private var seen = false
      @State private var nudge = false
      @State private var visible = false
      var body: some View {
          Group {
              if visible {
                  HStack(spacing: 6) {
                      Text("Swipe to continue")
                      Image(systemName: MangoSymbol.chevron.name)   // 0013: chevron.right
                  }
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(Palette.textSecondary)
                  .padding(.horizontal, 12).padding(.vertical, 7)
                  .background(Palette.surfaceAlt, in: Capsule())
                  .offset(x: reduceMotion ? 0 : (nudge ? -6 : 0))   // gentle nudge; static under RM
                  .animation(reduceMotion ? nil :
                      .easeInOut(duration: 0.7).repeatCount(3, autoreverses: true), value: nudge)
                  .transition(.opacity)
              }
          }
          .onAppear {
              guard !seen, !voiceOver else { return }               // never for VoiceOver/seen
              visible = true; nudge = true
              Task { try? await Task.sleep(for: .seconds(3)); withAnimation { visible = false }; seen = true }
          }
          .accessibilityHidden(true)   // the custom "Next" action is the affordance for VoiceOver
      }
  }
  ```
- **Targets/Dynamic Type (NFR-6):** `.mangoPrimary` already ≥44pt (15pt vertical padding,
  `Components.swift:12`); all text via `Typo`; cards scroll internally at large sizes.

### 6.9 Files to add / change (Xcode 16 sync groups — new files auto-register)
| Path | Action | Notes |
|---|---|---|
| `ios/Mango/App/MainTabView.swift` | **edit** | remove the Journey `NavigationStack`+`.tabItem` → 4 tabs (FR-1) |
| `ios/Mango/Features/Home/TodayView.swift` | **edit** | add "View journey" (`Route.journey(book)`) to `continueCard`; coordinate `0008` reader-button removal at lines 105–115,112 (FR-3) |
| `ios/Mango/App/Route.swift` | **audit only** | `Route.journey(Book)` unchanged; confirm no dead arms (FR-2). `0008` removes `.reader` |
| `ios/Mango/Features/Lesson/ActivitySession.swift` | **add** | `ActivityStepKind`, `ExerciseRef`, `ActivityStep`, **pure** `ActivityDeck`, `@Observable ActivitySessionModel` (§6.3) |
| `ios/Mango/Features/Lesson/ActivityDeckView.swift` | **add** | the deck container + gating + haptics + a11y actions (§6.4); becomes `Route.lesson` destination |
| `ios/Mango/Features/Lesson/ActivityCardView.swift` | **add** | dispatch + button-path footer + `SwipeHintChip` (§6.4, §6.7) |
| `ios/Mango/Features/Lesson/ReadCheckpointCard.swift` | **add** | reskin of `readingPhase` (§6.6); aligns with `0008` FR-6 |
| `ios/Mango/Features/Lesson/ExerciseCard.swift` | **add** (refactor) | `ExerciseRunnerView` body moved here; `onComplete`→`onGraded`, drop in-card Continue (§6.6) |
| `ios/Mango/Features/Lesson/CompletionCard.swift` | **add** | verbatim `summaryPhase` content (§6.6) |
| `ios/Mango/Features/Lesson/ExerciseRunnerView.swift` | **delete (deferred)** | remove once the deck flag is permanent (§9 teardown) |
| `ios/Mango/Features/Lesson/LessonView.swift` | **keep then delete** | kept behind the flag; deleted at teardown (§9) |
| `ios/Mango/App/Route.swift` (`mangoDestinations`) | **edit** | point `.lesson` at `ActivityDeckView` behind the flag (Task 11) |
| `ios/Mango/DesignSystem/Components.swift` | **edit** | add `SegmentedProgressBar` (§6.5) |
| `ios/MangoTests/ActivityDeckTests.swift` | **add** | pure-reducer coverage (§8) — imports `Foundation` + `@testable import Mango`, no SwiftUI/SwiftData |
| `docs/ARCHITECTURE.md` / screenshots | **edit** | navigation = 4 tabs; lesson loop = swipe deck (Task 13) |

### 6.8 Flow diagram
```
LESSON OPENS
   │
   ▼
[ Read-checkpoint card ]  "Read this section in your book" + recap(readingSummary)
   │  tap "I've read this section"  ─────────────────────────────► commit ✓
   │  swipe ← / Continue  (gated: only if committed)
   ▼
[ Quick Check card ]  prompt + options → "Check answer" (local grade) ─► commit ✓ (+XP)
   │  swipe ← / Continue
   ▼
[ Reflect card ]  prompt + TextEditor → "Submit" (app.ai.grade) ─► commit ✓ (+XP)
   │  swipe ← / Continue
   ▼
[ Apply It card ]  prompt + TextEditor → "Submit" (app.ai.grade) ─► commit ✓ (+XP)  ["Finish"]
   │  swipe ← / Finish
   ▼
[ Completion card ]  ✔ seal · +totalXP · streak · Level N! · badges · "Continue"→dismiss()
                     (reaching it runs recordLessonCompletion; optional "What's next" → 0008 FR-7)

Backward swipe → review a previous card (read-only). Uncommitted forward swipe → rubber-band + warn.
Reduce Motion → crossfade, no spring/rotation. VoiceOver → "Next"/"Previous" actions instead of swipe.
```

## 7. Acceptance criteria
- [ ] **AC-1 (Journey tab gone):** `MainTabView` shows exactly **Today, Catalog, Library, Profile**;
      a repo search finds **no** `JourneyView()` instantiated as a tab and **no** `map.fill` tab item.
      *(Build + grep + manual: launch shows 4 tabs.)*
- [ ] **AC-2 (no dead routes):** `Route.journey(Book)` still resolves; **Library → BookDetail → Open
      journey** and **Today → View journey** both push `JourneyView(book:)` and render; no
      `NavigationLink`/`navigationDestination` points at a removed destination; `make ios-test`
      green. *(Manual nav walk + grep of `Route.` references.)*
- [ ] **AC-3 (card deck exists):** opening a lesson presents a horizontally paged deck — read-checkpoint
      → one card per ordered exercise → completion — not the old single `ScrollView`. *(Manual.)*
- [ ] **AC-4 (forward swipe advances, gated):** a forward swipe on a **committed** card advances and
      fires `Haptics.tap()`; on an **uncommitted** card it rubber-bands, stays, and fires
      `Haptics.warning()`. *(Manual + `ActivitySessionModelTests` for `advance()`/`canGoForward`.)*
- [ ] **AC-5 (commit = grading, single award):** quiz commits on **Check answer**, reflection/application
      on **Submit** (Mock offline included); the gamification write runs **once** per exercise (guarded
      by `completedAtOpen`); XP/level/achievement outcomes match the pre-refactor `LessonView`.
      *(Unit on the commit path + manual XP check.)*
- [ ] **AC-6 (button path, no swipe needed):** the entire lesson can be completed using only the
      on-card **action/Continue/Finish** buttons — zero swipes — with identical end state. *(Manual
      with swipe deliberately unused; VoiceOver-style operation.)*
- [ ] **AC-7 (progress indicator):** a `SegmentedProgressBar` reflects current step / total and
      advances each transition. *(Manual + snapshot.)*
- [ ] **AC-8 (VoiceOver):** with VoiceOver on, the deck announces "step i of n," exposes a **Next**
      (and Previous) action that advances, options are buttons with state in their labels, and focus
      lands on Continue after grading. *(Manual VoiceOver pass.)*
- [ ] **AC-9 (Reduce Motion):** with Reduce Motion on, transitions **crossfade** with no
      spring/slide/rotation, the progress bar fills without spring, and the completion seal is static;
      all steps still advance and commit. *(Manual with Reduce Motion on.)*
- [ ] **AC-10 (completion parity):** the completion card shows +totalXP, streak, level-up tag, and
      unlocked badges, and `dismiss()` returns to the journey with the lesson marked complete —
      matching today's `summaryPhase`. *(Manual + state check.)*
- [ ] **AC-11 (empty lesson):** a lesson with no exercises is read-checkpoint → completion with a
      "Mark as done" button; completes correctly. *(Unit on `ActivitySessionModel.make` + manual.)*
- [ ] **AC-12 (one-time hint):** the swipe hint appears once on the first activity card ever, then
      never again (`hasSeenSwipeHint`), and is suppressed for Reduce-Motion/VoiceOver. *(Manual,
      fresh install + relaunch.)*
- [ ] **AC-13 (offline-first):** fresh install, Mock AI, no network/key: the sample lesson's full
      deck (incl. reflection/application commits) runs offline. *(Manual offline run — `CLAUDE.md`
      invariant.)*

## 8. Test plan
- **Unit (automated — pure logic, like `LevelCurveTests`/`StreakCalculatorTests`):**
  **`ActivityDeckTests`** (imports `Foundation` + `@testable import Mango` only — **no SwiftUI/
  SwiftData**, because `ActivityDeck` imports neither). Named cases mapped to ACs:
  | Test | Asserts | AC |
  |---|---|---|
  | `test_make_deckShape` | `make(exerciseKinds: [q,r,a], alreadyCompleted: [])` → 5 steps: readCheckpoint, 3 exercises, completion | AC-3 |
  | `test_make_emptyLesson_twoCards` | `make(exerciseKinds: [], …)` → `[readCheckpoint, completion]` (count 2) | AC-11 |
  | `test_make_preCompletedStartCommitted` | indices in `alreadyCompleted` → those steps `isCommitted == true` | AC-5 |
  | `test_advance_blockedWhenUncommitted` | `advance()` on uncommitted read step returns `false`, `index` unchanged | AC-4 |
  | `test_advance_allowedAfterCommit` | `commitCurrent(0)` then `advance()` returns `true`, `index == 1` | AC-4 |
  | `test_completionIsTerminal` | at completion, `canGoForward == false`, `advance()` returns `false` | AC-3 |
  | `test_goBack_bounds_andPreservesCommit` | `goBack()` at 0 → `false`; after back, a previously-committed step stays committed | AC-4 |
  | `test_commit_idempotent_awardsOnce` | two `commitCurrent(10)` calls → `totalAwardedXP` counts 10 once | AC-5 |
  | `test_progress_math` | `progress` is `index/(count-1)`; 1-card deck → 1.0 | AC-7 |
- **Unit (commit→gamification bridge, model-container backed like existing `GamificationEngine`
  tests):** assert committing an exercise step calls `recordExercise` exactly once, and that
  re-entering an already-completed lesson (all indices in `completedAtOpen`) awards 0 and still
  reaches completion via `finishLesson()` without a second `recordLessonCompletion` (guarded by
  `lessonWasComplete`).
- **iOS UI (manual):** the AC-3…AC-13 walkthroughs — swipe forward/back, gated rubber-band,
  button-only completion, VoiceOver "Next"/"Previous", Reduce-Motion crossfade, Dynamic Type XXL
  (cards scroll), one-time hint, offline Mock run; plus the **navigation** walk (4 tabs; journey via
  BookDetail and Today; no dead links).
- **Regression:** `make ios-test` stays green (grading, gamification, roadmap-graph, DTO decode are
  untouched). Backend `pytest` + `cdk synth` unaffected (no backend change).
- **What's automated vs hand-verified:** the **state machine** and the **commit→award bridge** are
  automated; **gesture feel, VoiceOver, Reduce-Motion, haptics, and visual polish** are manual
  (SwiftUI gesture/animation behavior isn't unit-testable without UITests, which this repo doesn't
  run in CI).

## 9. Rollout & migration
- **No data migration.** This spec changes presentation + navigation only; the SwiftData schema is
  unchanged (the `0008` schema additions are that spec's concern). `ActivitySessionModel` is built
  fresh from the existing `Lesson` graph on each open.
- **Flag:** reuse `0008`'s `activityFirstEnabled` (or a sibling `swipeActivityEnabled`) so the deck
  ships behind a flag for one release. With the flag **off**, `LessonView` (old) is the lesson root
  and the Journey tab change can still ship independently (the tab removal is low-risk and can be
  unflagged). With it **on**, `Route.lesson` resolves to `ActivityDeckView`. Recommend: unflag the
  **tab removal** immediately; flag the **card deck** for one release, then delete `LessonView`/
  `ExerciseRunnerView`'s replaced parts.
- **Backward compatibility:** the lesson runner is reachable only via `Route.lesson(Lesson)`; swapping
  its destination view (old `LessonView` → `ActivityDeckView`) in `mangoDestinations()` is a localized
  change with no callers to update. The Journey tab removal touches only `MainTabView` + one Today
  link; rolling back is reverting those two files.
- **Sequencing:** land **after/with `0008`** (read-checkpoint copy, `Route.reader` removal, optional
  `Route.readingCheckpoint`). Coordinate the `TodayView` edits so reader-button removal (`0008`) and
  the "View journey" add (this spec) happen together if both land in the same release.
- **Teardown:** once the deck flag is permanently on, delete the old `LessonView` `Phase`
  scroll-based body and fold any still-needed helpers into `ActivityDeckView`/`CompletionCard`.

## 10. Risks & open decisions
- **R-1 (TabView page-style fights commit-gating).** `.page` owns its own swipe; a live `selection`
  binding could let users skip uncommitted cards. *Mitigation:* §6.4 option **A** — read-only binding
  + our own `DragGesture`/buttons drive `index`; fall back to a custom `ZStack`+`DragGesture` deck
  only if A proves flaky. *(Decision **D-2**: recommend A; reserve custom deck.)*
- **R-2 (swipe undiscoverable).** Users may not realize cards swipe. *Mitigation:* FR-12 one-time
  hint + the always-visible Continue button means discovery isn't required to progress (research:
  pair gesture with a visible control). 
- **R-3 (VoiceOver + paged custom gestures are finicky).** Custom drag + `TabView` can confuse the
  rotor. *Mitigation:* rely on the **button path** as the primary VoiceOver affordance and the
  explicit `.accessibilityAction(named:)`; treat the visual swipe as a sighted-user enhancement.
- **R-4 (losing the Journey tab hurts findability of non-active books' journeys).** *Mitigation:*
  Library → BookDetail → "Open journey" is the canonical path (one tap from the book), Today links
  the active journey; both are explicit ACs. Track whether users still reach journeys post-change.
- **R-5 (regressing well-tested grading during the `ExerciseRunnerView` → `ExerciseCard` refactor).**
  *Mitigation:* keep the grading body byte-for-byte where possible; only rename the completion
  callback and remove the in-card Continue; manual quiz/reflection/application pass + existing tests.
- **Decisions needed (with recommendations):**
  - **D-1 (recommended: Today / Catalog / Library / Profile; fold journey-tracking into Today +
    Library).** The new tab set after dropping Journey. *(Alt: rename Journey→"Learn" — rejected,
    re-introduces "which book?" ambiguity.)*
  - **D-2 (recommended: `TabView(.page)` with a read-only selection binding + our own
    swipe/buttons).** Paging engine. *(Alt: custom `ZStack`+`DragGesture` deck — more control, more
    a11y wiring; hold in reserve.)*
  - **D-3 (recommended: backward swipe = read-only review, no un-commit).** Whether users can go back
    and whether going back can change a graded answer. *(Recommend: review only; graded state is
    immutable, matching `restoreIfCompleted`.)*
  - **D-4 (recommended: reuse `0008`'s `activityFirstEnabled`, unflag tab removal immediately).**
    Flagging strategy.
  - **D-5 (defer):** richer "throw the card away" physics, swipe-to-skip-optional-steps, or per-kind
    card theming — out of scope; revisit with `[activities-and-rewards]`.

## 11. Tasks & estimate
1. `MainTabView`: remove the Journey tab → 4 tabs (Today/Catalog/Library/Profile). **(S)**
2. `TodayView.continueCard`: add **"View journey"** (`Route.journey(book)`) secondary affordance;
   coordinate with `0008`'s reader-button removal in the same file. **(S)**
3. Audit/confirm no dead routes: `Route.journey` only reached per-book; grep `Route.*` and
   `JourneyView()`; keep `JourneyView`'s preview-only no-arg init. **(S)**
4. `ActivitySession.swift` — `ActivityStepKind`, `ExerciseRef`, `ActivityStep`, **pure**
   `ActivityDeck` (+ `make(exerciseKinds:alreadyCompleted:)`), and the `@Observable`
   `ActivitySessionModel` wrapper. Reducer file imports `Foundation` only. **(M)**
5. `ActivityDeckTests` — the nine named cases in §8 (deck shape, empty, pre-completed, advance gating,
   terminal completion, goBack bounds, idempotent commit, progress math). **(M)**
6. `SegmentedProgressBar` in `DesignSystem/Components.swift` (tokens + Reduce-Motion). **(S)**
7. Refactor `ExerciseRunnerView` → `ExerciseCard`: extract grading body, swap `onComplete` →
   `onGraded(xp)`, drop in-card Continue (deck owns advance); keep `submit`/`restoreIfCompleted`/
   `canSubmit` verbatim. **(M)**
8. `ReadCheckpointCard` (recap + "read in your book" + "I've read this section" → commit) — aligns
   with `0008` FR-6. **(S)**
9. `CompletionCard` — move `LessonView.summaryPhase` content (seal/+XP/streak/level/badges/Continue);
   optional "What's next" → `Route.readingCheckpoint` if `0008` FR-7 exists. **(M)**
10. `ActivityDeckView` — `TabView(.page)` + read-only binding + commit-gated `DragGesture` + buttons +
    haptics + VoiceOver actions + Reduce-Motion transition; wire `commit`/`finishLesson` to
    `GamificationEngine`. **(L)**
11. Point `Route.lesson` at `ActivityDeckView` (behind the flag) in `mangoDestinations()`; keep old
    `LessonView` until the flag is permanent. **(S)**
12. One-time **swipe hint** (`@AppStorage("hasSeenSwipeHint")`, suppressed for RM/VoiceOver). **(S)**
13. Manual a11y/offline/Dynamic-Type/haptics pass; update `docs/` (navigation = 4 tabs; lesson loop =
    swipe deck) and any screenshots. **(M)**

## 12. References
- **Repo (read for accuracy):**
  - `ios/Mango/App/MainTabView.swift` (5 tabs incl. `Label("Journey", systemImage: "map.fill")`),
    `ios/Mango/App/Route.swift` (`enum Route { bookDetail, reader, journey, lesson }` + `MangoDestinations`
    `.mangoDestinations()`), `ios/Mango/Features/Journey/JourneyView.swift` (`init(book: Book? = nil)`;
    `passedBook ?? books.first { $0.isActive }`; reached via `Route.journey` from BookDetail),
    `ios/Mango/Features/Lesson/LessonView.swift` (`enum Phase {reading, exercises, summary}`,
    `advance(awardedXP:)`, `finishLesson()`, `completedAtOpen`, `summaryPhase`),
    `ios/Mango/Features/Lesson/ExerciseRunnerView.swift` (`submit()`, `restoreIfCompleted()`,
    `canSubmit`, quiz-local vs `app.ai.grade`, `onComplete`), `ios/Mango/Features/Home/TodayView.swift`
    (`continueCard`, `Route.lesson`/`Route.reader` links),
    `ios/Mango/Features/Library/BookDetailView.swift:75` (`Route.journey(book)`),
    `ios/Mango/DesignSystem/{Components.swift (Card, Tag, ProgressRing, XPBar, StreakPill,
    MangoPrimaryButtonStyle), Haptics.swift (tap/soft/rigid/success/warning/selection),
    Theme.swift (Palette, Metrics), Typography.swift (Typo)}`,
    `ios/Mango/Models/{RoadmapModels.swift (Roadmap/Milestone/Lesson/Exercise; orderedExercises;
    persistentModelID; isCompleted), Enums.swift (ExerciseKind {quiz, reflection, application};
    LessonStatus {locked, available, completed})}`.
  - **Keystone dependency:** `working/0008-product-reframe-activity-first.md` (read-checkpoint copy
    FR-6; `Route.reader` removal FR-1; optional `Route.readingCheckpoint` FR-7; `activityFirstEnabled`
    flag). This spec is sequenced **after/with** `0008`.
- **Cross-spec:** `0009` (Catalog), `0010` (onboarding), `0014` (sync), `0016` (insight review),
  future `[activities-and-rewards]` (activity types + rewards — not designed here).
- **Research (web — verified 2026-06):**
  - **`TabView(.page)` carries paged-VoiceOver semantics for free.** With `.tabViewStyle(.page)`
    VoiceOver announces "page X of Y" and the **page trait** routes swipe-to-scroll through the
    parent's `.accessibilityScrollAction(_:)` — confirming our plan to keep `TabView` and add explicit
    `.accessibilityAction(named:)` as the deterministic affordance —
    https://developer.apple.com/documentation/swiftui/view/accessibilityscrollaction(_:) ·
    https://www.hackingwithswift.com/quick-start/swiftui/how-to-create-scrolling-pages-of-content-using-tabviewstyle ·
    https://swiftwithmajid.com/2021/04/15/accessibility-actions-in-swiftui/
  - **WCAG 2.5.1 (Pointer Gestures, Level A): every path-based gesture needs a single-pointer
    alternative.** Swipe-to-advance therefore *requires* the visible Continue/Finish button path
    (FR-9); the carousel "Previous/Next buttons" remedy is exactly our model —
    https://www.w3.org/WAI/WCAG22/Understanding/pointer-gestures.html ·
    https://www.wcag.com/developers/2-5-1-pointer-gestures/
  - **Swipe is undiscoverable without a visible affordance/hint; pair the gesture with a control and a
    one-time hint.** Real teams find users miss swipe until a visible icon/onboarding hint is added,
    and "for every animation, an equal and opposite gesture" — backing FR-12's nudge + always-present
    button — https://uxplanet.org/affordance-is-like-the-silent-guide-that-whispers-to-users-showing-them-where-to-tap-swipe-or-a6dcdda716f9 ·
    https://dfeldman.medium.com/for-every-animation-an-equal-and-opposite-gesture-abad4150c91e
  - **Cards as the universal learning-loop unit** (Duolingo restructured lesson rewards/flashcards/
    quests as cards) — validating the deck metaphor —
    https://medium.com/product-powerhouse/duolingo-just-made-everything-a-card-heres-the-pm-case-study-82694805ca13 ·
    https://www.925studios.co/blog/duolingo-design-breakdown
  - **SwiftUI paging vs custom deck** (reserve option): `TabView(.page)` vs `ZStack`+`DragGesture`+
    `offset`/rotation for "throw" cards —
    https://www.hackingwithswift.com/books/ios-swiftui/moving-views-with-draggesture-and-offset ·
    https://designcode.io/swiftui-handbook-tab-view-pagination/
