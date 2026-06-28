# 0010 — Onboarding redesign (swipe-through, animated)

- **Epic:** M11 · **Status:** Draft · **Owner:** unassigned · **Updated:** 2026-06-26
- **Reviewers:** Principal, SD, QA

## 1. Summary
Replace Mango's current step-indexed, vertically-scrolling onboarding
(`OnboardingFlow.swift` — a `step: Int` 0…4 driving a `ScrollView` + linear
`ProgressView` + a Back/Continue footer) with a **paged, right-swipe carousel**
that feels alive: spring-driven page transitions, light parallax on the hero
art, progress **dots**, and a haptic tick on each advance. The redesign also
**reframes the product up front** to match `0008-product-reframe-activity-first.md`:
the very first value screens make clear that **you read on your own — Mango is
your activities + journey coach**, not a reader. The flow captures the same
`UserProfile` data it does today (name, goals, interests, reading level, daily
goal, reminder time) plus a dedicated **notification-priming** page, ends with an
**optional, non-blocking sign-in**, and drops the user straight into their first
journey. Every motion is **reduce-motion-aware** (instant fallback) and **swipe is
never the only way forward** — a persistent primary button and accessible
controls advance the flow for VoiceOver and Switch Control users. All visuals use
DesignSystem tokens only; the two emoji in the current flow (`🥭`) are removed in
favor of theme icons (icon set deferred to `0013`).

## 2. Goals / Non-goals
- **Goals:**
  - A **4–6 page**, horizontally-paged onboarding with **right-swipe progression**
    and subtle, branded motion (spring page change, hero parallax, dot indicator,
    haptic on advance).
  - **Set expectations correctly** per `0008`: "read on your own; Mango coaches the
    active-learning loop (activities + journey + XP/streaks)" — communicated on the
    value and "how it works" pages.
  - Capture the **same profile data** as today and persist it idempotently to the
    single `UserProfile` (`name`, `goals`, `interests`, `readingLevel`,
    `dailyGoalUnits`, `reminderHour`/`reminderMinute`, `hasOnboarded`).
  - **Notification priming**: a value-first pre-permission page that explains *why*
    and *how often* before the OS prompt, with a clear "Maybe later".
  - **Optional sign-in** reachable at the end of onboarding (reuse `AuthView`),
    never blocking — offline-first invariant preserved.
  - **Accessibility parity**: full keyboard/VoiceOver/Switch-Control path that does
    not depend on the swipe gesture; honors **Reduce Motion** and **Dynamic Type**.
  - **Tokens only** — `Palette`/`Typo`/`Metrics`/`Haptics` (+ a new small `Motion`
    token group); no raw hex, no magic numbers, no emoji.
- **Non-goals:**
  - Designing/finalizing the **icon set** — that is `0013` (this spec consumes named
    icons as placeholders and must not hardcode emoji).
  - The product-reframe content/IA itself — that is `0008` (this spec only *reflects*
    its positioning in copy).
  - New backend, new `UserProfile` fields, or new analytics endpoints. (Funnel
    instrumentation is noted as a hook for `0015-analytics-events-ios.md` but is not
    required to ship.)
  - Localization beyond existing en strings; A/B experimentation framework.
  - Replacing `AuthView` or changing the sign-in mechanism (Hosted UI / `0003`,
    native Apple / `0019`).

## 3. Background & context
**Current state** (`ios/Mango/Features/Onboarding/OnboardingFlow.swift`):
- A single `@State private var step = 0` indexes a `switch` over 5 screens
  (welcome → goals → interests → level → reminder) rendered inside one vertical
  `ScrollView`. Advancement is **buttons only** (`withAnimation { step += 1 }`); a
  linear `ProgressView(value:total:)` shows progress; there is **no swipe paging**.
- Two **emoji** are used as the hero (`Text("🥭")`), which `0013` removes.
- On finish, it upserts the single `UserProfile` (`profiles.first` or a new one),
  sets `name/goals/interests/readingLevel/dailyGoalUnits = level.suggestedDailyUnits/
  hasOnboarded = true`, and — if the reminder toggle is on — stores
  `reminderHour/reminderMinute`, flips `app.settings.reminderEnabled`, and asks
  `app.notifications.requestAuthorization()` then schedules a daily reminder. (Note:
  today the OS permission prompt is **bundled into "Start reading"**, with no
  pre-permission priming.)

**Gating** (`ios/Mango/App/RootView.swift`): `RootView` shows `OnboardingFlow()`
whenever `profiles.first?.hasOnboarded != true`, else `MainTabView()`. Sign-in is an
**optional sheet** (`AuthView`) shown post-onboarding *only* when a real backend is
selected and there's no session (`maybePromptForSignIn()`); it never blocks
Offline/Direct use.

**Data** (`ios/Mango/Models/UserProfile.swift`, `Enums.swift`): exactly one
`UserProfile`. `ReadingLevel` ∈ `{casual, focused, deep}` with `suggestedDailyUnits`
`{1, 2, 3}` and human `title`/`subtitle`. `dailyGoalUnits` defaults to 2 and today is
derived from the chosen level.

