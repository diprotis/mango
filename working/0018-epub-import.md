# 0018 — EPUB import — bring-your-own-library connector

- **Epic:** M7 · **Status:** Draft · **Owner:** unassigned · **Updated:** 2026-06-26
- **Reviewers:** Principal, SD, QA

## 1. Summary
Add **EPUB** as a fifth source to the `ConnectorService` connectors layer (today: web
URL / Project Gutenberg / pasted text / PDF) so a user can import a book they already
own from Files/iCloud Drive. An EPUB is a ZIP archive of XHTML documents; iOS ships
**no built-in ZIP reader** and Mango allows **no third-party iOS dependencies**
(CLAUDE.md invariant), so the crux of this work is a small, dependency-free EPUB reader
built on Apple's **Compression framework** (`libcompression`, raw DEFLATE). The output
is the same normalized `ParsedBook` every other connector produces, plus lightweight
chapter metadata, so the existing import → roadmap → reader pipeline is unchanged
downstream. Acceptance: a known public-domain EPUB imports into a readable `Book` with
correctly ordered chapters and carried-over title/author.

## Pivot impact (see 0008)
Post-pivot, Mango is **not a reading app** and the in-app Reader is **removed** (`0008` FR-1): an
imported EPUB is parsed **only to feed activity/journey generation** (quizzes, reflections,
application tasks) — Mango does **not** present the EPUB as an in-app reading experience. The
connector work here is otherwise unchanged: EPUB still normalizes to the same `ParsedBook.fullText`
(plus chapter metadata) that `RoadmapGenerator`/activity generation consume. Adjust expectations on
two points:
- Wherever this spec says "readable `Book`"/"the reader," read it as **"usable as activity-generation
  input"**; the extracted text correctness, ordering, and metadata requirements are unchanged and
  still fully apply. The **`BookChapter`** model stays valuable — it gives activity generation better
  structure/segmentation even without a reader UI.
- FR-6's "reader can use chapters for a jump list" and Task 6's "reader chapter jump list" become
  **out of scope** under the pivot (no reader to host them); keep the **chapter index data** (it aids
  roadmap segmentation) but drop the reader-UI affordance. The ZIP/OPF/text-extraction core and the
  shared background pipeline (`0017`) are unaffected.

## 2. Goals / Non-goals
- **Goals:**
  - `ConnectorService.importEPUB(data:name:) -> ParsedBook` that parses a valid EPUB 2/3
    file fully on-device (offline) with **zero third-party deps**.
  - A dependency-free ZIP reader (central-directory parse + stored/DEFLATE inflate via
    `libcompression`) sufficient for real-world EPUBs.
  - Parse `META-INF/container.xml` → OPF; read the `<manifest>` + `<spine>`; extract each
    spine item's XHTML in reading order; strip markup with the **existing** `HTMLText`
    helper; concatenate into `ParsedBook.fullText`.
  - Carry metadata: title, author (OPF Dublin Core `dc:title` / `dc:creator`), and the
    cover image where present (for `coverHue` / future thumbnail).
  - Preserve **chapter boundaries** (per spine item) so the reader and roadmap can show
    structure, without changing the flat-`fullText` contract other connectors rely on.
  - Add EPUB to `AddBookView`'s source picker and the `.fileImporter` content types.
- **Non-goals:**
  - **DRM-protected** EPUBs (Adobe ADEPT / FairPlay) — detected and rejected with clear
    copy, never circumvented.
  - Full EPUB rendering fidelity (CSS, embedded fonts, fixed-layout/comic EPUBs, MathML,
    media overlays, footnote popovers) — Mango reads plain text, not a styled e-reader.
  - A general-purpose ZIP library; we implement only what EPUB needs (no ZIP64 archives,
    no encryption, no multi-disk, only `stored` + `deflate` compression methods).
  - Server-side EPUB parsing (the `/content/parse` endpoint) — local only for now;
    mirrors how the other connectors run on-device.
  - Re-flowing/throttling for very large EPUBs — large-file handling is delegated to the
    shared background pipeline in **0017-pdf-background-parsing.md** (see §10).

