# NNNN — App Store submission readiness

- **Epic:** M10 · **Status:** Draft · **Owner:** unassigned · **Updated:** 2026-06-26
- **Reviewers:** Principal, SD, QA

## 1. Summary
Everything required to make Mango **submittable to the App Store** (Roadmap #7). The
app builds and runs offline today, and a CI release path already exists
(`.github/workflows/ios-release.yml` archives + uploads to TestFlight). What's missing
is the **store-readiness** layer: polished app icon + launch screen, marketing
screenshots, the **App Privacy "nutrition labels"** (correctly distinguishing the
on-device Direct-Claude key path from the backend Bedrock path and the new analytics
events), notification rationale (the ~1/day cap), **Sign in with Apple** to satisfy
Guideline 4.8 (federated login), confirmation that **account deletion** (Guideline
5.1.1(v)) is satisfied by `DELETE /v1/me`, data-use disclosures, and a documented
TestFlight-beta → release flow. The deliverable is a **pre-submission checklist**
that, when every box is true, means the binary can be submitted for review.

## 2. Goals / Non-goals
- **Goals:**
  - Finalized **app icon** (all required sizes) and a **launch screen** consistent with
    the DesignSystem (`Palette`/`Typo`/`Metrics`).
  - A **screenshot set** for required device classes (6.7"/6.9" + 6.5" iPhone; iPad if
    the app ships universal — see §10) showing the core loop.
  - A complete, accurate **App Privacy** declaration mapping every data flow:
    Direct-Claude (on-device key → Anthropic) vs backend (Bedrock, no key in app) vs
    analytics events; what is **collected**, whether it is **linked** to identity, and
    whether it is used for **tracking** (it is not).
  - **Sign in with Apple** offered wherever federated sign-in is offered (Guideline
    4.8) — the iOS `AuthService` already supports the `SignInWithApple` Hosted-UI hint;
    this spec makes it a first-class button and verifies the Apple-specific rules.
  - A documented statement + test that **account deletion** is reachable in-app and
    erases server-side data (Guideline 5.1.1(v)); `DELETE /v1/me` already implements the
    cascade.
  - **Notification rationale** copy + a pre-permission explainer consistent with the
    single ~1/day reminder (`NotificationService`), plus an easy off switch.
  - Store **metadata** (name, subtitle, description, keywords, support/marketing/
    privacy-policy URLs, age rating, category) and **export-compliance** answer.
  - A **TestFlight → release** runbook tied to `ios-release.yml`, and a final
    **pre-submission checklist** (the AC).
- **Non-goals:**
  - Implementing new product features or wiring Cognito sign-in itself (tracked
    elsewhere; this spec depends on sign-in existing and surfaces the Apple button +
    review requirements). If sign-in is not yet shippable, see §9 "Path B (no-account
    release)".
  - The marketing website / App Store Optimization beyond required URLs + a first
    keyword pass.
  - Localization beyond the base language (only the base is required to submit).
  - Building the analytics producer or feature store (sibling specs); this spec only
    **declares** their data behavior on the privacy label.
  - Android / macOS / web.

