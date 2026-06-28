# 0008 — Activity-first product reframe · ROADMAP

> **Status:** Planned (grilled 2026-06-28) · **Epic:** M11 (keystone) · **Owner:** unassigned
> **Source spec:** [`../0008-product-reframe-activity-first.md`](../0008-product-reframe-activity-first.md)
> **Glossary:** [`/CONTEXT.md`](../../CONTEXT.md) · **Decisions:** [`ADR-0001`](../../docs/adr/0001-remove-in-app-reader.md), [`ADR-0002`](../../docs/adr/0002-journey-state-orthogonal-to-activity-gating.md), [`ADR-0003`](../../docs/adr/0003-reading-as-first-class-activity.md)

> ⚠️ **Amended 2026-06-28 — reading is now a first-class activity ([ADR-0003](../../docs/adr/0003-reading-as-first-class-activity.md)).**
> The **milestone-level passive Reading Checkpoint** below (D1/D9, §3.2 `readGated`, §4.3, slices
> A2/C1, FR-5, AC-5) is **superseded**: reading confirmation is now an `ExerciseKind.reading`
> activity that leads every lesson (`order 0`) and gates that lesson's practice — finer and
> active, not a per-milestone gate. `JourneyState` (book lifecycle, slice 1, shipped) and
> ADR-0002 are unaffected. Where this roadmap describes the milestone checkpoint, read it as
> "per-lesson reading activity." The migration backfill (§5/E1) prepends a reading activity per
> lesson (from `readingSummary`) instead of pre-confirming milestones.

This roadmap supersedes the spec's §11 task list. It reflects the decisions reached in the
`/grill-with-docs` session, where the spec was stress-tested against the real codebase and
several contradictions/gaps were resolved. Read this, [CONTEXT.md](../../CONTEXT.md), and the
two ADRs before implementing.

---

## 1. What we're building (one paragraph)

Mango **is not a reading app**. We delete the in-app Reader entirely and reframe the product
around *doing*: users read the real book on their own, then inside Mango they confirm
reading checkpoints and do the active-learning loop (quizzes, reflections, application
tasks). A `Book` gains a user-controlled **Journey State** (`notStarted → reading →
finished`); each `Milestone` gains a self-confirmed **Reading Checkpoint** that **gates all
of its lessons** (including the first milestone). "What to read next?" becomes an activity
card. The Catalog becomes "discover → Start journey." Generation is unchanged (it already
grounds on a ≤12k-char excerpt, not in-app reading).

---

## 2. Decisions locked in grilling (deltas from the spec)

These are binding. Where they differ from the spec text, **this roadmap wins**.

