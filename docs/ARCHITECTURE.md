# Architecture

Mango is a **monorepo** with two independently deployed halves that share a single
contract. The `ios/` folder is a native SwiftUI + SwiftData app (iOS 17+, built
with Xcode 16 file-system-synchronized groups, zero third-party dependencies). The
`backend/` folder is an AWS CDK (Python) project — API Gateway, Lambda, DynamoDB,
S3, Cognito, and Secrets Manager. The two are stitched together by
`shared/api/openapi.yaml`, the source of truth for every request and response
shape they exchange. The app is fully usable offline; the backend is an optional
accelerant that holds the Anthropic key and centralizes generation/grading.

## iOS layered architecture

The app is organized into four layers, each a top-level group under `ios/Mango/`:

- **DesignSystem** — the Claude-inspired visual language: `Theme.swift` (the
  `Palette`/`Metrics` tokens and the light/dark `Color` helper), `Typography.swift`,
  `Components.swift` (Card, Tag, ProgressRing, XPBar, StreakPill, BookCover,
  button styles), and `Haptics.swift`. Pure presentation, no business logic.
- **Models** — SwiftData `@Model` types and the enums/catalogs that describe them.
  The model graph is `UserProfile`, `Book → Roadmap → Milestone → Lesson →
  Exercise`, plus `Achievement` and `ActivityDay`. `MangoSchema` lists every model
  for the `ModelContainer`.
- **Services** — the engine room: AI (`AIService` and its implementations),
  Networking (`APIClient`, DTOs), Content connectors, Persistence (container,
  `AppSettings`, Keychain, seed data), Gamification (`GamificationEngine`,
  `StreakCalculator`, `LevelCurve`), and Notifications.
- **Features** — the SwiftUI screens: Onboarding, Today, Library, AddBook,
  BookDetail, Reader, Journey, Lesson (+ ExerciseRunner), Profile, and Settings.

Cross-cutting services live in an `@Observable` **AppModel** container that
`MangoApp` creates once and injects via the SwiftUI `environment`. It exposes
`settings`, `ai`, `connectors`, and `notifications`; calling `reloadAIService()`
re-resolves the AI backend after the user changes settings. SwiftData itself is
injected separately through `.modelContainer(...)`, and views reach it with
`@Query` and `@Environment(\.modelContext)`. Navigation is type-safe: a `Route`
enum (`bookDetail`, `reader`, `journey`, `lesson`) is registered on every tab's
`NavigationStack` via the `.mangoDestinations()` modifier.

## Data model and relationships

`Book` owns an optional `Roadmap` (cascade delete). A `Roadmap` owns ordered
`Milestone`s, each owning ordered `Lesson`s, each owning ordered `Exercise`s — all
cascade-deleted, with an `order` field used for sorting since SwiftData arrays are
unordered. An `Exercise` carries both its definition (kind, prompt, options,
`xp`) and the user's response state (`userAnswer`, `chosenIndex`, `completedAt`,
`score`, `feedback`), so progress is intrinsic to the graph. `UserProfile` is the
single "player" record holding profile fields plus all gamification counters
(`totalXP`, streaks, freezes). `ActivityDay` stores one row per active calendar
day to drive the streak strip and daily-goal ring. `Achievement` rows are seeded
locked and flipped to unlocked by the engine.

## AI abstraction: offline vs online

Everything model-facing goes through the `AIService` protocol (`generateRoadmap`,
`grade`), with two implementations: **RemoteAIService** (the AWS/Bedrock backend, via
`APIClient` — the only real generator) and **MockAIService** (on-device content, no
network). `AIServiceProvider.make` selects by environment: a configured real backend
→ RemoteAIService, otherwise → MockAIService, so the app still works offline today.

> The on-device **DirectClaudeAIService** (Anthropic Messages API with a Keychain key)
> was removed: the backend holds the only key and is the single source of generation.
> Under the in-progress 0008 Bedrock-only program, `MockAIService` will also be retired
> once Cognito sign-in lands — at which point generation requires sign-in + network.

## Connectors layer

`ConnectorService` is a set of importers that normalize any source — a web URL,
a Project Gutenberg id, pasted text, or a PDF (parsed with PDFKit) — into the same
`ParsedBook` shape. Parsing runs on-device, and the shapes map 1:1 to the
backend's `/v1/content/parse` endpoint for a future server-side path.

## How iOS talks to the backend

`APIClient` is a thin async JSON client that POSTs to the API Gateway HTTP API,
sending a `Bearer` token (when present) and an `x-mango-user` dev header. Its DTOs
mirror `openapi.yaml` exactly. The Anthropic key never ships in the app on the
production path — only the backend holds it (in Secrets Manager).

## Request flow: add a book → roadmap → lesson → XP

```
 ┌─────────┐  import   ┌──────────────┐  ParsedBook  ┌──────────┐
 │ AddBook │──────────▶│ ConnectorSvc │─────────────▶│  Book    │ (SwiftData)
 └─────────┘  (URL/PDF)└──────────────┘              └────┬─────┘
                                                          │ generateRoadmap()
                                              ┌───────────▼────────────┐
                                              │ AIService (mock/remote/ │
                                              │ direct) → RoadmapDTO    │
                                              └───────────┬────────────┘
                                            RoadmapBuilder │ builds graph
                                              ┌───────────▼────────────┐
                                              │ Roadmap→Milestone→      │
                                              │ Lesson→Exercise         │
                                              └───────────┬────────────┘
   Journey path ─tap lesson▶ LessonView ─grade answer▶ AIService.grade()
                                              ┌───────────▼────────────┐
                                              │ GamificationEngine:     │
                                              │ +XP, streak, level,     │
                                              │ achievements, ActivityDay│
                                              └─────────────────────────┘
```

A user imports a source in **AddBook**; `ConnectorService` returns a `ParsedBook`
that becomes a `Book`. On **BookDetail**, the active `AIService` produces a
`RoadmapDTO`, and `RoadmapBuilder` materializes the milestone/lesson/exercise
graph. The **Journey** view renders that graph as a gamified path; tapping a node
opens **LessonView**, which walks the reading summary, then each exercise. When an
answer is graded, `GamificationEngine.recordExercise` awards XP, advances the
day-granular streak (consuming a freeze on a one-day gap), evaluates achievement
unlocks, and bumps the day's `ActivityDay` — the loop that turns reading into a
durable habit.