## 3. Background & context
`ConnectorService` (`ios/Mango/Services/Content/ConnectorService.swift`) is the
connectors layer: each importer turns a source into a `ParsedBook`
(`ios/Mango/Services/Networking/DTOs.swift`) which `AddBookView`
(`ios/Mango/Features/Library/AddBookView.swift`) persists into a `Book`
(`ios/Mango/Models/Book.swift`) and feeds to `RoadmapGenerator`. `BookSourceKind`
(`ios/Mango/Models/Enums.swift`) currently enumerates `url, gutenberg, text, pdf,
sample`. Markup stripping already exists as `HTMLText.extract(_:)` and `HTMLText.title(_:fallback:)`;
reading stats as `TextStats.wordCount/estimatedMinutes/coverHue/excerpt`.

EPUB import is **Roadmap item #5** ("Extend the connectors layer … with EPUB so users
can bring their own library"). Why now: it is the highest-leverage remaining import path
— Gutenberg already serves `.txt`, but most owned books are EPUB — and "more books in
the funnel" is a direct retention lever in `docs/PRODUCT_ROADMAP.md`.

The hard constraint: **CLAUDE.md** — *"No third-party iOS dependencies. Keep the app
SPM/CocoaPods-free so it builds by just opening the project."* The natural EPUB approach
(ZIPFoundation/ZIPArchive) violates this directly. This spec therefore designs a minimal
reader on Apple frameworks. Related: `Book.fullText` is a single flat string with a
`lastReadOffset` resume cursor and `readProgress` fraction — any chapter model must not
break those, and the AI roadmap is `Roadmap → Milestone → Lesson`
(`ios/Mango/Models/RoadmapModels.swift`), independent of source chapters.

## 4. User stories
- As a reader, I want to import an EPUB I already own from Files/iCloud Drive, so that I
  can turn my own library into Mango journeys.
- As a reader, I want chapters to appear in the correct order with sensible titles, so the
  reader and roadmap reflect the book's structure.
- As a reader, I want a clear, non-technical message when a file is DRM-locked, corrupt,
  or image-only, so that I know it's the file — not the app — and what to do.
- As a reader on a large EPUB, I want the import to stay responsive and cancellable, so a
  big file doesn't freeze the app (delivered via the shared background pipeline).

## 5. Requirements
**Functional**
- **FR-1** `ConnectorService.importEPUB(data: Data, name: String) throws -> ParsedBook`
  exists and is reachable from `AddBookView` (new `.epub` source + `UTType.epub` in
  `.fileImporter`).
- **FR-2** A dependency-free ZIP reader reads EPUB archives: locate the End Of Central
  Directory record, walk central-directory file headers, and extract a named entry as
  `Data`, supporting compression method `0` (stored) and `8` (DEFLATE, inflated via
  `libcompression` raw `COMPRESSION_ZLIB`/raw-deflate).
- **FR-3** Read `META-INF/container.xml`, resolve the **OPF** path from its first
  `<rootfile full-path="…">`, and parse the OPF (`XMLParser`, stdlib) for `<metadata>`,
  `<manifest>` (id → href, media-type), and `<spine>` (ordered `itemref idref`s).
- **FR-4** For each spine item that is XHTML, extract its file, run `HTMLText.extract`,
  and concatenate in spine order into `fullText` (chapters separated by a stable marker,
  e.g. `"\n\n"`), trimming so total `fullText.count >= 50` else `ConnectorError.emptyContent`.
- **FR-5** Metadata: title = `dc:title` (fallback `HTMLText.title` of first chapter, then
  filename minus `.epub`); author = first `dc:creator`. Resolve cover image from the OPF
  `<meta name="cover">` → manifest item, or an `item` with `properties="cover-image"`
  (EPUB3); decode to derive `coverHue` (reuse `TextStats.coverHue(title)` if no image).
- **FR-6** Build a **chapter index**: an ordered list of `(title, startOffset)` into
  `fullText`, where `title` comes from the spine item's `<title>`/first heading or the
  NAV/NCX table of contents when present. Persist alongside `Book` (see §6 Data) without
  altering `fullText`, `lastReadOffset`, or `readProgress` semantics.
- **FR-7** Error mapping: DRM/encrypted (`META-INF/encryption.xml` present, or
  `mimetype` ≠ `application/epub+zip`) → new `ConnectorError.drmProtected`; malformed
  zip / missing OPF / unparseable container → `ConnectorError.epubMalformed`; no
  extractable text → existing `.emptyContent`.
- **FR-8** New `BookSourceKind.epub` (label `"EPUB"`); `AddBookView.Kind` gains `.epub`.

