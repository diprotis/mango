# 0036 — Localization foundation

- **Epic:** M13 · **Status:** Draft · **Owner:** unassigned · **Updated:** 2026-06-28
- **Reviewers:** Principal/SD/QA

> Expands **G13** of `working/ARCHITECTURE_REVIEW.md` §3 ("No i18n/localization foundation (string
> catalog)" → 🟡 → NEW `0036` — localization foundation, *plumbing before translating*). This spec
> lays the **plumbing** so the app **and** its Bedrock-generated content can go multilingual; it does
> **not** translate the product yet. v1 = foundation + **one pilot language** end-to-end.

## 1. Summary

Mango is **English-only and hard-codes every user-facing string**: there is no String Catalog, no
`String(localized:)` adoption (a repo grep finds **zero** — the only `.localized*` hits are
`error.localizedDescription` plumbing), and ~**122 string-literal UI call sites** across
`Features/` + `App/` (`Settings` 23, `Profile/Account` 12+8, `Onboarding` 9, `TodayView` 10, … —
~291 raw literals in `Features/` as an upper bound). Locale-aware formatting is essentially absent
(one hand-rolled `DateFormatter` in `ProfileView`). On the backend, the Bedrock prompts
(`shared/prompts.py`) are written in English and **the generated roadmap/track/activities come back
in English** regardless of who is reading; the `0028` shared cache key
(`sha256(promptVersion|modelId|excerptHash)`) has **no locale dimension**, so a multilingual cache
would silently serve the wrong language. `0009` (100-book catalog) is English public-domain, and
`0022` (App Store) explicitly defers localization to "base language only."

This spec establishes the **localization foundation**: (1) adopt a **Xcode String Catalog**
(`Localizable.xcstrings`, Xcode 15+) as the single source of UI strings; (2) a **migration plan**
that extracts hard-coded strings to `String(localized:)`/`LocalizedStringKey` (sweeping the offending
files in waves), backed by a **CI lint that fails new hard-coded user-facing strings**; (3)
**locale-aware formatting** (dates/numbers/plurals via `.formatted`, ICU plurals in the catalog);
(4) **RTL + Dynamic Type** correctness (leading/trailing, mirrored chevrons, pseudolanguage testing);
(5) **pass the user's `locale` to the backend** so Bedrock generates the roadmap/track/activities in
that language — adding `locale` to `RoadmapRequest`, persisting it on the job/track, and **folding it
into the `0028`/`0038` cache key** so caches never cross languages; (6) a **catalog/content language
strategy** (`0009`) and **App Store localized metadata** hooks (`0022`); (7) **pseudolocalization**
for layout testing. The deliverable is the scaffolding + a **pilot language (recommend Spanish
`es`)** wired end-to-end (UI shell + generated content + metadata) — **not** a full translation of
every string.

## 2. Goals / Non-goals

- **Goals:**
  - Adopt a **String Catalog** (`Localizable.xcstrings`) as the canonical UI-string store; build once
    so Xcode auto-extracts existing keys; **no third-party iOS dependency** (CLAUDE.md invariant).
  - A concrete, **wave-based migration** of the ~122 hard-coded call sites to `String(localized:)` /
    `LocalizedStringKey`, with **comments for translators** and **ICU plurals** replacing the manual
    `+ "s"` / ternary pluralization (e.g. `TodayView` "lesson\(…> 1 ? "s" : "")", `OnboardingFlow`).
  - A **CI lint** (`scripts/lint_hardcoded_strings.py` or SwiftLint custom rule) that **fails the
    build** when a new user-facing `Text("…")` / `Label("…")` / `.navigationTitle("…")` / `Button("…")`
    literal is introduced outside an allow-list — preventing regression after the migration.
  - **Locale-aware formatting** everywhere a number/date/duration/percent is shown (Dynamic Type,
    `.formatted()`, `Locale.current`), removing hand-rolled `DateFormatter` usage.
  - **RTL readiness:** audit hardcoded `.leading`/`.trailing`/`.left`/`.right`, directional padding,
    and mirror-sensitive SF Symbols; verify under the **RTL pseudolanguage**.
  - **Generated-content localization:** add a `locale` field to `RoadmapRequest`
    (openapi ⇄ `DTOs.swift` ⇄ `generate_roadmap.py`), inject the target language into the Bedrock
    **prompts** (`shared/prompts.py`), **persist `locale`** on the roadmap job/track, and **extend the
    `0028`/`0038` cache key with `locale`** so per-book caches are partitioned by language.
  - A documented **catalog/content language strategy** (`0009`) and **App Store localized metadata**
    plumbing (`0022`) — directory/process, not full copy.
  - **Pseudolocalization**: a documented scheme/run config (Accented, Double-Length, RTL) to catch
    un-localized strings and cramped layouts before any human translation.
  - Ship a **pilot language (`es`)** end-to-end as the proof: app shell strings translated, generated
    content emitted in `es`, one localized App Store metadata set.