**Design system** (`ios/Mango/DesignSystem/`): `Palette` (the only place hex lives;
`accent` = terracotta, cream surfaces, hairline `border`), `Metrics` (spacing/radii),
`Typo` (serif display/title, SF body), `Haptics` (`tap/soft/selection/success/…`).
The reduce-motion idiom is already established: `ProgressRing`, `XPBar`, and
`MangoPrimaryButtonStyle` read `@Environment(\.accessibilityReduceMotion)` and pass
`reduceMotion ? nil : .spring(...)`. There is **no shared motion-duration/curve token
group yet** — this spec adds a minimal one so onboarding (and future features) share a
single source of truth.

**Why now:** the product is pivoting to activity-first (`0008`). First-run is where we
set the mental model, and the current flow both mis-frames Mango as "a reader" and feels
flat. Onboarding redesign is the M11 "first impression" item; it pairs with the icon
cleanup (`0013`) and is a natural place to prime notifications correctly.

**Related specs:** `0008` (product reframe — source of positioning/copy),
`0013` (theme icon set / emoji removal — provides the icons this flow names),
`0002-claude-ui-theme.md` (design tokens), `0003-authentication.md` /
`0019-native-apple-signin.md` (the sign-in this flow links to),
`0015-analytics-events-ios.md` (optional funnel instrumentation hook).

## 4. User stories
- As a **new user**, I want to **swipe through** a short, attractive intro, so that
  first-run feels modern and effortless rather than like a form.
- As a **prospective reader**, I want to understand **up front** that I read on my own
  and Mango coaches the activities/journey, so that my expectations match the product
  (no "where's the books?" confusion).
- As a **motivated learner**, I want to tell Mango **my goals, interests, depth, and a
  daily target**, so that my journeys and reminders feel personal.
- As someone who **dislikes notification spam**, I want to know **why and how often**
  Mango would notify me **before** the OS asks, so that I can opt in (or defer) with
  confidence.
- As a **VoiceOver / Switch-Control / Reduce-Motion user**, I want a **non-swipe,
  non-animated** path with clear labels and a visible "Next" affordance, so that I can
  complete onboarding comfortably.
- As a **returning user reinstalling**, I want onboarding to **not lose or duplicate**
  my profile and to let me **resume** mid-flow if interrupted, so that it's safe and
  idempotent.
- As a user who wants sync, I want to **sign in at the end** (or skip), so that I can
  start offline immediately and add an account when ready.

## 5. Requirements
### Functional (testable)
- **FR-1 — Paged flow.** Onboarding presents **4–6 ordered pages** in a horizontal
  pager with **right-swipe** to advance and left-swipe to go back. Page order:
  (1) Welcome/value → (2) How Mango works → (3) Profile capture (goals/interests/level/
  daily goal — may be one page with sub-steps or split; see §6) → (4) Notification
  priming → (5) *optional* Sign-in → (6) Finish/first-journey handoff.
- **FR-2 — Progress dots.** A **dot indicator** reflects current page and total; it
  updates in lockstep with swipe and button navigation. (Replaces the linear bar.)
- **FR-3 — Persistent advance affordance.** Every page shows a **primary button**
  ("Continue", final page "Start your journey") and, where applicable, a **secondary**
  ("Back"). Swipe and button stay in sync; **the button alone can complete the entire
  flow** without any swipe.
- **FR-4 — Positioning copy.** Pages (1)–(2) explicitly state the activity-first
  framing from `0008`: you read on your own; Mango = activities + journey coach with
  XP/levels/streaks/daily goal. No copy implies Mango is an in-app reader/e-reader.
- **FR-5 — Profile capture.** The flow collects and, on finish, writes to the single
  `UserProfile`: `name` (optional), `goals: [String]`, `interests: [String]`,
  `readingLevel: ReadingLevel`, and `dailyGoalUnits: Int`. `dailyGoalUnits` defaults to
  `readingLevel.suggestedDailyUnits` and is **independently adjustable** (stepper) so
  "daily goal" is a first-class choice, not just a side effect of level.
- **FR-6 — Notification priming.** A dedicated page explains value + cadence ("one
  gentle nudge a day, off anytime") and offers **Enable reminders** (sets time, then
  triggers the OS prompt via `NotificationService.requestAuthorization()` and schedules)
  vs **Maybe later** (no OS prompt). Declining/deferring never blocks completion. If the
  user enables but the OS denies, the flow continues and we persist the chosen time so a
  later Settings toggle can re-request.
- **FR-7 — Optional sign-in.** A page (or terminal sheet) offers sign-in by presenting
  the existing `AuthView` (Continue / Apple / Google / offline). **Skipping is
  one tap** and is the default emphasis (offline-first). Sign-in success or "continue
  offline" both proceed to finish.
- **FR-8 — Idempotent completion.** On finish, upsert `profiles.first` (never create a
  second `UserProfile`), set fields above, set `hasOnboarded = true`, and `save()`. Re-
  running the finish path is safe (no duplicate profile, no duplicate scheduled
  notification — clear/replace before scheduling).
- **FR-9 — Skip / resume.** A lightweight **Skip** (or "Set up later") is available
  from the value pages and writes minimal defaults (`hasOnboarded = true`, defaults
  intact) so the user reaches the app; profile fields can be edited later in Settings.
  Current page index is persisted (e.g. `@SceneStorage`/`UserProfile`-adjacent draft)
  so an interrupted session **resumes on the page it left** within the same install,
  rather than restarting, **as long as** `hasOnboarded == false`.
