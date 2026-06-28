# 0023 — Payments & credits (StoreKit IAP + server credit ledger)

- **Epic:** M12 · **Status:** Draft · **Owner:** unassigned · **Updated:** 2026-06-28
- **Reviewers:** Principal / SD / QA / Legal

## 1. Summary
Introduce a **credits economy** for Mango's AI generation. Generating a learning roadmap **costs
credits**; **completing a roadmap earns credits back**; users can **buy more credits** through
**Apple In-App Purchase (StoreKit 2 consumables)**. The server owns the only authoritative balance:
a per-user **credit item** (`USER#<sub>/CREDITS`, integer `balance` + `version`) backed by an
**append-only ledger** (`USER#<sub>/CREDITLEDGER#<ts>#<uuid>`). Spending is an **atomic DynamoDB
conditional update** (`balance >= cost`) that returns **HTTP 402** when the balance is too low;
earning and purchasing are **idempotent**. Purchases are verified **server-side** from the signed
StoreKit 2 `Transaction` (JWS) and reconciled by **App Store Server Notifications V2** so refunds and
revocations claw credits back. The client never asserts a balance — it reads it from the backend and
shows a credits/paywall surface built entirely from `DesignSystem/` tokens. New endpoints
(`GET /v1/me/credits`, `POST /v1/credits/purchase`, `POST /v1/credits/notifications`) are added to
`shared/api/openapi.yaml`, and the existing `POST /v1/roadmaps/generate` is gated. No third-party iOS
dependencies; backend stays stdlib + boto3.

## 2. Goals / Non-goals
- **Goals:**
  - A **server-authoritative credit ledger** in the existing single table, **float-free** (integers
    only), with an append-only audit trail and optimistic concurrency (`version`).
  - **Atomic spend** on roadmap generation (decrement on accept, **402** when insufficient,
    **refund on generation failure**), and **idempotent earn** on roadmap completion (exactly once
    per roadmap).
  - **Consumable IAP** credit packs via **StoreKit 2**, with **server-side JWS verification**
    (App Store Server API), **idempotency** by `transactionId`/`originalTransactionId`, and an
    **App Store Server Notifications V2** webhook for refunds/revocations.
  - A first-class **iOS `PurchaseService`** (products, purchase, `Transaction.updates` listener,
    finishing transactions) + a **Credits / paywall** screen and an **out-of-credits** UX (buy or
    earn), all using `Palette`/`Typo`/`Metrics`/`Haptics` tokens.
  - Keep the contract in lockstep: `openapi.yaml` ⇄ `DTOs.swift` ⇄ handlers; preserve all repo
    invariants (offline-first, Bedrock-only AI, least-privilege IAM, no `float` in DynamoDB).
  - A concrete **starting economy** (free grant, generation cost, completion reward, example pack
    SKUs/prices, abuse limits) that is easy to tune later (cross-ref `0024-rewards-and-coupons.md`).
- **Non-goals:**
  - **Auto-renewing subscriptions** (a "Mango Plus" monthly that refills credits) — noted as a
    forward option in §10 / D-7 but **not built** here.
  - **Android / Google Play Billing** — Mango is iOS-only today (`CLAUDE.md`); the ledger is designed
    store-agnostic, but only the Apple processor ships.
  - **The full rewards/coupon system** (streak/daily bonus credits, promo codes, referral grants) —
    those live in `0024-rewards-and-coupons.md`; here we only reserve the `earned_*`/`admin_adjust`
    ledger reasons and the bonus-credit grant seam.
  - **Charging for grading** (`/v1/exercises/grade`) or content parsing (`/v1/content/parse`) — only
    **roadmap generation** is metered in v1 (it is the expensive, user-initiated Bedrock call).
  - **A billing/finance dashboard** — ledger is queryable in DynamoDB/Athena; UI reporting is out of
    scope (the data-lake events in §6.9 make it possible later).
  - **Replacing the offline path.** Mock / Direct-Claude modes do **not** touch credits (see §6.10);
    credits only apply when the **Mango Backend** (`RemoteAIService`) is the active AI provider.

## 3. Background & context
**Why now.** Roadmap generation is the one expensive, user-initiated server action: it runs a
Bedrock Claude call (`backend/src/handlers/generate_roadmap.py` → `shared.claude.generate_roadmap`,
the `RoadmapFn` Lambda is provisioned at `timeout=60, memory=512` in
`backend/mango_backend/api_stack.py`). Today it is **unmetered** — any authenticated caller can
generate unlimited roadmaps, which is both a cost risk and a missed monetization/engagement loop. A
credits economy turns generation into a resource the user **earns by doing the work** (finishing
journeys) and can **top up** — reinforcing the activity-first product thesis (`0008`) while creating
the only App-Store-compliant way to sell digital value in the app.

**Current relevant state (verified):**
- **AI gating point.** `generate_roadmap.handler` (verified) is **synchronous**: it loads text
  (inline `book.text` or a stored `bookId` from S3), calls `claude.generate_roadmap(...)`, and
  returns `ok(roadmap)` (HTTP 200). There is **no `jobId`/202 async path** in the live
  `shared/api/openapi.yaml` (the async variant referenced in `0008` §6.7 is **not** in the contract;
  v1 of this spec targets the **synchronous** handler — see D-6 for the async-ready design). This is
  where the **spend** (pre-call) and **refund-on-failure** (in the `except`) hooks go.
- **Identity.** `shared/response.user_id(event)` (verified) resolves the caller to the **Cognito
  `sub`** from `event.requestContext.authorizer.jwt.claims` and raises `PermissionError` in
  `prod`/`beta` when claims are missing (returned as 401 by handlers). All credit items key off
  `USER#<sub>`. The same `sub` is the **`appAccountToken`** the iOS client attaches to purchases so a
  StoreKit transaction maps back to the Mango user.
- **Single table.** `data_stack.py` (verified): one `PAY_PER_REQUEST` table, `PK`/`SK` strings, one
  `GSI1` (`GSI1PK`/`GSI1SK`), prod PITR on. The credit item and ledger entries are new SK shapes on
  the **same** table (no new infra). `0004-data-model-and-lake.md` documents the entity/key
  conventions this spec extends.
- **Write/idempotency idioms.** `progress.py` (verified) coerces numerics to `int` and decodes
  `Decimal`→`int` (the float-free invariant); `library.py` (verified) shows the per-user write +
  `GSI1` `ADDED#<ts>` listing idiom and the `USER#<sub>` keying. The ledger reuses both idioms.
- **API/route pattern.** `api_stack.py` (verified) builds thin Lambdas via `make_fn(...)`, wires
  routes with the local `route(path, method, fn, secured=True)` helper, and applies an
  `HttpUserPoolAuthorizer`. Least-privilege grants are explicit (`grade_fn` has **no** table access).
  New credit Lambdas follow this exactly. The **notifications** webhook route is **`secured=False`**
  (Apple cannot present a Cognito JWT) and is authenticated by **JWS signature verification** inside
  the handler instead.
- **iOS wiring.** `AppModel` (verified, `@Observable` service container) exposes `apiClient()` →
  `APIClient?` (carries the Cognito id token; `nil` when offline). `APIClient` (verified) already
  surfaces non-2xx as `APIError.badStatus(code, body)` — the **402** maps here. `AIServiceProvider`
  (verified) selects `RemoteAIService` vs `DirectClaudeAIService` vs `MockAIService` from
  `AppSettings.apiEnvironment`; credits apply only to the `RemoteAIService` path. `DTOs.swift` is the
  contract mirror; `SettingsView`/`ProfileView` (verified) are where a "Credits" entry slots in.
- **Apple's rule (the load-bearing constraint).** Digital content — explicitly including **"credits"
  and reward points** — **must** be sold via **In-App Purchase**; apps may **not** use external
  payment mechanisms, license keys, or crypto to unlock in-app value (App Review Guideline **3.1.1**,
  see §12). **Stripe/PayPal are not an option for buying credits.** Therefore the purchase processor
  is **StoreKit 2 consumables**, verified server-side.