| # | Area | Decision | Rationale / spec contradiction fixed |
|---|---|---|---|
| D1 | Read-gate scope | **Gate everything** — every milestone read-gated, incl. M1 | Product bet: read-first leads, even first-run |
| D2 | Sample first-run | Sample seeds `notStarted`, **fully gated** (no exception) | Consistency; onboarding (0010) preps it. AC-9 holds — confirm tap is offline |
| D3 | State machine | **5 events**: add `confirmReadingCheckpoint` (`notStarted→reading`) | Under D1, confirming the first checkpoint is the earliest reading signal; sample never hits Catalog's `start` |
| D4 | Migration backfill | Pre-confirm milestones with **≥1 completed lesson** (`contains`, not `allSatisfy`) | Spec's rule re-gated in-progress users — contradicted its own R-4 |
| D5 | `fullText` (D-1) | **Keep as non-displayed generation cache** (spec option A) | Dropping it breaks offline-first + Direct-Claude + Catalog gen (verified vs all 3 AI services). → ADR-0001 |
| D6 | Milestone identity | Add **`Milestone.stableId: String`** (UUID at build, backfilled); `confirmedMilestones` references it | `persistentModelID` is device-local, can't sync |
| D7 | First-activity nudge | Fire `firstActivityCompleted` in **`LessonView.finishLesson`** | Keeps `GamificationEngine` pure of journey concerns; now a backstop |
| D8 | Gating testability | Extract pure **`JourneyGating.status(...)`** | Spec's `status(_:)` is a nested closure — untestable; AC-5 needs a pure helper |
| D9 | Read-gated render | Lessons **visible + non-tappable**, checkpoint card above | Matches §6.2; shows the reward to motivate confirm |
| D10 | Flag (D-5) | **No flag — straight cutover** | `activityFirstEnabled` can't "revert to reader" when FR-1 deletes it — incoherent |
| D11 | State ⊥ gating | **Journey State and activity-gating are orthogonal**; "What to read next?" keys off `roadmap.progress == 1` (not `journeyState`) | Refused to couple them; → ADR-0002 |
| D12 | Today CTA | **Read-gate-aware**: routes to `Route.journey` when next lesson is gated, deep-links `Route.lesson` only when `.available` | Today bypassed the checkpoint on the home tab — defeated D1 |
| D13 | FR-7 routing | Add a **minimal `TabView` selection binding** so "Find my next book" switches to Catalog | No selection binding exists; 0011 builds on it |
| D14 | Checkpoint route | `ReadingCheckpointView` is **inline** (Today finished-arm + journey-end); **omit `Route.readingCheckpoint`** | Its action is a tab-switch, not a stack push — route would be unused |

---

## 3. Domain model changes (authoritative)

### 3.1 New types

**`JourneyState`** — `Models/Enums.swift` (append after `LessonStatus`):
```swift
enum JourneyState: String, CaseIterable, Codable, Identifiable {
    case notStarted, reading, finished
    var id: String { rawValue }
    var title: String { … }          // "Not started" / "Reading" / "Finished"
    var symbol: String { … }         // "bookmark" / "book" / "checkmark.seal.fill"
    var tint: Color { … }            // Palette.textTertiary / .accent / .success
}
```

**`JourneyEvent` + `JourneyStateMachine`** — `Services/Gamification/JourneyStateMachine.swift` (new, pure, SwiftData-free):
```swift
enum JourneyEvent { case start, confirmReadingCheckpoint, firstActivityCompleted, markFinished, reopen }

enum JourneyStateMachine {
    static func apply(_ event: JourneyEvent, to state: JourneyState) -> JourneyState
}
```

**Transition table** (illegal → no-op):

| from \ event | `start` | `confirmReadingCheckpoint` | `firstActivityCompleted` | `markFinished` | `reopen` |
|---|---|---|---|---|---|
| `notStarted` | `reading` | **`reading`** | `reading` | `finished` | `notStarted` |
| `reading`    | `reading` | `reading` | `reading` | `finished` | `reading` |
| `finished`   | `finished` | `finished` | `finished` | `finished` | `reading` |

- `markFinished` allowed from any state. `firstActivityCompleted` only nudges `notStarted→reading`.
- `confirmReadingCheckpoint` (**new, D3**) only nudges `notStarted→reading`; no-op otherwise.
- `reopen` only `finished→reading`.

**`JourneyGating`** — pure helper (D8), `Services/Gamification/JourneyGating.swift` (new) or alongside the state machine:
```swift
enum JourneyGating {
    static func status(isCompleted: Bool, milestoneConfirmed: Bool, isFirstIncomplete: Bool) -> LessonStatus {
        if isCompleted { return .completed }
        if !milestoneConfirmed { return .readGated }
        return isFirstIncomplete ? .available : .locked
    }
}
```

### 3.2 Modified types

**`LessonStatus`** — `Models/Enums.swift:83-85`. Add `readGated`:
```swift
enum LessonStatus { case locked, readGated, available, completed }
```
> ⚠️ Adding this case **breaks the non-exhaustive switches in `JourneyRow`** (`JourneyView.swift`
> `indicatorColor`, `indicatorSymbol`, and the tap-gating). Must add `readGated` arms:
> `indicatorColor → Palette.warning`, `indicatorSymbol → "lock.open"` (or `"hand.raised"`),
> non-tappable like `locked` but **full opacity** (D9).