- **FR-10 — Reduce-motion fallback.** When `accessibilityReduceMotion` is on, page
  changes are **instant cross-dissolves or no animation**, parallax is disabled, and any
  decorative looping animation is static. Functionality is identical.
- **FR-11 — Accessible navigation.** With VoiceOver on: each page is an
  accessibility-grouped unit with a meaningful label; the page position is announced
  ("Page 2 of 5"); the primary button is reachable and labeled; image-only/icon controls
  carry `accessibilityLabel`s. The custom controls and the swipe-to-page gesture must not
  trap focus (use `.accessibilityElement(children:)` grouping and `onChange` announcements as
  needed).
- **FR-12 — No emoji / tokens only.** No emoji anywhere; hero/accent imagery uses named
  theme icons (from `0013`; until then, SF Symbols already used elsewhere, e.g.
  `bell.badge`, `flame.fill`) and DesignSystem tokens for all color/spacing/type/haptics.

### Non-functional
- **Performance.** 60 fps page transitions on the min supported device; no main-thread
  work on swipe; hero parallax computed from the pager's normalized offset only.
- **Accessibility.** WCAG-aligned: Dynamic Type to XXL without truncation/overlap (pages
  scroll vertically *within* a page if content exceeds the viewport), AA contrast (via
  `Palette`), Reduce Motion + VoiceOver + Switch Control parity (FR-10/11), min 44×44 pt
  hit targets.
- **Privacy.** No PII leaves the device during onboarding; sign-in is the only network
  touch and is optional. Notification rationale shown **before** the OS prompt.
- **Offline-first invariant.** The whole flow works with **no network and no key**
  (CLAUDE.md): only the optional sign-in page reaches out, and it degrades gracefully.
- **Cost.** None (no backend changes).
- **Maintainability.** Page model is **data-driven** (an ordered enum/array of pages) so
  adding/reordering a page is a one-line change; motion constants live in one `Motion`
  token group.

## 6. Design
### iOS — screen flow (pages → what each sets)
A `OnboardingFlow` rewritten around a pager. Recommended container: **`TabView` with
`.tabViewStyle(.page(indexDisplayMode: .never))`** plus a **custom dot indicator**
(so dots are themable and reduce-motion-aware) and a custom footer — chosen over a
hand-rolled `DragGesture` pager for free swipe physics, VoiceOver "page X of Y", and
RTL correctness. (Alternative: custom `ScrollView(.horizontal)` + `.scrollTargetBehavior(.paging)`;
see §10 decision.) A single `@State private var page: Int` is the source of truth, bound
to the `TabView` selection so **swipe and buttons stay in sync**.

| # | Page | Purpose / framing | Captures / sets | Notes |
|---|------|-------------------|-----------------|-------|
| 1 | **Welcome / value** | Warm hero + one-line promise reframed per `0008`: "Read your own books. Mango turns them into a guided, game-like journey." Optional **name** field. | `name` (optional, deferred-write) | Hero uses theme icon (no emoji) + light parallax. Primary "Continue"; tertiary "Skip setup" (FR-9). |
| 2 | **How Mango works** | 3–4 beats: *Read on your own → Do short activities (quiz / reflect / apply) → Track your journey → Earn XP, levels & streaks.* Sets the mental model that Mango is a **coach, not a reader**. | none (informational) | Each beat = icon + title + caption (tokens). Optional staggered reveal (reduce-motion: appear at once). |
| 3 | **Make it yours** (profile) | Goals, interests, reading depth, daily goal. May be **one scrollable page** or **2 sub-pages** (goals+interests, then level+daily goal) — still within the 4–6 page budget. | `goals: Set<String>`→`[String]`, `interests: Set<String>`→`[String]`, `readingLevel`, `dailyGoalUnits` (stepper, defaulting to `level.suggestedDailyUnits`) | Reuse today's chip grid + level cards (already token-based). Selecting a level pre-fills the daily-goal stepper but the user can override (FR-5). |
| 4 | **Stay on track** (notification priming) | Pre-permission rationale + cadence + time picker. **Enable reminders** → set `reminderHour/Minute`, `settings.reminderEnabled = true`, request OS auth, schedule; **Maybe later** → skip prompt. | `reminderHour`, `reminderMinute`, `settings.reminderEnabled` | OS prompt fires **only** on Enable (FR-6). Copy: value + "one nudge/day, off anytime". |
| 5 | **Sign in to sync** (optional) | Present `AuthView` (Continue / Apple / Google) with **offline** emphasized. | (sign-in handled by `AuthService`; no `UserProfile` change) | Can be an embedded page *or* deferred to the existing post-onboarding sheet in `RootView` (see decision §10). Skipping is one tap. |
| 6 | **You're set** (finish) | Brief celebratory confirmation → **"Start your journey"** drops into the first journey/Home. | Calls `finish()` (idempotent upsert, `hasOnboarded = true`, schedule reminder) | Success haptic (`Haptics.success()`); optional confetti-free, token-based flourish (reduce-motion safe). |

> Pages 3 may be split to keep each page focused; total pages must remain **4–6**
> (FR-1). Pages 1–2 carry the `0008` framing (FR-4).