**Why a server ledger (not on-device counters).** Balances control spend on a paid backend call, so
they **cannot** be trusted from the client (a jailbroken device could mint credits). The server is
the single source of truth; the app only **displays** the balance returned by
`GET /v1/me/credits`. This mirrors `progress.py`'s server-owned model and Apple's own guidance to
verify transactions server-side rather than trust the device.

## 4. User stories
- As a **new user**, I get a **free starting balance** of credits so I can generate my first one or
  two roadmaps without paying — preserving the offline-first first-run (the bundled sample + Mock AI
  need **no** credits at all).
- As an **engaged learner**, when I **finish a roadmap** I'm rewarded with **credits**, so doing the
  work funds my next journey — the loop is self-sustaining for active users.
- As a **power user**, when I run low I can **buy a credit pack** (e.g. "Starter / Plus / Pro")
  through the normal Apple purchase sheet, and my new balance appears immediately and is restored if
  I reinstall.
- As a **user who hits zero**, when I try to generate and have **no credits**, I see a clear,
  friendly screen explaining I can **earn** credits by finishing a journey **or buy** a pack — never a
  dead end, never a raw error.
- As a **customer who requests a refund**, Apple refunds my pack and the app **removes** those
  credits from my balance (it may go negative and simply blocks generation until I earn/buy more),
  with no way to "spend then refund" for free generation.
- As **Mango (the business)**, every credit grant/spend is **auditable** (append-only ledger) and
  **idempotent**, so retries, duplicate notifications, and replays never double-credit or
  double-charge.

## 5. Requirements
### 5.1 Functional
- **FR-1 (credit item).** Each user has exactly one `USER#<sub>/CREDITS` item with integer `balance`,
  integer `version` (optimistic-concurrency counter), `updatedAt`, and `lifetimeEarned` /
  `lifetimePurchased` / `lifetimeSpent` integer roll-ups. Absent item ⇒ treated as a brand-new user
  eligible for the **signup grant** (FR-2).
- **FR-2 (signup grant).** On first credit-affecting interaction (first `GET /v1/me/credits` or first
  generate), if no `CREDITS` item exists, atomically create it with `balance = SIGNUP_GRANT`
  (default **30**) and append a ledger entry `reason=signup_grant`. Idempotent: the create is
  conditional on the item not existing, so concurrent first-calls grant exactly once.
- **FR-3 (atomic spend on generate).** `POST /v1/roadmaps/generate` first **decrements** `balance`
  by `GENERATION_COST` (default **10**) via a **conditional `UpdateItem`** (`balance >= cost`); on
  the condition failing return **HTTP 402** `{ "error": "insufficient_credits", "balance": N,
  "cost": C }` and **do not** call Bedrock. On success, proceed to generation; append ledger
  `reason=spent_generation` with the roadmap/book ref and a generated `spendId`.
- **FR-4 (refund on generation failure).** If Bedrock generation throws **after** a successful
  decrement, **credit the cost back** (append `reason=refund_generation_failure`, same `spendId`
  ref, idempotent on `spendId`) before returning 5xx, so a failed paid call never costs the user.
- **FR-5 (earn on completion, exactly once).** When a roadmap is **completed**, grant
  `COMPLETION_REWARD` credits (default **15**) **idempotently keyed by the roadmap/journey id** so a
  given roadmap rewards **at most once** (append `reason=earned_completion`, ref = roadmap id). The
  **trusted completion signal** is server-validated (§6.6) — not a raw client claim of "I'm done".
- **FR-6 (buy credits / IAP).** `POST /v1/credits/purchase` accepts a **signed StoreKit 2
  transaction (JWS)**, **verifies** it with Apple server-side (§6.5), maps the purchased **product id
  → pack credit amount** (server-side table, FR-12), credits the user **idempotently by
  `transactionId`**, appends `reason=purchased` (refs: `productId`, `transactionId`,
  `originalTransactionId`), and returns the **new balance**. Re-submitting the same `transactionId`
  is a no-op returning the same balance (200).
- **FR-7 (refund/revocation reconciliation).** `POST /v1/credits/notifications` receives **App Store
  Server Notifications V2** (`signedPayload` JWS). On `REFUND` / `REVOKE` (and consumable
  charge-backs) for a previously-granted `transactionId`, **debit** the pack's credits (append
  `reason=refund_revoke`), idempotent per `(transactionId, notificationType)`. Balance may go
  **negative** (generation simply blocked until ≥ cost). Always respond **200** quickly even on
  unknown/duplicate notifications (Apple retries on non-2xx).
- **FR-8 (read balance + history).** `GET /v1/me/credits` returns the current `balance`, `version`,
  the lifetime roll-ups, and the **most recent N (default 20)** ledger entries (newest first) for an
  in-app history view. Auto-creates the signup grant if absent (FR-2).
- **FR-9 (client never asserts balance).** The iOS app **reads** balance from the backend and renders
  it; it never sends a balance to the server and never gates generation purely on a cached number
  (it may *predict* "you'll need 10" for UX but the server is authoritative — a stale client just
  gets a 402 and refreshes).
- **FR-10 (out-of-credits UX).** When generation returns **402**, the app surfaces an out-of-credits
  sheet offering **Buy credits** (paywall) and **Earn credits** (deep-link to an in-progress journey
  / "finish a journey to earn"), not a generic error toast.
- **FR-11 (StoreKit client).** A `PurchaseService` loads products via `Product.products(for:)`,
  initiates `product.purchase(options:[.appAccountToken(<cognitoSub UUID>)])`, runs a
  `Transaction.updates` listener started at launch, **POSTs each verified transaction's JWS to
  `/v1/credits/purchase`**, and **only `finish()`es the transaction after the backend confirms the
  grant** (so a crash before confirmation re-delivers it).
- **FR-12 (server-side product catalog).** Product-id → credit-amount mapping lives **server-side**
  (a constant table in `shared/credits.py`), so the credit value of a pack is never decided by the
  client. The same ids are configured as **consumable** IAPs in App Store Connect and mirrored in the
  app's `.storekit` config for local testing.
- **FR-13 (no charging in offline/direct modes).** When the active AI provider is **not**
  `RemoteAIService` (i.e. Mock or Direct-Claude), the app **does not** spend or display credits;
  generation runs as today. Credits are a property of the **Mango Backend** environment only.

### 5.2 Non-functional
- **NFR-1 (float-free).** No `float` ever reaches DynamoDB. All credit amounts are **integers**;
  reads coerce `Decimal`→`int` exactly like `progress.py._to_plain`. (Invariant, `CLAUDE.md`.)
- **NFR-2 (atomicity & idempotency).** Spend/earn/purchase/refund are each a **single conditional
  write** (or a guarded transaction) so concurrent/retried calls cannot double-apply. Idempotency
  keys: `transactionId` (purchase), `(transactionId, notificationType)` (refund), roadmap id
  (completion earn), `spendId` (generation spend/refund).
- **NFR-3 (security).** Purchases are verified by **Apple's signature**, never trusted from the
  client body alone; the notifications endpoint verifies the **JWS x5c chain to Apple Root CA - G3**
  and checks `bundleId`/`environment` before mutating. The client balance is **display-only**. No
  payment card data ever touches Mango (Apple handles payment).
- **NFR-4 (least privilege).** Only the new credit Lambdas (and the gated `roadmap_fn`) get
  read/write on the table for credit items; the notifications Lambda needs table + (optionally)
  Secrets Manager for the App Store Server API key; `grade_fn` stays table-less. (Invariant,
  `api_stack.py`.)
- **NFR-5 (offline-first preserved).** First launch with Mock AI + bundled sample needs **no**
  network, **no** auth, and **no** credits (NFR per `CLAUDE.md`). Credits UI degrades to hidden/"sign
  in to sync" when offline.
- **NFR-6 (backend style/runtime).** stdlib + boto3 only (JWS verification via stdlib + a vendored
  pure-python verify, or boto3 KMS-free local crypto — see D-2); black (line-length 100) + flake8
  (max 120); `pytest` (moto) + `cdk synth -c stage=beta` both pass offline.
