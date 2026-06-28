# Mango feature backlog — `working/` INDEX

Numbered, **Draft** feature specs for everything planned but not yet implemented.
Each follows [`../docs/specs/SPEC_TEMPLATE.md`](../docs/specs/SPEC_TEMPLATE.md)
(12 sections), is grounded in the real codebase, and is written to be handed
straight to an implementer (incl. Claude Code). The numbering continues the
*implemented* specs in [`../docs/specs/`](../docs/specs/) (0001–0007). Source
backlog: [`../docs/PRODUCT_ROADMAP.md`](../docs/PRODUCT_ROADMAP.md).

Workflow: review → flip status to **Approved** → implement in small PRs against
the acceptance criteria → move the spec into `docs/specs/` with its number when it
ships. Keep `shared/api/openapi.yaml` ⇄ DTOs ⇄ handlers in sync (CLAUDE.md).

## Coverage of the requested work

| Your ask | Spec(s) |
|---|---|
| Icon redesign — Claude-style mark with a **literal mango**, not a letter | [0012](0012-app-icon-redesign.md) |
| Replace keyboard emojis with **theme-based icons**; broad **style refactor** | [0013](0013-design-system-iconography-gamification.md) |
| **Onboarding** more interesting — swipe / animated | [0010](0010-onboarding-redesign.md) |
| **Catalog ≥100 books** from public sources | [0009](0009-catalog-expansion-100-books.md) |
| **Not a reading app** — remove the reader; activities + journey tracking; manual status; "what to read" = an activity | [0008](0008-product-reframe-activity-first.md) |
| **Remove Journey shortcut**; make activities swipe-based / engaging | [0011](0011-navigation-and-activity-interaction.md) |
| Keep minimalist; make it **more gamified** | [0013](0013-design-system-iconography-gamification.md), [0011](0011-navigation-and-activity-interaction.md) |
| **Payment + credits** to generate roadmaps; earn credits on completion | [0023](0023-payments-and-credits.md) |
| **Rewards** — coupons, trips, gamified | [0024](0024-rewards-and-coupons.md) |
| **Notifications** for all updates/info | [0025](0025-notifications.md) |

## All specs

| # | Spec | Epic | Theme | Depends on |
|---|---|---|---|---|
| [0008](0008-product-reframe-activity-first.md) | Activity-first product reframe (remove in-app reader) | M11 | Product pivot | — (keystone) |
| [0009](0009-catalog-expansion-100-books.md) | Catalog expansion to 100+ public-domain books | M11 | Content | 0008 |
| [0010](0010-onboarding-redesign.md) | Onboarding redesign (swipe-through, animated) | M11 | UX | 0008 |
| [0011](0011-navigation-and-activity-interaction.md) | Nav cleanup + swipe-based activity interaction | M11 | UX | 0008 |
| [0012](0012-app-icon-redesign.md) | App icon redesign (mango-in-spark mark) | M11 | Brand | — |
| [0013](0013-design-system-iconography-gamification.md) | Design system: iconography + tasteful gamification | M11 | Design system | — |
| [0014](0014-progress-sync.md) | Progress sync across reinstalls & devices | M5 | Engagement/sync | auth (0003/0019) |
| [0015](0015-analytics-events-ios.md) | iOS analytics events → data lake | M9 | Data | — (backend live) |
| [0016](0016-insight-review.md) | Insight Review — daily spaced repetition | M6 | Engagement | 0008 |
| [0017](0017-pdf-background-parsing.md) | Background content parsing (PDF/EPUB off main thread) | M7 | Content/perf | 0008 |
| [0018](0018-epub-import.md) | EPUB import — bring-your-own-library | M7 | Content | 0017, 0008 |
| [0019](0019-native-apple-signin.md) | Native Sign in with Apple | M3 | Auth | Hosted UI (done) |
| [0020](0020-feature-store-personalization.md) | Feature store — population + personalization | M9 | Data/ML | 0015 |
| [0021](0021-social-leagues.md) | Social leagues, friends & buddies | M8 | Social | 0014 |
| [0022](0022-app-store-prep.md) | App Store submission readiness | M10 | Launch | many |
| [0023](0023-payments-and-credits.md) | Payments & credits (StoreKit IAP + ledger) | M12 | Monetization | 0019 (sign-in) |
| [0024](0024-rewards-and-coupons.md) | Rewards & coupons (gamified redemption) | M13 | Monetization | 0023 |
| [0025](0025-notifications.md) | Notifications (local + APNs remote push) | M14 | Engagement | 0015 (triggers) |

## Suggested sequencing

**Now — the immediate UI/product pivot (P0).** The reframe is the keystone; the
other five build on it and can go in parallel once it lands.
`0008` → `0009`, `0010`, `0011`, `0012`, `0013`.

**Next — make the server real & monetize.** `0014` progress-sync (durable state,
gates leagues) · `0015` analytics events · `0019` native Apple sign-in · `0023`
payments & credits · `0025` notifications.

**Later — depth, growth, launch.** `0016` insight review · `0017`/`0018` content
import · `0020` personalization · `0021` social leagues · `0024` rewards (digital
first; trips/sweepstakes are a flag-gated, legally-reviewed later phase) · `0022`
App Store prep.

## Status & conventions

All 18 specs are **Draft**, dated 2026-06-28, reviewers **Principal/SD/QA**
(plus **Legal** for `0023`/`0024` — IAP rules and sweepstakes law). None
implemented yet. Cross-cutting invariants every spec honors: zero third-party iOS
deps · DesignSystem tokens only · Lambdas stdlib+boto3, no DynamoDB floats ·
Xcode 16 file-system-synchronized groups · openapi ⇄ DTO ⇄ handler kept in sync.

> The detailed **activities & rewards mechanics** the user is iterating on plug
> into `0008` (activity model) and `0023`/`0024` (credit + reward economy); a
> dedicated `activities-and-rewards` mechanics spec can be added when that design
> is locked.