**`Book`** — `Models/Book.swift`:
- **ADD** `journeyStateRaw: String = JourneyState.notStarted.rawValue` + computed `journeyState` accessor (mirror the `sourceKindRaw`/`sourceKind` pattern at `:50,59-62`). Add to `init(...)` defaulting to `notStarted`.
- **REMOVE** `readProgress: Double` (`:22`), `lastReadOffset: Int` (`:24`), and their init assignments (`:54-55`). (D-4 / FR-9)
- **KEEP** `fullText` exactly as-is (D5) — non-displayed generation cache. Add a comment marking it as generation input only, never rendered.

**`Milestone`** — `Models/RoadmapModels.swift` (`@Model` at `:40-60`):
- **ADD** `readingConfirmed: Bool = false` (FR-5). Set `= false` in `init`.
- **ADD** `stableId: String = UUID().uuidString` (**D6**). Defaulted in the initializer, so
  `RoadmapBuilder.attach` and `SeedData` get it for free; backfill assigns it to pre-existing milestones.

> SwiftData migration: `MangoModelContainer` builds an **un-versioned** schema with no
> `SchemaMigrationPlan` → **automatic lightweight migration**. Additive defaulted properties
> and removed properties both succeed without a plan. `Book`/`Milestone` already in
> `MangoSchema.models`. The data **backfill** (§5) is a separate runtime pass.

---

## 4. UI / behavior changes

### 4.1 Removals (FR-1)
- **Delete** `Features/Reader/ReaderView.swift` (and the empty `Features/Reader/` group).
- **Remove** `Route.reader(Book)` case (`Route.swift:6`) + its `.mangoDestinations()` arm (`:16`).
- **No** `Route.readingCheckpoint` (D14). **No** `activityFirstEnabled` flag (D10).
- Repo-wide: zero references to `ReaderView` / `Route.reader` / `.reader(` / `readProgress` / `lastReadOffset` / `markReadToEnd`.

### 4.2 Affordance replacements (FR-2)
| Site | File:line (verified) | Replacement |
|---|---|---|
| "Read the book" link | `BookDetailView.swift:93` | "Open journey" (roadmap exists) / "Build my journey"; passive "Read on your own (Kindle/print)" hint; journey-state control |
| "Open reader" (`roadmap == nil` arm) | `TodayView.swift:105` | **D12**: read-gate-aware CTA → `Route.bookDetail` (generation) |
| "Read the book" secondary | `TodayView.swift:112` | Remove; compact journey-state control |
| nextLesson CTA | `TodayView.swift:99` | **D12**: if next lesson read-gated → `Route.journey(book)`; else → `Route.lesson` |
| "finished every lesson 🌱" | `TodayView.swift:109` | Inline `ReadingCheckpointView` (D14) |

### 4.3 Journey screen (FR-5, D1/D9)
- Replace nested `status(_:)` (`JourneyView.swift` inside `content(book:roadmap:)`) with a call to `JourneyGating.status(...)`.
- Per **unconfirmed** milestone: render a **checkpoint card** above its lessons — *"Have you read up to ‹milestone.title›?"* + **"I've read up to here"** primary button. Lessons render **visible + non-tappable** at full opacity (D9).
- Confirm flips `milestone.readingConfirmed = true`, dispatches `confirmReadingCheckpoint` to the book's `journeyState` (D3), `try? context.save()`, `Haptics.success()`, animates `.readGated → .available` with `.spring` (gated on `accessibilityReduceMotion → nil`). Reversible ("Undo / not yet").
- Journey screen shows **real gating regardless of `journeyState`** (D11) — a `finished` book can still show gated/incomplete lessons.