## 3. Background & context
- **Build/release exists:** `.github/workflows/ios-release.yml` ("iOS Release
  (TestFlight)") archives `Mango.xcodeproj` (scheme `Mango`, Release) and uploads via
  the App Store Connect API key; it **no-ops without Apple secrets** and bakes
  `BetaAPIURL`/`ProdAPIURL` into `Mango/Resources/AppConfig.plist`. Secrets are
  documented in `docs/OPERATIONS.md`.
- **Assets today:** `ios/Mango/Resources/Assets.xcassets` holds `AppIcon` and
  `AccentColor`. The DesignSystem (`ios/Mango/DesignSystem/` — `Palette`, `Typo`,
  `Metrics`) defines the visual language to match.
- **Offline-first invariant (CLAUDE.md):** the app runs fully offline on first launch
  (`MockAIService` + bundled public-domain sample). This shapes the privacy story:
  with the **Mock** path, **no data leaves the device**.
- **AI paths (privacy-relevant):**
  - **Backend (Remote → Bedrock):** the app sends book text / answers to the Mango
    backend over HTTPS; the backend calls Claude on **Amazon Bedrock** (IAM, no API
    key) — see `backend/src/shared/claude.py`. **No Anthropic key ships in the app.**
  - **Direct-Claude (on-device):** optional power-user path; the **user's own**
    Anthropic key is stored in the **Keychain** and the device calls Anthropic
    directly. The key is user-provided, never bundled (CLAUDE.md invariant).
  - **Mock/offline:** no network, no third-party calls.
- **Auth:** `ios/Mango/Services/Auth/AuthService.swift` already implements Cognito
  Hosted-UI OAuth2+PKCE and defines `IdPHint.apple = "SignInWithApple"` and
  `IdPHint.google = "Google"` with scope `openid email`. So **Apple sign-in is already
  reachable** via the Hosted UI; Guideline 4.8 is mostly a UI + configuration task, not
  a from-scratch build.
- **Account deletion:** `DELETE /v1/me`
  ([`shared/api/openapi.yaml`](../shared/api/openapi.yaml),
  `backend/src/handlers/delete_account.py`) erases all `USER#<sub>` items + `users/<sub>/`
  S3 objects and removes the Cognito user (`cognito-idp:AdminDeleteUser`,
  `backend/mango_backend/api_stack.py`). iOS wired this per task #28. Guideline
  5.1.1(v) requires the deletion entry point to be **in the app**.
- **Analytics (new):** the sibling spec `feature-analytics-events-ios` adds event
  emission (`POST /v1/events`) — ids + enums only, opt-out, **no ATT/IDFA**. Its data
  behavior must be reflected on the privacy label.
- **Why now:** M10 is "ship it"; the engineering is largely done, the gating work is
  store compliance + assets + disclosures.

## 4. User stories
- As a **prospective user**, I want an accurate App Privacy label and a clear "what
  leaves my device" story, so that I can trust the app before installing.
- As a **user**, I want to sign in with Apple and to delete my account from inside the
  app, so that I control my identity and my data.
- As the **submitter**, I want a single checklist that maps each App Store guideline
  risk to a concrete artifact/setting, so that the first review submission isn't
  rejected for avoidable reasons.
- As an **on-call/maintainer**, I want the release flow documented end-to-end
  (TestFlight beta → public release) tied to the existing workflow, so that cutting a
  build is repeatable.

## 5. Requirements
**Functional**
- **FR-1 (icon):** a final `AppIcon` set with all required iOS sizes (including the
  1024×1024 App Store marketing icon), no alpha/transparency on the marketing icon,
  matching the DesignSystem palette. Validates clean in Xcode (no missing-size
  warnings).
- **FR-2 (launch screen):** a launch screen (storyboard or SwiftUI launch) using
  `Palette`/`Typo`, no text that needs localization, that transitions seamlessly into
  the first real screen (no flash-of-unstyled-content).
- **FR-3 (screenshots):** a screenshot set per required device class showing: the
  reader, a lesson/exercise, the journey/roadmap, and the XP/streak/profile surface.
  Captured at the exact App Store pixel dimensions for each class.
- **FR-4 (App Privacy label):** a documented privacy declaration (the matrix in §6)
  entered in App Store Connect, covering each data type, its purpose, whether it is
  **linked to the user**, and **used for tracking** (none). Must state that backend AI
  uses Bedrock (no third-party AI vendor key in the app) and that Direct-Claude uses
  the user's own key on-device.
- **FR-5 (Sign in with Apple, Guideline 4.8):** the sign-in UI presents a **Sign in
  with Apple** option (driving `AuthService.signIn(idpHint: .apple)`) alongside any
  other federated provider; if Google (or any third-party login) is offered, Apple must
  be offered and meet 4.8's privacy bar (limit data collection to name + email; allow
  email relay; no advertising-data collection without consent). The Apple-provided
  email/relay flows through Cognito's `SignInWithApple` IdP.
- **FR-6 (account deletion, Guideline 5.1.1(v)):** an in-app, reachable "Delete
  account" action (Settings) that calls `DELETE /v1/me`, confirms, signs out, and
  clears local state; copy explains what is deleted. A support URL documents
  out-of-app deletion as a fallback.
- **FR-7 (notification rationale):** a pre-permission explainer screen before the iOS
  system prompt, stating the app sends **at most one gentle daily reminder** (matches
  `NotificationService` single repeating reminder), that it's optional and toggleable,
  with `reminderEnabled`/permission state honored. `UNAuthorizationStatus.denied` is
  handled gracefully (no nags).
- **FR-8 (store metadata):** finalized app name, subtitle, promotional text,
  description, keywords (first pass), category (Education or
  Books/Reference — decide in §10), age rating answers, and the three required URLs
  (marketing, support, **privacy policy**). The privacy policy text is drafted and
  hosted.
