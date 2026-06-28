# 0043 — Peer & human-in-the-loop activities

- **Epic:** M16 · **Status:** Draft · **Owner:** unassigned · **Updated:** 2026-06-28
- **Reviewers:** Principal / SD / QA / **Safety** / **Legal**

> ⚠️ **Read §10 first.** This is the most **safety-sensitive** spec in the activity cluster: it
> arranges sessions where a Mango user talks to **another human** about what they learned. The
> default posture is **maximum caution**. Two things are **hard gates that block ship and cannot be
> waived by engineering**: (1) **minors are excluded from any session with a person they do not
> already know** (no exceptions — see §6.2, §10 G-1), and (2) **no offline / in-person meetups are
> designed or shipped in this spec** (Phase C is explicitly deferred pending Legal + Safety sign-off —
> §6.2, §10 G-2). Every section below is written so that the *lowest-risk* capability (a **1:1
> interview with a vetted Mango facilitator**, Phase A) can ship **first and alone**, and the
> higher-risk peer↔peer capability (Phase B) is held behind separate, explicit Safety/Legal approval.

## 1. Summary
Mango's activity framework (`0039`) defines a `peer_session` kind with the `human` grading method —
an activity completed not by a model but by a **real person verifying** that the learner can
discuss, explain, and **defend** what a book taught them. This spec implements that kind as
**peer & human-in-the-loop activities**: structured, **online** sessions where a user articulates and
is gently tested on a chapter's ideas, with completion **verified by a human** and rewarded with XP
(and, where the user is on the paid backend, credits via `0023`). We ship it in **three strictly
phased tiers, safety-first**: **Phase A — facilitator interview** (1:1 with a **vetted Mango team
member / contracted facilitator** who interviews the learner against a rubric — a controlled,
lower-risk "structured viva"); **Phase B — peer↔peer online** (two **opt-in adult** Mango users,
matched from the `0021` social graph, meeting over **in-app-first or a managed video link**, wrapped
in strong trust-&-safety); and **Phase C — offline / in-person**, which is **explicitly out of scope
and deferred** pending a dedicated Legal + Safety review (and is **never** offered to minors at all).
The recommendation is unambiguous: **ship Phase A first**, prove the session/verification machinery
and the safety surfaces on the controlled 1:1-with-staff path, and only then consider Phase B behind
its own sign-off. Everything reuses the existing seams — the `0039` `human.pending` grading handoff
and lifecycle, the `0021` friends/block/report graph, `0025` notifications, `0023` credits, `0031`
age-gating (when it lands), and `0034`'s moderation queue (when it lands) — and honors Mango's
invariants (iOS zero-deps, Lambda stdlib+boto3, single DDB table, float-free, Cognito JWT, S3 under
`users/<sub>/`, openapi ⇄ DTO ⇄ handler lockstep).

## 2. Goals / Non-goals
- **Goals:**
  - **Implement the `peer_session` kind + `human` grading method** against the frozen `0039`
    contract: a `peer_session` activity is `assigned → … → grading` and **parks in `grading`** until a
    human verification signal arrives (a later `gradeReturned`), then proceeds to `graded(passed)` →
    `rewarded` exactly like every other kind (no special lifecycle).
  - **Phase A (ship first): the facilitator interview.** A learner requests a 1:1 session; a **vetted
    facilitator** (Mango staff or a contracted, background-checked, trained reviewer) accepts,
    schedules, runs a short structured interview against a **rubric**, and records a pass/score +
    feedback. This is the controlled, lowest-risk tier and the only one this spec *requires* to ship.
  - **Phase B (behind separate Safety/Legal sign-off): peer↔peer online.** Two **opt-in adults**,
    **matched from the `0021` mutual-friend / buddy graph first** (not cold strangers), schedule and
    meet over **in-app-first messaging and a managed video option**, then **both confirm** completion;
    a sampled fraction is human-reviewed. Strong T&S throughout (§6.6, §10).
  - **A matching + scheduling layer:** availability windows, **time-zone-correct** display, **explicit
    two-sided consent** before any pairing, reschedule and **no-show** handling, and reminders via
    `0025`.
  - **A session-completion + assessment capture:** for Phase A, a **facilitator rubric form**
    (structured viva); optionally a **recorded + model-graded reflection** via `0040` as corroborating
    evidence; for Phase B, **mutual confirmation + spot-check**. Reward (XP via `0039`'s `xpAwarded`;
    credits via `0023`) granted **once**, on a verified pass.
  - **Trust & safety as the core feature, not an afterthought:** a **hard age gate excluding minors**
    from stranger sessions (`0031`); identity/eligibility checks; **in-app block & report** (reuse
    `0021`); a **moderation / escalation queue** (`0034`); facilitator **vetting / background
    expectations**; a **code of conduct** gate; **recording-consent** handling under all-party-consent
    law; minimal **data handling / retention**; and a clear, conservative **liability / ToS posture**.
  - **Honor the invariants:** zero third-party iOS deps; Lambda stdlib+boto3; single DDB table
    (`PK`/`SK` + `GSI1`); **float-free** (scores in basis points, ints only); Cognito JWT auth; S3
    artifacts under `users/<sub>/`; `openapi.yaml` ⇄ `DTOs.swift` ⇄ handlers in lockstep.
- **Non-goals:**
  - **Offline / in-person meetups (Phase C).** Explicitly **deferred and out of scope**; §6.2 states
    the risks and the gate. We design **online-only** here, and **never** design offline-for-minors.
  - **Building a video stack.** We do **not** build WebRTC/SFU infrastructure. We recommend a
    **privacy-preserving option**: in-app text-first, plus (Phase B) either a vetted **external E2EE
    video link** (e.g. a reputable provider) created per-session, or a managed in-app call if/when
    justified — chosen in §6.5 / §10 D-3. No third-party iOS SDK is added regardless.
  - **A real-time presence / chat product.** Sessions are *scheduled*, not a live chat surface; the
    in-app messaging here is a **minimal, moderated, session-scoped** thread, not DMs (which `0021`
    explicitly excludes).
  - **Re-implementing the activity framework, social graph, credits, age-gating, notifications, or the
    admin console** — those are `0039`, `0021`, `0023`, `0031`, `0025`, `0034`. We **consume** them and
    define the seams; where a dependency (`0031`, `0034`) is not yet written, we specify the **minimum
    gate this spec needs** and make it a hard blocker (§9, §10).
  - **Facilitator marketplace / payments to facilitators, scheduling-platform features** (calendars,
    payroll). Phase A facilitators are a small **internal/contracted pool**; compensation/ops are out
    of scope.
  - **Changing gamification math or the grading contract.** We emit `human` outcomes into the `0039`
    contract; XP/credit amounts and the lifecycle are unchanged.

## 3. Background & context
**The framework already reserves this.** `0039` (Activity type framework) defines `peer_session`
as one of three **external** kinds, modality `external_proof`, default grading method **`human`**,
XP band **50**, difficulty 4–5 (Bloom *evaluate/create*), `verification{proofType: peer_confirm,
verifier: peer}`, and names **this spec (`0043`) as its implementer** (`0039` §6.4 table). The
grading contract's `human` branch is a stub here in `0039`:
```python
if method == "human":
    return human.pending(activity, submission)   # HANDOFF → 0043 (returns pending)
```
`human.pending` returns `{passed: None, pending: true}` and **the lifecycle stays in `grading`** until
a peer/human signal arrives as a later `gradeReturned(scoreBp, passThresholdBp)` (`0039` §6.3, §6.5).
That is the exact seam this spec fills: *what produces that human signal, who is allowed to produce
it, and how we keep the people involved safe.*

**The social graph already exists to build on.** `0021` (Social leagues, friends & buddies) ships
**opt-in** identity (a non-PII **handle**, never email/`sub` over the wire), **mutual friends** via
request/accept, **reading buddies** (1:1 accountability pairing), and — critically — first-class
**block** (`POST /v1/friends/{handle}/block`) and **report** (`POST /v1/reports` →
`PK=REPORT#<id> SK=META {reporterSub, targetHandle, reason, at}`, *"queued for review"*), plus a
**code-of-conduct gate at opt-in** and a **non-competitive / safety** posture ("no public shaming",
"harassment surfaces are first-class, not afterthoughts", `0021` §6, §10 R-2). Peer↔peer matching in
this spec **draws from that graph** (friends/buddies first), and **reuses block/report verbatim** —
we do not invent a parallel safety surface.

**Why now / why a dedicated spec.** Discussing and **defending** an idea to another person is the
highest rung of the active-learning ladder Mango is built on (`0008`): the literature on
**peer/cohort learning** shows large engagement and retention gains when learners "discuss and defend
their understanding" together, and the literature on **oral/viva assessment** shows a *structured*
oral exam (fixed questions + a rubric + a trained examiner) is a **valid, reliable, authentic**
assessment of reasoning that written tests cannot reach (§12). But the same act — **connecting two
people** — is exactly where consumer apps incur their gravest harms. The trust-&-safety playbook from
**dating and marketplace apps** is unambiguous: identity signals, **in-app-only communication first**,
robust **reporting/blocking**, fraud/abuse detection, **human moderation**, **no-show handling**, and
transparency about data — *and* a hard line around **minors interacting with adults** (the 2024
DOJ/FTC action against TikTok turned in part on letting minors interact with adults; §12). A feature
that books a stranger interaction therefore **cannot** be folded into `0039` or `0021` as a footnote;
it needs its own spec with the **safety analysis in front** and the riskiest capability **deferred**.