**Non-functional**
- **NFR-perf:** parsing a typical 1–3 MB novel completes in < 2 s on an iPhone 12-class
  device; the main thread is never blocked (FR routed through the shared background
  pipeline — see 0017-pdf-background-parsing.md). Memory stays bounded by extracting
  one spire item at a time rather than inflating the whole archive at once.
- **NFR-security:** the parser treats the file as **untrusted input** — bounds-check
  every offset/length read from the central directory, cap per-entry inflated size
  (e.g. 64 MB) and total output to defend against zip-bomb amplification, disable
  `XMLParser` external-entity resolution (`shouldResolveExternalEntities = false`), and
  ignore absolute/`..` paths in entry names (no path traversal; we read in-memory only,
  but reject traversal entries defensively).
- **NFR-privacy:** all processing on-device; no network; the file never leaves the phone.
- **NFR-accessibility:** progress + error states use DesignSystem tokens (`Palette`,
  `Typo`, `Metrics`) and are VoiceOver-labelled; honors Reduce Motion (shared progress UI).
- **NFR-deps:** **zero** third-party packages; only `Foundation`, `Compression`,
  `UniformTypeIdentifiers`, and the existing `HTMLText`/`TextStats`.

## 6. Design
**API / contract**
- No backend/openapi change (local connector). `ParsedBook` is unchanged; EPUB maps onto
  it exactly like PDF does today. If a server EPUB path is added later it reuses the OPF
  shape, but that is out of scope.

**Data**
- `BookSourceKind` (`Models/Enums.swift`): add `case epub` with `label "EPUB"`.
- Chapters: add an optional, **additive** SwiftData side model rather than touching the
  flat `fullText` contract:
  ```swift
  @Model final class BookChapter {
      var title: String
      var startOffset: Int      // index into Book.fullText
      var order: Int
      @Relationship var book: Book?
  }
  ```
  with `@Relationship(deleteRule: .cascade, inverse: \BookChapter.book) var chapters: [BookChapter]`
  on `Book`. SwiftData additive model changes are a lightweight migration (new entity;
  existing books simply have no chapters). The reader can use chapters for a jump list; if
  absent (URL/PDF/text books) it falls back to today's flat scroll. `ParsedBook` gains an
  optional `chapters: [ParsedChapter]?` (Sendable struct of `title`/`startOffset`/`order`)
  so the connector can hand structure to `AddBookView.finish`.

**iOS — module layout** (new files under `ios/Mango/Services/Content/`, auto-picked up by
Xcode 16 file-system-synchronized groups — **do not** edit `project.pbxproj`):
- `EPUBImporter.swift` — orchestrates: ZIP open → container → OPF → spine → text + chapters
  → `ParsedBook`. Pure, `Sendable` inputs/outputs; runs on the shared background executor.
- `MiniZip.swift` — the dependency-free reader. Surface:
  ```swift
  struct MiniZipArchive {
      init(data: Data) throws            // parses EOCD + central directory
      var entryNames: [String] { get }
      func data(forEntry name: String) throws -> Data   // stored or inflate
  }
  enum MiniZipError: Error { case notZip, unsupportedMethod, corrupt, entryNotFound, tooLarge }
  ```
  Inflate via `Compression`'s `compression_stream` API in `COMPRESSION_STREAM_DECODE` with
  the raw-DEFLATE algorithm (`COMPRESSION_ZLIB` operating on raw deflate streams), looping
  over output buffers until `COMPRESSION_STATUS_END`.
- `OPFDocument.swift` — `XMLParser` delegate extracting metadata/manifest/spine + NAV/NCX
  ToC titles. External entities disabled.
- `AddBookView`: add `.epub` to `Kind` and pass `[UTType.epub]` (falling back to a
  declared `public.epub` type) to `.fileImporter`; call `importEPUB` on the chosen file.

**Algorithm (importEPUB)**
1. `MiniZipArchive(data:)`. Validate `mimetype` entry == `application/epub+zip`
   (when present) and absence of `META-INF/encryption.xml` (else `.drmProtected`).
2. Read `META-INF/container.xml` → OPF href.
3. Parse OPF → metadata, `manifest[id→(href,type)]`, `spine[idref…]`.
4. For each spine idref → manifest href that is XHTML: `archive.data(forEntry:)` →
   `String(decoding:)` (UTF-8, ISO-Latin-1 fallback) → `HTMLText.extract`. Record chapter
   title (ToC > first heading > "Chapter N") and the running `startOffset`.
