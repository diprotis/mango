# 0017 — Background content parsing — move PDF/EPUB import off the main thread

- **Epic:** M7 · **Status:** Draft · **Owner:** unassigned · **Updated:** 2026-06-26
- **Reviewers:** Principal, SD, QA

## 1. Summary
Today `ConnectorService.importPDF(data:name:)` walks every PDFKit page **synchronously
on the main thread**; on a large PDF this hitches or freezes the UI during import, which
is exactly the kind of stutter that costs activation on first run. This spec moves PDF
text extraction onto a **dedicated background executor** with progress reporting,
cooperative cancellation, and a single `@MainActor` hop to publish results into SwiftData
— and generalizes that machinery into a small, reusable **background import pipeline** so
**EPUB import** (0018-epub-import.md) rides the same path. The correctness crux is
Swift concurrency: `PDFDocument`/`PDFPage` are **not thread-safe**, so the document must
be confined to one background executor, with only `Sendable` values crossing actor
boundaries. Acceptance: importing a large PDF keeps the UI responsive by a measurable
bar and is cancellable.

## Pivot impact (see 0008)
Post-pivot, Mango is **not a reading app** and the in-app Reader is **removed** (`0008` FR-1):
imported content is now ingested **solely to generate the activity/journey loop** (quizzes,
reflections, application tasks), **not** to be read inside Mango. This does **not** change the work
here — PDF text extraction still produces the same `ParsedBook.fullText`, which now feeds
`RoadmapGenerator`/activity generation rather than a reader view. Two consequences to keep in mind
during implementation:
- References below to a "reader"/"smooth reading" are about **import responsiveness and downstream
  activity generation**, not an in-app reading surface. The `lastReadOffset`/`readProgress` reader
  cursors are out of scope for this spec and may be vestigial after `0008`.
- The threading/progress/cancellation pipeline (`ContentImportPipeline`) is unchanged and remains the
  shared path `0018` (EPUB) reuses. Everything else in this spec stands as written.

