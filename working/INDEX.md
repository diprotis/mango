# Mango feature backlog — `working/` INDEX

**37 numbered, Draft feature specs (0008–0044)** for everything planned but not yet
implemented. Each follows [`../docs/specs/SPEC_TEMPLATE.md`](../docs/specs/SPEC_TEMPLATE.md)
(12 sections), is grounded in the real codebase, and is written to implementation
grade (concrete schemas, endpoints, Bedrock/iOS types, acceptance criteria mapped to
tests, file lists, task sizes). Numbering continues the *shipped* specs in
[`../docs/specs/`](../docs/specs/) (0001–0007). The gap analysis behind 0026–0037 is in
[`ARCHITECTURE_REVIEW.md`](ARCHITECTURE_REVIEW.md).

Workflow: review → flip status to **Approved** → implement in small PRs against the
acceptance criteria → move into `docs/specs/` with the number when shipped. Keep
`shared/api/openapi.yaml` ⇄ DTOs ⇄ handlers in sync (CLAUDE.md).

## Coverage of requested work

| Your ask | Spec(s) |
|---|---|
| App icon — Claude-style mark with a **literal mango** | [0012](0012-app-icon-redesign.md) |
| No keyboard emojis → **theme icons**; style refactor | [0013](0013-design-system-iconography-gamification.md) |
| **Onboarding** swipe / animated | [0010](0010-onboarding-redesign.md) |
| **Catalog ≥100 books**; **not a reading app** (remove reader); activities + journey; "what to read" = activity | [0008](0008-product-reframe-activity-first.md), [0009](0009-catalog-expansion-100-books.md) |
| **Remove Journey shortcut**; swipe-based activities | [0011](0011-navigation-and-activity-interaction.md) |
| Minimalist + **more gamified** | [0013](0013-design-system-iconography-gamification.md), [0011](0011-navigation-and-activity-interaction.md) |
| **Payments + credits** (buy / earn to generate roadmaps) | [0023](0023-payments-and-credits.md) |
| **Rewards** (coupons, trips), gamified | [0024](0024-rewards-and-coupons.md) |
| **Notifications** for all updates | [0025](0025-notifications.md) |
| **Agentic, multi-modal, personalized roadmap engine** + activity types (MCQ/quiz/puzzle/long-answer/voice/video/image/external/peer) + **gen-AI recommendation system** | [0038](0038-agentic-roadmap-engine.md)–[0044](0044-personalization-recommendation-engine.md) |
| User data + progress **tracking** in DDB | [0026](0026-server-side-activity-achievement-tracking.md) |
| Roadmap **assets + Q&A + responses in S3** + logging | [0027](0027-generation-artifact-store-observability.md) |
| Per-book catalog activities **cached** & shared | [0028](0028-shared-book-roadmap-cache.md) |
| (architecture-review hardening) | [0029](0029-edge-protection-rate-limiting.md)–[0037](0037-transactional-email-ses.md) |

## 1. Immediate UI / product pivot — M11

| # | Spec | Depends |
|---|---|---|
| [0008](0008-product-reframe-activity-first.md) | Activity-first reframe (remove in-app reader) | keystone |
| [0009](0009-catalog-expansion-100-books.md) | Catalog → 100+ public-domain books | 0008 |
| [0010](0010-onboarding-redesign.md) | Onboarding redesign (swipe, animated) | 0008 |
| [0011](0011-navigation-and-activity-interaction.md) | Nav cleanup + swipe activity loop | 0008 |
| [0012](0012-app-icon-redesign.md) | App icon (mango-in-spark) | — |
| [0013](0013-design-system-iconography-gamification.md) | Design system: iconography + gamification | — |

## 2. Engagement, content, identity & monetization

| # | Spec | Epic | Depends |
|---|---|---|---|
| [0014](0014-progress-sync.md) | Progress sync (reinstall/multi-device) | M5 | sign-in |
| [0015](0015-analytics-events-ios.md) | iOS analytics events → lake | M9 | — |
| [0016](0016-insight-review.md) | Insight Review (spaced repetition) | M6 | 0008 |
| [0017](0017-pdf-background-parsing.md) | PDF/EPUB parsing off main thread | M7 | 0008 |
| [0018](0018-epub-import.md) | EPUB import | M7 | 0017 |
| [0019](0019-native-apple-signin.md) | **Sign-in (ship now) + native Apple** | M3 | **first** |
| [0020](0020-feature-store-personalization.md) | Feature store + personalization | M9 | 0015 |
| [0021](0021-social-leagues.md) | Social leagues, friends & buddies | M8 | 0014 |
| [0022](0022-app-store-prep.md) | App Store submission readiness | M10 | many |
| [0023](0023-payments-and-credits.md) | Payments & credits (StoreKit IAP + ledger) | M12 | 0019 |
| [0024](0024-rewards-and-coupons.md) | Rewards & coupons (gamified) | M13 | 0023 |
| [0025](0025-notifications.md) | Notifications (local + APNs/SNS push) | M14 | 0015 |