### Page model (data-driven; the source of truth for the pager)
A single ordered enum drives count, order, dots, and `isLast` so adding/reordering a page is a
one-line change (NFR maintainability). Pure → unit-testable (§8):
```swift
enum OnboardingPage: Int, CaseIterable, Identifiable {
    case welcome, howItWorks, makeItYours, notifications, signIn, finish
    var id: Int { rawValue }
    static var ordered: [OnboardingPage] { allCases }          // count is 4–6 (here 6)
    var isLast: Bool { self == OnboardingPage.allCases.last }
    func next() -> OnboardingPage { OnboardingPage(rawValue: rawValue + 1) ?? self }   // clamps
    func prev() -> OnboardingPage { OnboardingPage(rawValue: rawValue - 1) ?? self }   // clamps
}
```
The `TabView` selection binds to `@State private var page: OnboardingPage = .welcome` (or its
`rawValue` `Int` if simpler for `.tag`). If D3 collapses the profile into one page, drop a case;
the count assertion in `OnboardingPageTests` keeps it within 4–6.

### Interaction & motion
- **Paging:** right-swipe advances, left-swipe returns; `TabView` `.page` provides the
  gesture, momentum, and bounds. `page` binding keeps the footer button, dots, and swipe
  consistent.
- **Progress dots:** custom `PageDots(count:current:)` — `current` dot is the
  `Palette.accent` capsule (slightly wider), others `Palette.border`; transitions use a
  spring **unless** reduce-motion. `accessibilityHidden(true)` on the decorative dots
  (position is announced by the pager / a `Text` "Step n of N").
- **Parallax / depth:** the hero artwork on pages 1–2 translates a few points based on
  the pager's normalized horizontal offset (read via `GeometryReader`/`PreferenceKey` or
  `TabView` selection-derived value), giving subtle depth. **Disabled** under reduce
  motion (offset forced to 0).
- **Micro-animations:** spring page-content settle and staggered beat reveal on page 2,
  using the new `Motion` tokens (target 200–300 ms per research §12). All gated on
  reduce motion (no animation → content simply present).
- **Haptics on advance:** `Haptics.soft()` (or `.selection()`) on each successful page
  advance; `Haptics.success()` on finish; `Haptics.selection()` already fires on chip/
  level selection. Keep haptics light and purposeful.
- **Buttons are first-class (a11y):** the primary "Continue" button advances `page`
  programmatically (`withAnimation(motion) { page += 1 }`), so **swipe is optional**
  (FR-3/FR-11). "Back" mirrors it. On the last page the primary becomes "Start your
  journey" → `finish()`.

### Motion tokens (new, small)
Add a `Motion` group to DesignSystem (e.g. extend `Theme.swift` or a new
`Motion.swift`) so durations/curves are tokenized and reduce-motion is centralized:
```
enum Motion {
    static let pageSpring  = Animation.spring(response: 0.42, dampingFraction: 0.86)
    static let microSpring = Animation.spring(response: 0.3,  dampingFraction: 0.8)
    static let dissolve    = Animation.easeInOut(duration: 0.22)
    static let parallaxMax: CGFloat = 18   // pts of hero travel across a page width
    /// Resolve an animation against Reduce Motion (nil = instant).
    static func resolved(_ a: Animation, reduceMotion: Bool) -> Animation? { reduceMotion ? nil : a }
}
```
Existing call sites (`ProgressRing`, `XPBar`, `MangoPrimaryButtonStyle`) may later adopt
these but are **out of scope** to change here.

### State & integration
- **Source of truth during the flow:** local `@State` — `page`, `name: String`,
  `goals: Set<String>`, `interests: Set<String>`, `level: ReadingLevel = .focused`,
  `dailyGoal: Int` (seeded from `level.suggestedDailyUnits`), `reminderOn: Bool`,
  `reminderTime: Date` — same shape as today (`OnboardingFlow.swift:11–19`, plus the new
  `dailyGoal`), written to the single `UserProfile` only in `finish()` (deferred-write keeps the
  flow cancel-safe).
- **Idempotent finish (FR-8) — exact mapping** (extends the current `finish()` at
  `OnboardingFlow.swift:209–239`; all target fields verified in `UserProfile.swift`):
  ```swift
  let profile = profiles.first ?? { let p = UserProfile(); context.insert(p); return p }()  // never a 2nd profile
  profile.name = name.trimmingCharacters(in: .whitespaces)
  profile.goals = Array(goals)
  profile.interests = Array(interests)
  profile.readingLevel = level                       // computed setter writes readingLevelRaw
  profile.dailyGoalUnits = dailyGoal                 // NEW: independent of level (FR-5), not level.suggestedDailyUnits
  profile.hasOnboarded = true
  if reminderOn {
      let comps = Calendar.current.dateComponents([.hour, .minute], from: reminderTime)
      profile.reminderHour = comps.hour
      profile.reminderMinute = comps.minute ?? 0
      app.settings.reminderEnabled = true
      app.notifications.cancelDailyReminder()        // CLEAR before schedule → no stacked notifs on re-entry
      Task {
          if await app.notifications.requestAuthorization() {       // only fired here if page 4 didn't already
              await app.notifications.scheduleDailyReminder(hour: comps.hour ?? 8, minute: comps.minute ?? 0, body: …)
          }
      }
  }
  try? context.save()
  // clear @SceneStorage("onboarding.page") and any "didOfferSignIn"/"primedNotifications" draft flags
  ```
  The one behavior change vs today: `dailyGoalUnits = dailyGoal` (the stepper value) instead of
  `level.suggestedDailyUnits`, making the daily goal a first-class choice (FR-5).
