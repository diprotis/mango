# 0009 — Catalog expansion to 100+ books (public-domain sources)

- **Epic:** M11 · **Status:** Draft · **Owner:** unassigned · **Updated:** 2026-06-26
- **Reviewers:** Principal/SD/QA

## 1. Summary
Grow the Mango catalog from the current 3-entry static "dummy shelf" to **at least
100 license-clear, public-domain titles** curated for the app's domain (personal
development, philosophy, classic non-fiction). The catalog is the app's **discovery
surface**: a user browses, picks a title, and immediately starts an **activity-based
journey** (quizzes / reflections / application tasks). Per the product reframe in
`0008-product-reframe-activity-first.md`, **the in-app Reader is being removed** — a
catalog item no longer ships full reading text and the "Create roadmap" action launches
an activity journey, not a reader. We do this with a **build-time ingestion script**
(Python, stdlib + `requests`) that queries **Gutendex** (Project Gutenberg metadata),
enriches with **Open Library** covers, optionally pulls a small set of high-quality
**Standard Ebooks** classics, normalizes everything to an extended `CatalogBook` schema,
and emits a **generated JSON file shipped with the backend** (`catalog_seed.json`). The
catalog endpoint gains pagination + filtering to serve 100+ items, and iOS gains a
browsable / searchable / filterable grid with real cover art and an offline fallback.

## 2. Goals / Non-goals
- **Goals:**
  - Ship a curated catalog of **≥100 public-domain titles** with title, author, one
    category, a short blurb, and a cover, every one of which **starts a journey**.
  - Source titles **programmatically and reproducibly** from license-clear APIs
    (Gutendex primary; Open Library covers; Standard Ebooks for a curated subset).
  - Encode the licensing reality: lean on **public-domain classics**; explicitly exclude
    still-in-copyright "expected" titles (Carnegie, Hill, Covey, …) with a note.
  - Add browsing affordances: **categories/tags**, **search**, and **pagination** so a
    100+ shelf is usable on a phone.
  - Extend the data model (`CatalogBook`: `categories`, `coverURL`, `source`, `license`,
    `gutenbergId`) and keep **openapi.yaml ⇄ DTOs.swift ⇄ handlers** in sync.