**What does not exist yet (and what this spec needs from it).** Two dependencies are *proposed* in
`working/ARCHITECTURE_REVIEW.md` but **not yet written**:
- **`0031` — Age assurance & COPPA/kids compliance** (gap **G4**): *"neutral DOB age gate; under-13 →
  block monetization/social/push or parental consent … Needs counsel."* This spec **requires** an age
  signal to enforce its hard minor-exclusion gate. Until `0031` ships, §6.2 defines the **minimum age
  gate this feature must have to ship at all** (it is a blocker, not a nicety).
- **`0034` — Admin & support console** (gap **G10**): *"moderation queue, support lookups, credit/
  refund admin_adjust."* This spec **requires** a place for reports/escalations to land and be acted
  on, and for facilitators to be managed. Until `0034` ships, §6.6 defines the **minimum moderation
  surface** (even if it is initially an internal-only Lambda + a DDB queue read by staff).

**Credits & notifications are ready to consume.** `0023` (Payments & credits) provides a
server-authoritative, append-only **credit ledger** (`USER#<sub>/CREDITLEDGER#<ts>#<uuid>`,
**idempotent earn**, reserving an `admin_adjust` reason and a bonus-grant seam). A verified
`peer_session` pass emits the `0039` `rewarded` terminal + `xpAwarded`; if the user is on the
`RemoteAIService` (paid) path, the credit-earn seam grants credits **once**. `0025` (Notifications)
provides local + APNs push for scheduling reminders, accept/decline, no-show, and "your session was
verified" events.

**Related specs.** Implements a kind of: `0039`. Builds on: `0021` (graph + block/report), `0023`
(credits), `0025` (notifications). **Hard-depends on (gating):** `0031` (age — minor exclusion) and
`0034` (moderation queue / facilitator management). Coordinates with: `0040` (a recorded reflection
can corroborate a session), `0026`/`0027` (server tracking + artifact/observability for session
records and any consented recording), `0014` (sync rides the per-user session items), `0019`
(sign-in — sessions require an authenticated, real account; no anonymous sessions ever).

## 4. User stories
- As a **learner who finished a hard chapter**, I want to **book a short interview with a Mango
  facilitator** and explain the key idea out loud, so a real person confirms I genuinely understood it
  and I earn the reward — a credential that a quiz can't give. *(Phase A)*
- As a **learner**, I want to pick **availability windows in my own time zone**, get matched, and
  receive **reminders**, so scheduling is painless and I don't miss it. *(Phase A/B)*
- As a **facilitator**, I want a **rubric form** with the chapter's objectives and a few standard
  questions, so my interview is **structured, fair, and consistent**, and my pass/score/feedback flows
  straight back into the learner's journey. *(Phase A)*
- As an **adult learner who opted into social**, I want to be **matched with a friend or buddy** (not
  a cold stranger) to **discuss and defend** a book together over an **in-app/managed video** session,
  and have us **both confirm** it happened, so we both earn the reward. *(Phase B, gated)*
- As **any user in a session**, I want **block and report** one tap away, **clear consent** before I'm
  ever paired or recorded, and the confidence that **the app keeps comms in-app first** and never
  shares my email or real identity. *(All phases)*
- As a **minor (or a user of unknown/under-18 age)**, I want the app to **simply not offer** me any
  session with someone I don't already know — the feature is **absent**, not merely restricted. *(Hard
  gate, all phases.)*
- As **Trust & Safety / an admin**, I want every report and no-show to land in a **queue** I can act on
  (warn, suspend, ban, remove a facilitator), with the **minimum data** needed and nothing more. *(All
  phases.)*
- As a **user who changes their mind**, I want to **cancel or leave** a pending session, withdraw
  consent, and have my session data handled per a clear retention policy. *(All phases.)*

## 5. Requirements
### Functional
- **FR-1 (`peer_session` via the `0039` `human` method).** A `peer_session` activity is graded by the
  `human` method. On submit, `human.pending(...)` returns `{passed: null, pending: true}` and the
  lifecycle stays in **`grading`**; a later **human verification** event drives
  `gradeReturned(scoreBp, passThresholdBp)` → `graded(passed|failed)` → (on pass) `awardGranted` →
  `rewarded`. No new lifecycle states; idempotent award-once is preserved (`0039` §6.3, FR-5).
- **FR-2 (Phase A — facilitator interview, ships first).**
  - **FR-2.1** A user with an eligible account (signed in `0019`; **age-eligible** per FR-9) may
    **request** a facilitator session for a specific objective/book: `POST /v1/sessions/request` with
    `{ kind: "facilitator", activityId, objectiveRef, availability[] }`.
  - **FR-2.2** A **vetted facilitator** (FR-10) is offered the request and **accepts/declines**;
    accept creates a **scheduled** session at a mutually-available time (FR-4).
  - **FR-2.3** The session runs **online** (in-app messaging first; optional managed video, FR-6). The
    facilitator completes a **structured rubric form** (FR-7) → score + feedback → a
    `gradeReturned`-equivalent signal (FR-1). Optionally the learner records a short **reflection**
    graded via `0040` as **corroborating** evidence (never the sole basis).
  - **FR-2.4** On a verified pass, reward is granted **once** (XP via `0039`; credits via `0023` on the
    paid path). The learner gets a "verified" notification (`0025`).
- **FR-3 (Phase B — peer↔peer online, gated).** Behind **`peerSessionsPeerEnabled`** *and* explicit
  Safety/Legal sign-off (§9/§10):
  - **FR-3.1** Only **opt-in adults** (FR-9 hard gate) participate. Matching draws from the **`0021`
    graph**: **mutual friends / buddies first**; broader matching (acquaintances of acquaintances, or
    same-book opt-in pool) is a **later, separately-approved** sub-phase, never cold-stranger by
    default (§10 D-2).
  - **FR-3.2** **Both sides explicitly consent** to the pairing (a request → accept handshake, mirroring
    `0021` friend requests) **before** any contact channel opens. Either may cancel any time.
  - **FR-3.3** Contact is **in-app first** (a minimal, **session-scoped**, moderated thread). A
    **managed video option** (FR-6) may be offered for the scheduled slot. No exchange of email/phone
    is solicited or stored.
  - **FR-3.4** Completion requires **mutual confirmation** (both tap "we completed this"); a **sampled
    fraction** (`verification.spotCheckRate`) is routed to human review before reward (anti-collusion).
    Reward granted **once** per participant on a verified pass.
- **FR-4 (matching + scheduling).** The system captures **availability windows** per user, displays all
  times **in the viewer's local time zone** (store UTC; render local — never a bare "9am"), proposes a
  mutually-available slot, and on accept creates a **scheduled** session with a start time + duration.
  Supports **reschedule** (either party proposes a new slot; the other accepts) and **cancel**.
  **No-show** is detected when a session passes its window without both parties marking present;
  no-shows are **logged**, surfaced to the other party gently, **never auto-punished with XP loss**,
  and **repeat no-shows** feed a reliability signal / escalation (FR-11, §6.6).
- **FR-5 (reminders via `0025`).** Schedule, accept/decline, **T-24h / T-1h reminders**, reschedule,
  no-show, and "verified" all emit notifications through `0025` (local + APNs), respecting the user's
  notification settings and quiet hours.
- **FR-6 (the session channel — privacy-preserving, in-app-first).** v1 default channel is **in-app
  text** (session-scoped, moderated). An optional **video** channel uses a **privacy-preserving**
  approach (§6.5): a **per-session, invite-only, encrypted external link** (recommended) created at
  schedule time and revoked after, surfaced **inside** the app — **never** posted publicly, never
  reused, and **not** requiring users to exchange personal contact details. **No third-party iOS SDK**
  is added; we open the link in a web view / Safari. Any **recording is off by default** and only
  permitted with **all-party consent** (FR-8).
- **FR-7 (assessment capture — facilitator rubric / corroborating reflection).** Phase A completion is
  captured via a **structured rubric form** (a "structured viva": fixed objective-aligned questions +
  scored criteria incl. a **mandatory negative criterion**, reusing the `0039` `Rubric` value type),
  producing `scoreBp` + `feedback`. Optionally a `0040` **recorded reflection** is attached as
  corroborating evidence (model-graded), but the **human score is authoritative**. Phase B completion is
  captured via **mutual confirmation** + optional spot-check (a reviewer applies a light rubric).
- **FR-8 (recording consent — all-party).** Sessions are **not recorded by default.** If a recording
  is ever made (e.g. a facilitator wants to capture a reflection for QA, or a learner opts to record
  their own answer for `0040` grading), the app MUST obtain **explicit, logged consent from every
  participant before recording starts** (all-party-consent posture, the strictest US standard; §12),
  show a persistent "recording" indicator, allow any party to **stop** it, store the artifact under
  `users/<sub>/` (S3), and apply a **short retention** with deletion on `DELETE /v1/me` (FR-13).
- **FR-9 (age gate — the hard minor exclusion).** **Minors (and any user whose age is unknown or
  < 18) are excluded from every session with a person they do not already know.** This is enforced at
  **eligibility** (the request/match endpoints reject ineligible users) and at the **UI** (the feature
  is **not surfaced** to them — absent, not greyed-out). The age signal comes from **`0031`** when it
  ships; until then, this spec's **minimum gate** is: a **neutral DOB / age-band check** at first use
  of any session feature, a stored age-eligibility flag, **fail-closed** (no signal → not eligible),
  and **no parental-consent path that would admit an under-18 into a stranger session** (we simply do
  not offer it — §10 G-1). *(A facilitator session is **staff-only on the other side**, so a future,
  separately-approved "minor + vetted-facilitator-only, parental-consent, recorded, no-peer" mode MAY
  be considered later — but it is **out of scope here** and requires its own Legal/Safety spec; the
  default remains exclusion.)*
