# 0024 — Rewards & coupons (gamified redemption)

- **Epic:** M13 · **Status:** Draft · **Owner:** unassigned · **Updated:** 2026-06-28
- **Reviewers:** Principal, SD, QA, Legal

## 1. Summary
Add a **gamified rewards program** where users redeem the **credits** they earn (the spendable
currency defined in `working/0023-payments-and-credits.md`) for real **rewards** — starting with
**low-risk digital rewards** (partner **coupon codes** and **gift cards**), with **physical
merch** and **aspirational prizes like trips** as later, separately-gated phases. The server is
the single source of truth: redemption is an **idempotent spend → reserve → fulfill** transaction
that decrements the credit ledger with the same conditional-decrement pattern `0023` uses, issues
a code from a pool or calls a digital-fulfillment partner (e.g. Tremendous / Tango Card), and
**refunds on failure**. The experience is wrapped in **ethical** gamification — tier/level
unlocks, milestone "reward drops," and a **transparent surprise reward with published odds** —
honoring every guardrail in `docs/GAMIFICATION.md` (no dark patterns, no loot boxes, honest odds,
surprises are bonuses on top of guaranteed rewards). **Trips and other high-value prizes are a
distinct SWEEPSTAKES module** modeled as *entries + a scheduled draw* (never a direct purchase),
which raises serious **promotion-law** obligations — the **prize + chance + consideration =
illegal-lottery** test, a mandatory **no-purchase-necessary / AMOE** free-entry path, US **state
registration/bonding**, **official rules**, age/eligibility/geo gating, **tax (1099-MISC)** handling,
winner verification, and **Apple Guideline 5.x** constraints. The strong recommendation is to
**ship Phase A (coupons/gift cards) first** and treat sweepstakes as a **later, legal-reviewed**
feature; the heavy compliance analysis is in §10. **This spec is engineering design, not legal
advice — the sweepstakes module must not ship without sign-off from qualified promotion-law counsel.**

## 2. Goals / Non-goals
- **Goals:**
  - A **rewards catalog** (`REWARD#<id>` items) the client can browse, **filtered by eligibility**
    (region, tier/level, credit balance, stock, active window).
  - An **idempotent redemption** endpoint that spends credits via `0023`'s conditional decrement,
    **reserves** the reward, **fulfills** it (issue a pooled coupon code, call a digital-fulfillment
    partner, or — Phase C — record a sweepstakes entry), and **refunds** on fulfillment failure.
  - A per-user **redemption ledger** (`USER#<sub>/REDEMPTION#<ts>`) with statuses
    `reserved → fulfilled → failed → refunded`, fully auditable.
  - **Ethical gamification:** tier/level **unlock gates**, **milestone/streak reward drops**, and a
    **transparent "surprise reward"** with **published odds**, plus a clear **redeemable-XP vs
    credits** distinction — all within the warm, minimalist Claude aesthetic and `0013` icon system.
  - A first-class **iOS Rewards screen** (catalog, redeem, history, tier progress) using DesignSystem
    tokens + `MangoSymbol`, **zero third-party deps**.
  - **Server-authoritative anti-abuse:** idempotency, fraud/self-dealing limits, per-user redemption
    caps, full audit trail; least-privilege IAM.
  - A **phased, legally-gated SWEEPSTAKES module** (entries + scheduled draw + AMOE + official rules
    + geo/age gating + winner verification + tax handling + fulfillment partner) **scaffolded now,
    launched later** behind a flag and counsel review.
- **Non-goals:**
  - **Defining the credit currency itself** — that is `0023` (earning, balance, ledger, conditional
    decrement). This spec **consumes** it and only ever **spends**.
  - **Running our own gift-card issuance / KYC / money transmission.** We integrate a licensed
    **fulfillment partner** for gift cards; we never custody stored value or move money ourselves.
  - **Cash payouts / real-money gaming / paid sweepstakes entries.** Explicitly out — banned by
    `docs/GAMIFICATION.md` and Apple 5.x; credits are **never** cash and **never** buy a paid entry.
  - **Loot boxes / pay-to-spin / variable-reward gambling mechanics.** The surprise reward is an
    honest bonus with published odds, never the only path and never tied to money (GAMIFICATION §2d/§6).
  - **Non-US sweepstakes** in v1 (jurisdictions differ materially — §10); sweepstakes launch is
    **US-only, geo-gated**, pending counsel.
  - **Android/web.** iOS-only, consistent with the rest of the app.

## 3. Background & context
**Why now / where it sits.** `0023` introduces **credits** as a spendable currency (earned via the
gamification loop and/or purchased — see that spec for the earn/buy rules and the **ledger +
conditional-decrement spend** primitive). Credits are only motivating if there is somewhere
worthwhile to **spend** them; this spec is that spend surface. It is the natural successor to the
gamification work in `0013` (tasteful celebration components — `LevelUpCelebration`, `ConfettiBurst`,
`AchievementChip`, the `MangoSymbol` vocabulary) and the social/engagement direction of `0021`.

