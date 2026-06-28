# 0038 — Agentic roadmap generation engine

- **Epic:** M15 · **Status:** Draft · **Owner:** unassigned · **Updated:** 2026-06-28
- **Reviewers:** Principal/SD/QA

> **Cluster note.** This is the **flagship / umbrella** spec of a 7-spec cluster (0038–0044). It owns the **architecture and orchestration**; the building blocks are specced separately and referenced by filename throughout: activity taxonomy [`0039-activity-type-framework`], multimodal activities [`0040-multimodal-activities`], conversational tutor [`0041-conversational-tutor-activities`], external engagement [`0042-external-engagement-activities`], peer/human [`0043-peer-and-human-activities`], recommendation engine [`0044-personalization-recommendation-engine`]. It builds on the architecture-review backlog: [`0020-feature-store-personalization`], [`0026` server-side activity tracking], [`0027` artifact store + LLM observability], [`0028` shared per-book template cache], [`0030` AI safety/Guardrails], plus [`0023` credits] and [`0029` rate-limit]. Where those are not yet drafted, this spec treats them as **forward dependencies** and pins the exact seam each must honor.

## 1. Summary

Today a "roadmap" is produced by a **single asynchronous Amazon Bedrock call**: `POST /v1/roadmaps/generate` persists a job, fire-and-forgets the `roadmap_worker` Lambda, the worker makes one `bedrock-runtime:InvokeModel` call (`shared/agent.generate_roadmap`), parses the JSON into a fixed `4 milestones × 2 lessons × 2 exercises{quiz|reflection|application}` shape, writes it back as a JSON string on the user's job row, and the app polls `GET /v1/roadmaps/jobs/{jobId}`. That is one model, one prompt, one shot, one rigid template, no grounding beyond a 12 k-char excerpt, no quality gate, and no personalization (the profile is empty until 0020).