- **NFR-7 (design system).** All new iOS UI uses `Palette`/`Typo`/`Metrics`/`Haptics`; **no raw hex
  or magic numbers** (`CLAUDE.md` style). Warm cream + terracotta retained; credit/coin motif uses
  `Palette.xp` (the existing gold token) so it reads as "earned value."
- **NFR-8 (cost & abuse).** Generation cost > 0 caps runaway Bedrock spend; per-user **daily
  generation cap** and **purchase velocity** guardrails (§6.7) mitigate abuse and runaway grants.
- **NFR-9 (accessibility).** Paywall and out-of-credits surfaces have large tap targets, Dynamic Type
  via `Typo`, VoiceOver labels ("Buy 100 credits for $4.99", "You have 8 credits"), and clear pricing
  pulled from `Product.displayPrice` (localized, never hardcoded).

## 6. Design

### 6.1 Data model (single table — extends `0004`)
All new items live on the existing table (`PK`/`SK` strings; `GSI1` reused). **No new infra.**

| Entity | PK | SK | GSI1PK / GSI1SK | Key attributes |
|---|---|---|---|---|
| **Credit balance** | `USER#<sub>` | `CREDITS` | — | `balance:int`, `version:int`, `lifetimeEarned:int`, `lifetimePurchased:int`, `lifetimeSpent:int`, `updatedAt` |
| **Ledger entry** | `USER#<sub>` | `CREDITLEDGER#<ts>#<uuid>` | `USER#<sub>` / `LEDGER#<ts>` | `delta:int`, `balanceAfter:int`, `reason:str`, `refType:str?`, `refId:str?`, `createdAt` |
| **Purchase receipt (idempotency)** | `USER#<sub>` | `PURCHASE#<transactionId>` | — | `productId`, `originalTransactionId`, `credits:int`, `status:str` (`granted`/`revoked`), `createdAt` |
| **Notification log (idempotency)** | `APPLE#NOTIF` | `<transactionId>#<notificationType>` | — | `processedAt`, `outcome` |

- **`reason` enum (closed set):** `signup_grant`, `purchased`, `earned_completion`,
  `spent_generation`, `refund_generation_failure`, `refund_revoke`, `admin_adjust`. (Reserve
  `earned_bonus` for `0024` streak/daily bonuses.)
- **Ledger is append-only** and ordered by `ts` (a zero-padded epoch-millis or ISO-8601 string) so
  `GET /v1/me/credits` can return recent entries via a `begins_with("CREDITLEDGER#")` query with
  `ScanIndexForward=False, Limit=N`. (Mirrors `library.py`'s `begins_with` listing.)
- **`PURCHASE#<transactionId>`** is the **idempotency anchor** for IAP: granting is conditional on
  this item **not** existing (`attribute_not_exists(PK)`), so a replayed `transactionId` no-ops.
- **`APPLE#NOTIF`** partition de-dupes Apple's at-least-once notifications by
  `(transactionId, notificationType)`.
- **Float-free:** every numeric attribute above is an `int`. Reads coerce `Decimal`→`int` (reuse a
  `_to_plain` helper, copied from `progress.py`).

### 6.2 Atomic operations (DynamoDB)
**Spend (generate) — single conditional update, then ledger append:**
```python
# shared/credits.py  (logic; handler stays thin)
def spend(uid: str, cost: int, *, ref_type: str, ref_id: str) -> dict:
    """Atomically debit `cost` credits. Raises InsufficientCredits if balance < cost."""
    t = table()
    key = {"PK": f"USER#{uid}", "SK": "CREDITS"}
    try:
        resp = t.update_item(
            Key=key,
            UpdateExpression=(
                "SET balance = balance - :c, lifetimeSpent = lifetimeSpent + :c, "
                "version = version + :one, updatedAt = :now"
            ),
            ConditionExpression="attribute_exists(PK) AND balance >= :c",
            ExpressionAttributeValues={":c": cost, ":one": 1, ":now": _now_iso()},
            ReturnValues="ALL_NEW",
        )
    except t.meta.client.exceptions.ConditionalCheckFailedException:
        bal = get_balance(uid)            # may auto-create the signup grant, then re-read
        raise InsufficientCredits(balance=bal, cost=cost)
    new_balance = int(resp["Attributes"]["balance"])
    _append_ledger(uid, delta=-cost, balance_after=new_balance,
                   reason="spent_generation", ref_type=ref_type, ref_id=ref_id)
    return {"balance": new_balance}
```
- **Insufficient → 402.** The handler catches `InsufficientCredits` and returns
  `json_response(402, {...})`. Add a `payment_required(...)` helper to `shared/response.py` (see
  §6.8). Bedrock is **not** invoked.
- **Refund on failure (idempotent).** In `generate_roadmap`'s `except`, call `credit(uid, cost,
  reason="refund_generation_failure", ref_type="spend", ref_id=spend_id)` where `credit` is
  conditional-on-no-prior-refund-for-`spend_id` (write a `REFUNDED#<spendId>` marker or check the
  ledger) so a retried failure refunds once.
- **Earn (completion) — idempotent grant keyed by roadmap id:**
```python
def grant_completion(uid: str, roadmap_id: str, reward: int) -> dict:
    """Grant `reward` once per roadmap. No-op (returns current balance) if already granted."""
    marker = {"PK": f"USER#{uid}", "SK": f"EARNED#ROADMAP#{roadmap_id}"}
    try:
        table().put_item(Item={**marker, "createdAt": _now_iso()},
                         ConditionExpression="attribute_not_exists(PK)")
    except ConditionalCheckFailed:
        return {"balance": get_balance(uid), "granted": False}   # already earned
    new = _add_credits(uid, reward, field="lifetimeEarned")      # unconditional add to CREDITS
    _append_ledger(uid, delta=reward, balance_after=new, reason="earned_completion",
                   ref_type="roadmap", ref_id=roadmap_id)
    return {"balance": new, "granted": True}
```
- **Purchase grant — idempotent by `transactionId`:** write `PURCHASE#<transactionId>` conditional on
  `attribute_not_exists`; on success add credits + ledger (`purchased`); on `ConditionalCheckFailed`
  return the existing balance (replay-safe).

> **Why not a single `TransactWriteItems` for spend+ledger?** A conditional `UpdateItem` for the
> balance is the atomic gate; the ledger append is a follow-on audit write. If strict
> all-or-nothing is required, wrap both in `TransactWriteItems` (balance update with the same
> condition + ledger `Put`) — recommended for `purchase`/`refund` where the receipt item **must**
> co-commit with the balance. Spend can use the simpler 2-step (the gate is the balance update; a
> rare ledger-write failure is logged and reconciled, never double-spends).

### 6.3 API / contract (add to `shared/api/openapi.yaml`)
Three new paths; one existing path gains a **402** response. Keep `DTOs.swift` and the handlers in
lockstep (sync note at the end of this section).