**Current backend.** Single DynamoDB table (`PK`/`SK` + `GSI1`), HTTP API v2 + Lambda (py3.12,
**stdlib + boto3 only**, no DynamoDB `float`), Cognito JWT authorizer (`response.user_id` →
`USER#<sub>`), S3, Bedrock. Routes are wired in `api_stack.py` with **least-privilege** grants
(e.g. the grade Lambda has *no* table access). Existing user data lives under `USER#<sub>` (PROFILE,
PROGRESS, LIBRARY#, REFLECTION#…). This spec adds `REWARD#`, `REDEMPTION#`, `COUPONPOOL#`, and
(Phase C) `SWEEP#`/`ENTRY#` items plus a few new handlers and routes — all additive.

**Current iOS.** `AppModel` (`@Observable` service container) exposes `apiClient()` (carrying the
Cognito id token, `nil` when offline) and per-feature services (e.g. `catalog()`). `APIClient` is a
thin async JSON client with `getJSON`/`postJSON`/`delete`. `DTOs.swift` mirrors `openapi.yaml`. The
Profile feature (`ProfileView`) already renders level/XP/streak/achievements with `ProgressRing` /
`XPBar` / `StatTile` and DesignSystem tokens — the Rewards screen will live beside it and reuse those.

**Hard constraints (from `CLAUDE.md`).** No third-party iOS deps; tokens-only UI (`Palette`/`Typo`/
`Metrics`/`MangoSymbol`); offline-first (Rewards must degrade gracefully with no backend/session);
backend AI on Bedrock (not relevant here, but no API keys shipped); **no `float` in DynamoDB** (all
credit/XP/cost values are `int`; money values, if ever needed, are integer **minor units** — cents);
keep `openapi.yaml` ⇄ `DTOs.swift` ⇄ handlers in lockstep; Xcode-16 file-system-synchronized groups
(new files auto-register — never hand-edit `project.pbxproj`); backend **black (100) + flake8 (120)**.

**The crux (read §10 first if short on time).** Coupons and gift cards are ordinary **loyalty
redemption** — low legal risk, the Phase-A focus. **Trips/high-value prizes are not** a redemption;
awarding them by *chance* to entrants creates the **prize + chance + consideration** trifecta that
defines an **illegal lottery** unless **consideration is removed** by a genuinely **equal, free
Alternate Method of Entry (AMOE)** — plus **state registration/bonding** (NY/FL when aggregate prize
value > $5,000; RI for retail promotions > $500), **official rules**, **eligibility/age** limits,
**winner verification** (affidavit/release), and **tax reporting** (**1099-MISC** — see §10 for the
**2026 $2,000 threshold**). Apple separately requires (5.x) that sweepstakes be **sponsored by the
developer**, show **official rules**, state **Apple is not a sponsor**, and **not use IAP currency to
enter a paid sweepstakes**.

## 4. User stories
- As a user with earned credits, I open **Rewards**, see what I can afford and what's locked, and
  redeem a **coupon** or **gift card** in a couple of taps — getting my code/confirmation immediately.
- As a user, I see **why** something is locked ("Reach Level 8" / "Earn 200 more credits" / "Not
  available in your region") so the gate feels honest, not arbitrary.
- As a user, I view my **redemption history** with each reward's status (issued / pending / refunded)
  and can re-copy a code I already earned.
- As a user climbing tiers, I get a **milestone reward drop** at a streak/level checkpoint and an
  occasional **surprise reward** whose **odds are published up front** — a delightful bonus, never a
  paywalled gamble.
- As a user who tapped **Redeem** twice (double-tap, flaky network), I am charged and issued **exactly
  once**.
- As a user whose fulfillment fails (partner outage / empty pool), I am **automatically refunded** my
  credits and told to try again — never silently charged.
- *(Phase C, post-legal)* As an eligible US user, I **enter a sweepstakes** for an aspirational prize,
  see the **official rules**, can enter via a **free no-purchase method**, and if I win I'm verified
  and the prize is fulfilled with proper tax handling.
- As an **abuser**, I cannot drain rewards via replay, balance races, multi-account self-dealing, or
  by editing the client — the server rejects me and logs it.

## 5. Requirements
### Functional
- **FR-1 (catalog).** `GET /v1/rewards` returns the **active, region-eligible** catalog. Each item:
  `id, type ∈ {coupon, giftcard, physical, sweepstakes_entry}, title, blurb, partner, imageSymbol,
  costCredits (int ≥ 0), requiredTier?, requiredLevel?, stockState ∈ {in_stock, low, out},
  regionAllow[], activeFrom, activeTo, eligibility { affordable, tierMet, levelMet, regionOk, reason? }`.
  Eligibility is **computed server-side** from the caller's balance/tier/level/region; the client only
  renders it.
- **FR-2 (redeem — idempotent spend→issue).** `POST /v1/rewards/{id}/redeem` with an
  **`Idempotency-Key`** (client-generated UUID, also echoed in the body as `clientToken`). The server,
  in one logical transaction: (a) validates eligibility & stock & window; (b) **decrements credits**
  by `costCredits` using the `0023` conditional-decrement (`UpdateItem … ConditionExpression: balance
  >= cost`); (c) writes a `REDEMPTION#` row `status=reserved`; (d) **fulfills** (pool code / partner
  call / sweepstakes entry); (e) marks `status=fulfilled` and returns the artifact (code or
  confirmation). **Replays with the same key return the original result, no second charge.**
- **FR-3 (refund on failure).** If fulfillment fails after the credit decrement, the server **refunds**
  the credits (via the `0023` ledger, an offsetting `+cost` entry) and sets `status=refunded` (or
  `failed` if even the refund must be retried by a sweeper). The user is never left charged-without-reward.
- **FR-4 (history).** `GET /v1/me/rewards` returns the caller's redemptions (newest first), each with
  `redemptionId, rewardId, title, type, status, costCredits, createdAt, artifact?` (a coupon code or a
  masked partner reference; never another user's data).
- **FR-5 (coupon pool).** Coupon rewards draw a **unique code** from a server-side pool
  (`COUPONPOOL#<rewardId>` items) via an **atomic claim** (conditional `UpdateItem` flipping
  `claimed=false→true`), so a code is issued to at most one user. Low-pool and empty-pool states drive
  `stockState` and a clean out-of-stock error.
- **FR-6 (digital-fulfillment partner).** Gift-card rewards call a pluggable **`FulfillmentClient`**
  (a server-side adapter; Tremendous/Tango Card-style) to **issue** the gift, passing the
  **`redemptionId` as the partner idempotency key** (`external_id`) so partner retries don't double-issue.
  The partner is behind an interface with a **`MockFulfillmentClient`** for tests/offline (no secret,
  no network) — mirroring the app's offline-first stance.
- **FR-7 (gamification — unlocks).** Catalog items may require a **tier** and/or **level**; locked items
  are returned with `eligibility.tierMet/levelMet=false` and a human `reason`. Tiers map to the
  existing level system (`LevelCurve`) — no new currency.
- **FR-8 (gamification — reward drops).** At defined **milestones** (e.g. streak 7/30, level-up,
  finishing a book) the server may grant a **reward drop** (a credit bonus and/or a guaranteed small
  reward), recorded in the redemption/credit ledgers like any other grant. **Deterministic and
  transparent** — the user is told what they earned and why.
- **FR-9 (gamification — transparent surprise).** An optional **surprise reward** mechanic where the
  user opens a "drop" with **published odds** (e.g. "70% +10 credits · 25% +25 credits · 5% a coupon").
  Odds are **disclosed in-UI before opening**, the roll is **server-side and auditable** (seeded,
  logged), the surprise is **always a positive bonus on top of a guaranteed reward**, is **never tied
  to money**, and has **no near-miss / pay-to-reroll** mechanics (GAMIFICATION §2d/§6). This is **not**
  a loot box and must never become one.
- **FR-10 (redeemable-XP vs credits).** The UI and API clearly distinguish **credits** (the spendable
  currency from `0023`) from **XP** (mastery/leveling, **never spent**, never decays — GAMIFICATION
  §2a). Tier/level gates read from XP/level; **costs** are always in credits. No endpoint ever spends XP.
- **FR-11 (sweepstakes — entries + draw, Phase C, flagged).** `POST /v1/sweepstakes/{id}/enter` records
  an **entry** (not a purchase) for an eligible user and supports **both** a credits/engagement entry
  **and** a **free AMOE** entry of equal standing (`method ∈ {standard, amoe}`); `GET /v1/sweepstakes`
  lists active draws with their **official-rules** reference; a **scheduled draw** (EventBridge) selects
  winner(s) auditable from the entry set. Entry is **geo-gated (US-only)**, **age-gated**, idempotent,
  and **gated behind `sweepstakesEnabled` + counsel sign-off**. **Credits/IAP currency must never be
  required to enter** (Apple 5.x; consideration analysis §10) — the standard method must be free-by-AMOE-equivalent
  or counsel-approved.
- **FR-12 (erase cascade).** `DELETE /v1/me` (specs 0003/0004) also removes the user's `REDEMPTION#`
  rows, sweepstakes entries, and any PII captured for winner verification; issued external codes are
  recorded as spent (not resurrected).

### Non-functional
- **NFR-1 (server-authoritative & idempotent).** Eligibility, cost, stock, and the spend are decided by
  the server; the client value is advisory. Every state-changing call is **idempotent** (FR-2/FR-3/FR-6).
  No endpoint accepts a client-supplied balance, cost, or "already paid" claim.
- **NFR-2 (consistency / no double-spend, no double-issue).** The credit decrement is a **conditional**
  write; the redemption row and pool claim use conditional writes keyed by `redemptionId`/`Idempotency-Key`;
  partner issuance uses the partner's idempotency key. A crash between steps is **recoverable** by a
  sweeper that reconciles `reserved` rows (re-fulfill or refund). **All numerics are `int`** (no `float`
  in DynamoDB); money, if present, is integer **cents**.
- **NFR-3 (anti-abuse / fraud).** Per-user **redemption rate** and **per-reward / per-window caps**;
  **self-dealing** controls for referral-style rewards (no rewarding your own alt); velocity/anomaly
  flags can **freeze** redemptions pending review; all redemptions are **audit-logged** (actor, time,
  reward, cost, result, idempotency key). Sweepstakes adds **one-entry-per-eligible-person** integrity.
- **NFR-4 (least-privilege IAM).** Each Lambda gets only the table/index/secret it needs; the **catalog
  reader** is read-only; only the **redeem** Lambda may write `REDEMPTION#`/claim pool codes and decrement
  credits; the **fulfillment secret** (partner API key) is granted **only** to the redeem/fulfillment
  Lambda (Secrets Manager), never the catalog reader (mirrors `api_stack.py`).
- **NFR-5 (privacy / compliance).** Minimize PII: gift-card delivery uses the partner's flow where
  possible; **winner-verification PII** (name/address/SSN for tax) is collected **only when legally
  required**, stored encrypted, access-scoped, and erasable (FR-12). **Official rules**, **odds**, and
  **"Apple is not a sponsor"** are shown in-app where applicable.
- **NFR-6 (accessibility / taste).** Rewards UI uses `Typo`/`Palette`/`Metrics`/`MangoSymbol`; locked/stock
  states have **text equivalents** (never color-only); celebration on redeem is the **restrained** `0013`
  style (Reduce-Motion-safe), proportional, non-repeating. Honest, calm copy — no fake urgency/scarcity.
- **NFR-7 (cost / performance).** Catalog read is a single `Query` (active items) + per-user eligibility
  compute (O(1) reads of balance/level); history is a single `USER#<sub>` `Query`. Stay within the
  single-table + HTTP-API budget. Partner calls are the only external latency — bounded timeout + the
  reserve/refund pattern means a slow partner never double-charges.

## 6. Design

### 6.0 Phasing (de-risked, ship the safe part first)
- **Phase A — Coupons & gift cards (LOW risk; ship first).** Catalog + redeem (pool codes + partner
  gift cards) + history + idempotency/refund + tier/level unlocks + iOS Rewards screen. No chance, no
  prizes, no sweepstakes — ordinary loyalty redemption.
- **Phase B — Ethical gamification polish.** Milestone reward drops + transparent published-odds surprise
  + redeemable-XP/credits clarity + celebration wiring (`0013` components). Still no sweepstakes.
- **Phase C — SWEEPSTAKES for trips/high-value (HIGH risk; flagged + legal-gated).** Entries + scheduled
  draw + **AMOE free entry** + official rules + geo/age gating + winner verification + tax (1099) +
  partner fulfillment. **Does not ship without promotion-law counsel sign-off and the state
  registration/bonding work in §10.**

### 6.1 API / contract (add to `shared/api/openapi.yaml`; keep `DTOs.swift` + handlers in sync)
All routes JWT-authorized (Cognito authorizer; `response.user_id` → `USER#<sub>`) **except** the
catalog read, which **may** be unauthenticated like `/v1/catalog` (eligibility flags then omitted /
"sign in to redeem"). Recommendation: **authorized** catalog so eligibility is personalized (D-6).

- `GET  /v1/rewards`
  → `{ rewards: [ RewardDTO ] }` — active + region-eligible; each with computed `eligibility`.
- `POST /v1/rewards/{id}/redeem`
  Header `Idempotency-Key: <uuid>`; body `{ clientToken: <uuid> }` (== key, belt-and-suspenders).
  → `200 { redemptionId, status, artifact?: { kind: "coupon_code"|"giftcard_link"|"entry", value|ref } }`
  → `409 { error: "insufficient_credits" | "out_of_stock" | "not_eligible" | "inactive" }`
  → replay with same key ⇒ original `200` body (no second charge).
- `GET  /v1/me/rewards`
  → `{ redemptions: [ RedemptionDTO ] }` (newest first).
- *(Phase C, flagged)* `GET  /v1/sweepstakes` → `{ sweepstakes: [ SweepstakesDTO (incl. officialRulesUrl, endsAt, eligibility) ] }`.
- *(Phase C, flagged)* `POST /v1/sweepstakes/{id}/enter`
  Header `Idempotency-Key`; body `{ method: "standard"|"amoe" }`
  → `200 { entryId, method, status: "entered" }` → idempotent; geo/age-gated; **never requires credits/IAP**.

`RewardDTO`, `RedemptionDTO`, `SweepstakesDTO` get **new `Codable` structs in `DTOs.swift`** that match
these shapes exactly (CLAUDE.md contract invariant). New `APIClient` verbs reuse the existing
auth-header path; add a small overload of `postJSON` that sets the `Idempotency-Key` header.

### 6.2 Data — single-table access patterns (`PK`/`SK` + `GSI1`; all ints, no floats)
**Catalog (admin-seeded items):**
- `PK=REWARD#<id>  SK=META` → `{ type, title, blurb, partner, imageSymbol, costCredits:int,
  requiredTier?:int, requiredLevel?:int, regionAllow:[..], activeFrom, activeTo, stockMode ∈
  {pool, partner, unlimited}, status ∈ {active, paused} }`.
- **GSI1 for "list active":** `GSI1PK=REWARD#ACTIVE`, `GSI1SK=<activeFrom>#<id>` → one `Query` returns
  the catalog; filter by window/region/status in the handler. (Small catalog; a `Query` on a constant
  PK with `GSI1` is fine and avoids a `Scan`.)

**Coupon pool (codes for a `pool`-mode reward):**
- `PK=COUPONPOOL#<rewardId>  SK=CODE#<codeId>` → `{ code: <string>, claimed:bool, claimedBy?, at? }`.
- **Atomic claim:** `UpdateItem` with `ConditionExpression: claimed = :false`, set
  `claimed=true, claimedBy=<sub>, at=<ts>` — guarantees one code → one user. To pick *an* unclaimed
  code without a scan, maintain `PK=COUPONPOOL#<rewardId> SK=META → { remaining:int, nextIdx:int }`
  and address codes by index (`CODE#<zeroPaddedIdx>`), claiming `nextIdx` then `ADD nextIdx 1` /
  `ADD remaining -1` (conditional on `remaining > 0`). `remaining` drives `stockState`.

**Redemption ledger (per user; the audit + idempotency record):**
- `PK=USER#<sub>  SK=REDEMPTION#<isoTs>#<redemptionId>` → `{ rewardId, type, costCredits:int,
  status ∈ {reserved, fulfilled, failed, refunded}, idempotencyKey, artifactRef?, partnerOrderId?,
  createdAt, updatedAt }`.
- **Idempotency guard:** `PK=USER#<sub>  SK=IDEMPOTENCY#REDEEM#<key>` → `{ redemptionId }`, written with
  `ConditionExpression: attribute_not_exists(PK)`. First request wins and proceeds; a replay finds the
  row and returns the **existing** redemption's result (no decrement, no second issue). (TTL e.g. 30 days.)

**Credit spend/refund (defined by `0023`; this spec only calls it):**
- Spend: `UpdateItem` on the user's credit-balance item with
  `ConditionExpression: creditBalance >= :cost`, `SET creditBalance = creditBalance - :cost` **+** a
  `CREDITLEDGER#<ts>` debit entry `{ amount: -cost, source: "redeem:<rewardId>", redemptionId }`.
- Refund: offsetting `+cost` ledger entry + `ADD creditBalance :cost`, `source: "refund:<redemptionId>"`.
- (If `0023` exposes these as a shared module, call it; otherwise this spec implements the same
  conditional pattern against the agreed key. **Decision D-1.**)

**Sweepstakes (Phase C; flagged):**
- `PK=SWEEP#<id>  SK=META` → `{ title, prizeDesc, prizeValueCents:int, officialRulesUrl, entryStart,
  entryEnd, drawAt, regionAllow:["US"], minAge:int, status, sponsor }`.
- `PK=SWEEP#<id>  SK=ENTRY#<sub>` → `{ method ∈ {standard, amoe}, at }` — **one entry row per user per
  sweepstakes** (`attribute_not_exists` guard = one-entry integrity); free AMOE entries are first-class.
- `PK=USER#<sub>  SK=SWEEPENTRY#<id>` → mirror for "my entries."
- Winner selection: a **scheduled Lambda** reads all `ENTRY#` rows for a closed sweep, picks winner(s)
  via a **seeded, logged** RNG (auditable), writes `SK=WINNER#<sub>`, and kicks the verification +
  fulfillment flow. Idempotent (keyed by sweep id); stdlib+boto3 only.

### 6.3 Redemption flow (the load-bearing transaction)
```
POST /v1/rewards/{id}/redeem  (Idempotency-Key: K)
 0. Idempotency: PutItem IDEMPOTENCY#REDEEM#K  (attribute_not_exists)
      └ exists? → load its redemption → return original result. STOP.
 1. Load REWARD#id/META → validate status=active, now∈[activeFrom,activeTo], region∈regionAllow,
      tier/level met, stock available (remaining>0 for pool).   else → 409 (not_eligible/out_of_stock/inactive)
 2. SPEND: UpdateItem creditBalance  (ConditionExpression creditBalance >= cost)  + ledger debit
      └ condition fails → 409 insufficient_credits (delete the idempotency row so a later top-up can retry)
 3. Write REDEMPTION#…  status=reserved   (redemptionId)
 4. FULFILL by type:
      coupon  → atomic claim a pool CODE# (conditional)             → artifact = code
      giftcard→ FulfillmentClient.issue(external_id=redemptionId)   → artifact = partner link/ref
      sweep   → (Phase C) record ENTRY#                              → artifact = entry receipt
 5a. success → REDEMPTION#.status=fulfilled (+ partnerOrderId/artifactRef) → 200 {artifact}
 5b. failure → REFUND credits (+cost ledger) → status=refunded(or failed) → 409/503 "try again, refunded"
Reconciliation sweeper (EventBridge, periodic): find REDEMPTION#.status=reserved older than N min →
   re-query partner by external_id=redemptionId (idempotent) → mark fulfilled if the partner did issue,
   else refund. (Handles crash-between-steps; the partner key makes re-fulfill safe.)
```
- **Why this is safe:** the decrement is conditional (no negative balances, no double-spend under
  concurrency); the idempotency row makes the whole op exactly-once per key; the partner `external_id`
  makes issuance exactly-once even across our retries; the refund path means a failure never leaves the
  user charged; the sweeper closes the crash window.

### 6.4 Ethical gamification (within the `0013` aesthetic)
- **Tiers / unlocks (FR-7).** Reuse `LevelCurve` (no new currency). A reward may require `requiredTier`
  (a named band over levels, e.g. Curious Reader → Practitioner → Mentor) and/or `requiredLevel`. Locked
  cards show the **exact** unlock condition ("Reach Level 8"). No fake "almost there" pressure.
- **Milestone reward drops (FR-8).** On streak/level/book milestones, grant a **guaranteed** small reward
  (credit bonus and/or a token coupon), surfaced via `LevelUpCelebration`/`AchievementChip` (`0013`) and
  recorded in the ledgers. The user is always **told what they got and why** — deterministic, honest.
- **Transparent surprise (FR-9).** A "surprise drop" the user opens (tap-to-open chest, `ConfettiBurst`),
  with **odds printed before opening** and a **published odds table** in-app. The roll is **server-side,
  seeded, and logged** (auditable — like the deterministic seeded surprise XP already used in the app),
  always **net-positive**, never money-gated, **no reroll-for-pay, no near-miss**. *Test for inclusion:*
  "Would I be comfortable showing the user exactly why this reward landed?" (GAMIFICATION §6) — yes.
- **Redeemable-XP vs credits (FR-10).** **XP** = mastery, leveling, never spent, never decays (drives
  tier gates). **Credits** = the spendable currency from `0023` (drives costs). The Rewards UI labels
  both distinctly so users are never confused into thinking learning progress is being "spent."
- **What we will NOT do.** No loot boxes, no pay-to-spin, no purchasable random rewards, no countdown
  fake-scarcity, no "spend credits or lose them" coercion. (All explicitly banned by `docs/GAMIFICATION.md`.)

### 6.5 iOS — screens, state, services (zero third-party deps; DesignSystem + `MangoSymbol`)
New feature module `ios/Mango/Features/Rewards/` (Xcode-16 sync — auto-registers; **no `project.pbxproj`
edits**):
- **`RewardsView`** — the catalog. A grid/list of **`RewardCard`**s (title, cost in credits with a
  `MangoSymbol` credit glyph, partner, an `Icon(imageSymbol)`), each showing **affordable / locked /
  out-of-stock** states with text + tint (never color-only). A header shows the user's **credit balance**
  and **tier progress** (reuse `ProgressRing`/`XPBar` like `ProfileView`).
- **`RewardDetailView` / redeem sheet** — confirm cost, tap **Redeem**, show a restrained success
  celebration (`0013` `LevelUpCelebration`-style, Reduce-Motion-safe), reveal/copy the **coupon code**
  or partner confirmation. Disabled with a clear reason when ineligible.
- **`RedemptionHistoryView`** — `GET /v1/me/rewards`; rows with status chips (`fulfilled`/`pending`/
  `refunded`) and copy-code affordance; empty state via `EmptyStateView`.
- *(Phase B)* **`SurpriseDropView`** — published odds shown **before** opening; tap-to-open; net-positive
  result; uses `ConfettiBurst`.
- *(Phase C, flagged)* **`SweepstakesView` / `SweepstakesDetailView`** — list + official-rules link +
  **"Apple is not a sponsor"** + the **free AMOE** entry path + geo/age gating; entry receipt.
- **State/services:** a new **`RewardsService`** (`@Observable`, constructed in `AppModel` like
  `catalog()`), wrapping the endpoints via `apiClient()`; **generates and stores the `Idempotency-Key`**
  for an in-flight redeem so a retry reuses it. Gated on a live session for redeem; **offline-safe** —
  with no backend it shows a friendly "sign in / connect to redeem" state and never blocks the app.
- **New DTOs** in `Services/Networking/DTOs.swift` (`RewardDTO`, `RewardEligibilityDTO`, `RedemptionDTO`,
  `RedeemResultDTO`, and Phase-C `SweepstakesDTO`/`SweepstakesEntryDTO`) matching §6.1.
- **Navigation:** a new `Route` case (`.rewards`, `.rewardDetail(id)`, `.redemptionHistory`) added to the
  central `Route` enum + `.mangoDestinations()`; entry point from **Profile** (a "Rewards" row) and/or a
  tab if product wants it later. **Icons:** extend `MangoSymbol` (`0013`) with `.credit` (e.g.
  `"creditcard.fill"` or a token glyph), `.gift` (`"gift.fill"`), `.coupon` (`"ticket.fill"`),
  `.reward` (`"sparkles"`/`rosette`) — names are tokens, no bare strings at call sites.

### 6.6 Fulfillment partner integration (server-side `FulfillmentClient`)
- **Interface (py):** `FulfillmentClient.issue(reward, redemption_id, recipient) -> Issuance` and
  `get(external_id) -> Issuance|None` (for the reconciliation sweeper). Implementations:
  - `MockFulfillmentClient` — deterministic, no network/secret; default in tests, local, and any non-prod
    stage without a configured key (offline-first parity).
  - `TremendousClient` / `TangoClient` — real adapter; uses **`external_id = redemption_id`** so the
    provider treats re-submits as **idempotent** (Tremendous documents that `create order` with an
    existing `external_id` does not create a new order; gift-card APIs generally de-dupe within an
    idempotency window). Reads the API key from **Secrets Manager** (granted only to the redeem Lambda).
- **Why a partner:** they hold the merchant relationships, brand catalog, KYC, and money movement; we
  stay out of stored-value/money-transmission. We pass the minimum recipient info and our idempotency key.

### 6.7 Files & where things live (Xcode-16 sync / CDK)
- **Backend new:** `backend/src/handlers/rewards.py` (catalog + redeem + history),
  `backend/src/shared/rewards.py` (eligibility compute, pool claim, redemption state machine),
  `backend/src/shared/fulfillment.py` (`FulfillmentClient` + Mock + partner adapters),
  `backend/src/shared/idempotency.py` (the conditional idempotency helper, reusable),
  *(Phase C)* `backend/src/handlers/sweepstakes.py` + `backend/src/handlers/sweep_draw.py` (scheduled).
- **Backend edited:** `backend/mango_backend/api_stack.py` (new Lambdas + routes + **least-privilege**
  grants: catalog read-only; redeem read-write table + Secrets Manager gift-card key; sweep-draw scheduled
  rule), reuse `data_stack.py` table/GSI1 (no schema change — single table). `cdk synth -c stage=beta`
  must pass.
- **Contract:** `shared/api/openapi.yaml` (new paths/schemas) ⇄ `ios/.../Services/Networking/DTOs.swift`.
- **iOS new:** `Features/Rewards/{RewardsView,RewardDetailView,RedemptionHistoryView,RewardsService}.swift`
  (+ Phase B/C views); `Route` cases; `MangoSymbol` additions.
- **Tests:** backend `backend/tests/test_rewards.py` (+ `test_sweepstakes.py` Phase C); iOS
  `MangoTests/RewardsDTOTests.swift`, `MangoTests/RewardEligibilityTests.swift`.

### 6.8 Diagram
```
catalog:   GET /v1/rewards → Query GSI1(REWARD#ACTIVE) → per-user eligibility(balance,level,region) → [RewardDTO]
redeem:    POST …/redeem (Idempotency-Key) → idem-guard → eligibility/stock → SPEND(cond. decrement+ledger)
             → REDEMPTION#reserved → fulfill{pool code | partner.issue(external_id=redemptionId) | entry}
             → fulfilled  | (fail) → REFUND(+ledger) → refunded
sweeper(EventBridge): reserved>Nmin → partner.get(external_id) → fulfilled-or-refund
gamification: milestone → guaranteed drop (ledger) ;  surprise → seeded+logged roll, net-positive, odds shown
sweepstakes(Phase C, flagged): enter{standard|AMOE-free} (geo/age, one ENTRY# per user) → scheduled seeded draw
             → WINNER# → verify(affidavit) → 1099 if ≥ threshold → partner fulfill
```

## 7. Acceptance criteria
- [ ] **AC-1 (catalog + eligibility):** `GET /v1/rewards` returns only active, in-window, region-eligible
      items, each with correct server-computed `eligibility` (affordable/tier/level/region). *(pytest with
      moto seeding rewards + a user balance/level/region; `RewardEligibilityTests` for the pure filter.)*
- [ ] **AC-2 (redeem happy path):** a coupon redeem spends exactly `costCredits`, claims one unique pool
      code, writes `REDEMPTION#=fulfilled`, and returns the code. *(pytest, moto.)*
- [ ] **AC-3 (idempotency — headline):** two `redeem` calls with the **same `Idempotency-Key`** result in
      **one** decrement, **one** issued code, and **identical** responses. *(pytest: replay the request;
      assert balance moved once and the same code returned — the key correctness test.)*
- [ ] **AC-4 (insufficient credits):** redeeming above balance returns `409 insufficient_credits`, makes
      **no** decrement, **no** `REDEMPTION#`, **no** code claimed. *(pytest with the conditional-decrement.)*
- [ ] **AC-5 (out of stock):** when the pool is exhausted (`remaining=0`), redeem returns `409 out_of_stock`,
      no charge. *(pytest seeding an empty pool.)*
- [ ] **AC-6 (refund on fulfillment failure):** with a `MockFulfillmentClient` forced to fail, a gift-card
      redeem **refunds** the credits (offsetting ledger entry, balance restored) and sets
      `status=refunded`. *(pytest: inject failing client; assert balance net-zero and status.)*
- [ ] **AC-7 (partner idempotency):** the fulfillment adapter passes `external_id=redemptionId`; a simulated
      partner retry does **not** create a second issuance. *(pytest with a mocked partner recording
      `external_id`s; assert single order.)*
- [ ] **AC-8 (history):** `GET /v1/me/rewards` returns the caller's redemptions newest-first with correct
      statuses and never another user's rows. *(pytest.)*
- [ ] **AC-9 (XP never spent):** no endpoint debits XP; gates read XP/level but costs debit **credits** only.
      *(Code review + pytest asserting redeem touches the credit item, not XP.)*
- [ ] **AC-10 (surprise odds honesty, Phase B):** the surprise endpoint returns a result drawn from the
      **published** odds, the roll is logged/seeded, and the outcome is **always net-positive**; the UI shows
      odds **before** opening. *(pytest of the seeded roll distribution + UI check.)*
- [ ] **AC-11 (least-privilege IAM):** the catalog Lambda has **no** Secrets-Manager/credit-write access;
      only the redeem Lambda holds the gift-card key + redemption writes. *(Inspect `api_stack.py`;
      `cdk synth` per stage.)*
- [ ] **AC-12 (erase cascade):** `DELETE /v1/me` removes the user's redemptions, sweepstakes entries, and
      verification PII. *(pytest extending the 0004 delete-cascade test.)*
- [ ] **AC-13 (iOS):** Rewards screen lists the catalog with correct affordable/locked/out-of-stock states
      (text + token, not color-only), redeems via the service with a reused `Idempotency-Key` on retry, shows
      history, and degrades gracefully offline. *(iOS unit + `FakeAPIClient` flow; manual on Beta.)*
- [ ] **AC-14 (no third-party deps / tokens-only / theme audit):** no SPM/CocoaPods added; `check_theme.sh`
      passes; Rewards UI uses `Palette`/`Typo`/`Metrics`/`MangoSymbol`. *(CI.)*
- [ ] **AC-15 (sweepstakes gating, Phase C):** with `sweepstakesEnabled=false` the sweepstakes routes/UI are
      absent; when enabled, entry is **geo-gated US**, **age-gated**, supports a **free AMOE** method of equal
      standing, shows **official rules** + **"Apple is not a sponsor"**, and **never requires
      credits/IAP**. *(pytest of the gates + manual; **plus** Legal sign-off recorded — see §10.)*

## 8. Test plan
- **Backend (pytest + moto — offline; primary):** catalog query + eligibility filter; redeem happy path
  (pool claim + spend + fulfilled); **idempotency replay** (AC-3); insufficient-credits conditional (AC-4);
  out-of-stock (AC-5); **refund-on-failure** with a forced-fail `MockFulfillmentClient` (AC-6); **partner
  idempotency** via a mocked adapter recording `external_id` (AC-7); history scoping (AC-8); XP-untouched
  (AC-9); surprise seeded-roll distribution + net-positive (AC-10, Phase B); delete cascade (AC-12);
  *(Phase C)* sweepstakes entry idempotency/one-per-user, geo/age gate, AMOE-equal-standing, scheduled-draw
  seeded selection. Claude/Bedrock not involved. `cdk synth -c stage=beta` for the new routes/grants.
  Keep all numerics `int`; black(100)+flake8(120).
- **iOS (`make ios-test` / ⌘U):** `RewardsDTOTests` (decode the new DTOs from sample JSON — contract);
  `RewardEligibilityTests` (pure affordable/locked/stock formatting if any client-side derivation);
  a `FakeAPIClient`-backed `RewardsService` flow (catalog → redeem → history; retry reuses the
  idempotency key). Manual: Reduce-Motion celebration, Dynamic-Type, dark mode, VoiceOver on locked/stock
  states; offline degradation.
- **Manual / operational:** on Beta with a real (sandbox) partner key in Secrets Manager — redeem a gift
  card end-to-end, force a partner error and confirm refund, run the reconciliation sweeper against a
  stuck `reserved` row. *(Phase C, only post-legal:)* dry-run a sweepstakes with test official rules, both
  entry methods, a scheduled draw, and the winner-verification/1099 path.

## 9. Rollout & migration
- **Flags (default off; enable per phase on Beta → soak → Prod):** `rewardsEnabled` (Phase A),
  `surpriseDropsEnabled` (Phase B), `sweepstakesEnabled` (Phase C — **plus** a hard counsel-sign-off gate).
- **Dependencies:** **`0023`** (credits ledger + conditional decrement — **blocking**; this spec spends
  what `0023` defines), Cognito sign-in (`0003`) for redeem, and the `0013` gamification components for
  celebration. Catalog/pool items and any partner account are **admin-seeded/configured** out of band.
- **Data:** new items are additive to the single table; no migration of existing rows. Coupon pools are
  loaded by an admin job. The redemption/idempotency rows carry a **TTL** for housekeeping (issued codes'
  audit retained per policy).
- **Backward-compat / teardown:** all routes are additive; disabling a flag hides the surface and stops its
  writes. Pausing a reward (`status=paused`) removes it from the catalog without deleting history.
- **Partner / region:** Phase A can launch US-first (region-gated catalog) and widen as partner coverage
  allows; **sweepstakes stays US-only** until non-US counsel review (§10).

## 10. Risks & open decisions

### 10A. Sweepstakes / promotion-law (the crux — Phase C blocker)
> **This section is the reason trips are Phase C and flagged. It is engineering's summary of why
> qualified promotion-law counsel must drive the sweepstakes design — not a substitute for that advice.**

- **R-1 Illegal-lottery trifecta (existential).** A promotion that awards a prize **by chance** is an
  **illegal lottery** if entrants give **consideration**. The three elements are **prize + chance +
  consideration**; remove any one and it is not a lottery. Since trips (prize) are awarded by draw
  (chance), we **must remove consideration** — hence a **no-purchase-necessary** design with a genuine
  **AMOE**. *Mitigation:* model sweepstakes as **entries + draw** with a **free Alternate Method of
  Entry of equal dignity/odds**; **credits/IAP currency must never be required to enter** (also Apple
  5.x). Note some states treat **significant non-monetary effort** as consideration too, so the AMOE must
  be genuinely easy. **Counsel-reviewed.**
- **R-2 State registration & bonding.** When the **aggregate retail prize value exceeds $5,000**, **New
  York** and **Florida** require **registering and bonding** the sweepstakes and filing the official
  rules (NY: ≥ **30 days** before start, with a surety bond + trust account; FL: ≥ **7 days** before, bond
  + post-promotion winners list within 60 days). **Rhode Island** requires registration for **retail**
  promotions when prizes exceed **$500** (no bond). A trip easily clears these thresholds. *Mitigation:*
  budget registration/bond lead time into the launch; counsel files; consider capping prize value or
  excluding states to manage burden (a common, legitimate tactic).
- **R-3 Official rules & disclosures.** Must publish complete **official rules** (sponsor identity,
  eligibility, **start/end/draw dates**, **odds depend on number of entries**, **free AMOE** instructions,
  prize description + **approximate retail value**, winner-selection method/date, how winners are notified,
  **"NO PURCHASE NECESSARY; A PURCHASE WILL NOT INCREASE YOUR CHANCES OF WINNING,"** and that **the
  promotion is void where prohibited**). Apple additionally requires that the rules state **Apple is not a
  sponsor/involved**. *Mitigation:* host official rules (URL in `SweepstakesDTO`), show in-app, gate entry
  behind viewing them.
- **R-4 Eligibility / age / geo.** Restrict to **US residents** (specified states), **18+ (or 19/21 where
  required)**, exclude employees/affiliates. *Mitigation:* **geo-gate (US-only)** and **age-gate** entry
  (FR-11/AC-15); store the attestation; counsel sets the exact eligibility.
- **R-5 Tax (1099-MISC) & winner verification.** Prizes are **taxable income to the winner** ("Winner is
  responsible for all taxes"). Historically a **Form 1099-MISC** issued at **≥ $600**; under the **One Big
  Beautiful Bill Act**, for **prizes awarded in 2026 the reporting threshold is $2,000** (inflation-adjusted
  thereafter) — collect the winner's info (incl. **SSN**) and issue a 1099-MISC **only** when the prize is
  **≥ that threshold**. A trip will exceed it. *Mitigation:* winner **affidavit of eligibility + liability/
  publicity release**, **W-9** collection where required, encrypted/scoped PII (NFR-5), erasable (FR-12);
  state the tax language in the official rules. **Confirm the then-current threshold with counsel at launch.**
- **R-6 Non-US jurisdictions differ materially.** Many countries (and Canadian provinces — e.g. **Québec**
  historically required registration/fees; a **skill-testing question** is commonly used) impose their own
  registration, language, and "no consideration" rules. *Mitigation:* **US-only** in v1; do **not** offer
  sweepstakes outside reviewed jurisdictions; geo-gate hard.
- **R-7 Apple App Review (5.x / 3.2.1).** Sweepstakes/contests must be **sponsored by the developer**, show
  **official rules** in-app, state **Apple is not a sponsor**, and comply with **local law**; apps **may not
  use IAP to purchase currency for real-money gaming** or to **enter lotteries/raffles**. *Mitigation:* our
  design keeps entry **free (AMOE)** and **never** spends IAP-purchased credits to enter; we are the sponsor;
  rules + Apple disclaimer shown. (Coupons/gift-card **redemption** for earned credits is ordinary loyalty
  and not implicated — another reason Phase A is low-risk.)
- **R-8 "Surprise reward" must not become an illegal/￠gambling mechanic.** Because the surprise involves
  **chance**, keep it free of **consideration and prize-of-value-by-purchase**: it's a **bonus on top of a
  guaranteed reward**, **never** purchasable, **never** money, odds **published**, roll **logged**. That
  keeps it outside the lottery/loot-box framing. *Mitigation:* the FR-9 guardrails + AC-10; if product ever
  wants paid randomness, that is a **new spec with counsel**, not this one.

### 10B. Engineering / product risks
- **R-9 Double-spend / double-issue / partial failure.** *Mitigation:* conditional decrement, idempotency
  guard row, partner `external_id`, refund path, reconciliation sweeper (§6.3; AC-3/4/6/7).
- **R-10 Fraud / self-dealing / farming.** Multi-account abuse, referral self-dealing, velocity attacks.
  *Mitigation:* per-user/per-reward caps, velocity/anomaly freeze, audit log, one-entry-per-person for
  sweepstakes, server-authoritative everything (NFR-3).
- **R-11 Partner outage / cost / catalog drift.** *Mitigation:* reserve→fulfill→refund tolerates partner
  failure; bounded timeouts; `MockFulfillmentClient` for non-prod; pause rewards via `status`.
- **R-12 Engagement-vs-ethics tension.** Rewards are a strong lever. *Mitigation:* the §6.4 guardrails (no
  loot boxes/scarcity/coercion), restrained celebration, honest odds, and instrument redeem/disable rates as
  a coercion alarm (GAMIFICATION §5/§6).
- **R-13 Credits become "real money"-like.** If credits buy gift cards, regulators/Apple may scrutinize how
  credits are obtained. *Mitigation:* keep **earned** credits the primary path; if `0023` allows **buying**
  credits, ensure redemption of purchased credits for gift cards is reviewed (gift-card-for-cash and money-
  transmission concerns sit with the **licensed partner**, not us) — **flag for counsel** (D-5).

### Decisions needed (with recommendations)
- **D-1 (recommended: `0023` owns the credit primitive; this spec calls a shared spend/refund module).**
  Whether spend/refund lives in `0023`'s module or is re-implemented here against the agreed key.
- **D-2 (recommended: ship Phase A coupons + gift cards first; sweepstakes is a later, counsel-gated phase).**
  Launch scope/order.
- **D-3 (recommended: Tremendous-style adapter with `external_id` idempotency; `MockFulfillmentClient`
  default off-prod).** Fulfillment provider + interface.
- **D-4 (recommended: server-side idempotency-key guard row + partner external_id).** Idempotency mechanism.
- **D-5 (recommended: keep earned credits the primary redemption source; legal-review buying-credits→gift-cards
  before enabling).** How purchased credits interact with gift-card redemption.
- **D-6 (recommended: authorized catalog so eligibility is personalized; unauth allowed with eligibility
  omitted).** Catalog auth.
- **D-7 (recommended: US-only sweepstakes, geo+age gated, free AMOE, value capped/states excluded to limit
  registration burden — all per counsel).** Sweepstakes jurisdiction/structure.
- **D-8 (recommended: published-odds surprise is bonus-only, never purchasable; any paid randomness is a new
  spec).** Surprise-reward boundary.

## 11. Tasks & estimate
1. **OpenAPI** additions (`/v1/rewards`, `/v1/rewards/{id}/redeem`, `/v1/me/rewards`; Phase-C sweepstakes
   paths noted) + matching **`DTOs.swift`** structs. **(M)**
2. `backend/src/shared/idempotency.py` — conditional idempotency-key guard helper + pytest. **(S)**
3. `backend/src/shared/rewards.py` — eligibility compute, **pool atomic claim**, redemption **state machine**
   (reserve→fulfill→refund) + pytest. **(L)**
4. `backend/src/shared/fulfillment.py` — `FulfillmentClient` + `MockFulfillmentClient` + a Tremendous/Tango
   adapter (external_id idempotency, Secrets-Manager key) + pytest with a mocked partner. **(M)**
5. `backend/src/handlers/rewards.py` — `GET /v1/rewards`, `POST …/redeem` (idempotent spend→issue→refund),
   `GET /v1/me/rewards` + pytest (AC-1..AC-9). **(L)**
6. `api_stack.py` — new Lambdas + routes + **least-privilege** grants (catalog read-only; redeem read-write +
   gift-card secret); `cdk synth` per stage (AC-11). **(M)**
7. **iOS** `Features/Rewards/` — `RewardsView` + `RewardCard` + `RewardDetailView`/redeem sheet +
   `RedemptionHistoryView` + `RewardsService` (idempotency-key reuse) + `Route` cases + `MangoSymbol`
   additions + Profile entry. **(L)**
8. iOS tests — `RewardsDTOTests`, `RewardEligibilityTests`, `RewardsService` `FakeAPIClient` flow (AC-13). **(M)**
9. **Reconciliation sweeper** (EventBridge) for stuck `reserved` redemptions (re-fulfill via external_id or
   refund) + pytest. **(M)**
10. *(Phase B)* Milestone **reward drops** + **transparent surprise** (server seeded/logged roll, published
    odds) + `SurpriseDropView` + celebration wiring (`0013`) + pytest (AC-10). **(M)**
11. *(Phase B)* `DELETE /v1/me` cascade for redemptions/entries/PII (with 0004) + pytest (AC-12). **(S)**
12. *(Phase C — only after Legal sign-off)* Sweepstakes: `handlers/sweepstakes.py` (enter incl. **free AMOE**,
    geo/age gate, one-entry) + `handlers/sweep_draw.py` (scheduled seeded draw) + winner verification +
    1099/affidavit flow + official-rules surfacing + `SweepstakesView` + pytest (AC-15). **(L)**
13. Anti-abuse: per-user/per-reward caps, velocity/anomaly freeze, audit log + pytest. **(M)**
14. Manual Beta e2e (sandbox partner): redeem, forced-fail refund, sweeper; (Phase C) sweepstakes dry-run. **(M)**

## 12. References
**Repo (read for accuracy):**
- `docs/GAMIFICATION.md` — ethics manifesto (§6: no deceptive variable rewards / loot boxes; §2a XP never
  decays/spent; §2d white-hat surprise = bonus on top of guaranteed, never money), the basis for §6.4.
- `working/0023-payments-and-credits.md` — **credits currency + ledger + conditional-decrement spend**
  (this spec's blocking dependency; the spend/refund primitive reused in §6.2/§6.3). *(Authoring note: at
  time of writing 0023 is the planned upstream M12 spec; confirm its module/key names — D-1.)*
- `working/0013-design-system-iconography-gamification.md` — `MangoSymbol`/`Icon`, `LevelUpCelebration`,
  `ConfettiBurst`, `AchievementChip`, Reduce-Motion rules (reused by the Rewards UI).
- `working/0021-social-leagues.md` — single-table access-pattern + GSI1 + anti-cheat + least-privilege
  conventions mirrored here.
- `backend/mango_backend/data_stack.py` (single table `PK`/`SK` + `GSI1`, no-float), `api_stack.py`
  (route wiring + least-privilege IAM, Secrets-Manager grant pattern), `backend/src/shared/response.py`
  (`user_id` → `USER#<sub>`; dev `x-mango-user` fallback only outside prod/beta).
- `ios/Mango/App/AppModel.swift` (`apiClient()`/service container), `ios/Mango/Services/Networking/APIClient.swift`
  (thin async client; auth header), `ios/Mango/Services/Networking/DTOs.swift` (contract structs),
  `ios/Mango/Features/Profile/ProfileView.swift` (level/XP/streak surface the Rewards screen sits beside).
- `shared/api/openapi.yaml` (extend), `docs/specs/SPEC_TEMPLATE.md` (this format), `CLAUDE.md` (invariants).

**Research (web) — fulfillment & rewards:**
- Tremendous — *Create order* (idempotency via `external_id`): https://developers.tremendous.com/reference/create-order ;
  Gift Card API overview: https://www.tremendous.com/gift-card-api/
- Tango Card (Blackhawk) — Gift Card / Rewards (RaaS) API: https://www.tangocard.com/gift-card-api
- Ethical gamification / transparent rewards vs loot boxes (published odds, predictable rewards):
  https://www.gamerbolt.com/beyond-the-loot-box/ ; UK loot-box odds-disclosure compliance study:
  https://journals.plos.org/plosone/article?id=10.1371%2Fjournal.pone.0286681

**Research (web) — sweepstakes / promotion law & Apple (the crux; verify with counsel):**
- Prize + chance + consideration / No-Purchase-Necessary / AMOE: https://ussweeps.com/about-us/blog/sweepstakes-law/sweepstakes-101/ ;
  AMOE removes consideration: https://www.snipp.com/blog/no-purchase-necessary-laws-and-amoe-for-sweepstakes
- State registration & bonding (NY/FL > $5,000; RI retail > $500; filing lead times):
  https://kleinmoynihan.com/sweepstakes-registration-and-bonding-requirements-2/ ;
  https://www.thompsoncoburn.com/insights/do-you-need-to-register-your-sweepstakes/
- Prize tax / 1099-MISC — **$600 historically; $2,000 for prizes awarded in 2026 (One Big Beautiful Bill
  Act), inflation-adjusted thereafter; winner responsible for taxes**:
  https://www.verrill-law.com/blog/the-new-2000-threshold-for-sending-irs-form-1099-misc-to-prize-winners/
- Apple App Review Guidelines (sweepstakes sponsored by developer, official rules, Apple-not-a-sponsor;
  no IAP currency for lotteries/raffles/real-money gaming; comply with local law):
  https://developer.apple.com/app-store/review/guidelines/