- **Non-goals:**
  - **Translating the entire app** or the 100-book catalog (foundation + pilot only; full locale
    rollout is a follow-up tracked here).
  - A **translation-management vendor / TMS** integration (Lokalise/Phrase/Transifex) — the catalog
    is editable by hand for v1; a TMS is an optional later add (§10).
  - **Server-side UI strings** — the backend returns ids/enums + (now localized) generated content,
    not display chrome; error envelopes stay developer-facing.
  - **Right-to-left visual redesign** beyond making the existing layout mirror correctly.
  - **Per-region pricing/legal** (handled by StoreKit/`0023` + counsel) and **machine-translating
    user reflections** (out of scope; reflections are the user's own words).
  - **Locale-specific content moderation tuning** — `0030` owns Guardrails; this spec only notes that
    safety must hold per-language (a known LLM risk, §10).

## 3. Background & context

**Current state (verified by reading the code).**
- **No catalog, no adoption.** There is **no `*.xcstrings`** anywhere under `ios/`. `grep` for
  `String(localized:`, `NSLocalizedString`, `LocalizedStringKey`, `.localized` across `ios/Mango`
  returns **only** `error.localizedDescription` / `(error as? LocalizedError)?.errorDescription`
  call sites (Networking/Content/Auth) — i.e. **zero** intentional localization. Every visible string
  is a Swift literal passed to SwiftUI, which renders it verbatim.
- **Scale (heuristic counts).** String-literal UI call sites (`Text|Label|Button|navigationTitle|
  TextField|Toggle|Tag|Section|DatePicker|alert|confirmationDialog("…")`) across `Features/` + `App/`
  + `DesignSystem/`: **~122**. Heaviest offenders: `Features/Settings/SettingsView.swift` (**23**),
  `Features/Profile/AccountView.swift` (**12**), `Features/Library/BookDetailView.swift` (9),
  `Features/Onboarding/OnboardingFlow.swift` (9), `Features/Profile/ProfileView.swift` (8),
  `Features/Home/TodayView.swift` (10), `Features/Auth/AuthView.swift` (7),
  `Features/Lesson/LessonView.swift` (7), `Features/Library/AddBookView.swift` (7). Raw double-quoted
  literals in `Features/` total ~**291** (upper bound; includes non-UI strings).
- **Manual pluralization & interpolation** is sprinkled through the UI, e.g. `TodayView`:
  `"Finish \(goalUnits - doneToday) more lesson\(goalUnits - doneToday > 1 ? "s" : "")…"`, the daily-goal
  card, and `OnboardingFlow` level subtitles `"…\(units) lesson\(units > 1 ? "s" : "")/day"`. These
  are exactly the constructs ICU plural rules in a String Catalog replace.
- **Formatting** is barely locale-aware: one `DateFormatter()` in `ProfileView.swift`; percentages are
  built as `"\(Int(progress*100))% complete"` (`TodayView`) — fine for en, wrong grouping/format in
  many locales.
- **Typography is already Dynamic-Type-relative** (`DesignSystem/Typography.swift` — every `Typo`
  token is `Font.system(.<textStyle>, …)`), so Dynamic Type interacts well *today*; localization must
  not regress that (longer strings + larger type is the worst case, §6.4).
- **Backend prompts are English** (`shared/prompts.py`): `_ROADMAP_SYSTEM` / `_GRADE_SYSTEM` are
  English instructions; `roadmap_user(book, profile, excerpt)` and `grade_user(kind, prompt, answer)`
  carry no language hint. `generate_roadmap.py` parses `profile = body.get("profile") or {}` with **no
  `locale`**; `agent.generate_roadmap` returns English JSON. So **all generated content is English**.
- **`RoadmapRequest`** (`shared/api/openapi.yaml` line ~322; `ios/.../Networking/DTOs.swift` line ~84)
  is `{ bookId?, book?, profile }` — **no `locale`** on either side.
- **`0028` cache key** (`working/0028-shared-book-roadmap-cache.md` §6.2,
  `shared/roadmap_cache.py` sketch): `cache_key(promptVersion, modelId, excerpt) =
  sha256("{promptVersion}|{modelId}|{excerpt_hash}")` and the pointer `BOOK#<id>/ROADMAP#latest`
  stores `cacheKey/promptVersion/modelId/excerptHash/engine` — **no `locale`**. `0038` (agentic
  engine) reuses this key and stores the track in S3 (`templates/<bookId>/<ver>.json`). **A localized
  cache would collide** without a locale dimension — the headline correctness fix here.
- **`AppSettings`** (`ios/.../Persistence/AppSettings.swift`) is `@Observable` + `UserDefaults` with a
  `didSet`-writes-`Keys` idiom (`apiEnvironment`, `themePreference`, `reminderEnabled`, a generated
  `deviceId`) — the established place to add an optional **content-language override**.

**Why now.** The product is scaling (catalog to 100 books `0009`, App Store prep `0022`, the agentic
engine `0038`). Retrofitting i18n after thousands more strings and a live multilingual cache is far
costlier than laying the seam now. Crucially, **the generated-content locale + cache-key change must
land before `0028`/`0038` ship to many users**, or the cache will need a painful re-key. This is the
"plumbing before translating" foundation `ARCHITECTURE_REVIEW.md` G13 calls for.

**Related specs.** `0009` (catalog language strategy), `0022` (App Store localized metadata + "base
language only" today), `0028` (cache key — extended here), `0038` (agentic track — `locale` threads
through the pipeline + cache), `0030` (per-language safety must hold), `0010`/`0011`/`0013` (UI specs
whose new strings must be born localized), `0025` (notification copy — localize the reminder body).

## 4. User stories

- As a **Spanish-speaking reader**, I want the app's interface **and** my generated learning journey,
  quizzes, reflections, and grading feedback **in Spanish**, so the whole experience feels native.
- As a **user in any locale**, I want dates, durations, counts, and percentages formatted the way my
  region expects (e.g. "1.234" vs "1,234", localized "min", correct plural forms), so numbers read
  naturally.
- As a **VoiceOver / RTL user** (e.g. Arabic), I want the layout to **mirror** correctly and every
  control to have a localized label, so the app is usable right-to-left.
- As an **engineer**, I want a **String Catalog + a CI lint** so that adding a raw user-facing string
  **fails the build**, keeping the app localizable as it grows.
- As a **translator/localizer**, I want every string to carry a **comment/context** and use **ICU
  plurals**, so I can translate accurately without reading the code.
- As a **release manager**, I want **localized App Store metadata** plumbing so I can ship the pilot
  language's store listing alongside the build.
- As an **offline first-run user**, I want the **base language** (and bundled sample) to work with
  **no network and no key** — localization must not break the offline-first invariant (CLAUDE.md).

## 5. Requirements

### Functional

- **FR-1 (String Catalog adopted).** The app contains a **`Localizable.xcstrings`** String Catalog
  with **development language = `en`**, registered in the build; a clean build extracts existing
  `String(localized:)`/`LocalizedStringKey` usages into it. `CFBundleLocalizations`/`knownRegions`
  include `en` and the pilot `es`.
- **FR-2 (migration to localized strings).** All **user-facing** literals in `Features/` + `App/` (+
  any user-facing strings in `DesignSystem/Components.swift`) are converted to `String(localized:…,
  comment:…)` (non-View code) or `LocalizedStringKey` (SwiftUI `Text`/`Label`/`Button`/
  `.navigationTitle` auto-localize string literals). Each new entry has a **translator comment**.
  Developer-only strings (log messages, `APIError`/`ConnectorError` debug detail, identifiers, asset
  names, URL strings) are **excluded** and may be marked `// i18n-ignore` where the lint would
  otherwise flag them.
- **FR-3 (ICU plurals & interpolation).** Manual pluralization (the `… > 1 ? "s" : ""` and
  `lesson\(n)`/day patterns in `TodayView`, `OnboardingFlow`, the daily-goal card) is replaced with
  **String Catalog plural variations** keyed by a format specifier (e.g.
  `"%lld more lessons to close your ring"` → *Vary by Plural* with `one`/`other`), so any language's
  plural rules (Arabic 6, Polish 4, …) are handled by the catalog, not Swift.
- **FR-4 (no-hardcoded-string lint).** A CI check (`make i18n-lint`, run in `ios-ci`) scans
  `ios/Mango/Features` + `ios/Mango/App` for **new** user-facing string literals in the flagged call
  sites and **fails** on any not covered by `String(localized:)`/`LocalizedStringKey` or an explicit
  `// i18n-ignore`/allow-list entry. The check is **deterministic and offline** (no network).
- **FR-5 (locale-aware formatting).** Dates, times, durations, counts, and percentages shown to users
  use `Date.FormatStyle`/`Measurement`/`.formatted()` / `NumberFormatter` honoring `Locale.current`
  (e.g. `Text(progress, format: .percent)`, `estimatedMinutes` via a localized duration/measurement
  helper). The hand-rolled `DateFormatter` in `ProfileView` is replaced with a locale-aware style.
- **FR-6 (RTL correctness).** Layout uses **leading/trailing** (not left/right); directional padding
  and any mirror-sensitive imagery (chevrons, "play"/back glyphs) mirror under RTL. The app renders
  correctly under the **Right-to-Left pseudolanguage** with no clipped/overlapping/mis-anchored
  elements. (No language need be RTL-translated in v1 — the pseudolanguage is the gate.)
- **FR-7 (Dynamic Type × localization).** With the **Double-Length** (or Accented) pseudolanguage **at
  Dynamic Type XXL**, primary screens (Today, Onboarding, a Lesson, Settings, Profile) show no
  truncation/overlap that breaks usability (text may wrap / the view may scroll). Verifies the
  existing Dynamic-Type-relative `Typo` tokens still hold under longer strings.
- **FR-8 (request carries locale).** `RoadmapRequest` gains an optional **`locale: String`** (BCP-47,
  e.g. `"es"`, `"es-MX"`); the iOS client sends `Locale.current` (or the user's content-language
  override, FR-13). `openapi.yaml` ⇄ `DTOs.swift` ⇄ `generate_roadmap.py` stay in sync. Absent/invalid
  `locale` defaults to `en` (back-compat).
- **FR-9 (prompt in user's language).** `shared/prompts.py` injects the resolved target language into
  the roadmap **and** grading prompts (a `LANGUAGE: <name/code>` directive instructing the model to
  produce **all learner-facing text** — titles, summaries, prompts, options, feedback — in that
  language while keeping the **JSON keys/enum values English/stable**). `grade_user`/`grade_system`
  likewise grade and respond in the learner's language. The book excerpt is passed through unchanged
  (the source text's language is independent of the output language directive).
- **FR-10 (persist locale on job/track).** The resolved `locale` is **persisted** on the roadmap job
  row (and, with `0038`, on the track) so a generated artifact records the language it was produced in
  (auditable, and required for cache correctness).
- **FR-11 (cache partitioned by locale).** The `0028` cache key becomes
  `sha256(promptVersion + "|" + modelId + "|" + locale + "|" + excerptHash)` and the
  `BOOK#<id>/ROADMAP#latest`/`#v<ver>` pointer + `templates/<bookId>/<locale>/<ver>.json` (or a
  `locale` attribute) record the locale, so **a hit only matches same-language requests** — caches
  **never cross languages**. `0038`'s per-book base + per-user overlay both honor the locale key. (The
  excerpt hash stays as-is; locale is an **independent** key dimension.)
- **FR-12 (catalog/content language strategy).** Document the `0009` catalog strategy: catalog
  **metadata** (title/author/blurb/category chips) is localizable via the catalog/known-region
  mechanism (author names typically stay as-is; category **labels** localize); the **generated
  journey** is localized at generation time (FR-9). v1 keeps catalog metadata English with the
  **journey** localized (the high-value surface); full metadata localization is a documented follow-up.
- **FR-13 (content-language override — optional).** `AppSettings` gains an optional
  **`contentLanguage`** (default: follow system `Locale.current`) so a user can request generated
  content in a language different from the UI (e.g. UI in device language, content in `es`). When set,
  it is the `locale` sent in FR-8. (UI strings always follow the OS-selected app language — Apple
  standard.)
- **FR-14 (App Store localized metadata).** Provide the **plumbing** for localized App Store metadata
  (e.g. `fastlane deliver` `metadata/<locale>/` directories, or App Store Connect localizations) for
  `en` + the pilot `es`: name/subtitle/description/keywords/screenshots slots. v1 ships the pilot
  locale's metadata; this extends `0022` (which today is base-language only).
- **FR-15 (notification copy localized).** The daily-reminder body (today an interpolated English
  string built in `OnboardingFlow`/`NotificationService`, `0025`) is moved to the catalog with ICU
  plurals/format and localized, so the pilot language's reminder is in-language.

### Non-functional

- **NFR-1 (offline-first preserved).** Base language + the bundled sample + `MockAIService` work with
  **no network/no key** on first launch (CLAUDE.md). `MockAIService` returns content in the base
  language (`en`); it is not required to be multilingual in v1.
- **NFR-2 (no third-party iOS deps).** String Catalogs + `String(localized:)` + `Locale`/`FormatStyle`
  are first-party. The CI lint is **stdlib Python** or a **SwiftLint custom regex rule** (SwiftLint is
  already used in CI; no new app dependency). No Kingfisher/TMS SDK in the app.
- **NFR-3 (backend invariants).** Bedrock via **IAM only, no API key**; new request field handled in
  **stdlib + boto3** handlers; **no DDB floats** (the cache key/locale are strings); black (100) +
  flake8 (120) clean; `pytest` + `cdk synth -c stage=beta` pass offline (moto + monkeypatched Bedrock).
- **NFR-4 (cost — cache amortization preserved).** Adding `locale` to the key multiplies distinct
  cache entries by **active languages**, not by users: the shared per-book base is still amortized
  across all users of a (book, locale). Pre-warm (`0028`/`0009`) only the **shipped** languages to
  bound cost; do not pre-warm every BCP-47 tag (§10).
- **NFR-5 (quality/safety per language).** Generated-content quality and **`0030` Guardrails** must
  hold in the pilot language (LLM safety/quality degrades off-English — a real risk). v1 limits the
  blast radius to **one well-supported pilot** and keeps a kill-switch (§9/§10).
- **NFR-6 (accessibility).** Localized strings keep VoiceOver labels meaningful; RTL + Dynamic Type
  parity per FR-6/FR-7; pseudolanguages are the automated/visual gate.
- **NFR-7 (no behavior change for en).** Existing English users see **identical** copy/formatting
  (the migration is string-for-string for `en`; the lint and catalog are additive). Old roadmap jobs
  (no `locale`) decode as `en`.

## 6. Design

### 6.1 String Catalog adoption (the canonical store)

- Add **`ios/Mango/Resources/Localizable.xcstrings`** (development language `en`). In Xcode 15+,
  String Catalogs **auto-extract** keys from `String(localized:)`, `Text("…")`, `LocalizedStringKey`,
  `.navigationTitle("…")`, etc. on every build, and surface untranslated/stale states. Set the
  project's **Localizations** to include `es` (pilot) so the catalog shows an `es` column.
- **Idiom:**
  - **SwiftUI views** — a string literal passed to `Text`, `Label`, `Button(_:)`,
    `.navigationTitle`, `TextField(_:)`, `Toggle(_:)` is already a `LocalizedStringKey` and localizes
    automatically once the catalog has the entry. Keep these as literals (they become keys) **but** add
    a comment via the catalog UI or use the explicit form where context is needed.
  - **Non-View / model / service strings** — use
    `String(localized: "key", defaultValue: "English text", comment: "where/why")`. Prefer **semantic
    keys** for reused/parameterized strings (compile-time-checked, code-complete per research) and
    literal-as-key for one-offs.
  - **Interpolation** — use format specifiers (`\(count)` → the catalog records `%lld`/`%@`), enabling
    plural/format variation (FR-3).
- **Organization:** one `Localizable.xcstrings` for v1 (122 strings is small). Note the option to
  namespace into multiple catalogs (e.g. `Onboarding.xcstrings`) if it grows past a few hundred (§10).

### 6.2 Migration plan (waves) + the lint

Migrate in **waves by screen**, each a small PR that (a) converts literals, (b) adds catalog
entries+comments, (c) replaces manual plurals/formatting, (d) leaves `en` output byte-identical:

| Wave | Files (string count) | Notes |
|---|---|---|
| **W1 — foundation + lint** | add `Localizable.xcstrings`; add `make i18n-lint` + CI wiring; convert `App/MainTabView` (5) + `DesignSystem/Components.swift` user-facing (2) as the reference pattern | establishes the idiom + the guardrail first |
| **W2 — Settings & Profile** | `Settings/SettingsView` (23), `Profile/AccountView` (12), `Profile/ProfileView` (8), `Profile/AchievementBadgeView` (1) | the densest cluster; replace `ProfileView`'s `DateFormatter` (FR-5) |
| **W3 — Onboarding & Home** | `Onboarding/OnboardingFlow` (9), `Home/TodayView` (10) | ICU plurals for the lesson-count strings (FR-3); greeting/time logic stays |
| **W4 — Library & Catalog** | `Library/LibraryView` (4), `Library/AddBookView` (7), `Library/BookDetailView` (9), `Catalog/CatalogView` (6) | coordinate with `0009`/`0011` so new strings are born localized |
| **W5 — Lesson, Journey, Reader, Auth** | `Lesson/LessonView` (7), `Lesson/ExerciseRunnerView` (4), `Journey/JourneyView` (4), `Reader/ReaderView` (4), `Auth/AuthView` (7) | `0008` removes the Reader — skip/limit Reader strings if it lands first |
| **W6 — pilot translation + pseudoloc pass** | translate the catalog to `es`; run Accented/Double-Length/RTL pseudolanguages; fix layout | the proof of the foundation |

**Lint (`scripts/lint_hardcoded_strings.py`, stdlib):** regex-scan `.swift` under
`ios/Mango/Features` + `ios/Mango/App` for the flagged constructors with a **bare string literal**
first argument — `Text("…")`, `Label("…", …)`, `Button("…") {`, `.navigationTitle("…")`,
`TextField("…", …)`, `Toggle("…", …)`, `Tag("…"`, `Section("…"`, `.alert("…"`,
`confirmationDialog("…"` — and **fail** unless the line carries `// i18n-ignore` or the literal is in
an allow-list (e.g. SF Symbol names are not matched because they're the `systemImage:` argument, not
the first label). Emit file:line for each violation. Keep it conservative (favor false-negatives over
false-positives) and **pin a baseline**: during migration, run in **`--baseline`** mode that only
fails on counts **above** a per-file recorded baseline, ratcheting to **0** as waves land. (Alternative
: a SwiftLint custom rule with the same regex — SwiftLint already runs in `ios-ci`.)

### 6.3 Locale-aware formatting (FR-5)

- **Percent:** `Text(roadmap.progress, format: .percent)` (or `.formatted(.percent.precision(…))`)
  instead of `"\(Int(progress*100))% complete"`.
- **Counts:** ICU plurals in the catalog (FR-3) — never string-built plurals.
- **Durations / minutes:** a small helper, e.g.
  `Duration.seconds(minutes*60).formatted(.units(allowed: [.minutes], width: .abbreviated))` or a
  `Measurement`-free localized "min" string in the catalog with a plural variation.
- **Dates:** replace `ProfileView`'s `DateFormatter()` with `date.formatted(.dateTime.year().month()
  .day())` (locale/calendar-aware) or a cached `Date.FormatStyle`.
- All read `Locale.current` (the OS app language), so formatting follows the selected language.

### 6.4 RTL + Dynamic Type (FR-6/FR-7)

- **RTL:** grep for `.leading`/`.trailing` (good) vs `.left`/`.right`/`leadingEdge` hardcoding;
  ensure `HStack` ordering and directional `padding(.leading/.trailing)` are used; set
  mirror-sensitive SF Symbols to flip (most do automatically; verify chevrons/`play.fill`/back). The
  **RTL pseudolanguage** (Product → Scheme → Run → App Language → *Right-to-Left Pseudolanguage*) is
  the gate; no human RTL translation required for v1.
- **Dynamic Type:** the `Typo` tokens are already text-style-relative; the risk is **longer localized
  strings × XXL**. Verify wrap/scroll on the five primary screens under **Double-Length** (or Accented)
  pseudolanguage at XXL; fix any fixed-width/`lineLimit(1)` that truncates meaning.

### 6.5 Generated-content localization (the backend seam)

**Contract.** Add `locale` to `RoadmapRequest`:

```yaml
# shared/api/openapi.yaml — RoadmapRequest
RoadmapRequest:
  type: object
  required: [profile]
  properties:
    bookId: { type: string, nullable: true }
    book: { type: object, nullable: true, properties: { title: {type: string}, author: {type: string, nullable: true}, text: {type: string} } }
    profile: { $ref: "#/components/schemas/Profile" }
    locale:  { type: string, nullable: true, description: "BCP-47 (e.g. es, es-MX). Language for generated content. Defaults to en." }
```

```swift
// ios/.../Networking/DTOs.swift
struct RoadmapRequest: Codable, Sendable {
    var bookId: String?
    var book: InlineBook?
    var profile: ProfilePayload
    var locale: String?            // Locale.current.identifier or AppSettings.contentLanguage
}
```

**Handler.** `generate_roadmap.py` resolves the language and threads it through:

```python
profile = body.get("profile") or {}
locale = _normalize_locale(body.get("locale"))          # → "en" default; validate against shipped set
# persist on the job (FR-10) and pass to generation + cache key
roadmap_jobs.create_pending(uid, job_id, book, profile, full_text, book_id, locale=locale)
roadmap = agent.generate_roadmap(book, profile, full_text[:12000], locale=locale)
```

**Prompts.** `shared/prompts.py` gains a language directive (kept simple, JSON-keys stay English):

```python
_LANG_DIRECTIVE = (
    "LANGUAGE: Produce ALL learner-facing text (titles, summaries, prompts, options, feedback) "
    "in {language} ({locale}). Keep JSON keys and enum values (quiz|reflection|application) in English."
)
def roadmap_user(book, profile, excerpt_text, locale="en"):
    return _LANG_DIRECTIVE.format(language=_language_name(locale), locale=locale) + "\n" + (
        f"BOOK: {json.dumps({k: book.get(k) for k in ('title','author','wordCount')})}\n"
        f"READER PROFILE: {json.dumps(profile)}\n"
        f'EXCERPT (use to ground the content):\n\"\"\"\n{excerpt_text[:12000]}\n\"\"\"\n\n'
        "Design the journey now. JSON only."
    )
# grade_user/grade_system similarly carry the directive so feedback is in-language.
```

`_language_name("es") → "Spanish"`; an unknown/unsupported locale falls back to `en` (and the
directive is omitted, preserving today's behavior exactly for `en`).

**Cache (the correctness fix).** Extend `0028`'s `cache_key` and pointer with `locale`:

```python
# shared/roadmap_cache.py (0028) — locale becomes a key dimension
def cache_key(prompt_version: str, model_id: str, locale: str, excerpt: str) -> str:
    basis = f"{prompt_version}|{model_id}|{locale}|{excerpt_hash(excerpt)}"
    return hashlib.sha256(basis.encode("utf-8")).hexdigest()
```

- `BOOK#<id>/ROADMAP#latest` gains a `locale` attribute; templates are stored at
  `templates/<bookId>/<locale>/<ver>.json` (or `<ver>` with `locale` recorded) so **per-language
  bases are distinct**. A generate request only **hits** when `(promptVersion, modelId, locale,
  excerptHash)` all match — so a Spanish reader never receives the English cached base, and vice
  versa. `0038`'s base + overlay both key on locale.
- **Pre-warm** (`0028`/`0009`) runs **per shipped locale** for the catalog (`en` + `es` in v1).

**`0038` thread-through.** The `locale` flows POST → job row → Step Functions execution → each
agent's prompt (Researcher/Planner/Designer write learner-facing text in `locale`; the Personalizer
overlay is language-agnostic ids) → the resolved track records `locale`. The status vocabulary is
unchanged. (`0038` already passes `book`/`profile`/`excerpt` by reference; `locale` is one more small
scalar on the job + cache key.)