- **Resume (FR-9):** persist the page with `@SceneStorage("onboarding.page")` (stores the
  `OnboardingPage.rawValue`) so a backgrounded/relaunched install with `hasOnboarded == false`
  resumes mid-flow; cleared on finish/skip. (`@SceneStorage` is per-scene and survives
  background/relaunch within an install — exactly the FR-9 scope.)
- **Gating (`RootView`):** unchanged contract — `RootView` shows `OnboardingFlow()` while
  `profiles.first?.hasOnboarded != true` (`RootView.swift:17–21`). The existing
  `maybePromptForSignIn()` (`RootView.swift:37–46`) already guards on `authPrompted` +
  `app.auth.isSignedIn` + `isConfigured` + `hasOnboarded`, so once onboarding signs the user in (or
  they reach the app signed-out) it won't double-prompt. **If** sign-in is an embedded page (D2),
  the only addition is: leave that guard as-is (a successful embedded sign-in flips
  `app.auth.isSignedIn`, which the guard already checks) — no new flag strictly required.
- **Notifications (verified API):** reuse `NotificationService` —
  `requestAuthorization() async -> Bool`, `scheduleDailyReminder(hour:minute:body:) async` (which
  itself already removes the pending `mango.dailyReminder` before adding, so it's safe), and
  `cancelDailyReminder()` (`NotificationService.swift:10–36`). The difference vs today is the
  **prompt is triggered from page 4's Enable action** (primed), not silently at the end; if page 4
  already requested, `finish()` won't re-prompt (the OS no-ops a second `requestAuthorization`
  anyway).
- **Analytics hook (optional):** emit `onboarding_page_view{index}`,
  `onboarding_skipped`, `onboarding_completed`, `notif_primed{enabled}` via the future
  `0015` pipeline. Not required to ship; behind the same no-op-if-absent pattern.

### Design language
Warm minimalist, Claude-like: cream `Palette.background`, terracotta `Palette.accent`,
serif `Typo.display`/`Typo.title` for headlines, SF body, hairline-bordered cards
(`Card`), generous `Metrics.padL`. **No raw hex, no emoji, no magic numbers.** Hero/beat
imagery via named theme icons (from `0013`; SF Symbols as interim). Reuse the existing
`.mangoPrimary`/`.mangoSecondary` button styles, the chip grid + level cards already in
`OnboardingFlow.swift:96–207`, and the established Reduce-Motion idiom
(`@Environment(\.accessibilityReduceMotion)` → pass `nil` animation), seen in `ProgressRing`/`XPBar`/
`MangoPrimaryButtonStyle`.

### Files to add / change (authoritative)
**Add** (auto-registered by Xcode 16 file-system-synchronized groups — no `project.pbxproj` edits):
- `ios/Mango/DesignSystem/Motion.swift` — the `Motion` token group + `resolved(_:reduceMotion:)`.
- `ios/Mango/Features/Onboarding/PageDots.swift` — token-based, reduce-motion-aware, a11y-hidden.
- `ios/Mango/Features/Onboarding/OnboardingPage.swift` — the page-model enum (above) + a reusable
  page scaffold (title/subtitle/hero/content).
- `ios/MangoTests/OnboardingPageTests.swift`, `ios/MangoTests/MotionTests.swift`,
  `ios/MangoTests/OnboardingFinishTests.swift` (§8).

**Change:**
- `ios/Mango/Features/Onboarding/OnboardingFlow.swift` — full rewrite around `TabView(.page)` bound
  to `page`; persistent footer; pages 1–6; deferred-write `finish()` with the FR-5 stepper.
- `ios/Mango/Models/UserProfile.swift` — **no field change** (already has `name/goals/interests/`
  `readingLevelRaw/dailyGoalUnits/hasOnboarded/reminderHour/reminderMinute`); the only delta is that
  `finish()` now writes `dailyGoalUnits` from the stepper.
- `ios/Mango/Services/Persistence/AppSettings.swift` — add optional `onboardingV2Enabled` flag
  (follow the `@Observable`+`UserDefaults` `didSet`/`Keys` pattern, lines 27–28, 70–77; default
  `true` in Beta).
- `ios/Mango/App/RootView.swift` — **no contract change** (still gates on `hasOnboarded`); only flips
  between the new and legacy view if the flag is used.
- (Reused, unchanged) `ios/Mango/Features/Auth/AuthView.swift`,
  `ios/Mango/Services/Notifications/NotificationService.swift`.

### Diagram (flow)
```
RootView
  └─ !hasOnboarded ─► OnboardingFlow (TabView .page, bound to `page`)
        ┌─────────────────────────────────────────────────────────────┐
   swipe│  [1 Welcome]→[2 How it works]→[3 Make it yours]→[4 Notif]    │swipe
   ◄────│      ▲ name        ▲ framing      ▲ goals/interests/  prime  │────►
        │      │             │              │  level/dailyGoal   │     │
        │   PageDots (●○○○○○) + footer: «Back»  «Continue»             │
        └───────────────────────────────┬─────────────────────────────┘
                                         ▼
                           [5 Sign in (optional, AuthView)] —skip→
                                         ▼
                              [6 You're set] —Start journey→ finish()
                                         ▼
                 upsert UserProfile · hasOnboarded=true · schedule reminder
                                         ▼
                                    MainTabView
```