### 4.4 Lesson loop (FR-6, D7)
- `LessonView.readingPhase`: relabel from "Read" to a **recap/orientation** — *"Read **‹lesson.title›** in your own copy, then come back to practice."* Show `lesson.readingSummary` as recap; **never** render `fullText`. Local `@State readConfirmed` gates the practice CTA (not persisted; the persisted gate is the milestone checkpoint).
- `LessonView.finishLesson` (`:138`): after `recordLessonCompletion`, dispatch `firstActivityCompleted` via the state machine on `lesson.milestone?.roadmap?.book` (D7), then save.

### 4.5 "What to read next?" (FR-7, D13/D14)
- `Features/Journey/ReadingCheckpointView.swift` (new) — celebratory inline card (`Card`, `Typo.title3`, `Palette.success`) + **"Find my next book"** button.
- Shown inline at journey-end (`roadmap.progress == 1`, **D11**) and in TodayView's finished-arm.
- Button switches tab to Catalog via a new **minimal `TabView` selection binding** (D13): `AppTab` enum + `selection` on `MainTabView`'s `TabView` + `AppModel.selectedTab` (so `ReadingCheckpointView` can set it).

### 4.6 Catalog (FR-8)
- `CatalogView` + `CatalogSamples`: primary CTA "Create roadmap" → **"Start journey"**; intro copy drops "read"/"classic to read" → "Discover a book and start a guided journey." Behavior unchanged (fetch text for generation, build roadmap, route to Journey). Seeds `Book` in `notStarted`; `start` dispatched as the journey opens.
- Stale comment cleanup: `CatalogView.swift:71-73` "Reader/Lesson destinations…" — drop "Reader".

---

## 5. Migration & backfill (D2, D4, D6)

One-time pass `MangoMigration.backfillJourneyState(_:)` invoked from `RootView.task`
(`RootView.swift`) **after** `SeedData.ensureSeeded`, guarded by a `UserDefaults` flag
(`mango.didBackfillJourneyState`) so it runs exactly once. Per existing `Book`:

```swift
let lessons = book.roadmap?.allLessons ?? []
if !lessons.isEmpty && lessons.allSatisfy(\.isCompleted)      { book.journeyState = .finished }
else if lessons.contains(where: \.isCompleted)               { book.journeyState = .reading }
else                                                         { book.journeyState = .notStarted }

for m in book.roadmap?.orderedMilestones ?? [] {
    if m.stableId.isEmpty { m.stableId = UUID().uuidString }            // D6 backfill
    if m.orderedLessons.contains(where: \.isCompleted) { m.readingConfirmed = true }  // D4: ≥1 complete
}
```
Then `try? context.save()` and set the flag.

- **Sample (D2):** seeded fresh as `notStarted`, all milestones unconfirmed → fully gated on first run. No special-casing in `SeedData`. AC-9 holds (confirm is offline).
- **Dropped fields (D-4/FR-9):** `readProgress`/`lastReadOffset` removed → lightweight migration ignores them; no data action.

---

## 6. Contract delta (FR-12, §6.7) — sync-shaped, wiring is 0014