- **FR-10 (facilitator vetting / eligibility).** A facilitator may run sessions only if they are in a
  **vetted facilitator pool**: **identity-verified**, **background-checked to the standard Legal
  specifies** (esp. because they may interview adults 1:1; the *minor* path is not offered at all in
  scope), **trained** on the rubric + code of conduct + safeguarding, under a **facilitator agreement**,
  and **revocable** instantly. The pool is managed via **`0034`** (or, interim, an internal-only
  Lambda + a `FACILITATOR#` DDB item). Facilitators see only what they need (handle + the objective +
  rubric — **not** the learner's email/`sub`).
- **FR-11 (block / report / escalation — reuse `0021`, land in `0034`).** Every session surface exposes
  one-tap **block** and **report** reusing `0021`'s `POST /v1/friends/{handle}/block` and
  `POST /v1/reports`. A **session-specific report** (`POST /v1/sessions/{id}/report`) captures context
  (session id, role, reason, optional free text). Reports, no-show patterns, and safety flags land in a
  **moderation/escalation queue** (`0034`); blocking removes any pairing and prevents future matching
  between those users (symmetric, final-in-effect, per `0021`). A reported/blocked counterpart is
  **never re-matched**.
- **FR-12 (code of conduct gate).** Before a user can request or accept **any** session, they must
  accept a **session code of conduct** (be respectful, in-app-first, no solicitation, no recording
  without consent, how to report) — a one-time, versioned acceptance (reusing `0021`'s code-of-conduct
  gate pattern), re-prompted if the CoC version changes.
- **FR-13 (data handling / retention / erase).** Store the **minimum**: session metadata (parties by
  `sub`/handle, times, state, outcome), the rubric result, report records, and (only if consented) a
  recording **key** in S3. **No** transcripts of in-app session chat beyond what moderation needs;
  **no** scraped third-party content. Apply **retention** (session metadata + rubric: keep for the
  account's life or a bounded window; recordings: short, e.g. ≤30–90 days unless flagged for a safety
  investigation; chat: minimal). `DELETE /v1/me` (`0021`/`0004`) **cascades** all session items,
  pairings, reports-as-reporter context, and S3 recordings for that user.

### Non-functional
- **NFR-1 (safety-by-design + fail-closed).** Every eligibility, consent, age, and matching decision
  **fails closed**: missing age signal → not eligible; missing consent → no channel; ambiguous state →
  no pairing. Safety surfaces (block/report) are reachable from **every** session screen and never
  more than one tap away (`0021` posture).
- **NFR-2 (privacy — handle-only, minimal data, in-app-first).** Peers/facilitators see a **handle**,
  never email/`sub`; the app **never solicits or stores** personal contact details; comms are
  **in-app-first**; any external video link is **per-session, invite-only, not public** (§12 dating-app
  lesson: in-app comms + transparency). Recordings are user content under `users/<sub>/` with
  least-privilege access.
- **NFR-3 (compliance gates — explicit Legal/Safety sign-off).** Shipping any peer↔peer capability
  (Phase B) and any recording feature is **blocked** until Legal signs off the **ToS/liability posture**
  (§6.7), the **recording-consent** flow (FR-8), the **age gate** (§6.2, `0031`), and the
  **facilitator background-check standard** (FR-10). Offline (Phase C) is **out of scope** and would
  need a separate spec + sign-off (§10 G-2).
- **NFR-4 (backend stdlib+boto3, float-free).** New handlers use only stdlib + boto3; all numeric DDB
  attrs are `int` (scores in **basis points 0–10000**, times as ISO strings or epoch `int`); no Python
  `float` reaches DynamoDB (`progress.py`/`generate_roadmap.py` rule). State machine is **pure** and
  unit-tested (the `0039`/`LevelCurve` style).
- **NFR-5 (no third-party iOS deps; Xcode-16 sync groups).** Pure SwiftUI/SwiftData/Foundation; new
  files under `ios/Mango/` auto-register; **no** video/WebRTC SDK, **no** calendar SDK. Video, if used,
  is an external link opened in `SFSafariViewController`/web view.
- **NFR-6 (contract lockstep).** `shared/api/openapi.yaml` ⇄ `Services/Networking/DTOs.swift` ⇄
  `backend/src/handlers` stay in sync; `cdk synth -c stage=beta` and `pytest` (moto + monkeypatched
  Bedrock) pass **offline**. `peer_session` activities and their renderer **never** appear in the
  offline sample (they require the network + a real account; `0039` FR-8).
- **NFR-7 (design tokens / a11y).** All new screens use `Palette`/`Typo`/`Metrics`/`Haptics`; every
  control has a VoiceOver label and a non-gesture path (WCAG 2.5.1); state (scheduled/awaiting/verified)
  is conveyed by **label + icon**, not color alone; reminder copy is calm and non-coercive (`0021`
  "no shaming" tone).
- **NFR-8 (least-privilege IAM).** The session Lambdas get **only** the table/GSI access they need; the
  rubric/verification writer is the **only** path that can write a session outcome / emit the XP-earn
  ledger entry; the recording path is the only one with scoped `s3:PutObject`/`GetObject` on
  `users/<sub>/sessions/*` (mirrors `api_stack.py` least-privilege).

## 6. Design

### 6.1 Phasing (safety-first — the spine of this spec)
| Phase | What | Who is "the other person" | Channel | Risk | Ship? |
|---|---|---|---|---|---|
| **A — Facilitator interview** | 1:1 structured viva; facilitator scores a rubric | **Vetted Mango staff / contracted facilitator** (background-checked, trained) | In-app text first; optional **managed video link** | **Lower** (controlled; one side is vetted; no stranger-to-stranger) | **YES — ship first, alone** |
| **B — Peer↔peer online** | Two learners discuss & defend; **both confirm** + spot-check | **Another opt-in adult Mango user**, **friend/buddy first** | In-app text first; optional managed video link | **Higher** (two members; abuse/harassment surface) | **Behind `peerSessionsPeerEnabled` + Safety/Legal sign-off** |
| **C — Offline / in-person** | Meeting in the real world | — | Physical | **Highest** (assault, liability, duty-of-care) | **NO — out of scope / deferred; never for minors** |

**Recommendation (explicit):** **Ship Phase A first and on its own.** It exercises the entire
machine — request → match → schedule → run → rubric-verify → reward → notify — while keeping the
*other side of every conversation a vetted, accountable Mango representative*, which removes the
stranger-danger and harassment surface that makes Phase B hard. Treat Phase A as the proving ground for
the safety surfaces (block/report, CoC, age gate, escalation) and the verification contract. Only after
Phase A is stable, instrumented, and reviewed should Phase B be considered — and only behind its own
flag and a **separate, explicit Safety + Legal approval** (NFR-3, §10). **Phase C is not designed
here.**

### 6.2 Trust & Safety — the hard gates (read before designing anything else)
Two gates are **non-negotiable** and **block ship**:

**G-1 — Minors are excluded from sessions with people they don't already know.** *Strangers + minors is
a hard line.* The 2024 DOJ/FTC enforcement against a major platform turned in part on **letting minors
interact with adults** (§12); a feature that books human↔human contact must **not** put a minor in a
session with someone they don't know — **at all, by absence of the feature, not by a toggle.** Enforce
at three layers:
1. **Eligibility (server, fail-closed):** `POST /v1/sessions/request` and the match path **reject** any
   caller who is not a **confirmed adult** (age-eligible flag true). No age signal → **not eligible**.
2. **UI (client):** the entire session feature is **not surfaced** to ineligible users — no entry
   point, no card, no "coming soon for you" — it is simply **absent**.
3. **Matching:** the matcher **never** pairs across an age boundary; Phase B pairs **adult↔adult** only.

The age signal is owned by **`0031`** (neutral DOB age gate; *"under-13 → block monetization/social/
push or parental consent … Needs counsel"*). For **this feature** the relevant boundary is **18**, not
13, because the harm is *contact*, not data: **no under-18 in a stranger/peer session, period.** Until
`0031` lands, this spec's **minimum gate** (a hard blocker for ship) is: a **neutral DOB / age-band
check** captured once before any session use, stored as an **age-eligibility flag**, **fail-closed**,
re-validated server-side on every request, and **no parental-consent bypass** that would admit an
under-18 into a peer/stranger session. *(A possible future "minor ↔ vetted-facilitator-only, recorded,
parental-consent, no-peer-ever" interview mode is noted as **explicitly out of scope** and requires its
own Legal/Safety spec; the default and the only thing shipped here is **exclusion**.)*

**G-2 — No offline / in-person meetups.** Phase C is **deferred and out of scope.** Designing an app
that **arranges in-person meetings between users** raises **duty-of-care and liability** exposure that
online sessions do not (physical-safety harm; the Section 230 immunity that covers *online* conduct is
weaker/uncertain once the platform actively *arranges offline* contact and there is no signed
participant waiver — and **guests/minors can't meaningfully waive**; §12 Meetup posture). Therefore:
**we design online-only**, we **state in the ToS that Mango does not arrange in-person meetings**, and
**any** future offline capability needs a **standalone Legal + Safety spec** with insurance, a
participant **waiver**, venue/safety guidance, and an **absolute exclusion of minors** before a single
line is written. **Nothing offline ships from `0043`.**

Supporting T&S controls (detailed in §6.6): identity/eligibility, **in-app-first** comms, **block &
report** (reuse `0021`), a **moderation/escalation queue** (`0034`), **facilitator vetting** (FR-10), a
**code of conduct** gate (FR-12), **recording consent** (FR-8), **no-show** handling (FR-4), and
**minimal data + retention** (FR-13).

### 6.3 The `peer_session` activity + the `human` grading handoff (filling the `0039` stub)
`backend/src/shared/human.py` (new) implements the `human` method `0039` stubs out:
```python
# backend/src/shared/human.py  — implements 0039's `human` grading branch
def pending(activity: dict, submission: dict) -> dict:
    """0039 §6.5 handoff. Submitting a peer_session does NOT grade it; it opens a SESSION
    and parks the activity in `grading`. Returns the 0039 pending envelope."""
    create_or_attach_session(activity, submission)        # §6.4 state machine: → requested
    return {"score": 0, "xpAwarded": 0, "feedback": "", "passed": None, "pending": True}

def verify(session: dict, outcome: dict) -> dict:
    """Called when a human (facilitator) or mutual-confirmation+spotcheck produces a result.
    Emits the 0039 gradeReturned signal so the activity proceeds graded(passed|failed)→rewarded.
    Idempotent on (activityId, sessionId): re-verify returns the stored outcome (award once)."""
    score_bp = int(outcome["scoreBp"])                    # basis points 0..10000 (float-free)
    passed   = score_bp >= int(session["passThresholdBp"])
    xp       = session["xp"] if passed else 0             # human method: full xp on pass (0039 §6.4)
    record_outcome(session, score_bp, xp, passed, outcome.get("feedback", ""))
    if passed:
        award_xp_and_credits_once(session, xp)            # 0039 rewarded + 0023 earn (idempotent)
    return {"score": score_bp / 10000.0, "xpAwarded": xp, "feedback": outcome.get("feedback",""),
            "passed": passed, "pending": False}
```
The activity's lifecycle is **unchanged** from `0039` §6.3: `submit` → (`human.pending`) → `grading`
(parked) → **`verify`** emits `gradeReturned` → `graded(passed|failed)` → `awardGranted` → `rewarded`.
A session that never completes (no-show / abandoned) lets the activity **`expire`** (`0039` terminal),
awarding nothing.

### 6.4 Session matching + scheduling state machine (pure, unit-testable)
A pure reducer (the `0039 ActivityLifecycle` / `LevelCurve` pattern), with a byte-identical Python twin
(`backend/src/shared/session_state.py`) so server transitions are `pytest`-tested. **No** SwiftData/
network in the pure core.

States: `requested → offered → scheduled → in_progress → awaiting_verification → verified` (terminal),
plus terminals `declined`, `cancelled`, `no_show`, `expired`.

Events: `offerToCounterparty`, `accept`, `decline`, `schedule(slot)`, `reschedule(slot)`,
`markPresent(party)` (both → `in_progress`), `markComplete(party)` (both, or facilitator → `awaiting_
verification`), `verifyResult(scoreBp, thr)`, `cancel`, `noShowTimeout`, `expireTimeout`.

```swift
// ios/Mango/Services/Sessions/SessionStateMachine.swift — Foundation only, pure, unit-tested
enum SessionState: String, Codable {
    case requested, offered, scheduled, inProgress = "in_progress",
         awaitingVerification = "awaiting_verification", verified,
         declined, cancelled, noShow = "no_show", expired
}
enum SessionEvent: Equatable {
    case offer, accept, decline
    case schedule(slotEpoch: Int), reschedule(slotEpoch: Int)
    case markPresent(both: Bool), markComplete(both: Bool)   // facilitator-side `both` is implicit true
    case verifyResult(scoreBp: Int, thresholdBp: Int)
    case cancel, noShowTimeout, expireTimeout
}
enum SessionMachine {
    static func apply(_ e: SessionEvent, to s: SessionState) -> SessionState {
        switch (s, e) {
        case (.requested, .offer):                         return .offered
        case (.offered, .accept):                          return .scheduled   // accept implies a slot (FR-4)
        case (.offered, .decline):                         return .declined
        case (.scheduled, .reschedule):                    return .scheduled
        case (.scheduled, .markPresent(true)):             return .inProgress
        case (.inProgress, .markComplete(true)):           return .awaitingVerification
        case (.awaitingVerification, let .verifyResult(score, thr)):
            return score >= thr ? .verified : .awaitingVerification  // fail → stays; may re-verify/expire
        case (.scheduled, .noShowTimeout):                 return .noShow
        case (.inProgress, .noShowTimeout):                return .noShow
        case (_, .cancel) where !isTerminal(s):            return .cancelled
        case (_, .expireTimeout) where !isTerminal(s):     return .expired
        default:                                           return s            // illegal → no-op
        }
    }
    static func isTerminal(_ s: SessionState) -> Bool {
        [.verified, .declined, .cancelled, .noShow, .expired].contains(s)
    }
}
```
**Scheduling specifics (FR-4):** availability windows are stored as **UTC epoch ranges**; the client
renders every time in the **viewer's `TimeZone.current`** (never a bare hour). The matcher intersects
both parties' windows (Phase B) or the learner's windows with the facilitator pool's open slots (Phase
A) and proposes the earliest overlap. **No-show:** a scheduled session whose window elapses without
`markPresent(both)` is moved to `no_show` by a scheduled sweep (EventBridge, like `0021`'s rollover);
the present party is told gently (`0025`), no XP is lost, and the pattern is counted for reliability/
escalation (§6.6).

### 6.5 The session channel (privacy-preserving; in-app-first) — recommendation
v1 ships **in-app text** as the default and only *required* channel: a **session-scoped, moderated
thread** (one per session, auto-closed at terminal state), surfaced inside the existing app, with
block/report inline. It is **not** a general DM surface (`0021` excludes DMs) — it exists only for the
duration of a session.

For **video** (optional, Phase A managed; Phase B behind its flag), the recommendation is a
**per-session, invite-only, end-to-end-encrypted external link** from a **reputable provider**, created
at schedule time and **revoked at terminal state**, surfaced **inside** Mango (opened in
`SFSafariViewController`/web view — **no third-party iOS SDK**, honoring zero-deps). This follows the
dating/marketplace + secure-video guidance (§12): **don't post links publicly, invite from within,
don't reuse, E2EE where possible**, and **keep comms in-app first** so users never have to exchange
personal contact details. **Recording is OFF by default** and gated by all-party consent (FR-8).
*(Decision D-3, §10: external-link-first vs a managed in-app call — recommend external-link-first to
avoid building/operating a video stack.)*

### 6.6 Trust & safety surfaces (the core)
- **Identity / eligibility.** Real, **signed-in** account only (`0019`) — **no anonymous sessions
  ever.** Handle-only to the counterpart (`0021`); email/`sub` never cross the wire. Eligibility =
  age-adult (FR-9) **and** social opted-in (`0021`) **and** CoC accepted (FR-12).
- **Block & report (reuse `0021`).** One-tap **block** (`POST /v1/friends/{handle}/block`) and
  **report** (`POST /v1/reports`) on every session surface, plus a **session-scoped report**
  (`POST /v1/sessions/{id}/report` carrying session context). Blocking **dissolves** any pairing and
  **bars future matching**; a reported/blocked counterpart is **never re-matched** (symmetric, per
  `0021`).
- **Moderation / escalation queue (`0034`).** Reports, repeat no-shows, and safety flags land in a
  **queue** an admin/T&S reviewer works (warn / suspend / ban a user; **remove a facilitator
  instantly**; quarantine a session). Until `0034` ships, the **minimum** is a `REPORT#`/`SAFETYFLAG#`
  DDB write + an internal-only Lambda (`GET` the queue, `POST` an action) behind staff auth — *the
  feature does not ship without somewhere for a report to go.*
- **Facilitator vetting (FR-10).** Identity-verified, **background-checked to Legal's standard**,
  trained on rubric + CoC + safeguarding, under a facilitator agreement, **instantly revocable**;
  managed via `0034`/interim `FACILITATOR#` items; facilitators see only handle + objective + rubric.
- **Code of conduct (FR-12).** Versioned, one-time acceptance gate before requesting/accepting any
  session (reuse `0021` pattern); re-prompt on version bump.
- **Recording consent (FR-8).** All-party consent before any recording; persistent indicator; any party
  can stop; short retention; `users/<sub>/` storage; deleted on erase.
- **Rate / abuse caps.** Per-user caps on **session requests**, **reschedules**, and **reports**
  (anti-spam, anti-harassment), mirroring `0021`'s anomaly caps; flagged users are shadow-paused from
  matching pending review.

### 6.7 Liability / ToS posture (Legal-owned; conservative by default)
- **Online-only, no in-person.** The ToS/feature copy states **Mango facilitates online learning
  sessions and does not arrange or supervise in-person meetings**; users are told to keep contact
  **in-app**. (Phase C would change this and needs its own review — §6.2 G-2.)
- **Participant agreement / release.** Following the marketplace lesson (§12: a platform's ToS is
  between the platform and each member, and **direct participant releases** are prudent for any
  higher-risk interaction), **Phase B** requires each participant to accept a **session participant
  agreement** (a release + the CoC) **before** matching. **Facilitators** sign a separate **facilitator
  agreement** (FR-10).
- **Section 230 framing.** For **online** user-to-user conduct, platforms are generally not liable
  (Meetup's posture, §12), but this spec does **not** rely on that as a substitute for the controls
  above — it **layers** identity, consent, vetting, reporting, and minor-exclusion on top, and **avoids
  the offline activity** where the immunity is least certain.
- **Crisis / not-advice posture.** Reuse the standing **not-medical-advice + crisis** disclaimer
  pipeline proposed in AI-safety (`0030`/G2): self-help discussions can surface distress; facilitators
  are trained to **disengage and signpost**, never counsel. (Coordinate with `0030` when it lands.)
- **Sign-off.** Phase B, recording, the age gate, and the facilitator background-check standard are
  **blocked on explicit Legal + Safety sign-off** (NFR-3, §10).

### 6.8 API / contract (OpenAPI, additive — keep `openapi.yaml` ⇄ `DTOs.swift` ⇄ handlers in lockstep)
All routes are **JWT-authorized** (Cognito; `response.user_id` → `USER#<sub>`); every mutating route
re-checks **eligibility** (age-adult fail-closed, CoC accepted) server-side.
```yaml
paths:
  /v1/sessions/request:
    post:   # FR-2.1 / FR-3 — open a session request for a peer_session activity
      summary: Request a facilitator (Phase A) or peer (Phase B) session
      requestBody: { required: true, content: { application/json: { schema: { $ref: "#/components/schemas/SessionRequest" } } } }
      responses:
        "201": { description: Session created (state=requested/offered), content: { application/json: { schema: { $ref: "#/components/schemas/Session" } } } }
        "403": { description: Ineligible (not an adult / CoC not accepted / feature disabled) }   # FR-9 fail-closed
  /v1/sessions/{id}/respond:
    post:   # accept | decline | reschedule  (counterpart or facilitator)
      summary: Accept, decline, or propose a new slot
      parameters: [{ name: id, in: path, required: true, schema: { type: string } }]
      requestBody: { required: true, content: { application/json: { schema: { $ref: "#/components/schemas/SessionRespond" } } } }
      responses: { "200": { description: Updated session, content: { application/json: { schema: { $ref: "#/components/schemas/Session" } } } } }
  /v1/sessions/{id}/schedule:
    post:   # FR-4 — confirm a slot (UTC); client renders local
      summary: Confirm a mutually-available slot
      parameters: [{ name: id, in: path, required: true, schema: { type: string } }]
      requestBody: { required: true, content: { application/json: { schema: { $ref: "#/components/schemas/SessionSchedule" } } } }
      responses: { "200": { description: Scheduled session, content: { application/json: { schema: { $ref: "#/components/schemas/Session" } } } } }
  /v1/sessions/{id}/complete:
    post:   # FR-2.3/FR-3.4 — facilitator submits rubric (Phase A) OR a party confirms (Phase B)
      summary: Submit the facilitator rubric result or a participant completion confirmation
      parameters: [{ name: id, in: path, required: true, schema: { type: string } }]
      requestBody: { required: true, content: { application/json: { schema: { $ref: "#/components/schemas/SessionComplete" } } } }
      responses:
        "200": { description: Outcome (verified or awaiting), content: { application/json: { schema: { $ref: "#/components/schemas/GradeOutcome" } } } }  # reuse 0039 GradeOutcome
        "403": { description: Caller not a participant / not a vetted facilitator }
  /v1/sessions/{id}/report:
    post:   # FR-11 — session-scoped report → moderation queue (0034)
      summary: Report a safety/conduct issue in this session
      parameters: [{ name: id, in: path, required: true, schema: { type: string } }]
      requestBody: { required: true, content: { application/json: { schema: { $ref: "#/components/schemas/SessionReport" } } } }
      responses: { "202": { description: Reported; queued for review } }
  /v1/sessions/mine:
    get: { summary: List the caller's sessions (states, slots, outcomes), responses: { "200": { description: Sessions } } }
components:
  schemas:
    SessionRequest:
      type: object
      required: [activityId, kind, availability]
      properties:
        activityId:   { type: string }
        kind:         { type: string, enum: [facilitator, peer] }   # peer gated by flag + sign-off
        objectiveRef: { type: string, nullable: true }
        counterpartHandle: { type: string, nullable: true }         # peer: a friend/buddy handle (FR-3.1)
        availability: { type: array, items: { $ref: "#/components/schemas/AvailabilityWindow" } }
    AvailabilityWindow:
      type: object
      required: [startEpoch, endEpoch]
      properties: { startEpoch: { type: integer }, endEpoch: { type: integer } }   # UTC epoch ints (float-free)
    SessionRespond:
      type: object
      required: [action]
      properties:
        action:    { type: string, enum: [accept, decline, reschedule] }
        slotEpoch: { type: integer, nullable: true }                # required for accept/reschedule
    SessionSchedule:
      type: object
      required: [slotEpoch, durationMin]
      properties: { slotEpoch: { type: integer }, durationMin: { type: integer } }
    SessionComplete:
      type: object
      properties:
        role:        { type: string, enum: [facilitator, participant] }
        scoreBp:     { type: integer, nullable: true }              # facilitator rubric score 0..10000
        passed:      { type: boolean, nullable: true }              # facilitator verdict
        feedback:    { type: string,  nullable: true }
        confirmed:   { type: boolean, nullable: true }              # participant "we completed this"
        rubricResult: { $ref: "#/components/schemas/RubricResult" } # structured viva criteria (FR-7)
        recordingConsent: { type: boolean, nullable: true }         # FR-8 all-party; default false
    RubricResult:
      type: object
      properties:
        criteria: { type: array, items: { type: object,
                    properties: { id: { type: string }, scoreBp: { type: integer }, note: { type: string } } } }
    SessionReport:
      type: object
      required: [reason]
      properties: { reason: { type: string }, detail: { type: string, nullable: true } }
    Session:                       # client projection (handle-only; no email/sub)
      type: object
      required: [id, kind, state]
      properties:
        id:    { type: string }
        kind:  { type: string, enum: [facilitator, peer] }
        state: { type: string, enum: [requested, offered, scheduled, in_progress, awaiting_verification, verified, declined, cancelled, no_show, expired] }
        activityId:        { type: string }
        counterpartHandle: { type: string, nullable: true }
        slotEpoch:         { type: integer, nullable: true }
        durationMin:       { type: integer, nullable: true }
        videoJoinUrl:      { type: string,  nullable: true }   # per-session, invite-only (FR-6); null until scheduled
        outcome:           { $ref: "#/components/schemas/GradeOutcome" }   # 0039 outcome; null until verified
```
`DTOs.swift` gains `SessionDTO`, `SessionRequestDTO`, `SessionRespondDTO`, `SessionScheduleDTO`,
`SessionCompleteDTO`, `RubricResultDTO`, `SessionReportDTO`, `AvailabilityWindowDTO` (lenient decode;
unknown enum → safe fallback, mirroring `CatalogBook`/`Exercise`). `GradeOutcome` is **reused** from
`0039` (no new outcome shape).

### 6.9 Data — DynamoDB items (single-table, float-free) & S3 artifacts
Single table, `PK`/`SK` + `GSI1`; numeric attrs **`int`** only (scores in basis points, times as epoch
`int` or ISO string). Coordinated with `0026` (tracking) / `0027` (artifacts).
```
# Session record (one per session; both parties get a pointer row for "my sessions")
PK = SESSION#<sessionId>        SK = META
  attrs: kind (S facilitator|peer), state (S), activityId (S), objectiveRef (S),
         learnerSub (S), counterpartSub (S, opt: facilitatorSub or peerSub),
         slotEpoch (N int, opt), durationMin (N int, opt), passThresholdBp (N int),
         scoreBp (N int, opt), passed (BOOL, opt), xpAwarded (N int, opt),
         createdAt (S iso), updatedAt (S iso), recordingKey (S→S3, opt, consented only)
PK = USER#<sub>                 SK = SESSION#<sessionId>     # per-user pointer (fast "my sessions")
  attrs: role (S learner|facilitator|peer), state (S), slotEpoch (N int, opt), updatedAt (S iso)
  GSI1 (optional): GSI1PK = USER#<sub>  GSI1SK = SESSTATE#<state>#<slotEpoch>   # "my upcoming/awaiting"

# Facilitator pool (managed via 0034 / interim internal Lambda)
PK = FACILITATOR#<sub>          SK = META
  attrs: status (S active|suspended|removed), vettedAt (S iso), bgCheck (S ref/none),
         trainedAt (S iso), agreementVersion (S), updatedAt (S iso)
PK = FACILITATOR#OPEN           SK = SLOT#<startEpoch>#<sub>   # open facilitator availability (Phase A matching)

# Reports & safety flags (reuse 0021 REPORT#; add session context + a safety-flag queue for 0034)
PK = REPORT#<reportId>          SK = META
  attrs: reporterSub (S), targetHandle (S), sessionId (S, opt), reason (S), detail (S, opt), at (S iso), status (S open|actioned)
PK = SAFETYFLAG#<flagId>        SK = META
  attrs: subjectSub (S), kind (S no_show|abuse_suspected|report), sessionId (S, opt), at (S iso), status (S)

# Recording consent (audit trail; FR-8) — all-party consent recorded before any recording
PK = SESSION#<sessionId>        SK = CONSENT#<sub>           # { consented: BOOL, at: iso }
```
**S3 (only if a recording is consented):**
```
s3://<product-bucket>/users/<sub>/sessions/<sessionId>/<artifactId>.<ext>   # consented recording only
```
under the existing `users/<sub>/` convention that `DELETE /v1/me` already purges. Uploaded via a
**pre-signed PUT** (Lambda never proxies media); least-privilege `s3:PutObject`/`GetObject` scoped to
`users/<sub>/sessions/*`. **Float-free:** scores are basis-point `int`s; times are epoch `int`/ISO
strings; the wire `number` (0..1 / local datetime) is converted at the edge (the `progress.py`
pattern).

### 6.10 iOS — screens, state, services (zero deps, DesignSystem tokens)
New feature module `ios/Mango/Features/Sessions/` (Xcode-16 sync — no `project.pbxproj` edits):
- **`SessionEntryGate`** — resolves eligibility (`0031` age-adult + `0021` opt-in + CoC). If
  **ineligible, renders nothing** (the feature is **absent** — G-1); else shows the entry point.
- **`SessionRequestView`** — pick **availability windows** (rendered in `TimeZone.current`), choose
  Phase A (facilitator) or, if enabled + a friend/buddy is chosen, Phase B (peer); accept the **CoC**
  if not yet accepted.
- **`SessionDetailView`** — state-driven (requested/offered/scheduled/awaiting/verified): shows the
  slot **in local time**, the **session-scoped thread** (in-app-first), the **video join button**
  (per-session link, opens in `SFSafariViewController`), and **Block / Report** inline on every state.
- **`FacilitatorRubricView`** *(facilitator build/role)* — the structured-viva form (objective-aligned
  questions + scored criteria incl. the mandatory negative criterion); submits via `/complete`.
- **`SessionsListView`** — "my sessions" (upcoming / awaiting / done) from `/v1/sessions/mine`.
- **`SessionRenderer`** — the `0039` `ActivityRenderer` for `kind == .peer_session`: a card that
  explains the session, launches `SessionRequestView`, and reflects lifecycle (`grading` = "awaiting
  your session"); **registered at app start** per `0039` §6.8. **Never** in the offline sample
  (NFR-6).
- **`SessionService`** (`@Observable`, in `AppModel`) — wraps the endpoints; **gated** on
  `AuthService.isSignedIn` + age-eligibility + `0021` opt-in; a friendly no-op offline ("connect to
  book a session"); schedules `0025` reminders. All spacing/type/color from `Metrics`/`Typo`/`Palette`;
  every control VoiceOver-labelled with a non-gesture path; reminder/no-show copy is calm and
  non-coercive (`0021` tone).

Routes: new `Route` cases (`.sessionRequest(activityId:)`, `.sessionDetail(id:)`, `.sessionsList`)
applied via `.mangoDestinations()`. Settings/Profile gain a **"Sessions"** entry only when eligible.

### 6.11 Diagrams
```
peer_session (0039)        this spec (0043)
─────────────────         ────────────────
Activity{kind:peer_session, gradingMethod:human}
  submit ─▶ human.pending() ─▶ activity parked in `grading`  ──┐ opens a SESSION:
                                                               ▼
  requested ─offer▶ offered ─accept▶ scheduled ─present(both)▶ in_progress
       │                │                  │                        │
       │             decline            reschedule              complete(both / facilitator)
       ▼                ▼                  ▼                        ▼
   (cancel/expire)   declined          scheduled            awaiting_verification
                                                                   │ verifyResult(scoreBp,thr)
                                                                   ▼
                                                       verified ─▶ human.verify() ─▶ 0039 gradeReturned
                                                                                    ─▶ graded(passed) ─▶ rewarded
                                                                                       (+0023 credit earn, once)
   no_show ◀─ noShowTimeout (scheduled/in_progress)     [no XP lost; reliability flag → 0034]

safety (all phases):  age-adult gate (fail-closed, 0031) ── ineligible ⇒ feature ABSENT
                      block/report (0021) on every screen ── report/no-show ⇒ queue (0034)
                      in-app-first comms; per-session invite-only video; recording OFF unless all-party consent
gates:  G-1 minors excluded from stranger/peer sessions (hard)   G-2 NO offline (Phase C out of scope)
```

## 7. Acceptance criteria
- [ ] **AC-1 (`human` handoff wired).** Submitting a `peer_session` activity calls `human.pending`,
      returns the `0039` pending envelope (`passed=null, pending=true`), and leaves the activity in
      `grading`; a later `human.verify` emits `gradeReturned` and the activity reaches
      `graded(passed)`→`rewarded`. *(pytest on `human.py` + the `0039` lifecycle twin.)*
- [ ] **AC-2 (Phase A end-to-end).** A request → facilitator offer/accept → schedule → present(both) →
      facilitator rubric `/complete` (pass) → reward granted **once**; the learner sees "verified".
      *(pytest with moto seeding the session + facilitator items; the award-once assertion is headline.)*
- [ ] **AC-3 (session state machine).** `SessionMachine.apply` matches the §6.4 table for **every**
      (state × event), including illegal no-ops, no-show timeouts from `scheduled`/`in_progress`, and
      terminal finality. *(Pure `SessionStateMachineTests` + the `session_state.py` twin in pytest.)*
- [ ] **AC-4 (age-gate exclusion — HARD).** A caller who is not a confirmed adult (or has no age
      signal) gets **403** from `/v1/sessions/request` and the **client surfaces no session entry
      point** for them; the matcher never pairs across an age boundary. *(pytest fail-closed on the
      eligibility check + an iOS view test that the gate renders nothing; this is a release-blocking
      test.)*
- [ ] **AC-5 (report / block flow).** `POST /v1/sessions/{id}/report` writes a `REPORT#`/`SAFETYFLAG#`
      item to the moderation queue; blocking a counterpart (`0021`) **dissolves** the pairing and the
      pair is **never re-matched**. *(pytest on the report write + a matcher test that a blocked pair is
      excluded.)*
- [ ] **AC-6 (scheduling + time zones + no-show).** Availability is stored UTC and **rendered in the
      viewer's local zone**; the matcher proposes the earliest overlap; an elapsed scheduled window
      with no `present(both)` → `no_show`, the other party is notified gently, and **no XP is lost**.
      *(pytest on the matcher + no-show sweep; iOS test on local-time rendering.)*
- [ ] **AC-7 (mutual confirmation + spot-check, Phase B).** With `peerSessionsPeerEnabled` on, reward
      requires **both** participants' confirmation; a `spotCheckRate` fraction is routed to review
      **before** reward; reward is granted **once** per participant on a verified pass. *(pytest on the
      dual-confirm + sampling path.)*
- [ ] **AC-8 (facilitator vetting enforced).** `/complete` with a facilitator verdict is **rejected**
      unless the caller is an **active** `FACILITATOR#` (status=active); a suspended/removed facilitator
      cannot verify. *(pytest on the facilitator-status check.)*
- [ ] **AC-9 (recording consent — all-party).** No recording artifact can be created without a
      **`CONSENT#<sub>` row for every participant**; absent any consent, no S3 key is written and the
      "recording" path is disabled. *(pytest that the recording write is blocked without all-party
      consent.)*
- [ ] **AC-10 (code-of-conduct gate).** Requesting/accepting a session requires a current-version CoC
      acceptance; a missing/stale acceptance forces the gate. *(pytest + iOS gate test.)*
- [ ] **AC-11 (no offline surface).** There is **no** endpoint, field, or screen that arranges an
      in-person meeting; the ToS copy states sessions are online-only. *(Code/grep + a contract check
      that no `location`/`address`/`inPerson` field exists.)*
- [ ] **AC-12 (erase cascades).** `DELETE /v1/me` removes the user's `SESSION#` pointers, dissolves
      pairings, removes their `FACILITATOR#`/consent rows, and deletes `users/<sub>/sessions/*` in S3.
      *(pytest of the delete cascade — extends `0021`/`0004`.)*
- [ ] **AC-13 (offline / contract / float-free).** `peer_session` never appears in the offline sample
      and renders a "connect to book" state with no network; `openapi.yaml` ⇄ `DTOs.swift` ⇄ handlers
      agree; all DDB numerics are `int` (basis points / epoch); `cdk synth -c stage=beta` + `pytest`
      pass offline; a grep finds no Python `float` in the new handlers. *(synth + pytest + grep.)*
- [ ] **AC-14 (sign-off gates honored).** Phase B, recording, and the facilitator background-check
      standard are behind flags that **cannot** be enabled in prod config without the documented Legal +
      Safety sign-off recorded in §10. *(Process/config check + flag-default test: peer + recording
      default **off**.)*

## 8. Test plan
- **Unit — Swift (pure, primary; `LevelCurveTests`/`ActivityDeckTests` style):**
  `SessionStateMachineTests` (exhaustive state×event incl. no-show/terminal no-ops, → AC-3);
  `SessionTimeZoneTests` (UTC store → `TimeZone.current` render, no bare hours, → AC-6);
  `SessionEligibilityGateTests` (ineligible ⇒ renders nothing, → AC-4); `SessionDTOTests` (round-trip +
  lenient decode of unknown enums, → AC-13).
- **Unit — Python (`pytest`, moto + monkeypatched Bedrock, offline):**
  `test_human_grading.py` (`pending`→parked, `verify`→`gradeReturned`, idempotent award-once, → AC-1/
  AC-2); `test_session_state.py` (Python twin matches the Swift table, → AC-3);
  `test_session_eligibility.py` (fail-closed 403 without adult age signal, → AC-4);
  `test_session_match.py` (earliest-overlap matcher; **blocked pair excluded**; no cross-age pairing,
  → AC-5/AC-6); `test_session_noshow.py` (sweep → `no_show`, no XP loss, → AC-6);
  `test_session_peer.py` (dual-confirm + spot-check sampling, → AC-7);
  `test_facilitator_gate.py` (only active facilitators verify, → AC-8);
  `test_recording_consent.py` (no all-party consent ⇒ no recording, → AC-9);
  `test_session_coc.py` (CoC gate, → AC-10); `test_session_delete_cascade.py` (erase, → AC-12);
  `test_no_offline_fields.py` (no `location`/`inPerson` in the contract, → AC-11).
- **Integration / contract:** `cdk synth -c stage=beta` passes; an openapi-lint/diff that the new
  schemas match `DTOs.swift`; a conformance test that `human.verify` satisfies the `0039` `GradeOutcome`
  shape (so the framework stays green); flag-default test (peer + recording **off**, → AC-14).
- **iOS UI (manual):** Phase A request → (test) facilitator → schedule → rubric → verified; the entry
  gate renders nothing for an ineligible test account; block/report reachable on every session screen;
  reminders fire (`0025`); VoiceOver labels + non-gesture paths; Reduce-Motion; **confirm `peer_session`
  is absent from the offline sample**.
- **Safety / red-team (manual, with Safety reviewer):** attempt to (a) book as a minor/unknown-age
  account (must be impossible), (b) reach a counterpart's email/real identity (must be impossible),
  (c) get matched with a blocked user (must be impossible), (d) start a recording without all-party
  consent (must be impossible), (e) verify as a non-/suspended facilitator (must be impossible), (f)
  find any offline-meeting path (must not exist). Each maps to an AC and **must pass before Phase B or
  recording is enabled.**

## 9. Rollout & migration
- **Flags (default off):** `facilitatorSessionsEnabled` (Phase A) → `peerSessionsPeerEnabled` (Phase B,
  **gated on Safety+Legal sign-off**) → `sessionRecordingEnabled` (**gated on Legal sign-off of the
  consent flow**). Phase C has **no flag** (not built). All default **off**; enable on Beta per phase,
  soak, then Prod **only after** the §10 sign-offs are recorded.
- **Hard dependencies before any prod enablement:**
  1. **`0019` sign-in shipped** (no anonymous sessions; the whole feature requires a real account).
  2. **An age signal** — `0031` (preferred) **or** this spec's minimum neutral DOB gate (§6.2 G-1).
     **Without it, the feature cannot ship** (the matcher would fail-closed and surface nothing — by
     design).
  3. **A moderation queue** — `0034` (preferred) **or** the interim internal Lambda + `SAFETYFLAG#`
     queue (§6.6). **Without somewhere for a report to go, the feature does not ship.**
  4. **`0039` landed** (the `peer_session` kind + `human` handoff this fills).
- **Phase A first (the recommendation).** Ship facilitator sessions on Beta to a **tiny internal
  facilitator pool**, soak the full machine + safety surfaces, then a limited Prod cohort. Only after
  Phase A is stable + reviewed do we consider **Phase B** (its own sign-off). **`sessionRecordingEnabled`
  stays off** until Legal signs the consent flow; v1 of both phases can run **recording-free** (rubric +
  mutual confirmation only).
- **Backfill:** none — sessions/facilitator/consent items start empty; existing users opt in fresh
  (and must pass the age + CoC gates). `peer_session` activities only appear once `0038` composes them
  into a track; until then there are no `peer_session` activities to book.
- **Backward-compat / teardown:** all routes/items are additive (new `SESSION#`/`FACILITATOR#`/
  `SAFETYFLAG#`/`CONSENT#` SKs); the existing `Activity`/`Exercise` flow is untouched. Disabling a flag
  hides its UI and stops its writes; `DELETE /v1/me` sweeps all session items (AC-12). If a serious
  safety issue arises, the flags are **kill-switches** (coordinate with remote config `0035` when it
  lands) that immediately stop new matching.

## 10. Risks & open decisions
**Severity:** 🔴 release-blocking (needs Legal/Safety) · 🟠 high · 🟡 medium.

- **🔴 G-1 — Minors in sessions with people they don't know.** *The gravest risk.* *Mitigation:* the
  **hard age gate** (§6.2): exclude all under-18 from facilitator-/peer-/stranger sessions at
  eligibility (fail-closed) **and** by making the feature **absent** in the UI; matcher never crosses an
  age boundary; **no parental-consent bypass** in scope. **Blocks ship until an age signal exists**
  (`0031` or the §6.2 minimum). **Requires Safety + Legal sign-off and counsel** (`0031` "Needs
  counsel"). *No minor-facing variant ships from this spec.*
- **🔴 G-2 — Liability for app-arranged in-person meetings.** *Mitigation:* **do not build offline**
  (Phase C out of scope, §6.2); ToS states **online-only, Mango does not arrange in-person meetings**;
  any future offline capability needs a **standalone Legal+Safety spec** (insurance, participant
  **waiver**, venue/safety guidance, **absolute minor exclusion**) — and online's Section 230 posture is
  **not** relied on as a substitute for controls (§6.7, §12). **Legal sign-off** on the online-only ToS
  posture required.
- **🔴 G-3 — Harassment / abuse / grooming between users (Phase B).** *Mitigation:* opt-in adults only,
  **friend/buddy-first** matching (not cold strangers), **in-app-first** comms, **block & report** on
  every surface (`0021`), a **moderation/escalation queue** (`0034`), rate/abuse caps, shadow-pause on
  flag, and **mutual-consent before any channel opens**. **Phase B is blocked on explicit Safety+Legal
  sign-off** and ships **after** Phase A. *(Dating/marketplace T&S playbook, §12.)*
- **🔴 G-4 — Recording / privacy law (all-party consent).** *Mitigation:* **recording OFF by default**;
  if ever enabled, **all-party consent** captured + logged (`CONSENT#` rows) before recording, a
  persistent indicator, any-party stop, `users/<sub>/` storage, short retention, erase on delete (FR-8,
  §12 two-party-consent law). **`sessionRecordingEnabled` blocked on Legal sign-off** of the flow.
- **🔴 G-5 — Facilitator vetting failure.** A bad-actor facilitator interviewing learners 1:1.
  *Mitigation:* identity verification + **background check to Legal's standard** + training + agreement
  + **instant revocation**; facilitators see handle-only; sessions can be recorded **only** with
  all-party consent for QA. **The background-check standard requires Legal sign-off** (FR-10).
- **🟠 R-6 — Collusion / reward-farming (Phase B).** Two users "confirm" without doing the work.
  *Mitigation:* `spotCheckRate` human review **before** reward, anomaly caps, and the reward is **XP/
  credits, not cash** (`0023`); like `0039` §10 R-4, the social cost is low and stricter checks gate
  anything monetizable.
- **🟠 R-7 — No-show / reliability churn.** *Mitigation:* gentle no-show handling (no XP loss),
  reminders (`0025`), reliability signal feeding escalation; never publicly shame (`0021`).
- **🟠 R-8 — Dependency not ready (`0031`/`0034`).** *Mitigation:* this spec defines the **minimum**
  age gate and the **minimum** moderation surface as **hard blockers**; if the full specs slip, the
  interim minimums gate ship, and the feature simply **stays off** until at least the minimums exist
  (fail-closed by design).
- **🟡 R-9 — Cost/ops of facilitators & video.** *Mitigation:* tiny internal pool first; external
  invite-only video link (no stack to run); revisit scale later.
- **🟡 R-10 — Contract drift with `0039`.** *Mitigation:* **reuse** the `0039` `GradeOutcome`/lifecycle
  verbatim; a conformance test keeps `human.verify` aligned (§8).

- **Decisions needed (with recommendations — bold ones need Legal/Safety):**
  - **D-1 (recommended: ship Phase A first and alone; Phase B behind its own sign-off; Phase C never in
    this spec).** Confirm the phasing & that **Phase A is the only required deliverable**.
  - **🔴 D-2 (recommended: friends/buddies-first for Phase B; broader/opt-in-pool matching is a later,
    separately-approved sub-phase; cold-stranger matching default OFF).** Confirm the matching breadth —
    **needs Safety sign-off.**
  - **D-3 (recommended: external per-session invite-only E2EE video link, opened in-app; in-app text is
    the default/only required channel; no third-party iOS SDK).** vs building/operating a managed in-app
    call. Recommend external-link-first.
  - **🔴 D-4 (recommended: recording OFF by default; if enabled, all-party consent only; short
    retention).** Confirm the recording posture — **needs Legal sign-off** (FR-8).
  - **🔴 D-5 (recommended: the minor boundary for this feature is 18, not 13 — exclude all under-18 from
    peer/stranger sessions; no parental-consent bypass in scope).** Confirm the age boundary &
    no-bypass — **needs Legal/Safety + counsel** (ties to `0031`).
  - **🔴 D-6 (recommended: facilitator background check to Legal's specified standard; instant
    revocation; handle-only visibility).** Confirm the vetting standard — **needs Legal** (FR-10).
  - **D-7 (defer to `0034`/`0026`/`0027`):** the moderation-queue UI, the session-record retention
    windows, and consented-recording lifecycle — **shaped here, owned there**.

## 11. Tasks & estimate
1. **OpenAPI additions** for `/v1/sessions/*` + matching `DTOs.swift` (`Session*`, `RubricResult`,
   `AvailabilityWindow`; reuse `0039` `GradeOutcome`); lenient-decode tests. **(M)**
2. **Pure session state machine** (Swift `SessionMachine`) + the byte-identical `session_state.py`
   twin; exhaustive `SessionStateMachineTests` + `test_session_state.py` (→ AC-3). **(M)**
3. **`human.py`** implementing `0039`'s `human` branch (`pending`→park, `verify`→`gradeReturned`,
   idempotent award-once + `0023` earn seam); `test_human_grading.py` (→ AC-1/AC-2). **(M)**
4. **Eligibility / age gate (fail-closed)** in the session handlers + `SessionEntryGate` (renders
   nothing when ineligible); `test_session_eligibility.py` + iOS gate test (→ AC-4). **Hard blocker;
   coordinate `0031`.** **(M)**
5. **Phase A handlers**: `request` / `respond` / `schedule` / `complete` (facilitator rubric) /
   `mine`; facilitator-status check; `test_facilitator_gate.py` + Phase-A e2e pytest (→ AC-2/AC-8).
   **(L)**
6. **Matching + scheduling** (UTC store, local render, earliest-overlap, **blocked-pair exclusion**,
   no cross-age) + **no-show sweep** (EventBridge, like `0021` rollover); `test_session_match.py` +
   `test_session_noshow.py` + `SessionTimeZoneTests` (→ AC-5/AC-6). **(L)**
7. **Block / report / escalation**: `/v1/sessions/{id}/report` + `REPORT#`/`SAFETYFLAG#` writes; reuse
   `0021` block; **minimum moderation surface** (interim internal Lambda + queue read) until `0034`;
   `test_session_report` + matcher exclusion (→ AC-5). **Coordinate `0034`.** **(M)**
8. **Code-of-conduct gate** (versioned acceptance, reuse `0021`) + `test_session_coc.py` + iOS gate
   (→ AC-10). **(S)**
9. **iOS `Features/Sessions/`**: `SessionEntryGate`, `SessionRequestView`, `SessionDetailView`
   (in-app thread + per-session video button via `SFSafariViewController` + inline block/report),
   `FacilitatorRubricView`, `SessionsListView`, the `0039` `SessionRenderer` (registered at start, not
   in offline sample), `SessionService`, `Route` cases. DesignSystem tokens + a11y. **(L)**
10. **Notifications wiring** (`0025`): schedule/accept/decline/T-24h/T-1h/reschedule/no-show/verified;
    quiet-hours respected. **(M)**
11. **Recording-consent path (flag-gated, default off)**: `CONSENT#` rows, all-party check, pre-signed
    PUT to `users/<sub>/sessions/*`, short retention; `test_recording_consent.py` (→ AC-9). **Blocked
    on Legal sign-off.** **(M)**
12. **Phase B (flag-gated, default off, Safety+Legal sign-off)**: friend/buddy-first matching, mutual
    confirmation + spot-check before reward; `test_session_peer.py` (→ AC-7). **(L)**
13. **Erase cascade** (`DELETE /v1/me` removes sessions/pairings/facilitator/consent + S3) +
    `test_session_delete_cascade.py` (→ AC-12); least-privilege IAM in `api_stack.py`. **(M)**
14. **Liability/ToS + CoC + facilitator-agreement copy** with **Legal**; record the §10 sign-offs;
    `test_no_offline_fields.py` + flag-default test (peer + recording off) (→ AC-11/AC-14). **(M)**
15. **Safety red-team pass** (the §8 attempt matrix) with the **Safety** reviewer; gate Phase B /
    recording on it passing. **(M)**
16. **Docs**: update `docs/ARCHITECTURE.md` / `docs/GAMIFICATION.md` (and a safety note) describing
    sessions, the phasing, and the hard gates; `cdk synth ×stages` + `pytest` green. **(S)**

## 12. References
- **Repo (read for accuracy):** `CLAUDE.md`; `working/INDEX.md`, `working/ARCHITECTURE_REVIEW.md`
  (gaps **G4** age/COPPA→`0031`, **G10** admin/moderation→`0034`, **G2** AI-safety/disclaimers→`0030`);
  `working/0039-activity-type-framework.md` (the `peer_session` kind + `human` grading handoff
  `human.pending`, lifecycle, `GradeOutcome`, S3 `submissions/` layout, float-free basis points);
  `working/0021-social-leagues.md` (opt-in handle identity, mutual friends/buddies, **block**
  `POST /v1/friends/{handle}/block`, **report** `POST /v1/reports`→`REPORT#`, code-of-conduct gate,
  no-shaming safety posture, `DELETE /v1/me` cascade); `working/0023-payments-and-credits.md`
  (append-only **credit ledger**, idempotent earn, `admin_adjust`/bonus seam — the reward sink);
  `working/0025-notifications.md` (local + APNs reminders); `working/0040-multimodal-activities.md`
  (recorded-reflection grading that can **corroborate** a session). Backend: `backend/src/handlers/`
  (`grade_exercise`, `progress`), `backend/src/shared/response.py` (`user_id`→`USER#<sub>`),
  `backend/mango_backend/api_stack.py` (least-privilege IAM); single-table `PK`/`SK` + `GSI1`. Contract:
  `shared/api/openapi.yaml`. **Findings used:** `human` grading is a stub awaiting this spec; DDB is
  single-table float-free (coerce to `int`); S3 user content lives under `users/<sub>/` and is purged by
  `DELETE /v1/me`; `0031`/`0034` are **not yet written**, so this spec defines the **minimum** age gate
  and moderation surface as hard ship-blockers.
- **Cross-spec:** `0039` (implements its `peer_session`/`human`), `0021` (graph + block/report),
  `0023` (credit earn), `0025` (reminders), **`0031`** (age/COPPA — **hard gate**), **`0034`**
  (moderation queue / facilitator mgmt — **hard gate**), `0040` (corroborating reflection), `0026`/`0027`
  (server tracking + artifacts/observability), `0019` (sign-in — no anonymous sessions), `0030`
  (not-advice/crisis disclaimer posture), `0035` (flags/kill-switches).
- **Research (web) — trust & safety for connecting strangers (dating/marketplace lessons):**
  - Identity verification + Trust & Safety frameworks for dating platforms (verification, fraud
    detection, content moderation, reporting/blocking; balance security with UX; transparency) —
    https://www.foiwe.com/trust-safety-for-dating-platforms-protecting-users-in-the-digital-dating-era/ ·
    https://appscrip.com/blog/identity-verification-process/ ·
    https://theodda.org/whats-happening/building-trust-and-safety-through-identity-verification/
  - **Peer / cohort-based learning** efficacy (engagement/retention lifts; learners "discuss and defend
    their understanding"; accountability + peer feedback) —
    https://clo100.com/2026/02/01/cohort-based-learning-how-structured-peer-cohorts-accelerate-ld-success/ ·
    https://www.frontiersin.org/journals/education/articles/10.3389/feduc.2024.1457550/full
  - **Oral / viva (interview-based) assessment** — a *structured* viva (fixed questions + rubric +
    trained examiner) is valid, reliable, authentic for reasoning that written tests miss (grounds the
    facilitator rubric / "structured viva") —
    https://bmcmededuc.biomedcentral.com/articles/10.1186/s12909-023-04524-6 ·
    https://www.ncbi.nlm.nih.gov/pmc/articles/PMC10369684/
  - **Safeguarding minors + COPPA** — COPPA "actual knowledge" once age is collected; mixed-audience age
    gates; the strangers-vs-minors hard line (DOJ/FTC action re: minors interacting with adults);
    Feb-2026 FTC age-verification policy; KOSA/COPPA-2.0 momentum —
    https://www.ftc.gov/business-guidance/resources/complying-coppa-frequently-asked-questions ·
    https://www.ftc.gov/news-events/news/press-releases/2026/02/ftc-issues-coppa-policy-statement-incentivize-use-age-verification-technologies-protect-children ·
    https://fortune.com/2026/03/18/kosa-kids-act-app-store-accountability-act-minors-age-verification/
  - **Liability for app-arranged meetings** — platforms generally not liable for **offline** conduct
    (Section 230), but direct participant **releases/waivers** are prudent for higher-risk interaction,
    and guests/minors can't meaningfully waive (grounds the online-only + conservative-ToS posture) —
    https://help.meetup.com/hc/en-us/articles/360001674971-Meetup-and-offline-responsibility ·
    https://help.meetup.com/hc/en-us/articles/360001674951-Organizer-liability-waivers
  - **Privacy-preserving video + recording-consent law** — invite-only, don't-share-publicly, E2EE
    where possible; **all-party (two-party) consent** states require every participant's consent before
    recording (grounds FR-6/FR-8) —
    https://www.highspeedinternet.com/resources/best-video-calling-apps-privacy ·
    https://www.recordinglaw.com/party-two-party-consent-states/ ·
    https://www.justia.com/50-state-surveys/recording-phone-calls-and-conversations/
  - **Scheduling across time zones** — store/display in the viewer's local zone; never a bare hour
    (grounds FR-4) —
    https://help.calendly.com/hc/en-us/articles/14078163170071-Time-Zones-overview