```yaml
  /v1/me/credits:
    get:
      summary: Read the caller's credit balance and recent ledger
      responses:
        "200":
          description: Balance + recent ledger
          content:
            application/json:
              schema: { $ref: "#/components/schemas/CreditsState" }
        "401": { description: Unauthenticated }
  /v1/credits/purchase:
    post:
      summary: Verify a StoreKit 2 transaction and grant pack credits (idempotent by transactionId)
      requestBody:
        required: true
        content:
          application/json:
            schema: { $ref: "#/components/schemas/PurchaseRequest" }
      responses:
        "200":
          description: Verified + granted (or replay no-op); returns new balance
          content:
            application/json:
              schema: { $ref: "#/components/schemas/CreditsState" }
        "400": { description: Malformed transaction }
        "402": { description: Verification failed / not a known product }
        "401": { description: Unauthenticated }
  /v1/credits/notifications:
    post:
      summary: App Store Server Notifications V2 webhook (refund/revoke reconciliation)
      security: []          # Apple cannot present a Cognito JWT; auth is JWS signature verification
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
              required: [signedPayload]
              properties:
                signedPayload: { type: string, description: "JWS (ES256) from Apple" }
      responses:
        "200": { description: Acknowledged (always 200 on accept; Apple retries non-2xx) }
```
Add to the existing `/v1/roadmaps/generate` responses:
```yaml
        "402":
          description: Insufficient credits to generate
          content:
            application/json:
              schema: { $ref: "#/components/schemas/InsufficientCredits" }
```
New component schemas:
```yaml
    CreditsState:
      type: object
      properties:
        balance:           { type: integer, example: 30 }
        version:           { type: integer }
        lifetimeEarned:    { type: integer }
        lifetimePurchased: { type: integer }
        lifetimeSpent:     { type: integer }
        updatedAt:         { type: string, format: date-time, nullable: true }
        ledger:
          type: array
          items: { $ref: "#/components/schemas/CreditLedgerEntry" }
    CreditLedgerEntry:
      type: object
      properties:
        delta:        { type: integer, example: -10 }
        balanceAfter: { type: integer }
        reason:
          type: string
          enum: [signup_grant, purchased, earned_completion, spent_generation,
                 refund_generation_failure, refund_revoke, admin_adjust]
        refType:   { type: string, nullable: true }
        refId:     { type: string, nullable: true }
        createdAt: { type: string, format: date-time }
    PurchaseRequest:
      type: object
      required: [jws]
      properties:
        jws:           { type: string, description: "StoreKit 2 VerificationResult JWS (Transaction)" }
        productId:     { type: string, nullable: true, description: "Hint only; server re-derives from the JWS" }
        transactionId: { type: string, nullable: true, description: "Hint only; server re-derives from the JWS" }
    InsufficientCredits:
      type: object
      properties:
        error:   { type: string, example: insufficient_credits }
        balance: { type: integer, example: 4 }
        cost:    { type: integer, example: 10 }
```
**openapi ⇄ DTO ⇄ handler sync notes.** Add Swift mirrors to `DTOs.swift`:
`CreditsStateDTO { balance, version, lifetimeEarned, lifetimePurchased, lifetimeSpent, updatedAt:
String?, ledger: [CreditLedgerEntryDTO] }`, `CreditLedgerEntryDTO`, `PurchaseRequest { jws,
productId?, transactionId? }`, and `InsufficientCreditsDTO { error, balance, cost }` (decode
leniently, defaulting absent ints to 0, mirroring `CatalogBook.init(from:)`'s tolerant style). The
402 body is decoded from `APIError.badStatus(402, body)` in the client (see §6.4).

### 6.4 Backend handlers (thin; logic in `shared/credits.py` + `shared/appstore.py`)
New Lambda handlers (mirroring the existing thin-handler pattern; registered via `make_fn` + `route`
in `api_stack.py`):
- **`handlers/credits.py`** — `GET /v1/me/credits` and `POST /v1/credits/purchase`. GET returns
  balance + recent ledger (auto-creates signup grant). POST parses `{jws}`, calls
  `appstore.verify_transaction(jws)` → `(productId, transactionId, originalTransactionId,
  bundleId, environment)`, validates `bundleId` + product is known (`credits.PACKS`), then
  `credits.grant_purchase(uid, …)`; returns `CreditsState`.
- **`handlers/credit_notifications.py`** — `POST /v1/credits/notifications`. Parses `{signedPayload}`,
  calls `appstore.verify_notification(signedPayload)` → decoded `notificationType`, `subtype`, and
  the embedded **signed transaction info**; for `REFUND`/`REVOKE`/charge-back, looks up the original
  `PURCHASE#<transactionId>` (which carries the granting **`uid`** and `credits`) and
  `credits.revoke_purchase(...)`. Always `ok({})` on accept.
- **Gate inside `handlers/generate_roadmap.py`** (verified file): immediately after resolving `uid`
  (add `uid = user_id(event)` with the `PermissionError → 401` guard already used by `progress.py`),
  and **only** when credits apply (always, in backend mode), call
  `credits.spend(uid, GENERATION_COST, ref_type="book", ref_id=book_id or "inline")` **before**
  `claude.generate_roadmap(...)`. Wrap the existing generation `try/except` so the `except` path
  calls `credits.refund_generation_failure(uid, spend_id)` and then returns `server_error(...)`.
  On success, stamp the returned roadmap with a `spendId`/`creditsSpent` for the client and (if the
  roadmap has an id) include the `roadmapId` already set today for the `bookId` path.

`shared/credits.py` (new) holds: `PACKS` (product-id → credits), `GENERATION_COST`,
`COMPLETION_REWARD`, `SIGNUP_GRANT`, and the `spend/credit/grant_completion/grant_purchase/
revoke_purchase/get_state/_append_ledger/_ensure_signup_grant` functions above.
`shared/appstore.py` (new) holds Apple JWS verification (§6.5).

### 6.5 Apple server-side verification (`shared/appstore.py`)
StoreKit 2 returns every transaction as a **JWS** (three dot-separated Base64URL parts:
header, payload, signature); the header's `x5c` array is the **certificate chain** that must verify
up to **Apple Root CA - G3**. Verification steps (for both the purchase JWS and the notification
`signedPayload`):
1. **Split** the JWS; decode the header (alg **ES256**, `x5c` chain).
2. **Validate the certificate chain**: leaf → intermediate → **Apple Root CA - G3** (pin the root;
   ship the root cert as a bundled asset under `backend/src/shared/certs/`). Reject if the chain
   doesn't terminate at the pinned root or any cert is expired.
3. **Verify the ES256 signature** of `header.payload` with the **leaf certificate's public key**.
4. **Decode the payload** and assert `bundleId == <Mango bundle id>` and
   `environment ∈ {Production, Sandbox}` consistent with the stage (sandbox allowed in dev/beta).
5. Extract `transactionId`, `originalTransactionId`, `productId`, `appAccountToken`
   (= the Cognito `sub` the client attached), `purchaseDate`, and (notifications)
   `notificationType`/`subtype`.
6. **Cross-check `appAccountToken == uid`** for the purchase path (defense in depth — the JWS already
   proves Apple signed it; this binds it to the authenticated caller).
- **Defense in depth (optional, recommended for prod):** additionally call the **App Store Server
  API** "Get Transaction Info" endpoint with the `transactionId` to fetch Apple's authoritative,
  freshly-signed record (guards against a replayed-but-revoked transaction). This requires an
  **App Store Connect API key** (issuer id + key id + .p8 private key) stored in **Secrets Manager**
  and an ES256-signed JWT bearer — gated to prod/beta. v1 may rely on **local JWS verification** for
  the consumable grant and use the **notifications** webhook for refunds; D-3 records the choice.
- **Idempotency:** grant keyed by `transactionId` (FR-6); refund keyed by `(transactionId,
  notificationType)` (FR-7). Consumables: **store `originalTransactionId`** so a later
  `CONSUMPTION_REQUEST` can be answered (respond within **12 hours** to influence Apple's refund
  decisioning — most refunds happen within 30 days). v1 may **not** auto-answer consumption requests
  (just log them); D-4 records this.
- **stdlib + boto3 constraint:** ES256 + X.509 chain validation is **not** in the stdlib. Options
  (D-2): **(a)** vendor a tiny pure-python ES256/X.509 verifier into `src/shared/vendor/` (no pip
  packaging step — files are deployed via `Code.from_asset("src")`); **(b)** add a single Lambda
  layer with `cryptography` + Apple's `app-store-server-library-python` (deviates from the strict
  "stdlib + boto3, no packaging" invariant — call out in review); **(c)** use **KMS**`Verify` for the
  ES256 signature is **not** applicable (the key is Apple's, not ours). **Recommendation: (a)** for
  the signature/chain to honor the no-packaging invariant, with the verification surface small and
  unit-tested against a **mock Apple key** (tests sign with a throwaway EC key + self-signed chain and
  monkeypatch the pinned root — see §8).

### 6.6 The trusted completion signal (earn-once)
A roadmap is "completed" when **all its lessons are completed**. The client cannot simply assert
this. Two server-validatable options:
- **(A) Recommended — derive from server-held progress.** Roadmap completion is recognized when the
  server can see that every lesson in the roadmap is done. Today lesson completion is tracked
  client-side; the **clean hook** is to have the client call a **completion endpoint** (or reuse the
  analytics/progress write) that the server **validates against the stored roadmap** (the roadmap is
  cached at `BOOK#<bookId>/ROADMAP`, verified in `generate_roadmap.py`): the server counts the
  roadmap's lessons and grants the reward **only** when the reported completed-lesson set covers all
  of them, keyed idempotently by roadmap id (FR-5). This ties the reward to the actual generated
  structure, not a free-form "done" flag.
- **(B) Server-counted activity events.** As lesson/exercise completions already flow to the
  event lake (`0004` FR-3, `0015`), a backend reducer grants the reward when it observes the
  roadmap's full lesson set completed. Heavier (stream processing); deferred.
- **Decision D-5:** ship **(A)** — add a minimal `POST /v1/roadmaps/{roadmapId}/complete` (or fold a
  `completedLessonIds` check into the existing progress PUT) that validates against the cached
  roadmap and calls `credits.grant_completion`. Anti-abuse: idempotent per roadmap id, and the
  reward (**15**) is **less** than the cost to generate (**10**)… intentionally the **reward ≥ a
  meaningful fraction** but the **daily generation cap** (§6.7) prevents "generate→complete→generate"
  farming since completing requires actually doing the lessons. (Tune so completion never
  out-earns the work; see §6.7 economy.)

### 6.7 Economy (concrete starting values — tunable in `shared/credits.py`)
| Parameter | Default | Rationale |
|---|---|---|
| `SIGNUP_GRANT` | **30 credits** | Enough for ~3 generations free, so the first journeys never hit a paywall (free-to-try, like AI tools that seed every plan with starter credits). |
| `GENERATION_COST` | **10 credits** | One roadmap generation = one unit of real Bedrock cost; round number for mental math. |
| `COMPLETION_REWARD` | **15 credits** | Finishing a journey funds **1.5×** of the next generation — rewards *doing the work* (activity-first thesis) without making generation effectively free. |
| Daily generation cap | **5/day** | Caps Bedrock spend + farming; returns 429 (or a credits-style 402 with a "daily limit" reason) past the cap. |
| Purchase velocity guard | **flag > 20 packs/day/user** | Anti-fraud signal; doesn't block, logs for review. |
| Ledger history returned | **20 entries** | Enough for an in-app "recent activity" list. |

**Example consumable packs (App Store Connect product ids + indicative US prices):**

| Product id | Credits | Price (USD) | Notes |
|---|---|---|---|
| `com.mango.credits.starter` | **50** | **$0.99** | Tier 1 price point; ~5 generations. |
| `com.mango.credits.plus` | **150** | **$2.99** | Best "first paid" value; ~15 generations. |
| `com.mango.credits.pro` | **500** | **$7.99** | Power users; ~50 generations, best per-credit. |

(Prices are **display-only via `Product.displayPrice`** in-app — never hardcoded; the table above is
the App Store Connect configuration + the `.storekit` test file. Credit *amounts* are server-side in
`PACKS` keyed by product id.)

**Anti-inflation / cost guardrails.** Credits are minted only by: `signup_grant` (once),
`purchased` (paid, Apple-verified), `earned_completion` (gated, once per roadmap, behind real
activity), and future `earned_bonus`/`admin_adjust`. There is **no** uncapped earn loop; the daily
generation cap bounds burn and the completion gate bounds free minting. Cross-ref
**`0024-rewards-and-coupons.md`** for streak/daily bonus credits and promo grants (which must respect
the same ledger + idempotency and add the `earned_bonus` reason).

### 6.8 `shared/response.py` addition
Add a 402 helper (mirrors the existing `bad_request`/`not_found`):
```python
def payment_required(payload: dict) -> dict:
    return json_response(402, payload)   # e.g. {"error":"insufficient_credits","balance":4,"cost":10}
```
(Existing `json_response`, `ok`, `parse_body`, `user_id`, `http_method` are reused unchanged.)

### 6.9 CDK / infra (`api_stack.py`, least-privilege)
- Add three Lambdas via `make_fn`: `credits_fn` (`handlers.credits.handler`), `credit_notifications_fn`
  (`handlers.credit_notifications.handler`); the existing `roadmap_fn` is reused (it already has
  table read/write — it now also writes credit items, which is the same table grant, so **no new
  grant** beyond confirming `table.grant_read_write_data(roadmap_fn)` is present — it is).
- `table.grant_read_write_data(credits_fn)` and `table.grant_read_write_data(credit_notifications_fn)`.
- Routes (via the local `route(...)` helper):
  - `route("/v1/me/credits", GET, credits_fn)` — secured (JWT).
  - `route("/v1/credits/purchase", POST, credits_fn)` — secured (JWT).
  - `route("/v1/credits/notifications", POST, credit_notifications_fn, secured=False)` — **no
    authorizer**; the handler verifies Apple's JWS signature (NFR-3).
  - (D-5) `route("/v1/roadmaps/{roadmapId}/complete", POST, roadmap_fn)` or fold into `progress_fn`.
- **Secrets (prod/beta, optional for App Store Server API):** add an App Store Connect API key secret
  and grant `secretsmanager:GetSecretValue` **only** to `credit_notifications_fn` /`credits_fn` if
  the "Get Transaction Info" defense-in-depth (D-3) is enabled. v1 local-JWS path needs **no** secret.
- **Bundled cert:** ship `AppleRootCA-G3.cer` under `src/shared/certs/` (deployed via the existing
  `Code.from_asset("src")` — no packaging step).
- **Events:** emit `credit_spent` / `credit_earned` / `credit_purchased` / `credit_refunded` analytics
  events through the existing events path (`0004`/`0015`) for revenue/economy dashboards — reuse the
  Firehose plumbing; **do not** put money/PII beyond the `sub` already in the lake.

### 6.10 iOS design
**New service — `ios/Mango/Services/Payments/PurchaseService.swift` (`@Observable`, no third-party
deps):**
```swift
@Observable
final class PurchaseService {
    private(set) var products: [Product] = []          // StoreKit.Product, loaded from PACK_IDS
    private(set) var balance: Int? = nil               // mirror of server CreditsState.balance
    private var updatesTask: Task<Void, Never>?

    func start(appAccountToken: UUID, client: APIClient?) { /* load products; begin updates listener */ }
    func loadProducts() async { products = (try? await Product.products(for: Self.PACK_IDS)) ?? [] }
    func purchase(_ product: Product, appAccountToken: UUID, client: APIClient) async throws { … }
    func refreshBalance(client: APIClient) async { /* GET /v1/me/credits → balance */ }
    private func listenForTransactions(client: APIClient) -> Task<Void, Never> { … }  // Transaction.updates
    static let PACK_IDS: Set<String> = ["com.mango.credits.starter",
                                        "com.mango.credits.plus",
                                        "com.mango.credits.pro"]
}
```
- **Purchase flow (FR-11):**
  1. `let result = try await product.purchase(options: [.appAccountToken(appAccountToken)])`
     where `appAccountToken` is the **Cognito `sub` as a `UUID`** (Cognito subs are UUIDs;
     fall back to a stored per-install UUID if unauthenticated, though purchasing requires sign-in).
  2. On `.success(let verification)`: take the **`verification.jwsRepresentation`** (the signed JWS
     string) and **POST it to `/v1/credits/purchase`**; on the backend's 200, update `balance` and
     **`await transaction.finish()`**. On a non-2xx, **do not finish** — leave it unfinished so
     `Transaction.updates` re-delivers it next launch (the backend grant is idempotent by
     `transactionId`, so re-posting is safe).
  3. `.userCancelled` / `.pending` handled with calm copy (no error).
- **Updates listener (started at launch from `AppModel`):** iterate `Transaction.updates`, and for
  each **verified** transaction POST its JWS to `/v1/credits/purchase`, then `finish()`. This catches
  Ask-to-Buy approvals, cross-device purchases, and interrupted purchases. Start it as soon as the
  app/store is created so no update is missed.
- **`AppModel` wiring:** add `let purchases = PurchaseService()`; call `purchases.start(...)` from
  `RootView.task` after auth restore, passing `apiClient()` and the `sub`-derived UUID. Re-`start`/
  refresh on sign-in (alongside the existing `reloadAIService()`), since the `appAccountToken` and the
  authoritative balance are per-user.
- **Generation integration (RemoteAIService path):** when `RemoteAIService.generateRoadmap` throws
  `APIError.badStatus(402, body)`, decode `InsufficientCreditsDTO` and surface the **out-of-credits
  sheet** (FR-10). On success, refresh the balance (the server already debited). Mock/Direct paths
  are untouched (FR-13).

**New screens (DesignSystem tokens only — `Palette`/`Typo`/`Metrics`/`Haptics`):**
- `ios/Mango/Features/Credits/CreditsView.swift` — balance header (coin glyph tinted `Palette.xp`,
  `Typo.title`), a "recent activity" list from `CreditsState.ledger` (earn = `Palette.success`,
  spend = `Palette.textSecondary`, refund = `Palette.warning`; each row paired with an SF Symbol so
  it stays colorblind-safe per the `Palette` doc-comment), and a **"Get more credits"** button →
  `PaywallView`.
- `ios/Mango/Features/Credits/PaywallView.swift` — the three packs as `Card`s, each showing
  `product.displayName` + credits + **`product.displayPrice`** (localized) and a buy button; a
  "Restore"/"manage" affordance is unnecessary for consumables but a "How credits work" disclosure
  explains earn-by-doing. Uses `Metrics.radius`, `Palette.accent` CTA, `Haptics.success()` on grant.
- `ios/Mango/Features/Credits/OutOfCreditsSheet.swift` — friendly empty-state when generation 402s:
  headline "You're out of credits", two actions — **Earn** (deep-link to an in-progress journey /
  "finish a journey to earn 15") and **Buy** (presents `PaywallView`). Calm terracotta, never an
  error red.
- **Entry points:** add a **"Credits"** row to `SettingsView` (Account section) and a compact
  **balance pill** in `ProfileView`'s `statsRow` (a 5th `StatTile`-style tile: value = balance,
  label = "Credits", symbol = `creditcard` or a coin, tint = `Palette.xp`) — both read-only displays
  of the server balance.