## 7. Acceptance criteria
- [ ] Onboarding is a **horizontal pager** of **4–6 pages**; **right-swipe advances** and
      left-swipe returns, with momentum/bounds. (FR-1)
- [ ] A **dot indicator** reflects current/total and stays in sync with both swipe and
      buttons. (FR-2)
- [ ] **The primary button alone completes the entire flow** (no swipe required); Back
      works on every page after the first. (FR-3, FR-11)
- [ ] Pages 1–2 state the **activity-first framing** (read on your own; Mango = activities
      + journey + XP/streaks coach); **no copy implies an in-app reader**. (FR-4)
- [ ] On finish, the single `UserProfile` has `name`, `goals`, `interests`,
      `readingLevel`, **independently-set `dailyGoalUnits`**, `hasOnboarded == true`, and
      (if enabled) `reminderHour/Minute` — with **no duplicate profile** created. (FR-5,
      FR-8)
- [ ] **Notification priming** page explains value+cadence and only triggers the OS prompt
      on **Enable**; **Maybe later** skips it and the flow still completes; OS-deny does
      not block. (FR-6)
- [ ] **Sign-in is reachable** from onboarding (embedded page or terminal sheet) and is
      **skippable in one tap**; the app starts offline regardless. (FR-7)
- [ ] With **Reduce Motion ON**: page changes are instant/cross-dissolve, parallax and
      decorative animation are disabled, behavior is otherwise identical. (FR-10)
- [ ] With **VoiceOver ON**: each page is a labeled group, position is announced, the
      primary button and all icon controls are reachable and labeled; focus is not
      trapped by the swipe gesture. (FR-11)
- [ ] **Dynamic Type XXL**: no truncation/overlap; content scrolls within a page if
      needed. (Non-functional a11y)
- [ ] **No emoji** anywhere; all color/spacing/type/haptic via DesignSystem tokens; motion
      via the new `Motion` tokens. (FR-12)
- [ ] **Resume**: backgrounding mid-flow and relaunching (still `!hasOnboarded`) returns to
      the same page; **Skip** writes minimal defaults and reaches the app. (FR-9)
- [ ] `RootView` still gates on `hasOnboarded`; no double sign-in prompt. (Integration)

## 8. Test plan
**Pure / unit (preferred — fast, offline; `MangoTests`, mirroring `LevelCurveTests` style):**
- `OnboardingPageTests` (FR-1): `testPageCountWithinBudget` (`OnboardingPage.allCases.count` in
  4...6); `testNextClampsAtLast` / `testPrevClampsAtFirst`; `testIsLast`.
- `MotionTests` (FR-10): `testResolvedNilWhenReduceMotion` (`Motion.resolved(.dissolve,
  reduceMotion: true) == nil`); `testResolvedReturnsAnimationOtherwise` (non-nil when `false`).
- `OnboardingFinishTests` (against an in-memory container, `isStoredInMemoryOnly: true`, with a
  `NotificationService` test double — note today's `NotificationService` is a `final class`, so make
  the call sites injectable or wrap in a small protocol for the spy):
  - `testDailyGoalIndependentOfLevel` (FR-5): selecting `.casual` seeds `dailyGoal = 1`, then an
    explicit stepper bump to 3 is **preserved** through `finish()` (asserts
    `profile.dailyGoalUnits == 3`, not `suggestedDailyUnits`).
  - `testIdempotentUpsert` (FR-8): with a pre-existing `UserProfile`, running `finish()` twice keeps
    the profile **count at 1**, sets `hasOnboarded == true`, and schedules the reminder **exactly
    once** per run (spy asserts one `cancelDailyReminder` + one `scheduleDailyReminder`).
  - `testPrimingEnableRequestsAndSchedules` (FR-6): Enable path → `requestAuthorization` called +
    `scheduleDailyReminder` called + `settings.reminderEnabled == true`.
  - `testPrimingMaybeLaterSkipsPrompt` (FR-6): Maybe-later → neither `requestAuthorization` nor
    `scheduleDailyReminder` called; flow still completes (`hasOnboarded == true`).
  - `testPrimingOSDenyStillCompletes` (FR-6): authorize returns `false` → no schedule, but
    `reminderHour/Minute` persisted so Settings can re-request later; `hasOnboarded == true`.

**UI / manual (XCUITest where automatable, else checklist):**
- Swipe through all pages; verify dots, footer sync, and that **buttons alone** also
  complete the flow. (FR-1/2/3)
- Reduce Motion ON (Settings > Accessibility): confirm no page-slide/parallax, instant
  transitions. (FR-10)
- VoiceOver ON: swipe and double-tap through; confirm labels, "page X of Y", reachable
  primary button, no focus trap. (FR-11)
- Dynamic Type XXL: confirm layout integrity. (a11y)
- Notification priming: Enable (accept + deny variants) and Maybe-later; verify the OS
  prompt only on Enable and that Settings can later re-request after a deny. (FR-6)
- Sign-in: open `AuthView` from onboarding, sign in *and* skip; verify both reach the app
  and there's no second prompt from `RootView`. (FR-7, integration)
