# 0037 — Transactional email (Amazon SES)

- **Epic:** M14 · **Status:** Draft · **Owner:** unassigned · **Updated:** 2026-06-28
- **Reviewers:** Principal / SD / QA

## 1. Summary
Mango today has **no product email** at all: Cognito sends its own **auth** emails (sign-up verification code, forgot-password), and `0025-notifications.md` ships **push + local only** — its non-goals explicitly exclude email/SMS, while noting its taxonomy and gate are "channel-extensible." This spec adds **transactional email via Amazon SES (v2 API)** as a **second delivery channel that plugs into `0025`'s existing seam** — the same `CATEGORIES` taxonomy, the same per-category preference item, the same `enqueue`/`notify` delivery path and pure gate — extended with a **`channels` dimension** so a notification can fan out to push **and/or** email. It delivers the product emails the monetization/compliance specs require but cannot themselves send: **purchase receipts and refund notices** (`0023`), **reward/coupon delivery and (Phase C) sweepstakes-winner notices** (`0024`), **security/account-change alerts**, and **"your data export is ready"** (the proposed `0033`). A small **`ses_stack`** provisions a **verified sending identity (domain) with Easy DKIM + SPF + custom MAIL FROM + DMARC**, a **configuration set** with an **SNS event destination** for bounces/complaints, and (out-of-band) the **sandbox→production** move. A new **`email` Lambda** + **`shared/email.py`** render a closed set of plain-text+HTML **templates**, resolve the recipient's **verified email from Cognito**, consult a **bounce/complaint suppression list** (DynamoDB, fed by an **`email_events` SNS-subscriber Lambda**), and call **SES `SendEmail`** with bounded retries. The load-bearing policy: **transactional categories (receipts, refunds, security, export, reward delivery) are exempt from suppression by user preference and from the daily cap** (they're CAN-SPAM "relationship/transactional" messages a user can't opt out of), while **optional/marketing-adjacent categories honor the `0025` per-category opt-in and an email-specific unsubscribe**. **No PII or secrets in email bodies** (no full coupon codes for high-value rewards, no balances beyond what's already user-visible, **never for under-13 users** per the proposed `0031`); deliverability is monitored (cross-ref `0032`). Backend stays **stdlib + boto3**, no `float` in DynamoDB, and `openapi.yaml` ⇄ `DTOs.swift` ⇄ handlers stay in lockstep (this spec adds only a tiny **unsubscribe** surface to the contract, not a user-facing email API).

## 2. Goals / Non-goals
- **Goals:**
  - **Extend `0025`'s channel model with email** as a first-class channel: a `channels: {push, email}` dimension on each `CATEGORIES` entry and on the per-category preference, so the **same `notify`/`enqueue` seam and pure gate** decide email exactly as they decide push — no parallel system.
  - A **`ses_stack`** (composed into `MangoStage`) provisioning: a **verified domain identity** with **Easy DKIM** (3 CNAMEs, auto-rotating), a documented **SPF** TXT + **custom MAIL FROM** subdomain (for SPF/DMARC alignment), a **DMARC** policy record, a **configuration set** (`mango-email-<stage>`) with an **SNS event destination** publishing **Bounce/Complaint/Delivery/Reject** events, and the **sandbox→production-access** runbook (with safe sandbox defaults so `cdk synth` works with no verified domain).
  - An **`email` Lambda** (`handlers/email.py`, invoked by `notify`, not routed) + **`shared/email.py`** that: resolves the recipient's **verified email from Cognito** (JWT `email`/`email_verified` claim primary, `AdminGetUser` fallback), checks the **suppression list**, renders the matching **template** (plain-text + HTML multipart), and calls **SES v2 `SendEmail`** with the configuration set, idempotency/dedupe, and bounded retry/backoff.
  - A closed set of **templates** (`shared/email_templates.py`): **receipt** (`0023` purchase), **refund** (`0023` refund/revoke), **reward delivery** (`0024` fulfilled coupon/giftcard), **sweepstakes-winner** (`0024` Phase C, flagged), **security alert** (account/email/password change, new sign-in), and **data-export-ready** (proposed `0033`) — each transactional, truthful, with a real physical postal address and (for optional categories only) an unsubscribe link.
  - A **bounce/complaint suppression list** (`EMAILSUPPRESS#<emailHash>` items) fed by an **`email_events` Lambda** subscribed to the configuration set's SNS topic; **hard bounces + complaints suppress permanently**; the `email` Lambda refuses to send to suppressed addresses (protects sender reputation).
  - **Preference integration with `0025`:** transactional categories are **not suppressible** (always sent if a verified address exists and isn't bounce/complaint-suppressed); optional categories honor the `0025` per-category email toggle **and** a one-click **unsubscribe** (`GET /v1/email/unsubscribe?token=…`, public, signed token) that flips the email channel off for that category.
  - **Privacy/safety:** **no sensitive data in bodies** (no full high-value codes, no PII beyond the user's own already-visible facts, no answer/reflection text), **never email under-13 users** (proposed `0031` age gate), email addresses treated as PII (hashed in logs/suppression keys), least-privilege IAM.
  - **Deliverability + monitoring:** DKIM/SPF/DMARC pass; bounce-rate / complaint-rate CloudWatch metrics + alarms (cross-ref `0032`); send/bounce/complaint analytics events to the existing lake.
  - Acceptance criteria mapped to **named tests**; a **Files to add/change** list; an ordered **S/M/L** task list; openapi⇄DTO⇄handler sync notes.
- **Non-goals:**
  - **Marketing / campaign / newsletter email** (drip sequences, promotional blasts, a campaign scheduler/segmentation UI). Everything here is **transactional or transactional-relationship**; the one "optional" tier (e.g. a weekly progress digest) is still event-triggered and opt-in, not a campaign engine.
  - **Replacing Cognito's auth emails.** Sign-up verification codes and forgot-password emails **stay with Cognito** (it owns those flows). This spec is for **product** email only. (We may later point Cognito at SES for branded auth emails — noted in §10, D-7 — but not built here.)
  - **SMS** (Cognito already does auth SMS when phone sign-in is on; product SMS is out — too costly/regulated for v1).
  - **Inbound email / receiving / parsing** (no SES receipt rules, no support-inbox ingestion — the proposed `0034` admin console may add a support address later).
  - **A user-facing "email me a copy" API or email-history screen.** Email is a side-effect of product events, plus a tiny unsubscribe endpoint. No new app screens beyond a per-category "also email me" affordance folded into the existing `0025` Settings list.
  - **Building the upstream features.** `0023` (payments), `0024` (rewards/sweepstakes), and the proposed `0033` (export) are **trigger sources**; this spec defines the **email seam** they call (a category + payload), not those features. Where a source isn't built, its email trigger is wired behind that feature's flag and is inert until it lands.
  - **Localization of email copy** (English v1; templates are structured so the proposed `0036` i18n foundation can localize later).

## 3. Background & context
**Current email state (verified).**
- **No product email exists anywhere in the repo.** A scan of `backend/src/` finds no SES usage; `shared/` modules are `agent, catalog_data, firehose, http, ids, prompts, response, roadmap_jobs, sources, storage, text`. There is no `email.py`, no `ses_stack.py`, and no SES grant in `api_stack.py`.
- **Cognito already sends auth email.** `auth_stack.py` (verified) builds a `UserPool` with `auto_verify=AutoVerifiedAttrs(email=True)`, `account_recovery=EMAIL_ONLY`, and a **required, mutable `email`** standard attribute. Cognito's default email (sandbox-grade, ~50/day, `no-reply@verificationemail.com`) sends the **sign-up code** and **forgot-password** message. **This spec does not touch that path** — it adds product email and leaves auth email to Cognito (D-7 notes optionally pointing Cognito at SES later).
- **Identity / recipient source.** `shared/response.user_id(event)` (verified) resolves the caller to the **Cognito `sub`** from `event.requestContext.authorizer.jwt.claims`. The **same claims block carries `email` and `email_verified`** when the id token is used and the pool maps them — the **primary recipient source** (no extra AWS call on the request path). For server-originated email (worker/cron/webhook contexts with no inbound JWT, e.g. an `0023` refund webhook from Apple), the `email` Lambda resolves the address via **Cognito `AdminGetUser`** keyed by `sub` (D-2).
- **Stacks compose in `stage.py`** (verified): `DataStack`, `AuthStack`, `AiStack`, `AnalyticsStack` are constructed, then `ApiStack` is wired with `table`, `bucket`, `user_pool`, `user_pool_client`, etc. A new **`SesStack`** is constructed here and its outputs (configuration-set name, MAIL FROM domain, sender address, SNS topic, optional App Store/secret ARNs) are passed to `ApiStack` so the `email`/`email_events` Lambdas can be wired with least-privilege grants.
- **Lambda/route pattern** (verified `api_stack.py`): thin Lambdas via `make_fn(name, handler, timeout, memory)`; routes via the local `route(path, method, fn, secured=True)` helper with an `HttpUserPoolAuthorizer`. Least-privilege grants are explicit (`grade_fn` has **no** table access; `events_fn` gets `firehose:PutRecord*` only). The `email`/`email_events` Lambdas follow this exactly; the **unsubscribe** route is **`secured=False`** (a recipient clicking a link in an email has no Cognito JWT) and is authenticated by a **signed token** in the handler.
- **Single table + float-free** (verified `data_stack.py`, `progress.py`): one `PAY_PER_REQUEST` table, `PK`/`SK` strings + one `GSI1`; prod PITR; `Decimal`→`int` coercion idiom. Suppression and email-send/dedupe items are **new SK shapes on the same table** (no new infra), all-int scalars.
- **`DELETE /v1/me` cascade** (verified `delete_account.py`): deletes all `USER#<sub>` items + `users/<sub>/` S3 objects, then admin-deletes the Cognito user. Email **send-log/dedupe** items keyed under `USER#<sub>` are therefore **already purged**; the **suppression list is keyed by email hash (not `sub`)** by design (a bounce/complaint must persist past account deletion to protect reputation if the address re-registers) — §6.7/§10 D-5 records this deliberate retention with a long TTL.

**The seam this extends — `0025-notifications.md` (verified, the spine of this spec).**
- `0025` defines a **closed `CATEGORIES` taxonomy** (`daily_reminder`, `streak_at_risk`, `roadmap_ready`, `activity_due`, `credits_earned`, `reward_available`, `league_update`, `achievement_unlocked`), each with `local|push`, `defaultOn`, `interruptionLevel`, a `DeepLink` target, and a "counts vs cap" flag. **Its non-goals explicitly defer email/SMS** but state the taxonomy and gate are **channel-extensible** — this spec is the realization of that extension.
- `0025` defines a **pure `NotificationGate`** (`shared/notify_gate.py`) the `notify` Lambda calls: order **disabled → dedupe → quiet-hours → cap → send**. It defines per-category preference items `USER#<sub>/NOTIFPREFS`, a per-day counter `NOTIFCOUNT#<localDate>`, and dedupe markers `NOTIFDEDUPE#<category>#<key>`, plus an `enqueue(uid, category, payload, dedupeKey)` seam every producer calls (so the gate always runs) and a `notify` delivery worker that fans out to devices via `shared/sns_push.py`.
- `0025` already maps the **producers→categories** this spec needs as email triggers: `roadmap_worker`→`roadmap_ready`, `0023` ledger grant→`credits_earned`, `0024` reward state→`reward_available`, `0021` rollover→`league_update`, grading→`achievement_unlocked`. **This spec adds email-specific categories** (`purchase_receipt`, `purchase_refund`, `security_alert`, `data_export_ready`, `reward_delivery`, `sweepstakes_winner`) that are **email-primary/email-only** and slots them into the same machinery.

**The trigger sources (verified specs).**
- `0023-payments-and-credits.md`: the credit ledger writes (`grant_purchase` `reason=purchased`; `revoke_purchase` `reason=refund_revoke`) and the App Store Server Notifications V2 webhook (`credit_notifications.py`) are the natural triggers for a **receipt** and a **refund** email respectively. The `PURCHASE#<transactionId>` item already carries the granting `uid`, `productId`, and credit amount — exactly the receipt fields (no card data ever touches Mango; Apple owns payment).
- `0024-rewards-and-coupons.md`: redemption flow step 5a marks `REDEMPTION#….status=fulfilled` with an `artifactRef` (a **pooled coupon code** or a **giftcard partner link**). A **reward-delivery** email is sent **after** fulfillment as a convenience copy — but the **body must not contain a high-value raw code** (link the user back into the app to reveal it; D-4). **Phase C** sweepstakes winner selection (`sweep_draw.py`) writes `WINNER#<sub>` and kicks verification — a **winner-notice** email is part of that flow, **flagged behind `sweepstakesEnabled` + counsel sign-off** (the whole sweepstakes module is legal-gated in `0024`).
- **Security/account notices** have no single owning spec yet; this spec defines the **`security_alert`** category and the seam, and lists the events that should fire it (email change, password change, new-device sign-in) — wired where those flows live (Cognito-triggered via a Cognito Lambda trigger, or our own account endpoints), behind a flag until those producers exist.
- The proposed **`0033` (data export / DSAR)** — **not yet drafted** — will produce a `GET /v1/me/export` that assembles a zip/JSON and (for large exports) completes **asynchronously**; the completion is the trigger for a **data-export-ready** email with a **time-limited, signed S3 link** (no raw data in the body). This spec defines the `data_export_ready` category + template so `0033` can call it when written.
- The proposed **`0034` (admin console)** — **not yet drafted** — may later add a support/`from` address and resend tooling; out of scope here beyond noting the seam.

**Compliance context (verified via research, §12).**
- **CAN-SPAM:** **transactional / relationship** messages — confirming an agreed transaction, delivering goods/services bought, security/T&C changes — are **exempt** from the commercial-email rules (no unsubscribe required), **but must still be truthful**: accurate `From`/subject, no deceptive headers, and a **valid physical postal address** is best practice even when exempt. **Marketing-adjacent** messages (an optional digest) require a working **opt-out honored within 10 business days** and a postal address. Mango's email is overwhelmingly transactional; the one optional tier carries an unsubscribe to stay clearly compliant.
- **Amazon SES:** sending starts in a **sandbox** (only verified recipients, 200/day, 1/s) and requires a **production-access request** (choose **Transactional**) after a **verified domain with SPF/DKIM/DMARC** is in place and a real website exists. **Easy DKIM** publishes 3 auto-rotating CNAMEs; a **custom MAIL FROM** subdomain is needed for **SPF/DMARC alignment** (otherwise SPF aligns to `amazonses.com`). A **configuration set** with an **SNS (or EventBridge) event destination** delivers **bounce/complaint** notifications used to maintain a **suppression list** — required to keep bounce-rate <5% and complaint-rate <0.1% (above which AWS pauses sending).

**Why now.** `0023`/`0024` introduce money and redeemable value; a purchase with **no receipt** and a refund with **no notice** is a support-ticket generator and a trust gap, and the proposed `0033` export is useless if the user is never told it's ready. `0025` deliberately shipped push-only and left a clean, channel-extensible seam precisely so email could be added without a second notification system. Doing it now — with transactional/optional separation and a suppression list baked in — means every future email inherits the deliverability and consent guardrails instead of bolting them on after a reputation incident.

## 4. User stories
- As a **paying user**, when I buy a credit pack I receive a **clear receipt email** (what I bought, when, the order id, and that Apple processed payment), so I have a record outside the app — even if I closed the app right after purchasing.
- As a **user who was refunded**, I get a **refund/adjustment notice** so the change to my balance isn't a silent surprise.
- As a **user who redeemed a reward**, I get a **delivery email** confirming the reward and pointing me back into the app to view/copy my code (the email itself never exposes a high-value code), so I can find it later.
- *(Phase C, post-legal)* As a **sweepstakes winner**, I receive an **official winner notice** with the next steps for verification, per the official rules.
- As a **security-conscious user**, when my email or password changes or my account is accessed from a new device, I get a **security alert** I can act on — and this email is sent **regardless of my marketing preferences** because it protects my account.
- As a **user who requested my data**, I get a **"your export is ready" email** with a **secure, expiring link**, so I can download it without watching a spinner.
- As a **privacy-minded user**, I want transactional emails to contain **no sensitive content** (no full codes, no personal answers), my address treated as private, and any **optional** email (a progress digest) to be **one-click unsubscribe** — while I understand I **can't** unsubscribe from receipts and security alerts.
- As a **minor (under 13)** (or their parent), I want the app to **never email me** product email, consistent with the age-gate (proposed `0031`).
- As an **on-call engineer**, I want a hard bounce or a complaint to **automatically suppress** that address so we never keep mailing a dead/angry inbox and never get SES paused, and email failures to be **best-effort** (never break the purchase/refund that triggered them).

## 5. Requirements
### 5.1 Functional
- **FR-1 (email as a `0025` channel).** Extend the closed `CATEGORIES` taxonomy (shared client+server) with a **`channels`** field — a set drawn from `{push, email}` — and add the **email-primary categories** (§6.1): `purchase_receipt`, `purchase_refund`, `reward_delivery`, `sweepstakes_winner` (flagged), `security_alert`, `data_export_ready`. Existing push categories may **opt-in** an `email` channel (e.g. an optional `weekly_digest`), but the default-on push categories (`daily_reminder`, `roadmap_ready`, …) **do not** gain email by default. Unknown categories/channels are not representable.
- **FR-2 (transactional vs optional classification).** Each category carries a boolean **`transactional`**. **Transactional** categories (`purchase_receipt`, `purchase_refund`, `reward_delivery`, `sweepstakes_winner`, `security_alert`, `data_export_ready`) are **not suppressible by user preference** and **exempt from the daily cap** for the email channel; they are sent whenever a **verified, non-bounce/complaint-suppressed** address exists. **Optional** categories (any future `weekly_digest`) honor the `0025` per-category email toggle **and** the unsubscribe (FR-9).
- **FR-3 (recipient resolution).** The `email` Lambda resolves the recipient's address in order: (a) `email` from the inbound JWT claims if present **and `email_verified == true`**; else (b) **Cognito `AdminGetUser(sub)`** reading the `email` + `email_verified` attributes. If no address, or **`email_verified == false`**, the email is **dropped** (logged, health-event emitted) — Mango never sends product email to an unverified address.
- **FR-4 (suppression check).** Before sending, the Lambda checks the **suppression list** (`EMAILSUPPRESS#<sha256(lowercased email)>`). If present (hard bounce or complaint), the send is **dropped** for **all** categories including transactional (a dead/complaining inbox must not be mailed — this protects reputation and is required by SES). A **soft/transient** bounce does **not** permanently suppress (it may retry within policy, §6.6).
- **FR-5 (template render + send).** For an allowed `(uid, category, payload)`, render the matching **template** (`shared/email_templates.py`) into a **multipart plain-text + HTML** message (text part always present for accessibility/deliverability), then call **SES v2 `SendEmail`** with: `FromEmailAddress` = the stage sender (e.g. `Mango <no-reply@mail.mango.app>`), `Destination.ToAddresses=[recipient]`, `Content.Simple` (Subject/Body Text+Html), `ConfigurationSetName` = `mango-email-<stage>`, and message tags `{category, stage}` for event attribution. Return best-effort `bool` (mirrors `firehose.put_event`).
- **FR-6 (idempotency / dedupe).** Email sends are **idempotent per `(category, dedupeKey)`** using the **same `0025` dedupe markers** (`NOTIFDEDUPE#<category>#<dedupeKey>`) extended with a channel suffix (`…#email`) so a retried producer or a push+email fan-out of the same event sends **at most one** email. dedupeKeys reuse `0025`'s conventions (`receipt:<transactionId>`, `refund:<transactionId>`, `reward:<redemptionId>`, `export:<exportId>`, `security:<eventId>`).
- **FR-7 (bounce/complaint ingestion).** An **`email_events` Lambda** is subscribed to the configuration set's **SNS topic**. On **`Bounce` (bounceType=Permanent)** or **`Complaint`**, it writes/updates `EMAILSUPPRESS#<emailHash>` with `{ reason, type, at, ttl }` (permanent reasons get a long TTL, e.g. 180 days, then re-eligible). On **transient bounce** it records a soft-bounce counter (no permanent suppress). It emits `email_bounced`/`email_complained` analytics events. It never logs the raw address (hash only).
- **FR-8 (cap accounting on the email channel).** Transactional emails are **exempt** from any cap (FR-2). If an optional email category exists, it counts against a **separate per-channel email cap** (default generous, e.g. ≤1/day) tracked with a channel-suffixed counter (`NOTIFCOUNT#<localDate>#email`) so email volume never silently rides the push cap (and vice versa).
- **FR-9 (unsubscribe — optional categories only).** Every **optional** email includes a **List-Unsubscribe** header (`mailto:` + a one-click HTTPS URL) and a visible footer link to `GET /v1/email/unsubscribe?token=<signed>`. The token is an **HMAC-signed** (server secret) `{uid, category, exp}` blob; the public handler verifies it and flips that category's **email** channel off in `NOTIFPREFS` (never the push channel, never a transactional category — a token minted for a transactional category is rejected). Returns a minimal HTML confirmation page. Transactional emails carry **no** unsubscribe link (they're exempt and unsubscribing would be misleading).
- **FR-10 (no sensitive data in bodies).** Templates render **only**: the user's own already-visible facts (their email, a product display name, an order id, a credit delta they already see in-app, a reward title, a timestamp) and **app deep links**. They must **never** include: a **high-value coupon/giftcard code** (link into the app to reveal — D-4), a **password or token**, **answer/reflection/book text**, another user's data, or any **PII for tax/winner verification** (that flow happens in-app/over a secured channel per `0024`). A lint test (§8) asserts forbidden fields never reach a rendered body.
- **FR-11 (minors never emailed).** If the user is flagged **under-13** (proposed `0031` age signal — a `USER#<sub>/AGEGATE` attribute / claim), **all** product email is **suppressed** (transactional included) — consistent with COPPA's data-minimization for children; the app surfaces the same information in-app only. The check is in the `email` Lambda (defense in depth) and reflected in the category gate. (Until `0031` lands, this is a no-op guard reading an absent attribute = treat as adult; the seam exists.)
- **FR-12 (purge on delete; suppression retained).** `DELETE /v1/me` already purges `USER#<sub>` send-log/dedupe items. The **suppression list is intentionally retained** (keyed by email hash, not `sub`) with its own TTL so a bounced/complaining address stays protected even if the account is deleted and the address later re-registers (§10 D-5). No raw address survives in logs.

### 5.2 Non-functional
- **NFR-1 (transactional-truthful, consent-correct — the compliance invariant).** Transactional emails have accurate `From`/subject, a valid **physical postal address** in the footer, and **no** deceptive content (CAN-SPAM truthful even when exempt). Optional emails additionally carry a working **one-click unsubscribe** honored immediately (well within the 10-business-day rule) and the postal address. The transactional/optional split is **enforced server-side** in the category table + gate so no producer can mis-send a marketing message as transactional.
- **NFR-2 (privacy / PII).** Email addresses are **PII**: **never logged in clear** (sha256 hash in logs and as the suppression key), **never placed in analytics `props`** (only the hash + category + outcome), **never echoed to other users**. Bodies carry no sensitive data (FR-10). The HMAC unsubscribe secret and any App Store/partner secret live in **Secrets Manager**. Minors are never emailed (FR-11).
- **NFR-3 (least-privilege IAM).** The **`email` Lambda** gets: `ses:SendEmail` scoped to the **verified identity ARN** + the **configuration-set** condition; `cognito-idp:AdminGetUser` on the **specific user-pool ARN** (recipient resolution); table read/write for suppression + dedupe; `secretsmanager:GetSecretValue` on the **unsubscribe-secret** only. The **`email_events` Lambda** gets table write (suppression) + `firehose:PutRecord*` only — **no** SES send, **no** Cognito. The **unsubscribe** Lambda gets table read/write + the unsubscribe secret only. `grade_fn` stays table-less (existing invariant). No other Lambda gets `ses:SendEmail`.
- **NFR-4 (best-effort / resilient).** An email failure (SES error, throttle, missing identity, unresolved address) **never** breaks the producing request (purchase, refund, export) and **never** raises to a user; it logs (hashed), emits a health event, and — for retryable SES errors — retries with bounded exponential backoff (then drops). Mirrors `firehose.put_event`'s returns-`False` contract. A poison email is dropped, not retried forever; an **SQS DLQ** (if `enqueue` uses SQS per `0025` D-3) captures it for inspection (cross-ref `0032`).
- **NFR-5 (offline-first / no regression).** Email is a **server-side side-effect** of backend events; it requires **no** app change for first run and is **inert** in Mock/Direct AI modes and when SES is unconfigured (a stage with no verified domain simply no-ops sends — `cdk synth` and `pytest` pass with SES sandbox defaults / mocked). Cognito auth email is unchanged. No new mandatory app screen.
- **NFR-6 (no new iOS deps; minimal client surface).** The only client change is folding an **"also email me"** toggle into the existing `0025` per-category Settings rows for **optional** categories (transactional categories are not shown as toggles), using `Palette`/`Typo`/`Metrics` tokens — no raw hex, no magic numbers, no SPM/CocoaPods.
- **NFR-7 (backend style/runtime).** stdlib + boto3 only (SES + SNS + Cognito via boto3; HTML/text templates are plain Python f-strings/`string.Template` — **no Jinja/no packaging**). black (line-length 100) + flake8 (max 120). `pytest` (moto mocks SES/SNS/Cognito; `SendEmail` monkeypatched/asserted) + `cdk synth -c stage=beta` both pass offline.
- **NFR-8 (float-free).** Every persisted numeric (suppression `at`/`ttl`, soft-bounce counters, email cap counters, send timestamps) is an `int`; reads coerce `Decimal`→`int` (reuse the `progress.py` idiom). Money in receipts is **display-only** from Apple's localized price (never recomputed; never a `float` in DDB).
- **NFR-9 (deliverability).** DKIM (Easy DKIM, 3 CNAMEs) + SPF (custom MAIL FROM) + DMARC must **pass**; a plain-text part is always included; bounce-rate and complaint-rate are monitored with **CloudWatch alarms** (cross-ref `0032`). Production-access request filed as **Transactional**. Sender domain is a **subdomain** (e.g. `mail.mango.app`) to isolate sending reputation from the root domain.
- **NFR-10 (cost / scale).** Email is pay-per-send (SES is inexpensive; historically generous free tier from AWS-hosted senders). Volume is bounded by being **event-triggered + deduped + suppression-gated**; there is no broadcast path. The `email_events` subscriber is O(1) per event.

## 6. Design

### 6.1 Email categories — extending the `0025` taxonomy (the spine)
Email reuses `0025`'s closed `NotificationCategory`/`CATEGORIES`. Each entry gains **`channels`** (subset of `{push, email}`) and **`transactional`** (bool). The push-only rows from `0025` are unchanged (`channels={push}`, plus `daily_reminder`/`streak_at_risk` which also allow `local`). The **new email rows**:

| id (wire) | Trigger / source | Channels | Transactional | Default email on | Suppressible | Counts vs email cap | Body links to |
|---|---|---|---|---|---|---|---|
| `purchase_receipt` | `0023` `grant_purchase` (ledger `purchased`) | **email** | **Yes** | on (forced) | **No** | Exempt | Credits screen |
| `purchase_refund` | `0023` `revoke_purchase` / ASSN V2 `REFUND`/`REVOKE` | **email** | **Yes** | on (forced) | **No** | Exempt | Credits screen |
| `reward_delivery` | `0024` redemption `status=fulfilled` | **email** | **Yes** | on (forced) | **No** | Exempt | Rewards screen (reveal code in-app) |
| `sweepstakes_winner` | `0024` Phase C `sweep_draw` `WINNER#` (flagged) | **email** | **Yes** | on (forced) | **No** | Exempt | Official-rules / in-app claim |
| `security_alert` | account/email/password change, new-device sign-in | **email** (push optional later) | **Yes** | on (forced) | **No** | Exempt | Settings / account |
| `data_export_ready` | proposed `0033` export job complete | **email** | **Yes** | on (forced) | **No** | Exempt | Signed S3 link (expiring) |
| `weekly_digest` *(optional, future)* | cron weekly summary | **email** (+push) | No | **off** | **Yes** | Counts (≤1/day) | Home |

Notes:
- **Transactional rows are "forced on"** — they have no user-facing toggle; the only thing that stops them is **no verified address / bounce-complaint suppression / under-13**. This matches CAN-SPAM (relationship messages) and the product need (a receipt the user can't accidentally turn off).
- `weekly_digest` is the **only** optional/marketing-adjacent example and is included to prove the channel-extension is general; it is **off by default**, honors the `0025` email toggle, and carries unsubscribe. It is **not** built in v1 (no cron producer); it documents the optional path.
- Existing push categories are **not** auto-emailed. A user could later be offered "also email me my achievements," but that's an opt-in `email` channel on an existing category, off by default, honoring FR-2.

### 6.2 Where email plugs into the `0025` delivery path
`0025`'s `notify` Lambda already: loads prefs + dedupe/count state, calls the **pure gate**, and on `send` fans out to **devices** via `sns_push.py`. This spec makes the fan-out **multi-channel**:

```
producer ──enqueue(uid, category, payload, dedupeKey)──▶ notify Lambda
notify:
  load NOTIFPREFS, NOTIFCOUNT#<day>[#channel], NOTIFDEDUPE#…           (0025)
  channels = CATEGORIES[category].channels                            (NEW: push/email)
  for channel in channels:
     decision = gate.decide(category, dedupeKey, prefs, state, now, channel)   (NEW: channel arg)
     if decision == "send":
        if channel == "push":  sns_push.publish(...)                  (0025)
        if channel == "email": email.deliver(uid, category, payload, dedupeKey)  (NEW → email Lambda)
        record NOTIFDEDUPE#…#<channel>; increment NOTIFCOUNT#<day>#<channel> (if counts)
        emit notification_sent{channel}
     else: emit notification_suppressed{channel, decision}
```

- **The gate stays pure** (`shared/notify_gate.py`), extended with a **`channel`** parameter and a **`transactional`** short-circuit: for a `transactional` category on the `email` channel it **skips the disabled/quiet/cap checks** and returns `send` unless the channel itself is unavailable (that availability — verified address, suppression, minor — is checked in the **`email` Lambda**, which is I/O, not in the pure gate). For optional categories the existing order (`disabled → dedupe → quiet → cap → send`) applies per channel. This keeps the gate exhaustively unit-testable while the I/O-bound email-specific drops live in the `email` Lambda.
- **D-1:** the `email` Lambda is invoked **by `notify`** (single fan-out point), not directly by producers — so the gate and dedupe always run and email can't bypass consent. (A producer that only wants email still calls `enqueue` with an email-only category.)

### 6.3 `ses_stack` (new CDK stack; safe sandbox defaults)
`backend/mango_backend/ses_stack.py` — provisions sending infrastructure. Designed so **plain `cdk synth` works with no verified domain** (all domain-dependent pieces are gated on a `sendingDomain` config value; absent ⇒ a synth-only placeholder identity is **not** created and the stack exposes `configured=False`, making the `email` Lambda a no-op).

- **Verified identity (domain) + Easy DKIM.** When `config["sendingDomain"]` (e.g. `mail.mango.app`) is set: `ses.EmailIdentity` with `Identity.domain(...)` and **Easy DKIM** enabled → emits the **3 DKIM CNAME** records (the stack `CfnOutput`s them for the operator to add to DNS; CDK can't write external DNS unless the zone is a Route 53 `HostedZone` also provided — if `hostedZoneId` is in config, the construct adds the records automatically; otherwise outputs them).
- **Custom MAIL FROM** (for SPF/DMARC alignment): set `mailFromDomain = "bounce.<sendingDomain>"` on the identity; output the required **MX** (`feedback-smtp.<region>.amazonses.com`) and **SPF TXT** (`v=spf1 include:amazonses.com -all`) records for the MAIL FROM subdomain.
- **DMARC**: output a recommended **`_dmarc.<domain>` TXT** (`v=DMARC1; p=quarantine; rua=mailto:dmarc@<domain>; fo=1`) for the operator (start at `p=none` for monitoring, tighten to `quarantine`/`reject` — D-6).
- **Configuration set** `mango-email-<stage>`: `ses.ConfigurationSet` with **reputation metrics enabled** and a **suppression policy** (account-level SES suppression for bounces+complaints is also enabled as a backstop, but our **own DDB suppression list** is the authoritative pre-send gate so we can reason about it and purge per policy).
- **SNS event destination**: an `sns.Topic` (`mango-email-events-<stage>`) + `ses.ConfigurationSetEventDestination` publishing **`BOUNCE`, `COMPLAINT`, `DELIVERY`, `REJECT`, `RENDERING_FAILURE`** to it. The `email_events` Lambda subscribes to this topic.
- **Sender address**: `config["senderAddress"]` (default `no-reply@<sendingDomain>`), `config["senderName"]` (default `Mango`), and a **physical postal address** string (`config["postalAddress"]`) rendered in every footer (CAN-SPAM).
- **Sandbox→production**: documented in §9 — the production-access request is a **console/CLI action** (choose **Transactional**), not a CDK resource; the stack is production-ready once the domain verifies and the request is approved. Until then, sandbox limits apply and only verified test recipients receive mail (fine for beta).
- **Outputs** passed to `ApiStack` via `stage.py`: `configuration_set_name`, `sender_from` (formatted `Name <addr>`), `mail_from_domain`, `events_topic`, `identity_arn`, `configured` (bool), `postal_address`.

### 6.4 The `email` Lambda + `shared/email.py` (delivery)
**`backend/src/handlers/email.py`** — invoked by `notify` (async invoke or SQS, mirroring `0025` D-3); **not** an API route. Input event: `{ uid, category, payload, dedupeKey }`. Flow:
```python
# handlers/email.py (thin)
def handler(event, _ctx):
    if not email_cfg.configured:           # stage has no verified domain → no-op
        return {"sent": False, "reason": "ses_unconfigured"}
    uid      = event["uid"]
    category = event["category"]
    payload  = event.get("payload", {})
    return {"sent": email.deliver(uid, category, payload, event.get("dedupeKey"))}
```
**`backend/src/shared/email.py`** — logic:
```python
def deliver(uid: str, category: str, payload: dict, dedupe_key: str | None) -> bool:
    cat = CATEGORIES[category]
    if not (cat.channels & {"email"}):            return False
    if is_minor(uid):                              return _drop(uid, category, "minor")   # FR-11
    addr, verified = resolve_email(uid)                                                    # FR-3
    if not addr or not verified:                   return _drop(uid, category, "no_verified_email")
    if is_suppressed(addr):                        return _drop(uid, category, "suppressed")  # FR-4
    if dedupe_key and already_sent(category, dedupe_key, "email"):  return False          # FR-6
    subject, text, html = render(category, payload, unsubscribe_url=_unsub(uid, category)) # FR-5/FR-10
    ok = _ses_send(addr, subject, text, html, category)                                    # FR-5 + retry
    if ok:
        mark_sent(uid, category, dedupe_key, "email")
        firehose.put_event("email_sent", uid, {"category": category, "emailHash": _hash(addr)})
    return ok
```
- `resolve_email(uid)` — tries the request's JWT claims first (passed through the payload by `notify` when available), then `cognito_idp.admin_get_user(UserPoolId, Username=uid)` reading `email`/`email_verified`. Caches nothing sensitive.
- `_ses_send` — `sesv2.send_email(FromEmailAddress=cfg.sender_from, Destination={"ToAddresses":[addr]}, Content={"Simple":{"Subject":{"Data":subject},"Body":{"Text":{"Data":text},"Html":{"Data":html}}}}, ConfigurationSetName=cfg.configuration_set_name, EmailTags=[{"Name":"category","Value":category},{"Name":"stage","Value":STAGE}])`; bounded retry on `Throttling`/`TooManyRequests` with exponential backoff; returns `bool`.
- `is_minor(uid)` — reads `USER#<uid>/AGEGATE` (proposed `0031`); absent ⇒ adult (no-op until `0031`).
- `_unsub(uid, category)` — `None` for transactional categories (no link); for optional, an HMAC-signed URL (FR-9).
- All address logging is **hashed**; the raw address never appears in logs or analytics.

### 6.5 Templates (`shared/email_templates.py`)
A closed registry `TEMPLATES: dict[category -> render_fn]`; each returns `(subject, text, html)`. Plain Python (`string.Template`/f-strings), **no template engine**. Shared chrome: a tiny `_wrap(html_body)` adds the Mango header/footer with the **postal address** and (optional only) the unsubscribe link; a matching `_wrap_text`. Each template takes a **typed, minimal payload** and renders **only allowed fields** (FR-10).

| Category | Payload (minimal, non-sensitive) | Subject (example) | Body gist |
|---|---|---|---|
| `purchase_receipt` | `{ productName, credits:int, priceDisplay:str, orderId, purchasedAt }` | "Your Mango receipt" | What you bought, credits added, localized price (display-only), order id, date, "Apple processed this payment." Link → Credits. |
| `purchase_refund` | `{ productName, creditsRemoved:int, orderId, refundedAt }` | "Your Mango refund" | Refund/adjustment confirmation; credits removed; balance may be lower; no card data. Link → Credits. |
| `reward_delivery` | `{ rewardTitle, rewardType, redemptionId, fulfilledAt }` | "Your reward is ready" | Reward title/type; **"Open Mango to view your code"** (no code in body for high-value); link → Rewards. |
| `sweepstakes_winner` *(flagged)* | `{ sweepTitle, officialRulesUrl, claimDeadline }` | "You won a Mango sweepstakes" | Official winner notice; next steps for verification per rules; **no PII collected via email**; link → in-app claim. |
| `security_alert` | `{ eventKind ∈ {email_changed,password_changed,new_signin}, when, deviceHint? }` | "Security alert for your Mango account" | What changed/when; "If this wasn't you, secure your account"; link → account; **no password/token**. |
| `data_export_ready` | `{ downloadUrl (signed, expiring), expiresAt }` | "Your Mango data export is ready" | Your export is ready; **secure link expiring `<expiresAt>`**; no data in body. |

- **HTML is simple, inline-styled, table-light** for client compatibility; the **text part is authoritative** (always present) for accessibility and spam scoring.
- **i18n-ready:** subjects/bodies are produced by functions keyed by category, so the proposed `0036` can swap a locale bundle without touching `email.py`.

### 6.6 Bounce/complaint suppression (`email_events` Lambda)
**`backend/src/handlers/email_events.py`** — SNS-subscribed (the configuration set's topic). Parses the SES notification JSON (`notificationType` ∈ `Bounce|Complaint|Delivery|Reject`):
```python
def handler(event, _ctx):
    for rec in event.get("Records", []):
        msg = json.loads(rec["Sns"]["Message"])
        t = msg.get("notificationType") or msg.get("eventType")
        if t == "Bounce":
            b = msg["bounce"]
            permanent = b.get("bounceType") == "Permanent"
            for r in b.get("bouncedRecipients", []):
                addr = r["emailAddress"]
                if permanent: suppress(addr, reason="hard_bounce", ttl_days=180)   # FR-7
                else:         note_soft_bounce(addr)                                # transient
                firehose.put_event("email_bounced", _uid_unknown, {"emailHash": _hash(addr), "permanent": permanent})
        elif t == "Complaint":
            for r in msg["complaint"].get("complainedRecipients", []):
                addr = r["emailAddress"]
                suppress(addr, reason="complaint", ttl_days=180)                    # FR-7
                firehose.put_event("email_complained", _uid_unknown, {"emailHash": _hash(addr)})
        # Delivery/Reject: metrics only (no suppression)
    return {"ok": True}
```
- `suppress(addr, …)` upserts `EMAILSUPPRESS#<sha256(addr.lower())>` with `{ reason, type, at:int, ttl:int }`. **TTL** lets a hard-bounced address become eligible again after the window (addresses get reactivated; permanent SES suppression is a backstop). Complaints likewise expire but could be configured permanent (D-5).
- **Soft bounces**: increment a counter; if it crosses a threshold within a window, escalate to suppression (mailbox full repeatedly). v1 simply records; threshold escalation is a small follow-up.
- The Lambda **never logs the raw address** and has **no SES send / no Cognito** permission (write-suppression + Firehose only).

### 6.7 Data — single-table items (all scalars; no `float`)
| Entity | PK | SK | Key attributes | Lifecycle |
|---|---|---|---|---|
| **Suppression** | `EMAILSUPPRESS#<emailHash>` | `META` | `reason:str` (`hard_bounce`/`complaint`), `bounceType:str`, `at:int`, `ttl:int` | **TTL** (e.g. 180 d); **retained across account deletion** (keyed by hash, not `sub`) — D-5 |
| **Soft-bounce counter** | `EMAILSUPPRESS#<emailHash>` | `SOFT` | `count:int` (atomic `ADD`), `lastAt:int`, `ttl:int` | TTL ~7 d |
| **Email dedupe (extends 0025)** | `USER#<sub>` | `NOTIFDEDUPE#<category>#<dedupeKey>#email` | `sentAt:int`, `ttl:int` | TTL 24–72 h; purged by `DELETE /v1/me` |
| **Email cap counter (extends 0025)** | `USER#<sub>` | `NOTIFCOUNT#<localDate>#email` | `count:int` (atomic `ADD`), `ttl:int` | TTL ~2 d; purged by delete |
| **(Reuse) Preferences** | `USER#<sub>` | `NOTIFPREFS` | `0025` item; **add** `emailEnabled: map<cat,bool>` for optional categories | purged by delete |

- Transactional categories have **no** `NOTIFPREFS` entry (forced on); only optional categories read/write `emailEnabled[cat]`.
- The **suppression partition is the one deliberate exception** to the "everything under `USER#<sub>`" rule — a reputation signal must outlive an account (D-5). It contains **no PII in clear** (hashed key, no stored raw address), so retaining it is privacy-safe; the user's *account* data is still fully purged by `DELETE /v1/me`.

### 6.8 API / contract (minimal — only the unsubscribe surface)
Only one **public** route is added to `shared/api/openapi.yaml`; no user-facing email API. Keep `DTOs.swift` in lockstep (the unsubscribe page is server-rendered HTML, so no DTO is strictly required, but the optional **email toggles** extend the `0025` `NotificationPreferences` schema — mirror that addition).
```yaml
  /v1/email/unsubscribe:
    get:
      summary: One-click unsubscribe from an OPTIONAL email category (signed token)
      security: []                       # recipient has no Cognito JWT; auth is the signed token
      parameters:
        - { name: token, in: query, required: true, schema: { type: string } }
      responses:
        "200": { description: "Unsubscribed (HTML confirmation page)", content: { text/html: { schema: { type: string } } } }
        "400": { description: "Invalid/expired token, or token for a non-optional category" }
    post:                                  # RFC 8058 List-Unsubscribe-Post one-click
      summary: One-click unsubscribe (List-Unsubscribe=One-Click)
      security: []
      parameters:
        - { name: token, in: query, required: true, schema: { type: string } }
      responses:
        "200": { description: "Unsubscribed" }
        "400": { description: "Invalid token" }
```
Extend the existing `0025` `NotificationPreferences` schema with:
```yaml
        emailEnabled:
          type: object
          additionalProperties: { type: boolean }
          description: "Per-category EMAIL channel opt-in (optional categories only; transactional ignored)"
          example: { weekly_digest: false }
```
**openapi ⇄ DTO ⇄ handler sync note.** `DTOs.swift`'s `NotificationPreferences` mirror gains `emailEnabled: [String: Bool]?` (decode leniently, default `[:]`). No other DTO changes. The unsubscribe handler returns HTML, not JSON.

### 6.9 CDK / infra wiring (`stage.py` + `api_stack.py`, least-privilege)
- **`stage.py`:** construct `SesStack(self, "Ses", config=config)`; pass its outputs (`configuration_set_name`, `sender_from`, `mail_from_domain`, `events_topic`, `identity_arn`, `configured`, `postal_address`) into `ApiStack(...)`.
- **`api_stack.py`:** add Lambdas via `make_fn`: `email_fn` (`handlers.email.handler`, timeout 15), `email_events_fn` (`handlers.email_events.handler`, timeout 15), `email_unsub_fn` (`handlers.email_unsubscribe.handler`, timeout 10). Common env adds `SES_CONFIG_SET`, `SES_SENDER_FROM`, `SES_MAIL_FROM_DOMAIN`, `SES_CONFIGURED`, `EMAIL_POSTAL_ADDRESS`, `COGNITO_USER_POOL_ID` (for `email_fn`'s `AdminGetUser`), `UNSUB_SECRET_ARN`.
- **Grants (explicit, least-privilege):**
  - `email_fn`: `ses:SendEmail` on `identity_arn` (with a `ses:FromAddress`/config-set condition where practical); `cognito-idp:AdminGetUser` on the user-pool ARN; `table.grant_read_write_data` (suppression + dedupe + cap); `secretsmanager:GetSecretValue` on the unsubscribe secret (for minting links) — **scoped, not `*`**.
  - `email_events_fn`: `table.grant_read_write_data` (suppression only in practice) + `firehose:PutRecord*`; **subscribe** to `events_topic` (`topic.add_subscription(LambdaSubscription(email_events_fn))`). **No** SES/Cognito.
  - `email_unsub_fn`: `table.grant_read_write_data` (NOTIFPREFS) + the unsubscribe secret. **No** SES/Cognito/SNS.
  - The `notify` Lambda (`0025`) gains **`lambda:InvokeFunction` on `email_fn`** (or SQS send) to dispatch the email channel — the single fan-out point.
- **Routes:** `route("/v1/email/unsubscribe", GET, email_unsub_fn, secured=False)` and the `POST` variant — **no** authorizer; the handler verifies the signed token. No other new routes.
- **Secrets (prod/beta):** an **unsubscribe HMAC secret** (`mango/<stage>/email-unsub`) created in `ses_stack` (or `auth_stack`), granted only to `email_fn` + `email_unsub_fn`. v1 needs no other secret.
- **`grade_fn` stays table-less and SES-less** (invariant preserved). **No** Lambda other than `email_fn` gets `ses:SendEmail`.
- **`delete_account.py`:** no change required (send-log/dedupe under `USER#<sub>` already purged; suppression intentionally retained). Optionally emit a `security_alert`-class confirmation is **out of scope** (deletion is user-initiated and already final).

### 6.10 Producer integration (the triggers)
Each producer calls the **`0025` `enqueue`** seam with an email category — it never calls SES directly (D-1), so the gate/dedupe/suppression always run.

| Producer (spec) | Hook | Category | dedupeKey | Payload (minimal) |
|---|---|---|---|---|
| `0023` `grant_purchase` (after `PURCHASE#<txnId>` write) | post-grant | `purchase_receipt` | `receipt:<transactionId>` | `{productName, credits, priceDisplay, orderId, purchasedAt}` |
| `0023` `revoke_purchase` / `credit_notifications.py` (`REFUND`/`REVOKE`) | post-debit | `purchase_refund` | `refund:<transactionId>` | `{productName, creditsRemoved, orderId, refundedAt}` |
| `0024` redemption `status=fulfilled` (`rewards.py`) | post-fulfill | `reward_delivery` | `reward:<redemptionId>` | `{rewardTitle, rewardType, redemptionId, fulfilledAt}` |
| `0024` `sweep_draw.py` `WINNER#` (Phase C, flagged) | post-winner | `sweepstakes_winner` | `sweepwin:<sweepId>:<sub>` | `{sweepTitle, officialRulesUrl, claimDeadline}` |
| Account/security flows (Cognito Lambda trigger or our endpoints) | on change/sign-in | `security_alert` | `security:<eventId>` | `{eventKind, when, deviceHint?}` |
| proposed `0033` export job complete | post-assemble | `data_export_ready` | `export:<exportId>` | `{downloadUrl(signed,expiring), expiresAt}` |

- **`security_alert` producer note:** the cleanest source for email-change / password-change / new-sign-in is a **Cognito Lambda trigger** (`PostAuthentication`, `CustomMessage`, or a custom account endpoint) that calls `enqueue(uid, "security_alert", …)`. Defining the trigger Lambda is a small follow-up; this spec defines the **category + template + seam**, behind a `securityEmailEnabled` flag until the trigger is wired.
- **`data_export_ready` note:** depends on the proposed `0033`; the signed S3 URL (short TTL) is generated by `0033`'s export Lambda and passed in the payload — **the email body never contains data**, only the link.
- Where a producer isn't built yet, its `enqueue(...)` call site is added **with** that feature (behind its flag); the email machinery is ready to receive it.

### 6.11 Sequence (receipt happy path)
```
0023 grant_purchase ──(idempotent PURCHASE#<txnId> written)──▶ enqueue(uid,"purchase_receipt",payload,"receipt:<txn>")
notify ──load prefs/dedupe; channels={email}; gate(transactional → send)──▶ invoke email_fn
email_fn ──resolve_email(uid) [JWT/AdminGetUser, email_verified]──▶ addr
        ──is_minor? suppressed? already_sent?──▶ no
        ──render(purchase_receipt, payload)──▶ (subject,text,html)  [no card data, postal addr in footer]
        ──sesv2.SendEmail(ConfigurationSetName=mango-email-<stage>, tags)──▶ SES ──▶ inbox
        ──mark_sent; firehose email_sent{emailHash,category}
SES ──(later) Delivery event──▶ SNS topic ──▶ email_events_fn ──▶ metrics
SES ──(if it bounces) Bounce(Permanent)──▶ SNS ──▶ email_events_fn ──▶ suppress(addr)  (future sends dropped)
```

## 7. Acceptance criteria
- [ ] **AC-1 (email is a `0025` channel).** `CATEGORIES` carries `channels` + `transactional`; the email-primary categories exist with `channels={email}`; existing push categories are unchanged and **not** auto-emailed. *(unit test asserts the taxonomy shape + that no default push category has `email` in its channels.)*
- [ ] **AC-2 (templated send, mocked SES).** For a `purchase_receipt` `(uid, payload)` with a verified address, `email.deliver` renders subject+text+html and calls `sesv2.send_email` **once** with `ConfigurationSetName=mango-email-<stage>` and the `category` tag; returns `True`. *(moto/monkeypatched `send_email`; asserts call args.)* → `test_email_send.py::test_receipt_renders_and_sends`
- [ ] **AC-3 (bounce suppression).** An SNS `Bounce`(`Permanent`) event makes `email_events.handler` write `EMAILSUPPRESS#<hash>`; a subsequent `deliver(...)` to that address returns `False` with reason `suppressed` and **does not** call `send_email`. *(unit test.)* → `test_email_events.py::test_hard_bounce_suppresses_then_send_dropped`
- [ ] **AC-4 (complaint suppression).** An SNS `Complaint` event suppresses the address (same as AC-3). *(unit test.)* → `test_email_events.py::test_complaint_suppresses`
- [ ] **AC-5 (transactional not suppressed by preference / cap).** With `NOTIFPREFS` having every optional toggle off and the email cap already hit, a `purchase_receipt`/`security_alert` **still sends** (transactional exempt); a `weekly_digest` in the same state is **dropped** (`drop_disabled`/`drop_capped`). *(gate unit test + deliver test.)* → `test_notify_gate.py::test_transactional_email_bypasses_prefs_and_cap`
- [ ] **AC-6 (preference honored for optional).** A `weekly_digest` with `emailEnabled[weekly_digest]=true` and cap free **sends**; flipping it false (or via unsubscribe) **drops** it. *(gate + handler test.)* → `test_email_prefs.py::test_optional_category_respects_toggle`
- [ ] **AC-7 (unsubscribe flips only optional email channel).** `GET /v1/email/unsubscribe?token=<valid optional>` sets `emailEnabled[cat]=false` and returns 200 HTML; a token for a **transactional** category or a tampered/expired token returns **400** and changes nothing; the **push** channel is never altered. *(unit test.)* → `test_email_unsubscribe.py`
- [ ] **AC-8 (no verified email / unverified → drop).** With no `email` claim and `AdminGetUser` returning `email_verified=false`, `deliver` returns `False` (`no_verified_email`) and does not send. *(mocked Cognito.)* → `test_email_send.py::test_unverified_email_dropped`
- [ ] **AC-9 (no sensitive data in body).** A render of every template asserts the body contains **none** of: a raw high-value code, a password/token, answer/reflection text, another user's id; `reward_delivery` links to the app instead of embedding a code. *(lint-style unit test over all templates.)* → `test_email_templates.py::test_no_forbidden_fields_in_any_template`
- [ ] **AC-10 (minor never emailed).** With `USER#<sub>/AGEGATE` flagged under-13, `deliver` returns `False` (`minor`) for a transactional category and does not send. *(unit test; until `0031`, a stub sets the attribute.)* → `test_email_send.py::test_minor_suppressed`
- [ ] **AC-11 (idempotent / deduped).** Two `enqueue`s for the same `(purchase_receipt, receipt:<txn>)` send **one** email (dedupe marker `…#email`). *(unit test.)* → `test_email_send.py::test_dedupe_one_email_per_event`
- [ ] **AC-12 (best-effort).** An SES `Throttling` error retries within policy then returns `False`; the producing path is unaffected (no exception propagates). *(unit test forcing the error.)* → `test_email_send.py::test_ses_error_is_best_effort`
- [ ] **AC-13 (float-free + Decimal-safe).** Suppression `at`/`ttl`, counters, and timestamps persist as `int`; a `Decimal` read coerces to `int`. *(mirrors `test_progress_coerces_float_to_int`.)*
- [ ] **AC-14 (least privilege).** `cdk synth` shows `ses:SendEmail` only on `email_fn` (scoped to the identity), `email_events_fn` with no SES/Cognito, `email_unsub_fn` with table+secret only, and `grade_fn` still table-less. *(synth IAM inspection.)*
- [ ] **AC-15 (synth with + without a domain).** `cdk synth -c stage=beta` passes with `sendingDomain` set (identity/config-set/SNS created) **and** unset (stack exposes `configured=False`, no identity created, sends no-op). *(synth ×2.)*
- [ ] **AC-16 (contract sync).** `openapi.yaml` defines `/v1/email/unsubscribe` (GET+POST, `security:[]`) and the `emailEnabled` preference field; `DTOs.swift` mirrors `emailEnabled`; openapi lint + DTO decode test pass.
- [ ] **AC-17 (Cognito auth email untouched).** No change to `auth_stack.py`'s email/verification config; Cognito still owns sign-up/forgot-password email. *(diff review + synth.)*

## 8. Test plan
**Backend — `pytest` (moto mocks SES v2/SNS/Cognito; `send_email` asserted), new files under `backend/tests/`:**
- `test_email_send.py` — core `shared/email.deliver` paths using the `aws` moto fixture: receipt render+send (AC-2), unverified/no-address drop (AC-8), minor drop (AC-10), dedupe (AC-11), SES-error best-effort (AC-12). Mocks `cognito_idp.admin_get_user` and asserts `send_email` call args (From, ConfigurationSetName, tags, To). Asserts the raw address never appears in captured logs (only the hash).
- `test_email_events.py` — `email_events.handler` with synthetic SNS `Bounce`(Permanent / Transient) and `Complaint` payloads: hard bounce + complaint suppress (AC-3/AC-4); transient bounce does **not** permanently suppress; `Delivery` writes no suppression. Asserts the suppression item shape (int `at`/`ttl`, hashed key) and that a follow-on `deliver` is dropped.
- `test_email_templates.py` — render every template with a representative payload; assert subject non-empty, **text part present**, postal address in footer, unsubscribe link **present for optional / absent for transactional**, and the **forbidden-field lint** (AC-9) — a denylist of substrings (sample raw code, "password", a fake reflection string) must not appear in any rendered body.
- `test_notify_gate.py` (extend `0025`'s) — the `channel` param + `transactional` short-circuit: transactional bypasses disabled/quiet/cap on email (AC-5); optional respects disabled/cap per channel (AC-6); push behavior for existing categories unchanged (regression).
- `test_email_prefs.py` / `test_email_unsubscribe.py` — optional toggle respected (AC-6); unsubscribe flips only the optional email channel, rejects transactional/expired tokens, never touches push (AC-7); HMAC verification.
- `test_email_float.py` — `Decimal`→`int` coercion for suppression/counters (AC-13), mirroring `test_progress_coerces_float_to_int`.
- **`cdk synth -c stage=beta` ×2** (AC-15) — once with a `sendingDomain` context/config value, once without; plus IAM inspection (AC-14) and the unauthenticated unsubscribe route (AC-7/AC-16).
- **Contract:** extend `test_contract.py` — assert `/v1/email/unsubscribe` exists with `security:[]` and `emailEnabled` is in `NotificationPreferences`.

**iOS — `make ios-test` / ⌘U:**
- `NotificationPreferencesTests` (extend `0025`'s) — `NotificationPreferences` DTO decodes `emailEnabled` leniently (absent → `[:]`); the Settings list shows an "also email me" toggle **only** for optional categories and **not** for transactional ones; toggling round-trips via `PUT /v1/me/notification-preferences`.

**Manual / deliverability (staged):**
- In **sandbox**, verify a test recipient, trigger a sandbox purchase (StoreKit test) → confirm a receipt arrives, renders in Apple Mail + Gmail (text + HTML), DKIM/SPF/DMARC **pass** (check headers), and the SNS topic receives a `Delivery` event.
- Force a bounce via the **SES mailbox simulator** (`bounce@simulator.amazonses.com`) and a complaint (`complaint@simulator.amazonses.com`) → confirm `email_events` suppresses and a follow-up send is dropped.
- Confirm the **unsubscribe** link (optional category) flips the toggle and that **no** unsubscribe link renders on a receipt.

## 9. Rollout & migration
1. **Stack + DNS (sandbox).** Land `ses_stack` with `sendingDomain` set for **beta**; add the **DKIM CNAMEs + MAIL FROM MX/SPF + DMARC TXT** to DNS (output by the stack, or auto-added if a Route 53 zone is provided). Wait for the identity to verify. Email machinery deploys but stays in **SES sandbox** (only verified recipients receive mail) — fine for beta testing.
2. **Wire producers behind flags.** Add `enqueue(...)` calls in `0023`/`0024` (and the proposed `0033` when it lands), each behind its feature flag; `security_alert`'s Cognito trigger behind `securityEmailEnabled`. With flags off, no email sends; turning a flag on routes that event's email through the gate.
3. **Production-access request (Transactional).** Once the beta domain verifies and a real website/landing exists (cross-ref proposed web/landing item), file the SES **production-access** request choosing **Transactional**; on approval, beta/prod can mail any recipient. Keep bounce/complaint alarms (cross-ref `0032`) green before/after.
4. **DMARC tightening.** Start `_dmarc` at `p=none` (monitor via `rua`), then move to `p=quarantine` and consider `p=reject` once DKIM/SPF alignment is confirmed clean (D-6).
5. **Backward compatibility.** Purely additive: no existing endpoint changes behavior; `0025` push is untouched (email is an additional channel). A stage with `sendingDomain` unset (e.g. a dev synth) compiles and no-ops. `DELETE /v1/me` semantics unchanged.
6. **Teardown.** Disabling email = remove the `enqueue` email categories (or set `SES_CONFIGURED=false`); suppression items self-expire via TTL. Removing the stack deletes the identity/config-set/topic (RETAIN on prod identity to avoid re-verification churn — match the repo's prod-RETAIN convention).

## 10. Risks & open decisions
- **Risk: domain/reputation.** A bad first send (no DKIM/SPF alignment, or mailing unverified/bounced addresses) damages sender reputation and can get SES paused. **Mitigation:** custom MAIL FROM for alignment, suppression-before-send, `email_verified`-only recipients, dedicated **subdomain** sender, bounce/complaint alarms (`0032`), start in sandbox.
- **Risk: leaking sensitive data in email.** A template could accidentally embed a code or PII. **Mitigation:** the forbidden-field **lint test** (AC-9), reward codes revealed **in-app only**, export links **signed + expiring** with no data in body, minors never emailed.
- **Risk: transactional/optional mis-classification.** A marketing message sent as "transactional" (no unsubscribe) is a CAN-SPAM violation. **Mitigation:** `transactional` is a **server-side category property**; only the closed transactional set is exempt; the one optional example carries unsubscribe; reviewers gate any new category's classification.
- **Risk: stdlib-only HTML.** Hand-built HTML can render poorly across clients. **Mitigation:** simple, inline-styled, table-light HTML with an authoritative **text part**; manual cross-client check in §8.
- **Decision D-1 (fan-out point).** Email is dispatched **by the `0025` `notify` Lambda**, not by producers directly — guarantees gate/dedupe/suppression. **Recommend: adopt.**
- **Decision D-2 (recipient source).** JWT `email` claim when present+verified, else **`AdminGetUser`**. **Recommend:** prefer the claim (no extra call) and fall back to `AdminGetUser` for server-originated sends (webhooks/cron). Pass the claim through `enqueue`'s payload when the trigger is request-scoped.
- **Decision D-3 (transport).** **Amazon SES v2 `SendEmail`** (Simple content) from Lambda via boto3. **Recommend: adopt** (no packaging; native). Raw MIME only if attachments are ever needed (export is a **link**, not an attachment — so Simple suffices).
- **Decision D-4 (reward codes).** **Do not** put high-value coupon/giftcard codes in the email body; link into the app to reveal (the app already holds the artifact per `0024`). Low-value/token codes **may** be included if `0024` deems them non-sensitive — default **link-only**. **Recommend: link-only.**
- **Decision D-5 (suppression retention vs deletion).** Suppression is keyed by **email hash** and **retained past account deletion** (with TTL) to protect reputation if the address re-registers — a deliberate exception to per-`sub` purge, privacy-safe because no raw address is stored. **Recommend: adopt;** document in the privacy notice. (If counsel prefers strict deletion, switch the key to `sub` and accept the reputation risk — **decision needed** with privacy/legal.)
- **Decision D-6 (DMARC policy ramp).** Start `p=none`, ramp to `quarantine`/`reject`. **Recommend: adopt** the staged ramp.
- **Decision D-7 (Cognito → SES for auth email).** Optionally configure the Cognito user pool's email to send **via SES** (branded, higher limits) for verification/reset. **Recommend: defer** (separate change; keep this spec to product email) — noted so the verified identity here can later serve Cognito too.
- **Open decision (postal address).** CAN-SPAM wants a valid physical postal address in optional mail (and best-practice in transactional). **Needs:** a real mailing address (or a registered agent / PO box) from the business. Blocks production-access polish, not the build.

## 11. Tasks & estimate
1. **(S)** Extend `0025` `CATEGORIES` with `channels` + `transactional`; add the six email categories + `weekly_digest` (optional, off). Update the client mirror's category metadata (no UI yet).
2. **(M)** `ses_stack.py`: domain identity + Easy DKIM, custom MAIL FROM, configuration set + SNS event destination, sender/postal config, outputs; **safe sandbox defaults** (gated on `sendingDomain`). Compose into `stage.py`.
3. **(M)** `shared/email.py` (`deliver`, `resolve_email`, `is_suppressed`, `is_minor`, dedupe/cap helpers, `_ses_send` with retry) + `handlers/email.py` (thin, invoked by `notify`).
4. **(M)** `shared/email_templates.py` — six templates (text+HTML), shared chrome (postal address, conditional unsubscribe), i18n-ready function registry.
5. **(S)** Extend `shared/notify_gate.py` with the `channel` arg + `transactional` short-circuit; extend `notify` to fan out push **and** email and to use channel-suffixed dedupe/count keys.
6. **(M)** `handlers/email_events.py` — SNS subscriber; suppression writes (hard bounce/complaint), soft-bounce counter, Firehose health events; SNS subscription in `api_stack.py`.
7. **(S)** `handlers/email_unsubscribe.py` + HMAC token mint/verify (`shared/email.py` `_unsub`/`verify_unsub`); `GET`/`POST /v1/email/unsubscribe` route (`secured=False`); unsubscribe secret in CDK.
8. **(S)** `api_stack.py` wiring: `email_fn`/`email_events_fn`/`email_unsub_fn` via `make_fn`, env vars, **least-privilege grants** (SES scoped, AdminGetUser, table, secret), `notify`→`email_fn` invoke grant.
9. **(S)** Producer hooks: `enqueue(...)` calls in `0023` (`purchase_receipt`/`purchase_refund`) and `0024` (`reward_delivery`, Phase-C `sweepstakes_winner`), each behind its flag; stub the `security_alert` + `data_export_ready` call sites for when those producers land.
10. **(M)** Tests: `test_email_send.py`, `test_email_events.py`, `test_email_templates.py`, `test_email_prefs.py`, `test_email_unsubscribe.py`, extend `test_notify_gate.py` + `test_contract.py`; **synth ×2** (domain set/unset) + IAM inspection.
11. **(S)** openapi: `/v1/email/unsubscribe` + `emailEnabled` on `NotificationPreferences`; `DTOs.swift` mirror; iOS Settings — "also email me" toggle for optional categories only (extend the `0025` list) + DTO test.
12. **(S)** Ops/runbook (in PR description / `docs` if requested): DNS records to add, sandbox→production (Transactional) steps, DMARC ramp, bounce/complaint alarm thresholds (cross-ref `0032`), postal-address + sending-domain config keys.

## 12. References
- Amazon SES v2 `SendEmail` (boto3 `sesv2`) — request shape, `ConfigurationSetName`, `EmailTags`: https://boto3.amazonaws.com/v1/documentation/api/latest/reference/services/sesv2/client/send_email.html
- Amazon SES — authenticating email with **DKIM** (Easy DKIM, CNAMEs, rotation): https://docs.aws.amazon.com/ses/latest/dg/send-email-authentication-dkim.html
- Amazon SES — **DMARC** compliance (SPF/DKIM alignment, custom MAIL FROM): https://docs.aws.amazon.com/ses/latest/dg/send-email-authentication-dmarc.html
- Amazon SES — **request production access** (moving out of the sandbox; Transactional vs Marketing): https://docs.aws.amazon.com/ses/latest/dg/request-production-access.html
- Amazon SES — **event publishing** / bounce & complaint notifications via SNS (configuration sets, event destinations): https://docs.aws.amazon.com/ses/latest/dg/monitor-using-event-publishing.html
- Amazon SNS notification contents for SES (Bounce/Complaint/Delivery JSON for the suppression subscriber): https://docs.aws.amazon.com/ses/latest/dg/notification-contents.html
- FTC — **CAN-SPAM Act** compliance guide (transactional/relationship exemption; truthful headers; postal address; opt-out timing): https://www.ftc.gov/business-guidance/resources/can-spam-act-compliance-guide-business
- Cognito Identity Provider — **`AdminGetUser`** (boto3) for resolving the verified `email`/`email_verified` attribute server-side: https://boto3.amazonaws.com/v1/documentation/api/latest/reference/services/cognito-idp/client/admin_get_user.html
- **Internal cross-references:** `working/0025-notifications.md` (channel/preference model, pure gate, `enqueue`/`notify` seam — extended here), `working/0023-payments-and-credits.md` (receipt/refund triggers), `working/0024-rewards-and-coupons.md` (reward-delivery + sweepstakes-winner triggers), `working/0031-age-assurance-coppa.md` (minors-not-emailed gate), proposed `0033` (data-export-ready trigger) and `0034` (admin/support address) from `working/ARCHITECTURE_REVIEW.md` §3 (G15) / §4, `working/0032` observability (deliverability alarms — proposed).
