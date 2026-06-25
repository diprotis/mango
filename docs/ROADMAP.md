# Mango — Delivery Roadmap & Backlog

The engineering backlog: what to build, in order, with scope and acceptance
criteria. This is the *delivery* plan; [PRODUCT_ROADMAP.md](PRODUCT_ROADMAP.md) holds
the lighter product framing and [GAMIFICATION.md](GAMIFICATION.md) the design rationale.

**Legend** — Status: ✅ done · 🔶 partial · ⬜ not started. Size: S (≤1d) · M (≤1wk) · L (>1wk).

## Now / Next / Later

- **Now (M1–M4):** real-stack deploy + on-device testing · Claude-consistent theme · sign-up & auth · data model + S3 lake.
- **Next (M5–M8):** progress sync · profile-built library & connectors · spaced-repetition review · social leagues.
- **Later (M9–M15):** content ingestion hardening · richer triggers · analytics · monetization · a11y/i18n · observability · App Store + OSS launch.

---

## M1 — Initial setup, deployment & real-app testing  🔶  (L)

**Goal:** a developer can stand up personal + Beta/Prod backends and run the real app
against each, with CI/CD doing the heavy lifting.

**Scope**
- [x] Monorepo, CI (iOS + backend), Beta/Prod CDK stages, OIDC deploy.
- [x] `dev` stage + `make backend-deploy-personal` for personal AWS.
- [x] iOS environment switch (Mock / Personal / Beta / Prod) + `AppConfig.plist`.
- [x] TestFlight release workflow (`ios-release.yml`, secrets-gated).
- [x] SOPs: [OPERATIONS.md](OPERATIONS.md), [DEPLOY.md](DEPLOY.md), [RUN_ON_IPHONE.md](RUN_ON_IPHONE.md).
- [ ] **Actually deploy** dev/beta to `diprotis-dev` and capture real API URLs (runs on your Mac).
- [ ] Bake real Beta/Prod URLs into `AppConfig.plist` (or CI secrets).
- [ ] First on-device smoke test against a live `/health`.