**`AppSettings`/config:** no new persisted balance (server-authoritative). Add a build-time
`creditsEnabled` flag (default **true** in backend builds; the feature is inert in Mock/Direct since
those don't call the backend). Pack ids live in `PurchaseService.PACK_IDS` (and the `.storekit` file).

**`.storekit` test config:** add `ios/Mango/Resources/Mango.storekit` (StoreKit Configuration File)
defining the three **consumable** products with the ids/prices above, enabling **StoreKitTest** and
Xcode's local testing (purchases, Ask-to-Buy, refunds) without sandbox round-trips. Reference it in
the test scheme.

### 6.11 Sequence diagrams
```
Buy credits (happy path):
  iOS PaywallView ──product.purchase(.appAccountToken=sub)──▶ StoreKit
  StoreKit ──.success(verification: JWS)──▶ PurchaseService
  PurchaseService ──POST /v1/credits/purchase {jws}──▶ credits_fn
  credits_fn ──appstore.verify_transaction(jws)──▶ (verify x5c→AppleRootCA-G3, ES256, bundleId)
  credits_fn ──PUT PURCHASE#<txnId> (cond: not exists) + add credits + ledger(purchased)──▶ DynamoDB
  credits_fn ──200 CreditsState(balance)──▶ PurchaseService ──transaction.finish()──▶ StoreKit

Generate (gated):
  iOS RemoteAIService ──POST /v1/roadmaps/generate──▶ roadmap_fn
  roadmap_fn ──credits.spend(uid, 10) [cond: balance>=10]──▶ DynamoDB
      └─ fail ─▶ 402 InsufficientCredits ─▶ iOS OutOfCreditsSheet (Earn / Buy)
      └─ ok   ─▶ claude.generate_roadmap(...)
                    └─ throws ─▶ refund(spendId) ─▶ 500
                    └─ ok     ─▶ ledger(spent_generation) ─▶ 200 Roadmap

Refund (Apple → us):
  App Store ──POST /v1/credits/notifications {signedPayload}──▶ credit_notifications_fn
  verify JWS ─▶ REFUND/REVOKE for txnId ─▶ lookup PURCHASE#<txnId> (uid, credits)
            ─▶ debit credits + ledger(refund_revoke) [idempotent per (txnId,type)] ─▶ 200
```

## 7. Acceptance criteria
- [ ] **AC-1 (signup grant, idempotent).** A brand-new user's first `GET /v1/me/credits` (or first
  generate) creates `USER#<sub>/CREDITS` with `balance = 30` and a `signup_grant` ledger entry;
  concurrent first-calls grant exactly once. *(moto unit test.)*
