# CLAUDE.md

Guidance for AI agents (Claude Code / Cowork) and developers working in this repo.
Read this before making changes.

## What Mango is

A native iOS app that turns reading self-help books into a motivating, game-like
learning journey. Mango is **not a reader** — users read the real book on their own;
inside Mango they do the active-learning loop (a curated reading slice, then quizzes,
reflections, and real-world application tasks) wrapped in XP, levels, streaks, a daily
goal, and achievements. It's a **monorepo** — a SwiftUI app and a separately deployed
AWS backend.

## Workflow — plan every slice before implementing (REQUIRED)

For any non-trivial slice of work (a feature, a contract change, a refactor — anything
beyond a one-line fix), **brainstorm and plan in plan mode first, and close every gap in
the plan before writing code.** Concretely:

1. **Brainstorm + investigate first.** Read the real code/contracts involved; don't assume.
   Surface constraints and edge cases (offline-first, the three AI services, the
   `openapi.yaml ⇄ DTOs.swift ⇄ backend` contract chain, SwiftData migration, no fabricated
   data) *before* proposing a design.
2. **Use plan mode** (`EnterPlanMode`) to think, and **`AskUserQuestion`** to resolve every
   genuine fork with the operator. Do not pick a default on a decision that changes the
   model, the contract, or the UX — ask.
3. **Write the plan down** (a `working/<spec>/…PLAN.md`, an ADR for decisions, and update
   `CONTEXT.md`/memory) and get explicit sign-off **before** implementation.
4. **No open gaps at code time.** If a question surfaces mid-implementation, stop and resolve
   it in the plan first — don't paper over it.

This is the standard regardless of how the work is kicked off (direct request, `/drive`,
`/ralph`, etc.). Spec-first keeps the repo coherent and the contract in sync.

## Repo layout

```
ios/                     SwiftUI + SwiftData app (iOS 17+). Open ios/Mango.xcodeproj.
  Mango/
    App/                 entry, RootView, MainTabView, Route (navigation), AppModel
    DesignSystem/        Palette, Typo, Metrics, Components, Color+Hex, Haptics
    Models/              SwiftData @Model types + enums + AchievementCatalog
    Services/            AI/, Content/ (connectors), Gamification/, Networking/,
                         Persistence/, Notifications/
    Features/            Onboarding, Home, Library, Reader, Journey, Lesson, Profile, Settings
    Resources/           Assets.xcassets (AppIcon, AccentColor)
  MangoTests/            XCTest unit tests
backend/                 AWS CDK (Python): API Gateway HTTP API + Lambda + DynamoDB + S3 + Cognito
  mango_backend/         CDK stacks: data_stack, auth_stack, ai_stack, api_stack, stage
  src/handlers/          Lambda handlers (health, content_parse, generate_roadmap, grade_exercise, progress)
  src/shared/            shared modules (response, claude, http, text, storage, prompts, …)
  tests/                 pytest suite
shared/api/openapi.yaml  the iOS ⇄ backend contract (keep in sync with both sides)
docs/                    ARCHITECTURE, BACKEND, DESIGN_SYSTEM, GAMIFICATION, PRODUCT_ROADMAP
.github/workflows/       ios-ci, backend-ci, backend-deploy (Beta on main / Prod on release)
```

## Common commands

Use the root `Makefile` (run `make help`). Key targets:

| Task | Command |
|---|---|
| Open iOS app | `make ios-open` (or `open ios/Mango.xcodeproj`) |
| iOS unit tests | `make ios-test` (or ⌘U in Xcode) |
| Regenerate Xcode project | `cd ios && xcodegen generate` (only if the .xcodeproj breaks) |
| Backend install | `make backend-install` |
| Backend tests | `make backend-test` (`cd backend && pytest`) |
| Backend lint/format | `make backend-lint` (black --check + flake8) |
| Backend synth | `make backend-synth` |
| Backend deploy | `make backend-deploy-beta` / `make backend-deploy-prod` |

## Architecture & conventions