### 6.6 iOS plumbing (settings + sending locale)

- `AppSettings`: add optional `contentLanguage: String?` (default `nil` = follow `Locale.current`),
  following the `@Observable` + `UserDefaults` `didSet`/`Keys` idiom; a Settings row lets the user
  pick "Content language" (System / English / Español …) limited to **shipped** locales.
- `RoadmapGenerator`/the catalog "Start journey" path sets
  `request.locale = settings.contentLanguage ?? Locale.current.identifier` when building
  `RoadmapRequest`. No change to the poll path or the offline/Mock path (Mock returns base-language).

### 6.7 App Store localized metadata (FR-14, extends 0022)

- Add a `fastlane/metadata/<locale>/` tree (or App Store Connect localizations) with `name`,
  `subtitle`, `description`, `keywords`, `release_notes`, and per-locale screenshot folders for
  `en-US` + `es-ES` (pilot). `0022`'s release runbook gains a "localized metadata" step. v1 ships the
  pilot's listing; additional locales are additive directories later.

### 6.8 Diagram (generated-content locale + cache)

```
iOS Start-journey
  request.locale = settings.contentLanguage ?? Locale.current        (FR-8/FR-13)
        │  POST /v1/roadmaps/generate { book|bookId, profile, locale }
        ▼
generate_roadmap.py ── _normalize_locale ──► locale ("en" default)
        │  persist locale on job (FR-10)             │ pass to cache + prompts
        ▼                                            ▼
  0028 cache_key(promptVersion, modelId, LOCALE, excerptHash)   ── miss ─► agent.generate_roadmap(..., locale)
        │  hit only if same language (FR-11)                                  │ prompt carries LANGUAGE: <name> (FR-9)
        ▼                                                                     ▼
  BOOK#<id>/ROADMAP#latest {…, locale}  +  templates/<id>/<locale>/<ver>.json   Bedrock → JSON (keys EN, text localized)
        ▼
  poll GET jobs/{id} ─► localized roadmap/track (records locale)
```