- **FR-9 (compliance answers):** export-compliance (uses only standard
  HTTPS/TLS/system crypto → typically "exempt"); content-rights (public-domain sample
  books only, attributions present); IDFA/tracking question answered **No** (we do not
  use IDFA — consistent with the analytics spec).
- **FR-10 (release runbook):** a documented TestFlight-beta → public-release procedure
  tied to `ios-release.yml` (publish a GitHub Release → workflow archives + uploads;
  promote in App Store Connect after TestFlight validation), including the required
  secrets and the `AppConfig.plist` URL-baking step.

**Non-functional**
- **NFR-1 (truthfulness):** the privacy label and disclosures must exactly match
  runtime behavior — in particular, **no Anthropic key in the app binary** (grep/symbol
  check), **no ATT prompt / no IDFA symbol** (consistent with analytics spec), and the
  Mock path makes no network calls.
- **NFR-2 (no third-party iOS deps):** the app remains SPM/CocoaPods-free (CLAUDE.md);
  nothing added here introduces a dependency or an SDK that would change the privacy
  label.
- **NFR-3 (accessibility baseline):** Dynamic Type, VoiceOver labels on primary
  actions, and color contrast on the icon/launch/onboarding meet a reasonable bar
  (reduces "spam/quality" rejection risk under Guideline 4.x and is good practice).
- **NFR-4 (reproducible release):** cutting a build is deterministic from a tagged
  release; secrets-absent runs no-op (already true) so forks aren't broken.
- **NFR-5 (privacy-by-region):** the privacy policy covers GDPR/CCPA basics and the
  documented deletion paths (`DELETE /v1/me`), and acknowledges the analytics
  event-lake / feature-store deletion **follow-ups** (specs 0006 §9 + sibling spec) so
  the policy isn't overclaiming on erasure completeness.

## 6. Design
**App Privacy "nutrition label" matrix** (App Store Connect "Data Collection"):

| Data type | Collected? | Where it goes | Linked to user? | Used for tracking? | Purpose | Path |
|---|---|---|---|---|---|---|
| Reading/book text & answers | Yes (only on non-Mock) | Mango backend over HTTPS → **Bedrock** (no vendor key in app) | Yes (Cognito sub) | **No** | App functionality (generate roadmap, grade) | Remote |
| Reading/book text & answers | Yes (only if user enables Direct-Claude) | **On-device** → Anthropic API using the **user's own** Keychain key | N/A (user's own key, not our servers) | **No** | App functionality | Direct-Claude |
| Profile (goals, interests, reading level, daily goal, name?) | Yes (signed-in) | Mango backend (DynamoDB) | Yes | No | App functionality / personalization | Backend |
| Gamification (XP, level, streak) | Yes (signed-in) | Mango backend | Yes | No | App functionality | Backend |
| Reflections (free text) | Yes (signed-in) | Mango backend | Yes | No | App functionality (user's own journal) | Backend |
| Identifiers (Cognito sub; email via Apple/Cognito) | Yes (signed-in) | Cognito / backend | Yes | No | Account / auth | Auth |
| **Analytics events (ids + enums only)** | Yes (if analytics on) | `POST /v1/events` → Firehose → S3 lake | Yes (Cognito sub) | **No** | Analytics (product improvement) | Analytics |
| IDFA / advertising id | **No** | — | — | — | — | — (no ATT prompt) |
| Precise location / contacts / health / photos | **No** | — | — | — | — | — |
| Mock/offline usage | **No data leaves device** | — | — | — | — | Mock |

Notes baked into the label/policy:
- **"Used for tracking" = No** across the board: we do not link data with third-party
  data for advertising and do not use IDFA; hence **no ATT prompt** and
  `NSUserTrackingUsageDescription` is intentionally absent.
- **Direct-Claude** is the only path that calls a third party from the device, and it
  uses the **user's own** key (disclosed in-app where the key is entered).
- Analytics data is **ids + enums only** (no book text / reflections) per the sibling
  spec — the label must not overstate what analytics collects.

**Sign in with Apple (Guideline 4.8) design:**
- Sign-in screen shows **Sign in with Apple** (primary, per Apple HIG button style)
  calling `AuthService.signIn(idpHint: .apple)`; if Google is shown it sits below.
  Email/relay is handled by Cognito's `SignInWithApple` IdP (already configured as a
  Hosted-UI provider). Scope stays `openid email` (already set in `AuthService`).