- [ ] **AC-2 (atomic spend + 402).** `generate` with `balance >= 10` debits 10 atomically, appends
  `spent_generation`, and proceeds; with `balance < 10` returns **402** `insufficient_credits` and
  **does not** call Bedrock. *(moto unit test asserts Bedrock/`claude.generate_roadmap` not invoked
  on 402.)*
- [ ] **AC-3 (refund on failure).** If `claude.generate_roadmap` raises after the debit, the cost is
  credited back (`refund_generation_failure`) and the response is 5xx; balance is unchanged net.
  Retried failure refunds once (idempotent by `spendId`). *(moto unit test.)*
- [ ] **AC-4 (earn once per roadmap).** Completing a roadmap grants 15 (`earned_completion`) the
  first time and is a **no-op** on repeat for the same roadmap id. *(moto unit test.)*
- [ ] **AC-5 (purchase verify + idempotent grant).** A valid (mock-Apple-signed) JWS grants the
  mapped pack credits and writes `PURCHASE#<txnId>`; re-posting the same `transactionId` returns the
  same balance without double-granting; an **invalid/unsigned** JWS returns 402 and grants nothing.
  *(moto + mocked-Apple-verification unit test.)*
- [ ] **AC-6 (refund reconciliation).** A `REFUND`/`REVOKE` notification for a granted `transactionId`
  debits exactly that pack's credits once (idempotent per `(txnId, type)`); an unknown/duplicate
  notification returns 200 and changes nothing. *(moto + mocked-verification unit test.)*
- [ ] **AC-7 (float-free + Decimal-safe).** Every credit attribute persisted is an `int`; `GET`
  returns ints (a `Decimal` round-trips to `int`). *(unit test mirrors `test_progress_coerces_float_to_int`.)*
- [ ] **AC-8 (auth required).** Credit endpoints return **401** when unauthenticated in `prod`/`beta`
  (no JWT claims), reusing the `user_id` `PermissionError` path. *(unit test mirrors
  `test_progress_requires_auth_in_prod`.)*
- [ ] **AC-9 (notifications endpoint is unauthenticated but signature-gated).** The route has **no**
  Cognito authorizer, yet a payload that fails JWS verification mutates nothing. *(`cdk synth`
  inspection + unit test.)*
- [ ] **AC-10 (iOS purchase flow).** With the `.storekit` config + **StoreKitTest**, buying a pack
  drives `PurchaseService.purchase`, posts the JWS, and finishes the transaction **only** after a
  stubbed-200 backend; a stubbed non-2xx leaves the transaction unfinished for retry. *(iOS unit test
  with `SKTestSession`.)*
- [ ] **AC-11 (out-of-credits UX).** A stubbed 402 from `generate` surfaces the out-of-credits sheet
  with Earn + Buy, not a generic error. *(iOS unit/UI check + manual.)*
- [ ] **AC-12 (offline-first preserved).** Fresh install, Mock AI, no network/auth: first journey +
  first activities run with **no** credit calls and **no** paywall. *(manual offline run + assert the
  Mock/Direct paths never call credits.)*
- [ ] **AC-13 (contract sync).** `openapi.yaml` defines the three paths + 402 + schemas; `DTOs.swift`
  mirrors them and decodes leniently; `cdk synth -c stage=beta` passes. *(openapi lint + DTO decode
  test + synth.)*