## 3. Agentic learning engine (flagship) — M15/M16

The agentic, multi-modal, personalized roadmap system. **[0038](0038-agentic-roadmap-engine.md) is
the umbrella architecture** (Step Functions orchestrating Researcher → Curriculum
Planner → Activity Designer → Personalizer → Verifier on Bedrock); the rest are components.

| # | Spec | What it adds |
|---|---|---|
| [0038](0038-agentic-roadmap-engine.md) | **Agentic roadmap engine** — multi-agent Bedrock pipeline that curates personalized tracks |
| [0039](0039-activity-type-framework.md) | **Activity type framework** — the 11-kind taxonomy + grading/verification contract |
| [0040](0040-multimodal-activities.md) | **Multi-modal** — voice/video/image capture + Bedrock (Transcribe / Claude vision / Nova) grading |
| [0041](0041-conversational-tutor-activities.md) | **Conversational tutor** — Socratic back-and-forth (text + voice) |
| [0042](0042-external-engagement-activities.md) | **External** — X/social posting + YouTube/article consumption, verified & rewarded |
| [0043](0043-peer-and-human-activities.md) | **Peer & human** — facilitator interviews / peer sessions (safety-gated) |
| [0044](0044-personalization-recommendation-engine.md) | **Gen-AI recommendation engine** — hybrid recsys + LLM re-ranker curating each track |

Depends on: 0020 (features), 0026 (history), 0027 (artifacts), 0028 (cache), 0030 (safety),
0023 (credits), 0031 (age-gating for external/peer), 0021 (social graph for peers).

## 4. Architecture hardening (from the review) — M9/M13/M14

| # | Spec | Addresses |
|---|---|---|
| [0026](0026-server-side-activity-achievement-tracking.md) | Server-side activity & achievement tracking | concern #1 |
| [0027](0027-generation-artifact-store-observability.md) | Generation artifact store & LLM observability | concern #2 |
| [0028](0028-shared-book-roadmap-cache.md) | Shared per-book roadmap cache & activity templates | concern #3 |
| [0029](0029-edge-protection-rate-limiting.md) | Edge protection & rate-limiting (denial-of-wallet) | G1 |
| [0030](0030-ai-safety-guardrails.md) | AI safety: Guardrails, input tagging, disclaimers | G2 |
| [0031](0031-age-assurance-coppa.md) | Age assurance & COPPA/kids compliance | G4 |
| [0032](0032-observability-cost-reliability.md) | Observability, cost guardrails & worker reliability | G5–G7 |
| [0033](0033-data-export-and-deletion.md) | Data export (DSAR) & deletion completeness | G8/G9 |
| [0034](0034-admin-support-console.md) | Admin & support console (internal) | G10 |
| [0035](0035-remote-config-flags.md) | Remote config & feature flags | G11 |
| [0036](0036-localization-foundation.md) | Localization foundation | G13 |
| [0037](0037-transactional-email-ses.md) | Transactional email (Amazon SES) | G15 |

## Suggested sequencing

1. **Unblock:** ship **0019** sign-in (gates everything server-side).
2. **Before scale / monetization:** **0029** rate-limit + Budgets · **0030** AI safety ·
   **0031** COPPA · **0032** observability + worker DLQ/cost.
3. **The three data concerns:** **0026** tracking → **0028** catalog cache (with 0009) →
   **0027** artifacts/observability.
4. **Product pivot:** **0008** then 0009–0013.
5. **Flagship engine:** **0039** activity framework → **0038** engine → **0044** recsys →
   then the modality components **0040/0041/0042/0043** (0042/0043 gated by 0031 + Legal).
6. **Monetization & growth:** 0023 → 0024; 0014/0020/0021; 0025.
7. **Compliance & platform:** 0033 export/deletion · 0034 admin · 0035 flags · 0036 i18n ·
   0037 email; then 0022 App Store.

## Status & conventions

All 37 are **Draft**, dated 2026-06-26/28, reviewers **Principal/SD/QA** (+**Safety**
for 0040/0041/0043, +**Legal** for 0023/0024/0031/0033/0042/0043, +**Security** for
0029/0034). Cross-cutting invariants every spec honors: zero third-party iOS deps ·
DesignSystem tokens only · Lambdas stdlib+boto3, no DynamoDB floats · Xcode 16
file-system-synchronized groups · openapi ⇄ DTO ⇄ handler in sync · offline-first.
The agentic engine introduces **AWS Step Functions**, **Bedrock Guardrails**, multi-modal
models (Claude vision, Amazon Nova, Transcribe/Polly), and (v2) embeddings/vector search —
each scoped in its spec with cost, safety, and quota considerations.