- 4.8 bar: equivalent option that (a) limits collection to name + email, (b) supports
  Apple's private email relay, (c) collects no advertising interactions without
  consent — all satisfied since we collect only auth identity and run no ads.
- Backend config dependency: the Cognito user pool must have the Apple IdP enabled
  (tracked in the auth/sign-in work; this spec verifies it end-to-end, not implements
  the pool config).

**Account deletion (Guideline 5.1.1(v)) design:**
- Settings → "Delete account" → confirmation sheet → `apiClient.delete("/v1/me")` →
  on success: `auth.signOut()` + clear local SwiftData/`UserDefaults` → return to
  onboarding. Copy: "This permanently deletes your account and all your data on our
  servers." Already-implemented backend cascade (DynamoDB + S3 + Cognito user) is the
  target; iOS entry point per task #28. Provide a support-page URL describing deletion
  for users who can't open the app.

**Notification rationale design:**
- A lightweight explainer (DesignSystem-styled) shown **before**
  `NotificationService.requestAuthorization()`: "Mango sends at most one gentle daily
  reminder to keep your streak — you can change the time or turn it off anytime." Honor
  `reminderEnabled` and `authorizationStatus()`; if denied, surface a Settings deep
  link instead of re-prompting.

**Icon / launch / screenshots design:**
- Icon: produce the full size matrix in `Assets.xcassets/AppIcon.appiconset`
  (`ios/Mango/Resources/Assets.xcassets`); marketing 1024 is opaque, no rounded
  corners (Apple masks). Palette-consistent.
- Launch: `Palette.background` + wordmark in `Typo`; no localized text.
- Screenshots: capture on simulators at exact dimensions for each required class;
  annotate lightly; show the core loop (reader → lesson → roadmap → XP/streak).

**Store metadata design:** name "Mango", subtitle (value prop), description
(active-learning loop + gamification + offline), keywords (first pass:
reading, books, learning, habit, self-help, quiz, streak, …), category (decide §10),
URLs (marketing/support/privacy), age rating (likely 4+; verify no objectionable
UGC — reflections are private/local, not shared).

**Release flow (tie to `ios-release.yml`):**
```
tag + publish GitHub Release ─► ios-release.yml (gate on Apple secrets)
   ├─ bake Beta/Prod URLs into AppConfig.plist
   ├─ install ASC API key, set Team ID in ExportOptions
   ├─ xcodebuild archive (Release, -allowProvisioningUpdates)
   └─ exportArchive + upload to TestFlight
        ► validate on TestFlight (internal → external testers)
        ► App Store Connect: attach build, fill metadata + App Privacy + 4.8/5.1.1
        ► Submit for review ─► (after approval) Release
```

## 7. Acceptance criteria
The app is **submittable** when all are true:
- [ ] **AC-1 (icon):** `AppIcon` has every required size incl. opaque 1024 marketing
      icon; Xcode shows no missing-asset warnings; archive validates.
- [ ] **AC-2 (launch):** launch screen renders in `Palette`/`Typo`, no FOUC into the
      first screen, no localized strings.
- [ ] **AC-3 (screenshots):** a complete set at correct dimensions for each required
      device class is uploaded and shows reader, lesson, roadmap, and XP/streak.