## 2. Goals / Non-goals
- **Goals:**
  - Parse PDFs off the main thread; the UI (scroll, the import sheet's spinner/Cancel)
    stays responsive throughout.
  - **Progress** (0…1 by page) surfaced to `AddBookView` and **cooperative cancellation**
    from the sheet's Cancel button.
  - **Bounded memory** for big PDFs by streaming page-by-page, never holding all page
    strings plus the final joined string at peak unnecessarily.
  - A reusable `ContentImportPipeline` (or equivalent actor) that both PDF and EPUB use, so
    we solve threading/progress/cancel once.
  - Strict Swift 6-style concurrency correctness: `Sendable` boundaries, `@MainActor` only
    for UI/state, no data races on PDFKit objects.
  - Accessible progress UI (determinate where possible) honoring **Reduce Motion**.
- **Non-goals:**
  - Changing **what** text we extract or the `ParsedBook` shape — output is identical to
    today; only *where/how* it runs changes.
  - OCR of scanned/image-only PDFs (still `ConnectorError.pdfUnreadable`).
  - Server-side parsing or the `/content/parse` endpoint.
  - Background execution after the app is suspended (no `BGTaskScheduler`); import is a
    foreground, user-initiated operation.
  - Reworking URL/Gutenberg/text importers — they are already `async` and network-bound,
    not CPU-bound on the main thread (though they may adopt the pipeline's progress hooks
    later).

## 3. Background & context
`ConnectorService.importPDF` (`ios/Mango/Services/Content/ConnectorService.swift`) is a
**synchronous, non-`async`** function:
```swift
func importPDF(data: Data, name: String) throws -> ParsedBook {
    guard let document = PDFDocument(data: data) else { throw ConnectorError.pdfUnreadable }
    for index in 0..<document.pageCount { … page.string … }   // main-thread loop today
}
```
It is called from `AddBookView.handlePDF(_:)` inside a `Task { … }`, but because the
function itself is synchronous and the surrounding `Task` inherits the view's
`@MainActor` context, the page loop executes on the main actor — so a multi-hundred-page
PDF blocks the run loop. The view already models a `working: String?` label and a
ProgressView, and `ParsedBook` is already `Sendable` (`DTOs.swift`).

This is **Roadmap item #6** ("Offload PDF parsing off the main thread … Moving parsing to
a background context keeps import smooth and protects the first-run experience"). It also
unblocks/derisks **0018-epub-import.md**, whose large-file handling is explicitly
delegated here. Constraints from CLAUDE.md: SwiftUI + SwiftData, iOS 17+, the single
`@Observable AppModel`, DesignSystem tokens, and **no third-party deps** (all of this uses
first-party Swift Concurrency + PDFKit).

## 4. User stories
- As a reader importing a long PDF, I want the app to stay smooth (I can still see the
  spinner animate and tap Cancel), so it never feels frozen.
- As a reader who picked the wrong/huge file, I want to **cancel** mid-import and get back
  to the picker immediately, so I'm not stuck waiting.
- As a reader, I want a **progress indicator** that actually moves (page X of Y), so I
  trust the app is working.
- As a developer adding EPUB, I want one background pipeline to reuse, so import threading
  is solved once and consistently.

## 5. Requirements
**Functional**
- **FR-1** PDF text extraction runs on a background executor, never on `@MainActor`. The
  main thread stays responsive during import.
- **FR-2** New async API:
  `func importPDF(data: Data, name: String, progress: @Sendable (Double) -> Void = { _ in }) async throws -> ParsedBook`
  replacing/supplementing the synchronous variant (old sync signature deprecated or
  removed — only `AddBookView` calls it; see §9).
- **FR-3** Progress is reported as `Double` in `0…1` (by `completedPages / pageCount`),
  delivered on the main actor for direct binding to UI state.
- **FR-4** Cancellation is cooperative: the parse loop checks `Task.isCancelled` (or
  `try Task.checkCancellation()`) each page; cancelling the SwiftUI `Task` (e.g. on sheet
  dismiss / Cancel tap) stops work promptly and throws `CancellationError`, surfaced as a
  benign "import cancelled" (no error alert).
- **FR-5** `PDFDocument`/`PDFPage` instances are created and used **only** inside the
  background executor; they never cross an actor boundary. Only `Sendable` values
  (`String`, `Data`, `Double`, `ParsedBook`) cross boundaries.
- **FR-6** Results are published to SwiftData/state via exactly one `@MainActor` hop in
  `AddBookView.finish(with:)` (unchanged), keeping all `ModelContext` access on the main
  actor (the app's existing convention).
- **FR-7** A reusable surface — `ContentImportPipeline` actor (or a documented detached-
  `Task` helper) — exposes `run(_ work:) async throws -> ParsedBook` with progress +
  cancellation, used by both `importPDF` and the EPUB importer.
- **FR-8** Memory: extract page text incrementally and accumulate into a single growing
  buffer; do not retain per-page `PDFPage` objects beyond their iteration, and avoid
  building a large intermediate `[String]` when a streaming append suffices.

**Non-functional**
- **NFR-perf (measurable):** with a ~500-page / ~30 MB text PDF importing, the main run
  loop stays responsive: an on-screen indeterminate-but-animating control keeps animating,
  and a scripted UI interaction (tapping Cancel) is handled within **≤ 100 ms**; no
  main-thread hang assertion fires. Concretely: a **hang-detection** check (no main-thread
  stall > 250 ms during import) and a manual "spinner keeps spinning + Cancel responds"
  check.
- **NFR-correctness:** compiles clean under strict concurrency checking (treat as Swift 6
  language mode / "complete" concurrency checking) with **no** `Sendable` warnings around
  PDFKit usage.
- **NFR-memory:** peak additional memory scales with output text size, not pageCount ×
  page object retention; no unbounded `autoreleasepool` growth across the page loop (wrap
  per-page work in `autoreleasepool` if profiling shows CoreGraphics buildup).
- **NFR-accessibility:** progress UI uses `Palette`/`Typo`/`Metrics`; is a determinate
  `ProgressView(value:)` with a VoiceOver label ("Importing, 40 percent"); under **Reduce
  Motion** it avoids gratuitous animation and shows a static/stepped indicator.
- **NFR-deps:** first-party only (Swift Concurrency, PDFKit) — no third-party packages.

## 6. Design
**API / contract**
- No backend/openapi change. `ParsedBook` unchanged. The only signature change is
  `ConnectorService.importPDF` becoming `async` with an optional progress closure (and the
  matching EPUB API from 0018-epub-import.md gaining the same).

**Concurrency model**
- Introduce a dedicated executor that **owns** the PDFKit work:
  ```swift
  actor ContentImportPipeline {
      // Runs CPU-bound, non-Sendable-touching work off the main actor.
      func parsePDF(data: Data, name: String,
                    onProgress: @Sendable @escaping (Double) -> Void) async throws -> ParsedBook {
          guard let doc = PDFDocument(data: data) else { throw ConnectorError.pdfUnreadable }
          let count = doc.pageCount
          var text = ""
          text.reserveCapacity(count * 2_000)
          for i in 0..<count {
              try Task.checkCancellation()
              autoreleasepool {
                  if let s = doc.page(at: i)?.string { text += s; text += "\n\n" }
              }
              onProgress(Double(i + 1) / Double(max(count, 1)))
          }
          let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
          guard trimmed.count >= 50 else { throw ConnectorError.pdfUnreadable }
          return ConnectorService.makeBook(title: name.deletingPDFExtension, author: nil,
                                            text: trimmed, kind: .pdf, value: name)
      }
  }
  ```
  - The `actor` gives a single serialized execution context off the main actor; the
    `PDFDocument` is a **local** inside the actor method and never escapes, satisfying the
    "not thread-safe → confine to one executor" rule. (If actor-hopping overhead matters,
    the alternative is a `Task.detached(priority: .userInitiated)` that does the same loop;
    the actor is preferred because it names and centralizes the executor and is trivially
    reused by EPUB.)
  - `onProgress` is `@Sendable`; the caller wraps a `@MainActor` state mutation:
    `await pipeline.parsePDF(...) { p in Task { @MainActor in self.progress = p } }` —
    or, cleaner, an `AsyncStream<Double>` the view consumes. (Decision in §10.)
- `ConnectorService.importPDF(data:name:progress:)` becomes a thin `async` wrapper that
  delegates to the pipeline. `makeBook` is reused unchanged (it's pure).
- **`@MainActor` boundary:** only `AddBookView` (state: `working`, new `progress: Double`,
  the owning `Task`) and `finish(with:)` (SwiftData insert/save) are on the main actor.
  Nothing PDFKit crosses into it.

**iOS — screens/state**
- `AddBookView`:
  - Add `@State private var progress: Double = 0` and `@State private var importTask: Task<Void, Never>?`.
  - `handlePDF` becomes: store `importTask = Task { … await app.connectors.importPDF(data:…, name:…) { p in progress = p } … }`.
  - Cancel: the toolbar **Cancel** button and `.interactiveDismissDisabled`/`onDisappear`
    call `importTask?.cancel()`; a `CancellationError` is swallowed (no `errorMessage`).
  - Progress UI: replace the indeterminate `ProgressView()` in the busy button with
    `ProgressView(value: progress)` (determinate) once `progress > 0`, styled with
    `Palette.onAccent`; under Reduce Motion (`@Environment(\.accessibilityReduceMotion)`)
    skip pulsing.
- `ConnectorService` gains a reference to (or constructs) the `ContentImportPipeline`.
  `makeBook` is promoted to `static` (or `internal`) so the pipeline can call it without
  duplicating the stat math.

**Diagram (threading)**
```
AddBookView (@MainActor)
  │  importTask = Task { await connectors.importPDF(...){ p in progress = p } }
  ▼
ConnectorService.importPDF (async)               ContentImportPipeline (actor, off-main)
  └────────────── await ───────────────────────▶  PDFDocument(data:) … page loop
        progress(p) ◀── @Sendable closure ──────  onProgress per page  (Task.checkCancellation)
  ◀───────────── ParsedBook (Sendable) ─────────  makeBook(...)
  │
  ▼  @MainActor hop
AddBookView.finish(with:)  ──▶  ModelContext.insert/save (main actor)
```

## 7. Acceptance criteria
- [ ] Importing a ~500-page text PDF, the main thread is never blocked: a UI hang
      detector reports **no** main-thread stall > 250 ms, and tapping **Cancel** is handled
      within ~100 ms. *(→ instrumented/manual responsiveness check)*
- [ ] Cancelling mid-import stops work promptly, throws `CancellationError`, returns the
      user to the picker, and shows **no** error alert. *(→ unit test on the pipeline +
      manual)*
- [ ] Determinate progress advances 0→1 by page and is announced by VoiceOver; under
      Reduce Motion no pulsing animation is used. *(→ manual a11y check)*
- [ ] Extracted text for a fixture PDF is **identical** to the pre-change synchronous
      output (no regression in content). *(→ ConnectorServicePDFTests golden compare)*
- [ ] Builds clean under strict/"complete" concurrency checking with no `Sendable`
      warnings touching `PDFDocument`/`PDFPage`. *(→ ios-ci build flag)*
- [ ] EPUB import (0018-epub-import.md) uses the same `ContentImportPipeline` for its
      large-file path. *(→ code review / shared-type usage)*
- [ ] Image-only PDF still throws `ConnectorError.pdfUnreadable`. *(→ unit test)*

## 8. Test plan
**Unit (XCTest, offline)**
- `ContentImportPipelineTests` — feed a small generated PDF (build a `PDFDocument`
  programmatically or check in a tiny fixture): assert returned text/`ParsedBook`,
  progress callback fires monotonically and ends at `1.0`, and `Task` cancellation throws
  `CancellationError` partway. (Cancellation determinism: inject a per-page hook or use a
  large enough fixture and cancel quickly; assert it does not run to completion.)
- `ConnectorServicePDFTests` — golden test: same fixture, new async path output equals the
  prior synchronous output; image-only fixture → `.pdfUnreadable`.
- Concurrency: a test that asserts the pipeline method is `nonisolated`-from-main /
  doesn't require the main actor (compile-time guarantee via call from a detached context).

**Integration / manual**
- Real large PDFs (textbook-sized, 300–800 pp): observe spinner keeps animating, Cancel is
  instant, Instruments **Time Profiler** shows the page loop on a non-main thread, and
  **Allocations** shows bounded growth (no per-page leak).
- A11y: VoiceOver announces progress; Reduce Motion path verified.

**Not automated:** Instruments profiling (Time Profiler / Allocations / Hangs), real-device
responsiveness, VoiceOver/Reduce-Motion passes.

## 9. Rollout & migration
- **Code migration:** `AddBookView.handlePDF` is the **only** caller of `importPDF`
  (verified) and already runs inside a `Task`; switching to the `async` signature is a
  localized change. Keep the synchronous `importPDF` temporarily as `@available(*,
  deprecated)` calling into the async path on a detached task, or delete it once the view
  is updated (recommend delete — single call site).
- **Flag:** gate behind `AppSettings.backgroundImportEnabled` (default **on**) so we can
  fall back to the synchronous path if a regression appears; the flag also lets EPUB adopt
  it incrementally.
- **Backward compatibility:** no persisted-data or API change; `ParsedBook`/`Book`
  unchanged, so no SwiftData migration. Safe to ship independently of EPUB, but EPUB should
  land after/with it to reuse the pipeline.
- **Teardown:** removing the flag and the deprecated sync shim once EPUB ships and the
  background path has soaked on Beta.

## 10. Risks & open decisions
- **Risk — PDFKit thread-safety.** `PDFDocument`/`PDFPage` are not thread-safe; misuse
  causes intermittent crashes/garbage text. *Mitigation:* strict confinement inside the
  actor method; never store/return PDFKit objects; enable complete concurrency checking so
  the compiler enforces it.
- **Risk — actor-hop overhead per page.** Calling a `@MainActor` progress closure every
  page could thrash. *Mitigation:* coalesce progress (e.g. update at most every N pages or
  on a throttled cadence), or use an `AsyncStream<Double>` the view samples.
- **Risk — `@Sendable` closure capturing view state.** A naive `progress: { self.progress = $0 }`
  is a main-actor mutation from a non-isolated context. *Mitigation:* hop via
  `Task { @MainActor in … }` or the `AsyncStream` pattern (see decision).
- **Risk — cancellation granularity.** Per-page checks mean a single very large page can
  still run to completion before cancel takes effect. *Acceptable;* documented.
- **Decision needed — progress transport (recommend AsyncStream).**
  - **A (recommend):** pipeline returns/accepts an `AsyncStream<Double>`; the view does
    `for await p in stream { progress = p }` inside its `@MainActor` task — clean Sendable
    story, natural cancellation, easy throttling.
  - **B:** a `@Sendable (Double) -> Void` callback wrapped in `Task { @MainActor … }` —
    simpler signature, but the callback's hop is easy to get subtly wrong.
- **Decision needed — actor vs detached Task.** *Recommend a named `ContentImportPipeline`
  actor* for reuse (EPUB) and a single owned executor, over ad-hoc `Task.detached`.
- **Decision needed — keep or delete the synchronous `importPDF`.** *Recommend delete*
  (one call site) after the view migrates, to avoid two code paths.

## 11. Tasks & estimate
1. **(M)** Add `ContentImportPipeline` actor with `parsePDF(data:name:onProgress:)`;
   confine `PDFDocument`, per-page `Task.checkCancellation()`, `autoreleasepool`, size
   guard. Promote `ConnectorService.makeBook` to reusable. **+ unit tests.**
2. **(S)** Make `ConnectorService.importPDF` `async` with progress; delegate to pipeline;
   remove/deprecate the sync variant.
3. **(M)** `AddBookView`: `importTask`, `progress` state, async call, Cancel →
   `importTask?.cancel()`, swallow `CancellationError`, determinate `ProgressView(value:)`.
4. **(S)** Progress transport (`AsyncStream<Double>` per decision) + throttling/coalescing.
5. **(S)** Accessibility: VoiceOver progress label + Reduce-Motion path.
6. **(S)** Turn on complete/strict concurrency checking for the target (or at least these
   files) in CI; fix any `Sendable` findings.
7. **(S)** `AppSettings.backgroundImportEnabled` flag + fallback wiring.
8. **(S)** Generalize for EPUB: expose a generic `run(...)`/`parse(...)` entry the EPUB
   importer calls (coordinate with 0018-epub-import.md).
9. **(S)** Instruments pass (Time Profiler/Allocations/Hangs) on a large PDF; record the
   responsiveness measurement.

_Rough total: ~2 M + 6 S._

## 12. References
- `ios/Mango/Services/Content/ConnectorService.swift` (`importPDF`, `makeBook`)
- `ios/Mango/Features/Library/AddBookView.swift` (`handlePDF`, `finish`)
- `ios/Mango/Services/Networking/DTOs.swift` (`ParsedBook: Sendable`)
- `docs/PRODUCT_ROADMAP.md` (item #6), `CLAUDE.md` (concurrency / no-deps / SwiftData)
- `working/0018-epub-import.md` (shares this pipeline)
- Apple PDFKit (`PDFDocument` thread-safety), Swift Concurrency (`actor`, `Task`,
  `Sendable`, `AsyncStream`, `Task.checkCancellation`).