- `shared/api/openapi.yaml` `LibraryItem` (`:299-304`): **add `journeyState`** (enum `[notStarted, reading, finished]`, default `notStarted`). **Drop `confirmedMilestones` from v1** — it depends on roadmap sync (0014's domain) and is local-only until then; `Milestone.stableId` (D6) is the identity it will eventually reference.
- `Services/Networking/DTOs.swift`: add `LibraryItemDTO` with `journeyState: String` defaulting to `"notStarted"`, decoded **leniently** (unknown enum → `notStarted`), mirroring `CatalogBook.init(from:)` (`CatalogBook.swift:40-49`).
- `backend/src/handlers/library.py`: `_item_to_ref` (`:32-35`) gains `"journeyState": item.get("journeyState", "notStarted")`; POST persists the string attr. All-string values → no `float` concern. **Backend change is optional for v1** (state is on-device); if added, `pytest` (moto) round-trip + `cdk synth -c stage=beta` must pass.
- **No change** to `Progress`, roadmap-generate (async 202/poll), or grade contracts.

---

## 7. Work breakdown → phases (for `/to-issues`)

Structured as **vertical tracer-bullet slices** — each lands a testable increment with the app still building.

### Phase A — Domain core (pure, no UI) · unblocks everything
- **A1** `JourneyState` enum + `Book.journeyState` accessor; remove `readProgress`/`lastReadOffset`. *(S)*
- **A2** `Milestone.readingConfirmed` + `Milestone.stableId` + `LessonStatus.readGated` (fix `JourneyRow` switches). *(S)*
- **A3** `JourneyStateMachine` (5 events) + `JourneyStateMachineTests` (exhaustive table). *(M)*
- **A4** `JourneyGating.status(...)` pure helper + `JourneyGatingTests`. *(M)*

### Phase B — Remove the reader (cutover) · depends on A
- **B1** Delete `ReaderView.swift`; remove `Route.reader` + nav arm; fix all references (build + grep green). *(S)*

### Phase C — Reframe the surfaces · depends on A, B
- **C1** `JourneyView`: read-gated gating via `JourneyGating` + milestone checkpoint card (confirm → `confirmReadingCheckpoint` + unlock animation, reversible). *(M)*
- **C2** `LessonView`: recap reading-phase ("read in your book", no `fullText`) + fire `firstActivityCompleted` in `finishLesson`. *(S)*
- **C3** `BookDetailView` + `TodayView`: replace reader affordances; journey-state control; **read-gate-aware Today CTA** (D12). *(M)*
- **C4** `CatalogView`/`CatalogSamples`: "Start journey" copy/CTA; `notStarted`→`start` on open; stale-comment cleanup. *(S)*

### Phase D — "What to read next?" activity · depends on A, C
- **D1** Minimal `TabView` selection binding (`AppTab` + `AppModel.selectedTab`). *(S)*
- **D2** `ReadingCheckpointView` (inline) wired into journey-end + Today finished-arm; button switches tab to Catalog. *(M)*

### Phase E — Migration & contract · depends on A
- **E1** `MangoMigration.backfillJourneyState` (journey state + `stableId` + ≥1-complete checkpoint rule) from `RootView.task` + `JourneyMigrationTests` (seeded in-memory container). *(M)*
- **E2** Contract: `journeyState` on `LibraryItem` (`openapi.yaml` + `DTOs.swift` lenient decode) + `LibraryItemDTOTests`. *(S)*

### Phase F — Polish & docs
- **F1** Docs/copy: `docs/PRODUCT_ROADMAP.md` + `docs/ARCHITECTURE.md` drop "immersive reader"; manual UX/offline/accessibility pass (Dynamic Type, VoiceOver labels, warm-theme tints). *(S)*

**Dependency graph:** `A → B → C → D`, with `E` parallel to C/D (depends only on A), `F` last.
Critical path: A3/A4 → C1 (the gating + checkpoint heart of the reframe).

---

## 8. Acceptance criteria (updated from spec §7)

- [ ] **AC-1** Reader gone: no `ReaderView`/`Route.reader`/`.reader(` references; build + `make ios-test` green.
- [ ] **AC-2** No reader affordances on BookDetail/Today; replaced per §4.2.
- [ ] **AC-3** `JourneyStateMachine.apply` matches the §3.1 table for **all 5 events** × 3 states, incl. `confirmReadingCheckpoint` (D3) and `markFinished`-from-any.
- [ ] **AC-4** Journey state changes from BookDetail/Today persist; **never** inferred from a reading signal; `firstActivityCompleted` auto-advances `notStarted→reading`; nothing auto-sets `finished`.
- [ ] **AC-5** `JourneyGating.status` returns `readGated`/`available`/`locked`/`completed` correctly (pure test, D8); gate is additional to prior-lesson rule.
- [ ] **AC-6** Lesson reading phase shows recap + "read in your book"; **never** renders `fullText`; activities award XP via the unchanged engine.
- [ ] **AC-7** Completing a journey (`roadmap.progress == 1`) surfaces the "What to read next?" card → switches to Catalog (D11/D13).
- [ ] **AC-8** Catalog CTA reads "Start journey", no in-app-reading copy; starting still builds a roadmap + opens Journey.
- [ ] **AC-9** Offline first-run: sample seeds `notStarted` fully gated; user confirms M1 checkpoint **offline**, then first activity completes offline (D2).
- [ ] **AC-10** `readProgress`/`lastReadOffset` gone; backfill maps existing books to a sensible state and **pre-confirms milestones with ≥1 completed lesson** (D4) so no in-progress user is re-gated; migration test green.
- [ ] **AC-11** `LibraryItem.journeyState` in `openapi.yaml` + `DTOs.swift` (lenient, absent → `notStarted`); `confirmedMilestones` **not** in v1.

---

## 9. Test plan

- **Unit (primary, pure — like `LevelCurve`/`StreakCalculator`):** `JourneyStateMachineTests` (5-event exhaustive table), `JourneyGatingTests` (4-state predicate), `JourneyMigrationTests` (seeded in-memory container: `finished`/`reading`/`notStarted` + `readingConfirmed` per D4 + `stableId` assigned), `LibraryItemDTOTests` (lenient decode).
- **iOS UI (manual):** affordance review (no reader); journey-state control; checkpoint confirm + unlock animation; read-gate-aware Today CTA; lesson recap copy; "What to read next?" → Catalog tab; Dynamic Type + VoiceOver; warm-theme tints.
- **Backend:** none required v1. If `library.py` `journeyState` added: `pytest` (moto) round-trip + `cdk synth -c stage=beta`.
- **Regression:** `make ios-test` + backend `pytest`/`cdk synth` stay green (generation/grading/gamification/roadmap-graph untouched).

---

## 10. Cross-spec impact

- **0009** (catalog 100 books): Catalog is the primary "discover → Start journey" surface; per-book synopses enable future hybrid generation (§6.6 option C). Adopt "Start journey" + no-reader framing.
- **0010** (onboarding): **must prep the gate-everything wall** (D1/D2) — the sample first-run leads with a checkpoint, not an activity. Onboarding should introduce the book/checkpoint concept.
- **0011** (nav + activity UX): builds on the journey-state control, checkpoints, and the **`TabView` selection binding** introduced here (D13) — don't reinvent it. Removed `Route.reader` reflected.
- **0014** (progress sync): owns syncing `journeyState` (field already shaped) and, later, roadmap + `confirmedMilestones` via `Milestone.stableId` (D6).
- **0016** (insight review): reinforced, not broken — review draws from completed lessons, no reading dependency.
- **0017/0018** (PDF/EPUB): reposition as **"ingest for generation only, no reader."** Connectors stand; drop "so the user can read it" rationale.

---

## 11. Risks (carried from spec §10, updated)

- **R-1** Generation quality without a reader → unaffected; generation already uses a ≤12k excerpt (D5/ADR-0001).
- **R-2** Self-attested checkpoints gameable → honor system matches existing application tasks; reversible; gate activities, not rewards.
- **R-3** Users expect to read in-app → clear "read on your own" framing + onboarding (0010); deliberate product bet.
- **R-4** Losing reading progress on migration → backfill maps to sensible state and pre-confirms ≥1-complete milestones (D4) — **no one re-gated** (now literally true).
- **R-5** Copyright/ingestion of user text → never displayed; only excerpt sent to model (D5/ADR-0001).
- **R-6** Cross-spec drift → this is the keystone, sequenced first; §10 explicit.
