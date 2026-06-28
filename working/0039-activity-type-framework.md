# 0039 — Activity type framework & taxonomy

- **Epic:** M15 · **Status:** Draft · **Owner:** unassigned · **Updated:** 2026-06-28
- **Reviewers:** Principal/SD/QA

## 1. Summary
Mango delivers **engaging activities** for a book and tracks the journey — it is not a reader.
Today the only "activity" is an `Exercise` whose `kind` is one of `{quiz, reflection, application}`,
graded by `grade_exercise.py` (deterministic for quiz, Bedrock-graded free text for the rest). That
hard-codes a single shape, a single response modality (choice or text), and a single grading path —
which blocks every richer activity the product wants (multimodal, conversational, external
engagement, peer/human). This spec defines the **foundational, extensible Activity Type Framework**
the whole agentic activity cluster builds on: a formal **taxonomy** of 11 activity kinds (8
**internal** — `mcq`, `quiz`, `puzzle`, `long_answer`, `voice`, `conversation`, `video`, `image`; 3
**external** — `social_engage`, `content_consume`, `peer_session`), one **unified polymorphic
Activity schema** (JSON ⇄ Swift `@Model`/Codable ⇄ OpenAPI) that supersedes `Exercise`, a pure
**activity lifecycle state machine** (`assigned → in_progress → submitted → grading/verifying →
graded(passed/failed) → rewarded`), and a single **grading/verification contract**
(`grade(activity, submission) → {score, xpAwarded, feedback, passed}`) with five pluggable methods
(`deterministic | model_graded | multimodal_graded | external_verify | human | self_report+spotcheck`).
The engine spec (`0038-agentic-roadmap-engine`) composes tracks out of these kinds; each **component
spec** (`0040-multimodal-activities`, `0041-conversational-tutor-activities`,
`0042-external-engagement-activities`, `0043-peer-and-human-activities`) implements one or more
kinds against this contract. This spec defines the **framework, schema, lifecycle, and contract** —
it does **not** build any individual renderer or grader beyond the deterministic/model-graded paths
already in the codebase, which it generalizes. We keep the offline-first, zero-dependency, float-free
invariants intact: `mcq`/`quiz`/`puzzle` and the bundled sample run fully offline via `MockAIService`.