- [ ] **AC-14 (least privilege).** `grade_fn` still has no table access; the notifications Lambda has
  table (+ optional Secrets) only. *(`cdk synth` IAM inspection.)*

## 8. Test plan
**Backend — `pytest` (moto; Claude/Apple monkeypatched), new files under `backend/tests/`:**
- `test_credits.py` (logic in `shared/credits.py` via the handler, using the `aws` moto fixture and
  the `_event(...)` helper idiom from `test_progress.py`):
  - `test_signup_grant_created_once` (AC-1) — GET twice, assert one `signup_grant`, balance 30.
  - `test_spend_decrements_atomically` / `test_spend_insufficient_returns_402` (AC-2) — the 402 test
    monkeypatches `claude.generate_roadmap` to **raise if called** and asserts it wasn't.
  - `test_refund_on_generation_failure` + `test_refund_idempotent_by_spend_id` (AC-3).
  - `test_earn_completion_once_per_roadmap` (AC-4).
  - `test_get_balance_coerces_decimal_to_int` (AC-7, mirrors `test_progress_coerces_float_to_int`).
  - `test_credits_requires_auth_in_prod` (AC-8, mirrors `test_progress_requires_auth_in_prod`).
- `test_credits_purchase.py` (AC-5) — a fixture **mints a throwaway EC P-256 key**, builds a
  self-signed cert "chain", signs a fake `Transaction` payload (ES256) into a JWS, and
  **monkeypatches `appstore`'s pinned root + chain check** to trust the throwaway root; asserts
  grant, idempotent replay (same `transactionId`), and rejection of a tampered signature.
- `test_credit_notifications.py` (AC-6) — same mock-signing helper for a `signedPayload`; assert
  `REFUND` debits once, duplicate `(txnId, type)` no-ops, unknown txn → 200 + no change.
- `test_appstore.py` — unit tests for `appstore.verify_transaction` happy path (mock key), expired
  cert rejected, wrong `bundleId` rejected, `alg != ES256` rejected.
- `test_contract.py` (extend) — assert the new schemas/paths exist and a 402 shape from `generate`
  (monkeypatch `credits.spend` to raise `InsufficientCredits`) decodes to `InsufficientCredits`.
- `cdk synth -c stage=beta` must pass (routes, the unauthenticated notifications route, grants).
**iOS — `make ios-test` (XCTest), new files under `ios/MangoTests/`:**
- `PurchaseServiceTests.swift` (AC-10) — uses **`SKTestSession`** with `Mango.storekit`: load
  products, buy one, inject a **stub `APIClient`** that returns 200 → assert `finish()`; return 401 →
  assert the transaction is **not** finished and is re-offered.
- `CreditsDTOTests.swift` (AC-13) — decode `CreditsState`/`InsufficientCredits` JSON with and without
  optional fields (lenient; absent ints → 0), mirroring `CatalogBookTests`.
- `OutOfCreditsTests.swift` (AC-11) — feed a `badStatus(402, body)` through the RemoteAIService error
  path and assert the decoded `InsufficientCreditsDTO` and the sheet trigger.
**Manual:**
- Sandbox purchase on a device (Ask-to-Buy + cross-device via the `Transaction.updates` listener);
  initiate a **refund** via App Store Connect / the sandbox and confirm the webhook debits.
- Offline-first run (AC-12). Dynamic Type + VoiceOver on Paywall/Out-of-credits (NFR-9). Warm-theme
  tint check (coins = `Palette.xp`).

## 9. Rollout & migration
- **No data migration.** New SK shapes on the existing table; existing users get the `signup_grant`
  lazily on first credit interaction (FR-2). Existing roadmaps generated before this ships are simply
  un-metered history; the gate applies to **new** generations.
- **Flag/sequencing:** ship behind `creditsEnabled` (build flag). Roll out **backend first**
  (endpoints + gate, with `GENERATION_COST` initially **0** so generation is unmetered while the
  ledger/telemetry bake), then flip cost to **10** once the iOS purchase + paywall ship and the
  AC suite is green. This lets the server-side ledger and notifications soak with zero user impact.
- **App Store Connect prerequisites (block release):** create the three **consumable** IAP products
  (ids in §6.7), set the **App Store Server Notifications V2** URL to `…/v1/credits/notifications`
  (prod + a separate sandbox URL → the beta stage), and (if D-3 enabled) create an App Store Connect
  API key stored in Secrets Manager. Coordinate with `0022-app-store-prep.md` (review submission) —
  the credit packs and "how credits work" copy must be review-ready, and the app must **not**
  reference any external/web purchase path (3.1.1).
- **Backward compatibility / teardown:** with `creditsEnabled` off (or cost 0), the app behaves
  exactly as today (unmetered generation, no paywall). The notifications endpoint is harmless when no
  purchases exist. Rollback = set cost to 0 / flag off; ledger data is retained (auditable).
- **Cross-spec:** lands after identity/sign-in exists (purchasing requires a Cognito `sub` for
  `appAccountToken`; per `CLAUDE.md` "no Cognito sign-in yet" and `0019-native-apple-signin.md`,
  **this spec depends on sign-in being wired** — gate the paywall behind sign-in, and keep the
  offline path credit-free). `0024-rewards-and-coupons.md` extends the ledger (bonus/promo grants).

## 10. Risks & open decisions
- **R-1 (Apple rejection, 3.1.1).** Selling credits with anything but IAP → guaranteed rejection.
  *Mitigation:* StoreKit consumables only; **never** show or link an external purchase path in-app;
  paywall copy and pricing come from StoreKit. (Load-bearing — surfaced in §3/§9.)
- **R-2 (verification correctness).** A bug in JWS/chain verification could accept forged purchases.
  *Mitigation:* pin **Apple Root CA - G3**, verify ES256 + chain + `bundleId` + `appAccountToken`;
  unit-test rejection paths; optionally cross-check via App Store Server API (D-3). Keep the verify
  surface tiny and reviewed.
- **R-3 (double-credit / replay).** Duplicate purchase posts or at-least-once notifications.
  *Mitigation:* idempotency anchors (`PURCHASE#<txnId>`, `APPLE#NOTIF` `(txnId,type)`, roadmap-id
  earn marker, `spendId` refund marker); all grants conditional writes.
- **R-4 ("spend then refund" abuse).** Buy → spend on generation → refund the pack. *Mitigation:*
  refunds **debit** credits even into a **negative** balance (generation blocked until ≥ cost); the
  daily generation cap bounds blast radius; consumption data stored for Apple's decisioning (D-4).
- **R-5 (negative balance UX).** A heavily-refunded user sees a negative number. *Mitigation:* clamp
  the **displayed** balance at 0 ("0 credits") while the **stored** value stays negative for
  accounting; generation gate uses the stored value.
- **R-6 (offline/Direct modes).** Users on Mock/Direct shouldn't see credits at all. *Mitigation:*
  FR-13 — credits are a Mango-Backend-only concept; UI hidden otherwise.
- **R-7 (stdlib-only crypto).** ES256/X.509 isn't stdlib. *Mitigation:* D-2 (vendor a small verifier
  vs a Lambda layer) — recommend vendoring to keep the no-packaging invariant; fully unit-tested.
- **R-8 (cost during soak).** Un-metered generation while baking (cost 0) keeps Bedrock spend
  exposed. *Mitigation:* keep the daily cap **on** even at cost 0; short soak window.
