# working/ — pending-feature specs (next-up backlog)

Detailed, **Draft** specs for the features still pending after v0.1 + the
Cognito/auth, data-lake, catalog, and e2e work already shipped. One file per
feature, following [`../docs/specs/SPEC_TEMPLATE.md`](../docs/specs/SPEC_TEMPLATE.md)
(12 sections each). These are planning docs — the *implemented* specs live in
[`../docs/specs/`](../docs/specs/) (0001–0007). Source backlog:
[../docs/PRODUCT_ROADMAP.md](../docs/PRODUCT_ROADMAP.md).

Workflow: review a spec → flip its status to Approved → implement in small PRs
against its acceptance criteria → move it into `docs/specs/` with a number when it
ships. Each spec is self-contained and grounded in the real codebase (endpoints,
services, models), so it can be handed to an implementer (incl. Claude Code) as-is.

## Suggested sequencing

Progress-sync is the keystone (it makes server state durable and gates leagues);
the rest are largely independent.

| Order | Spec | Epic | Roadmap | What it adds |
|---|---|---|---|---|
| 1 | [feature-progress-sync](feature-progress-sync.md) | M5 | #2 | Sync XP/level/streak via `GET`/`PUT /v1/me/progress`; survives reinstall + multi-device (server-reconciliation merge). |
| 2 | [feature-analytics-events-ios](feature-analytics-events-ios.md) | M9 | gap | iOS `AnalyticsService` → `POST /v1/events` → the data lake (typed taxonomy, offline queue, opt-out, no IDFA). |
| 3 | [feature-insight-review](feature-insight-review.md) | M6 | #4 | Daily ~60s spaced-repetition review; pure SM-2-lite scheduler; keeps the streak alive. |
| 4 | [feature-pdf-background-parsing](feature-pdf-background-parsing.md) | M7 | #6 | Move PDF parsing off the main thread (reusable import pipeline actor); smooth large imports. |
| 5 | [feature-epub-import](feature-epub-import.md) | M7 | #5 | EPUB connector, dependency-free (mini ZIP + Apple Compression); reuses the background pipeline. |
| 6 | [feature-native-apple-signin](feature-native-apple-signin.md) | M3 | gap | Native Sign in with Apple button + token-exchange Lambda (vs today's web Hosted-UI federation); Guideline 4.8. |
| 7 | [feature-feature-store-personalization](feature-feature-store-personalization.md) | M9 | gap | Populate + consume `MangoFeatures` — personalize the roadmap prompt, reminder timing, difficulty. |
| 8 | [feature-social-leagues](feature-social-leagues.md) | M8 | #3 | Opt-in weekly XP leagues + friends + buddies; server-authoritative anti-cheat; no shaming. |
| 9 | [feature-app-store-prep](feature-app-store-prep.md) | M10 | #7 | Submission readiness: privacy labels, Sign in with Apple, account deletion, screenshots, TestFlight→release. |

## Status

All nine are **Draft** (reviewers: Principal/SD/QA), dated 2026-06-26. None
implemented yet. Dependencies called out per spec — notably leagues (M8) depends on
progress-sync (M5), and personalization (M9) depends on analytics events (M9).