- [ ] **AC-4 (privacy label):** the §6 matrix is entered in App Store Connect and
      matches runtime; it correctly distinguishes Bedrock (no key in app), Direct-Claude
      (user's own key), and analytics (ids/enums only); "used for tracking" = No
      everywhere.
- [ ] **AC-5 (no key / no IDFA in binary):** a grep/symbol check on the archived app
      confirms no bundled Anthropic key and no IDFA/`ATTrackingManager` symbol; the
      Mock path makes no network calls. *(manual + a CI grep over the build / source.)*
- [ ] **AC-6 (Sign in with Apple):** the sign-in screen offers Sign in with Apple; on
      a configured backend it completes via the Cognito `SignInWithApple` IdP and
      returns a session; if Google is offered, Apple is offered too (4.8). *(manual on
      a configured stage; AuthService path already covered by app-side flow.)*
- [ ] **AC-7 (account deletion):** Settings exposes Delete account; confirming calls
      `DELETE /v1/me`, signs out, clears local state, and returns to onboarding;
      server-side cascade verified (no `USER#<sub>` items, no `users/<sub>/` objects,
      Cognito user removed). *(backend cascade has pytest; iOS path manual.)*
- [ ] **AC-8 (notification rationale):** the pre-permission explainer appears before the
      system prompt, states the ~1/day cap, and the reminder is toggleable; denied state
      doesn't re-nag.
- [ ] **AC-9 (metadata + compliance):** name/subtitle/description/keywords/category set;
      marketing+support+**privacy policy** URLs live; age rating completed;
      export-compliance answered (exempt/standard crypto); IDFA question = No.
- [ ] **AC-10 (release flow):** a TestFlight build is produced via `ios-release.yml`
      from a published Release with the documented secrets, installs on a device, and
      the documented promote-to-release steps are followed in App Store Connect.
- [ ] **AC-11 (privacy policy completeness):** the policy covers data types in §6,
      GDPR/CCPA basics, the `DELETE /v1/me` deletion path, and notes the analytics
      event-lake / feature-store erasure follow-ups (no overclaiming).

## 8. Test plan
- **Automated (CI / unit):**
  - AC-5 grep: a CI step / script asserts no Anthropic-key literal and no
    `ATTrackingManager`/IDFA reference in `ios/` sources and (best-effort) the archived
    app; confirms `NSUserTrackingUsageDescription` is absent from Info.plist.
  - AC-7 (server side): existing `delete_account` pytest proves the cascade
    (`cd backend && pytest`).
  - `make ios-test` stays green (no product regressions from icon/launch/UI explainer
    additions).
  - `ios-release.yml` continues to no-op safely without Apple secrets (existing
    behavior; verify the gate after edits).
- **Manual (Xcode / device / App Store Connect):**
  - AC-1/AC-2/AC-3 in Xcode + simulators (asset validation, launch render, screenshot
    capture at exact sizes).
  - AC-4/AC-9/AC-11 in App Store Connect (label + metadata + compliance) cross-checked
    against §6.
  - AC-6 sign-in-with-Apple on a configured stage; AC-7 in-app deletion end-to-end;
    AC-8 the explainer + permission flow on device.
  - AC-10 cut a TestFlight build from a published Release and install on a device.
- **Automated vs manual:** binary checks + backend cascade + suite green are automated;
  asset/label/metadata/sign-in/deletion-UX/release are manual (require Xcode + an Apple
  account + a configured backend).

## 9. Rollout & migration
- **Sequence:** assets (icon/launch/screenshots) → in-app compliance UX (Apple button,
  delete-account entry, notification explainer) → App Store Connect metadata + privacy
  label → TestFlight beta (internal then external) → submit → release.
- **Path A (account release):** ship with sign-in (Apple required if any federated
  login is shown). Requires the Cognito Apple IdP enabled and backend reachable. Pairs
  with the analytics + personalization specs being label-accurate.
- **Path B (no-account release fallback):** if sign-in isn't shippable in time, submit a
  **fully offline / Mock-only** build with **no login UI at all** — then 4.8 doesn't
  apply (no third-party login is offered) and 5.1.1(v) account-deletion isn't triggered
  (no account is created). The privacy label collapses to "no data collected" (Mock
  path). *Decision in §10.* This is a clean way to ship value early without blocking on
  sign-in/Cognito.
- **Backward compatibility / secrets:** `ios-release.yml` already no-ops without Apple
  secrets, so forks/CI stay green; baking URLs into `AppConfig.plist` is gated on
  secrets.
- **Privacy follow-ups acknowledged:** the policy + label note that event-lake and
  feature-store per-user erasure are tracked follow-ups (specs 0006 §9 + sibling) — keep
  analytics `props` to non-sensitive ids/enums until those land, so the disclosures stay
  truthful.
- **Teardown:** none (additive assets/metadata/docs); a rejected review iterates the
  metadata/label and resubmits.

## 10. Risks & open decisions
- **Decision — release path A vs B** (account vs offline-only first): *recommend B
  (offline/Mock-only) for the first submission if sign-in/Cognito isn't production-ready
  — it avoids 4.8/5.1.1 surface entirely and ships the core loop; then A once sign-in
  lands.* If A, **Sign in with Apple is mandatory** because Google is offered.
- **Decision — universal vs iPhone-only:** *recommend iPhone-only for v1* (fewer
  screenshot classes / less iPad layout QA); revisit for iPad later. Affects FR-3 device
  classes.
- **Decision — category:** Education vs Books/Reference. *Recommend Education* (matches
  the active-learning positioning); confirm keyword fit.
- **Risk — privacy-label inaccuracy → rejection or trust loss.** *Mitigation:* §6 matrix
  derived from real data paths + AC-5 binary checks + the analytics spec's ids/enums-only
  guarantee.
- **Risk — 4.8 rejection** if Google is shown without Apple. *Mitigation:* FR-5 makes
  Apple first-class; `AuthService.IdPHint.apple` already exists.
- **Risk — 5.1.1(v) rejection** if deletion isn't *in-app*. *Mitigation:* FR-6 in-app
  entry to the already-built `DELETE /v1/me`; support-URL fallback.
- **Risk — notifications rejection** for unclear purpose / nagging. *Mitigation:*
  pre-permission explainer + single ~1/day reminder + easy off (matches
  `NotificationService`).
- **Risk — public-domain content rights.** *Mitigation:* bundle only public-domain
  sample(s) with attribution; content-rights answer reflects this.
- **Risk — export compliance misanswer.** *Mitigation:* uses only standard
  HTTPS/TLS/system crypto (CryptoKit for PKCE) → exempt; document the answer.

## 11. Tasks & estimate
1. Final app icon set (all sizes, opaque 1024) in `Assets.xcassets/AppIcon` (**M**).
2. Launch screen in DesignSystem tokens, FOUC-free (**S**).
3. Screenshot capture pipeline for required device classes (core-loop shots) (**M**).
4. Sign-in screen: first-class **Sign in with Apple** button →
   `AuthService.signIn(idpHint: .apple)`; provider ordering; verify Cognito Apple IdP
   end-to-end (**M**, depends on sign-in shipping).
5. Settings **Delete account** UX (confirm → `DELETE /v1/me` → sign out → clear local →
   onboarding) + copy (**S**, backend done).
6. Notification pre-permission explainer + denied-state handling, tied to
   `NotificationService` (**S**).
7. App Privacy label matrix (§6) + draft & host **privacy policy** (GDPR/CCPA, deletion,
   follow-ups) (**M**).
8. Store metadata (name/subtitle/description/keywords/category/age) + URLs +
   export-compliance/IDFA answers (**S**).
9. CI/manual binary checks (no Anthropic key, no IDFA/ATT, no UTD string) — AC-5 script
   (**S**).
10. Release runbook in `docs/OPERATIONS.md`: TestFlight beta → submit → release, tied to
    `ios-release.yml` (secrets, `AppConfig.plist` baking) (**S**).
11. Pre-submission checklist (this spec's AC) as a living checklist; promote spec to
    `docs/specs/NNNN-…` (**S**).

## 12. References
- Release/build: `.github/workflows/ios-release.yml`, `docs/OPERATIONS.md`,
  `ios/Mango/Resources/AppConfig.plist`, `ios/ExportOptions.plist`.
- Assets/design: `ios/Mango/Resources/Assets.xcassets` (`AppIcon`, `AccentColor`),
  `ios/Mango/DesignSystem/` (`Palette`, `Typo`, `Metrics`).
- Auth (Sign in with Apple): `ios/Mango/Services/Auth/AuthService.swift`
  (`IdPHint.apple = "SignInWithApple"`, scope `openid email`),
  `backend/mango_backend/api_stack.py` (Cognito authorizer).
- Account deletion: [`shared/api/openapi.yaml`](../shared/api/openapi.yaml) `DELETE
  /v1/me`, `backend/src/handlers/delete_account.py`, `backend/mango_backend/api_stack.py`
  (`cognito-idp:AdminDeleteUser`).
- AI paths: `backend/src/shared/claude.py` (Bedrock), CLAUDE.md invariants (no key in
  app; offline-first), Direct-Claude Keychain key.
- Notifications: `ios/Mango/Services/Notifications/NotificationService.swift`
  (single ~1/day reminder).
- Privacy-relevant data flows: `feature-analytics-events-ios.md`,
  `feature-feature-store-personalization.md`,
  [`0006-data-lake.md`](../docs/specs/0006-data-lake.md) §9 (erasure follow-ups),
  [`../docs/DATA_MODEL.md`](../docs/DATA_MODEL.md).
- Apple guidelines referenced: 4.8 (Sign in with Apple), 5.1.1(v) (account deletion),
  App Privacy details / ATT.
- Template: [`SPEC_TEMPLATE.md`](../docs/specs/SPEC_TEMPLATE.md).