- **Decisions needed (with recommendations):**
  - **D-1 (recommended: meter only `generate`).** Which calls cost credits. Generation only in v1
    (grading/parse stay free). 
  - **D-2 (recommended: vendor a minimal ES256/X.509 verifier into `src/shared/vendor/`).** How to do
    JWS verification under stdlib+boto3 (vs add a `cryptography` Lambda layer). 
  - **D-3 (recommended: local JWS verify for v1; App Store Server API "Get Transaction Info"
    cross-check enabled in prod later).** Depth of verification. 
  - **D-4 (recommended: log `CONSUMPTION_REQUEST` in v1, don't auto-answer; add the consumption
    response later).** Consumable consumption handling (12-hour window). 
  - **D-5 (recommended: validate completion against the cached roadmap via a small `complete`
    endpoint; earn once per roadmap).** The trusted completion signal (§6.6). 
  - **D-6 (recommended: target the current synchronous `generate`; keep the spend/refund hooks
    factored so an async `jobId` variant — `0008` §6.7 — can reuse them by spending on accept and
    refunding on job failure).** Sync vs async generation gating. 
  - **D-7 (defer: auto-renewing "Mango Plus" subscription that refills credits monthly).** Subscription
    option — out of scope here; the ledger + `purchased`/notification plumbing already generalize to
    `DID_RENEW`/`EXPIRED` later. 
  - **D-8 (recommended: clamp displayed balance at 0, keep stored value signed).** Negative-balance
    handling.

## 11. Tasks & estimate
1. **Ledger core** — `shared/credits.py`: items/keys, `_append_ledger`, `_ensure_signup_grant`,
   `spend` (conditional), `credit`, `grant_completion`, `grant_purchase`, `revoke_purchase`,
   `get_state`; `PACKS`/`GENERATION_COST`/`COMPLETION_REWARD`/`SIGNUP_GRANT`. **(M)**
2. **`shared/response.py`** `payment_required(...)`. **(S)**
3. **Gate `generate_roadmap.py`** — resolve `uid`, spend before Bedrock, refund-on-failure, 402.
   **(M)**
4. **`handlers/credits.py`** — GET balance+ledger, POST purchase. **(M)**
5. **`shared/appstore.py`** — JWS split/verify (ES256 + x5c→AppleRootCA-G3 + bundleId), decode
   transaction/notification; vendor the verifier (D-2); bundle the root cert. **(L)**
6. **`handlers/credit_notifications.py`** — verify + reconcile REFUND/REVOKE; idempotent log. **(M)**
7. **Completion earn** (D-5) — `POST /v1/roadmaps/{roadmapId}/complete` (or progress-PUT hook) that
   validates against the cached roadmap and calls `grant_completion`. **(M)**
8. **CDK** (`api_stack.py`) — 3 Lambdas + routes (notifications `secured=False`), grants, optional
   Secrets, bundled cert; `cdk synth` green. **(M)**
9. **openapi** — add paths, 402, schemas; keep in sync. **(S)**
10. **Backend tests** — `test_credits.py`, `test_credits_purchase.py`, `test_credit_notifications.py`,
    `test_appstore.py`, extend `test_contract.py`; black+flake8. **(L)**
11. **iOS `PurchaseService`** — products, purchase(`appAccountToken=sub`), `Transaction.updates`
    listener, finish-after-confirm, `refreshBalance`. **(M)**
12. **iOS DTOs** — `CreditsStateDTO`, `CreditLedgerEntryDTO`, `PurchaseRequest`,
    `InsufficientCreditsDTO` (lenient decode). **(S)**
13. **iOS screens** — `CreditsView`, `PaywallView`, `OutOfCreditsSheet` (tokens only); Settings row +
    Profile balance tile; `AppModel`/`RootView` wiring; 402 handling in `RemoteAIService` callers.
    **(L)**
14. **`.storekit` config** + `PurchaseServiceTests` (StoreKitTest) + `CreditsDTOTests` +
    `OutOfCreditsTests`. **(M)**
15. **App Store Connect** — create 3 consumable IAPs, set ASSN V2 URLs (prod + sandbox), (D-3) API
    key in Secrets; coordinate copy with `0022`. **(M)**
16. **Rollout** — flag `creditsEnabled`, cost-0 soak, telemetry events, then flip to cost 10; docs
    update (`docs/BACKEND.md` access patterns, `0004` entity table). **(M)**

## 12. References
- **Repo (read for accuracy):** `CLAUDE.md` (invariants: offline-first, Bedrock-only, no `float`,
  least-privilege, openapi⇄DTO⇄handler sync, no third-party iOS deps);
  `backend/src/handlers/generate_roadmap.py` (synchronous gate point; spend/refund hooks);
  `backend/src/handlers/progress.py` (float-free + `Decimal`→`int` idiom, `user_id`+401 guard);
  `backend/src/handlers/library.py` (per-user write + `GSI1 ADDED#` listing idiom);
  `backend/src/shared/response.py` (`user_id`→`USER#<sub>`, `json_response`/`parse_body`);
  `backend/src/shared/storage.py` (`table()`/`s3_client()`); `backend/mango_backend/api_stack.py`
  (`make_fn`/`route` pattern, `HttpUserPoolAuthorizer`, least-privilege grants, Secrets pattern);
  `backend/mango_backend/data_stack.py` (single table + `GSI1`, PITR); `backend/tests/test_progress.py`
  + `backend/tests/test_contract.py` (moto + monkeypatch test idioms to mirror);
  `shared/api/openapi.yaml` (contract to extend; note: `generate` is **200-sync**, no `jobId`);
  `docs/specs/0004-data-model-and-lake.md` (entity/key conventions); `docs/specs/SPEC_TEMPLATE.md`.
  iOS: `ios/Mango/App/AppModel.swift` (`apiClient()`, service container, `reloadAIService`);
  `ios/Mango/Services/Networking/APIClient.swift` (`APIError.badStatus(code, body)` → 402 surface);
  `ios/Mango/Services/Networking/DTOs.swift` (mirror); `ios/Mango/Services/AI/AIServiceProvider.swift`
  + `ios/Mango/Services/AI/RemoteAIService.swift` (the metered path; Mock/Direct untouched);
  `ios/Mango/Services/Auth/AuthService.swift` (Cognito `sub` → `appAccountToken` UUID);
  `ios/Mango/Services/Persistence/AppSettings.swift` (flag/env pattern);
  `ios/Mango/DesignSystem/Theme.swift` (`Palette.xp`/`success`/`warning`, `Metrics`);
  `ios/Mango/Features/Settings/SettingsView.swift` + `ios/Mango/Features/Profile/ProfileView.swift`
  (entry points); `ios/MangoTests/CatalogBookTests.swift` (lenient-decode test style to mirror).
- **Cross-spec:** `working/0008-product-reframe-activity-first.md` (roadmap completion = journey
  completion; the async-`generate` note in its §6.7 is **not** in the live contract — see D-6);
  `working/0019-native-apple-signin.md` (sign-in dependency for `appAccountToken`);
  `working/0022-app-store-prep.md` (review submission + IAP copy); `0024-rewards-and-coupons.md`
  (bonus/promo credits extend this ledger — reserve `earned_bonus`).
- **Research (web):**
  - **App Review Guideline 3.1.1 — "credits" / reward points are digital content and MUST use IAP;
    external payment mechanisms, license keys, and crypto are not allowed** —
    https://developer.apple.com/app-store/review/guidelines/
  - StoreKit 2 `Transaction` (every transaction is a JWS you verify; consumables included) —
    https://developer.apple.com/documentation/storekit/transaction
  - **App Store Server API** (verify by `transactionId` server-side instead of receipts; Apple-signed
    transaction info) — https://developer.apple.com/documentation/appstoreserverapi
  - **App Store Server Notifications V2** (`signedPayload` JWS; `REFUND`/`REVOKE`/`CONSUMPTION_REQUEST`;
    decode/verify locally; respond 200 or Apple retries) —
    https://developer.apple.com/documentation/AppStoreServerNotifications/App-Store-Server-Notifications-V2
  - `appAccountToken` (UUID associating a transaction with your user; set at purchase, persisted in
    transaction info) — https://developer.apple.com/documentation/storekit/transaction/appaccounttoken
  - StoreKit 2 + App Store Server API for support/refunds (server verification, consumption within
    12h, store `originalTransactionId`) — https://developer.apple.com/videos/play/tech-talks/10887/
  - AI credit-economy patterns (free starter credits per plan, anti-inflation metering, cost-plus
    pitfalls): https://www.framer.com/blog/ai-credits-simpler-plans-and-lower-prices/ ·
    https://metronome.com/blog/the-rise-of-ai-credits-why-cost-plus-credit-models-work-until-they-dont