This spec **replaces that single call with a multi-agent, personalized, multi-modal agentic engine**: a named pipeline of specialized Bedrock-backed agents — **Researcher → Curriculum Planner → Activity Designer → Personalizer → Verifier/QA** — orchestrated by an **AWS Step Functions Standard** state machine that calls Bedrock through the optimized `bedrock:invokeModel` integration (offloading large payloads to S3), grounds the curriculum in **learning science** (Bloom's taxonomy, backward design, scaffolding, retrieval + spaced practice), draws activities from the **0039 taxonomy** across modalities (0040–0043), curates the track with **0020 features + 0044 recommendations**, and gate-checks every artifact for **schema validity, difficulty balance, and safety (0030)** before it is shown. The richer track JSON (milestones → lessons → activities[] each referencing a 0039 type + grading method + XP + modality) is **versioned and cached per-book (0028)** with a thin **per-user personalization layer**, and every stage emits an artifact + transcript to the 0027 store. **The existing `202 {jobId}` + poll contract is preserved** — only the progress vocabulary grows (`researching → planning → designing → personalizing → verifying → complete`) — so the iOS app changes minimally.

## 2. Goals / Non-goals

- **Goals:**
  - Define a **named, staged agent pipeline** (Researcher, Curriculum Planner, Activity Designer, Personalizer, Verifier/QA) with crisp responsibilities, inputs/outputs, and the data flowing between them (§6.2–§6.3).
  - **Recommend and justify the AWS orchestration mechanism** — Step Functions Standard orchestrating Bedrock — against the alternatives (Bedrock multi-agent collaboration, Bedrock Flows, the current async-Lambda), with the tradeoffs that drive the choice (§6.4, §10).
  - Specify the **richer track output schema** (versioned, cached per-book base + per-user layer) where each activity references a 0039 type, a grading method, an XP value, and a modality (§6.6).
  - Keep the **`202 {jobId}` + poll contract** intact while extending the **progress state machine** to the five pipeline phases, so the app shows live progress (§6.5, §6.7).
  - Pin the **data/contract surface**: job/track DDB items, S3 artifacts (0027), endpoints (`/v1/roadmaps/generate` + status; openapi notes), and how iOS consumes progress + the track (§6.7–§6.8).
  - Define the **cost & credit model**: shared base generation cached per book (0028) vs the per-user personalization layer; what costs a credit (0023) and what is free (§6.9).
  - Bake in **retries, idempotency, and timeouts** so the long pipeline is reliable across the 15-min Lambda boundary and Bedrock throttles (ties 0027/0032).
  - Ground the curriculum in **learning science** so the output is pedagogically defensible, not just well-formatted (§6.1).
- **Non-goals:**
  - **Designing the activity taxonomy itself** — the type catalog, per-type schemas, and grading methods are [`0039`]; this spec only consumes "a 0039 type id + grading method + modality."
  - **The modality implementations** (audio/visual rendering 0040, conversational tutor runtime 0041, external/peer mechanics 0042/0043) — the engine *selects and references* them; it does not build their runtimes.
  - **The recommendation/feature math** — [`0044`] (which activities/modalities/difficulty to favor) and [`0020`] (the feature store + producers) own that; the Personalizer *calls* them.
  - **AI safety controls** themselves — [`0030`] owns Guardrails config, input tagging, and disclaimers; the Verifier *invokes* them as a gate.
  - **Credit ledger, paywall, or StoreKit** — [`0023`]; this spec only defines *when* a credit is consumed.
  - **The iOS journey/track rendering redesign** — beyond decoding the richer track and showing pipeline progress; the activity-card UX lives in [`0011`]/[`0039`].
  - **Migrating historical roadmaps** beyond a forward-compatible decode (old `4×2×2` roadmaps remain valid; §9).

## 3. Background & context

**As-built generation (verified by reading the code).**
- `POST /v1/roadmaps/generate` (`backend/src/handlers/generate_roadmap.py`) resolves the book (inline `book.text` or stored `bookId` → S3 `contentRef`), persists a **pending job** (`roadmap_jobs.create_pending`: `PK=USER#<uid>`, `SK=ROADMAPJOB#<jobId>`, carrying `book`, `profile`, `excerpt=full_text[:12000]`), then `lambda.invoke(InvocationType="Event")` the worker and returns `202 {jobId, status:"pending"}`. If no worker is configured it generates inline (local/offline path).
- `roadmap_worker` (`backend/src/handlers/roadmap_worker.py`) loads the inputs and calls `agent.generate_roadmap(book, profile, excerpt)` — **one** `InvokeModel` call (`shared/agent.py`) with adaptive extended thinking at **effort "medium"** (measured ~27 s; "high" truncated the JSON / pushed ~45–50 s), `max_tokens=3000` (+4096 thinking headroom) — then `extract_json` and `mark_complete`/`mark_failed`. The worker has a **60 s** Lambda budget, off the 30 s API Gateway path.
- The **prompt** (`shared/prompts.py`) hard-codes the shape: *exactly* 4 milestones × 2 lessons × 2 exercises, `kind ∈ {quiz, reflection, application}`, fixed XP (quiz 15 / reflection 25 / application 40), grounded in `{title, author, wordCount}` + `excerpt[:12000]`.
- The roadmap is stored **as a JSON string on the job row** (`mark_complete`) — **not** in S3, **not** shared per book; `BOOK#<id>/ROADMAP` is documented but never written (`ARCHITECTURE_REVIEW.md` §1).
- Bedrock is reached via `bedrock-runtime:InvokeModel` with **IAM, no API key** (`CLAUDE.md` invariant; `BEDROCK_MODEL_ID`/`BEDROCK_REGION` env). DynamoDB **rejects Python `float`** (coerce to int / JSON string). Lambdas are **stdlib + boto3 only** (no packaging step). Backend style: black (100) + flake8 (120).

**Why now (the pivot).** Per [`0008`] and the cluster brief, Mango is **not a reading app** — it delivers **engaging activities** and tracks the journey. A "roadmap" is a **personalized track of activities for a book**. The single-shot generator produces one rigid, text-only template (`quiz/reflection/application`) with no grounding research, no pedagogy, no modality variety, no personalization, and no quality gate. That is the wrong engine for the product we are now building. The cluster (0039–0044) introduces a rich **activity taxonomy** across **modalities** (audio, visual, conversational, external, peer/human) and a **recommendation engine** — and those only pay off if a real **engine** can research a book, plan a sound curriculum, design varied activities per objective, personalize the track, and verify it. This spec is that engine and the orchestration umbrella the rest plug into.

**Why agentic + Step Functions (the research basis).**
- Single-shot generation conflates five different jobs (research, curriculum design, activity authoring, personalization, QA) into one prompt; **decomposing into specialized agents** (the planner→worker→verifier + reflection + tool-use patterns) raises quality and lets each stage use a right-sized model and prompt ([philschmid](https://www.philschmid.de/agentic-pattern), [deeplearning.ai Reflection](https://www.deeplearning.ai/the-batch/agentic-design-patterns-part-2-reflection)).
- The pipeline is **deterministic and ordered** (a curriculum is built backward from objectives, not improvised), needs **full auditability** (every artifact inspectable — 0027), and **outlives a single 15-min Lambda** when run end-to-end with reflection loops. **AWS Prescriptive Guidance** explicitly recommends **Step Functions for deterministic, auditable, well-defined control flows** and reserves **Bedrock Agents for dynamic/conversational goal-fulfilment** ([orchestration-models](https://docs.aws.amazon.com/prescriptive-guidance/latest/agentic-ai-serverless/orchestration-models.html)). **Step Functions Standard** runs up to **1 year**, is **exactly-once**, and gives a **full state trace** ([choosing-workflow-type](https://docs.aws.amazon.com/step-functions/latest/dg/choosing-workflow-type.html)). It integrates Bedrock via the **optimized `bedrock:invokeModel`** task (no Lambda glue) with **S3 `Input`/`Output` offloading** for payloads >256 KiB ([connect-bedrock](https://docs.aws.amazon.com/step-functions/latest/dg/connect-bedrock.html)). That matches our needs better than the single async Lambda (no DLQ/retry/idempotency/observability today — `ARCHITECTURE_REVIEW.md` G6/G7) and better than fully AI-native orchestration for a flow this structured.

**Related specs.** Consumes 0039 (types), 0040–0043 (modalities), 0044 + 0020 (personalization), 0030 (safety), 0028 (cache), 0027 (artifacts/observability), 0023 (credits), 0029 (rate-limit). Pairs with 0026 (the completion signals the track drives) and 0032 (worker reliability + cost guardrails, which this folds the new state machine into).

## 4. User stories

- As a **learner starting a new book**, I tap **Start journey** and watch the app move through *Researching → Planning → Designing → Personalizing → Verifying* in a few seconds, then land on a track of varied activities that actually fits the book and my level.
- As a **returning learner** who finds quizzes too easy and loves the talk-it-out tutor, I get a track that **leans into conversational/application activities at a higher difficulty** because the engine personalized it from my features (0020) and 0044's recommendations.
- As a **second learner opening the same popular book**, my track appears **near-instantly and at no credit cost** because the shared per-book base was already generated and cached (0028); only my thin personalization layer is computed.
- As a **product owner**, when a generated track looks wrong I can open the **full transcript of every stage** (Researcher findings, Planner objectives, Designer choices, Verifier verdict) in the 0027 artifact store and see exactly which agent produced the issue.
- As an **on-call engineer**, a stuck or throttled generation **retries with backoff, is idempotent, surfaces in CloudWatch with the `jobId` correlation id, and dead-letters** instead of silently hanging — and I can see token usage and estimated cost per run.
- As a **safety reviewer**, I am assured that **no track reaches a user** without passing the 0030 Guardrails + difficulty + schema gate, and that medical/sensitive content is blocked or disclaimed.
- As an **offline first-run user**, none of this is on my critical path: the bundled sample + `MockAIService` still work with **zero network/agents** (the `CLAUDE.md` offline invariant is untouched).

## 5. Requirements

### Functional

- **FR-1 (named pipeline).** Generation MUST execute as five named stages in order — **Researcher → Curriculum Planner → Activity Designer → Personalizer → Verifier/QA** — each a discrete Bedrock-backed step with a defined input contract and a defined output artifact (§6.2–§6.3).
- **FR-2 (Researcher).** Extract the book's **themes, key concepts, and real-world applications** from the book excerpt/text (and, when enabled, an optional knowledge-base/web grounding source — §6.2), producing a structured `research.json` the Planner consumes. MUST degrade gracefully to "excerpt-only" when no external grounding is configured.
- **FR-3 (Curriculum Planner).** Produce **milestones with explicit learning objectives** grounded in pedagogy — each objective tagged with a **Bloom's level**, scaffolded low→high across the track, designed **backward** from the objectives, and arranged for **retrieval + spaced practice** (later milestones re-surface earlier concepts) (§6.1, §6.2).
- **FR-4 (Activity Designer).** For each objective, **select and author activities from the 0039 taxonomy** matched to the objective's Bloom level + an appropriate **modality** (0040–0043) + the user's level, emitting per-activity `{type, modality, gradingMethod, xp, prompt/payload}` that conform to the 0039 per-type schema. MUST cover a **mix of modalities** across a track (not all text), subject to availability flags.
- **FR-5 (Personalizer).** Apply **0020 features + 0044 recommendations** to curate the track for the user: reorder/select activities, set difficulty, and choose modality emphasis — as a **thin layer over the shared base** (no full re-generation when a base exists), so the cache stays hot (§6.6, §6.9). MUST no-op to a sensible default when features are cold (cold-start = the unpersonalized base).
- **FR-6 (Verifier/QA).** Before completion, every track MUST pass a gate: **(a) JSON-schema validity** for the track + each activity's 0039 type; **(b) difficulty balance** (Bloom distribution + XP spread within bounds, no milestone all-hard/all-easy); **(c) safety** via **0030 Guardrails** (input-tagged book/user text; output filtered; denied topics; disclaimers). A failing gate triggers a **bounded reflection/repair** loop or a clean failure — never ships an unverified track (§6.3).
- **FR-7 (contract preserved).** `POST /v1/roadmaps/generate` MUST still return **`202 {jobId, status}`** and `GET /v1/roadmaps/jobs/{jobId}` MUST still return the job view; the **status enum grows** to `pending → researching → planning → designing → personalizing → verifying → complete | failed`, and the completed job MUST carry (or point to) the richer track (§6.5, §6.7).
- **FR-8 (richer track schema).** The output MUST be the versioned track JSON of §6.6: `track → milestones[] → lessons[] → activities[]`, each activity referencing a **0039 type id**, **grading method**, **XP**, and **modality**, plus per-milestone **objectives[]** with Bloom levels. MUST remain **forward-compatible** so the iOS decoder and old `4×2×2` roadmaps still work (§9).
- **FR-9 (cache-aware).** Generation MUST integrate with the **0028 shared per-book cache**: a cache hit **clones** the shared base into the user's job and runs **only** the Personalizer (+ a light Verifier re-check); a miss runs the full pipeline once under 0028's single-flight lock and **populates** the shared base (§6.6, §6.9).
- **FR-10 (artifacts + observability).** Each stage MUST write its artifact + transcript (prompt, model id, token usage, latency, stop-reason, prompt hash, outcome) to the **0027 store**, keyed by `jobId` as the correlation id, best-effort (never fail the run on a logging error) (§6.3, §6.8).
- **FR-11 (reliability).** The pipeline MUST be **idempotent** by `(jobId, stage)` (re-running a stage overwrites its artifact, not appends), apply **bounded retries with backoff** on Bedrock throttling/transient errors, enforce **per-stage + overall timeouts**, and **dead-letter** terminal failures (ties 0032). Jobs MUST carry a **TTL** (jobs currently leak — no TTL).
- **FR-12 (offline/mock untouched).** The on-device `MockAIService` path and the inline local generation path MUST keep working with **no Step Functions / no agents** so first-run and tests stay offline (§9; `CLAUDE.md` invariant).

### Non-functional

- **NFR-1 (latency budget).** Full cold pipeline (miss) target **p50 ≤ 45 s, p95 ≤ 90 s**; **cache hit (personalize-only)** target **p50 ≤ 6 s, p95 ≤ 15 s**. The app shows phase progress throughout so perceived latency is bounded (§6.5). (Single-shot today is ~27 s for a far poorer artifact.)
- **NFR-2 (cost).** Track per-run **token usage + estimated USD** (0027/0032). A cold full generation should cost on the order of a handful of Opus calls; **the shared base is amortized across all users of a book** (0028), and the per-user personalize layer is a single small call. Budget alarms via 0032; only a true personalized re-gen consumes a credit (0023) (§6.9).
- **NFR-3 (security).** Bedrock via **IAM only, no API key** (invariant). Step Functions execution role + each stage Lambda role **least-privilege** (e.g. invoke only the specific model ARNs; Verifier needs no table write; the personalize-clone path needs read of the shared template prefix). User/book text is **tagged untrusted** before Bedrock (0030). Per-user S3 artifacts stay under `users/<sub>/` so `DELETE /v1/me` purges them (0027).
- **NFR-4 (privacy).** Transcripts may contain user answers/excerpts → user-scoped, lifecycle to IA/Glacier (0027), excluded from non-sensitive analytics props.
- **NFR-5 (no DDB floats).** Bloom weights, difficulty, XP, scores stored as **scaled ints or JSON strings** (invariant). The track JSON itself lives in **S3** (0027/0028) with a DDB **pointer**, dodging the 400 KB item limit.
- **NFR-6 (stdlib + boto3).** New Lambdas use **stdlib + boto3 only** (no packaging). Step Functions ASL is CDK-authored. black/flake8 clean; `cdk synth -c stage=beta` + `pytest` must pass offline (moto + monkeypatched Bedrock).
- **NFR-7 (rate-limit).** Generation is the most expensive call — it MUST sit behind the **0029** per-user/IP limiter + stage throttle + Budgets so it is not loop-callable (denial-of-wallet).

## 6. Design

### 6.1 Learning-science foundation (what makes the curriculum *good*)

The Curriculum Planner and Activity Designer are constrained by a small, explicit pedagogy model so output is defensible, not just well-shaped:

- **Backward design.** Plan from **objectives → assessment → activity**, not from "summarize the chapters." Each milestone declares **learning objectives** first; activities are then chosen to *evidence* those objectives ([IAMSE](https://www.iamse.org/websem/instructional-design-learning-objectives-backwards-design-blooms-taxonomy/), [DMU CME](https://cme.dmu.edu/content/aligning-beginning-and-end-instructional-design-bloom%E2%80%99s-taxonomy-and-backward-design)).
- **Bloom's taxonomy.** Every objective carries a **Bloom level** (`remember, understand, apply, analyze, evaluate, create`). The Designer maps level → activity type/modality (e.g. *remember/understand* → recall quiz / flashcard (0039/0040); *apply* → real-world application or scenario; *analyze/evaluate* → reflection / compare-contrast / conversational tutor (0041); *create* → make-something / teach-back / peer share (0043)) ([ASU LTH](https://lth.engineering.asu.edu/reference-guide/blooms-taxonomy/), [commlabindia](https://www.commlabindia.com/blog/blooms-taxonomy-in-instructional-design)).
- **Scaffolding.** Objectives are **sequenced low→high** Bloom across milestones; lesson-level objectives ladder up to milestone objectives ([Sage](https://sk.sagepub.com/hnbk/edvol/the-sage-handbook-of-higher-education-instructional-design/chpt/9-blooms-taxonomy-proposed-application-instructional)).
- **Retrieval + spaced practice.** The two highest-impact techniques in a 242-study, 169 k-participant meta-analysis are **practice testing** and **distributed practice** ([evidencebased.education](https://evidencebased.education/resource/retrieval-and-spaced-practice-study-strategies-that-must-be-combined/), [PMC retrieval](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC3983480/)). The Planner therefore (a) makes **active retrieval** the default activity spine and (b) **re-surfaces earlier concepts in later milestones** (a `spacedReview` activity that pulls a prior objective forward), which also feeds [`0016` insight review]. This is encoded as a `pedagogy` block the Planner must satisfy and the Verifier checks.

### 6.2 The agents (responsibilities, I/O)

Each agent is a **single Bedrock `invokeModel` call** with a focused system prompt and a strict JSON contract (built in a new `shared/prompts/` module, mirroring today's `prompts.py`). Models are right-sized per stage (config-driven `BEDROCK_MODEL_ID_*`): heavier reasoning (Planner, Verifier) can use Opus; lighter transforms (Researcher summarize, Personalizer curate) can use a cheaper/faster model.

| # | Agent | Reads | Produces | Notes |
|---|---|---|---|---|
| 1 | **Researcher** | book `{title, author, wordCount}` + excerpt/text (from S3 `contentRef`); **optional** grounding: a per-book **knowledge base** (Bedrock KB) or curated synopsis (0009), or a guarded web source. | `research.json`: `themes[]`, `keyConcepts[]` (concept + 1-line gloss), `realWorldApplications[]`, `audienceLevel`, `tone`. | Tool-use seam: KB retrieval is optional and **off the critical offline path**. Excerpt-only is the default and is sufficient (today's quality baseline). |
| 2 | **Curriculum Planner** | `research.json` + `pedagogy` constraints (§6.1) + target track size (default 4 milestones; configurable). | `plan.json`: `milestones[]` each `{ title, subtitle, objectives[] {text, bloom, sourceConcepts[]}, spacedReviewOf[] }`. | Backward design; Bloom-laddered; injects spaced-review links. |
| 3 | **Activity Designer** | `plan.json` + the **0039 type catalog** (allowed types + per-type schema + grading method) + **modality availability** flags (0040–0043) + user level hint. | `activities.json`: per objective, `lessons[]` → `activities[]` `{ typeId, modality, gradingMethod, xp, prompt|payload }` conforming to 0039. | One call may author per-milestone to bound token size; reflection sub-loop allowed if a type's schema fails. |
| 4 | **Personalizer** | the assembled **base track** (from Designer, or the cached 0028 base) + **0020 features** (`USER#<sub>` from `MangoFeatures`) + **0044 recommendation** output (preferred types/modalities, difficulty target). | `personalization.json`: an **overlay** — selected/reordered activity ids, per-activity difficulty, modality emphasis — **not** a re-authored track. | Thin layer → cache stays hot (§6.9). Cold features → identity overlay (= base). |
| 5 | **Verifier/QA** | the **resolved track** (base + overlay) + 0039 schemas + 0030 Guardrails. | `verdict.json`: `pass|fail`, `errors[]`, `bloomDistribution`, `difficultyBalance`, `safety{guardrailAction}`. On `fail` within budget → **repair** (re-invoke the offending stage with the verdict as feedback — reflection pattern) then re-verify; else mark job `failed`. | LLM-as-judge for qualitative checks; **deterministic** JSON-schema + Guardrails checks first (cheap floor) ([promptfoo JSON](https://www.promptfoo.dev/docs/guides/evaluate-json/), [Langfuse LLM-judge](https://langfuse.com/docs/evaluation/evaluation-methods/llm-as-a-judge)). |

### 6.3 Data flow + diagram

```mermaid
flowchart TD
    A["POST /v1/roadmaps/generate"] -->|persist pending job| J[(DDB job\nUSER#sub / ROADMAPJOB#id)]
    A -->|StartExecution name=jobId| SF{{Step Functions Standard\nstate machine}}
    A -->|202 jobId| C[iOS app]
    C -->|poll GET jobs/id| J

    subgraph SF [ ]
      direction TB
      CK{cache check 0028}
      CK -- hit --> P
      CK -- miss --> R[Researcher\nresearch.json]
      R --> CP[Curriculum Planner\nplan.json]
      CP --> AD[Activity Designer\nactivities.json]
      AD --> ASM[assemble base track\n+ write shared base 0028]
      ASM --> P[Personalizer\noverlay.json]
      P --> V[Verifier/QA\nverdict.json]
      V -- fail&budget --> REP[repair: re-invoke stage\nw/ verdict] --> V
      V -- pass --> DONE[resolve track\nwrite to S3 + DDB pointer]
      V -- fail&exhausted --> FAIL[mark failed]
    end

    R -. transcript+artifact .-> S3[(0027 artifact store\nusers/sub/roadmaps/id/*)]
    CP -. .-> S3
    AD -. .-> S3
    P -. .-> S3
    V -. .-> S3
    ASM -. shared base .-> S3T[(0028 templates\nbooks/id/v*.json)]
    DONE -->|status=complete + trackRef| J
    FAIL -->|status=failed + error| J

    AD <-->|type schemas| T039[(0039 taxonomy)]
    P <-->|features| FS[(0020 MangoFeatures)]
    P <-->|recs| R044[0044 recommender]
    V <-->|Guardrails| G030[0030]
```

Each stage updates the job's `status` (the progress vocabulary) **before** it begins, so the poll reflects live phase. Stage I/O is passed **by S3 reference** between Step Functions states (the optimized `bedrock:invokeModel` `Input`/`Output` S3 fields) to stay under the 256 KiB Bedrock payload / 256 KB state-payload limits ([connect-bedrock](https://docs.aws.amazon.com/step-functions/latest/dg/connect-bedrock.html)).

### 6.4 Orchestration — choice & tradeoffs

**Recommendation: AWS Step Functions *Standard* orchestrating Bedrock via the optimized `bedrock:invokeModel` integration (Lambda only where glue/parse is needed).**

Why this over the three alternatives:

| Option | Fit for Mango | Verdict |
|---|---|---|
| **A. Current single async Lambda** (`roadmap_worker`) | One call, 60 s budget, **no DLQ/retry/idempotency/observability** (`ARCHITECTURE_REVIEW.md` G6/G7); cannot host a 5-stage + reflection pipeline within 15 min reliably; no per-stage trace. | **Insufficient** for a multi-agent, verified pipeline. |
| **B. Step Functions Standard + `bedrock:invokeModel`** *(chosen)* | **Deterministic, ordered, auditable** — exactly what a backward-designed curriculum needs; **1-yr duration / exactly-once / full state trace** ([choosing-workflow-type](https://docs.aws.amazon.com/step-functions/latest/dg/choosing-workflow-type.html)); built-in **Retry/Catch**, parallelism, and **S3 payload offload**; calls Bedrock **without Lambda glue** ([connect-bedrock](https://docs.aws.amazon.com/step-functions/latest/dg/connect-bedrock.html)); AWS Prescriptive Guidance recommends SFN for **deterministic, auditable** flows ([orchestration-models](https://docs.aws.amazon.com/prescriptive-guidance/latest/agentic-ai-serverless/orchestration-models.html)). Stays **stdlib+boto3** (ASL in CDK; thin parse Lambdas). | **Best fit.** |
| **C. Bedrock multi-agent collaboration** (supervisor + ≤10 collaborators, GA Mar 2025) | Great for **dynamic, conversational** delegation; supervisor *reasons* about routing. But our flow is **fixed and ordered**, we want **explicit control + full audit**, and it adds an agent-runtime surface (and weaker state trace) we don't need here ([MAC GA](https://aws.amazon.com/blogs/machine-learning/amazon-bedrock-announces-general-availability-of-multi-agent-collaboration/), [MAC docs](https://docs.aws.amazon.com/bedrock/latest/userguide/agents-multi-agent-collaboration.html)). **Revisit for 0041** (conversational tutor) where dynamic routing fits. | Defer (better for 0041). |
| **D. Bedrock Flows** (visual node graph: prompt/KB/Guardrail/Lambda/condition nodes, GA) | Excellent for a **mostly-linear prompt chain** with KB + Guardrail nodes and immutable versioned deploy ([Flows](https://aws.amazon.com/bedrock/flows/), [Flows docs](https://docs.aws.amazon.com/bedrock/latest/userguide/flows.html)). Viable **alternative**; we prefer SFN for first-class **Retry/Catch/idempotency/DLQ + CloudWatch state trace + cost-metric hooks** and because the team already operates CDK/Lambda. | **Strong runner-up.** |

**How B fits today's contract.** The POST handler swaps `lambda.invoke(Event)` for **`states:StartExecution`** with `name=jobId` (idempotency: re-POST of the same job is a no-op duplicate-execution error we treat as "already running"). The state machine writes `status` transitions to the **same job row** the poll reads. **No iOS change** beyond the larger status enum. The inline/offline path is unchanged (no SFN locally).

### 6.5 Progress state machine (the poll vocabulary)

```
pending ──▶ researching ──▶ planning ──▶ designing ──▶ personalizing ──▶ verifying ──▶ complete
   │            │              │            │               │               │   ╰─(repair loop)─╮
   ╰────────────┴──────────────┴────────────┴───────────────┴───────────────┴── failed ◀────────╯
                          (cache hit skips straight to ── personalizing ──▶ verifying ──▶ complete)
```

- The job row gains `status` (above), `phaseUpdatedAt`, and a small `progress` int (0–100, monotonic) for a determinate-ish bar.
- iOS maps each phase to friendly copy ("Researching the book…", "Designing your activities…", "Personalizing for you…", "Final checks…"). Unknown future phases fall back to a generic "Working…" (forward-compat).
- Backward-compat: a client that only knows `pending|complete|failed` still works (it ignores intermediate phases and waits for a terminal state).

### 6.6 Output schema (versioned track — base + per-user layer)

Stored in **S3** (per 0027/0028), DDB holds a **pointer**. `schemaVersion` lets the decoder evolve. Numbers are ints (XP, bloom weight ×100, difficulty 1–5). The **shared base** (`books/<id>/templates/<ver>.json`, 0028) is user-agnostic; the **personalization overlay** (`users/<sub>/roadmaps/<id>/overlay.json`) is thin; the app receives the **resolved** track (base ⊕ overlay) on completion.

```jsonc
{
  "schemaVersion": 2,
  "trackId": "trk_…",
  "bookId": "pg-2680",
  "promptVersion": "0038.1",
  "modelId": "…opus…",
  "generatedAt": "2026-06-28T…Z",
  "title": "…", "summary": "…",
  "pedagogy": { "model": "backward-design", "spacedReview": true },
  "milestones": [
    {
      "id": "m1", "title": "…", "subtitle": "…",
      "objectives": [
        { "id": "o1", "text": "Explain the habit loop", "bloom": "understand",
          "sourceConcepts": ["cue-routine-reward"], "spacedReviewOf": [] }
      ],
      "lessons": [
        {
          "id": "l1", "title": "…", "orientation": "Read §1 in your own copy…",
          "estimatedMinutes": 8,
          "activities": [
            { "id": "a1", "objectiveId": "o1",
              "typeId": "recall_quiz",        // ── references a 0039 taxonomy type
              "modality": "text",             // text|audio|visual|conversational|external|peer (0040–0043)
              "gradingMethod": "exact_choice",// defined by the 0039 type
              "xp": 15,
              "difficulty": 2,                // 1–5; set/overridden by Personalizer
              "payload": { "prompt": "…", "options": ["…"], "answerIndex": 0 } },
            { "id": "a2", "objectiveId": "o1",
              "typeId": "real_world_application", "modality": "external",
              "gradingMethod": "llm_rubric", "xp": 40, "difficulty": 3,
              "payload": { "prompt": "Try the 2-minute rule today and report back…" } }
          ]
        }
      ]
    }
  ]
}
```

- **0039 reference is by id, not embedding** the type definition — the engine only needs `typeId + gradingMethod + modality + xp`; the renderer (0039/0040–0043) owns presentation/grading.
- **Overlay shape** (`overlay.json`): `{ trackId, userSub, selectedActivityIds[], difficultyById{}, modalityEmphasis, order[] }`. Resolve = apply overlay to base; absent overlay = base.
- **Forward/back-compat:** old `4×2×2` roadmaps (no `schemaVersion`, `exercises[]` with `kind`) are decoded by a shim (`kind→typeId`, `quiz/reflection/application` → the three seed 0039 types) so existing on-device/job data still renders (§9).

### 6.7 Data & contract

**DDB (single table, float-free).**
- Job (extended): `PK=USER#<sub>`, `SK=ROADMAPJOB#<jobId>` — add `status` (new enum), `phaseUpdatedAt`, `progress:int`, `executionArn`, `trackRef` (S3 key of resolved track), `trackId`, `ttl:int`. The full track is **not** inlined (400 KB limit) — `trackRef` points to S3 (0027).
- Shared base pointer (0028, now actually written): `PK=BOOK#<id>`, `SK=ROADMAP#latest` → `{ ver, trackRef, outline, promptVersion, modelId }`; `SK=ROADMAP#v<ver>` history. Cache key `sha256(promptVersion+modelId+excerptHash)`.
- Artifact index (0027): `PK=USER#<sub>`, `SK=ARTIFACT#<jobId>#<stage>` → S3 key + meta (model, tokens, latency, cost-est, stop-reason).

**S3 (0027/0028 layout).**
- Per-user (purged by `DELETE /v1/me`): `users/<sub>/roadmaps/<jobId>/{research.json, plan.json, activities.json, overlay.json, verdict.json, track.json}` + `…/transcripts/<stage>.json`.
- Shared per-book: `books/<id>/templates/<ver>.json` (the base track) + `books/<id>/provenance.json`.

**Endpoints (openapi notes — keep `openapi.yaml` ⇄ `DTOs.swift` ⇄ handlers in sync).**
- `POST /v1/roadmaps/generate` — **unchanged request** (inline `book` or `bookId`, optional `profile`); **response still `202 RoadmapJob`**. Doc: now starts a Step Functions execution; behaviour is cache-aware (0028).
- `GET /v1/roadmaps/jobs/{jobId}` — **same shape**, `status` enum extended; when `complete`, returns the **resolved track** (or a `trackRef`/inline per size). Add `progress` + `phase` fields (optional, additive).
- Schemas: extend `RoadmapJob.status` enum; add `Track`/`Milestone`/`Activity` schemas (superset of the legacy `Roadmap`); keep the legacy `Roadmap` schema for back-compat decode. No new required fields on the request → **no breaking change**.

**iOS consumption.** `RoadmapGenerator`/`APIClient` already POST→poll. Changes: (1) decode the **extended status** and show **phase copy + progress** (new `RoadmapJobStatus` cases, lenient — unknown → "working"); (2) decode the **richer track** via a `TrackDTO` that is a superset of `RoadmapDTO`, with the §9 shim so old payloads still build the existing `Roadmap→Milestone→Lesson→Exercise` graph; activity `typeId/modality/gradingMethod` map onto the 0039-aware activity model (0011/0039). No change to the generate request, gamification, or offline path.

### 6.8 Observability (ties 0027/0032)

- `jobId` is the **correlation id** end-to-end (POST → each SFN state → poll); structured JSON logs per stage with `{model, latencyMs, inputTokens, outputTokens, estUsdMicros, promptHash, stopReason, outcome}` (cost as **int micro-USD** — float-free).
- **CloudWatch metric filters + alarms** (via 0032): pipeline failure rate, `stopReason=max_tokens` truncation, Verifier `fail` rate, per-stage p95 latency, **per-run token/cost** + **AWS Budgets**. Step Functions gives the **state-machine execution history** for free (per-stage timing, retries, the failing state).
- The 0027 artifact index powers "show everything generated for this user/job."

### 6.9 Cost & credits (ties 0023/0028)

- **Shared base = amortized & free to view/clone.** First open of a book pays the full pipeline **once** (under 0028's single-flight lock) and writes the shared base; all later users **clone** it and run **only** the Personalizer (one small call) — so the cache stays ~100% hot and **cloning the base costs no credit** (resolves the 0020⇄0023 tension noted in `ARCHITECTURE_REVIEW.md` §2.3).
- **Credits (0023) are charged only for a *true personalized re-generation*** — when a user explicitly requests a fresh, fully-personalized track (full pipeline, not a clone) — or for premium modality generation if 0023 decides so. The default Start-journey flow on a cached book is **free**.
- **Pre-warm.** A batch Lambda (0028 + 0009) pre-generates bases for the curated catalog so popular books ship **warm** (no first-user latency or cost spike).
- Per-run cost is **tracked and alarmed** (§6.8); model right-sizing per stage (§6.2) keeps cold-generation cost bounded.

## 7. Acceptance criteria

- [ ] **AC-1 (pipeline runs end-to-end).** A cold generation executes Researcher→Planner→Designer→Personalizer→Verifier and produces a valid resolved track; the job ends `complete` with a `trackRef`. *(SFN integration test with mocked Bedrock — §8.)*
- [ ] **AC-2 (contract preserved).** `POST /v1/roadmaps/generate` returns `202 {jobId,status}`; `GET …/jobs/{jobId}` returns the job; the status passes through `researching…verifying` to `complete`; a legacy client reading only `pending|complete|failed` still succeeds. *(Handler + DTO tests.)*
- [ ] **AC-3 (schema-valid output).** Every generated track validates against the §6.6 schema **and** each activity against its 0039 type schema; the Verifier rejects an intentionally malformed track. *(Schema-validity eval — §8.)*
- [ ] **AC-4 (pedagogy).** Each milestone has ≥1 objective with a valid Bloom level; Bloom levels ladder non-decreasing across milestones (scaffolding); ≥1 `spacedReview` activity re-surfaces an earlier objective. *(Plan-structure assertions.)*
- [ ] **AC-5 (modality variety).** A generated track for a book with all modalities enabled contains **≥2 distinct modalities**; with modalities disabled it degrades to text-only without error. *(Designer test under availability flags.)*
- [ ] **AC-6 (personalization layer).** With seeded 0020 features + a stub 0044 rec, the Personalizer produces an overlay that demonstrably changes difficulty/order/modality vs the base; with **cold** features the overlay is identity (= base). *(Personalizer unit test.)*
- [ ] **AC-7 (verify gate).** A track failing schema/difficulty/safety triggers a bounded repair then re-verify; if still failing, the job ends `failed` and **no track is exposed**. 0030 Guardrails block a denied-topic injection. *(Verifier + Guardrails-stub test.)*
- [ ] **AC-8 (cache-aware).** Second generation of the same book+promptVersion **skips** Researcher/Planner/Designer (cache hit), runs personalize-only, and returns within the hit latency budget; the shared base is written exactly once under the single-flight lock. *(0028 integration test.)*
- [ ] **AC-9 (reliability).** A simulated Bedrock throttle on one stage is retried with backoff and succeeds; a terminal failure dead-letters and marks the job `failed`; re-`StartExecution` with the same `jobId` does not double-run. Jobs have a TTL. *(SFN Retry/Catch + idempotency test.)*
- [ ] **AC-10 (artifacts + observability).** Each stage writes its artifact + transcript to the 0027 store keyed by `jobId`, with token/latency/cost-est logged; a logging failure does **not** fail the run. *(Artifact-write test, best-effort assertion.)*
- [ ] **AC-11 (cost/credits).** Cloning a cached base consumes **no** credit; a true personalized re-gen consumes one (0023 stub). Per-run cost metric is emitted. *(Credit-hook + metric test.)*
- [ ] **AC-12 (offline/mock untouched).** Fresh install, Mock AI, no network: Start-journey builds a track with **no** Step Functions/agents; `make ios-test` green; backend `pytest` + `cdk synth -c stage=beta` green. *(Offline run + CI.)*
- [ ] **AC-13 (invariants).** No DDB floats anywhere in the new items; new Lambdas are stdlib+boto3; least-privilege IAM (Verifier has no table write; clone path reads only the template prefix); black/flake8 clean. *(Synth + lint + IAM review.)*

## 8. Test plan

- **Unit (backend, pytest + moto + monkeypatched Bedrock):**
  - **Prompt builders** (`shared/prompts/*`): each agent's system/user prompt is stable and asks for strict JSON (golden-string tests, mirroring today's prompt tests).
  - **Stage parsers:** `research/plan/activities/overlay/verdict` JSON → typed dicts; tolerant `extract_json`; truncation/`max_tokens` handled.
  - **Schema-validity eval (AC-3):** a vendored JSON-schema (stdlib `jsonschema`-style validator or a hand-rolled stdlib check — no new packaged dep) for the track + a fixture of valid/invalid activities per seed 0039 type; the Verifier's deterministic floor must accept valid and reject each invalid mutation.
  - **Pedagogy assertions (AC-4):** on a fixture `plan.json`, Bloom present + non-decreasing across milestones; spaced-review link resolves to an earlier objective.
  - **Personalizer (AC-6):** seeded features+rec → overlay diff; cold → identity.
  - **Verifier repair loop (AC-7):** inject a failing verdict → one repair re-invocation → pass; exhaust budget → `failed`. Guardrails stub blocks denied topic.
  - **Idempotency/TTL (AC-9):** duplicate `StartExecution(name=jobId)` handled; job carries `ttl`.
- **Integration (backend, mocked Bedrock per stage):**
  - **Full pipeline (AC-1):** drive the state machine logic with a local executor (Step Functions Local in CI, or a Python harness that runs the stage handlers in ASL order) and stubbed per-stage Bedrock responses; assert the resolved track + final `complete`.
  - **Cache hit (AC-8):** pre-seed a 0028 base → second run skips heavy stages → personalize-only path + latency budget; single-flight writes base once.
  - **Reliability (AC-9):** stub a throttling `ClientError` on one stage → Retry succeeds; terminal error → Catch → DLQ + `failed`.
- **Eval harness (quality, offline, CI-gated soft):** a small **golden-book set** (2–3 public-domain books) run through the pipeline with recorded/mocked Bedrock; assert structural + pedagogy + modality-variety invariants (the schema-validity + Bloom + spaced-review + ≥2-modality checks). LLM-as-judge scoring of *qualitative* track quality is **logged, not gating** initially (deeplearning.ai / Langfuse pattern) to avoid flaky CI.
- **iOS (unit + manual):** `TrackDTO` decodes the new schema **and** the legacy `4×2×2` payload (shim); `RoadmapJobStatus` decodes the extended enum leniently; manual: phase progress copy through a real generation; offline Mock path still builds a journey.
- **Synth/regression:** `cdk synth -c stage=beta` (the new SFN stack), `pytest` (existing 29 + new), `make ios-test` — all green offline.

## 9. Rollout & migration

- **Flags / config.** `AI_ENGINE=agentic|single` (default `single` until the AC suite is green, then flip to `agentic` in beta first). `BEDROCK_MODEL_ID_*` per stage. Modality availability flags (gate 0040–0043 as they land). `KB_GROUNDING=off` by default (Researcher excerpt-only).
- **Backward compatibility.**
  - **Contract:** request unchanged; status enum is **additive**; old clients tolerate it (§6.5).
  - **Data:** legacy roadmaps (no `schemaVersion`) decode via the **shim** (`exercises[].kind` → seed `typeId`s, defaults: `modality:"text"`, `gradingMethod` per kind, XP preserved). No data migration required; the shim lives in `DTOs.swift` and the backend `Track` parser.
  - **Offline/mock:** untouched (no SFN locally; inline generation still produces a (now shim-compatible) roadmap).
- **Stages of rollout.** (1) Land the SFN stack + stage Lambdas behind `AI_ENGINE=single` (no traffic). (2) Turn on `agentic` in **beta**, dark-launch with the **eval harness** + 0027 transcripts + 0032 alarms watching. (3) **Pre-warm** the 0009 catalog bases (0028) so beta users hit warm cache. (4) Promote to prod after latency/cost/quality SLOs hold; keep `single` as a **kill-switch** for one release. (5) Remove `single` + dead single-shot worker once stable.
- **Teardown / cost control.** Pause pre-warm + flip to `single` instantly via flag if Bedrock cost spikes (0032 Budgets alarm). Job TTL reaps old rows; S3 lifecycle (0027) ages transcripts to IA/Glacier.
- **Sequencing.** Depends on **0027** (artifact store/observability) and **0028** (cache + single-flight) landing first or alongside; **0039** (at least the seed type catalog + schemas) is required for the Designer; **0030** for the Verifier safety gate; **0020/0044** for the Personalizer (degrades to identity overlay until they ship); **0023/0029** for credits/rate-limit. This umbrella can land **incrementally**: ship the pipeline with a minimal 0039 seed set + identity Personalizer + schema/Guardrails-only Verifier, then enrich each stage as its sibling spec lands.

## 10. Risks & open decisions

- **R-1 Latency (5 calls + reflection > 1 shot).** *Mitigation:* per-stage model right-sizing (§6.2), **cache hit = personalize-only** (the common path after pre-warm), parallel-where-safe states, phase progress so perceived latency is bounded, hard per-stage timeouts. Worst-case full cold p95 ≤ 90 s (NFR-1) but rare once warm.
- **R-2 Cost (more Bedrock calls).** *Mitigation:* shared base amortized across all users of a book (0028); per-user layer is one small call; pre-warm batches; **token/cost metric + Budgets** (0032); credits only for true re-gen (0023). Right-size cheaper models for Researcher/Personalizer.
- **R-3 Quality regression / agent drift.** *Mitigation:* the **Verifier gate** (schema + difficulty + safety) blocks bad tracks; the **eval harness** (golden books) catches structural/pedagogy regressions in CI; transcripts (0027) make any bad output diagnosable; reflection/repair loop fixes recoverable failures.
- **R-4 Bedrock quotas/throttling on a multi-stage burst.** *Mitigation:* SFN **Retry with backoff**, bounded concurrency, 0029 rate-limit upstream so generation isn't loop-callable; request **provisioned throughput** if volume warrants (config seam).
- **R-5 Schema coupling to 0039.** *Risk:* Designer output must match 0039 type schemas that may evolve. *Mitigation:* reference types **by id**; version the type catalog; Verifier validates against the **current** catalog; `promptVersion` invalidates cache on change.
- **R-6 Step Functions/CDK + stdlib constraint.** *Mitigation:* ASL authored in CDK; stage logic stays **stdlib+boto3** thin Lambdas (or pure `bedrock:invokeModel` tasks where no glue is needed); validator vendored without a packaged dep (NFR-6).
- **R-7 Big payloads between stages.** *Mitigation:* pass by **S3 reference** (the optimized integration's `Input`/`Output` S3 fields) not inline state (256 KiB/256 KB limits).
- **Decisions needed (with recommendations):**
  - **D-1 (recommend: Step Functions Standard).** Standard vs Express — Standard for duration/exactly-once/full trace (§6.4); Express's 5-min/at-least-once is wrong for a verified, auditable pipeline.
  - **D-2 (recommend: SFN over Bedrock Flows for v1).** Flows is a strong runner-up; choose SFN for first-class Retry/Catch/idempotency/DLQ + CloudWatch state trace + cost hooks and existing CDK/Lambda ops. Re-evaluate Flows if the pipeline becomes mostly-linear prompt-chaining with KB+Guardrail nodes.
  - **D-3 (recommend: reserve Bedrock multi-agent collaboration for 0041).** Use the supervisor/collaborator model where **dynamic** routing fits (the conversational tutor), not for this deterministic flow.
  - **D-4 (recommend: personalize-on-clone, not in-prompt).** Personalization is a **thin overlay** over the cached base (keeps cache hot, §6.9) rather than injected into the generation prompt; a full personalized re-gen is the paid exception.
  - **D-5 (recommend: incremental landing).** Ship the engine with a seed 0039 set + identity Personalizer + schema/Guardrails Verifier, then enrich per sibling spec — rather than blocking on all of 0039–0044.
  - **D-6 (recommend: KB grounding off by default).** Researcher is excerpt-only on the critical path; optional per-book Bedrock KB / curated synopsis (0009) is a config-gated enhancement, never a hard dependency.

## 11. Tasks & estimate

1. **Define the stage contracts** (`research/plan/activities/overlay/verdict` + the §6.6 `Track`) as JSON schemas + a vendored stdlib validator. **(M)**
2. **Prompt builders** for the 5 agents in `shared/prompts/` (system + user, strict-JSON), with the §6.1 pedagogy constraints baked into Planner/Designer. **(M)**
3. **Stage handlers** (thin Lambdas / `bedrock:invokeModel` tasks): Researcher, Planner, Designer, Personalizer, Verifier — each idempotent by `(jobId, stage)`, artifact+transcript write to 0027 (best-effort), token/cost logging. **(L)**
4. **Step Functions Standard state machine** (CDK): cache-check branch (0028), the 5 stages with **Retry/Catch + backoff**, the Verifier **repair loop**, terminal success/fail → job row; S3 payload offload; **least-privilege** execution role (per-model ARNs). **(L)**
5. **Rework `generate_roadmap.py`**: `StartExecution(name=jobId)` instead of `lambda.invoke(Event)`; keep the inline/offline fallback; cache-aware clone path (0028). **(M)**
6. **Extend `roadmap_jobs.py`**: new `status` enum + `phase/progress/executionArn/trackRef/trackId/ttl`; resolve-track read (S3 pointer); shim to decode legacy `4×2×2`. **(M)**
7. **Write the shared base + pointer** (0028 seam): `BOOK#<id>/ROADMAP#latest|v<ver>` + `templates/<ver>.json`; single-flight lock; cache key. **(M)**
8. **0027 wiring**: artifact index items + S3 layout + lifecycle; correlation-id logging. **(M)**
9. **0032 wiring**: CloudWatch metric filters/alarms (failure rate, truncation, Verifier-fail, p95, token/cost), DLQ, Budgets hook. **(M)**
10. **0030 gate** in the Verifier: input tagging + Guardrails invoke + denied-topic/disclaimer handling. **(M)** *(depends on 0030)*
11. **0020/0044 seam** in the Personalizer: read `MangoFeatures`, call the recommender; identity overlay on cold. **(M)** *(depends on 0020/0044)*
12. **0023 hook**: charge a credit only on true personalized re-gen; free clone. **(S)** *(depends on 0023)*
13. **openapi.yaml**: extend `RoadmapJob.status`, add `Track/Milestone/Activity` schemas, keep legacy `Roadmap`; note SFN + cache behavior. **(S)**
14. **iOS**: `TrackDTO` (superset + legacy shim), extended `RoadmapJobStatus` (lenient), phase progress copy + progress bar in the generate flow. **(M)**
15. **Tests**: unit (parsers, schema-eval, pedagogy, personalizer, verifier/repair, idempotency), integration (full pipeline + cache hit + reliability via SFN Local/harness), eval harness (golden books), iOS DTO decode (new + legacy). **(L)**
16. **Eval harness + golden-book fixtures** + CI job (structural/pedagogy gating; LLM-judge logged-not-gating). **(M)**
17. **Rollout**: `AI_ENGINE` flag, pre-warm batch for 0009 catalog, beta dark-launch + SLO watch, kill-switch, then remove single-shot. **(M)**

*Total: roughly 2 L + 9 M + 2 S of backend + 1 M iOS, landable incrementally behind `AI_ENGINE`.*

## 12. References

**Repo (read for accuracy):** `CLAUDE.md`; `docs/ARCHITECTURE.md`; `working/INDEX.md`; `working/ARCHITECTURE_REVIEW.md` (§1 as-built, §2.2 artifacts/0027, §2.3 cache/0028, G6/G7 worker reliability); `working/0008-product-reframe-activity-first.md` (activity-first pivot; the ≤12 k excerpt grounding fact); `working/0020-feature-store-personalization.md` (the personalization consumer seam). Backend: `src/handlers/{generate_roadmap.py, roadmap_worker.py}`, `src/shared/{agent.py, prompts.py, roadmap_jobs.py, storage.py}`; contract `shared/api/openapi.yaml` (`RoadmapRequest`, `RoadmapJob`). **Sibling cluster (referenced):** `0039-activity-type-framework`, `0040-multimodal-activities`, `0041-conversational-tutor-activities`, `0042-external-engagement-activities`, `0043-peer-and-human-activities`, `0044-personalization-recommendation-engine`; dependencies `0026`, `0027`, `0028`, `0030`, `0023`, `0029`, `0032`.

**Research (web):**
- AWS — *Orchestration models: rule-based (Step Functions) vs AI-native (Bedrock Agents)* (deterministic/auditable → SFN; dynamic/conversational → Agents) — https://docs.aws.amazon.com/prescriptive-guidance/latest/agentic-ai-serverless/orchestration-models.html
- AWS — *Invoke and customize Amazon Bedrock models with Step Functions* (`bedrock:invokeModel`, `.sync`, S3 `Input`/`Output` payload offload, least-privilege IAM) — https://docs.aws.amazon.com/step-functions/latest/dg/connect-bedrock.html
- AWS — *Choosing a workflow type in Step Functions* (Standard = 1-yr, exactly-once, full trace; Express = 5-min, at-least-once) — https://docs.aws.amazon.com/step-functions/latest/dg/choosing-workflow-type.html
- AWS — *Amazon Bedrock announces GA of multi-agent collaboration* (supervisor + ≤10 collaborators; parallel delegation) — https://aws.amazon.com/blogs/machine-learning/amazon-bedrock-announces-general-availability-of-multi-agent-collaboration/
- AWS — *Use multi-agent collaboration with Amazon Bedrock Agents* (supervisor/routing modes, collaborator limits) — https://docs.aws.amazon.com/bedrock/latest/userguide/agents-multi-agent-collaboration.html
- AWS — *Build an end-to-end generative AI workflow with Amazon Bedrock Flows* (visual nodes: prompt/KB/Guardrail/Lambda/condition; versioned immutable deploy) — https://docs.aws.amazon.com/bedrock/latest/userguide/flows.html
- Phil Schmid — *Zero to One: Learning Agentic Patterns* (planner→worker→synthesizer, tool-use, reflection) — https://www.philschmid.de/agentic-pattern
- DeepLearning.AI — *Agentic Design Patterns: Reflection* (critic/verifier self-review improves reliability) — https://www.deeplearning.ai/the-batch/agentic-design-patterns-part-2-reflection
- IAMSE — *Instructional Design: Learning Objectives, Backward Design, Bloom's Taxonomy* (plan backward from objectives; Bloom-tag) — https://www.iamse.org/websem/instructional-design-learning-objectives-backwards-design-blooms-taxonomy/
- ASU LTH — *Bloom's Taxonomy* (the six cognitive levels; scaffolding objectives) — https://lth.engineering.asu.edu/reference-guide/blooms-taxonomy/
- Evidence Based Education — *Retrieval and Spaced Practice must be combined* (242-study meta-analysis: practice testing + distributed practice are the top techniques) — https://evidencebased.education/resource/retrieval-and-spaced-practice-study-strategies-that-must-be-combined/
- NCBI/PMC — *Retrieval practice enhances new learning (forward testing effect)* — https://www.ncbi.nlm.nih.gov/pmc/articles/PMC3983480/
- Promptfoo — *Evaluate JSON outputs* / Langfuse — *LLM-as-a-Judge* (deterministic schema floor first, then rubric LLM-judge — the Verifier model) — https://www.promptfoo.dev/docs/guides/evaluate-json/ · https://langfuse.com/docs/evaluation/evaluation-methods/llm-as-a-judge
