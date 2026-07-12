# 0008 · Issue tracker mirror

Local mirror of the GitHub issues for the 0008 activity-first reframe (epic M11).
**GitHub is authoritative** — update this file when issues change (`gh issue list -R
diprotis/mango --label epic:M11-reframe`). Last synced: **2026-07-12**.

## Live slices (dependency order)

| Issue | Slice | Type | Blocked by | Status |
|---|---|---|---|---|
| [#3](https://github.com/diprotis/mango/issues/3) | `JourneyStateMachine` (4 events) + manual journey-status control | AFK | — | **CLOSED** (`438f828`+`9f377bc`, 2026-07-12) |
| [#11](https://github.com/diprotis/mango/issues/11) | Roadmap-gen latency + idempotency (600s worker, matched poll, no double-gen) | AFK | — | **CLOSED** (`b121e63`, deployed beta, 2026-07-12) |
| [#8](https://github.com/diprotis/mango/issues/8) | Catalog reframe ("Start journey", `start` dispatch) | AFK | #3 | ready |
| [#6](https://github.com/diprotis/mango/issues/6) | "What to read next?" activity + tab-selection binding | AFK | #3 | ready |
| [#9](https://github.com/diprotis/mango/issues/9) | Migration backfill (journeyState + reading-activity prepend + `stableId`) | AFK | #3 | ready |
| [#7](https://github.com/diprotis/mango/issues/7) | Sync-ready contract: `journeyState` on `LibraryItem` | AFK | #3 | ready |
| [#12](https://github.com/diprotis/mango/issues/12) | On-device verification: hosted-UI sign-in + authed full-book gen | HITL | #11 | ready |
| [#13](https://github.com/diprotis/mango/issues/13) | P3 cutover: remove `MockAIService` (Bedrock-only; sign-in-gated gen UX) | HITL | #12 | ready |
| [#10](https://github.com/diprotis/mango/issues/10) | Docs + manual UX/accessibility pass | HITL | #13 | ready |

Critical paths: **#3 → #6/#8/#9/#7** (product track) and **#11 → #12 → #13 → #10**
(Bedrock-only track). The two tracks are parallel until #10.

## Record-keeping (open by operator preference; not implementable)

| Issue | Disposition |
|---|---|
| [#2](https://github.com/diprotis/mango/issues/2) | **SHIPPED** — reader removal + `JourneyState` foundation (commits `5acddcc`, `65ba002`) |
| [#4](https://github.com/diprotis/mango/issues/4) | **SUPERSEDED by ADR-0003** — checkpoints/read-gating replaced by per-lesson reading activities |
| [#5](https://github.com/diprotis/mango/issues/5) | **DELIVERED via ADR-0003** — lesson loop reframe (residual nudge dispatch → #3) |

## Shipped context (not on the tracker)

- Reading-as-activity + structured locators/anchor quotes + full-book grounding:
  commits `5962939`, `16dceed`, `ef1bd10` (S3 spill), verified on device + real Bedrock
  (8/8 verbatim anchors, Art of War).
- DirectClaude removed (`7187061`); beta redeployed fresh 2026-07-12 after the July-7
  stack deletion (`53d86b7` repoints the app; API `t0ctofkj52…`, pool `us-east-1_wtmj55nPo`).
- Decisions: [ADR-0001](../../docs/adr/0001-remove-in-app-reader.md) ·
  [ADR-0002](../../docs/adr/0002-journey-state-orthogonal-to-activity-gating.md) ·
  [ADR-0003](../../docs/adr/0003-reading-as-first-class-activity.md) ·
  [ROADMAP §7](ROADMAP.md) (slice table mirrors this file).