**Acceptance:** `curl <ApiUrl>/health` returns ok for dev & beta; the app, pointed at
Personal, reaches the backend; CI is green on `main`.
**Depends on:** AWS creds on your machine (sandbox can't deploy).

## M2 — Claude-consistent UI theme  ⬜  (M)

**Goal:** the app reads unmistakably "Claude": warm, calm, editorial.

**Scope**
- [ ] Audit current `Palette`/`Typo` against Claude's product palette; tune cream/ink/terracotta tokens + dark mode for AA contrast.
- [ ] Display serif (New York) pass on titles; refine spacing/rhythm to Claude's density.
- [ ] Component polish: cards, pills, primary/secondary buttons, progress ring, streak/XP — consistent radii, shadows, borders.
- [ ] Motion: subtle, consistent transitions (lesson complete, XP tick, node unlock); reduce-motion support.
- [ ] Iconography + app icon refinement; empty/loading/error states.
- [ ] Snapshot the theme in [DESIGN_SYSTEM.md](DESIGN_SYSTEM.md) with do/don't.

**Acceptance:** every screen uses only design tokens (no hardcoded hex), passes
contrast + Dynamic Type + dark mode, and a design review signs off.
**Depends on:** none (pure front-end).

## M3 — Sign-up & authentication (Cognito + app)  ⬜  (L)  ← unblocks real-backend AI

**Goal:** users sign in; the app sends a Cognito JWT so `/v1/*` works end-to-end.

**Scope — backend**
- [ ] Confirm Cognito user pool + app client config (hosted UI vs native); add email verification, password policy, password reset.
- [ ] (Optional) social / Sign in with Apple via Cognito identity providers.
- [ ] Token refresh strategy; map `sub` → `USER#<id>` everywhere.
**Scope — iOS**
- [ ] Auth service (AWS Amplify Auth **or** a thin SRP/native client — evaluate vs the "no third-party deps" invariant; Amplify would be the first dependency, so weigh a slim custom client).
- [ ] Sign-up / sign-in / reset screens in the Claude theme; secure token storage (Keychain); silent refresh.
- [ ] Send `Authorization: Bearer <IdToken>`; gate "real backend" modes on a session; graceful signed-out → Offline fallback.
- [ ] Account screen (sign out, delete account → backend data deletion).

**Acceptance:** a new user signs up, the app calls `/v1/roadmaps/generate` against
Beta and gets a real roadmap; signed-out app still works Offline.
**Depends on:** M1. **Risk:** dependency policy (Amplify) — decide explicitly.

## M4 — Data modelling: DynamoDB + S3 data lake  ⬜  (L)

**Goal:** durable, well-modelled storage for users, books, roadmaps, progress, and
an analytics-ready lake.

**Scope — operational store (DynamoDB single-table)**
- [ ] Finalize access patterns + entity model: `USER#`, `BOOK#`, `ROADMAP#`, `PROGRESS#`, `ACTIVITY#`, `ACHIEVEMENT#`, `REFLECTION#`; design `GSI1` (e.g., user→books, book→roadmap).
- [ ] Endpoints: persist imported books + roadmaps per user; reflections/journal; progress already exists — extend.
- [ ] TTL on ephemeral items; idempotency keys; optimistic concurrency where needed.
- [ ] Data-deletion path (GDPR/account delete) cascading across items + S3.
**Scope — S3 data lake**
- [ ] Raw zone: store parsed book text + source metadata (already partially in the content bucket) with partitioned keys (`raw/books/dt=…`).
- [ ] Curated/analytics zone: export progress/activity events (Firehose → S3 parquet) for retention metrics; Glue catalog + Athena for queries.
- [ ] Lifecycle policies (raw → IA → Glacier), encryption (SSE-S3/KMS), least-privilege access.
**Scope — modelling docs**
- [ ] Document the schema + access patterns in a new `docs/DATA_MODEL.md`; keep `openapi.yaml` ⇄ DTOs in sync.

**Acceptance:** a user's books/roadmaps/progress survive reinstall (synced from DDB);
activity events land in S3 and are queryable in Athena; deletion removes all traces.
**Depends on:** M3 (per-user identity). **Pairs with:** M5.

---

## M5 — Progress sync (device ⇄ backend)  ⬜  (M)
Two-way sync of XP/level/streak/achievements/library via `/v1/me/*`; conflict
resolution (last-writer-wins + monotonic XP); offline queue. **Depends on:** M3, M4.

## M6 — Profile-built library & connectors  ⬜  (L)
Turn the "library from user profile" idea into reality: recommend public-domain +
user-owned material from onboarding goals/interests; formalize connectors as real
tools/MCP (web URL, Gutenberg search, RSS/Substack, PDF, paste) with a server-side
parse path; a discovery feed. **Depends on:** M4. **Note:** respect copyright — default
to public-domain + user-supplied.

## M7 — Spaced-repetition "Insight Review"  ⬜  (M)
`InsightCard` model + a daily 60-sec review drawn from past chapters; Leitner/SM-2
intervals; keeps the streak alive on busy days. Ties directly to retention. **Depends on:** M4.

## M8 — Social leagues & friends  ⬜  (L)
Weekly XP leagues (promotion/demotion), friend streaks, opt-in + non-competitive mode.
Needs leaderboards, identity, anti-cheat. **Depends on:** M3, M4, M5.

## M9 — Content ingestion hardening  ⬜  (M)
EPUB import; move PDF parsing off the main thread; better web readability extraction;
size/rights guardrails; server-side parse for big files. **Depends on:** M6.

## M10 — Notifications & habit triggers  ⬜  (S–M)
Smarter (still ≤1–2/day) reminders tied to the user's goal + streak-at-risk; quiet
hours; rich content; opt-out telemetry. Ethical guardrails per GAMIFICATION.md.

## M11 — Analytics & metrics  ⬜  (M)
Instrument D1/D7/D30 retention, streak distribution, lesson funnel, reflection/
application rates; dashboards on the S3 lake (Athena/QuickSight); privacy-first.
**Depends on:** M4.

## M12 — Monetization  ⬜  (M–L)
Free core + optional Pro (extra tracks, unlimited imports, insight review). StoreKit 2
subscriptions; entitlement checks; ethical, no dark patterns. **Depends on:** M3.

## M13 — Accessibility, localization & polish  ⬜  (M)
VoiceOver labels everywhere, Dynamic Type stress test, color-blind validation, haptics
audit; string catalog + first localization; reduce-motion. Partly underway.

## M14 — Observability, security & cost  ⬜  (M)
CloudWatch dashboards/alarms, structured logs, X-Ray; WAF on the API; per-stage budgets
+ alerts; pen-test the SSRF/auth surface; rotate the Anthropic secret. Extends existing
security notes in [BACKEND.md](BACKEND.md).

## M15 — App Store + open-source launch  ⬜  (M)
App Store metadata/screenshots/privacy nutrition label; TestFlight → review; OSS
hygiene: `LICENSE`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, issue/PR templates,
`SECURITY.md`, a tagged `v0.1.0`.

---

## Suggested sequencing

```
M1 ─┬─ M2 (parallel, front-end only)
    └─ M3 ── M4 ──┬─ M5 ── M8
                  ├─ M6 ── M9
                  ├─ M7
                  └─ M11
M10, M13 anytime · M12, M14, M15 before public launch
```

Recommended first build after this plan: **M3 (auth)** — it unblocks real-backend
testing (SOP 5), M5, and most of what follows. M2 can run in parallel since it's
pure front-end.