- **Non-goals:**
  - **No in-app reading.** We are not shipping or rendering full book text for the
    reader (the reader is removed in `0008`). Full-text fetch is out of scope here.
  - No user-generated / imported books (that's the connector path, unchanged).
  - No personalization/ranking model (that's `0020-feature-store-personalization.md`).
  - No localized (non-English) catalog in v1.
  - No live, request-time calls to Gutendex/Open Library from Lambda (ingestion is
    **build-time**, not on the hot path).

## 3. Background & context
**Current state (verified).** `backend/src/shared/catalog_data.py` is a hand-written list of **3
entries** (`dummy-meditations`/`dummy-aesop`/`dummy-self-reliance`) each carrying a short inline
`text`; `wordCount`/`estimatedMinutes` are **derived** in `_build_catalog()` so they never drift,
and `DUMMY_BOOK_ID = "dummy-meditations"` is the integration-harness anchor. The handler
`backend/src/handlers/catalog.py` (a thin wrapper over `list_items()`/`get_item()`) serves
`GET /v1/catalog` → `ok({"items": list_items()})` (text stripped) and `GET /v1/catalog/{id}` →
`ok(item)` (detail, includes `text`) / `not_found` for unknown ids. Both routes are **public**
(`security: []` in `openapi.yaml:235–260`). The contract (`openapi.yaml` → `CatalogBook`) and the
iOS DTOs (`ios/Mango/Models/CatalogBook.swift` — `CatalogBook` + `CatalogBookDetail`, both with
lenient `init(from:)`) model `id, title, author, excerpt, coverHue, wordCount, estimatedMinutes
[, text]`. iOS renders rows in `CatalogView.swift` (`CatalogRow`) via a generated `BookCover` (a
colored gradient from `coverHue` — **no image**), with an offline fallback bundle
`CatalogSamples` (2 titles today). The flow today: pick a book → `app.catalog().detail(id)` →
`bookFromDetail` seeds/updates a `Book` (`sourceKind = .sample`, `sourceValue = "catalog:<id>"`) →
`RoadmapGenerator.generate` (which uses the **async** POST `/v1/roadmaps/generate` → 202 `{jobId}`
→ poll job path) → `JourneyView`. The catalog detail's `text` only matters as a **generation
input** (`book.fullText`, truncated to ≤12k chars before the prompt) — already not used for
display.

**Why now.** Three titles is a demo, not a catalog. The `0008` reframe makes the catalog
the *primary* entry point ("discover → start an activity journey"), so it must feel like
a real shelf. Because we no longer read in-app, we are freed from the heavy constraint
that every catalog entry carry full public-domain text inline — we only need **metadata
+ a cover + enough context to generate activities**. That makes a 100+ catalog cheap to
ship.

**Dependency on `0008`.** This spec assumes the activity-first reframe: the detail
endpoint no longer needs to return full `text`, and the journey is generated from
**title/author/summary/subjects/category** rather than the book body. If `0008` has not
landed, see §10 (Open decisions) for the interim shim.

Related: `docs/specs/0004-data-model-and-lake.md` (DynamoDB single table, `BOOK#<id>/META`),
`docs/PRODUCT_ROADMAP.md` (M11), `docs/BACKEND.md`.

## 4. User stories
- As a **new user**, I want to browse a rich shelf of well-known classics, so that I
  immediately find something worth my time and start learning.
- As a **user**, I want to **filter by category** (Stoicism, Success & Habits, Eastern
  philosophy, Ethics, …) and **search by title/author**, so that I can find a book that
  fits my goal.
- As a **user**, I want each book to show a **real cover + author + a one-line "why"**,
  so the shelf feels trustworthy and curated, not auto-generated.
- As a **user**, I want to tap a book and **start an activity journey** (quiz / reflect /
  apply) without reading the book in-app, so I learn by doing.
- As a **maintainer**, I want to **regenerate the catalog from a script**, so adding or
  re-curating titles is reproducible and license-traceable.
- As **legal/compliance**, I want each catalog item to record its **source + license +
  attribution**, so we can prove every shipped title is license-clear.

## 5. Requirements

### Functional
- **FR-1 (≥100 titles).** The shipped catalog contains **≥100 unique, license-clear,
  public-domain (US) titles** in the personal-development / philosophy / classic
  non-fiction domain. (Target ~120 ingested → curate to ≥100 after dedupe/QA.)
- **FR-2 (fields).** Every catalog item has: stable `id`, `title`, `author` (nullable),
  `excerpt` (curated or summary-derived blurb), at least one `categories[]` entry, a
  `coverURL` (or a deterministic generated fallback), `source`, `license`, and
  `gutenbergId` when sourced from Gutenberg.
- **FR-3 (browse).** `GET /v1/catalog` supports **pagination** (`limit`, `cursor`/`page`)
  and **filtering** (`category`, `q` free-text over title+author) and **never returns
  full book text** in list mode.
- **FR-4 (detail/start).** `GET /v1/catalog/{id}` returns the full item metadata needed
  to **start a journey** (title, author, summary, subjects, category). It does **not**
  require full body text (per `0008`).
- **FR-5 (start a journey).** Selecting a catalog item creates/activates a `Book` from
  the catalog metadata and routes into the activity `JourneyView`. No reader is opened.
- **FR-6 (ingestion script).** A build-time Python script (`backend/scripts/build_catalog.py`)
  queries the sources, normalizes to the schema, resolves cover URLs/ids, applies the
  curated allow-list, and writes a deterministic `catalog_seed.json` plus a human-readable
  `CATALOG_SOURCES.md` provenance report. It is **idempotent** and **offline-safe**
  (re-runnable; caches raw API responses).
- **FR-7 (exclusions).** Titles that are **not** license-clear in the US (e.g. Carnegie
  *How to Win Friends* 1936, Covey, Peale, Frankl, Goggins, Clear) are **excluded**, with
  a documented "expected but excluded" list and the reason.
- **FR-8 (covers + fallback).** When a remote cover is unavailable or fails to load, iOS
  renders the existing **generated `coverHue` cover** so the grid never shows a blank.
- **FR-9 (contract sync).** `openapi.yaml`, `DTOs.swift`/`CatalogBook.swift`, and the
  handler all reflect the extended schema and the new query params.

### Non-functional
- **NFR-1 (offline first-run).** Per the project invariant, first launch works fully
  offline: iOS falls back to a **bundled subset** (≥12 titles) of the same catalog when
  the backend is unreachable (Mock/Offline). Generated covers mean no network is needed
  to render.
- **NFR-2 (no third-party iOS deps).** Cover loading uses **`AsyncImage`** (SwiftUI,
  built-in) — no Kingfisher/SDWebImage.
- **NFR-3 (cost / hot path).** No per-request external API calls from Lambda. The catalog
  is static generated data (JSON in the deployment bundle, or a pre-seeded DynamoDB
  table). List responses are cacheable (`Cache-Control`).
- **NFR-4 (license traceability).** Every item carries `source` + `license`; the build
  emits an auditable provenance file. Covers are **referenced by URL** (hotlinked to
  Open Library / Gutenberg), not bulk-downloaded, honoring the providers' "display, not
  bulk-download" guidance (§6/§10).
- **NFR-5 (payload size).** A full list page is ≤ ~50 items and ≤ ~100 KB; the full
  generated seed (≥100 items, no body text) is well under ~250 KB.
- **NFR-6 (accessibility).** Covers have `accessibilityLabel` = title + author; category
  chips are reachable by VoiceOver; tap targets ≥ 44pt.
- **NFR-7 (attribution).** A "Sources" footer in the Catalog screen credits Project
  Gutenberg, Open Library, and Standard Ebooks (courtesy attribution; see §6).

## 6. Sources & licensing

### 6.1 Source comparison

| Source | API / access | Returns | Auth / rate limit | License of the *text/metadata* | Attribution requirement | Mango use |
|---|---|---|---|---|---|---|
| **Project Gutenberg via Gutendex** | `https://gutendex.com/books` (JSON REST) | id, title, authors (name + birth/death year), subjects, bookshelves, languages, `copyright` flag, `summaries`, `formats` (MIME→URL), `download_count` | **No key**; no published/known rate limit (be polite: cache + throttle). Public hosted instance; self-host option exists. | Works are **US public domain** (filter `copyright=false`). Metadata is freely usable. | Courtesy: credit Project Gutenberg; do not imply PG endorses Mango. PG **trademark** must not be used on altered text — we ship no text, only metadata, so this is low-risk. | **Primary metadata source** (title/author/subjects/popularity/PG id). |
| **Open Library** | Search: `https://openlibrary.org/search.json`; Covers: `https://covers.openlibrary.org/b/{key}/{value}-{size}.jpg` (`key`∈ id/olid/isbn/oclc/lccn; `size`∈ S/M/L) | Search: work key, title, author, `cover_i`, `ia`, subjects, edition info. Covers: a JPEG. | **No key.** Covers by **CoverID/OLID are unlimited**; by ISBN/OCLC/LCCN limited to **100 req / IP / 5 min** (HTTP 403 over limit). Covers API is for **display, not bulk download**. | Metadata under **CC0/ODbL-style open data**; covers may be third-party — **hotlink for display**, do not redistribute/bulk-download. | "Courtesy link back to Open Library is appreciated." | **Cover art** (`coverURL` via `cover_i`/OLID) + fallback metadata/ISBN. |
| **Standard Ebooks** | OPDS feeds at `https://standardebooks.org/feeds` (OPDS + Atom/RSS). Per-book pages have cover images. | High-quality, well-formatted **US public-domain** editions: title, author, subjects, cover, download links. | **New-Releases** Atom/RSS feed is **open to everyone**; access to the **other ebook feeds (full OPDS catalog)** requires one of: **Patrons Circle** donation, **producing an ebook** for SE (lifetime access), or **corporate sponsorship** (verified 2026 — see §15). No hard rate limit documented; be polite. | **Content produced by/for Standard Ebooks is CC0 1.0** (public-domain dedication) — the *most* license-clean option, including covers. | CC0 requires none; courtesy credit is good form. | **Curated subset** of ~20–30 flagship classics for premium covers/blurbs (where full-catalog access is arranged) **or** hand-map a small SE subset via the open New-Releases feed + per-book public pages. |
| **Wikidata** | SPARQL `https://query.wikidata.org/sparql` or REST | Canonical work entity, author, publication year, subject (P921), identifiers (Gutenberg ID P2034, OL ID P648, ISBN). | **No key**; SPARQL has fair-use throttling. | **CC0** (data). | None (CC0). | **Cross-reference / enrichment** to resolve PG id ⇄ OL id ⇄ canonical author/year, and to confirm public-domain via author death year. |

### 6.2 Recommendation
- **Primary:** **Gutendex** for the title set + author + subjects + popularity + PG id.
  Filter `copyright=false&languages=en`, then `topic=`/`search=` per subject (§ below),
  ranked by `download_count` to surface the recognizable classics.
- **Covers:** **Open Library Covers** keyed by **CoverID (`cover_i` from search.json)**
  to stay in the *unlimited* tier and avoid the ISBN 403 throttle. Resolve via one
  `search.json?q=<title author>&fields=cover_i,key,edition_key` lookup per title at
  **build time** (not at request time).
- **Curated classics:** **Standard Ebooks** for a flagship subset (best covers + CC0).
  If full-catalog OPDS access isn't arranged for v1, map ~20 known SE titles by hand and
  hotlink their public cover URLs, or fall back to Open Library covers for those.
- **Enrichment:** **Wikidata** to disambiguate author/edition and double-check PD status
  (author death year) for any title where Gutendex's `copyright` flag is `null`.

### 6.3 Licensing reality — what we can and cannot ship
- **Can ship (US public domain):** pre-1929 works, plus 1929–1963 works **not renewed**.
  The classic personal-development/philosophy canon is overwhelmingly here.
- **Notable PD edge cases we *can* ship:** **Napoleon Hill, *Think and Grow Rich* (1937)**
  is **US public domain** because its copyright was **not renewed** in the 28th year
  (verify edition; the 1937 text only — not modern annotated revisions). Treat with care
  and cite the renewal-lapse rationale in provenance.
- **Cannot ship (still in US copyright) — "expected but excluded":**
  - Dale Carnegie, *How to Win Friends and Influence People* (1936, **renewed 1964**).
  - Stephen Covey, *The 7 Habits of Highly Effective People* (1989).
  - Norman Vincent Peale, *The Power of Positive Thinking* (1952).
  - Viktor Frankl, *Man's Search for Meaning* (1946/1959, est.).
  - Modern titles: James Clear *Atomic Habits*, Mark Manson, David Goggins, Brené Brown,
    Carol Dweck *Mindset*, Cal Newport, Ryan Holiday's *The Obstacle Is the Way*
    (Holiday is modern even though it popularizes Stoicism — exclude, but **include the
    Stoic sources** it draws on).
  - **Rule of thumb encoded in the script:** reject anything with `copyright=true`, any
    author with `death_year` within US-copyright range and no renewal-lapse evidence, and
    a hard-coded **deny-list** of the above titles by normalized title key.

## 7. Curation

### 7.1 How we pick ~100 titles
1. **Seed by subject queries** against Gutendex (`copyright=false&languages=en`), e.g.
   `topic=philosophy`, `topic=ethics`, `topic=conduct of life`, `topic=success`,
   `topic=self-culture`, `search=stoic`, `search=self-help`, `search=character`,
   `search=will power`, plus targeted `ids=` for known classics.
2. **Rank by `download_count`** within each subject to favor recognizable, high-quality
   titles; take the top N per category.
3. **Map to a fixed category taxonomy** (§7.2). Each book gets exactly one **primary
   category** (for the filter) and may carry extra free-text `subjects` (from Gutendex)
   as secondary tags for search.
4. **De-duplicate** by normalized `(title, author)` and by Gutenberg "also-by" reissues
   (prefer the most-downloaded English edition; drop duplicate translations).
5. **Apply the deny-list** (§6.3) and the `copyright`/death-year filter.
6. **Enrich**: resolve Open Library `cover_i` for a cover; write a one-line curated
   **"why"** blurb (authored, falling back to a trimmed Gutendex `summaries[0]`).
7. **QA to ≥100**: review the generated `CATALOG_SOURCES.md`, drop weak/oddball matches,
   hand-add any missing canon, re-run.

### 7.2 Category taxonomy (browse/filter)
A small, legible set (each maps to a filter chip in iOS):

| Category (id) | Display | Example anchors |
|---|---|---|
| `stoicism` | Stoicism | Marcus Aurelius, Epictetus, Seneca |
| `success_habits` | Success & Self-Mastery | Smiles, Marden, Allen, Wattles, Conwell, Hill |
| `eastern_philosophy` | Eastern Philosophy | Lao Tzu, Confucius, Sun Tzu |
| `ethics_virtue` | Ethics & Virtue | Aristotle, Plato, Kant, Cicero |
| `mind_psychology` | Mind & Psychology | William James, Atkinson, Trine, Émile Coué |
| `wisdom_essays` | Wisdom & Essays | Emerson, Thoreau, Montaigne, Bacon, Schopenhauer |
| `lives_letters` | Lives & Letters | Franklin's *Autobiography*, Plutarch, Boethius |
| `leadership_strategy` | Leadership & Strategy | Sun Tzu, Machiavelli, Clausewitz, Xenophon |
| `spiritual_classics` | Spiritual Classics | *Tao Te Ching*, *Dhammapada*, *Imitation of Christ*, Gibran (PD subset) |

(Use 6–9 categories so the filter bar fits a phone; `success_habits`, `stoicism`,
`ethics_virtue`, and `wisdom_essays` will be the deepest.)

### 7.3 Representative starter list (named, with PG id + why)
All verified public-domain on Project Gutenberg; ids confirmed via Gutendex/PG.

| # | Title | Author | Category | PG id | Why it's in the catalog |
|---|---|---|---|---|---|
| 1 | Meditations | Marcus Aurelius | Stoicism | 2680 | The canonical Stoic journal; daily practice maps perfectly to activity prompts. |
| 2 | The Enchiridion | Epictetus | Stoicism | 45109 | Short, punchy handbook of control vs. acceptance — ideal for micro-lessons. |
| 3 | Of a Happy Life / Letters | Seneca | Stoicism | (author 1308) | Stoic letters on time, anger, and adversity — rich reflection material. |
| 4 | Self-Reliance & other essays | Ralph Waldo Emerson | Wisdom & Essays | 16643 / 2945 | "Trust thyself" — foundational self-development essay. |
| 5 | Walden; & Civil Disobedience | Henry David Thoreau | Wisdom & Essays | 205 | Deliberate living and simplicity; great for "apply it" tasks. |
| 6 | As a Man Thinketh | James Allen | Success & Self-Mastery | 4507 | The seed text of "mindset" literature; tiny and quotable. |
| 7 | Self-Help | Samuel Smiles | Success & Self-Mastery | 935 | The Victorian original of the genre — character + perseverance. |
| 8 | The Science of Getting Rich | Wallace D. Wattles | Success & Self-Mastery | (PG) | The "law of attraction" precursor; concrete action framing. |
| 9 | Acres of Diamonds | Russell H. Conwell | Success & Self-Mastery | (PG) | Famous lecture: opportunity is where you already stand. |
| 10 | Pushing to the Front | Orison Swett Marden | Success & Self-Mastery | (PG) | Prolific motivational classic; abundant exercise hooks. |
| 11 | Think and Grow Rich (1937) | Napoleon Hill | Success & Self-Mastery | (PD, not renewed) | Recognizable name; ship only the PD 1937 text (see §6.3). |
| 12 | Nicomachean Ethics | Aristotle | Ethics & Virtue | 8438 | Virtue, habit, and the mean — the philosophical backbone of "habits." |
| 13 | The Republic | Plato | Ethics & Virtue | 1497 | Justice and the good life; strong discussion/quiz material. |
| 14 | Apology / Crito | Plato | Ethics & Virtue | 1656 / 1657 | Short Socratic dialogues; excellent for reflection prompts. |
| 15 | Tao Te Ching | Lao Tzu | Spiritual Classics | 216 | 81 short verses — each verse is a ready-made micro-lesson. |
| 16 | The Analects | Confucius | Eastern Philosophy | 3330 | Aphoristic ethics of conduct and learning. |
| 17 | The Art of War | Sun Tzu | Leadership & Strategy | 132 | Strategy applied to everyday decisions; very "apply it"-friendly. |
| 18 | The Prince | Niccolò Machiavelli | Leadership & Strategy | 1232 | Power and pragmatism; debate-style activities. |
| 19 | Autobiography of Benjamin Franklin | Benjamin Franklin | Lives & Letters | 20203 | The original "13 virtues" self-improvement system. |
| 20 | The Consolation of Philosophy | Boethius | Lives & Letters | 14328 | Adversity and fortune; reflective and timeless. |
| 21 | Essays | Francis Bacon | Wisdom & Essays | 575 | Compact essays on studies, adversity, fortune. |
| 22 | Essays of Schopenhauer | Arthur Schopenhauer | Wisdom & Essays | 10732 | On reading, thinking, and will — provocative discussion. |
| 23 | The Essays (Montaigne) | Michel de Montaigne | Wisdom & Essays | 3600 | The inventor of the personal essay; introspection at its best. |
| 24 | The Varieties of Religious Experience | William James | Mind & Psychology | 621 | Psychology of habit, will, and belief from a founder of the field. |
| 25 | In Tune with the Infinite | Ralph Waldo Trine | Mind & Psychology | (PG) | Early New-Thought wellbeing classic. |
| 26 | Thought-Force in Business and Everyday Life | William W. Atkinson | Mind & Psychology | (PG) | Practical "mental power" exercises. |
| 27 | The Imitation of Christ | Thomas à Kempis | Spiritual Classics | 1653 | Devotional self-discipline; daily-practice structure. |
| 28 | The Prophet | Kahlil Gibran | Spiritual Classics | (PD US) | Lyrical life lessons (US PD — verify edition). |
| 29 | Plutarch's Lives (selections) | Plutarch | Lives & Letters | 674 | Character studies of great lives; modeling + reflection. |
| 30 | An Iron Will | Orison Swett Marden | Success & Self-Mastery | (PG) | Bite-size willpower classic; perfect first journey. |

(The remaining ~70 come from deeper cuts in the same authors/categories — e.g. more
Marden, Seneca letters, Cicero *On Duties*, Epictetus *Discourses*, Kant *Fundamental
Principles of the Metaphysic of Morals*, Xenophon, Cleanthes/Stoic anthologies, Émile
Coué *Self-Mastery Through Conscious Autosuggestion*, Florence Scovel Shinn *The Game of
Life* (verify PD), Charles Haanel *The Master Key System* (1916, PD), Wattles *Science of
Being Great*, Smiles *Character*/*Thrift*/*Duty*, Dhammapada, Bhagavad Gita (trans.),
Bacon, Seneca *On the Shortness of Life*, etc. — all selected by the script and pinned in
`catalog_seed.json`.)

> Ids marked "(PG)"/"(PD)" are resolved and pinned by the ingestion script at build
> time; only ids that were directly verified during research are written numerically
> above. The script writes the exact id + source URL into `CATALOG_SOURCES.md`.

## 8. Pipeline (build-time ingestion)

### 8.1 Decision: generated JSON seed (v1), DynamoDB table (if it must scale)
**Recommendation: ship a generated `catalog_seed.json` with the backend for v1.** The
catalog is small (≥100 items, no body text, ≤ ~250 KB), read-only, and changes only when
we re-curate. A static file loaded into memory by the Lambda is the simplest, cheapest,
testable option and keeps the hot path free of external calls. We add **in-handler
pagination + filtering** over the in-memory list.

Promote to a **DynamoDB `BOOK#<id>/CATALOG` seed** (single table, per `0004`) **only if**
the catalog grows large enough to page from storage, needs partial updates without a
redeploy, or needs server-side filtering at scale. Design the loader behind an interface
so the data source can swap from JSON → DynamoDB without touching the handler contract.
(See §10 decision.)

### 8.2 Script: `backend/scripts/build_catalog.py`
Stdlib + `requests` (a dev/build dependency only — **not** added to the Lambda runtime,
honoring "Lambdas use stdlib + boto3 only"). Pseudocode:

```
INPUTS:
  curation.yaml         # category → {gutendex queries, explicit PG ids, hand-adds}
  deny_list.txt         # normalized titles we must never ship (Carnegie, Covey, …)
  standard_ebooks.csv   # optional curated SE subset (title, author, cover_url)

STEPS:
  1. For each category query: GET gutendex.com/books?copyright=false&languages=en&<q>
     - page through `next`; collect candidate Books (cache raw JSON under .cache/).
  2. Filter: drop copyright!=false; drop deny-listed (normalized title); de-dupe by
     (normalized_title, author); keep top-N per category by download_count.
  3. For each kept book, resolve a cover:
     - GET openlibrary.org/search.json?q=<title author>&fields=cover_i,key,edition_key&limit=1
     - if cover_i: coverURL = https://covers.openlibrary.org/b/id/<cover_i>-L.jpg
     - else if SE subset has it: use SE cover URL
     - else: coverURL = null  (iOS uses generated coverHue cover)
  4. Optionally enrich via Wikidata (author death year / canonical year) for any book
     whose gutendex `copyright` was null.
  5. Normalize to CatalogBook schema (id = "pg-<gutenbergId>" or "se-<slug>"):
     { id, title, author, excerpt, categories[], coverURL, source, license,
       gutenbergId, coverHue (stable hash of title for fallback) }
  6. Curate excerpt: prefer authored blurb (curation.yaml) else trim summaries[0] to ~160 chars.
  7. Assert len(catalog) >= 100; write catalog_seed.json (sorted, pretty) +
     CATALOG_SOURCES.md (id, title, author, source URL, license, why).

OUTPUTS:
  backend/src/shared/catalog_seed.json     # shipped with the backend
  backend/CATALOG_SOURCES.md               # provenance / license audit
```

Run via a Makefile target, e.g. `make catalog-build` (documented in `OPERATIONS.md`).
The script is **idempotent** (stable sort, cached responses) and **rate-polite**
(throttle + on-disk cache so re-runs don't re-hit the APIs).

### 8.3 `catalog_data.py` change
`catalog_data.py` stops hand-listing books and instead **loads `catalog_seed.json`** at import time
into the same `CATALOG`/`_BY_ID` structures (`json.load` from a path next to the module; stdlib
only, no new Lambda dep), then exposes `get_item()` as today (returns the dict incl. `text` if the
seed has none, simply absent) plus a paginating/filtering `list_items`. **Keep `DUMMY_BOOK_ID`
stable for the integration harness** — change it to `"pg-2680"` (Meditations) **and** update the two
backend tests that reference the old id (`backend/tests/test_catalog.py`, which asserts
`body["wordCount"] == len(body["text"].split())` — relax this when `text` is dropped) so the suite
stays green. Concrete signatures:
```python
def list_items(category: str | None = None, q: str | None = None,
               limit: int = 50, cursor: str | None = None) -> tuple[list[dict], str | None]:
    """Filter + page the catalog (text omitted). Returns (items, next_cursor)."""
```
- **Filtering** is a pure pass over the in-memory `CATALOG`: `category` = exact match on any entry
  in `categories[]`; `q` = case-insensitive substring on `title` + `author`. `text` is always
  stripped (`{k: v for k, v in item.items() if k != "text"}` as today).
- **Cursor** is an **opaque offset token** (simplest deterministic scheme): `next_cursor =
  base64(str(offset + limit))` when more remain, else `None`; decode with a tolerant helper that
  returns offset `0` on any malformed/oversized value. `limit` is clamped to `1..50`. Keep these as
  small **pure functions** (`_filter`, `_encode_cursor`, `_decode_cursor`) so they unit-test without
  the handler (§12).

### 8.4 Serving 100+ via `GET /v1/catalog`
- **Pagination:** `?limit=<=50&cursor=<opaque>`; response becomes `{ "items": [...], "nextCursor":
  string|null }`. Default `limit=50`.
- **Filtering:** `?category=<id>` (exact) and `?q=<text>` (case-insensitive substring on
  title+author). Both applied in-handler over the in-memory list.
- **List shape:** the list-mode response gains `nextCursor` alongside `items`; `text` is never
  present. The **detail** response (`GET /v1/catalog/{id}`) drops `text` (per `0008`).
- `Cache-Control: public, max-age=86400` since the catalog is static per deploy.
- **Handler change (`catalog.py`)** — read params from `event.get("queryStringParameters") or {}`,
  call `list_items(...)`, and add the header via `ok(...)`. The current `ok`/`not_found` helpers
  in `shared.response` return the JSON body; if `ok` doesn't already accept headers, either extend
  it or build the response dict inline. Sketch:
  ```python
  def handler(event, context):
      book_id = _book_id_from_path(event)
      if book_id:
          item = get_item(book_id)
          if item is None:
              return not_found("unknown catalog id")
          return ok({k: v for k, v in item.items() if k != "text"})   # detail, text dropped (0008)
      qs = event.get("queryStringParameters") or {}
      items, next_cursor = list_items(
          category=qs.get("category"), q=qs.get("q"),
          limit=int(qs.get("limit", 50) or 50), cursor=qs.get("cursor"),
      )
      return ok({"items": items, "nextCursor": next_cursor},
                headers={"Cache-Control": "public, max-age=86400"})
  ```
  (Verify the `ok` signature in `shared/response.py` before assuming a `headers=` kwarg; this is the
  one place the handler stops being a pure passthrough.)

### 8.5 iOS browse/search/filter
- `CatalogView` becomes a **grid** (`LazyVGrid`, 2–3 columns) of cover cards with a
  **category chip bar** (horizontal `ScrollView`) and a **`.searchable`** field.
- Filtering/search hit the API params when online; when using the bundled fallback they
  filter the local array.
- **Infinite scroll**: load the next page on reaching the end (`nextCursor`).
- Tap a card → existing **start-a-journey** flow (now without a text fetch): build a
  `Book` from catalog metadata → `RoadmapGenerator.generate` → `JourneyView`.

## 9. Design

### 9.1 API / contract (keep `openapi.yaml` in sync)
- **`GET /v1/catalog`** — add query params and a cursor to the response:
  ```yaml
  parameters:
    - { name: category, in: query, required: false, schema: { type: string } }
    - { name: q,        in: query, required: false, schema: { type: string } }
    - { name: limit,    in: query, required: false, schema: { type: integer, default: 50, maximum: 50 } }
    - { name: cursor,   in: query, required: false, schema: { type: string } }
  responses:
    "200":
      content:
        application/json:
          schema:
            type: object
            properties:
              items:      { type: array, items: { $ref: "#/components/schemas/CatalogBook" } }
              nextCursor: { type: string, nullable: true }
  ```
- **`GET /v1/catalog/{id}`** — returns the extended `CatalogBook` **without** `text`
  (reader removed). Keep `404` for unknown id.
- **`CatalogBook` schema** — extend and **deprecate/remove `text`**:
  ```yaml
  CatalogBook:
    type: object
    properties:
      id:               { type: string }
      title:            { type: string }
      author:           { type: string, nullable: true }
      excerpt:          { type: string }
      categories:       { type: array, items: { type: string } }
      coverURL:         { type: string, nullable: true, description: "Open Library / Standard Ebooks cover; null → generated cover" }
      coverHue:         { type: integer, description: "0-360; generated-cover fallback" }
      source:           { type: string, enum: [gutenberg, standard_ebooks, open_library] }
      license:          { type: string, example: "Public Domain (US)" }
      gutenbergId:      { type: integer, nullable: true }
      wordCount:        { type: integer, nullable: true }
      estimatedMinutes: { type: integer, nullable: true }
      # NOTE: `text` removed — the in-app reader is gone (0008). Journey is generated
      # from title/author/summary/category, not the body.
  ```
  *(If `0008` hasn't shipped yet, keep `text` nullable and have the detail endpoint omit
  it; the iOS journey path must already tolerate an empty body — see §10.)*

### 9.2 Data model (DynamoDB, per `0004`)
- v1: **no DynamoDB change** — catalog is the in-bundle `catalog_seed.json`.
- If promoted to storage: store each item as `PK=BOOK#<id>`, `SK=CATALOG`, with `GSI1PK=
  CATALOG#<category>` / `GSI1SK=ZPAD#<10-digit zero-padded (1e9 − downloadCount)>` so a
  `begins_with` query on `GSI1PK` returns a category **most-downloaded-first** (DynamoDB sorts SKs
  lexicographically, so encode the descending order as a zero-padded string — **not** a negative
  number, which the resource API would reject as needing care). Store `categories` as a DynamoDB
  **list of strings**; `coverURL`/`source`/`license`/`gutenbergId(as string)` as strings.
- **Float-free invariant:** `coverHue`, `wordCount`, `estimatedMinutes`, `gutenbergId` are **ints**
  in the seed JSON (note: iOS models `coverHue` as `Double` but it round-trips fine from an int).
  If any value is ever computed as a Python `float`, coerce to `int` before `put_item` (per
  `CLAUDE.md` / `progress.py`). The JSON-seed path (v1) sidesteps this entirely — it's
  `json.load`-ed, not written through the DynamoDB resource API.

### 9.3 iOS (screens, state, services; design tokens)
- **`CatalogBook` / `CatalogBookDetail` DTOs** (`Models/CatalogBook.swift`): add the new fields and
  extend the existing **lenient** `init(from:)` (lines 40–49 / 88–98) so older/partial payloads
  still decode (mirrors how `coverHue` already defaults to 28). New stored properties + decode:
  ```swift
  let categories: [String]      // decodeIfPresent ?? []
  let coverURL: URL?            // decodeIfPresent(URL.self) ?? nil  (URL decodes from a string)
  let source: String            // decodeIfPresent ?? "gutenberg"
  let license: String           // decodeIfPresent ?? "Public Domain (US)"
  let gutenbergId: Int?         // decodeIfPresent ?? nil
  // wordCount/estimatedMinutes already default to 0; CatalogBookDetail.text already defaults to ""
  ```
  Add the matching `CodingKeys` cases and constructor params (with defaults, so existing call sites
  like `CatalogSamples.all` keep compiling). Add the page wrapper:
  ```swift
  struct CatalogPage: Decodable, Sendable {
      let items: [CatalogBook]
      let nextCursor: String?
  }
  ```
- **`CatalogService`** (`Services/Content/CatalogService.swift`): replace `list() -> [CatalogBook]`
  (lines 18–22, which decodes the private `CatalogListResponse`) with a paginating variant that
  decodes `CatalogPage` and builds the query string from non-nil params:
  ```swift
  func list(category: String? = nil, q: String? = nil,
            limit: Int = 50, cursor: String? = nil) async throws -> CatalogPage {
      guard let client else { throw APIError.notConfigured }
      var items = [URLQueryItem]()
      if let category { items.append(.init(name: "category", value: category)) }
      if let q, !q.isEmpty { items.append(.init(name: "q", value: q)) }
      items.append(.init(name: "limit", value: String(limit)))
      if let cursor { items.append(.init(name: "cursor", value: cursor)) }
      // build "/v1/catalog?<encoded>" via URLComponents; reuse client.getJSON
      return try await client.getJSON(path)
  }
  ```
  Keep `detail(_:)` (lines 25–29) as-is. `CatalogPage` replaces the now-unused `CatalogListResponse`.
- **`CatalogView`** (`Features/Catalog/CatalogView.swift`): `LazyVGrid` of `CatalogCard`s,
  category chip bar, `.searchable`, paginated `.task`/`onAppear` loading, pull-to-refresh.
  Pull colors/spacing/type from `Palette`/`Typo`/`Metrics` (no hardcoded hex).
- **`CatalogCard`**: `AsyncImage(url: book.coverURL)` with a `BookCover(title:hue:)`
  placeholder/failure view → guarantees a cover offline (NFR-1/FR-8). Title (2 lines),
  author (1 line), a category `Tag`, and a primary **"Start journey"** button (rename
  from "Create roadmap" per `0008`).
- **`CatalogSamples`** (`Features/Catalog/CatalogSamples.swift`): expand the bundled
  fallback to **≥12** items mirroring `catalog_seed.json` (covers via `coverHue`, no
  remote URL needed) so first-run/offline is rich. Optionally generate this file from the
  same build script to avoid drift.
- **Attribution**: a small "Covers via Open Library · Texts via Project Gutenberg &
  Standard Ebooks" footer in `CatalogView`.

### 9.4 Diagram (build + serve)
```
[build time]  curation.yaml ─┐
                             ├─► build_catalog.py ──► catalog_seed.json ──► (shipped in backend bundle)
 Gutendex ──► (metadata) ────┤                         └► CATALOG_SOURCES.md (audit)
 Open Library ─► (cover_i) ──┘
 Standard Ebooks / Wikidata ─► (enrich)

[request time]  iOS Catalog ──GET /v1/catalog?category&q&limit&cursor──► Lambda
                                  (in-memory filter+page over catalog_seed.json) ──► {items,nextCursor}
                iOS cover ◄── AsyncImage hotlinks covers.openlibrary.org (fallback: generated coverHue)
                iOS tap ──► build Book from metadata ──► RoadmapGenerator ──► JourneyView (no reader)
```

### 9.5 Files to add / change (authoritative)
**Add (backend):**
- `backend/scripts/build_catalog.py` — build-time ingestion (Gutendex + OL covers + normalize +
  dedupe + provenance). Dev-only dep `requests` (not in the Lambda runtime).
- `backend/scripts/curation.yaml`, `backend/scripts/deny_list.txt`, optional
  `backend/scripts/standard_ebooks.csv` — curation inputs.
- `backend/src/shared/catalog_seed.json` — **generated**, shipped in the Lambda bundle.
- `backend/CATALOG_SOURCES.md` — **generated** provenance/license audit.
- `backend/tests/fixtures/*.json` — captured Gutendex/OL responses for the pure-function tests.

**Change (backend):** `backend/src/shared/catalog_data.py` (load JSON + `list_items` filter/paging),
`backend/src/handlers/catalog.py` (query params + `nextCursor` + `Cache-Control`),
`backend/tests/test_catalog.py` (new id + extended assertions), `Makefile` (`catalog-build` target),
`docs/OPERATIONS.md` (SOP).

**Change (contract + iOS):** `shared/api/openapi.yaml` (`CatalogBook` fields, query params,
`nextCursor`, drop `text`), `ios/Mango/Models/CatalogBook.swift` (+`CatalogPage`),
`ios/Mango/Services/Content/CatalogService.swift` (params/paging),
`ios/Mango/Features/Catalog/CatalogView.swift` (grid + chips + `.searchable` + infinite scroll +
"Start journey" CTA — coordinate with `0008`), `ios/Mango/Features/Catalog/CatalogSamples.swift`
(expand to ≥12), `ios/MangoTests/CatalogBookTests.swift` (extended/lenient decode + `CatalogPage`).
All new Swift files are auto-registered by Xcode 16 file-system-synchronized groups.

## 10. Risks & open decisions
- **Risk — covers unavailable / hotlink breakage / 403 throttle.** *Mitigation:* key
  covers by **CoverID** (unlimited tier), resolve at build time, and **always** ship a
  generated `coverHue` fallback so a missing/blocked cover never shows blank.
- **Risk — Open Library "display, not bulk-download" / cover redistribution.** *Mitigation:*
  we **reference** cover URLs (hotlink), do not bulk-download or re-host. If we later need
  to self-host covers, prefer **Standard Ebooks (CC0)** covers or generated covers.
- **Risk — Standard Ebooks full OPDS feed gated.** *Mitigation:* v1 uses the open
  New-Releases feed + a hand-mapped SE subset, or skips SE covers and uses Open Library;
  pursue the **open-source project** access grant for the full feed (contact required).
- **Risk — mislabeling a copyrighted title as PD.** *Mitigation:* triple gate
  (`copyright=false` + author death-year/Wikidata + explicit deny-list), and a human QA
  pass on `CATALOG_SOURCES.md` before shipping. *Think and Grow Rich* specifically is PD
  only as the **non-renewed 1937 text** — pin the exact edition.
- **Risk — `0008` not landed (reader still present).** *Mitigation (interim shim):* keep
  `text` nullable; the catalog ships **without** text and the journey is generated from
  metadata. Confirm `RoadmapGenerator`/AI prompts can build a roadmap from
  title/author/summary alone before removing the text dependency.
- **Decisions needed:**
  1. **Storage: generated JSON seed (recommended for v1)** vs DynamoDB catalog table.
     *Recommendation: JSON now; DynamoDB only if it must scale/partial-update.*
  2. **Standard Ebooks: pursue full OPDS access now** vs ship Open Library covers only.
     *Recommendation: ship with Open Library covers; add SE covers opportunistically.*
  3. **Catalog size target: exactly 100 vs ~120 curated.** *Recommendation: ingest ~120,
     curate to ≥100.*
  4. **Ship Think and Grow Rich?** Recognizable but needs careful edition pinning.
     *Recommendation: include the verified non-renewed 1937 text with a provenance note;
     drop if QA can't confirm the edition.*

## 11. Acceptance criteria
- [ ] **AC-1** `catalog_seed.json` contains **≥100 unique titles**, each with `id`,
  `title`, `author`, ≥1 `categories`, `source`, `license`, and either `coverURL` or a
  `coverHue` fallback. (`pytest` asserts count + required fields.)
- [ ] **AC-2** No deny-listed/copyrighted title appears; every item is `source=gutenberg|
  standard_ebooks|open_library` and `license` indicates US public domain. (`pytest`.)
- [ ] **AC-3** `GET /v1/catalog` paginates (`limit`/`cursor`) and filters
  (`category`, `q`); list responses contain **no** `text`. (`pytest`.)
- [ ] **AC-4** `GET /v1/catalog/{id}` returns the extended schema and `404`s unknown ids.
- [ ] **AC-5** iOS Catalog shows a **grid with real covers**, a working **category
  filter** and **search**, and **infinite scroll**; offline it falls back to ≥12 bundled
  titles with generated covers. (Manual + snapshot.)
- [ ] **AC-6** Tapping any catalog item **starts an activity journey** (no reader is
  presented) and reaches `JourneyView`. (Manual.)
- [ ] **AC-7** `openapi.yaml` ⇄ `CatalogBook.swift`/`DTOs.swift` ⇄ `catalog.py` are in
  sync (DTO decode test passes; `cdk synth` passes).
- [ ] **AC-8** `CATALOG_SOURCES.md` provenance file lists every title's source URL +
  license and is regenerated by `make catalog-build`.

## 12. Test plan
- **Unit (pytest, offline — extend `backend/tests/test_catalog.py`):**
  - `test_seed_has_at_least_100_unique_titles` (→ AC-1): `len(CATALOG) >= 100`; ids unique; every
    item has `id/title/author/categories(≥1)/source/license` and (`coverURL` or `coverHue`).
  - `test_deny_list_enforced` (→ AC-2): assert known-copyrighted normalized titles (Carnegie/Covey/
    Peale/Clear/Manson) are **absent**; every `source ∈ {gutenberg, standard_ebooks, open_library}`
    and `license` indicates US public domain.
  - `test_list_items_filters_and_pages` (→ AC-3): `category` exact match; `q` substring on
    title+author (case-insensitive); `limit` clamp to 1..50; `nextCursor` round-trips
    (`_decode_cursor(_encode_cursor(n)) == n`); last page → `nextCursor is None`; **no `text`** key
    in any list item.
  - `test_get_item` (→ AC-4): known id returns item; unknown id → `None`/`404` at the handler.
  - Pure-function tests for the ingestion script (`backend/scripts/build_catalog.py`):
    `test_normalize_title`, `test_dedupe_by_title_author`, `test_category_map`, `test_excerpt_trim`
    (≤160 chars), `test_cover_url_builder` (`cover_i` → `https://covers.openlibrary.org/b/id/<id>-L.jpg`),
    each fed **fixture API JSON** under `backend/tests/fixtures/` (no live network).
- **Integration (pytest):** `test_catalog_handler_paginates` (→ AC-3) asserts the
  `{items, nextCursor}` shape + `Cache-Control: public, max-age=86400` header; `404` path for an
  unknown id.
- **Contract:** iOS `CatalogBookTests` (extend the existing file) — `testDecodesExtendedFields`
  (categories/coverURL/source/license/gutenbergId present), `testLenientDecodeMissingNewFields`
  (absent → defaults: `categories == []`, `coverURL == nil`, `source == "gutenberg"`),
  `testCatalogPageDecodes` (items + `nextCursor` nullable). `cdk synth -c stage=beta` passes.
- **iOS (XCUITest/manual):** grid renders (`LazyVGrid`); `AsyncImage` falls back to `BookCover`
  generated cover when `coverURL` nil or load fails (AC-5); category chip + `.searchable`; infinite
  scroll on `nextCursor`; offline shows the ≥12 bundled subset; tapping a book reaches `JourneyView`
  with no reader (AC-6).
- **Manual/live smoke:** run `make catalog-build` against live Gutendex/Open Library, eyeball
  `CATALOG_SOURCES.md` (→ AC-8) for licensing sanity and cover coverage.

## 13. Rollout & migration
- **Build the catalog** (`make catalog-build`), review provenance, commit
  `catalog_seed.json` + `CATALOG_SOURCES.md`.
- **Backend:** deploy to **beta** behind no flag (static data, low risk); verify the
  paginated endpoint; then **prod**.
- **iOS:** ship the grid + DTO changes; the bundled fallback guarantees first-run works
  offline. Old `id`s change (`pg-2680` vs `dummy-meditations`) — but catalog ids are not
  persisted long-term except as a `Book.sourceValue`, so re-adding simply creates a fresh
  `Book`; document this. Keep one stable id for the integration harness.
- **Sequencing:** land **after** (or alongside) `0008` so the reader removal and the
  "Start journey" rename are consistent. If shipping before `0008`, use the §10 shim.
- **Teardown/backout:** revert to the previous `catalog_data.py` (3 items) — endpoint
  shape is backward compatible (extra fields are additive; pagination params are
  optional).

## 14. Tasks & estimate
1. **(M)** Write `curation.yaml` (category queries, explicit PG ids, hand-adds) +
   `deny_list.txt`.
2. **(L)** Build `backend/scripts/build_catalog.py` (Gutendex + Open Library covers +
   normalize + dedupe + provenance), with caching + pure-function unit tests.
3. **(S)** Run it, curate to **≥100**, commit `catalog_seed.json` + `CATALOG_SOURCES.md`.
4. **(M)** Rework `catalog_data.py` to load the JSON + add filter/pagination helpers;
   update `catalog.py` handler (params + `nextCursor` + `Cache-Control`).
5. **(S)** Update `openapi.yaml` (`CatalogBook` fields, query params, `nextCursor`, drop
   `text`).
6. **(M)** Update iOS DTOs (`CatalogBook`/`CatalogBookDetail`/`CatalogPage`) +
   `CatalogService` (params/paging) + decode tests.
7. **(L)** Rebuild `CatalogView` as a grid (covers via `AsyncImage` + generated
   fallback, category chips, `.searchable`, infinite scroll, "Start journey"); expand
   `CatalogSamples` to ≥12.
8. **(M)** Tests: pytest (count/fields/deny-list/filter/paging) + iOS decode/UI + `cdk
   synth`; wire `make catalog-build`; note SOP in `OPERATIONS.md`.
9. **(S)** Attribution footer + accessibility labels; QA pass on licensing.

## 15. References
> **Verified (2026-06) via web search** — the four load-bearing source/licensing claims were
> re-confirmed during enrichment: (1) Gutendex `copyright=true|false|null` + comma-separated
> two-char `languages` params and no-auth/popularity-ordered JSON; (2) Open Library Covers are
> **unlimited by CoverID/OLID**, **100 req / IP / 5 min** by ISBN/OCLC/LCCN (HTTP 403 over limit),
> "for display, not bulk download"; (3) Standard Ebooks content + covers are **CC0 1.0**, the
> New-Releases Atom/RSS feed is open but the **full OPDS catalog** requires Patrons Circle /
> producing an ebook / corporate sponsorship; (4) *Think and Grow Rich* (1937) is **US public
> domain via non-renewal** (1909 Act 28-yr term, renewal deadline ~1965 missed) — ship the 1937
> text only, not modern annotated revisions.

- Gutendex API docs — <https://gutendex.com/> · source <https://github.com/garethbjohnson/gutendex>
- Open Library Covers API (CoverID unlimited; ISBN/OCLC/LCCN 100/IP/5min → 403) — <https://openlibrary.org/dev/docs/api/covers>
- Open Library Search API — <https://openlibrary.org/dev/docs/api/search> · Subjects API <https://openlibrary.org/dev/docs/api/subjects> · APIs index <https://openlibrary.org/developers/api>
- Standard Ebooks feeds (open New-Releases; gated full OPDS — Patrons Circle / produce-an-ebook / corporate sponsorship) — <https://standardebooks.org/feeds> · CC0 dedication <https://creativecommons.org/publicdomain/zero/1.0/>
- Wikidata SPARQL — <https://query.wikidata.org/> (Gutenberg id = P2034, Open Library id = P648, subject = P921)
- 2026 in public domain — <https://en.wikipedia.org/wiki/2026_in_public_domain>
- *Think and Grow Rich* (1937) PD/non-renewal — <https://zerolimits.org/is-think-and-grow-rich-in-the-public-domain/>
- *How to Win Friends* still in copyright — <https://en.wikipedia.org/wiki/How_to_Win_Friends_and_Influence_People>
- Verified PG ids — Meditations <https://www.gutenberg.org/ebooks/2680>, Enchiridion <https://www.gutenberg.org/ebooks/45109>, As a Man Thinketh <https://www.gutenberg.org/ebooks/4507>, Self-Help (Smiles) <https://www.gutenberg.org/ebooks/935>, Nicomachean Ethics <https://www.gutenberg.org/ebooks/8438>, Tao Te Ching <https://www.gutenberg.org/ebooks/216>, Art of War <https://www.gutenberg.org/ebooks/132>, Walden <https://www.gutenberg.org/ebooks/205>
- Internal: `backend/src/shared/catalog_data.py`, `backend/src/handlers/catalog.py`,
  `shared/api/openapi.yaml` (CatalogBook + /v1/catalog), `docs/specs/0004-data-model-and-lake.md`,
  `ios/Mango/Models/CatalogBook.swift`, `ios/Mango/Features/Catalog/CatalogView.swift`,
  `ios/Mango/Features/Catalog/CatalogSamples.swift`, `ios/Mango/Services/Content/CatalogService.swift`,
  `working/0008-product-reframe-activity-first.md` (reader removal / activity-first).