- Resume/skip: background mid-flow → relaunch resumes page; Skip reaches app with defaults.
  (FR-9)
- Grep/build check: **no emoji literals** in `Features/Onboarding`; no raw hex; build with
  no new warnings. (FR-12)

**Regression:** existing `RootView` gating and `maybePromptForSignIn()` still behave for
Mock/Direct/Real backends.

## 9. Rollout & migration
- **Pure client change**, no backend/schema migration; `UserProfile` fields unchanged
  (we just expose `dailyGoalUnits` directly). Users who already onboarded
  (`hasOnboarded == true`) **never see** the new flow — no migration needed.
- **Feature flag (optional):** gate behind `AppSettings.onboardingV2Enabled` (default ON
  in Beta first) so we can fall back to the old `OnboardingFlow` if a blocking a11y/layout
  issue appears; remove the flag and the old view once validated.
- **Dependency ordering:** `0013` (icons) ideally lands first so heroes use final art;
  until then ship with interim SF Symbols (no emoji). `0008` copy should be settled before
  finalizing pages 1–2 strings.
- **Teardown:** delete the legacy step-index view and the flag after one stable release;
  keep `finish()`'s idempotent upsert + reminder-clear logic.
- **Backward compatibility:** none broken — same persisted fields, same gating contract,
  same `AuthView`.

## 10. Risks & open decisions
**Risks + mitigations**
- **VoiceOver focus trapping in a paged `TabView`.** *Mitigation:* group each page with
  `.accessibilityElement(children: .contain)`, announce page changes via `onChange`, and
  keep the primary button as the reliable advance path; covered by the VoiceOver manual
  test. (Research §12 notes default "page X of Y" behavior to lean on.)
- **Motion that annoys or causes discomfort.** *Mitigation:* keep it subtle (200–300 ms),
  centralize in `Motion`, and fully honor Reduce Motion (no parallax, no slide).
- **Notification opt-in mistimed.** *Mitigation:* dedicated pre-permission page with value
  + cadence + "Maybe later" (research §12: pre-prompts lift opt-in materially).
- **Funnel length vs. data capture.** Profile capture adds screens; mitigated by keeping
  to 4–6 pages, a visible dot indicator, and a Skip path (research §12: each pre-value
  screen can cost 10–15% completion).
- **Emoji creep / icon dependency on `0013`.** *Mitigation:* lint for emoji; use interim
  SF Symbols; swap to named theme icons when `0013` lands.

**Decisions needed (with recommendation)**
- **D1 — Pager implementation.** `TabView(.page)` vs custom `ScrollView(.horizontal)` +
  `.scrollTargetBehavior(.paging)`. **Recommend `TabView(.page)`** for free gesture
  physics, built-in VoiceOver paging, and RTL correctness; revisit only if parallax needs
  finer offset control than the selection-derived value provides.
- **D2 — Sign-in placement.** Embedded page (5) vs reuse the existing post-onboarding
  `AuthView` **sheet** in `RootView`. **Recommend embedded page** for a single coherent
  swipe flow, *and* suppress the `RootView` sheet when onboarding already offered sign-in
  (guard flag) to avoid double-prompting. (If we want minimal change, keep the sheet and
  make page 5 a "Sync your progress?" teaser that defers to it.)
- **D3 — Split profile page?** One scrollable "Make it yours" vs two sub-pages.
  **Recommend two sub-pages** (goals+interests; level+daily goal) for focus, staying
  within the 6-page cap; collapse to one if QA finds the funnel too long.
- **D4 — Feature flag.** Ship behind `onboardingV2Enabled`? **Recommend yes** for Beta,
  remove after one stable release.

## 11. Tasks & estimate
1. **(S)** Add `Motion` tokens (durations/curves/`parallaxMax`/`resolved(_:reduceMotion:)`)
   to DesignSystem; unit-test `resolved`. (FR-10)
2. **(S)** Build `PageDots` component (token-based, reduce-motion-aware, a11y-hidden) +
   reusable `OnboardingPage` scaffold (title/subtitle/hero/content). (FR-2)
3. **(M)** Rewrite `OnboardingFlow` as a `TabView(.page)` bound to `page`, with persistent
   footer (Back/Continue→Start) so **buttons alone complete the flow**; wire swipe↔button↔
   dots sync + advance haptics. (FR-1/3)
4. **(S)** Pages 1–2 content (welcome + "how Mango works") with `0008` framing and hero
   parallax (reduce-motion gated); interim SF Symbol icons (no emoji). (FR-4/12)
5. **(S)** Page 3 profile capture: reuse chip grid + level cards; add a **daily-goal
   stepper** seeded by `suggestedDailyUnits` but independently editable; optionally split
   into two sub-pages (D3). (FR-5)
6. **(M)** Page 4 notification priming: rationale + cadence + time picker; Enable triggers
   `requestAuthorization` + schedule (+ clear-before-schedule), Maybe-later skips;
   handle OS-deny gracefully. (FR-6)
7. **(S)** Page 5 sign-in: embed/launch `AuthView`; ensure skip is one tap and guard
   `RootView` against double-prompt (D2). (FR-7)
8. **(S)** Page 6 finish: idempotent `finish()` (upsert, `hasOnboarded=true`, reminder
   clear+schedule), success haptic, "Start your journey" → first journey. (FR-8)