5. Join chapters, build `ParsedBook` via the existing `makeBook(...)` path (so
   `wordCount`/`estimatedMinutes`/`excerpt`/`coverHue` are computed identically), attaching
   `chapters` and `sourceKind: .epub`, `sourceValue: name`.

**Diagram (data flow)**
```
.epub Data ─▶ MiniZipArchive ─▶ container.xml ─▶ OPF (metadata/manifest/spine)
                                                        │
                 per spine item ◀───────────────────────┘
                 XHTML Data ─▶ HTMLText.extract ─▶ chapter text + offset
                                                        │
                          join ─▶ makeBook(...) ─▶ ParsedBook(+chapters) ─▶ Book(+BookChapter)
```

## 7. Acceptance criteria
- [ ] A bundled public-domain test EPUB (e.g. a Standard Ebooks / Gutenberg EPUB of
      *Meditations* or *Pride and Prejudice*) imports into a `Book` whose `fullText` is
      non-empty, readable, and in correct reading order. *(→ EPUBImporterTests)*
- [ ] Title and author are populated from OPF Dublin Core. *(→ EPUBImporterTests)*
- [ ] `chapters` is ordered, each `startOffset` lands at the start of that chapter's text
      in `fullText`, and `order` is contiguous from 0. *(→ EPUBImporterTests)*
- [ ] `MiniZipArchive` extracts both a `stored` and a `deflate` entry byte-for-byte equal
      to a fixture produced by the `zip` CLI. *(→ MiniZipTests)*
- [ ] An EPUB containing `META-INF/encryption.xml` throws `ConnectorError.drmProtected`;
      a truncated/garbage file throws `.epubMalformed`; an image-only EPUB throws
      `.emptyContent`. *(→ EPUBImporterTests, error-path)*
- [ ] A crafted zip-bomb-style entry (declared inflated size beyond the cap) throws
      `MiniZipError.tooLarge` and does not exhaust memory. *(→ MiniZipTests)*
- [ ] `AddBookView` offers an **EPUB** source and the file importer accepts `.epub`;
      importing a large EPUB keeps the UI responsive and is cancellable. *(→ manual +
      shared pipeline check in 0017-pdf-background-parsing.md)*
- [ ] App still builds by opening `ios/Mango.xcodeproj` with **no** package resolution
      (no SPM/CocoaPods added). *(→ manual / ios-ci)*

## 8. Test plan
**Unit (XCTest, `ios/MangoTests/`, offline — preferred per CLAUDE.md)**
- `MiniZipTests` — fixtures generated at test time or checked in: a `stored` entry and a
  `deflate` entry round-trip; EOCD/central-dir parsing; corrupt header → `.corrupt`;
  oversized entry → `.tooLarge`; missing entry → `.entryNotFound`.
- `EPUBImporterTests` — a small valid EPUB fixture (a few XHTML files + OPF + NAV):
  asserts text content, ordering, title/author, chapter offsets; DRM/malformed/empty
  error paths; UTF-8 + Latin-1 decoding.
- Reuse existing `HTMLTextTests`/`TextStatsTests` coverage for the stripping/stat math
  (no duplication).

**Integration / manual**
- Import 3–5 real public-domain EPUBs (Standard Ebooks, Gutenberg EPUB, an EPUB3 with a
  NAV ToC) from Files; verify reader + generated roadmap.
- Negative: a Calibre-DRM or Adobe-DRM sample → friendly `.drmProtected` copy; a
  fixed-layout/comic EPUB → `.emptyContent` (no crash).
- Large-file responsiveness/cancellation verified via the shared background pipeline.

**Not automated:** real-device performance/memory profiling (Instruments Allocations on a
40+ MB EPUB), VoiceOver pass on the import/progress/error UI.

## 9. Rollout & migration
- Ship behind a lightweight `AppSettings` flag (`epubImportEnabled`, default **on** once
  QA passes) so it can be dark-launched and disabled without a build if a problem EPUB
  class surfaces in the wild.
- **Data migration:** introducing `BookChapter` is an **additive** SwiftData schema change
  (new `@Model` + new optional relationship); existing books migrate automatically with
  empty `chapters`. No destructive migration; no backfill required.
- **Backward compatibility:** `BookSourceKind` decoding already falls back to `.text` for
  unknown raw values, so older builds reading a future store degrade gracefully; the
  reader treats a missing chapter list as "flat", identical to today.
