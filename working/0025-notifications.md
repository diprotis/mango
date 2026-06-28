# 0025 — Notifications (local + remote push)

- **Epic:** M14 · **Status:** Draft · **Owner:** unassigned · **Updated:** 2026-06-28
- **Reviewers:** Principal / SD / QA

## 1. Summary
Mango today schedules exactly **one** local daily reminder (`NotificationService`, a `final class` with `requestAuthorization`, `scheduleDailyReminder(hour:minute:body:)`, `cancelDailyReminder`). This spec replaces that single-purpose service with a **proper notifications system** that delivers timely, **opt-in, per-category, respectful** notifications — both **local** (scheduled on-device) and **remote push** (server-initiated via APNs) — for every meaningful update: the **daily reminder**, **streak-at-risk**, **"your roadmap is ready"**, **activity/lesson due**, **credits earned**, **reward available**, **league updates**, and **achievement unlocked**. It honors `docs/GAMIFICATION.md` §2g/§6: a **hard frequency cap of ~1/day by default**, **quiet hours**, per-category toggles, calm copy, no fake urgency, and one-tap off. On iOS it extends `NotificationService` with `UNUserNotificationCenter` **categories + actions**, **provisional vs explicit** authorization, remote-push registration (`registerForRemoteNotifications` → device token), and a delegate that handles **foreground presentation** and **taps → deep link** through the existing `Route` enum. On the backend it adds **device registration** (`POST`/`DELETE /v1/me/devices`), **server-side preferences** (`GET`/`PUT /v1/me/notification-preferences`), and a **`notify` Lambda** that — triggered by product events — loads a user's devices + preferences, applies a **pure, unit-testable cap/quiet-hours/opt-in/dedupe gate**, and sends via **Amazon SNS mobile push (token-based APNs, .p8 in Secrets Manager)** — the recommended transport. Device tokens are treated as sensitive (no PII in payloads); sign-out and `DELETE /v1/me` purge devices. No third-party iOS deps; backend stays stdlib + boto3; no `float` in DynamoDB; `openapi.yaml` ⇄ `DTOs.swift` ⇄ handlers stay in lockstep.

## 2. Goals / Non-goals
- **Goals:**
  - A **typed notification taxonomy** (§6.1) covering all listed update types, each marked local-vs-push, default on/off, interruption level, and a **`Route` deep-link target**.
  - **iOS:** extend `NotificationService` to register **categories + actions**, register for **remote push**, request **provisional** (quiet) or **explicit** authorization, schedule local notifications, and route **foreground presentation + taps** to a deep link via `Route`. Concrete Swift signatures (§6.6).
  - **Backend device registry:** `POST /v1/me/devices` (register an APNs token) + `DELETE /v1/me/devices/{token}`, stored as `USER#<sub>/DEVICE#<token>` (`platform`, `env=sandbox|prod`, `lastSeen`).
  - **Backend delivery path:** product events/triggers → a `notify` Lambda that loads the user's devices + preferences, applies the **frequency cap + quiet hours + per-category opt-in + dedupe**, and sends via **Amazon SNS** (recommendation §6.4; APNs `.p8` in Secrets Manager; least-privilege IAM). No `float` in DynamoDB.
  - **Server-side preferences:** `GET`/`PUT /v1/me/notification-preferences` (per-category booleans, quiet-hours window, daily cap) + a **Settings screen** with per-category toggles and a quiet-hours picker. Default cap **~1/day**.
  - A **pure cap/quiet-hours function** (a `NotificationGate`, mirroring `StreakCalculator`/`LevelCurve`) that the `notify` Lambda calls and that is exhaustively unit-tested.
  - **Privacy/security:** tokens are sensitive (never logged, never echoed to peers, **no PII in payloads**), `.p8` in Secrets Manager, opt-in by construction, easy off, and a clean purge on sign-out / `DELETE /v1/me`.
  - Acceptance criteria mapped to **named tests**; a **Files to add/change** list; an ordered **S/M/L** task list; openapi⇄DTO⇄handler sync notes.
- **Non-goals:**
  - **Email / SMS** channels (push + local only; the taxonomy and gate are channel-extensible but only APNs ships).
  - **Android / FCM** (Mango is iOS-only per `CLAUDE.md`; the device registry stores `platform` so FCM can be added later without a schema change).
  - **Rich/media push** (images, communication notifications, Live Activities, notification-service-extension mutation) — text + deep link only in v1.
  - **A marketing campaign engine / scheduler UI / A-B testing** (Pinpoint-style). Triggers here are **transactional**, fired by existing product events; a daily-reminder/streak **cron** is the only scheduled producer.
  - **Building the upstream features.** Credits (`0023`), rewards (`0024`), and leagues (`0021`) are **trigger sources**; this spec defines the **notification seam** each will call, not those features. Where a source is not yet built, its trigger is wired behind that feature's flag and is inert until it lands.
  - **In-app notification inbox / notification center screen** (a feed of past notifications) — deferred; only OS notifications + a Settings preferences screen ship.
  - Changing `docs/GAMIFICATION.md` (we **reference** its §2g cap + §6 ethics; no doc edit).

## 3. Background & context
**Current iOS state (verified).**
- `ios/Mango/Services/Notifications/NotificationService.swift` is a `final class` with a private `UNUserNotificationCenter.current()` and `reminderID = "mango.dailyReminder"`. Its **entire public API today** is:
  ```swift
  func requestAuthorization() async -> Bool                 // options: [.alert, .sound, .badge]
  func authorizationStatus() async -> UNAuthorizationStatus
  func scheduleDailyReminder(hour: Int, minute: Int, body: String) async   // UNCalendarNotificationTrigger, repeats: true; removes pending reminderID first
  func cancelDailyReminder()
  ```
  It schedules a single repeating calendar notification titled "Mango". There are **no** categories, **no** remote-push registration, **no** delegate, and **no** deep linking. The doc-comment already states the design intent: "One gentle daily reminder… capped at a single repeating notification — no fake urgency, easy to turn off."
- `ios/Mango/App/AppModel.swift` — the `@Observable` service container constructs `notifications = NotificationService()` (a stored `let`). It also exposes `apiClient() -> APIClient?` (carries the Cognito id token, `nil` offline), `auth: AuthService`, `settings: AppSettings`, and `reloadAIService()`.
- `ios/Mango/App/RootView.swift` — currently requests notification authorization only indirectly: onboarding (`0010`) triggers it. `RootView.task` runs `SeedData.ensureSeeded`, `auth.refreshIfNeeded`, `reloadAIService`, and `maybePromptForSignIn`. **There is no `UIApplicationDelegate`** yet — `MangoApp` is a pure SwiftUI `App` (`MangoApp.swift`), so remote-push registration needs an `@UIApplicationDelegateAdaptor` (added here).
- `ios/Mango/App/Route.swift` — `enum Route: Hashable { case bookDetail(Book); case reader(Book); case journey(Book); case lesson(Lesson) }`, applied via `.mangoDestinations()` on each tab's `NavigationStack`. **Today all cases carry a SwiftData `@Model` value** (`Book`/`Lesson`), not an id — so deep links from a notification (which only carry ids/strings) need an **id-based resolution step** (a `DeepLink` enum + a resolver that fetches the model from SwiftData) before pushing a `Route`. This is the one real design wrinkle (§6.7, D-2).
- `ios/Mango/Resources/AppConfig.plist` — holds baked-in endpoints + Cognito Hosted-UI config (`BetaAPIURL`, `CognitoDomain`, `CognitoClientId`, `CognitoRegion`, `CognitoRedirectScheme = mango`). A custom URL scheme `mango://` is already reserved for the OAuth callback; notification deep links reuse the **app-internal** `DeepLink` model (no new URL scheme strictly needed, but `mango://` is available for universal handling — D-2).
- `ios/Mango/Services/Persistence/AppSettings.swift` — `@Observable`, `UserDefaults`-backed, with a `Keys` enum and `didSet` persistence. It already has `reminderEnabled: Bool` and a stable `deviceUserId` UUID. This is where local mirror flags (e.g. `notificationsPrimed`, the cached preference snapshot, the last APNs token) live.

**Current backend state (verified).**
- `backend/mango_backend/api_stack.py` — HTTP API v2 + `make_fn(name, handler, timeout, memory)` thin Lambdas; a local `route(path, method, fn, secured=True)` helper applies an `HttpUserPoolAuthorizer` (Cognito JWT). Least-privilege grants are explicit (`grade_fn` has **no** table access). The events Lambda gets `firehose:PutRecord*` only. New notification Lambdas follow this exactly.
- `backend/mango_backend/data_stack.py` — one `PAY_PER_REQUEST` table, `PK`/`SK` strings + a single `GSI1` (`GSI1PK`/`GSI1SK`); prod PITR. Device + preference + dedupe items are new SK shapes on the **same** table (no new infra).
- `backend/mango_backend/analytics_stack.py` — the events lake: a Firehose `mango-events-<stage>` stream → S3 `events/dt=…/`, Glue `mango_<stage>.events` (`ts,type,userId,props`). The `notify` Lambda's **scheduled** producer and **event-driven** triggers can both subscribe to product events; emitting `notification_sent`/`notification_suppressed` back to this lake gives us notification-health metrics (`docs/GAMIFICATION.md` §5).
- `backend/src/shared/response.py` — `user_id(event)` resolves the Cognito `sub` (raises `PermissionError` in `prod`/`beta` without JWT claims; dev `x-mango-user` fallback only outside those stages); helpers `ok`, `bad_request`, `not_found`, `server_error`, `json_response`, `parse_body`, `http_method`. Reused unchanged; we add `no_content()` (204) for `DELETE /v1/me/devices/{token}`.
- `backend/src/shared/firehose.py` — `put_event(type, user_id, props) -> bool`, best-effort, returns `False` on misconfig/failure. The `notify` Lambda reuses it for health events.
- `backend/src/handlers/events.py` — thin: `user_id` → validate `type` → `firehose.put_event`. The **template** for our thin device/preference handlers.
- `backend/src/handlers/delete_account.py` — `DELETE /v1/me` already deletes **all** `USER#<sub>` items (paginated `Query` + `batch_writer`) and `users/<sub>/` S3 objects, then admin-deletes the Cognito user. Because devices/preferences are `USER#<sub>/DEVICE#…`/`USER#<sub>/NOTIFPREFS`, **they are already swept** by this handler — we only add an SNS-endpoint cleanup (§6.9) so we don't leak SNS platform endpoints.
- `shared/api/openapi.yaml` — `openapi: 3.0.3`, `security: [ bearerAuth: [] ]` global, with per-route `security: []` for public routes (`/health`, `/v1/catalog`). `components.securitySchemes.bearerAuth`. **Note (correction to the task brief):** the live contract's `POST /v1/roadmaps/generate` is **async** — it returns **202 + `RoadmapJob`** and the client polls `GET /v1/roadmaps/jobs/{jobId}`. That async path is exactly why **`roadmap_ready` is a natural push**: the worker (`roadmap_worker.handler`) finishes off the request path and can fire the notification when the job completes (§6.3).