9. **(S)** Skip + resume: `@SceneStorage` page persistence (cleared on finish/skip) and a
   Skip action writing minimal defaults. (FR-9)
10. **(S)** Accessibility pass: page grouping, VoiceOver announcements, labels on icon
    controls, Dynamic-Type XXL audit, 44pt targets. (FR-11)
11. **(S)** Feature flag `onboardingV2Enabled` + keep legacy flow as fallback (D4). (§9)
12. **(S)** Tests: page-model + Motion + daily-goal + idempotent-finish + priming-branch
    unit tests; XCUITest/checklist for swipe/dots/reduce-motion/VoiceOver. (§8)
13. **(S)** Lint/build: assert no emoji/raw-hex in `Features/Onboarding`; remove legacy
    view + flag after validation. (FR-12, §9)

_Rough total: ~3 M + 10 S._

## 12. References
**Codebase**
- `ios/Mango/Features/Onboarding/OnboardingFlow.swift` (current step-index flow; emoji to
  remove per `0013`)
- `ios/Mango/App/RootView.swift` (gating on `hasOnboarded`; optional post-onboarding
  `AuthView` sheet), `ios/Mango/App/AppModel.swift` (services container: `settings`,
  `auth`, `notifications`)
- `ios/Mango/Models/UserProfile.swift`, `ios/Mango/Models/Enums.swift` (`ReadingLevel`,
  `suggestedDailyUnits`)
- `ios/Mango/DesignSystem/{Theme.swift,Components.swift,Typography.swift,Haptics.swift}`
  (tokens; existing `@Environment(\.accessibilityReduceMotion)` idiom in `ProgressRing`/
  `XPBar`/`MangoPrimaryButtonStyle`)
- `ios/Mango/Features/Auth/AuthView.swift` (the sign-in this flow links to)
- `ios/Mango/Services/Notifications/NotificationService.swift`
  (`requestAuthorization`, `scheduleDailyReminder`)

**Related specs**
- `0008-product-reframe-activity-first.md` (positioning/copy source — "read on your own;
  Mango coaches activities + journey")
- `0013-…-theme-icons.md` (icon set / emoji removal — provides the named icons used here)
- `docs/specs/0002-claude-ui-theme.md` (design tokens), `docs/specs/0003-authentication.md`
  / `0019-native-apple-signin.md` (sign-in), `0015-analytics-events-ios.md` (optional
  funnel events)

**External research — key takeaways (cited)**
1. **Cut to ≤3 screens before value; show a progress indicator on the rest.** Each extra
   pre-value screen can cost ~10–15% completion; a visible "Step n of N" (our dots)
   reduces abandonment on the steps that remain. Keep value-first ("aha" early). —
   [VWO: Mobile App Onboarding Guide](https://vwo.com/blog/mobile-app-onboarding-guide/),
   [NextNative: 7 Mobile Onboarding Best Practices](https://nextnative.dev/blog/mobile-onboarding-best-practices)
2. **Carousels: 3–5 slides, value-first — most users don't read them.** Engagement drops
   sharply after the first slide, so lead with the promise and reinforce the mental model
   fast (supports our 4–6 page budget and pages 1–2 framing). —
   [Userpilot: Mobile Carousels](https://userpilot.com/blog/mobile-carousels/),
   [Plotline: Onboarding Examples](https://www.plotline.so/blog/mobile-app-onboarding-examples)
3. **Prime notification permission before the OS prompt.** A full-screen pre-permission
   screen explaining value + cadence (with a "later" option) lifts opt-in materially
   (Adjust saw ~65% when integrated into onboarding; pre-prompts commonly +20–30%) —
   exactly our page 4. —
   [Appcues: Mobile Permission Priming](https://www.appcues.com/blog/mobile-permission-priming),
   [Adjust: ATT/opt-in design](https://www.adjust.com/blog/opt-in-design-for-apple-app-tracking-transparency-att-ios14/)
4. **`TabView(.page)` gives VoiceOver paging for free; override/group as needed.** It
   announces "Page X of Y" and animates automatically; group page content and use
   `onChange` announcements, and label icon-only buttons via `accessibilityLabel`
   (our FR-11). —
   [KahWee: Understanding SwiftUI's TabView](https://kahwee.com/2025/understanding-swiftui-tabview/),
   [SwiftLee: VoiceOver navigation tips](https://www.avanderlee.com/swiftui/voiceover-navigation-improvement-tips/)
5. **Keep micro-animations subtle and purposeful (~200–300 ms); pair gestures with
   haptics.** Subtle motion + tactile confirmation boosts activation (animated progress
   shown to lift activation markedly) — informs our `Motion` tokens, dot transitions, and
   advance haptics, all behind Reduce Motion. —
   [UXPin: Onboarding Microinteractions](https://www.uxpin.com/studio/blog/designing-onboarding-microinteractions-guide/),
   [BricxLabs: Micro Animation Examples 2026](https://bricxlabs.com/blogs/micro-interactions-2025-examples)
6. **Onboarding completion is a real funnel.** Median completion ~19% vs ~40–50% for top
   apps — justifying a short, motivating, swipe-friendly flow with a clear skip and a
   progress cue. —
   [VWO: Mobile App Onboarding Guide](https://vwo.com/blog/mobile-app-onboarding-guide/)