- **Teardown:** disabling the flag hides the source and skips the new code path; the model
  stays (harmless) to avoid a destructive migration.

## 10. Risks & open decisions
- **Risk — `libcompression` raw-DEFLATE correctness.** The Compression API distinguishes
  zlib-wrapped vs raw deflate; ZIP stores **raw** deflate. *Mitigation:* a byte-exact
  `MiniZipTests` fixture vs the system `zip` tool; this is the single highest-risk unit.
- **Risk — EPUB variety** (EPUB2 NCX vs EPUB3 NAV, nested ToC, non-linear spine items,
  remote/missing manifest hrefs). *Mitigation:* tolerant parsing — skip non-XHTML and
  missing items, fall back through ToC → heading → "Chapter N"; corpus-test on real books.
- **Risk — zip bombs / malicious archives.** *Mitigation:* per-entry and total inflate
  caps, bounds-checked header reads, traversal-name rejection, external-entities-off XML
  (see NFR-security).
- **Risk — large EPUB main-thread hitch** (same failure mode as PDF). *Mitigation:* depend
  on and land **0017-pdf-background-parsing.md** first / together; EPUB reuses that
  background executor, progress, and cancellation.
- **Decision needed — build vs. invariant (recommend A).**
  - **Option A (recommended):** implement the minimal `Compression`-based reader; keeps the
    **no-third-party-deps** invariant intact. Cost: real, security-sensitive code (~a few
    hundred lines) plus tests.
  - **Option B:** relax CLAUDE.md to allow a vetted ZIP package (e.g. ZIPFoundation).
    Faster, less risk surface in our code, but **breaks a hard invariant** and needs
    explicit **Principal/Owner sign-off**; would also be the app's first SPM dependency,
    changing the "just open the project" build story. Recommend only if A's reader proves
    unreliable across the test corpus.
- **Decision needed — chapter model.** Persist `BookChapter` now (richer reader/roadmap) vs
  keep purely flat and derive chapters lazily. *Recommendation:* persist (additive,
  cheap, enables a ToC jump list and better roadmap segmentation).

## 11. Tasks & estimate
1. **(S)** Add `BookSourceKind.epub`; add `.epub` to `AddBookView.Kind` + `.fileImporter`
   (`UTType.epub`); add `ConnectorError.drmProtected` / `.epubMalformed`.
2. **(L)** `MiniZip.swift`: EOCD + central-directory parse, stored extraction, `libcompression`
   raw-DEFLATE inflate, size caps + bounds checks. **+ `MiniZipTests`.**
3. **(M)** `OPFDocument.swift`: `XMLParser` for container.xml + OPF (metadata/manifest/spine)
   + NAV/NCX ToC titles; external entities disabled.
4. **(M)** `EPUBImporter.swift`: orchestration → text + chapter index → `ParsedBook`; wire
   `ConnectorService.importEPUB`. **+ `EPUBImporterTests`** with a small EPUB fixture.
5. **(S)** `ParsedBook.chapters` + `BookChapter` `@Model` + `Book.chapters` relationship;
   persist chapters in `AddBookView.finish`.
6. **(S)** Reader: optional chapter jump list (or defer to a follow-up if reader work is
   out of scope) — minimally surface chapter titles.
7. **(M)** Integrate with the shared background pipeline (0017-pdf-background-parsing.md):
   progress, cancellation, large-file streaming.
8. **(S)** `AppSettings.epubImportEnabled` flag + dark-launch wiring.
9. **(S)** Manual corpus test + VoiceOver/Reduce-Motion pass; docs note in import help text.

_Rough total: ~1 L + 4 M + 4 S._

## 12. References
- `ios/Mango/Services/Content/ConnectorService.swift`, `HTMLText.swift`, `TextStats.swift`
- `ios/Mango/Features/Library/AddBookView.swift`
- `ios/Mango/Models/Book.swift`, `ios/Mango/Models/Enums.swift`, `RoadmapModels.swift`
- `ios/Mango/Services/Networking/DTOs.swift` (`ParsedBook`)
- `docs/PRODUCT_ROADMAP.md` (item #5), `CLAUDE.md` (no-third-party-deps invariant)
- `working/0017-pdf-background-parsing.md` (shared background pipeline)
- EPUB OCF/Packages spec (W3C/IDPF); Apple Compression framework (`compression_stream`).