## 2. Goals / Non-goals
- **Goals:**
  - **Formalize the taxonomy.** Define all 11 kinds (8 internal + 3 external) with: purpose, the
    prompt/content shape, the **response modality** (`text | choice | audio | video | image |
    external_proof | none`), the **grading/verification method**, XP/difficulty guidance, and the
    **sibling spec** that implements it (§6.4).
  - **One unified, polymorphic `Activity` schema** with fields `id`, `kind`, `title`,
    `prompt/content`, `modality`, `gradingMethod`, `rubric?`, `options?`, `answerKey?`, `xp`,
    `difficulty`, `objectiveRef`, `verification` config, `estimatedMinutes` — expressed as JSON, a
    Swift `@Model` + `Codable`, and an OpenAPI schema, and shown to **supersede today's `Exercise`**
    (with a clean migration path, §6.5 / §9).
  - **A pure, unit-testable lifecycle state machine** (`ActivityLifecycle`) over an explicit event
    set, with **retries** and **partial credit**, no SwiftData/SwiftUI dependency (in the spirit of
    `LevelCurve` / `StreakCalculator` / `0011`'s `ActivityDeck`).
  - **A single grading/verification contract** — `grade(activity, submission) → GradeOutcome` — with a
    deterministic path (`mcq`/`quiz`/`puzzle`, reusing `grade_exercise.py`'s quiz branch), a
    **model-graded rubric** path (`long_answer` and today's reflection/application, reusing/extending
    `agent.grade` + `prompts.grade_*`), and **typed handoffs** to multimodal (`0040`), external
    (`0042`), and human (`0043`). Idempotency + anti-cheat hooks defined.
  - **The data & contract seams:** DynamoDB **activity-assignment** and **submission** item shapes
    (coordinated with tracking `0026`), **S3** submission-artifact layout (coordinated with `0027`),
    and the endpoints (`GET /v1/activities/{id}`, `POST /v1/activities/{id}/submit`) with OpenAPI
    notes — float-free, stdlib+boto3.
  - **An iOS `ActivityRenderer` protocol** so the `0011` swipe deck renders **any** kind via a
    registry, and a `GradingMethod`/modality routing layer the three AI services share.
  - **Honor the invariants:** offline-first (deterministic kinds + sample), no third-party iOS deps,
    Xcode-16 sync groups, Lambda stdlib+boto3, no DDB floats, openapi ⇄ DTO ⇄ handler in lockstep.
- **Non-goals:**
  - **Building the individual renderers/graders** for `voice`, `conversation`, `video`, `image`,
    `social_engage`, `content_consume`, `peer_session` — those are `0040`–`0043`. Here we define the
    schema each must fill and the contract each must satisfy, plus reference stubs.
  - **The roadmap-composition / track-selection logic** — that is `0038`. We expose the Activity as
    the composable unit and the `objectiveRef` it pins to, nothing more.
  - **Credits / rewards economy** (`0023` payments & credits, `0024` rewards). We emit the
    `rewarded` lifecycle terminal and the `xpAwarded` outcome; how XP/credits convert to money or
    coupons is theirs. We only specify the **XP guidance per kind**, not the credit ledger.
  - **Recommendation** of which activity to serve next (`0044`); we provide `difficulty` + `kind` +
    `objectiveRef` as inputs.
  - **Changing gamification math** (`LevelCurve`, `StreakCalculator`, XP amounts for the three
    existing kinds). New kinds get XP guidance; the engine math is untouched.
  - **Progress sync wiring** (`0014`) and **server-side tracking implementation** (`0026`) — we shape
    the items so they ride those, and note the contract delta, but do not build the sync.

## 3. Background & context
**Current state (single hard-coded activity shape).** The entire "active learning loop" is one
SwiftData `@Model Exercise` (`ios/Mango/Models/RoadmapModels.swift:94–139`) with:
`kindRaw: String`, `prompt`, `options: [String]`, `answerIndex: Int?`, `xp`, `order`, plus response
state (`userAnswer`, `chosenIndex`, `completedAt`, `score`, `feedback`). `ExerciseKind`
(`Models/Enums.swift:46–81`) is a closed enum `{quiz, reflection, application}` with per-kind
`title`/`symbol`/`tint`/`baseXP` (15/25/40). The graph is `Roadmap → Milestone → Lesson → Exercise`.

**Grading today** (`backend/src/handlers/grade_exercise.py`): a `kind` switch.
- **`quiz`** → **deterministic**, no model call: `correct = chosenIndex == answerIndex`; XP = 15 if
  correct else 0.
- **`reflection`/`application`** → **model-graded** via `agent.grade(kind, prompt, answer)`
  (`shared/agent.py:109`), prompted by `prompts.grade_system()` / `grade_user()`
  (`shared/prompts.py:41–48,64–74`): the model returns `{score: 0..1, feedback}`; the handler clamps
  `score`, then `xp = round(base * (0.5 + 0.5*score))` with `base ∈ {25, 40}`. The on-device path
  mirrors this in `ExerciseRunnerView.submit()` (`Features/Lesson/ExerciseRunnerView.swift:119–142`):
  quiz graded locally, free-text via `app.ai.grade(...)`.

**The contract** (`shared/api/openapi.yaml`): `Exercise` (`:378–388`), `GradeRequest` (`:389–397`),
`GradeResult` (`:398–404` — `{correct?, score, feedback, xpAwarded}`); roadmap generation is async
(POST `/v1/roadmaps/generate` → 202 `{jobId}`, poll `GET /v1/roadmaps/jobs/{jobId}`, `:49–82`).
DTOs mirror these (`Services/Networking/DTOs.swift:54–67,90–94`).

**Why now.** Mango's whole product thesis (`0008`) is *engaging activities*, and `0011` already turns
the lesson into a **swipeable card deck** of activity steps. But every richer activity the roadmap
wants — a spoken summary, a back-and-forth with a tutor, a photo of a habit you built, a "post this
idea / go read the cited paper / call a friend and discuss" task — **cannot be expressed** by an
`Exercise` whose only modalities are choice/text and whose only graders are quiz-equality and a
single free-text rubric prompt. The agentic engine (`0038`) needs a **uniform composable unit** with a
**uniform grading contract** so it can mix kinds into a track without special-casing each. Defining
that unit/contract **once, here** is the precondition for `0040`–`0044`; otherwise each of those
specs reinvents the schema and the grading seam and they drift. This is the classic *plugin /
extensible-schema* problem: a stable host (schema + lifecycle + grading contract + a renderer
registry) with pluggable types, so new activity kinds are additive — "extending base node types …
virtually the only components needed to add custom activities"
([Polyglot/.NET adaptive learning paths, arXiv 2310.07314](https://arxiv.org/pdf/2310.07314);
[plugin/pathway architecture, USPTO 12277869](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/12277869)).

**Pedagogy grounds the taxonomy.** Bloom's revised taxonomy (Remember → Understand → Apply → Analyze
→ Evaluate → Create) maps cleanly onto our kinds and onto `difficulty`: `mcq`/`quiz` exercise
*remember/understand*; `puzzle`/`long_answer` push *apply/analyze*; `voice`/`conversation` reach
*evaluate/explain*; `image`/`video`/external kinds are *apply/create* in the real world — the durable,
"authentic assessment" end of the scale
([Bloom's taxonomy activities & assessments, U. Waterloo](https://uwaterloo.ca/centre-for-teaching-excellence/resources/teaching-tips/blooms-taxonomy-learning-activities-and-assessments)).
This is the same bet `0008` already cites (active "doing" beats passive recall) — the taxonomy just
gives the engine a principled spread of *kinds* to compose across that scale.

**Grading reality grounds the contract.** LLM-as-grader is viable but must be designed carefully:
reliable rubric scoring needs **fixed criteria, traceable evidence, and calibrated interpretation**,
and three failure modes (rubric-execution drift, unverifiable attribution, human-scale misalignment)
recur when those are missing
([From Rubrics to Reliable Scores, arXiv 2601.08654](https://arxiv.org/abs/2601.08654)). Two design
findings drive our rubric format: **include a negative/penalty criterion** (without it, models
"make sense" of weak answers and over-award), and **embed concrete examples** in criteria (improves
alignment a few points) — but **never let the model auto-expand the rubric** (catastrophic −15–20%
alignment)
([Autorubric, arXiv 2603.00077](https://arxiv.org/abs/2603.00077)). For `mcq` auto-generation, the
hard part is **distractors**: generic LLMs produce *superficial* distractors that don't mirror real
misconceptions, so we keep generation behind quality filters and an `answerKey` the deterministic
grader trusts
([D-GEN distractor generation/eval, arXiv 2504.13439](https://arxiv.org/pdf/2504.13439);
[automated distractor generation for MCQs, arXiv 2404.02124](https://arxiv.org/html/2404.02124)). For
the multimodal/external/human kinds, the literature is unanimous that **human-in-the-loop / oversight
is required** and that **self-rating + spot-checks** with confidence sampling are the practical mode
— which is exactly the `human` and `self_report+spotcheck` methods we define
([LLM-as-a-Grader practical insights, arXiv 2511.10819](https://arxiv.org/html/2511.10819v1);
multimodal grading of visual work, [arXiv 2601.00730](https://arxiv.org/pdf/2601.00730)).

**Related specs.** Consumes/depends-on: `0008` (activity-first reframe — the model this extends),
`0011` (swipe deck + the `ActivityDeck`/`ActivityStep` pattern this generalizes). Builds-on this:
`0038` (engine composes tracks of activities), `0040`/`0041`/`0042`/`0043` (each implements kinds),
`0044` (recommends kinds). Coordinates with: `0026` (server tracking — assignment/submission items),
`0027` (artifact store — S3 submission artifacts + grading observability), `0023` (credits — consumes
`rewarded`/`xpAwarded`), `0014` (sync — rides the per-user activity-state items).

## 4. User stories
- As the **roadmap engine** (`0038`), I want every step of a track to be a single `Activity` value
  with a uniform `kind`/`modality`/`gradingMethod`/`objectiveRef`, so I can compose a mixed track
  (an `mcq`, then a `long_answer`, then a `voice` recap, then a real-world `image` task) without
  special-casing each type.
- As a **component-spec implementer** (`0040`–`0043`), I want a documented schema slot and a single
  `grade(activity, submission)` contract to implement my kind against, so adding `voice` or
  `peer_session` is *additive* (a renderer + a grader registration) and never edits the core.
- As a **learner**, I do a varied, motivating mix — a quick check, a written reflection, a 30-second
  spoken explanation, a "go apply this and photograph it" task — and each gives me fair XP and warm,
  specific feedback, all inside the same swipe deck.
- As an **offline first-run user**, the bundled sample's `mcq`/`quiz`/`puzzle` activities and their
  grading work with **no network and no key** (the offline-first invariant), while richer kinds
  degrade gracefully (queued for later verification, or marked "needs connection").
- As a **backend engineer**, I want activity **assignments** and **submissions** to be plain
  single-table DDB items (float-free) and submission media to land in S3 under a predictable prefix,
  so tracking (`0026`), artifacts (`0027`), and sync (`0014`) layer on without a schema fight.
- As a **reviewer**, I want the lifecycle and the grading determinism to be **pure and unit-tested**
  (like `LevelCurve`), so "submitted twice → awarded once" and "quiz X always grades to Y" are
  provable, not hoped-for.

## 5. Requirements
### Functional
- **FR-1 (taxonomy).** The system defines exactly **11 activity kinds** in one enum: **internal** =
  `mcq`, `quiz`, `puzzle`, `long_answer`, `voice`, `conversation`, `video`, `image`; **external** =
  `social_engage`, `content_consume`, `peer_session`. Each kind has a fixed **response modality**,
  default **grading method**, **XP band**, **difficulty** default, and an **implementing spec**
  (§6.4 table). `mcq` and `quiz` are distinct: `mcq` = single-best-answer with generated distractors
  (Bloom remember/understand, ≥3 options + `answerKey`); `quiz` = the existing lightweight
  true/false-or-short recall check (back-compatible with today's `quiz`). The closed
  `ExerciseKind {quiz, reflection, application}` is **subsumed**: `reflection`/`application` map onto
  `long_answer` (with a `subtype` discriminator preserving their distinct prompts/XP — §6.5).
- **FR-2 (unified Activity schema).** One polymorphic model `Activity` carries: `id`, `kind`,
  `title`, **`content`** (the prompt/stimulus; superset of today's `prompt`), `modality`,
  `gradingMethod`, **`rubric?`** (criteria for model/multimodal grading), **`options?`** +
  **`answerKey?`** (for choice/deterministic kinds), `xp` (max award), `difficulty`,
  **`objectiveRef`** (the learning objective / book idea it targets, set by `0038`), **`verification`**
  (a typed config blob for external/human kinds: proof type, who verifies, spot-check rate),
  `estimatedMinutes`, and `order`. It is expressed identically as **JSON**, a Swift `@Model` +
  `Codable`, and an **OpenAPI** schema, and **supersedes `Exercise`** (FR-9 migration). Unknown
  `kind`/`modality`/`gradingMethod` strings decode **leniently** to a safe fallback (never crash),
  exactly like `CatalogBook.init(from:)` and `Exercise.kind`'s `?? .reflection`.
- **FR-3 (lifecycle state machine).** A pure `ActivityLifecycle` defines states
  `assigned → in_progress → submitted → grading → graded(passed|failed) → rewarded`, plus terminal
  `expired`, over events `start`, `submit(Submission)`, `gradeReturned(GradeOutcome)`, `retry`,
  `awardGranted`, `expire`. It supports **retries** (failed → in_progress, bounded by
  `maxAttempts`) and **partial credit** (`graded` carries a `score ∈ 0…1`; `passed` is
  `score ≥ passThreshold`). Illegal transitions are no-ops. No SwiftData/SwiftUI import; unit-tested
  exhaustively.
- **FR-4 (grading/verification contract).** A single entry point
  `grade(activity, submission) → GradeOutcome{score, xpAwarded, feedback, passed}` dispatches on
  `activity.gradingMethod`:
  - **`deterministic`** (`mcq`, `quiz`, `puzzle`): pure, no model — compares `submission` to
    `answerKey`/solution; reuses `grade_exercise.py`'s quiz branch generalized to an `answerKey`.
  - **`model_graded`** (`long_answer`, and today's reflection/application subtypes): rubric-prompted
    Bedrock call; **reuses/extends** `agent.grade` + `prompts.grade_*` to accept an explicit `rubric`
    (with a mandatory **negative criterion** and optional in-criterion **examples**, per research),
    returning `{score, feedback}`; XP via the existing `base*(0.5+0.5*score)` formula generalized to
    the activity's `xp`.
  - **`multimodal_graded`** (`voice`, `image`, `video`): **handoff to `0040`** — same contract, but
    the grader consumes an S3 media artifact + a multimodal Bedrock call (or ASR→text→model). This
    spec defines the **interface + stub**, not the implementation.
  - **`external_verify`** (`social_engage`, `content_consume`): **handoff to `0042`** — verifies a
    proof (URL/screenshot/oauth signal/time-on-task) per `activity.verification`; may fall back to
    `self_report+spotcheck`.
  - **`human`** (`peer_session`): **handoff to `0043`** — a peer/human marks completion/quality;
    `grade` returns a *pending* outcome and the lifecycle parks in `grading` until the human signal
    arrives.
  - **`self_report+spotcheck`** (any honor-system task): immediate provisional pass on self-report,
    with a sampled fraction routed to a deeper check (model/human) per `verification.spotCheckRate`.
- **FR-5 (idempotency + anti-cheat hooks).** `grade` is **idempotent** on `(activityId, submissionId)`
  — re-grading the same submission yields the same outcome and **awards XP at most once** (mirrors
  `LessonView`'s `completedAtOpen` guard and `0011`'s `commitCurrent` idempotence). The contract
  exposes **anti-cheat hooks**: per-attempt **answerKey withholding** (never sent to the client for
  `model_graded`/`deterministic` until after submit), **spot-check sampling** for self-reported kinds,
  a **plausibility/length-floor** check for free text (already present as `canSubmit ≥ 3 chars`), and
  **proof binding** (external proofs are tied to `activityId` + user + timestamp) — implementations
  live in `0042`/`0043`; the seam is defined here.
- **FR-6 (endpoints).** Add `GET /v1/activities/{id}` (fetch one activity's definition — the
  client-safe projection, **without** `answerKey`/`rubric`) and
  `POST /v1/activities/{id}/submit` (submit a `Submission`, returns a `GradeOutcome` or a
  `pending` envelope for async/human grading). Both are additive to `openapi.yaml`; the existing
  `/v1/exercises/grade` is **retained as a thin shim** that constructs an ephemeral `Activity` from
  the old `GradeRequest` and calls the new contract (back-compat for clients mid-migration).
- **FR-7 (iOS `ActivityRenderer` registry).** Define a Swift `ActivityRenderer` protocol
  (`func makeCard(for: Activity, …) -> AnyView`, `var canSubmit`, `func makeSubmission() ->
  Submission`) and a `ActivityRendererRegistry` keyed by `kind`. The `0011` swipe deck resolves the
  renderer for each step's `kind` instead of switching on `ExerciseKind`. This spec ships the
  registry + the **deterministic and `long_answer` renderers** (reskinning today's `ExerciseCard`);
  `0040`–`0043` register theirs. An unregistered kind renders a safe "not available on this device /
  update the app" card (never a crash) — the offline-degradation path.
- **FR-8 (offline-first preserved).** `mcq`/`quiz`/`puzzle` (`deterministic`) and `long_answer` via
  `MockAIService.grade` run with **no network/key**; the bundled sample book's activities are all
  offline-capable kinds. Kinds whose grading needs the network (`multimodal_graded`, `external_verify`,
  `human`) render and **queue** their submission, surfacing a clear "will verify when online" state —
  they never block first-run or appear in the offline sample.
- **FR-9 (supersede `Exercise`, migration).** `Activity` replaces `Exercise` in the model graph
  (`Lesson.exercises: [Exercise]` → `Lesson.activities: [Activity]`), behind a flag, with a one-time
  SwiftData backfill mapping each `Exercise` to an `Activity` (`quiz→quiz`, `reflection→long_answer`
  subtype `reflection`, `application→long_answer` subtype `application`), preserving response state,
  XP, order, and completion. The DTO/OpenAPI `Exercise` is kept as an **alias view** of an `Activity`
  for one release so the generation contract (`0038`/today's roadmap JSON) keeps working unchanged.

### Non-functional
- **NFR-1 (purity/testability).** `ActivityLifecycle` and the `deterministic` grader are **pure**
  (no SwiftData, no SwiftUI, no network), unit-tested exhaustively like `LevelCurveTests` /
  `ActivityDeckTests` (`0011` §8). Round-trip (encode→decode) tests for every kind.
- **NFR-2 (no third-party iOS deps; Xcode-16 sync groups).** Pure SwiftUI/SwiftData/Foundation; new
  files under `ios/Mango/` auto-register — never hand-edit `project.pbxproj` (CLAUDE.md).
- **NFR-3 (backend stdlib+boto3, float-free).** New handlers use only stdlib + boto3; all numeric DDB
  attributes are `int` (XP, attempts, difficulty) or JSON strings (rubric, verification, score) —
  scores stored as **basis points `int` (0–10000)** or JSON, never a Python `float` (the `progress.py`
  / `generate_roadmap.py` rule).
- **NFR-4 (contract lockstep).** `shared/api/openapi.yaml` ⇄ `Services/Networking/DTOs.swift` ⇄
  `backend/src/handlers` stay in sync; `cdk synth -c stage=beta` and `pytest` (moto + monkeypatched
  Bedrock) pass offline.
- **NFR-5 (grading reliability).** Model-graded rubrics MUST include a **negative criterion** and MUST
  NOT auto-expand criteria at runtime (research, §3); model/multimodal grading runs in the async
  worker path (off the 30 s API-GW budget) where it can exceed the request timeout, like roadmap
  generation. Grading calls are logged with model, latency, token usage, and outcome for `0027`.
- **NFR-6 (design tokens / a11y).** All renderers use `Palette`/`Typo`/`Metrics`/`Haptics`; every kind
  has a VoiceOver label, a non-gesture submit path (WCAG 2.5.1, per `0011`), and Reduce-Motion
  fallbacks. Difficulty/kind are conveyed by label+icon, never color alone.
- **NFR-7 (privacy/cost).** Submission media (audio/photo/video) are user content — stored in S3 with
  least-privilege access, referenced by key (never inlined in DDB), with a retention policy
  (coordinated with `0027`); external proofs store the **minimum** (a URL or a hash, not scraped
  third-party content). New model-graded kinds increase Bedrock cost — bounded by `maxAttempts` and
  per-kind token caps.

## 6. Design

### 6.1 The unified `Activity` schema (one polymorphic model)

**Canonical JSON** (what `0038` emits per step, what `GET /v1/activities/{id}` returns minus the
withheld fields). Fields marked *(withheld)* are never sent to the client before submit (FR-5):
```jsonc
{
  "id": "act_3f9c",                  // stable id (server-assigned; client uses for submit)
  "kind": "long_answer",            // one of the 11 kinds (FR-1)
  "subtype": "reflection",          // optional discriminator within a kind (e.g. reflection|application)
  "title": "Reflect: your keystone habit",
  "content": "Describe one keystone habit you could install this week and the cue that triggers it.",
  "modality": "text",               // text|choice|audio|video|image|external_proof|none
  "gradingMethod": "model_graded",  // deterministic|model_graded|multimodal_graded|external_verify|human|self_report+spotcheck
  "difficulty": 2,                  // 1..5 (Bloom-aligned band; default per kind)
  "xp": 25,                         // MAX award; partial credit scales it
  "estimatedMinutes": 5,
  "order": 3,
  "objectiveRef": "obj_habit_loop", // the learning objective/book idea (set by 0038); nullable
  "options": null,                  // [String] for choice kinds (mcq/quiz/puzzle), else null
  "answerKey": null,                // (withheld) correct answer/solution for deterministic kinds
  "rubric": {                       // (withheld) for model_graded/multimodal_graded; null otherwise
    "passThreshold": 0.6,
    "criteria": [
      { "id": "specific", "weight": 0.5, "desc": "Names a concrete habit AND its cue",
        "example": "e.g. 'after I pour my morning coffee, I read one page'" },
      { "id": "depth",    "weight": 0.5, "desc": "Explains why this cue is reliable for them" },
      { "id": "penalty_offtopic", "weight": -1.0, "negative": true,
        "desc": "Penalize answers that are off-topic, empty, or copy the prompt" } // mandatory negative criterion
    ]
  },
  "verification": null,             // typed config for external_verify/human/self_report; null otherwise
  "maxAttempts": 3,
  "passThreshold": 0.6
}
```
An **external** example (`social_engage`, implemented by `0042`):
```jsonc
{
  "id": "act_9a12", "kind": "social_engage", "title": "Share one insight",
  "content": "Post one sentence you learned from this chapter to a friend or feed, then confirm.",
  "modality": "external_proof", "gradingMethod": "self_report+spotcheck",
  "difficulty": 1, "xp": 30, "estimatedMinutes": 5, "order": 6, "objectiveRef": "obj_share",
  "options": null, "answerKey": null, "rubric": null,
  "verification": {
    "proofType": "url_or_screenshot",   // url_or_screenshot|oauth_signal|time_on_task|peer_confirm
    "verifier": "self",                 // self|model|peer|human
    "spotCheckRate": 0.1,               // fraction routed to a model/human deeper check
    "minDurationSec": null
  },
  "maxAttempts": 1, "passThreshold": 1.0
}
```

**Swift `@Model` + `Codable`** (`ios/Mango/Models/Activity.swift`, new; auto-registered by Xcode-16
sync groups). The `@Model` stores enums as raw strings (the `Exercise.kindRaw` idiom) and the
structured blobs (`rubric`, `verification`, `answerKey`, `options`) as **Codable value types**
persisted via a JSON-string accessor so SwiftData stays happy and the wire shape is exact:
```swift
import Foundation
import SwiftData

@Model
final class Activity {
    // Identity & taxonomy
    var id: String                       // server id; "local_<uuid>" for offline-seeded
    var kindRaw: String                  // ActivityKind raw
    var subtypeRaw: String?              // optional within-kind discriminator
    var title: String
    var content: String                  // the prompt/stimulus (supersedes Exercise.prompt)
    var modalityRaw: String              // ResponseModality raw
    var gradingMethodRaw: String         // GradingMethod raw

    // Scoring & placement
    var difficulty: Int                  // 1...5
    var xp: Int                          // max award
    var estimatedMinutes: Int
    var order: Int
    var objectiveRef: String?            // learning-objective id (0038)
    var maxAttempts: Int
    var passThresholdBp: Int             // basis points 0...10000 (float-free)

    // Polymorphic payloads (stored as JSON strings; typed accessors below)
    var optionsJSON: String?             // [String]
    var answerKeyJSON: String?           // AnswerKey (withheld client-side)
    var rubricJSON: String?              // Rubric   (withheld client-side)
    var verificationJSON: String?        // Verification

    // Lifecycle / response state (supersedes Exercise's response fields)
    var lifecycleRaw: String             // ActivityState raw; default "assigned"
    var attempts: Int
    var userAnswer: String?              // free text (long_answer) or chosen-option text
    var chosenIndex: Int?                // choice kinds
    var submissionArtifactKey: String?   // S3 key for audio/image/video/external proof
    var scoreBp: Int?                    // basis points 0...10000 (float-free); nil until graded
    var feedback: String?
    var completedAt: Date?

    var lesson: Lesson?

    // Typed accessors (decode leniently; never crash on unknown — FR-2)
    var kind: ActivityKind { ActivityKind(rawValue: kindRaw) ?? .long_answer }
    var modality: ResponseModality { ResponseModality(rawValue: modalityRaw) ?? .text }
    var gradingMethod: GradingMethod { GradingMethod(rawValue: gradingMethodRaw) ?? .model_graded }
    var lifecycle: ActivityState { ActivityState(rawValue: lifecycleRaw) ?? .assigned }
    var options: [String]? { optionsJSON.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } }
    var rubric: Rubric? { rubricJSON.flatMap { try? JSONDecoder().decode(Rubric.self, from: Data($0.utf8)) } }
    var verification: Verification? { verificationJSON.flatMap { try? JSONDecoder().decode(Verification.self, from: Data($0.utf8)) } }
    var isCompleted: Bool { completedAt != nil }
    var score: Double? { scoreBp.map { Double($0) / 10000.0 } }     // convenience for UI only
    // … designated init mirrors Exercise.init with sensible defaults …
}

// Plain Codable value types for the wire + the JSON-string columns:
struct Rubric: Codable, Equatable { var passThreshold: Double; var criteria: [RubricCriterion] }
struct RubricCriterion: Codable, Equatable {
    var id: String; var weight: Double; var desc: String
    var example: String? = nil; var negative: Bool = false        // mandatory ≥1 negative (NFR-5)
}
struct Verification: Codable, Equatable {
    var proofType: String; var verifier: String
    var spotCheckRate: Double; var minDurationSec: Int?
}
struct AnswerKey: Codable, Equatable {                            // deterministic kinds
    var answerIndex: Int? = nil                                   // mcq/quiz
    var solution: String? = nil                                   // puzzle (normalized compare)
    var acceptable: [String]? = nil                              // puzzle alternates
}
```
Enums (new `Models/ActivityKind.swift`; closed but lenient-decoded, mirroring `ExerciseKind`):
```swift
enum ActivityKind: String, CaseIterable, Codable, Identifiable {
    // internal
    case mcq, quiz, puzzle, long_answer, voice, conversation, video, image
    // external
    case social_engage, content_consume, peer_session
    var id: String { rawValue }
    var isExternal: Bool { [.social_engage, .content_consume, .peer_session].contains(self) }
    // title/symbol/tint/defaultDifficulty/defaultXP/defaultModality/defaultGrading per §6.4 table
}
enum ResponseModality: String, Codable { case text, choice, audio, video, image, external_proof, none }
enum GradingMethod: String, Codable {
    case deterministic, model_graded, multimodal_graded, external_verify, human
    case self_report_spotcheck = "self_report+spotcheck"
}
enum ActivityState: String, Codable {
    case assigned, in_progress, submitted, grading, graded_passed = "graded(passed)",
         graded_failed = "graded(failed)", rewarded, expired
}
```

**OpenAPI** (`shared/api/openapi.yaml`, additive — full block in §6.6). The client projection omits
`answerKey`/`rubric`; an internal `ActivityFull` (used server-side / by the grader) includes them.

### 6.2 How it supersedes today's `Exercise`
| Today (`Exercise`) | Becomes (`Activity`) | Note |
|---|---|---|
| `kindRaw ∈ {quiz,reflection,application}` | `kindRaw` (11 kinds) + `subtypeRaw` | `reflection`/`application` → `kind=long_answer`, `subtype=reflection/application` (FR-9) |
| `prompt` | `content` | rename (superset — may hold richer stimulus) |
| `options:[String]`, `answerIndex:Int?` | `optionsJSON`, `answerKeyJSON.answerIndex` | choice kinds; `answerKey` now withheld client-side |
| `xp` | `xp` (max) | same; partial credit scales it |
| `order` | `order` | unchanged |
| `userAnswer/chosenIndex/completedAt/score/feedback` | same, + `scoreBp` (int), `submissionArtifactKey`, `attempts`, `lifecycleRaw` | response state generalized; float `score` → `scoreBp` |
| (none) | `modality`, `gradingMethod`, `rubric`, `difficulty`, `objectiveRef`, `verification`, `maxAttempts`, `passThresholdBp` | the new polymorphism + grading config |
| `Lesson.exercises:[Exercise]` | `Lesson.activities:[Activity]` | relationship renamed; back-compat alias for one release (FR-9) |

Generation stays compatible: today's roadmap JSON (`prompts.py` `_ROADMAP_SYSTEM`) emits
`exercises[]` with `{kind, prompt, options, answerIndex, xp}`. The ingestion path maps each to an
`Activity` (defaulting `modality`/`gradingMethod`/`difficulty` from the kind table, `content←prompt`,
`answerKey.answerIndex←answerIndex`). `0038` will emit the richer `activities[]` shape natively; until
then the alias keeps the contract green (§9).

### 6.3 Activity lifecycle state machine (pure, unit-testable)
`ios/Mango/Services/Activities/ActivityLifecycle.swift` — `Foundation`-only, value-type reducer
(the `0011` `ActivityDeck` pattern), exhaustively unit-tested. (A byte-identical Python twin lives in
`backend/src/shared/activity_lifecycle.py` so server-side grading transitions are tested in `pytest`.)

```swift
import Foundation

enum ActivityEvent: Equatable {
    case start                          // assigned → in_progress (user opened/began)
    case submit                         // in_progress → submitted (a Submission captured)
    case beginGrading                   // submitted → grading (dispatched to a grader)
    case gradeReturned(scoreBp: Int, passThresholdBp: Int)   // grading → graded(passed|failed)
    case retry                          // graded(failed) → in_progress (if attempts < maxAttempts)
    case awardGranted                   // graded(passed) → rewarded (XP/credits applied once)
    case expire                         // any non-terminal → expired
}

enum ActivityLifecycle {
    /// Pure transition. `attempts`/`maxAttempts` gate `retry`. Illegal → unchanged.
    static func apply(_ e: ActivityEvent, to s: ActivityState,
                      attempts: Int, maxAttempts: Int) -> ActivityState {
        switch (s, e) {
        case (.assigned, .start):                 return .in_progress
        case (.in_progress, .submit):             return .submitted
        case (.submitted, .beginGrading):         return .grading
        case (.grading, let .gradeReturned(score, thr)):
            return score >= thr ? .graded_passed : .graded_failed
        case (.graded_failed, .retry):
            return attempts < maxAttempts ? .in_progress : .graded_failed   // bounded retry
        case (.graded_passed, .awardGranted):     return .rewarded
        case (_, .expire) where s != .rewarded && s != .expired: return .expired
        default:                                  return s                  // no-op
        }
    }
    static func isTerminal(_ s: ActivityState) -> Bool { s == .rewarded || s == .expired }
}
```
**Partial credit & retries.** `gradeReturned` carries `scoreBp`; `passed = scoreBp ≥ passThresholdBp`.
A failed activity may `retry` until `attempts == maxAttempts` (then it stays `graded_failed`; the
engine may still award partial XP proportional to the best `scoreBp` — XP policy in §6.4). `rewarded`
and `expired` are terminal. **Idempotency** (FR-5): `awardGranted` fires once; a second
`gradeReturned`/`awardGranted` on a `rewarded` activity is a no-op, and the XP-application site is
guarded by `lifecycle == .graded_passed` before granting (the `completedAtOpen`/`commitCurrent`
guard pattern).

Transition table (rows = state, cols = event; `–` = no-op):

| from \ event | `start` | `submit` | `beginGrading` | `gradeReturned` | `retry` | `awardGranted` | `expire` |
|---|---|---|---|---|---|---|---|
| `assigned` | in_progress | – | – | – | – | – | expired |
| `in_progress` | – | submitted | – | – | – | – | expired |
| `submitted` | – | – | grading | – | – | – | expired |
| `grading` | – | – | – | passed/failed | – | – | expired |
| `graded(failed)` | – | – | – | – | in_progress* | – | expired |
| `graded(passed)` | – | – | – | – | – | rewarded | expired |
| `rewarded` | – | – | – | – | – | – | – |
| `expired` | – | – | – | – | – | – | – |

\* `retry` only if `attempts < maxAttempts`, else stays `graded(failed)`.

### 6.4 Per-type taxonomy table (all 11 kinds)
Modality, default grading method, XP band (max award; partial credit scales), default difficulty
(Bloom band), the schema specialization each kind fills, and the **implementing spec**. (This spec
ships `mcq`/`quiz`/`puzzle`/`long_answer`; the rest are stubs against the contract.)

| Kind | Int/Ext | Modality | Grading method | XP (max) | Diff. (Bloom) | Schema specialization | Implemented by |
|---|---|---|---|---|---|---|---|
| `mcq` | internal | `choice` | `deterministic` | 15 | 1–2 (remember/understand) | `options[≥3]` + `answerKey.answerIndex`; distractors quality-filtered (research) | **0039** (this spec) |
| `quiz` | internal | `choice` | `deterministic` | 15 | 1 (remember) | lightweight recall; `options` (T/F or short) + `answerKey.answerIndex`; back-compat w/ today | **0039** |
| `puzzle` | internal | `choice`/`text` | `deterministic` | 20 | 2–3 (understand/apply) | ordering/matching/fill-in; `answerKey.solution` + `acceptable[]`, normalized compare | **0039** |
| `long_answer` | internal | `text` | `model_graded` | 25–40 | 3–4 (apply/analyze) | `rubric` (≥1 negative criterion, examples); `subtype ∈ {reflection, application, explain}` | **0039** (generalizes today's reflection/application) |
| `voice` | internal | `audio` | `multimodal_graded` | 35 | 4 (evaluate/explain) | `rubric`; `submissionArtifactKey`→S3 audio; ASR→text→model or audio-native model | **0040** (multimodal) |
| `conversation` | internal | `text`/`audio` | `model_graded` | 40 | 4–5 (evaluate) | `rubric` over a transcript; multi-turn tutor dialogue; grade the whole exchange | **0041** (conversational tutor) |
| `video` | internal | `video` | `multimodal_graded` | 45 | 4–5 (create) | `rubric`; `submissionArtifactKey`→S3 video; frame/audio multimodal grading | **0040** (multimodal) |
| `image` | internal | `image` | `multimodal_graded` | 30 | 3–4 (apply/create) | `rubric`; `submissionArtifactKey`→S3 image (e.g. photo of the applied habit) | **0040** (multimodal) |
| `social_engage` | external | `external_proof` | `self_report+spotcheck` (→ `external_verify`) | 30 | 1–3 (apply) | `verification{proofType:url_or_screenshot, verifier:self, spotCheckRate}` | **0042** (external engagement) |
| `content_consume` | external | `external_proof`/`none` | `external_verify` (→ `self_report+spotcheck`) | 25 | 2–3 (understand/apply) | `verification{proofType:time_on_task|url, minDurationSec}`; "go read/watch the cited source" | **0042** (external engagement) |
| `peer_session` | external | `external_proof` | `human` (peer) | 50 | 4–5 (evaluate/create) | `verification{proofType:peer_confirm, verifier:peer}`; both parties confirm | **0043** (peer & human) |

**XP policy (consistent across kinds).** `xp` is the **max**; the awarded XP is:
`deterministic` → full `xp` on pass, 0 on fail (today's quiz rule); `model_graded`/`multimodal_graded`
→ `round(xp * (0.5 + 0.5*score))` on a graded attempt (today's free-text rule, generalized);
`self_report+spotcheck` → full `xp` provisionally, clawed back to 0 only if a spot-check fails;
`human` → full `xp` once confirmed. Difficulty is advisory metadata for `0044` and does **not**
auto-scale XP (kept explicit per-kind to avoid surprises). XP amounts for the three existing kinds
are unchanged (15/25/40) to preserve `GamificationEngine` behavior.

### 6.5 Grading/verification contract (the common entry point)
`backend/src/shared/grading.py` (new) exposes the single contract; `grade_exercise.py` and the new
`activities_submit.py` handler both call it. The Swift side mirrors the dispatch in
`Services/Activities/ActivityGrader.swift` for the on-device path (Mock/Direct), reusing
`app.ai.grade` for `model_graded`.

```python
# backend/src/shared/grading.py
def grade(activity: dict, submission: dict) -> dict:
    """Common contract: returns {score: 0..1, xpAwarded: int, feedback: str, passed: bool}.
    Idempotent on (activity['id'], submission['id'])."""
    method = activity.get("gradingMethod", "model_graded")
    if method == "deterministic":
        return _grade_deterministic(activity, submission)      # mcq/quiz/puzzle — pure, no model
    if method == "model_graded":
        return _grade_model(activity, submission)              # reuse/extend agent.grade + rubric
    if method == "multimodal_graded":
        return multimodal.grade(activity, submission)          # HANDOFF → 0040 (stub here)
    if method in ("external_verify", "self_report+spotcheck"):
        return external.verify(activity, submission)           # HANDOFF → 0042 (stub here)
    if method == "human":
        return human.pending(activity, submission)             # HANDOFF → 0043 (returns pending)
    return _grade_model(activity, submission)                  # safe default
```

- **Deterministic** (`_grade_deterministic`): generalizes `grade_exercise.py`'s quiz branch.
  `mcq`/`quiz`: `passed = submission.chosenIndex == answerKey.answerIndex`. `puzzle`: normalize
  (lowercase/trim/whitespace-collapse) and compare `submission.text` to `answerKey.solution` ∪
  `acceptable`. `score ∈ {0.0, 1.0}`; `xpAwarded = xp if passed else 0`. **Pure, offline.**
- **Model-graded** (`_grade_model`): builds the prompt from `activity.rubric`. Extends
  `prompts.grade_system()`/`grade_user()` to inject the rubric criteria (incl. the **mandatory
  negative criterion** and any **examples**), and to forbid runtime criterion expansion (NFR-5,
  research). Calls `agent.grade`-style `_invoke` (async-worker path, off the 30 s budget). Returns
  `{score, feedback}`; `xpAwarded = round(xp*(0.5+0.5*score))`; `passed = score ≥ passThreshold`.
  Logs model/latency/tokens/outcome for `0027`. Reflection/application keep their exact prompts via
  `subtype`.
- **Multimodal** (`multimodal.grade`, **stub → 0040`**): same contract; consumes
  `submission.artifactKey` (S3) → multimodal Bedrock (or ASR→text). This spec provides the function
  signature + a deterministic test stub that asserts the contract shape.
- **External** (`external.verify`, **stub → 0042**): inspects `activity.verification` — for
  `self_report+spotcheck` returns an immediate provisional pass and (per `spotCheckRate`) flags a
  deeper check; for `external_verify` validates the proof (URL reachable / oauth signal / time-on-task
  ≥ `minDurationSec`). Stores only the minimal proof (NFR-7).
- **Human** (`human.pending`, **stub → 0043**): returns `{passed: None, pending: true}` and the
  lifecycle stays in `grading` until a peer/human signal arrives (a later `gradeReturned`).

**Idempotency + anti-cheat (FR-5).** The contract keys outcomes on `(activityId, submissionId)`; the
submit handler writes the outcome once and re-submits of the same `submissionId` return the stored
outcome (no double XP). Anti-cheat **hooks** (implemented in component specs): `answerKey`/`rubric`
are **withheld** from `GET /v1/activities/{id}` (client projection) and only the server grader sees
them; free text keeps the ≥3-char floor; self-reported kinds carry `spotCheckRate`; external proofs
are bound to `activityId+user+timestamp`.

### 6.6 API / contract (OpenAPI, additive)
Two new paths + the schemas; `/v1/exercises/grade` retained as a shim (FR-6). Keep
`openapi.yaml` ⇄ `DTOs.swift` ⇄ handlers in lockstep.
```yaml
paths:
  /v1/activities/{id}:
    get:
      summary: Fetch one activity's client-safe definition (no answerKey/rubric)
      parameters: [{ name: id, in: path, required: true, schema: { type: string } }]
      responses:
        "200": { description: Activity, content: { application/json: { schema: { $ref: "#/components/schemas/Activity" } } } }
        "404": { description: No such activity for the caller }
  /v1/activities/{id}/submit:
    post:
      summary: Submit a response; returns a grade outcome or a pending envelope
      parameters: [{ name: id, in: path, required: true, schema: { type: string } }]
      requestBody:
        required: true
        content: { application/json: { schema: { $ref: "#/components/schemas/Submission" } } }
      responses:
        "200": { description: Graded, content: { application/json: { schema: { $ref: "#/components/schemas/GradeOutcome" } } } }
        "202": { description: Accepted; grading async/human-pending, content: { application/json: { schema: { $ref: "#/components/schemas/GradeOutcome" } } } }
components:
  schemas:
    Activity:                          # CLIENT projection (answerKey/rubric withheld)
      type: object
      required: [id, kind, title, content, modality, gradingMethod, xp]
      properties:
        id: { type: string }
        kind: { type: string, enum: [mcq, quiz, puzzle, long_answer, voice, conversation, video, image, social_engage, content_consume, peer_session] }
        subtype: { type: string, nullable: true }
        title: { type: string }
        content: { type: string }
        modality: { type: string, enum: [text, choice, audio, video, image, external_proof, none] }
        gradingMethod: { type: string, enum: [deterministic, model_graded, multimodal_graded, external_verify, human, "self_report+spotcheck"] }
        difficulty: { type: integer, minimum: 1, maximum: 5 }
        xp: { type: integer }
        estimatedMinutes: { type: integer }
        order: { type: integer }
        objectiveRef: { type: string, nullable: true }
        options: { type: array, nullable: true, items: { type: string } }   # choice kinds only
        verification: { $ref: "#/components/schemas/Verification" }          # external/human kinds
        maxAttempts: { type: integer }
        passThreshold: { type: number, description: "0..1 (stored as basis-point int server-side)" }
    Verification:
      type: object
      nullable: true
      properties:
        proofType: { type: string, enum: [url_or_screenshot, oauth_signal, time_on_task, peer_confirm] }
        verifier: { type: string, enum: [self, model, peer, human] }
        spotCheckRate: { type: number }
        minDurationSec: { type: integer, nullable: true }
    Submission:
      type: object
      required: [id]
      properties:
        id: { type: string, description: "client-generated; idempotency key with activity id" }
        chosenIndex: { type: integer, nullable: true }   # choice kinds
        text: { type: string, nullable: true }           # long_answer/puzzle/conversation transcript
        artifactKey: { type: string, nullable: true }    # S3 key for audio/image/video/proof
        proofUrl: { type: string, nullable: true }       # external_proof
        selfReported: { type: boolean, nullable: true }
        durationSec: { type: integer, nullable: true }
    GradeOutcome:
      type: object
      required: [score, xpAwarded, feedback]
      properties:
        score: { type: number, description: "0..1 quality score (basis-point int in DDB)" }
        xpAwarded: { type: integer }
        feedback: { type: string }
        passed: { type: boolean, nullable: true }        # null while human/async-pending
        pending: { type: boolean, nullable: true }
        attemptsRemaining: { type: integer, nullable: true }
```
**`DTOs.swift`** gains `ActivityDTO`, `VerificationDTO`, `SubmissionDTO`, `GradeOutcomeDTO`
(lenient decode; absent enum → fallback), and an `ExerciseDTO`→`ActivityDTO` adapter for the alias
release. `GradeResultDTO` stays for the `/v1/exercises/grade` shim.

### 6.7 Data — DynamoDB items (single-table, float-free) & S3 artifacts
Coordinated with `0026` (tracking) and `0027` (artifacts). Single table, `PK`/`SK`, the existing
`USER#<sub>/…` and `BOOK#<id>/…` conventions; numeric attrs `int` only (scores as basis points).

- **Activity definition** (part of the generated roadmap artifact; authored by `0038`, persisted by
  `0027`): lives inside the roadmap JSON in S3 (`BOOK#<id>/ROADMAP` or per-user job artifact). The
  `Activity` client projection is served by `GET /v1/activities/{id}` resolving from that artifact (or
  a DDB `ACTIVITY#<id>` item if `0026` denormalizes it). `answerKey`/`rubric` stay server-side only.
- **Activity assignment / state** (per user, per activity — rides `0026`/`0014`):
  ```
  PK = USER#<sub>            SK = ACTIVITY#<activityId>
  attrs: kind (S), lifecycle (S), attempts (N int), scoreBp (N int 0..10000),
         xpAwarded (N int), passed (BOOL, optional), objectiveRef (S),
         submissionArtifactKey (S, optional), updatedAt (S iso), completedAt (S iso, optional)
  GSI1 (optional): GSI1PK = USER#<sub>  GSI1SK = ACTSTATE#<lifecycle>#<updatedAt>   # "my in-progress activities"
  ```
- **Submission record** (immutable, one per attempt — feeds idempotency + `0027` audit):
  ```
  PK = USER#<sub>            SK = SUBMISSION#<activityId>#<submissionId>
  attrs: chosenIndex (N, opt), textRef (S→S3, opt), artifactKey (S→S3, opt),
         proofUrl (S, opt), durationSec (N, opt), gradedScoreBp (N int), xpAwarded (N int),
         feedback (S), gradedBy (S: deterministic|model|multimodal|external|peer|human),
         createdAt (S iso)
  ```
  Long free-text and all media go to **S3**, referenced by key (never inlined — NFR-7); the DDB item
  holds only the key + scalar outcome. **Float-free:** `score`/`passThreshold` are basis-point
  `int`s; the wire `number` (0..1) is divided/multiplied at the edge (the `progress.py` Decimal→int
  pattern).
- **S3 submission-artifact layout** (under the existing artifact bucket, namespaced for `0027`):
  ```
  s3://<artifacts-bucket>/submissions/<sub>/<activityId>/<submissionId>.<ext>   # audio/jpg/mp4/txt
  ```
  Uploaded via a pre-signed PUT (the submit flow requests a URL, uploads, then submits the key) so
  Lambda never proxies large media. Least-privilege: the submit/grade Lambdas get scoped `s3:GetObject`
  on `submissions/*` only; the grade Lambda for `model_graded`/`deterministic` needs **no** S3 (mirrors
  the least-privilege `api_stack.py` grants).

### 6.8 iOS — `ActivityRenderer` registry (the `0011` deck renders any kind)
`ios/Mango/Features/Lesson/ActivityRenderer.swift`. The `0011` swipe deck (`ActivityCardView`) today
switches on `ExerciseKind`; it instead resolves a renderer by `Activity.kind` from a registry, so new
kinds plug in without touching the deck.
```swift
import SwiftUI

protocol ActivityRenderer {
    var kind: ActivityKind { get }
    /// Builds the card body for this activity; `onCommit` reports the graded XP (deck owns advance).
    func makeCard(for activity: Activity, onGraded: @escaping (GradeOutcome) -> Void) -> AnyView
    /// Whether the user has provided enough input to submit (reuses ExerciseRunnerView.canSubmit logic).
    func canSubmit(_ activity: Activity, state: ActivityInputState) -> Bool
    /// Builds the Submission to send (idempotency id is generated once per attempt).
    func makeSubmission(_ activity: Activity, state: ActivityInputState) -> Submission
}

@MainActor
final class ActivityRendererRegistry {
    static let shared = ActivityRendererRegistry()
    private var byKind: [ActivityKind: ActivityRenderer] = [:]
    func register(_ r: ActivityRenderer) { byKind[r.kind] = r }
    func renderer(for kind: ActivityKind) -> ActivityRenderer { byKind[kind] ?? FallbackRenderer() }
}
```
- **Ships here:** `ChoiceRenderer` (`mcq`/`quiz`/`puzzle` — reskins `ExerciseRunnerView`'s
  `quizOptions`, grades locally/deterministically), `LongAnswerRenderer` (`long_answer` — reuses the
  `TextEditor` + `app.ai.grade` path), and `FallbackRenderer` (unregistered/unsupported kind → a calm
  "update the app to do this activity" card; the offline-degradation path, FR-7/FR-8).
- **Registered by component specs:** `VoiceRenderer`/`ImageRenderer`/`VideoRenderer` (0040),
  `ConversationRenderer` (0041), `SocialEngageRenderer`/`ContentConsumeRenderer` (0042),
  `PeerSessionRenderer` (0043) — each in its own spec, registered at app start.
- The deck calls `renderer.makeCard(...)`; commit/advance/idempotency stay exactly as `0011` defines
  (the `commitCurrent` guard + `GamificationEngine.recordExercise` write — now `recordActivity`).

### 6.9 Diagrams
```
Composition (0038)            This spec (0039)                         Implemented by
─────────────────            ────────────────                         ──────────────
Track = [Activity, …]  ──▶   Activity{kind,modality,gradingMethod,    mcq/quiz/puzzle/long_answer → 0039
                              rubric?,answerKey?,verification?,xp,     voice/image/video           → 0040
                              difficulty,objectiveRef}                 conversation                → 0041
                                      │                                social_engage/content_consume → 0042
                                      ▼                                peer_session                → 0043
                              ActivityLifecycle (pure)
   assigned ─start▶ in_progress ─submit▶ submitted ─beginGrading▶ grading
        │                ▲                                   │
        │                └──────────── retry (attempts<max) ─┤ gradeReturned(scoreBp,thr)
        ▼                                                    ▼
     expired                              graded(passed) ─awardGranted▶ rewarded
                                          graded(failed)

grade(activity, submission) ──dispatch on gradingMethod──┐
  deterministic   → pure compare to answerKey  (mcq/quiz/puzzle)        [offline]
  model_graded    → rubric prompt → Bedrock     (long_answer/convo)     [async worker]
  multimodal_graded → S3 media → multimodal model (voice/image/video)   → 0040
  external_verify / self_report+spotcheck → proof check                 → 0042
  human           → peer/human confirm (pending)                        → 0043
        └────────────▶ GradeOutcome{score, xpAwarded, feedback, passed}
```

## 7. Acceptance criteria
- [ ] **AC-1 (taxonomy complete).** `ActivityKind` defines all 11 kinds (8 internal + 3 external);
      each has a default `modality`, `gradingMethod`, XP band, difficulty, and an implementing-spec
      reference matching the §6.4 table. *(Enum + a table-driven unit test asserting defaults per
      kind.)*
- [ ] **AC-2 (schema round-trip).** Every kind's `Activity` encodes to JSON and decodes back equal
      (Swift `Codable` + the OpenAPI shape), including `rubric`, `verification`, `options`,
      `answerKey`; unknown `kind`/`modality`/`gradingMethod` strings decode to the documented
      fallback without crashing. *(Round-trip + lenient-decode unit tests, mirroring
      `CatalogBookTests`.)*
- [ ] **AC-3 (lifecycle correctness).** `ActivityLifecycle.apply` matches the §6.3 table for **every**
      (state × event) pair, including illegal-transition no-ops, bounded `retry`
      (`attempts == maxAttempts` stays failed), and `rewarded`/`expired` terminality. *(Pure
      `ActivityLifecycleTests` + the Python twin in `pytest`.)*
- [ ] **AC-4 (grading determinism).** `_grade_deterministic` is pure and stable: a given
      `mcq`/`quiz`/`puzzle` + submission always yields the same `{score, xpAwarded, passed}`; correct
      → full `xp`, incorrect → 0; puzzle normalization accepts `acceptable[]` alternates. *(Pure
      `pytest` + Swift `ActivityGraderTests`, no network.)*
- [ ] **AC-5 (model-graded rubric path).** `_grade_model` builds a prompt that includes the rubric
      criteria **and a mandatory negative criterion**, never auto-expands criteria, and returns the
      `{score, feedback}` shape; XP = `round(xp*(0.5+0.5*score))`; reflection/application subtypes
      reproduce today's behavior. *(Unit test with monkeypatched Bedrock asserting the prompt contains
      the negative criterion and the XP math.)*
- [ ] **AC-6 (idempotency / award-once).** Submitting the same `(activityId, submissionId)` twice
      returns the stored outcome and awards XP exactly once; the lifecycle grants `awardGranted` only
      from `graded(passed)`. *(Handler test on `activities_submit` + lifecycle guard test.)*
- [ ] **AC-7 (endpoints + shim).** `GET /v1/activities/{id}` returns the client projection **without**
      `answerKey`/`rubric`; `POST /v1/activities/{id}/submit` returns a `GradeOutcome` (or 202 pending
      for human/async); `/v1/exercises/grade` still works via the shim. *(pytest with moto + a
      contract check that withheld fields are absent.)*
- [ ] **AC-8 (supersede `Exercise`).** A pre-migration store of `Exercise`s migrates to `Activity`s
      (`quiz→quiz`, `reflection/application→long_answer` subtypes), preserving XP/order/response
      state/completion; the generation alias keeps the roadmap contract green. *(SwiftData migration
      test on a seeded in-memory container.)*
- [ ] **AC-9 (renderer registry).** The `0011` deck renders an `Activity` of each **shipped** kind via
      the registry; an **unregistered** kind renders the `FallbackRenderer` card (no crash). *(UI smoke
      + a registry unit test.)*
- [ ] **AC-10 (offline-first).** Fresh install, Mock AI, no network/key: the sample's
      `mcq`/`quiz`/`puzzle`/`long_answer` activities complete and award XP; network-bound kinds render
      a queued/"verify when online" state and never appear in the offline sample. *(Manual offline run
      + assertion the sample contains only offline-capable kinds.)*
- [ ] **AC-11 (float-free + contract lockstep).** All new DDB numeric attrs are `int` (scores in basis
      points); `openapi.yaml` ⇄ `DTOs.swift` ⇄ handlers agree; `cdk synth -c stage=beta` and `pytest`
      pass offline. *(synth + pytest + a grep that no handler writes a Python `float`.)*

## 8. Test plan
- **Unit — Swift (pure, primary; `LevelCurveTests`/`ActivityDeckTests` style):**
  - `ActivityLifecycleTests` (→ AC-3): exhaustive (state × event) table; bounded-retry boundary
    (`attempts == maxAttempts`); terminal no-ops; partial-credit `gradeReturned` pass/fail split.
  - `ActivityCodableTests` (→ AC-2): per-kind round-trip; lenient decode of unknown
    `kind`/`modality`/`gradingMethod`; `rubric`/`verification`/`answerKey` JSON-column accessors.
  - `ActivityKindDefaultsTests` (→ AC-1): asserts each kind's default modality/grading/XP/difficulty
    and `isExternal` per §6.4.
  - `ActivityGraderTests` (→ AC-4): deterministic grader stability for mcq/quiz/puzzle (incl.
    `acceptable[]` normalization); the `FallbackRenderer` selection (→ AC-9).
  - `ActivityMigrationTests` (→ AC-8): seed `Exercise`s in an in-memory `ModelContainer`, run the
    backfill, assert mapping + preserved state.
  - `ActivityDTOTests` (→ AC-2/AC-11): decode the OpenAPI example JSON; `ExerciseDTO→ActivityDTO`
    adapter.
- **Unit — Python (`pytest`, moto + monkeypatched Bedrock, offline):**
  - `test_activity_lifecycle.py` (→ AC-3): the Python twin matches the Swift table (shared fixture of
    expected transitions).
  - `test_grading_deterministic.py` (→ AC-4): mcq/quiz/puzzle outcomes; idempotency on
    `(activityId, submissionId)` (→ AC-6).
  - `test_grading_model.py` (→ AC-5): asserts the built prompt contains the **negative criterion**,
    no runtime criterion expansion, and the XP formula; monkeypatched `agent.grade`.
  - `test_activities_submit.py` (→ AC-7): `GET` omits `answerKey`/`rubric`; `submit` returns a graded
    outcome and a 202-pending for `human`; the `/v1/exercises/grade` shim still grades quiz + free
    text. Float-free DDB round-trip (basis-point scores).
- **Integration / contract:** `cdk synth -c stage=beta` passes; an openapi-lint/diff check that the
  new schemas match `DTOs.swift`; a stub test for each **handoff** (`multimodal.grade`,
  `external.verify`, `human.pending`) asserting it satisfies the `GradeOutcome` contract shape (so
  `0040`/`0042`/`0043` have a conformance target).
- **iOS UI (manual):** deck renders each shipped kind; Fallback card for an unregistered kind;
  VoiceOver labels + non-gesture submit per kind; Reduce-Motion; offline sample run (AC-10).
- **Regression:** `make ios-test` + backend `pytest`/`cdk synth` green; the existing
  quiz/reflection/application loop behaves identically through the `Activity`/shim path (same XP).

## 9. Rollout & migration
- **Flag:** `activityFrameworkEnabled` (in `AppSettings`, `@Observable`+`UserDefaults` pattern;
  default **off** until the AC suite is green, then **on**). Off → the app keeps using `Exercise`
  end-to-end; on → the `Activity` model + registry + new endpoints are active behind the same
  generation contract.
- **Phase 1 (additive, no behavior change).** Land the schema (`Activity` + enums + value types),
  the pure `ActivityLifecycle` (+ Python twin), the `grade()` contract reusing `grade_exercise.py`,
  and the new endpoints **as a parallel path**. `Exercise` and `/v1/exercises/grade` keep working; the
  new `Activity` is populated by a **mapping adapter** from generated `exercises[]` (FR-9). All tests
  green; nothing user-visible changes.
- **Phase 2 (supersede in the model graph).** Behind the flag, switch `Lesson` to `activities:
  [Activity]`, register `ChoiceRenderer`/`LongAnswerRenderer`, point the `0011` deck at the registry.
  One-time SwiftData backfill (`MangoMigration.backfillActivities(_:)` from `RootView.task` after
  `ensureSeeded`, `UserDefaults`-guarded once): map each `Exercise`→`Activity`, preserve
  XP/order/response/completion; keep the `Exercise` DTO alias for one release so `0038`/today's roadmap
  JSON still decodes.
- **Phase 3 (component kinds + teardown).** `0040`–`0043` register their renderers/graders against the
  frozen contract. After they ship and the alias release passes, **remove** `Exercise`, the
  `ExerciseKind` enum usage, and the `/v1/exercises/grade` shim (or keep the shim as a documented
  legacy alias). Update `prompts.py` (`0038`) to emit `activities[]` natively, retiring the adapter.
- **Backward compatibility.** Lenient decoding means an old client receiving an unknown future `kind`
  renders the Fallback card rather than crashing; a new client receiving the legacy `exercises[]`
  shape maps it via the adapter. The DDB items are additive (new `SK` prefixes `ACTIVITY#`/`SUBMISSION#`)
  — no rewrite of `PROGRESS`/`PROFILE`/`BOOK#` items.
- **Coordination.** Land **before** `0040`–`0043` (they implement against this) and **with/after**
  `0038` (which composes `Activity`s) and `0011` (the deck this registry plugs into). `0026`/`0027`
  own the server-side persistence/observability of the items defined in §6.7.

## 10. Risks & open decisions
- **R-1 Over-engineering the schema for kinds not built yet.** *Mitigation:* ship only the four
  offline/cheap kinds (`mcq`/`quiz`/`puzzle`/`long_answer`) plus the contract + stubs; the other seven
  are *schema slots + a stub test*, not code. The schema is additive, so getting a field slightly
  wrong for `video` costs a lenient-decode default, not a migration.
- **R-2 Model-graded reliability/bias.** *Risk:* free-text rubrics drift, over-award, or self-prefer.
  *Mitigation:* mandatory **negative criterion**, in-criterion **examples**, **no runtime criterion
  expansion**, fixed pass threshold, and logged grading for audit — directly from the rubric-grading
  literature ([Autorubric](https://arxiv.org/abs/2603.00077);
  [From Rubrics to Reliable Scores](https://arxiv.org/abs/2601.08654)). Keep the "be generous with
  genuine effort, never harsh" tone from today's `_GRADE_SYSTEM`.
- **R-3 Auto-generated `mcq` distractors are superficial.** *Mitigation:* generation (in `0038`) runs
  distractors through quality filters and stores an explicit `answerKey`; the deterministic grader
  trusts the key, not the model, at grade time ([D-GEN](https://arxiv.org/pdf/2504.13439)).
- **R-4 Anti-cheat for self-reported / external kinds.** *Risk:* honor-system tasks are gameable.
  *Mitigation:* the contract defines the hooks (proof binding, `spotCheckRate`, oauth/time-on-task
  signals); the *enforcement* lives in `0042`/`0043`. Like `0008`'s self-attested checkpoints, the
  social cost is low (XP, not money) — `0023`/`0024` add stricter checks before anything monetizable.
- **R-5 Float-free discipline across a richer schema.** *Risk:* `score`/`passThreshold`/`difficulty`
  invite Python `float`s into DDB. *Mitigation:* store scores as **basis-point `int`s**, convert at
  the wire edge; a grep test forbids `float(` in handlers (the `progress.py` rule).
- **R-6 Cost/latency of more model grading.** *Mitigation:* `maxAttempts` caps re-grades; per-kind
  token caps; model/multimodal grading on the async-worker path (off the 30 s budget); deterministic
  kinds stay free/offline. Logged token usage feeds `0027` cost alarms.
- **R-7 Contract drift across the cluster.** *Risk:* `0040`–`0043` diverge from this contract.
  *Mitigation:* the **handoff stub tests** (§8) are a conformance target each component spec must keep
  green; the schema/lifecycle live here only.
- **Decisions needed (with recommendations):**
  - **D-1 (recommended: one `Activity` model with a `subtype` discriminator, *not* a class hierarchy).**
    Polymorphism via `kind`+`subtype`+JSON payload columns vs SwiftData subclassing — recommend the
    flat model (SwiftData inheritance is fragile; lenient-decode is trivial; the wire stays simple).
  - **D-2 (recommended: scores as basis-point `int` 0–10000 in DDB; `number` 0..1 on the wire).** vs
    storing JSON-string scores. Basis points keep arithmetic/queries int-clean and float-free.
  - **D-3 (recommended: retain `/v1/exercises/grade` as a thin shim for one release, then deprecate).**
    vs hard-cut to `/v1/activities/{id}/submit`. The shim de-risks the migration.
  - **D-4 (recommended: ship `mcq` distinct from `quiz`).** `mcq` = single-best-answer w/ generated
    distractors + quality filter; `quiz` = the existing lightweight recall check (back-compat). vs
    merging them — keeping both lets `0038` pick the right rigor per objective.
  - **D-5 (recommended: client-safe projection withholds `answerKey`/`rubric`; an internal
    `ActivityFull` carries them server-side).** vs sending everything (insecure — defeats deterministic
    grading and leaks rubrics).
  - **D-6 (defer to `0026`/`0027`):** exact DDB GSIs and S3 retention/lifecycle for submissions —
    shaped here, owned there.

## 11. Tasks & estimate
1. `ActivityKind`/`ResponseModality`/`GradingMethod`/`ActivityState` enums (+ per-kind defaults
   table) and the `Rubric`/`Verification`/`AnswerKey`/`Submission`/`GradeOutcome` Codable value types.
   **(S)**
2. `Activity` `@Model` + `Codable` + lenient accessors + JSON-string columns; `ActivityCodableTests`
   + `ActivityKindDefaultsTests`. **(M)**
3. Pure `ActivityLifecycle` (Swift) + the byte-identical `activity_lifecycle.py` twin; exhaustive
   `ActivityLifecycleTests` + `test_activity_lifecycle.py`. **(M)**
4. `grade()` contract in `backend/src/shared/grading.py`: `_grade_deterministic` (generalize
   `grade_exercise.py` quiz branch) + `_grade_model` (extend `agent.grade`/`prompts.grade_*` with
   rubric + mandatory negative criterion, no runtime expansion); idempotency keying. **(M)**
5. Stubs + conformance tests for the handoffs (`multimodal.grade`→0040, `external.verify`→0042,
   `human.pending`→0043) asserting the `GradeOutcome` shape. **(S)**
6. New handlers `GET /v1/activities/{id}` (client projection, withhold answerKey/rubric) +
   `POST /v1/activities/{id}/submit` (idempotent, returns outcome/202-pending); retain
   `/v1/exercises/grade` shim. `openapi.yaml` + `DTOs.swift` (+ `ExerciseDTO→ActivityDTO` adapter).
   **(M)**
7. iOS `ActivityRenderer` protocol + `ActivityRendererRegistry` + `ChoiceRenderer`,
   `LongAnswerRenderer`, `FallbackRenderer`; wire the `0011` deck to resolve by `kind`. **(M)**
8. DDB item shapes (assignment/state + submission) + S3 submission prefix + pre-signed-PUT flow;
   least-privilege IAM (coordinate `0026`/`0027`); float-free (basis-point) round-trip tests. **(M)**
9. Supersede `Exercise`: `Lesson.activities:[Activity]` behind `activityFrameworkEnabled`; one-time
   `MangoMigration.backfillActivities`; generation adapter (`exercises[]`→`Activity`) + migration
   test. **(M)**
10. XP policy wiring: generalize `GamificationEngine.recordExercise`→`recordActivity` (same math for
    existing kinds); guard award-once on `graded(passed)`. **(S)**
11. Flag + docs: `AppSettings.activityFrameworkEnabled`; update `docs/ARCHITECTURE.md` /
    `docs/GAMIFICATION.md` to describe the Activity framework; manual offline/a11y pass. **(M)**
12. *(Future, separate specs)* component kinds `0040`–`0043` register renderers/graders;
    `0038` emits `activities[]` natively; retire the adapter/shim. **(L)**

## 12. References
- **Repo (read for accuracy):** `CLAUDE.md`; `working/INDEX.md`, `working/ARCHITECTURE_REVIEW.md`;
  `working/0008-product-reframe-activity-first.md`, `working/0011-navigation-and-activity-interaction.md`.
  iOS: `ios/Mango/Models/RoadmapModels.swift` (`Exercise`/`Lesson`), `ios/Mango/Models/Enums.swift`
  (`ExerciseKind`/`LessonStatus`), `ios/Mango/Features/Lesson/{ExerciseRunnerView,LessonView}.swift`,
  `ios/Mango/Services/Networking/DTOs.swift`. Backend: `backend/src/handlers/{grade_exercise,progress,
  generate_roadmap}.py`, `backend/src/shared/{agent,prompts}.py`. Contract:
  `shared/api/openapi.yaml` (`Exercise`/`GradeRequest`/`GradeResult`/`RoadmapJob`). **Findings used:**
  grading is a `kind` switch (quiz deterministic; reflection/application model-graded via a single
  free-text rubric prompt); DDB is single-table `PK`/`SK` with float-free int coercion; the
  `Exercise.kind`/`CatalogBook` lenient-decode idiom is the model for unknown-string fallback.
- **Cross-spec (this cluster):** `0038-agentic-roadmap-engine` (composes tracks of `Activity`),
  `0040-multimodal-activities` (`voice`/`image`/`video` — `multimodal_graded`),
  `0041-conversational-tutor-activities` (`conversation` — `model_graded` over a transcript),
  `0042-external-engagement-activities` (`social_engage`/`content_consume` —
  `external_verify`/`self_report+spotcheck`), `0043-peer-and-human-activities` (`peer_session` —
  `human`). Coordinates: `0026` (server tracking — assignment/submission items), `0027` (artifact
  store + LLM observability — S3 submissions, grading logs), `0023` (credits — consumes
  `rewarded`/`xpAwarded`), `0044` (recommendation — consumes `kind`/`difficulty`/`objectiveRef`),
  `0014` (sync — rides the per-user activity-state items).
- **Research (web):**
  - Rubric-based LLM grading — fixed criteria, traceable evidence, calibrated interpretation; three
    failure modes (rubric drift, unverifiable attribution, human-scale misalignment) —
    https://arxiv.org/abs/2601.08654
  - Autorubric — analytic rubrics, ensembles, calibration, bias mitigations; **add a negative
    criterion**, **embed examples** (+a few % alignment), **never auto-expand criteria** (−15–20%) —
    https://arxiv.org/abs/2603.00077
  - LLM-as-a-Grader practical insights (short-answer/report; flexible rubrics; human-in-the-loop is
    the effective mode) — https://arxiv.org/html/2511.10819v1
  - Automated **distractor** generation for MCQs (LLMs produce superficial distractors; quality
    filtering / overgenerate-and-rank needed) — https://arxiv.org/html/2404.02124 ·
    D-GEN distractor generation & evaluation — https://arxiv.org/pdf/2504.13439
  - Multimodal LLM grading of visual/handwritten work (direct image grading; human oversight
    required) — https://arxiv.org/pdf/2601.00730
  - Bloom's revised taxonomy → learning activities & assessments (maps kinds/difficulty;
    authentic assessment at the apply/create end) —
    https://uwaterloo.ca/centre-for-teaching-excellence/resources/teaching-tips/blooms-taxonomy-learning-activities-and-assessments
  - Extensible **plugin / pathway** architecture for learning platforms (custom node types extend base
    types — minimal surface to add an activity) —
    https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/12277869 ·
    Adaptive & gamified learning paths (Polyglot/.NET — pluggable activity components) —
    https://arxiv.org/pdf/2310.07314