**iOS** is layered: DesignSystem → Models → Services → Features. A single
`@Observable AppModel` (services container) is injected via the SwiftUI environment.
Navigation is centralized in the `Route` enum applied with `.mangoDestinations()` on
each tab's `NavigationStack`. Persistence is SwiftData (`@Model` + `@Query`); there is
exactly one `UserProfile`. AI generation goes through the `AIService` protocol with
three interchangeable implementations — `RemoteAIService` (backend), `DirectClaudeAIService`
(Anthropic on-device), `MockAIService` (offline) — chosen by `AIServiceProvider` from
`AppSettings.aiMode`. Content import is the `ConnectorService` (web URL / Gutenberg /
pasted text / PDF). Gamification lives in `GamificationEngine` with pure, unit-tested
`StreakCalculator` and `LevelCurve`.

**Backend** is four CDK stacks (Data, Auth, Ai, Api) composed into a `MangoStage` per
environment. Lambda handlers are thin; logic lives in `src/shared/`. DynamoDB is a
single table (`PK`/`SK`, e.g. `BOOK#<id>/META`, `USER#<id>/PROGRESS`) plus `GSI1`.

## Invariants — do not break these

- **Backend AI calls go through Amazon Bedrock** (IAM auth, no API key). The Secrets
  Manager Anthropic key is optional/only for the on-device Direct-Claude testing path
  (`DirectClaudeAIService`, key in Keychain) — never ship a key in the app.
- **The app must run fully offline** on first launch: `MockAIService` + the bundled
  public-domain sample book. Don't make onboarding or the first lesson depend on a
  network call or a key.
- **No third-party iOS dependencies.** Keep the app SPM/CocoaPods-free so it builds by
  just opening the project.
- **Xcode 16 file-system-synchronized groups:** new Swift files placed under
  `ios/Mango/` are picked up automatically. Do **not** hand-edit `project.pbxproj` to
  register files.
- **Keep the contract in sync:** `shared/api/openapi.yaml` ⇄ `ios/.../Services/Networking/DTOs.swift`
  ⇄ `backend/src/handlers`. The roadmap endpoint accepts an inline `book` or a `bookId`.
- **Backend Lambdas use stdlib + boto3 only** (no packaging step). The DynamoDB resource
  API rejects Python `float` — coerce to `int` or store JSON strings (see `progress.py`,
  `generate_roadmap.py`).
- **Backend style:** black (line-length 100) + flake8 (max 120). Run before committing.

## Testing / verification

- **Backend:** `cd backend && pytest` (29 tests) **and** `cdk synth -c stage=beta` must
  both pass. These run offline (moto mocks AWS; Claude calls are monkeypatched).
- **iOS:** `make ios-test` / ⌘U. Pure logic (LevelCurve, StreakCalculator, TextStats,
  HTMLText, DTO decoding, GamificationEngine) is covered; prefer adding tests there.
- Run the relevant suite before committing non-trivial changes.

## Security notes

- `src/shared/http.py` has an SSRF guard (blocks private/loopback/link-local IPs and
  re-validates redirects) because `content_parse` fetches arbitrary user URLs — keep it.
- `response.user_id` only trusts the `x-mango-user` header outside `prod`/`beta`; deployed
  stages require Cognito JWT claims.
- IAM grants in `api_stack.py` are least-privilege (e.g. the grade Lambda has no table access).

## Status / not-yet-built

- The app has **no Cognito sign-in yet**, so "Mango Backend" AI mode can't authenticate
  against the deployed (authorizer-protected) API. Use Direct-Claude or Mock until sign-in
  is wired — it's the top item in `docs/PRODUCT_ROADMAP.md`.
- Planned: progress sync, social leagues, spaced-repetition "insight review", EPUB import,
  moving PDF parsing off the main thread.

## Style

- Swift: idiomatic SwiftUI; pull colors/spacing/type from `DesignSystem/` tokens
  (`Palette`, `Typo`, `Metrics`) — don't hardcode hex or magic numbers.
- Python: black + flake8, type hints where they help, keep handlers thin.
- Commits: concise, imperative mood.