**Cross-references (triggers & priming).**
- `working/0010-onboarding-redesign.md` §6 page 4 ("Stay on track") is the **permission-priming** surface: a value-first pre-permission page that explains *why* + *how often* before the OS prompt, with "Maybe later". This spec defines what that page calls (provisional vs explicit, §6.6) and the per-category defaults it seeds.
- `working/0015-analytics-events-ios.md` — the event taxonomy (`lesson_completed`, `streak_extended`, `streak_frozen`, `achievement_unlocked`, `roadmap_created`, …). Several of these are **the same product moments** that should (server-side) fan out to a push; §6.3 maps events→notifications.
- `working/0023-payments-and-credits.md` — `earned_completion`/`purchased` credit grants → **`credits_earned`** notification; the credit ledger write is the trigger.
- `working/0024-rewards-and-coupons.md` — a new affordable/unlocked reward or a milestone "reward drop" → **`reward_available`**.
- `working/0021-social-leagues.md` — weekly rollover (promotion/relegation, EventBridge Mon 00:05 UTC) and leaderboard movement → **`league_update`**; achievements → **`achievement_unlocked`**.
- `docs/GAMIFICATION.md` §2g (notifications: "Hard cap at ~1–2/day… Quiet hours + full opt-out one tap away"), §2h (leagues opt-in / gentle), §5 ("Notification health: opt-in retention, open rate, **opt-out/disable rate**"), §6 (ethics manifesto: respect attention, no fake-urgency/fake-social, calm copy).

**Why now.** The app is growing surfaces that produce timely, server-side events (roadmap-ready async jobs, credits, rewards, leagues). Without a real notification system those moments are invisible unless the app is open, and the single local reminder can't represent them. M14 is the "bring users back, respectfully" milestone; doing it now — with the ethics cap baked into a pure gate — ensures every future trigger inherits the guardrails instead of bolting urgency on later.