### 6.9 Files to add / change (authoritative)

**Add (iOS):**
- `ios/Mango/Resources/Localizable.xcstrings` — the String Catalog (dev language `en`, `es` column).
  *(Auto-picked-up by Xcode 16 file-system-synchronized groups under `ios/Mango/`; resource membership
  via the catalog being in the app target — verify it's compiled into the bundle.)*
- `ios/MangoTests/LocalizationTests.swift` — catalog-lookup + formatting + locale→request unit tests
  (§8).

**Add (repo/CI):**
- `scripts/lint_hardcoded_strings.py` — the no-hardcoded-string lint (stdlib), with `--baseline` mode.
  *(Or a SwiftLint custom rule in `.swiftlint.yml` — pick one in §10 D2.)*
- `fastlane/metadata/en-US/` + `fastlane/metadata/es-ES/` (or ASC localizations) — localized metadata
  (FR-14), extending `0022`.

**Change (iOS):**
- All migrated feature files (waves W2–W5): `Features/Settings/SettingsView.swift`,
  `Features/Profile/{AccountView,ProfileView,AchievementBadgeView}.swift`,
  `Features/Onboarding/OnboardingFlow.swift`, `Features/Home/TodayView.swift`,
  `Features/Library/{LibraryView,AddBookView,BookDetailView}.swift`, `Features/Catalog/CatalogView.swift`,
  `Features/Lesson/{LessonView,ExerciseRunnerView}.swift`, `Features/Journey/JourneyView.swift`,
  `Features/Reader/ReaderView.swift` (if not removed by `0008`), `Features/Auth/AuthView.swift`,
  `App/MainTabView.swift`, `DesignSystem/Components.swift` (user-facing strings only).
- `ios/Mango/Services/Networking/DTOs.swift` — add `locale` to `RoadmapRequest`.
- `ios/Mango/Services/Persistence/AppSettings.swift` — add `contentLanguage` (+ `Keys`).
- `ios/Mango/Services/AI/RoadmapGenerator.swift` (or wherever `RoadmapRequest` is built) — set
  `locale`; `Features/Settings/SettingsView.swift` — a "Content language" picker.
- `ios/Mango/Services/Notifications/NotificationService.swift` + the reminder-body construction
  (`OnboardingFlow`) — move copy to the catalog (FR-15).

**Change (backend):**
- `shared/api/openapi.yaml` — `RoadmapRequest.locale`.
- `backend/src/handlers/generate_roadmap.py` — parse/normalize/persist/forward `locale`.
- `backend/src/shared/prompts.py` — language directive in roadmap + grade prompts (+ `_language_name`).
- `backend/src/shared/roadmap_jobs.py` — store `locale` on the job (FR-10).
- `backend/src/shared/roadmap_cache.py` (`0028`) — `locale` in `cache_key` + pointer/template path
  (FR-11). `0038` track parser/writer — record `locale`.
- `backend/src/shared/agent.py` — pass `locale` through to the prompt builders.
- `backend/tests/` — new tests (§8).

**Change (docs):** `docs/specs/0022-app-store-prep.md` (localized metadata step),
`working/0009-catalog-expansion-100-books.md` (content language note),
`working/0028-shared-book-roadmap-cache.md` + `working/0038-agentic-roadmap-engine.md` (locale key
dimension cross-ref), `working/INDEX.md` (this spec's row), `docs/ARCHITECTURE.md` (i18n note).

## 7. Acceptance criteria

- [ ] **AC-1 (catalog exists & builds).** `Localizable.xcstrings` is in the app target with dev
  language `en` and an `es` localization; a clean build extracts existing localized strings; `es` and
  `en` are in `knownRegions`. *(Build + `make ios-test`.)*
- [ ] **AC-2 (strings migrated).** Every flagged user-facing literal in `Features/` + `App/` resolves
  through the catalog (`String(localized:)`/`LocalizedStringKey`); `en` output is unchanged.
  *(`testNoHardcodedUserFacingStrings` lint at baseline 0; `testCatalogResolvesKnownKeys`.)*
- [ ] **AC-3 (no-hardcoded lint gates CI).** `make i18n-lint` fails on an introduced raw
  `Text("New raw")` and passes once it's localized or `// i18n-ignore`'d; wired into `ios-ci`.
  *(`testLintFailsOnRawLiteral` / `testLintPassesOnLocalized` — fixture-based.)*
- [ ] **AC-4 (ICU plurals).** The lesson-count strings use catalog plural variations; the count "1"
  vs "2" renders the correct form in `en` and `es`. *(`testPluralLessonsCount` via `String(localized:)`
  with a count argument across locales.)*
- [ ] **AC-5 (locale-aware formatting).** Percent/duration/date render per `Locale.current` (verified
  for `en` and a comma-grouping locale); no `"\(Int(progress*100))%"` or bare `DateFormatter` remains
  on user-facing paths. *(`testPercentFormatLocalized`, `testMinutesFormatLocalized`, grep check.)*
- [ ] **AC-6 (RTL).** Under the **RTL pseudolanguage**, the five primary screens mirror correctly (no
  left-anchored content, chevrons flipped, no clipping). *(Manual pseudolanguage run + screenshots.)*
- [ ] **AC-7 (Dynamic Type × length).** Under **Double-Length** pseudolanguage at **XXL**, the five
  primary screens show no usability-breaking truncation/overlap (wrap/scroll OK). *(Manual.)*
- [ ] **AC-8 (request carries locale).** The iOS client includes `locale` in `RoadmapRequest`
  (`Locale.current` or `contentLanguage`); `openapi.yaml` ⇄ `DTOs.swift` ⇄ handler agree; a missing
  `locale` decodes/defaults to `en`. *(`testRoadmapRequestEncodesLocale`; `testGenerateDefaultsLocaleEn`
  pytest.)*
- [ ] **AC-9 (prompt localized).** With `locale="es"`, the roadmap **and** grade prompts contain the
  Spanish language directive; with `locale="en"` (or absent) the prompt is byte-identical to today.
  *(`test_roadmap_prompt_includes_language_directive`, `test_grade_prompt_localized`,
  `test_prompt_unchanged_for_en` — golden-string pytest.)*
- [ ] **AC-10 (locale persisted).** The roadmap job row records the resolved `locale`; `0038` records
  it on the track. *(`test_job_persists_locale` pytest.)*
- [ ] **AC-11 (cache partitioned by locale).** `cache_key(...,'es',...) != cache_key(...,'en',...)` for
  the same book/excerpt; an `es` request does **not** hit an `en`-cached base and vice versa; same
  `(locale, excerpt)` is a hit. *(`test_cache_key_includes_locale`, `test_cache_miss_across_locales`,
  `test_cache_hit_same_locale` pytest — the headline test.)*
- [ ] **AC-12 (App Store localized metadata).** `metadata/en-US/` + `metadata/es-ES/` exist with the
  required fields; the `0022` runbook references the localized step. *(File presence + doc check.)*
- [ ] **AC-13 (pilot end-to-end).** With device language `es`: the app shell shows translated strings,
  a generated journey returns Spanish content, and the reminder body is Spanish. *(Manual `es` device/
  simulator run.)*
- [ ] **AC-14 (invariants).** Offline/Mock first-run works in the base language with no network/key;
  no third-party iOS dep added; backend stays stdlib+boto3, **no DDB floats** (locale is a string),
  black/flake8 clean; `pytest` + `cdk synth -c stage=beta` + `make ios-test` green. *(CI.)*

## 8. Test plan

- **iOS unit (`MangoTests/LocalizationTests.swift`, offline — mirrors `LevelCurveTests` style):**
  - `testCatalogResolvesKnownKeys` (AC-2): `String(localized: "<key>")` for a sample of migrated keys
    returns the `en` value (and `es` value under an `es` bundle/locale override) — proves catalog
    lookups resolve, not the raw key.
  - `testPluralLessonsCount` (AC-4): the lesson-count key with `count: 1` vs `count: 2` yields the
    correct `en` form; with an `es` locale, the correct `es` form. *(Use `String(localized:)` with the
    plural format + an explicit `locale:`.)*
  - `testPercentFormatLocalized` / `testMinutesFormatLocalized` (AC-5): `.formatted(.percent)` /
    duration helper differ appropriately between `en_US` and e.g. `de_DE` (comma decimal) via an
    explicit `Locale`.
  - `testRoadmapRequestEncodesLocale` (AC-8): encoding `RoadmapRequest(locale: "es")` includes
    `"locale":"es"`; decoding a payload **without** `locale` yields `nil` (handler defaults to `en`).
  - `testcontentLanguageOverridePicksLocale` (AC-8/FR-13): `AppSettings.contentLanguage = "es"` →
    the built request's `locale == "es"`; `nil` → `Locale.current.identifier`.
- **CI lint tests (AC-3) — `scripts/lint_hardcoded_strings.py` self-tests / fixtures:**
  - `testLintFailsOnRawLiteral`: a fixture file with `Text("Raw")` exits non-zero with the file:line.
  - `testLintPassesOnLocalized`: `Text("Localized")` that is a known catalog key (or any
    `String(localized:)`) passes; an `// i18n-ignore` line is skipped; `systemImage:`/asset args are not
    flagged.
  - `testBaselineRatchet`: with a recorded baseline, counts **at** baseline pass and **above** fail.
- **Backend unit (pytest, offline — extend prompt/cache tests):**
  - `test_roadmap_prompt_includes_language_directive` / `test_grade_prompt_localized` (AC-9): `locale=
    "es"` → directive naming Spanish present in both prompts; JSON-keys instruction intact.
  - `test_prompt_unchanged_for_en` (AC-9/NFR-7): `locale="en"`/absent → prompt string equals the
    pre-change golden (no directive) so English behavior is provably unchanged.
  - `test_generate_defaults_locale_en` (AC-8): POST without `locale` → handler resolves `"en"`.
  - `test_normalize_locale` : `"es-MX"`→kept/validated, unknown→`"en"`, casing normalized.
  - `test_job_persists_locale` (AC-10): the pending job row carries `locale`.
  - `test_cache_key_includes_locale` (AC-11): `cache_key(pv, m, "es", x) != cache_key(pv, m, "en", x)`;
    equal for equal args.
  - `test_cache_miss_across_locales` / `test_cache_hit_same_locale` (AC-11): seed an `en` base → an
    `es` generate **misses** (new version) and an `en` generate **hits**; templates land under distinct
    `templates/<id>/<locale>/…` paths. *(moto + monkeypatched Bedrock.)*
- **Contract/synth:** `openapi.yaml` ⇄ `DTOs.swift` decode test green; `cdk synth -c stage=beta` green.
- **iOS manual / pseudolocalization (AC-6/AC-7/AC-13):**
  - **Accented** pseudolanguage: scan the five primary screens for any **un-accented** (= un-localized)
    string → fix. **Double-Length** at **Dynamic Type XXL**: check wrap/scroll, no broken truncation.
    **RTL** pseudolanguage: check mirroring + flipped chevrons.
  - **Pilot `es` run:** set the simulator/device to Spanish; verify shell strings, a freshly generated
    journey (Spanish content), and the Spanish reminder body.
- **Regression:** `make ios-test` (no `en` behavior change), backend `pytest` (existing 29 + new), and
  the offline/Mock first-run path.

## 9. Rollout & migration

- **Sequencing.** Land **W1 (catalog + lint)** first so all subsequent UI specs (`0010`/`0011`/`0013`)
  add **born-localized** strings. Land the **backend locale seam (FR-8–FR-11) before `0028`/`0038` ship
  broadly** so the cache is locale-partitioned from day one (avoids a painful re-key of a populated
  cache). Migration waves W2–W5 are independent small PRs (ratchet the lint baseline down each wave).
  W6 (pilot `es` + pseudoloc) is the proof.
- **Flags / config.** A backend **`SUPPORTED_CONTENT_LOCALES`** set (default `{"en","es"}`) gates which
  `locale` values are honored (others fall back to `en`) — a **kill-switch** to disable a language if
  quality/safety regresses (NFR-5). iOS only offers shipped locales in the "Content language" picker.
- **Backward compatibility.**
  - **Contract:** `locale` is **optional/additive**; old clients omit it → `en` (no breaking change).
  - **Data:** old roadmap jobs/tracks without `locale` are treated as `en`; the cache key change rolls
    a new `cacheKey` (and, until pre-warmed, the next generate per (book, locale) is a one-time miss).
  - **`en` users:** see identical strings/formatting (string-for-string migration; directive omitted
    for `en`).
- **Pre-warm.** Run `0028`/`0009` pre-warm **per shipped locale** for the catalog so pilot users hit a
  warm Spanish cache; do **not** pre-warm unsupported locales (cost bound, NFR-4).
- **Teardown / backout.** Remove `es` from `SUPPORTED_CONTENT_LOCALES` (content falls back to `en`
  instantly) and/or hide the picker; the catalog/lint are additive and harmless if a language is
  paused. Reverting a migration wave is a normal PR revert (the catalog keeps the `en` values).
- **Docs.** Update `0022` (localized metadata), `0009` (content language), `0028`/`0038` (locale key),
  `INDEX.md`, and `docs/ARCHITECTURE.md`.

## 10. Risks & open decisions

- **R-1 Migration scale / churn.** ~122 sites across 16 files. *Mitigation:* wave-based small PRs +
  the **baseline-ratchet lint** so partial migration is enforceable and reviewable; `en` output stays
  byte-identical so diffs are mechanical.
- **R-2 Cache explosion across locales.** Key now includes `locale`. *Mitigation:* entries scale by
  **shipped languages**, not users; the per-book base is still amortized per (book, locale); pre-warm
  only shipped locales; `SUPPORTED_CONTENT_LOCALES` bounds the set.
- **R-3 LLM quality/safety off-English.** Generated content + `0030` Guardrails are weaker outside
  English. *Mitigation:* **one well-supported pilot (`es`)** in v1, a **kill-switch**, and `0030`
  safety re-verified for the pilot before enabling; keep medical/crisis disclaimers (`0030`) in the
  target language.
- **R-4 Mixed-language confusion.** UI language (OS) vs content language (override) can differ.
  *Mitigation:* default content to follow `Locale.current`; the override (FR-13) is opt-in and clearly
  labeled; both default to the same thing for most users.
- **R-5 Pseudoloc misses dynamic strings.** Server-generated content isn't pseudolocalized.
  *Mitigation:* the **prompt directive + cache-key** tests (AC-9/AC-11) cover the generated path; the
  pilot `es` run is the end-to-end check.
- **R-6 RTL regressions in future PRs.** *Mitigation:* keep the RTL pseudolanguage in the QA checklist;
  the leading/trailing lint-grep can be added to `make i18n-lint` as a soft warning.
- **Decisions needed (with recommendation):**
  - **D-1 Pilot language.** *Recommend `es` (Spanish)* — large audience, excellent LLM support, Latin
    script (lower RTL/encoding risk for the first pass). (Alternatives: `pt-BR`, `fr`.)
  - **D-2 Lint mechanism.** Standalone **stdlib Python** script vs **SwiftLint custom rule**.
    *Recommend the Python script* (`make i18n-lint`) for the `--baseline` ratchet + precise messaging,
    runnable independently of SwiftLint; optionally also add a SwiftLint rule later.
  - **D-3 Content-language override (FR-13).** Ship the override now vs follow `Locale.current` only.
    *Recommend shipping the override* (cheap; enables "English UI, Spanish journey" and decouples the
    cache-locale from the OS language for testing).
  - **D-4 Catalog metadata localization (FR-12).** Localize catalog metadata now vs journey-only.
    *Recommend journey-only for v1* (the high-value surface); document full metadata localization as a
    follow-up.
  - **D-5 TMS integration.** Hand-edited catalog vs a TMS (Lokalise/Phrase). *Recommend hand-edited for
    v1* (one pilot language); revisit a TMS when ≥3 languages or non-engineer translators are involved.
  - **D-6 Template path vs attribute for locale (FR-11).** Encode `locale` in the S3 template **path**
    (`templates/<id>/<locale>/<ver>.json`) vs a DDB attribute only. *Recommend both* — path for
    human/debug clarity, attribute on the pointer for queries; the **cache key** is the correctness
    gate either way.

## 11. Tasks & estimate

1. **(M)** W1: add `Localizable.xcstrings` (dev `en`, add `es`); convert `MainTabView` +
   `Components.swift` as the reference pattern; verify catalog membership/extraction.
2. **(M)** Build `scripts/lint_hardcoded_strings.py` (flagged constructors, `// i18n-ignore`,
   allow-list, `--baseline` ratchet) + self-tests; wire `make i18n-lint` into `ios-ci`.
3. **(M)** W2: migrate `Settings`, `Profile/Account`, `Profile`, `AchievementBadge` (~44 strings);
   replace `ProfileView`'s `DateFormatter` (FR-5).
4. **(M)** W3: migrate `Onboarding` + `TodayView`; convert manual plurals → **ICU plural** catalog
   entries; localize the daily-goal/greeting strings.
5. **(M)** W4: migrate `Library/*` + `Catalog` (coordinate with `0009`/`0011`).
6. **(M)** W5: migrate `Lesson/*`, `Journey`, `Reader` (skip if `0008` removed it), `Auth`.
7. **(S)** Locale-aware formatting helpers (percent/duration/date) + replace remaining string-built
   formats; grep-clean.
8. **(S)** Backend: add `locale` to `openapi.yaml` + `DTOs.swift` + `RoadmapGenerator` (send
   `contentLanguage ?? Locale.current`); `AppSettings.contentLanguage` + Settings picker.
9. **(M)** Backend: `generate_roadmap.py` parse/normalize/persist/forward `locale`; `prompts.py`
   language directive (roadmap + grade) + `_language_name`/`_normalize_locale`; `roadmap_jobs.py`
   persist `locale`; `agent.py` pass-through.
10. **(M)** Extend `0028` `roadmap_cache.py` cache key + pointer/template path with `locale`; thread
    `locale` through `0038`'s track writer; `SUPPORTED_CONTENT_LOCALES` gate + pre-warm per locale.
11. **(S)** Notifications: move reminder copy to the catalog + localize (FR-15).
12. **(S)** App Store localized metadata: `metadata/en-US/` + `metadata/es-ES/`; extend `0022` runbook.
13. **(M)** W6: translate the catalog to `es`; run Accented/Double-Length/RTL pseudolanguages; fix
    layout; pilot `es` end-to-end pass.
14. **(M)** Tests: iOS (`LocalizationTests`) + backend (prompt/locale/cache) + lint self-tests + synth;
    drive the lint baseline to **0**.
15. **(S)** Docs: `INDEX.md` row, `0009`/`0022`/`0028`/`0038` cross-refs, `ARCHITECTURE.md` i18n note.

*Rough total: ~9 M + 5 S, landable incrementally behind the lint baseline + `SUPPORTED_CONTENT_LOCALES`.*

## 12. References

**Repo (read for accuracy):** `CLAUDE.md` (no-3rd-party-deps, offline-first, stdlib+boto3, no-floats,
keep-openapi-in-sync invariants); `working/ARCHITECTURE_REVIEW.md` §3 G13; `ios/Mango/DesignSystem/
Typography.swift` (Dynamic-Type-relative `Typo`); the migrated feature files
(`Features/{Settings,Profile,Onboarding,Home,Library,Catalog,Lesson,Journey,Reader,Auth}`,
`App/MainTabView.swift`); `ios/Mango/Services/Networking/DTOs.swift` (`RoadmapRequest`);
`ios/Mango/Services/Persistence/AppSettings.swift`; `backend/src/shared/prompts.py`;
`backend/src/handlers/generate_roadmap.py`; `shared/api/openapi.yaml` (`RoadmapRequest`);
`working/0028-shared-book-roadmap-cache.md` (§6.2 cache key — extended here);
`working/0038-agentic-roadmap-engine.md` (locale through the pipeline);
`working/0009-catalog-expansion-100-books.md` (English catalog); `working/0022-app-store-prep.md`
(base-language-only today); `working/0010-onboarding-redesign.md`, `working/0025-notifications.md`,
`docs/specs/SPEC_TEMPLATE.md`.

**Research (web, verified 2026-06):**
- Apple — *Localizing and varying text with a string catalog* (`.xcstrings`, Xcode 15+; auto-extract;
  plural/device/substitution variations) — https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog
- Apple — *Preparing your interface for localization* / *Testing localizations when running your app*
  (pseudolanguages: Accented, Double-Length, Right-to-Left, Bounded — enabled via the Run scheme) —
  https://developer.apple.com/documentation/xcode/preparing-your-interface-for-localization · https://developer.apple.com/documentation/xcode/testing-localizations-when-running-your-app/
- SimpleLocalize — *iOS localization 2026: `.strings`, `.xcstrings` & String Catalogs* (Editor →
  Convert to String Catalog migration; key-based `String(localized:)`; incremental, not all-or-nothing)
  — https://simplelocalize.io/blog/posts/manage-ios-translation-files/
- tanaschita — *Pluralization with String Catalogs* (ICU plural rules via a format specifier; Vary by
  Plural; languages have differing plural categories) — https://tanaschita.com/20230710-pluralization-with-string-catalogs/
- Nil Coalescing — *Check localizable strings with the accented pseudolanguage in Xcode* (spot
  un-localized strings via the Accented pseudolanguage in the scheme) — https://nilcoalescing.com/blog/CheckLocalizableStringsWithAccentedPseudolanguage/
- Global Tech Council — *Designing Multilingual Chatbots: Localization* (prompt the model with **locale
  tags + explicit style/formality rules**; define in-scope locales + fallback; localize units/dates) —
  https://www.globaltechcouncil.org/chatbot/designing-multilingual-chatbots-localization-strategies-translation-pitfalls/
- Forrester — *AI Can Make You Multilingual Overnight — Or Create Chaos* (LLM **safeguards/quality do
  not reliably carry beyond English**; treat localization as strategy, not a switch — basis for the
  one-pilot, kill-switch, per-language-safety stance) — https://www.forrester.com/blogs/ai-can-make-you-multilingual-overnight-or-create-chaos-just-as-fast/