## 4. User stories
- As a **new user**, I want a **pre-permission explanation** (during onboarding) of why and how often Mango notifies me **before** the OS asks, so I can opt in (or defer) with confidence — never prompted cold.
- As a **returning learner**, I want **one gentle daily nudge** at my anchor time, so the habit rides my routine without spam.
- As a **user with a streak**, I want a **single, kind heads-up only when my streak is genuinely at risk** (and only if I haven't already studied today), so I don't lose progress to a busy day — framed as a choice, not a threat.
- As a **user who imported a book**, I want a **"your roadmap is ready"** push when the async generation finishes, so I can start even if I closed the app while it ran.
- As an **engaged user**, I want to know when I **earned credits**, a **reward became available**, my **league standing changed**, or I **unlocked an achievement** — but only the categories I opted into, and never more than my daily cap.
- As a **privacy-minded user**, I want notification content to carry **no sensitive personal text**, my device token to be treated as a secret, and a **one-tap per-category off** plus quiet hours, so I stay in control.
- As **any user**, when I **tap** a notification I want it to **open the exact place** it's about (the journey, the lesson, my credits, the league), not just the home screen.
- As a **user who signs out or deletes my account**, I want my device + push registration **purged** so I stop receiving notifications and leave no token behind.
- As an **on-call engineer**, I want delivery to be **best-effort and rate-limited server-side**, so a trigger storm or a stale token never spams a user or pages me.

## 5. Requirements
### 5.1 Functional
- **FR-1 (taxonomy).** A typed, closed set of notification **categories** (§6.1) exists on both client and server with identical wire ids (snake_case). Each has: `local|push`, `defaultOn`, `interruptionLevel`, and a **deep-link target** expressed as a `DeepLink` (resolves to a `Route`). Unknown categories are not representable.
- **FR-2 (authorization — provisional & explicit).** `NotificationService` supports requesting **provisional** authorization (`.provisional`, quiet, no prompt) **and** explicit authorization (`[.alert, .sound, .badge]`, with the OS prompt). Onboarding's priming page (`0010`) decides which to request; the default recommended posture is **provisional on first run** (so early notifications are quiet/non-intrusive) with an explicit upgrade prompt offered later (D-4).
- **FR-3 (categories + actions).** On launch the service **registers `UNNotificationCategory`s** with relevant **actions** (e.g. `streak_at_risk` → "Study now" / "Remind me later"; `roadmap_ready` → "Open"; `reward_available` → "View"). Tapping the body or an action routes to the category's deep link (FR-8).
- **FR-4 (local scheduling).** The service schedules **local** notifications for the local-eligible categories: `daily_reminder` (repeating calendar trigger at the user's anchor, preserving today's behavior) and — when client-derivable — `streak_at_risk` (a same-day evening trigger that is **removed** as soon as the user studies). Scheduling is **idempotent** (clear + re-add by stable identifier).
- **FR-5 (remote-push registration).** On launch (after authorization is at least provisional), the app calls `UIApplication.shared.registerForRemoteNotifications()`; the app delegate's `didRegisterForRemoteNotificationsWithDeviceToken` forwards the hex token to `NotificationService.registerDeviceToken(_:)`, which **POSTs it to `/v1/me/devices`** (when signed in to a real backend). `didFailToRegister…` is handled (logged, no crash). Token changes (Apple may rotate) re-register.
- **FR-6 (device registry — backend).** `POST /v1/me/devices` upserts `USER#<sub>/DEVICE#<token>` with `{ platform: "ios", env: "sandbox"|"prod", appVersion, lastSeen }`; idempotent on `<token>`. `DELETE /v1/me/devices/{token}` removes it (and best-effort deletes the SNS endpoint). Tokens are validated (hex, length-bounded) and **never logged**.
- **FR-7 (preferences — backend + client).** `GET /v1/me/notification-preferences` returns the user's per-category booleans, quiet-hours window, daily cap, and timezone; `PUT` updates them. Stored at `USER#<sub>/NOTIFPREFS` (all scalars; no `float`). Defaults: each category's `defaultOn`, quiet hours **22:00–08:00 local**, daily cap **1**. The client renders a **Settings screen** with per-category toggles + a quiet-hours picker + a master switch, and caches a snapshot in `AppSettings` for offline display.
- **FR-8 (deep linking).** Tapping a notification (foreground or background, cold or warm launch) resolves `userInfo["deepLink"]` (a small JSON: `{ kind, ... ids }`) to a `DeepLink`, then to a `Route`, and **navigates** to it via a shared, observable navigation target on `AppModel` consumed by the active tab's `NavigationStack`. Cold-launch taps are honored after the first frame.
- **FR-9 (foreground presentation).** The delegate's `willPresent` returns a sensible presentation option set (`.banner, .list, .sound` for normal; `.banner` only / suppressed for low-value categories) so notifications don't jarringly interrupt active use, per `docs/GAMIFICATION.md` §6.
- **FR-10 (delivery gate — the load-bearing requirement).** The `notify` Lambda applies, in order, a **pure `NotificationGate`** decision (§6.5): (a) **per-category opt-in** (drop if the user disabled the category or the master switch); (b) **quiet hours** (defer/drop if now ∈ the user's quiet window in their tz — high-urgency categories may be exempt, D-5); (c) **frequency cap** (drop if the user already received ≥ `dailyCap` today, where `daily_reminder`/`streak_at_risk` are **exempt from counting against** the cap or counted, per §6.5 policy); (d) **dedupe** (drop if an identical `(category, dedupeKey)` was already sent within a window). Only if the gate returns **send** does it call SNS.
- **FR-11 (trigger sources).** The `notify` path is invoked by: a **scheduled** producer (EventBridge cron) for `daily_reminder` and `streak_at_risk` evaluation; and **inline** from the producing handlers/workers for `roadmap_ready` (roadmap worker), `credits_earned` (`0023` ledger grant), `reward_available` (`0024`), `league_update` (`0021` rollover), `achievement_unlocked` (grading/gamification). Each producer calls a thin `notify.enqueue(uid, category, payload, dedupeKey)` (a direct async Lambda invoke or an SQS hop — D-3) rather than sending directly, so the gate is always applied.
- **FR-12 (purge on sign-out / delete).** On **sign-out**, the client `DELETE`s its current token (`/v1/me/devices/{token}`) and unregisters for remote notifications; on **`DELETE /v1/me`** the existing cascade removes `DEVICE#`/`NOTIFPREFS` items, and the delete handler additionally **deletes the SNS platform endpoints** for those tokens (§6.9) so nothing keeps trying to deliver.

### 5.2 Non-functional
- **NFR-1 (respectful by construction — the ethics invariant).** Default **daily cap = 1** (`docs/GAMIFICATION.md` §2g). The gate enforces the cap, quiet hours, and per-category opt-in **server-side** so no producer can bypass it; copy is calm; no category uses `.timeSensitive`/`.critical` except a genuinely time-bound `streak_at_risk` (and even that is configurable off). No fake-social or fake-urgency categories exist. Opt-out is one tap (per category and master).
- **NFR-2 (privacy / token sensitivity).** Device tokens are **secrets**: never logged, never returned to other users, never placed in analytics `props`. **Payloads carry no PII** — no reflection/answer/book text, no email, no name; only short templated copy + ids in `userInfo` for routing. The `.p8` APNs key lives in **Secrets Manager** (the repo already provisions a Secrets-Manager path for the on-device Direct-Claude key; the APNs key is a separate secret).
- **NFR-3 (least-privilege IAM).** The device/preferences Lambdas get table read/write only. The `notify` Lambda gets table read (devices/prefs/dedupe write) + `sns:Publish`/`sns:CreatePlatformEndpoint`/`sns:GetEndpointAttributes`/`sns:SetEndpointAttributes` on the **specific platform-application ARN** + `secretsmanager:GetSecretValue` on the **APNs key secret** only. No other Lambda gets SNS. `grade_fn` stays table-less (existing invariant preserved).
- **NFR-4 (best-effort / resilient).** A delivery failure (bad token, SNS error, missing key) **never** breaks the producing request and **never** raises to a user; it logs + emits a health event and, on `EndpointDisabled`/invalid-token, **prunes** the device row. Mirrors `firehose.put_event`'s returns-`False` contract.
- **NFR-5 (offline-first preserved).** First launch with Mock AI + the bundled sample needs **no** push, **no** auth, **no** network: `daily_reminder` is a purely **local** notification that works with no backend (exactly as today). Remote categories simply don't fire until the user signs in to a real backend and registers a token. The Settings screen degrades to local-only controls offline.
- **NFR-6 (no new iOS deps; tokens-only UI).** No SPM/CocoaPods. The Settings screen uses `Palette`/`Typo`/`Metrics`/`Haptics` only — no raw hex, no magic numbers. APNs JWT/registration uses only `UserNotifications` + `UIKit` (via the delegate adaptor) + `Foundation`.
- **NFR-7 (backend style/runtime).** stdlib + boto3 only (SNS via boto3; no extra packaging). black (line-length 100) + flake8 (max 120). `pytest` (moto) + `cdk synth -c stage=beta` both pass offline (SNS mocked by moto / monkeypatched).
- **NFR-8 (float-free).** Every persisted numeric (cap, quiet-hour ints, counters, `lastSeen` epoch) is an `int`; reads coerce `Decimal`→`int` (reuse the `progress.py` idiom). Quiet hours are stored as integer minutes-from-midnight or `HH:MM` strings — never floats.
- **NFR-9 (accessibility).** Notification copy is concise and meaningful (good for the OS's own VoiceOver readout); the Settings screen has 44pt targets, Dynamic Type via `Typo`, VoiceOver labels on each toggle, and text equivalents for any status. No color-only state.
- **NFR-10 (performance/cost).** Delivery is per-user O(devices) (≤ a few rows) + O(1) cap/dedupe writes; the scheduled producer batches users it must evaluate. SNS mobile push is pay-per-publish (cheap; first 1M/month free tier historically). Dedupe + cap bound publish volume. The cron evaluates only users with the relevant category enabled and a recent install (a `GSI1` "active reminder users" listing — D-6).

## 6. Design

### 6.1 Notification taxonomy (the spine)
A closed `NotificationCategory` enum, mirrored as `CATEGORIES` server-side. `defaultOn` seeds new users' preferences; `local|push` says who schedules it; `interruption` maps to `UNNotificationInterruptionLevel`; the deep-link column is the `DeepLink` case it carries.

| id (wire) | Trigger / source | Local vs Push | Default on | Interruption level | Deep-link target (`DeepLink` → `Route`) | Counts vs cap? |
|---|---|---|---|---|---|---|
| `daily_reminder` | Scheduled cron at user anchor (and client-local mirror) | **Local** (also push fallback) | **On** | `active` | `.home` (Home tab; resume CTA) | **Exempt** (the one expected daily nudge) |
| `streak_at_risk` | Cron evening check *iff* streak alive and **not** studied today | **Local** (client-derivable) + push fallback | **On** | `timeSensitive` (configurable→`active`) | `.home` / `.journey(bookId)` (continue) | Exempt (replaces, not adds to, the daily reminder that day) |
| `roadmap_ready` | `roadmap_worker` job completes | **Push** | **On** | `active` | `.journey(bookId)` | Counts |
| `activity_due` | Cron: an in-progress lesson/journey idle ≥ N days | **Push** (+ local fallback) | Off | `passive` | `.journey(bookId)` or `.lesson(lessonId)` | Counts |
| `credits_earned` | `0023` ledger grant (`earned_completion`/`purchased`) | **Push** | Off | `passive` | `.credits` | Counts |
| `reward_available` | `0024` new affordable/unlocked reward or milestone drop | **Push** | Off | `passive` | `.rewards` | Counts |
| `league_update` | `0021` weekly rollover / notable rank change | **Push** | Off | `passive` | `.league` | Counts |
| `achievement_unlocked` | Grading/gamification unlock | **Push** (local fallback if earned offline) | **On** | `active` | `.profile` (or `.achievement(id)`) | Counts |

Notes:
- **Local fallback** means: if the moment is derivable on-device and the app is foreground/just-backgrounded, schedule a near-immediate local notification instead of (or in addition to, dedupe-guarded) a server push — useful for `achievement_unlocked` earned while offline.
- **`timeSensitive`** is used **only** for `streak_at_risk` and is **off by default-configurable**; research is explicit that overusing it makes users disable notifications entirely (§12). `.critical` is **never** used (requires a special entitlement and is inappropriate here).
- Default-on set is deliberately tiny (`daily_reminder`, `streak_at_risk`, `roadmap_ready`, `achievement_unlocked`) so a fresh user, even fully opted-in, stays within ~1/day in practice; the rest are **opt-in** (`defaultOn=false`), honoring §6 ethics.

### 6.2 `DeepLink` model + `Route` resolution (the one wrinkle)
`Route` cases carry SwiftData `@Model` values (`Book`/`Lesson`), but a notification can only carry **ids**. So we introduce an **id-based `DeepLink`** and a **resolver** that fetches the model and produces a `Route` (or a tab selection when no model is needed):
```swift
enum DeepLink: Equatable {
    case home
    case journey(bookId: String)
    case lesson(lessonId: String)
    case credits          // 0023 surface (Settings/Profile)
    case rewards          // 0024 surface
    case league           // 0021 surface
    case profile
    case achievement(id: String)

    /// Parse from a notification's userInfo["deepLink"] JSON ({ "kind": "...", ... }).
    init?(userInfo: [AnyHashable: Any]) { /* tolerant decode */ }
    var wire: [String: String] { /* { kind, bookId? , ... } for the push payload */ }
}
```
- The push payload's `userInfo` includes `{"deepLink": {"kind":"journey","bookId":"<id>"}}` plus `aps` (alert/sound). The server builds it from the category + ids it already has.
- On tap, `NotificationCoordinator` (held by `AppModel`) decodes the `DeepLink`, resolves any `@Model` from the SwiftData context (e.g. fetch `Book` by id), maps to a `Route`, and sets an `@Observable var pendingDeepLink` / selects the owning tab. The active tab's `NavigationStack` observes and pushes the `Route` (or, for `.credits/.rewards/.league/.profile`, switches tab / presents the screen). Cold launch: the coordinator stores the link and the resolver runs once the model container + first profile are ready (`RootView.task`).
- **D-2 decision:** keep deep links **app-internal** (`DeepLink` in `userInfo`) rather than minting `mango://` URLs; simpler, type-safe, and avoids overloading the OAuth scheme. (`mango://` remains available if universal-link parity is wanted later.)

### 6.3 Triggers → notifications (server mapping)
| Producer (existing/spec) | Event/hook | Category fired | dedupeKey |
|---|---|---|---|
| `roadmap_worker.handler` (async job complete) | on `status=complete` | `roadmap_ready` | `roadmap:<bookId>:<jobId>` |
| `0023` credit grant (`shared/credits.py` `grant_completion`/`grant_purchase`) | after ledger write | `credits_earned` | `credits:<ledgerTs>` |
| `0024` reward state (`shared/rewards.py`) | new affordable/unlocked / milestone drop | `reward_available` | `reward:<rewardId>:<day>` |
| `0021` rollover (`sweep`/league rollover Lambda) | next-week tier assigned / rank delta | `league_update` | `league:<weekId>` |
| grading/gamification (`grade_exercise` / engine) | `achievement_unlocked` | `achievement_unlocked` | `ach:<achievementId>` |
| **Scheduled cron** (`notify_cron`, EventBridge) | per-user evaluation | `daily_reminder`, `streak_at_risk`, `activity_due` | `daily:<localDate>` / `streak:<localDate>` / `due:<bookId>:<localDate>` |

Each inline producer calls `notify.enqueue(uid, category, payload, dedupeKey)`; it never sends directly (FR-11), guaranteeing the gate runs. The cron is the only producer that *originates* notifications without a user action; it reads the candidate set from a `GSI1` listing (D-6) and enqueues one evaluation per user.

### 6.4 Transport decision — **Amazon SNS mobile push (token-based APNs)** ✅ recommended
Three options were evaluated (research §12):

| Option | What it is | Pros | Cons | Verdict |
|---|---|---|---|---|
| **A. Amazon SNS mobile push** | Create an **APNs platform application** (token-based, `.p8`), register each device token as a **platform endpoint** (`CreatePlatformEndpoint`), `Publish` to the endpoint ARN. SNS speaks APNs HTTP/2 for us. | Managed (no HTTP/2 client, no JWT minting, no connection pooling in Lambda); **token-based `.p8`** supported (no yearly cert renewal) and the **same `.p8`/keyId/teamId** model we already use Secrets Manager for; cheap pay-per-publish; native CDK/boto3; auto-handles APNs feedback (disables dead endpoints). | One extra abstraction (platform endpoints); message/payload shaped as a JSON string under the `APNS`/`APNS_SANDBOX` key; per-endpoint publish (we already loop per device). | **Recommended.** |
| **B. Amazon Pinpoint** | Campaign/engagement platform with push. | Targeting, journeys, A/B, analytics. | **Being sunset** — no new customers since **May 20 2025**, **end of support Oct 30 2026** (research §12). Overkill for transactional pushes. | **Rejected** (deprecated). |
| **C. Direct APNs HTTP/2 from Lambda** | Mint an **ES256 JWT** (`.p8`, `kid`, `iss=teamId`, refresh ≤1h) and POST to `api.push.apple.com` over HTTP/2 per device. | No SNS dependency; full control of headers (`apns-priority`, `apns-collapse-id`, `apns-push-type`). | We must implement HTTP/2 + JWT signing + token caching + 403-expired handling + dead-token feedback **in stdlib** (no `httpx`/`PyJWT` under the no-packaging invariant); more code to test and keep correct. | **Fallback only** (if we later need APNs headers SNS doesn't expose, e.g. `collapse-id`). |

**Why A wins here:** it removes exactly the parts that are error-prone in a stdlib-only Lambda (HTTP/2, hourly JWT rotation, APNs feedback), keeps us on boto3, and reuses the `.p8`/Secrets-Manager pattern the repo already has. The platform application is created in CDK; the `.p8` (+ keyId, teamId, bundleId) is read from Secrets Manager by the platform-application config / the `notify` Lambda. SNS automatically marks endpoints disabled on APNs feedback, and the `notify` Lambda prunes the matching `DEVICE#` row on `EndpointDisabled` (NFR-4).

> If C is ever chosen, the per-device send becomes: build JWT (cache ~50 min), `POST https://api.push.apple.com/3/device/<token>` with `authorization: bearer <jwt>`, `apns-topic: <bundleId>`, `apns-push-type: alert`, body = `{aps:{…}, deepLink:{…}}`; treat `410` (`Unregistered`) / `403 ExpiredProviderToken` by pruning/refreshing. Documented for completeness; **not** the v1 path.

### 6.5 The pure gate — `NotificationGate` (mirrors `StreakCalculator`/`LevelCurve`)
A **pure, dependency-free** decision function the `notify` Lambda calls. No I/O, no clock of its own (caller passes `now`), exhaustively unit-tested.
```python
# backend/src/shared/notify_gate.py  (pure; no boto3)
from dataclasses import dataclass

@dataclass(frozen=True)
class Prefs:
    master_enabled: bool
    enabled: dict            # category -> bool
    quiet_start_min: int     # minutes from local midnight, e.g. 22*60
    quiet_end_min: int       # e.g. 8*60  (window wraps midnight if start > end)
    daily_cap: int           # default 1
    tz_offset_min: int       # user's UTC offset in minutes (from prefs/tz)

@dataclass(frozen=True)
class SendState:
    sent_today: int          # count of cap-counting notifications already sent on the user's local day
    recent_dedupe_keys: frozenset  # (category, dedupeKey) seen in the dedupe window

EXEMPT_FROM_CAP = {"daily_reminder", "streak_at_risk"}
QUIET_HOURS_EXEMPT = set()   # D-5: by default NOTHING bypasses quiet hours; streak_at_risk may be added

class Decision:  # str enum: "send" | "drop_disabled" | "drop_quiet" | "drop_capped" | "drop_dupe"
    ...

def decide(category: str, dedupe_key: str, prefs: Prefs, state: SendState, now_utc_min: int) -> str:
    if not prefs.master_enabled or not prefs.enabled.get(category, False):
        return "drop_disabled"
    if (category, dedupe_key) in state.recent_dedupe_keys:
        return "drop_dupe"
    if _in_quiet_hours(now_utc_min, prefs) and category not in QUIET_HOURS_EXEMPT:
        return "drop_quiet"        # v1: drop; a later rev may defer-to-window
    if category not in EXEMPT_FROM_CAP and state.sent_today >= prefs.daily_cap:
        return "drop_capped"
    return "send"

def _in_quiet_hours(now_utc_min: int, prefs: Prefs) -> bool:
    local = (now_utc_min + prefs.tz_offset_min) % (24*60)
    s, e = prefs.quiet_start_min, prefs.quiet_end_min
    return (s <= local < e) if s <= e else (local >= s or local < e)  # wrap midnight
```
- **Order:** disabled → dedupe → quiet hours → cap → send. (Disabled and dedupe are "never", quiet/cap are "not now".)
- **Cap accounting:** `daily_reminder`/`streak_at_risk` are **exempt** from the cap (the user explicitly wants the daily nudge); everything else increments a per-local-day counter (`USER#<sub>/NOTIFCOUNT#<localDate>`, atomic `ADD`, TTL'd). With `dailyCap=1`, a user gets the daily reminder **plus at most one** other notification per day — comfortably within `docs/GAMIFICATION.md` §2g's "~1–2/day".
- **Quiet-hours v1 policy:** **drop** (not queue) — simplest, safest, no late delivery; a future revision can **defer to the window's end** for non-urgent categories (D-5). `streak_at_risk` is the candidate exemption (it's inherently evening/time-bound) but defaults to **respecting** quiet hours unless the user's quiet window starts after the streak check time.
- **Dedupe:** the `notify` Lambda records `(category, dedupeKey)` in `USER#<sub>/NOTIFDEDUPE#<key>` with a TTL (e.g. 24–72h); the gate's `recent_dedupe_keys` is loaded from a small `begins_with` query. Prevents double-sends from retried producers / overlapping cron runs.

### 6.6 iOS — extended `NotificationService` + delegate (concrete signatures)
`NotificationService` grows from 4 methods to a small, testable surface. It stays a `final class` but its scheduling/auth calls are wrapped behind a tiny protocol so tests can spy (mirroring the `0010` note that today's `final class` must be made injectable for the onboarding tests).
```swift
import UserNotifications
import UIKit

final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()

    // MARK: Authorization
    /// Quiet, prompt-less authorization for early/low-friction enrollment (FR-2).
    func requestProvisionalAuthorization() async -> Bool        // options: [.alert,.sound,.badge,.provisional]
    /// Explicit prompt (used by the onboarding "Enable reminders" CTA / a Settings upgrade).
    func requestAuthorization() async -> Bool                   // options: [.alert,.sound,.badge]
    func authorizationStatus() async -> UNAuthorizationStatus

    // MARK: Categories + delegate
    /// Register all UNNotificationCategory + actions and set `self` as the center delegate. Call at launch.
    func registerCategories()
    // UNUserNotificationCenterDelegate:
    func userNotificationCenter(_:willPresent:withCompletionHandler:)   // foreground presentation (FR-9)
    func userNotificationCenter(_:didReceive:withCompletionHandler:)    // tap/action → deep link (FR-8)

    // MARK: Remote push (FR-5)
    /// Ask the OS for an APNs token (call once authorized). Triggers the delegate-adaptor callbacks.
    func registerForRemotePush()                                // -> UIApplication.shared.registerForRemoteNotifications()
    /// Called from AppDelegate.didRegisterForRemoteNotificationsWithDeviceToken; POSTs to /v1/me/devices.
    func registerDeviceToken(_ token: Data, client: APIClient?, env: APNSEnvironment) async
    /// Called on sign-out / disable; DELETE /v1/me/devices/{token} + unregister.
    func unregisterDeviceToken(client: APIClient?) async

    // MARK: Local scheduling (existing + new)
    func scheduleDailyReminder(hour: Int, minute: Int, body: String) async    // preserved API/behavior
    func cancelDailyReminder()
    func scheduleStreakAtRisk(at date: Date, deepLink: DeepLink, body: String) async   // same-day, removed on study
    func cancelStreakAtRisk()
    func scheduleLocal(_ category: NotificationCategory, deepLink: DeepLink, body: String, at trigger: UNNotificationTrigger) async
}

enum APNSEnvironment: String { case sandbox, prod }   // chosen from build config (DEBUG → sandbox)
```
- **App delegate (new).** A minimal `AppDelegate: NSObject, UIApplicationDelegate` wired via `@UIApplicationDelegateAdaptor` in `MangoApp` (the app currently has none). It implements `didRegisterForRemoteNotificationsWithDeviceToken` → `app.notifications.registerDeviceToken(...)`, `didFailToRegisterForRemoteNotificationsWithError` → log, and forwards `application(_:didReceiveRemoteNotification:…)` if we later add silent/content-available pushes (not v1). It holds a weak `AppModel` reference (set on launch) so token registration can reach `apiClient()`.
- **Delegate routing.** `didReceive response` reads `response.notification.request.content.userInfo`, builds a `DeepLink`, and hands it to `AppModel.notificationCoordinator.handle(_:)` which sets `pendingDeepLink`. `willPresent` returns presentation options by category (FR-9).
- **Wiring in `AppModel`/`RootView`.** `AppModel` gains `let notificationCoordinator = NotificationCoordinator()` and exposes `notifications`. `RootView.task` (after auth restore): `notifications.registerCategories()`; if authorization ≥ provisional, `notifications.registerForRemotePush()`; consume any `pendingDeepLink`. Sign-out path (in `AuthService`/Settings) calls `notifications.unregisterDeviceToken(client:)`.
- **Settings screen.** `ios/Mango/Features/Settings/NotificationSettingsView.swift` — a master toggle, a per-category `Toggle` list (label + caption from the taxonomy), a quiet-hours `DatePicker` pair, and a daily-cap stepper (1–3). Reads/writes via a `NotificationPreferencesService` (over `apiClient()`), caches a snapshot in `AppSettings`. Tokens-only styling. When notifications are OS-denied, shows a "Open Settings" affordance and disables toggles with an explanation.
- **No third-party deps:** everything above is `UserNotifications` + `UIKit` + `Foundation`.

### 6.7 Backend — endpoints, handlers, data (single table)
**New routes (in `api_stack.py`, via the local `route(...)` helper; all JWT-secured):**
```
POST   /v1/me/devices                      -> devices_fn   (register/upsert APNs token)
DELETE /v1/me/devices/{token}              -> devices_fn   (remove token + SNS endpoint)
GET    /v1/me/notification-preferences     -> notifprefs_fn
PUT    /v1/me/notification-preferences     -> notifprefs_fn
```
The **`notify` Lambda is not a route** — it's invoked by producers (async invoke or SQS, D-3) and by the EventBridge cron; it has no API Gateway integration.

**New handlers (thin; logic in `shared/`):**
- `backend/src/handlers/devices.py` — `POST` parses `{ token, platform?, env? }`, validates the token, upserts `USER#<sub>/DEVICE#<token>`, **creates/refreshes the SNS platform endpoint** (or defers endpoint creation to `notify` — D-7), returns `{ registered: true }`. `DELETE` removes the row + best-effort `sns:DeleteEndpoint`, returns 204.
- `backend/src/handlers/notification_preferences.py` — `GET` returns the prefs (auto-seeding defaults from `CATEGORIES` if absent), `PUT` validates + writes `USER#<sub>/NOTIFPREFS`. All ints; quiet hours as `HH:MM` strings or minute-ints.
- `backend/src/handlers/notify.py` — the **delivery worker** (invoked, not routed). Loads devices + prefs + dedupe/count state, calls `notify_gate.decide(...)`, and on `send` publishes via `shared/sns_push.py`; records the dedupe key + increments the day counter; emits a `notification_sent`/`notification_suppressed` health event via `firehose.put_event`. Prunes disabled endpoints.
- `backend/src/handlers/notify_cron.py` — EventBridge-scheduled; lists candidate users (D-6), enqueues `daily_reminder`/`streak_at_risk`/`activity_due` evaluations into `notify`.

**New shared modules:**
- `backend/src/shared/notify_gate.py` — the pure gate (§6.5).
- `backend/src/shared/sns_push.py` — `ensure_endpoint(token, platform_app_arn) -> endpoint_arn` (`CreatePlatformEndpoint`, idempotent; handles the "already exists with different attrs" reconcile), `publish(endpoint_arn, payload) -> bool` (wraps the APNs/APNS_SANDBOX JSON envelope), `disable_prune(endpoint_arn)`. boto3 only.
- `backend/src/shared/notifications.py` — the `CATEGORIES` table (id → defaultOn/local|push/interruption/deepLink kind), payload/copy builders, and `enqueue(uid, category, payload, dedupeKey)` (async-invoke/SQS put).

**Data — single-table items (all scalars; no `float`):**

| Entity | PK | SK | GSI1PK / GSI1SK | Key attributes |
|---|---|---|---|---|
| **Device** | `USER#<sub>` | `DEVICE#<token>` | `DEVICE#ACTIVE` / `<lastSeen>#<sub>` | `platform:"ios"`, `env:"sandbox"|"prod"`, `endpointArn`, `appVersion`, `lastSeen:int` |
| **Preferences** | `USER#<sub>` | `NOTIFPREFS` | — | `masterEnabled:bool`, `enabled:map<cat,bool>`, `quietStart:"22:00"`, `quietEnd:"08:00"`, `dailyCap:int`, `tz:"America/New_York"`, `tzOffsetMin:int`, `updatedAt` |
| **Day counter** | `USER#<sub>` | `NOTIFCOUNT#<localDate>` | — | `count:int` (atomic `ADD`), `ttl:int` |
| **Dedupe marker** | `USER#<sub>` | `NOTIFDEDUPE#<category>#<dedupeKey>` | — | `sentAt:int`, `ttl:int` |

- The `DEVICE#ACTIVE` GSI listing (D-6) gives the cron an O(query) candidate set of recently-seen devices to evaluate, instead of a table scan.
- `NOTIFCOUNT#`/`NOTIFDEDUPE#` carry a DynamoDB **TTL** so they self-expire (housekeeping-free). All are under `USER#<sub>`, so the **existing `DELETE /v1/me` cascade already purges them**.

### 6.8 API / contract (add to `shared/api/openapi.yaml`; keep `DTOs.swift` + handlers in lockstep)
```yaml
  /v1/me/devices:
    post:
      summary: Register (or refresh) this device's APNs token for push
      requestBody:
        required: true
        content:
          application/json:
            schema: { $ref: "#/components/schemas/DeviceRegistration" }
      responses:
        "200": { description: Registered, content: { application/json: { schema: { $ref: "#/components/schemas/DeviceRegistered" } } } }
        "400": { description: Malformed token }
        "401": { description: Unauthenticated }
  /v1/me/devices/{token}:
    delete:
      summary: Remove a device's push registration (sign-out / disable)
      parameters:
        - { name: token, in: path, required: true, schema: { type: string } }
      responses:
        "204": { description: Removed (idempotent) }
        "401": { description: Unauthenticated }
  /v1/me/notification-preferences:
    get:
      summary: Read the caller's notification preferences (auto-seeds defaults)
      responses:
        "200": { description: Preferences, content: { application/json: { schema: { $ref: "#/components/schemas/NotificationPreferences" } } } }
        "401": { description: Unauthenticated }
    put:
      summary: Update the caller's notification preferences
      requestBody:
        required: true
        content:
          application/json:
            schema: { $ref: "#/components/schemas/NotificationPreferences" }
      responses:
        "200": { description: Updated, content: { application/json: { schema: { $ref: "#/components/schemas/NotificationPreferences" } } } }
        "400": { description: Invalid preferences }
        "401": { description: Unauthenticated }
components:
  schemas:
    DeviceRegistration:
      type: object
      required: [token]
      properties:
        token:      { type: string, description: "APNs device token (hex)" }
        platform:   { type: string, enum: [ios], default: ios }
        env:        { type: string, enum: [sandbox, prod] }
        appVersion: { type: string, nullable: true }
    DeviceRegistered:
      type: object
      properties:
        registered: { type: boolean, example: true }
    NotificationPreferences:
      type: object
      properties:
        masterEnabled: { type: boolean, example: true }
        enabled:
          type: object
          additionalProperties: { type: boolean }
          example: { daily_reminder: true, streak_at_risk: true, roadmap_ready: true,
                     activity_due: false, credits_earned: false, reward_available: false,
                     league_update: false, achievement_unlocked: true }
        quietStart: { type: string, example: "22:00" }
        quietEnd:   { type: string, example: "08:00" }
        dailyCap:   { type: integer, example: 1, minimum: 0, maximum: 10 }
        tz:         { type: string, example: "America/New_York" }
        updatedAt:  { type: string, format: date-time, nullable: true }
```
**openapi ⇄ DTO ⇄ handler sync notes.** Add to `ios/Mango/Services/Networking/DTOs.swift` (tolerant decode, mirroring `CatalogBook.init(from:)`): `DeviceRegistration { token; platform; env; appVersion? }`, `DeviceRegisteredDTO { registered }`, `NotificationPreferencesDTO { masterEnabled; enabled: [String: Bool]; quietStart; quietEnd; dailyCap: Int; tz; updatedAt: String? }`. The handlers (`devices.py`, `notification_preferences.py`) return exactly these shapes; `enabled` keys are the §6.1 category ids. The `notify`/`notify_cron` Lambdas are **internal** (no contract surface). Keep all three in lockstep per the `CLAUDE.md` invariant.

### 6.9 CDK / infra (`api_stack.py` + a small push construct; least-privilege)
- **SNS platform application (APNs, token-based).** Add a CDK construct (L1 `CfnPlatformApplication` or a small custom resource) configured for **APNs token auth**: `PlatformCredential = <.p8 contents>`, `PlatformPrincipal = <signingKeyId>`, plus `ApplePlatformTeamID`/`ApplePlatformBundleID` attributes — sourced from **Secrets Manager** (`mango/apns/<stage>` holding `{ p8, keyId, teamId, bundleId }`). Separate `APNS` (prod) vs `APNS_SANDBOX` apps, selected by stage / device `env`.
- **Lambdas** via `make_fn`: `devices_fn` (`handlers.devices.handler`), `notifprefs_fn` (`handlers.notification_preferences.handler`), `notify_fn` (`handlers.notify.handler`, not routed), `notify_cron_fn` (`handlers.notify_cron.handler`, not routed).
- **Routes** (secured): `POST /v1/me/devices`, `DELETE /v1/me/devices/{token}`, `GET`/`PUT /v1/me/notification-preferences`.
- **Grants (least-privilege):**
  - `table.grant_read_write_data(devices_fn)`, `table.grant_read_write_data(notifprefs_fn)`, `table.grant_read_write_data(notify_fn)`, `table.grant_read_data(notify_cron_fn)` (+ write to enqueue).
  - `notify_fn`: `sns:Publish`, `sns:CreatePlatformEndpoint`, `sns:GetEndpointAttributes`, `sns:SetEndpointAttributes`, `sns:DeleteEndpoint` **scoped to the platform-application ARN(s)**; `secretsmanager:GetSecretValue` on the **APNs key secret** only.
  - `devices_fn`: `sns:CreatePlatformEndpoint`/`sns:DeleteEndpoint` on the platform app (if endpoint creation happens at register-time — D-7), else none.
  - Producers that enqueue (`roadmap_worker_fn`, `grade_fn`'s caller, `0023`/`0024`/`0021` Lambdas): `lambda:InvokeFunction` on `notify_fn` **only** (or `sqs:SendMessage` to the notify queue) — not SNS, not the APNs secret. **`grade_fn` keeps no table access**; it enqueues via the same invoke permission, preserving the existing invariant.
- **EventBridge rule** → `notify_cron_fn` (e.g. hourly; it picks users whose local anchor/quiet window matches). `cdk synth -c stage=beta` must pass with the new routes, the platform app, and the IAM scoping.
- **`delete_account.py` addition (FR-12).** Before/while deleting `USER#<sub>` items, enumerate the user's `DEVICE#` rows and `sns:DeleteEndpoint` each `endpointArn` (best-effort, never raises), so account deletion leaves **no** live SNS endpoint. Grant `delete_fn` `sns:DeleteEndpoint` on the platform app(s).

### 6.10 Push payload shape (SNS → APNs)
The `notify` Lambda publishes a message whose `MessageStructure=json` body carries the APNs envelope:
```json
{
  "APNS": "{\"aps\":{\"alert\":{\"title\":\"Your roadmap is ready\",\"body\":\"Tap to start your journey.\"},\"sound\":\"default\",\"interruption-level\":\"active\",\"category\":\"roadmap_ready\"},\"deepLink\":{\"kind\":\"journey\",\"bookId\":\"<id>\"}}",
  "APNS_SANDBOX": "{ ...same... }",
  "default": "Your roadmap is ready"
}
```
- `aps.category` matches the registered `UNNotificationCategory` (enables actions). `interruption-level` set per taxonomy. **No PII** — `title`/`body` are short templated strings; only ids ride in `deepLink` (NFR-2).
- For local notifications the same `deepLink` dict goes into `content.userInfo["deepLink"]`, so tap-handling is identical for local and push.

### 6.11 Diagrams
```
iOS launch:
  AppDelegate.didRegister…DeviceToken(data)
    → NotificationService.registerDeviceToken(hex, client, env)
        → POST /v1/me/devices {token,platform:"ios",env}  → devices_fn → USER#<sub>/DEVICE#<token> (+ SNS endpoint)

Trigger (e.g. roadmap ready):
  roadmap_worker (job complete)
    → notifications.enqueue(uid, "roadmap_ready", payload, dedupe="roadmap:<bookId>:<jobId>")
        → notify_fn:
             load DEVICE#*, NOTIFPREFS, NOTIFCOUNT#<day>, NOTIFDEDUPE#*
             decide = notify_gate.decide("roadmap_ready", key, prefs, state, now)
               ├ drop_disabled/quiet/capped/dupe → firehose("notification_suppressed",{reason}); STOP
               └ send → sns_push.publish(endpointArn, {aps,deepLink})
                        → record NOTIFDEDUPE#key (ttl) ; ADD NOTIFCOUNT#<day> 1 (if counts)
                        → firehose("notification_sent",{category})
                        → on EndpointDisabled → prune DEVICE# row

iOS tap:
  UNUserNotificationCenterDelegate.didReceive(response)
    → DeepLink(userInfo) → AppModel.notificationCoordinator.pendingDeepLink = link
        → active tab NavigationStack resolves @Model by id → push Route(.journey(book)) (cold launch: after RootView.task)

Daily/streak (no user action):
  EventBridge (hourly) → notify_cron_fn → list DEVICE#ACTIVE candidates whose local anchor matches
    → enqueue("daily_reminder"|"streak_at_risk", …) → notify_fn (same gate)
  (client also schedules a LOCAL daily_reminder so it works fully offline — NFR-5)

Sign-out / delete:
  sign-out → NotificationService.unregisterDeviceToken → DELETE /v1/me/devices/{token} (+ sns:DeleteEndpoint) + unregisterForRemoteNotifications
  DELETE /v1/me → existing cascade purges DEVICE#/NOTIFPREFS/COUNT/DEDUPE + sns:DeleteEndpoint per endpointArn
```

## 7. Acceptance criteria
- [ ] **AC-1 (taxonomy parity).** The `NotificationCategory` set on iOS and the `CATEGORIES` table on the backend have identical wire ids, and each has a `local|push`, `defaultOn`, `interruptionLevel`, and a `DeepLink`. *(iOS: `NotificationCategoryTests.test_ids_and_defaults`; backend: `test_notifications_catalog.py::test_category_ids_match_contract`.)*
- [ ] **AC-2 (gate — opt-in).** A category disabled in prefs (or master off) → `decide` returns `drop_disabled` and **no** SNS publish. *(unit: `test_notify_gate.py::test_drop_when_disabled`, `::test_drop_when_master_off`.)*
- [ ] **AC-3 (gate — quiet hours, wrap midnight).** With quiet 22:00–08:00 and `now` at 23:30 local → `drop_quiet`; at 12:00 → not dropped for quiet. Wrap-around window handled. *(unit: `test_notify_gate.py::test_quiet_hours_wrap`.)*
- [ ] **AC-4 (gate — daily cap).** With `dailyCap=1` and one cap-counting notification already sent today, a second cap-counting category → `drop_capped`, while `daily_reminder` (exempt) → `send`. *(unit: `test_notify_gate.py::test_cap_blocks_second_and_exempts_daily`.)*
- [ ] **AC-5 (gate — dedupe).** A repeated `(category, dedupeKey)` within the window → `drop_dupe`. *(unit: `test_notify_gate.py::test_dedupe`.)*
- [ ] **AC-6 (device register/unregister).** `POST /v1/me/devices` upserts `USER#<sub>/DEVICE#<token>` (idempotent on token); `DELETE /v1/me/devices/{token}` removes it and returns 204. Unauthenticated → 401 in prod/beta. *(moto: `test_devices.py::test_register_idempotent`, `::test_delete_removes`, `::test_requires_auth_in_prod`.)*
- [ ] **AC-7 (preferences CRUD + defaults).** `GET` on a new user **auto-seeds** the `CATEGORIES` defaults (quiet 22:00–08:00, cap 1); `PUT` round-trips per-category booleans + quiet hours + cap; all numerics are `int` (a `Decimal` round-trips to `int`). *(moto: `test_notification_preferences.py::{test_get_seeds_defaults,test_put_roundtrip,test_int_coercion}`.)*
- [ ] **AC-8 (mocked send + prune).** With `sns_push.publish` monkeypatched: a `send` decision calls publish exactly once with the §6.10 envelope and records dedupe + increments the day counter; an `EndpointDisabled` result **prunes** the `DEVICE#` row. *(moto + monkeypatch: `test_notify.py::{test_send_publishes_and_records,test_disabled_endpoint_pruned}`.)*
- [ ] **AC-9 (no-PII payload).** The built payload's `title`/`body` contain only templated copy and the `deepLink` carries only ids — asserted against a forbidden-substring set (no reflection/answer/book-text/email markers). *(unit: `test_notifications_catalog.py::test_payload_has_no_pii`.)*
- [ ] **AC-10 (least privilege).** `grade_fn` still has **no** table access; only `notify_fn` (and `delete_fn` for cleanup) hold SNS perms and they are scoped to the platform-application ARN; only `notify_fn` reads the APNs secret. *(`cdk synth -c stage=beta` IAM inspection; assertion in `test_infra_iam` if present.)*
- [ ] **AC-11 (iOS category→deep-link mapping).** Decoding a sample `userInfo` for each category yields the expected `DeepLink`, and the resolver maps it to the expected `Route`/tab. *(iOS: `NotificationDeepLinkTests.test_userInfo_maps_to_deeplink_and_route` per category.)*
- [ ] **AC-12 (iOS registration flow).** `registerDeviceToken` hex-encodes the token and POSTs `/v1/me/devices` via a `FakeAPIClient`; `unregisterDeviceToken` DELETEs it; both no-op cleanly when `client == nil` (offline). *(iOS: `NotificationServiceTests.{test_register_posts_token,test_unregister_deletes,test_noop_offline}`.)*
- [ ] **AC-13 (provisional vs explicit).** `requestProvisionalAuthorization` requests `.provisional` (quiet) and `requestAuthorization` requests the explicit set; the onboarding priming page calls the chosen one (D-4). *(iOS: `NotificationServiceTests.test_auth_option_sets` with a spy center; manual: no cold prompt.)*
- [ ] **AC-14 (offline-first).** Fresh install, Mock AI, no network/auth: the **local** `daily_reminder` schedules and fires with **no** backend call; no push/device registration is attempted. *(manual offline run + `test_noop_offline`.)*
- [ ] **AC-15 (purge on sign-out / delete).** Sign-out DELETEs the token + unregisters; `DELETE /v1/me` removes `DEVICE#`/`NOTIFPREFS`/`NOTIFCOUNT#`/`NOTIFDEDUPE#` items and `sns:DeleteEndpoint`s each device. *(moto: `test_delete_account.py::test_purges_devices_and_prefs` extends the existing cascade test; `test_devices.py` for endpoint delete.)*
- [ ] **AC-16 (contract sync).** `openapi.yaml` defines the four paths + schemas; `DTOs.swift` mirrors them and decodes leniently; `cdk synth -c stage=beta` passes. *(openapi lint + `DTOsTests` decode test + synth.)*
- [ ] **AC-17 (respectful defaults).** Default prefs yield ≤ ~1/day for a fully-opted-in new user (cap 1 + exempt daily reminder); `.timeSensitive` is used by **only** `streak_at_risk` and is configurable off; no `.critical`. *(unit assertion on `CATEGORIES` + manual review against `docs/GAMIFICATION.md` §2g.)*

## 8. Test plan
- **Backend unit (pytest + moto; offline; primary):**
  - `test_notify_gate.py` — the **pure gate**, exhaustive: disabled/master-off, quiet-hours incl. **wrap-midnight** and tz offset, cap (block + exempt daily), dedupe, and the decision **ordering** (AC-2…AC-5). Mirrors `test_streak_calculator` style.
  - `test_devices.py` — register idempotency, delete + 204, token validation, auth-in-prod (AC-6, AC-15 endpoint delete).
  - `test_notification_preferences.py` — GET seeds defaults, PUT round-trip, int coercion (`Decimal`→`int`), invalid payload → 400 (AC-7).
  - `test_notify.py` — with `sns_push.publish` and `firehose.put_event` monkeypatched: send publishes the §6.10 envelope once + records dedupe + increments counter; suppression paths emit `notification_suppressed`; `EndpointDisabled` prunes the device (AC-8).
  - `test_notifications_catalog.py` — category ids match the contract enum, payload has no PII (AC-1, AC-9).
  - `test_delete_account.py` (extend) — purges devices/prefs/count/dedupe + `sns:DeleteEndpoint` (AC-15).
  - `test_contract.py` (extend) — the four new paths/schemas exist (AC-16).
  - `cdk synth -c stage=beta` — new routes, platform app, **IAM scoping** (AC-10, AC-16).
- **iOS unit (XCTest, `MangoTests`, pure-logic-preferred per `CLAUDE.md`):**
  - `NotificationCategoryTests` — ids/defaults/interruption/deep-link mapping (AC-1).
  - `NotificationDeepLinkTests` — `DeepLink(userInfo:)` per category → expected `DeepLink` + resolved `Route`/tab (AC-11).
  - `NotificationServiceTests` — token hex-encode + POST via `FakeAPIClient`; unregister DELETE; offline no-op; provisional vs explicit option sets via a spy `UNUserNotificationCenter` wrapper (AC-12, AC-13, AC-14 no-op).
  - `NotificationPreferencesServiceTests` — encode/decode `NotificationPreferencesDTO`, snapshot cache in `AppSettings`.
  - `DTOsTests` (extend) — decode the new DTOs from sample JSON (contract; AC-16).
- **Manual / device (TestFlight beta):**
  - Provisional enrollment: no cold prompt; a quiet notification appears in Notification Center with keep/turn-off (AC-13).
  - End-to-end push: sign in on beta, import a book, background the app, confirm a `roadmap_ready` push when the async job completes, tap → lands on the journey (AC-11/AC-8 e2e).
  - Quiet hours / cap honored on device (set quiet window around "now", confirm suppression; confirm only one capped notification/day).
  - Sign-out + delete: confirm notifications stop and re-install requires re-registration (AC-15).
  - Offline: airplane mode, fresh install — local daily reminder still fires (AC-14).
- **Automated vs manual:** the gate, device/prefs CRUD, mocked send/prune, and DTO/deep-link mapping are **automated**; actual APNs delivery, provisional-prompt-absence, and on-device quiet-hours/cap behavior are **manual** (need a signed build + APNs sandbox).

## 9. Rollout & migration
- **Additive, no migration.** New routes + new single-table SK shapes + new Lambdas + an SNS platform app. Existing `daily_reminder` behavior is **preserved** (the local path is unchanged; the server path is additive). Users who never grant push simply keep the local reminder.
- **Secrets prerequisite.** Create the **APNs `.p8`** (Apple Developer → Keys → APNs), store `{ p8, keyId, teamId, bundleId }` in Secrets Manager (`mango/apns/<stage>`), and enable the **Push Notifications** capability + an APNs-enabled provisioning profile on the app target. The app must be a **real signed build** (push doesn't work in Simulator pre-iOS-16 reliably; use a device).
- **Staged flags (default off except the preserved local reminder):**
  - `pushEnabled` (master, default **off** until the platform app + secret are live on a stage) — gates remote registration + the server `notify` path; the **local** `daily_reminder` is always available.
  - Per-source enablement rides each upstream feature's own flag (`credits_earned` behind `0023`'s `creditsEnabled`; `reward_available` behind `0024`'s `rewardsEnabled`; `league_update` behind `0021`'s `socialLeaguesEnabled`) — so a category only fires once its source ships.
  - A `notificationsHardDisabled` kill-switch (AppConfig + a server env flag) lets a bad build/stage ship with push fully inert.
- **Dogfood on beta first** (verify provisional enrollment, roadmap-ready push, quiet hours, cap), then Prod.
- **Backward compatibility.** Older app versions: no device token → no push; they keep the local reminder. New categories are additive; `enabled` is a map so unknown keys default off.
- **Teardown.** Disabling `pushEnabled` stops the server path and registration; the local reminder remains. Deleting the platform app + secret fully removes remote push.

## 10. Risks & open decisions
**Risks + mitigations**
- **R-1 Over-notification / ethics regression (headline).** A future producer could spam. *Mitigation:* the **server-side gate** is the single choke point (FR-10/NFR-1); producers can only `enqueue`, never send; default cap 1; instrument **opt-out/disable rate** as a coercion alarm (`docs/GAMIFICATION.md` §5). Code review checklist: any new category must declare `defaultOn`/interruption and pass through the gate.
- **R-2 Token leakage / privacy.** Device tokens or PII in payloads. *Mitigation:* tokens never logged/echoed; payloads carry only templated copy + ids (AC-9); `.p8` in Secrets Manager; least-privilege SNS (AC-10).
- **R-3 Stale / invalid tokens.** Tokens rotate; uninstalls leave dead endpoints. *Mitigation:* SNS marks endpoints disabled on APNs feedback; `notify` prunes the `DEVICE#` row on `EndpointDisabled` (NFR-4); `lastSeen` + the cron's recency filter avoid evaluating long-dead devices.
- **R-4 Sandbox vs prod APNs mismatch.** A sandbox token published to the prod platform app silently fails. *Mitigation:* store `env` per device, select the matching platform app, set `env` from build config (DEBUG→sandbox); manual beta test covers it.
- **R-5 Cold-launch deep-link race.** Tapping a notification before SwiftData/profile is ready. *Mitigation:* the coordinator **stores** `pendingDeepLink` and resolves after `RootView.task` seeds the container + first profile; resolver is id-based and tolerant of a missing model (falls back to the owning tab).
- **R-6 No `UIApplicationDelegate` today.** Remote registration needs one. *Mitigation:* add a minimal `@UIApplicationDelegateAdaptor` (the only purpose is push token callbacks); it doesn't change the SwiftUI app lifecycle otherwise.
- **R-7 Quiet-hours "drop vs defer".** Dropping during quiet hours can lose a timely message. *Mitigation:* v1 drops (simplest/safest); D-5 leaves room to defer non-urgent categories to the window's end in a later rev; `streak_at_risk` timing is chosen to precede typical quiet windows.
- **R-8 Trigger-storm fan-out cost.** A burst of grants could enqueue many evaluations. *Mitigation:* dedupe + per-day cap bound publishes; the enqueue hop (SQS, D-3) smooths spikes; SNS publish is cheap.
- **R-9 Cron timezone fairness.** A single cron must respect each user's tz/anchor. *Mitigation:* prefs store `tz`/`tzOffsetMin`; the hourly cron only enqueues users whose local anchor/quiet matches this hour; the gate re-checks quiet hours in the user's tz.

**Decisions needed (with recommendation)**
- **D-1 (recommended: Amazon SNS mobile push, token-based APNs).** Transport. *Recommend SNS* (§6.4) — managed HTTP/2 + `.p8` reuse + boto3; reject Pinpoint (sunset), keep direct-APNs (C) as a documented fallback if we need `collapse-id`/custom headers.
- **D-2 (recommended: app-internal `DeepLink` in `userInfo`, not `mango://`).** Deep-link encoding. *Recommend the typed `DeepLink`* over URL strings; reserve `mango://` for future universal-link parity.
- **D-3 (recommended: direct async Lambda invoke for v1; SQS if volume grows).** Producer→`notify` hop. *Recommend async invoke* now (simplest, IAM = `lambda:InvokeFunction`); switch to **SQS** if we need buffering/retries/DLQ at scale.
- **D-4 (recommended: provisional on first run, explicit upgrade later).** Authorization posture. *Recommend provisional* so early notifications are quiet/non-intrusive (research: avoids cold prompts, lifts long-run opt-in), with an explicit "turn on sounds/banners" upgrade offered from the priming page (`0010`) or Settings.
- **D-5 (recommended: quiet hours = drop in v1; nothing bypasses by default).** Quiet-hours behavior + exemptions. *Recommend drop*, with `QUIET_HOURS_EXEMPT` empty by default; revisit deferring non-urgent categories and exempting `streak_at_risk` after data.
- **D-6 (recommended: a `DEVICE#ACTIVE` GSI listing for the cron).** Candidate selection. *Recommend the GSI* over a table scan; the cron queries recently-seen devices and enqueues per user.
- **D-7 (recommended: create the SNS endpoint lazily in `notify`, cache `endpointArn` on the device row).** Where endpoint creation happens. *Recommend lazy* (keeps `devices_fn` SNS-free; `notify` reconciles/creates and stores `endpointArn`), trading a tiny first-send latency for tighter IAM on `devices_fn`.
- **D-8 (recommended: do NOT edit `docs/GAMIFICATION.md`).** Per the brief — reference §2g/§6; no doc change. The cap/ethics live in code (the gate) + this spec.

## 11. Tasks & estimate
1. **(S)** Define the **taxonomy**: `NotificationCategory` (iOS) + `CATEGORIES` (backend) with parity test; the `DeepLink` enum + `userInfo` codec. (FR-1, AC-1)
2. **(M)** **Pure gate** `shared/notify_gate.py` (disabled/quiet/cap/dedupe, tz, wrap-midnight) + exhaustive `test_notify_gate.py`. (FR-10, AC-2…AC-5)
3. **(M)** Backend **device registry**: `handlers/devices.py` (`POST`/`DELETE`), `USER#<sub>/DEVICE#<token>` (+ `DEVICE#ACTIVE` GSI listing) + `test_devices.py`. (FR-6, AC-6)
4. **(M)** Backend **preferences**: `handlers/notification_preferences.py` (`GET`/`PUT`, default-seeding, int-safe) + `test_notification_preferences.py`. (FR-7, AC-7)
5. **(M)** **Delivery worker** `handlers/notify.py` + `shared/sns_push.py` (ensure-endpoint, publish envelope, prune) + `shared/notifications.py` (`enqueue`, copy/payload builders) + `test_notify.py` (mocked SNS). (FR-10/11, AC-8/AC-9)
6. **(M)** **Cron** `handlers/notify_cron.py` (candidate listing → enqueue daily/streak/activity) + EventBridge rule. (FR-11)
7. **(M)** **CDK**: SNS APNs platform app (token-based, Secrets-Manager-sourced), four Lambdas + routes, **least-privilege IAM** (notify-only SNS + secret; producers get `InvokeFunction`; `grade_fn` stays table-less), `delete_account` SNS-endpoint cleanup; `cdk synth ×stages`. (FR-12, AC-10, AC-15)
8. **(S)** **OpenAPI** additions (4 paths + schemas) + matching `DTOs.swift` + `test_contract.py`/`DTOsTests`. (AC-16)
9. **(L)** **iOS `NotificationService`** extension: provisional/explicit auth, `registerCategories` + actions, remote-push registration, `registerDeviceToken`/`unregisterDeviceToken`, local scheduling (preserve daily reminder + add streak-at-risk), delegate (`willPresent`/`didReceive`). (FR-2…FR-5, FR-9)
10. **(M)** **App delegate + coordinator**: `@UIApplicationDelegateAdaptor` for token callbacks; `NotificationCoordinator` (deep-link resolution → `Route`/tab) wired into `AppModel`/`RootView`; cold-launch handling. (FR-8, AC-11)
11. **(M)** **iOS preferences**: `NotificationPreferencesService` + `NotificationSettingsView` (master + per-category toggles + quiet-hours picker + cap stepper; tokens-only; OS-denied affordance) + `AppSettings` snapshot/flags. (FR-7)
12. **(S)** Wire **producers** to `enqueue` (roadmap worker; and behind-flag seams for `0023`/`0024`/`0021`/gamification). (FR-11)
13. **(M)** **iOS tests**: category/deep-link mapping, registration/auth/offline, prefs DTO; extend `DTOsTests`. (AC-11/AC-12/AC-13/AC-14)
14. **(S)** **Flags + rollout**: `pushEnabled` master + per-source flags + `notificationsHardDisabled` kill-switch; runbook for the APNs key/capability. (§9)
15. **(S)** **Manual beta verification** (provisional enrollment, roadmap-ready push + tap, quiet hours/cap, sign-out/delete, offline) + health events. (§8 manual, AC-17)

_Rough total: ~1 L + 8 M + 6 S._

## 12. References
**Codebase (read for accuracy):**
- iOS: `ios/Mango/Services/Notifications/NotificationService.swift` (current 4-method API), `ios/Mango/App/AppModel.swift` (service container; `apiClient()`), `ios/Mango/App/RootView.swift` (launch task; no app delegate today), `ios/Mango/App/MangoApp.swift` (pure SwiftUI `App` — needs `@UIApplicationDelegateAdaptor`), `ios/Mango/App/Route.swift` (`Route` carries `@Model`s → needs id-based `DeepLink`), `ios/Mango/Resources/AppConfig.plist` (`mango://` scheme; endpoints), `ios/Mango/Services/Persistence/AppSettings.swift` (`reminderEnabled`, `deviceUserId`, `Keys` pattern).
- Backend: `backend/mango_backend/api_stack.py` (`make_fn`/`route`/`HttpUserPoolAuthorizer`, least-privilege), `backend/mango_backend/data_stack.py` (single table + `GSI1`), `backend/mango_backend/analytics_stack.py` (events lake for health events), `backend/src/shared/response.py` (`user_id`, helpers), `backend/src/shared/firehose.py` (`put_event` best-effort), `backend/src/handlers/events.py` (thin-handler template), `backend/src/handlers/delete_account.py` (the `DELETE /v1/me` cascade we extend).
- Contract: `shared/api/openapi.yaml` (3.0.3; global `bearerAuth`; **roadmap generate is async 202 + `RoadmapJob`** — the `roadmap_ready` trigger).
- Specs/docs: `docs/specs/SPEC_TEMPLATE.md` (this format), `docs/GAMIFICATION.md` §2g (cap), §5 (notification health metrics), §6 (ethics); cross-refs `working/0010-onboarding-redesign.md` (priming page 4), `working/0015-analytics-events-ios.md` (events→triggers), `working/0023-payments-and-credits.md` (`credits_earned`), `working/0024-rewards-and-coupons.md` (`reward_available`), `working/0021-social-leagues.md` (`league_update`).

**External research (cited):**
1. **APNs token-based auth (`.p8`, Key ID, Team ID, ES256 JWT over HTTP/2; refresh ≤1h or 403 ExpiredProviderToken).** The provider token is a JWT with header `alg=ES256`,`kid=<10-digit Key ID>` and claim `iss=<10-digit Team ID>`,`iat`; must be re-signed at least hourly. Token auth is stateless/faster than certs and avoids yearly renewal. — [Apple: Establishing a token-based connection to APNs](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns), [GOBIKO: Token-based HTTP/2 APNs](https://gobiko.com/blog/token-based-authentication-http2-example-apns/)
2. **UNUserNotificationCenter — provisional authorization + interruption levels.** Provisional auth (iOS 12+) enrolls quietly with **no prompt**; notifications land in Notification Center with keep/turn-off. `.timeSensitive` breaks through Focus/notification controls but Apple/community guidance is to **use it sparingly or users disable notifications**; `.critical` needs a special entitlement. — [Apple: UNNotificationInterruptionLevel](https://developer.apple.com/documentation/usernotifications/unnotificationinterruptionlevel), [Use Your Loaf: Provisional Authorization](https://useyourloaf.com/blog/provisional-authorization-of-user-notificatons/), [nil coalescing: Trial notifications with provisional auth](https://nilcoalescing.com/blog/TrialNotificationsWithProvisionalAuthorizationOnIOS/)
3. **AWS transport — SNS vs Pinpoint vs direct APNs.** **Amazon Pinpoint is being sunset** (no new customers from **May 20 2025**, **end of support Oct 30 2026**) → **SNS mobile push** is the path for new transactional push. SNS supports **token-based APNs (`.p8`)**: create an APNs **platform application** (`PlatformCredential=<.p8>`, `PlatformPrincipal=<signingKeyId>`, Team ID + Bundle ID), register tokens as **platform endpoints** (`CreatePlatformEndpoint`), and `Publish` to the endpoint ARN; SNS handles APNs HTTP/2 + feedback. — [AWS: SNS Apple authentication methods (token-based `.p8`)](https://docs.aws.amazon.com/sns/latest/dg/sns-apple-authentication-methods.html), [AWS Compute Blog: Token-based authentication for iOS with Amazon SNS](https://aws.amazon.com/blogs/compute/token-based-authentication-for-ios-applications-with-amazon-sns/), [AWS: Amazon Pinpoint end of support](https://docs.aws.amazon.com/pinpoint/latest/userguide/migrate.html)
4. **Notification UX — priming, frequency capping, quiet hours, no dark patterns.** Don't prompt cold: show a value-first **pre-permission primer** before the OS prompt (lifts opt-in materially). **Frequency-cap** (commonly 3–5/week as an industry default — Mango caps tighter at ~1/day per its ethics) and **cap cross-channel** to avoid fatigue. **Quiet hours** silence non-working/sleep windows. Avoid **dark patterns**: research shows users dislike **losing control** of notifications, not notifications themselves; guilt/urgency copy and a single "Allow?" toggle are anti-patterns (and increasingly an FTC/CPPA enforcement focus). — [Appcues: Mobile permission priming](https://www.appcues.com/blog/mobile-permission-priming), [Braze: Frequency capping](https://www.braze.com/resources/articles/whats-frequency-capping), [Designlab: Are notifications a dark pattern?](https://designlab.com/blog/are-notifications-a-dark-pattern-ux-ui)
5. **Deep linking from a notification tap in SwiftUI.** Set a `UNUserNotificationCenterDelegate`; in `didReceive(response)` read `response.notification.request.content.userInfo`, decode the deep-link payload, and drive navigation through observable app state (works for foreground, background, and cold-launch taps). — [Swift with Majid: Deep linking for local notifications in SwiftUI](https://swiftwithmajid.com/2024/04/09/deep-linking-for-local-notifications-in-swiftui/), [iOS Coffee Break: Handling deep links from push notifications in SwiftUI](https://www.ioscoffeebreak.com/issue/issue45)
