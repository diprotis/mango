# 0031 — Age assurance & COPPA/kids compliance

- **Epic:** M14 · **Status:** Draft · **Owner:** unassigned · **Updated:** 2026-06-28
- **Reviewers:** Principal / SD / QA / **Legal**

> ⚠️ **Read §10 first.** This spec gates monetization (`0023`/`0024`) and stranger-interaction
> (`0042`/`0043`) for minors. It is **engineering design, not legal advice** — the policy choices
> here (especially the **under-13 posture** and any future verifiable-parental-consent path) **must
> not ship without sign-off from qualified children's-privacy counsel.** Today Mango has **no age
> screening anywhere**; that is itself the compliance gap (it is exactly what the FTC charged in the
> Jan-2025 HoYoverse/*Genshin Impact* settlement — a gamified app with loot boxes/virtual currency,
> marketed broadly, with *no age gate*). The default posture of this spec is **maximum caution and
> fail-closed**.

## 1. Summary
Introduce **age assurance** to Mango: a **neutral date-of-birth (DOB) age gate** asked once during
onboarding, stored **server-authoritatively** on the user's profile, tamper-resistant, and used to
place every user into one of three **age bands — under-13, 13–17, 18+** — that other specs consult
through a small set of **per-feature gates**. The server is the only source of truth: the client may
*hint* the band for UX, but every gated endpoint (`0023` purchase/spend, `0024` redeem,
`0042` social/external, `0043` peer/human sessions, `0021` social) **re-derives eligibility
server-side and fails closed** when the age signal is absent or stale. The **recommended v1 policy is
block-by-default**: **under-13 users are excluded from monetization, social, peer/external, and
push-marketing entirely** (no verifiable-parental-consent path is built in v1 — collecting under-13
data with the consent machinery COPPA now requires is out of scope until counsel and product commit
to it); **13–17 users are blocked from stranger interaction (`0043`) and external/social posting
(`0042`/`0021`) and have rewards (`0024`) restricted**; **18+ users get the full feature set**. The
gate is **neutral** (asks "What's your date of birth?", never "Are you 13+?"), **data-minimizing**
(store the **age band + a coarse birth-month/year or just the derived band**, not the raw exact DOB
beyond what's needed to compute the band — D-4), and **aligned with Apple's new App Store age-rating
system** (the 13+ rating Mango will carry once monetization/social ship). Existing users are
**age-gated retroactively** via a one-time interstitial that fail-closes gated features until they
answer. New profile fields, one new endpoint pair (`GET/PUT /v1/me/age`), a shared
`ageband`/eligibility module the other specs import, and an onboarding page are added; all repo
invariants (offline-first first-run, no third-party iOS deps, Lambda stdlib+boto3, float-free DDB,
`openapi.yaml` ⇄ `DTOs.swift` ⇄ handlers in lockstep) are preserved.

## 2. Goals / Non-goals
- **Goals:**
  - A **neutral DOB age gate** (FTC-compliant: not defaulted, doesn't encourage falsification, not a
    yes/no "are you over 12" checkbox) presented **once** in onboarding (`0010`), with sensible
    **re-prompt** rules (only if unanswered / corrupted / on the retroactive backfill).
  - A **server-authoritative age signal** on the profile: derive an **age band** (`under13` /
    `teen` (13–17) / `adult` (18+)) and an **eligibility set**; persist it tamper-resistantly so a
    hacked client can't self-promote out of a restriction.
  - **Per-feature gates** other specs call: a single `ageband.eligibility(uid) -> {...}` server
    helper + a parallel `AgeGate` client helper, so `0023`/`0024`/`0042`/`0043`/`0021` each enforce
    the policy in one line and **fail closed** when the signal is missing.
  - A concrete, **counsel-reviewable policy matrix** (under-13 / 13–17 / 18+ → what each band
    unlocks), with **block-by-default** for under-13 in v1 (no VPC path built).
  - **Data minimization for minors** per the amended COPPA Rule (collect/retain the minimum; written
    retention posture; no under-13 PII collection beyond the age signal in v1).
  - **Retroactive age-gating** of existing users (a one-time gate that fail-closes gated features
    until answered) — because there are users today with **no** age on file.
  - **Apple age-rating alignment** (the app self-rates **13+** once monetization/social ship; the
    age gate + under-13 block keep us consistent with that rating and with App Store kids rules).
  - Honor invariants: **offline-first first launch is unaffected** (the bundled sample + Mock AI need
    no age gate — see Non-goals/D-7); zero iOS deps; stdlib+boto3; **float-free** (ages/bands are
    `int`/`enum` strings, never floats); contract lockstep.
- **Non-goals:**
  - **Building verifiable parental consent (VPC)** / a parent-dashboard / knowledge-based-auth /
    ID+selfie / `$0`-card flows for under-13. v1 **blocks** under-13 from the regulated surfaces
    instead of consenting them (D-1). A future VPC spec (`0031b`) is where that lives, **with
    counsel**.
  - **Hard age *verification*** (government-ID / facial-age-estimation / third-party AV vendors). v1
    is **age *assurance* by self-declared neutral DOB** — the level of assurance the FTC and the UK
    Children's Code say to match to risk; document the upgrade path (§10 R-2) but don't build it.
  - **Per-jurisdiction age-of-consent tables** (e.g. GDPR-K's 13–16 member-state spread). v1 is
    **US-first** with a single under-13 line + an 18+ line for contact features; international
    (GDPR-K / UK AADC) is **noted and designed-around** (§6.9, §10) but not fully localized.
  - **Re-implementing** monetization, rewards, social, external, or peer specs — this spec **defines
    the signal + the gates they call**; each enforcing spec wires the gate on its own endpoints.
  - **Marketing/targeting logic, geofencing, or analytics-band segmentation** beyond suppressing
    push-marketing to under-13 (the analytics lake must simply not receive under-13 PII; coordinate
    with `0015`/`0033`).
  - **Changing the offline first-run.** The first sample lesson with Mock AI stays gate-free; the age
    gate only **conditions the regulated features**, which are all network/auth-bound anyway.

## 3. Background & context
**Why now.** Mango is about to add precisely the signals that draw FTC/COPPA scrutiny: it will
**sell credits** (`0023`, StoreKit consumables — "virtual currency"), **offer redeemable rewards**
(`0024`, coupons/gift-cards and a flagged sweepstakes), and add **social/peer/external** interaction
(`0021` leagues/friends, `0042` public posting + external content, `0043` human↔human sessions).
**Today there is no age screening anywhere** — `UserProfile` (`ios/Mango/Models/UserProfile.swift`,
verified) has `name/goals/interests/readingLevelRaw/dailyGoalUnits/…` and **no DOB or age field**;
`OnboardingFlow.swift` (verified) never asks age; `backend/src/handlers/profile.py` (verified) stores
a fixed `DEFAULT_PROFILE` with **no** age attribute. That absence is the exact gap **G4** in
`working/ARCHITECTURE_REVIEW.md` §3 ("No COPPA / age-gating for a gamified app selling credits +
redeemable rewards"), and it is what the FTC charged in **HoYoverse**: *"Cognosphere did not
implement an age screening mechanism … to determine which users were under 13."*

**The regulatory landscape (researched June 2026 — cite, but defer to counsel).**
- **COPPA + the 2025 amended Rule.** COPPA governs operators that collect personal information online
  from **children under 13**. The **FTC's amended COPPA Rule** took effect **June 23, 2025**, with
  full-compliance required by **April 22, 2026** (§12). It **expands "personal information"** (now
  includes biometric identifiers, government IDs, phone numbers, and more), requires a **written data
  retention policy** ("retain only as long as reasonably necessary," no indefinite retention,
  disclosed in the privacy notice), requires a **written information-security program**, and
  tightens **verifiable parental consent** (adds knowledge-based-auth, gov-ID+facial-match, and
  text-to-parent methods; requires **separate** consent before third-party disclosure). The
  load-bearing takeaway for us: **if we knowingly collect data from under-13s we incur the full VPC +
  retention + security-program apparatus** — so v1 **avoids that by not admitting under-13s to the
  regulated, data-collecting surfaces at all** (block-by-default).
- **Neutral age gate (the mechanism).** The FTC's long-standing guidance: an age screen **must be
  neutral** — ask **"What is your date of birth?"** / "How old are you?", **not** "Are you over 13?";
  it **must not default to an age, pre-fill a date, or only offer birth-years ≥13**, and a checkbox
  "I am over 12" is **not** acceptable. Asking month+year of birth (and computing age) is the
  canonical neutral mechanism. (BBB/FTC FAQ, §12.)
- **FTC's Feb-2026 age-verification policy statement.** The FTC issued an enforcement-policy
  statement that it **will not pursue** general/mixed-audience operators who collect PI **solely to
  determine age** via age-verification tech, **provided** they (a) use the data **only** for age
  determination, (b) **don't retain it beyond what's necessary** and delete promptly, (c) vet any
  third party, (d) give clear notice, and (e) use a method **likely to produce accurate results**.
  It **also reiterates** that services **primarily directed to under-13** should **assume the
  audience is under 13** and not collect age at all. This **supports** our design (a minimal,
  single-purpose age signal with tight retention) and tells us **how** to handle the data if we ever
  move from self-declared DOB to real verification (§10 R-2).
- **FTC enforcement against gamified/loot-box apps marketed to minors.** **HoYoverse / *Genshin
  Impact* (Jan 2025, $20M)** is directly on point: a gamified app with **loot boxes + a confusing
  virtual-currency system**, **marketed to children**, with **no age gate** and **deceptive odds**.
  The settlement **requires an age-screening mechanism**, **parental consent for under-16 to engage
  with loot boxes**, and **clear odds/cost disclosure**. Mango's credits (`0023`) + surprise-reward
  mechanic (`0024` FR-9) sit adjacent to this; the under-16 line in HoYoverse is a strong signal that
  **the agency cares about teens, not just under-13s, when money + randomness are involved** — which
  is why `0024`'s rewards are **restricted for 13–17** here, and why `0024`'s surprise reward must
  stay an honest, non-purchasable, published-odds bonus (it already is — `0024` §6.4).
- **Apple age ratings / App Store kids rules.** Apple **revamped** App Store age ratings (questionnaire
  due **Jan 31, 2026**; new bands **13+/16+/18+** replace 12+/17+). Apps **rated for under-13** must
  comply with COPPA; the **Kids Category** (opt-in for 4+/9+) carries strict rules (no behavioral ads,
  no outbound links/purchases without a parental gate). Mango with IAP + social will self-rate
  **13+** (not Kids Category, not 4+/9+); our **under-13 block** keeps the app's actual behavior
  consistent with a 13+ rating and avoids the Kids-Category obligations. The age gate also satisfies
  Apple's expectation that apps **gate age-sensitive functionality**.
- **GDPR-K / UK Age-Appropriate Design Code (international, brief).** Under **UK-GDPR / the
  Children's Code**, the digital-consent age is **13 in the UK** (the EU spread is **13–16** by member
  state); services "likely to be accessed by children" must apply **15 standards** — **high-privacy
  defaults, data minimization, geolocation off by default, no nudging**, and **age assurance
  proportionate to risk** (not necessarily hard verification). Our **band model + data minimization +
  minors-default-restrictive** posture is broadly aligned; full GDPR-K localization (per-country
  consent age, parental-consent flows for EU minors) is **future work** and **counsel-gated** before
  any non-US launch (§10 R-7).

**Where the gate fits in onboarding.** `0010` (onboarding redesign) is a 4–6 page paged flow
(Welcome → How it works → Make it yours → Notifications → optional Sign-in → Finish). The age gate is
a **small, early, mandatory step** — recommended **right after Welcome / before "Make it yours"** so
the band is known before any profile/marketing capture — and it writes to the **single
`UserProfile`** (offline) and **syncs to the server** when a session exists (D-3, D-6). `0010`'s
data-driven page enum makes adding one page a one-line change; this spec slots an `ageGate` case in.

**Related specs.** Gates **`0023`** (block under-13 from purchase/spend; teen purchase per policy),
**`0024`** (block under-13; restrict 13–17 rewards; sweepstakes already US-18+/AMOE), **`0042`**
(block under-13 from external/social; restrict 13–17), **`0043`** (hard-exclude **under-18** from
stranger/peer sessions — its own §6.2 G-1 already names *this* spec as the age source), **`0021`**
(social opt-in gated by band). Consumes **`0010`** (onboarding host), **`0019`** (sign-in — the
server signal keys off the Cognito `sub`; offline pre-sign-in stores locally then backfills),
**`0033`** (deletion/export — age data is swept by `DELETE /v1/me`). Coordinates with **`0015`**
(analytics — never send under-13 PII), **`0035`** (remote config — the policy thresholds/flags can be
server-tunable).

## 4. User stories
- As a **new user**, early in onboarding I'm asked **my date of birth** in a neutral way (a real date
  picker, nothing pre-filled, no "are you 13?" shortcut), and the app simply continues — I'm never
  told which answer "unlocks" more, so I have no reason to lie.
- As an **under-13 user (or a parent setting it up for a child)**, the app **still works for
  reading + learning** (the core journey, quizzes, reflections, XP, streaks), but the **store,
  rewards, social, posting, and human sessions are simply absent** — not greyed-out teasers, just not
  there — and I'm not nudged with purchase/marketing pushes.
- As a **13–17 user**, I can use the core product **and** earn/spend credits, **but** I **cannot**
  meet strangers (`0043`), **cannot** post publicly or pull arbitrary external content (`0042`/
  `0021`'s public surfaces), and **redeemable rewards are limited** to a safe subset — and the app
  tells me *why* something is unavailable in calm, non-shaming copy.
- As an **18+ user**, I get the **full** feature set (credits, rewards, social leagues, external
  engagement, peer/facilitator sessions), subject to each feature's own opt-ins.
- As an **existing user with no age on file**, the next time I open a gated feature I'm asked my DOB
  **once** (a one-time interstitial); until I answer, gated features **fail closed** and the core app
  keeps working.
- As a **user who mistyped my DOB**, there is a **constrained correction path** (Settings → in a
  way that doesn't let me freely toggle bands to dodge restrictions — corrections are server-checked
  and rate-limited, and a self-downgrade that *removes* a restriction is treated cautiously — D-5).
- As **Mango (the business)**, the **server** decides every band and every gated action; a jailbroken
  client that flips a local flag **still gets 403** from the gated endpoints, and our logs show the
  band-decision was server-made — so the COPPA/teen protections actually hold.
- As **Legal/Compliance**, I can point to a **single policy matrix** (band → unlocked features), a
  **data-retention statement** for the age signal, and a **block-by-default** under-13 posture, and
  sign off (or direct changes) before monetization/social ship.

## 5. Requirements
### 5.1 Functional
- **FR-1 (neutral DOB gate).** Onboarding presents a **mandatory, neutral** age step: a **date
  picker** (or month+year) labeled **"What's your date of birth?"** with **no pre-filled/defaulted
  date**, **no** "Are you over 12/13?" shortcut, and **no** birth-year list that starts at "13 years
  ago." The user must enter a date to proceed past the gate. (FTC neutral-screen rule, §12.)
- **FR-2 (derive band, never store a bare "is adult" claim from the client).** From the entered DOB
  the **server** computes **age in whole years** and the **band**: `under13` (< 13), `teen`
  (13 ≤ age < 18), `adult` (≥ 18). The band is computed from a date, **not** asked directly. (Client
  may compute a provisional band for instant UX, but the **server recomputes and is authoritative**,
  FR-7.)
- **FR-3 (persist server-authoritatively + tamper-resistant).** The age signal is stored on the
  user's profile item server-side (`USER#<sub>/PROFILE` extended, or a dedicated `USER#<sub>/AGE`
  item — D-2) as: `ageBand` (enum), `ageVerifiedAt` (ts the gate was answered), `ageSource`
  (`self_declared` v1), and a **minimized** birth reference (D-4: store **birth year + month** *or*
  just the band + a recompute-safe `dobEpochDay` — **not** the exact day if the band suffices for all
  policy). The server **never trusts a client-sent band**; it accepts a **DOB** (or a recompute
  input) and derives the band itself. Optimistic-concurrency `version` like other profile writes.
- **FR-4 (three-band policy matrix — the load-bearing requirement).** The server exposes an
  **eligibility set** per user that the gated specs consult. **v1 policy (counsel to confirm, §10):**

  | Capability | `under13` | `teen` (13–17) | `adult` (18+) |
  |---|---|---|---|
  | Core read/learn/quiz/reflect, XP, streaks, daily goal | ✅ | ✅ | ✅ |
  | **Buy credits / IAP** (`0023` purchase) | ❌ **block** | ⚠️ per policy (default ❌ in v1 — D-8) | ✅ |
  | **Spend credits on generation** (`0023` spend) | ❌ (no metered backend) | ✅ | ✅ |
  | **Redeemable rewards** (`0024` coupons/gift-cards) | ❌ | ⚠️ **restricted** (no gift-cards/cash-equivalent; low-risk only — D-8) | ✅ |
  | **Sweepstakes** (`0024` Phase C) | ❌ | ❌ (already US-**18+** in `0024`) | ✅ (US-only, AMOE) |
  | **Social leagues/friends** (`0021`) | ❌ | ✅ (no external links) | ✅ |
  | **External posting / arbitrary content** (`0042`) | ❌ | ❌ **block** (no public posting; vetted-content-only or off — D-8) | ✅ |
  | **Peer/stranger & facilitator sessions** (`0043`) | ❌ | ❌ **block** (`0043` hard-excludes **under-18**) | ✅ |
  | **Push *marketing* / promotional notifications** (`0025`) | ❌ **suppress** | ✅ (transactional + learning reminders always OK) | ✅ |

  Cells marked **block** are **hard, server-enforced 403s**; the **client also hides** the surface
  (absent, not greyed) so the band is never advertised.
- **FR-5 (under-13 → block-by-default, no VPC in v1).** For `under13`, the regulated surfaces
  (purchase, spend-on-backend, rewards, social, external, peer, push-marketing) are **refused
  server-side** and **not surfaced** client-side. **No verifiable-parental-consent flow is offered**
  — meaning we **do not collect** the additional under-13 PII those features would entail, keeping us
  outside the heaviest COPPA obligations for v1. (Recommendation in §10 also contemplates **excluding
  under-13 from account creation entirely** until a VPC spec exists — D-1.)
- **FR-6 (13–17 → block stranger + external/social-posting + restrict rewards).** For `teen`:
  **`0043` is refused** (no sessions with anyone they don't already know — `0043` already requires
  **18+**), **`0042` public posting + arbitrary external content is refused** (and `0021` external
  links are off), and **`0024` rewards are restricted** to a safe subset (no gift-cards/cash-like;
  the sweepstakes is already 18+). Core learning + leagues + (per D-8) credits remain.
- **FR-7 (server authoritative; per-feature gates fail closed).** Every gated endpoint
  (`0023` purchase/spend, `0024` redeem, `0042` submit/feed/link, `0043` request/respond/schedule,
  `0021` social opt-in) **calls `ageband.require(uid, capability)`** which loads the server band and
  **raises → 403** if the band is missing/`unknown` or the capability isn't permitted. **Absent age
  signal ⇒ not eligible** (fail closed). The client mirrors this with `AgeGate` but the **server is
  the gate**; a stale/forged client at most gets a 403.
- **FR-8 (retroactive gate for existing users).** A user whose profile has **no `ageBand`** is shown
  a **one-time DOB interstitial** the first time they (a) open a gated surface, or (b) on next launch
  after this ships if a gated feature is enabled. Until answered, gated features **fail closed**; the
  **core app is unaffected**. Answering writes the band (FR-3) and unblocks per policy. (No mass
  email; in-app, lazy, fail-closed — see §9.)
- **FR-9 (re-prompt rules — minimal, non-nagging).** The gate is asked **once** and **not re-asked**
  unless: the stored signal is **absent/corrupt**, the **retroactive backfill** applies, or a
  **policy/version bump** (`ageGatePolicyVersion`) requires re-acknowledgement (rare; counsel-driven).
  Normal users see it exactly once.
- **FR-10 (correction path, abuse-resistant).** Settings offers **"Correct your date of birth"** with
  guardrails (D-5): corrections are **server-validated**, **rate-limited** (e.g. ≤ N/year), **logged**
  (old→new band, ts), and a correction that **removes** a restriction (e.g. teen→adult, or under13→
  teen) may require **re-confirmation** and is flagged for review; an account repeatedly toggling near
  a boundary is **frozen at the most-restrictive** band pending review. (We never let band be a free
  client toggle.)
- **FR-11 (data minimization for minors).** Collect/store the **minimum** to compute and enforce the
  band (D-4: band + coarse birth ref; **not** exact DOB if unnecessary). For `under13`, **no other
  PII is collected** in v1 (no email/social/handle/purchase data — those surfaces are blocked).
  Analytics events (`0015`) for under-13 carry **no PII** and **no purchase/marketing signals**.
- **FR-12 (Apple-rating consistency).** Ship behavior consistent with a **13+** App Store rating: the
  under-13 block means the app does **not** knowingly operate monetization/social for under-13s; we do
  **not** opt into the Kids Category. (The rating questionnaire + metadata are an App Store Connect
  task tracked in §11, not code.)
- **FR-13 (offline / first-run unaffected).** The **bundled sample + Mock AI first lesson** need **no**
  age gate (no regulated feature, no network, no PII). The gate is part of onboarding but the **core
  offline path completes regardless**; only the **regulated features** consult the band, and they are
  network/auth-bound anyway. (D-7 records whether the DOB step is mandatory-to-finish-onboarding or
  deferrable-until-first-gated-use — recommend **mandatory in onboarding** so the band is known early,
  with the *core* app still usable if somehow skipped.)
- **FR-14 (contract).** Add `GET /v1/me/age` (read band + flags) and `PUT /v1/me/age` (submit DOB →
  server derives + stores band) to `openapi.yaml`, mirrored in `DTOs.swift`; the enforcing specs add a
  **403 `age_restricted`** response shape to their gated endpoints (this spec defines the shared
  `AgeRestricted` schema).

### 5.2 Non-functional
- **NFR-1 (server-authoritative & fail-closed).** The band is **decided and stored by the server**;
  no gated decision trusts a client-supplied band or a cached flag. Missing/`unknown` band ⇒
  **denied**. (Mirrors `0023`/`0021` server-authoritative posture.)
- **NFR-2 (tamper-resistance).** The client cannot set its band directly; it submits a **DOB** (or
  correction input) and the **server derives**. Corrections are rate-limited/logged (FR-10). The band
  used for enforcement is **always re-read server-side** at the gated call (not passed in the
  request body).
- **NFR-3 (data minimization & retention — COPPA-amended).** Store the **least** age data that
  supports policy (D-4). Maintain a **written retention statement** for the age signal in the privacy
  notice (the amended Rule requires a retention policy disclosed in the notice). The age signal is
  **swept by `DELETE /v1/me`** (`0033`) and is **never** sent to the analytics lake as PII.
- **NFR-4 (privacy / no third-party disclosure).** The age signal is **not** disclosed to any third
  party (no ad SDKs anyway — the app has zero third-party deps). If a real **age-verification vendor**
  is ever added (future), it must satisfy the FTC Feb-2026 policy conditions (single-purpose, tight
  retention, vetted processor, clear notice) — **out of scope here**, flagged §10 R-2.
- **NFR-5 (security).** Age fields ride the existing authed profile path (Cognito JWT;
  `response.user_id`); writes are validated server-side; least-privilege IAM (the age handler gets
  table read/write on the profile/age item only). No new secrets.
- **NFR-6 (accessibility & tone).** The gate uses `Palette`/`Typo`/`Metrics`; the date control is
  VoiceOver-labeled with a **non-gesture** path; "feature unavailable for your age" copy is **calm,
  non-shaming, non-coercive** (no "upgrade your age," no dark patterns). Dynamic Type to XXL; AA
  contrast. (`0010`/`0024`/`0043` tone.)
- **NFR-7 (offline-first preserved).** Pre-sign-in, the band is computed locally and stored on the
  single `UserProfile`; on sign-in it **backfills to the server** (idempotent) and the **server band
  becomes authoritative**. The first sample lesson never blocks on it. (CLAUDE.md invariant.)
- **NFR-8 (backend style/runtime & float-free).** stdlib + boto3 only; ages are **`int`** years, band
  is an **enum string**; **no float** reaches DynamoDB; black (100) + flake8 (120); `pytest` (moto) +
  `cdk synth -c stage=beta` pass offline.
- **NFR-9 (contract lockstep & no iOS deps).** `openapi.yaml` ⇄ `DTOs.swift` ⇄ handlers in sync; new
  iOS files under `ios/Mango/` auto-register (Xcode-16 sync groups); pure SwiftUI/SwiftData — no SDKs.

## 6. Design

### 6.1 The age signal (data) — single table, float-free
Extend the user's profile state with an age signal. **Decision D-2** chooses between folding onto the
existing `PROFILE` item vs. a dedicated `AGE` item; **recommend a dedicated item** so the age write
path and IAM stay narrowly scoped and the retention/erase story is crisp.

| Entity | PK | SK | Key attributes |
|---|---|---|---|
| **Age signal** | `USER#<sub>` | `AGE` | `ageBand` (S: `under13`/`teen`/`adult`/`unknown`), `birthYear` (N int, **D-4**), `birthMonth` (N int 1–12, **D-4**), `ageSource` (S: `self_declared`), `ageVerifiedAt` (S iso), `policyVersion` (N int), `correctionCount` (N int), `version` (N int), `updatedAt` (S iso) |

- **D-4 minimization:** store **birthYear + birthMonth** (enough to recompute the band as the user
  ages across a birthday — important so a `teen` correctly becomes `adult` at 18 without re-prompting)
  but **not the day**, unless counsel wants exact-DOB for audit. The **band is recomputed server-side
  on read** from `birthYear/Month` + "now" so it's always current (a `teen` who turns 18 is treated as
  `adult` on their next gated call without any client action). Alternatively (most minimal) store
  **only `ageBand` + `ageVerifiedAt`** and accept that band transitions need a periodic recompute job
  — **recommend year+month** as the balance (D-4).
- **Float-free:** `birthYear`, `birthMonth`, `version`, `correctionCount` are `int`; band is a
  string enum. Reads coerce `Decimal`→`int` (reuse `profile.py`'s pattern).
- **Erase:** the `AGE` item is under `USER#<sub>` so the existing `DELETE /v1/me` cascade (`0033`)
  removes it; the analytics lake never receives it as PII (NFR-3).

### 6.2 Band derivation (pure, unit-tested — the `LevelCurve`/`StreakCalculator` style)
A pure function with a **byte-identical** twin on both sides (Swift `AgeBand.from(birthYear:month:asOf:)`
and Python `ageband.band_from(birth_year, birth_month, as_of)`), so the **same** rule is tested in
`MangoTests` and `pytest` and there is no client/server drift:
```python
# backend/src/shared/ageband.py  (stdlib only; pure; unit-tested)
UNDER13, TEEN, ADULT, UNKNOWN = "under13", "teen", "adult", "unknown"

def years_old(birth_year: int, birth_month: int, as_of: date) -> int:
    months = (as_of.year - birth_year) * 12 + (as_of.month - birth_month)
    return months // 12                      # whole years, birthday-month accurate enough at month granularity

def band_from(birth_year: int | None, birth_month: int | None, as_of: date) -> str:
    if not birth_year or not birth_month:
        return UNKNOWN                        # fail closed
    y = years_old(birth_year, birth_month, as_of)
    if y < 13:  return UNDER13
    if y < 18:  return TEEN
    return ADULT
```
```swift
// ios/Mango/Services/Age/AgeBand.swift  (Foundation only; pure; mirrors the Python twin)
enum AgeBand: String, Codable { case under13, teen, adult, unknown
    static func from(birthYear: Int?, month: Int?, asOf: Date = .now) -> AgeBand { /* same rule */ }
}
```
(Using **year+month** keeps the rule float-free and deterministic; day-precision is intentionally
dropped per D-4. If counsel requires day precision, both twins take a full `dobEpochDay: Int`.)

### 6.3 Eligibility / the per-feature gate (what the other specs import)
A single source of truth the enforcing specs call — **server is the gate**, client mirrors for UX:
```python
# backend/src/shared/ageband.py  (continued)
# capability -> minimum acceptable bands (v1 policy table FR-4; tunable via 0035 remote config)
POLICY: dict[str, set[str]] = {
    "iap_purchase":     {ADULT},                  # D-8: teen default-blocked in v1
    "credits_spend":    {TEEN, ADULT},
    "rewards_redeem":   {TEEN, ADULT},            # teen = restricted subset (enforced in 0024)
    "rewards_giftcard": {ADULT},                  # teen blocked from cash-equivalent
    "sweepstakes":      {ADULT},                  # 0024 already US-18+
    "social":           {TEEN, ADULT},            # 0021 leagues/friends
    "external_post":    {ADULT},                  # 0042 public posting / arbitrary content
    "peer_session":     {ADULT},                  # 0043 hard 18+ (stranger contact)
    "push_marketing":   {TEEN, ADULT},            # under13 suppressed
}

def eligibility(uid: str, *, as_of=None) -> dict:
    band = current_band(uid, as_of=as_of)         # reads AGE item, recomputes from year/month
    return {"band": band, "caps": {cap: (band in ok) for cap, ok in POLICY.items()}}

def require(uid: str, capability: str) -> None:
    """Raise AgeRestricted(403) unless the caller's CURRENT server band permits `capability`.
    Fail-closed: UNKNOWN band is in no allow-set, so it always denies."""
    band = current_band(uid)
    if band not in POLICY.get(capability, set()):
        raise AgeRestricted(capability=capability, band=band)
```
- **Each enforcing spec** adds one line at the top of its gated handler, e.g. in
  `handlers/credits.py` purchase: `ageband.require(uid, "iap_purchase")`; in `0042`'s submit:
  `ageband.require(uid, "external_post")`; in `0043`'s request: `ageband.require(uid, "peer_session")`.
  The handler maps `AgeRestricted` → `json_response(403, {"error":"age_restricted","capability":…,
  "band":…})` via a new `response.age_restricted(...)` helper.
- **Client mirror** (`ios/Mango/Services/Age/AgeGate.swift`): `AgeGate.allows(.peerSession)` from the
  **server-fetched** band (`GET /v1/me/age`), used **only to hide/absent the UI** — never as the
  security boundary. If the client and server disagree (stale client), the server 403 wins and the
  client refreshes the band.
- **Remote-config tunable (`0035`):** `POLICY` defaults live in code but can be **overridden by
  server config** so counsel can tighten (e.g. flip `iap_purchase` for teens) without an app release.

### 6.4 API / contract (add to `shared/api/openapi.yaml`)
```yaml
  /v1/me/age:
    get:
      summary: Read the caller's age band + capability flags (server-authoritative)
      responses:
        "200": { description: Age state, content: { application/json: { schema: { $ref: "#/components/schemas/AgeState" } } } }
        "401": { description: Unauthenticated }
    put:
      summary: Submit date of birth; server derives + stores the band (neutral gate)
      requestBody:
        required: true
        content:
          application/json:
            schema: { $ref: "#/components/schemas/AgeSubmit" }
      responses:
        "200": { description: Updated age state, content: { application/json: { schema: { $ref: "#/components/schemas/AgeState" } } } }
        "400": { description: Missing/invalid date }
        "409": { description: Correction not allowed (rate-limited / requires review) }
        "401": { description: Unauthenticated }
components:
  schemas:
    AgeSubmit:
      type: object
      required: [birthYear, birthMonth]
      properties:
        birthYear:  { type: integer, example: 2009 }
        birthMonth: { type: integer, minimum: 1, maximum: 12, example: 4 }
        # NOTE: client sends a DATE, never a band. Server derives the band (FR-2/FR-7).
    AgeState:
      type: object
      properties:
        band:          { type: string, enum: [under13, teen, adult, unknown] }
        ageVerifiedAt: { type: string, format: date-time, nullable: true }
        caps:
          type: object
          additionalProperties: { type: boolean }   # capability -> allowed (mirror of POLICY)
        policyVersion: { type: integer }
    AgeRestricted:                                   # the shared 403 body the gated specs return
      type: object
      properties:
        error:      { type: string, example: age_restricted }
        capability: { type: string, example: peer_session }
        band:       { type: string, example: teen }
```
**openapi ⇄ DTO ⇄ handler sync.** `DTOs.swift` gains `AgeStateDTO { band: String, ageVerifiedAt:
String?, caps: [String:Bool], policyVersion: Int }`, `AgeSubmitDTO { birthYear, birthMonth }`, and
`AgeRestrictedDTO { error, capability, band }` (lenient decode; unknown band string → `.unknown`,
fail-closed). The enforcing specs reference `AgeRestricted` for their new 403 response.

### 6.5 Backend handler (thin; logic in `shared/ageband.py`)
`backend/src/handlers/age.py` (new), mirroring `profile.py`'s thin shape:
- **GET** → `uid = user_id(event)` (401 on `PermissionError`), `eligibility(uid)` → `AgeState`.
- **PUT** → parse `{birthYear, birthMonth}`; **validate** (plausible year range, month 1–12; reject a
  date in the future / absurdly old); compute band server-side; **if an `AGE` item already exists**
  (a correction), enforce FR-10 (rate-limit `correctionCount`, flag self-downgrades, possibly 409);
  write the `AGE` item (`int` fields, `version++`); return `AgeState`. **Never** accepts a `band` from
  the body.
- Wire in `api_stack.py`: `age_fn` via `make_fn(...)`, `route("/v1/me/age", GET, age_fn)` +
  `route("/v1/me/age", PUT, age_fn)` (both **secured** = Cognito JWT), `table.grant_read_write_data(
  age_fn)`. (Least-privilege: `age_fn` touches only the table; no Bedrock, no S3, no secrets.)
- `shared/response.py` gains `age_restricted(payload) -> json_response(403, payload)` (mirrors the
  existing `bad_request`/`payment_required`).

### 6.6 iOS — onboarding gate, retroactive interstitial, services
- **Onboarding step (`0010` page enum).** Add an `ageGate` case to `OnboardingPage` **after
  `welcome`** (so it's early). The page (`Features/Onboarding/AgeGatePage.swift`) shows a neutral
  prompt + a **`DatePicker`** (`.date`, **no default selection** — start empty / require interaction;
  range capped to a plausible window, never pre-filled to "13 years ago") with copy *"What's your date
  of birth?"* and a short *why* line (*"This keeps Mango age-appropriate"*). On advance it computes a
  **provisional** band locally (instant UX) and stores `birthYear/Month` on the single `UserProfile`
  draft; the **server PUT** happens at finish/sign-in (D-6). **No "Are you 13+?" control exists.**
- **`UserProfile` (SwiftData) additions.** Add `birthYear: Int?`, `birthMonth: Int?`,
  `ageBandRaw: String` (default `"unknown"`), `ageVerifiedAt: Date?` — offline source of truth
  pre-sign-in; the **server band overrides** once fetched. (Xcode-16 sync — no `project.pbxproj`
  edits; SwiftData lightweight migration adds the optionals/defaults — §9.)
- **`AgeService` (`@Observable`, in `AppModel`).** Holds the **current band** (server-fetched when
  signed in, else local), exposes `allows(_ capability:)` for the UI, `submit(birthYear:month:)`
  (writes local + PUTs server when a session exists), and `refresh()` (`GET /v1/me/age`). Gated views
  ask `AgeService` to decide **visibility**; the **server** decides **access**.
- **Retroactive interstitial.** `Features/Age/AgeGateInterstitial.swift` — a one-time sheet shown when
  `ageBand == .unknown` and the user reaches a gated surface (or on next launch if a gated feature is
  live). It hosts the same neutral DOB control; on submit it writes/PUTs and dismisses. Until answered,
  gated entry points are **absent**; the core app is untouched. (§9 rollout.)
- **Gated-surface integration (each enforcing feature, one check).** `0023` Paywall/`OutOfCreditsSheet`,
  `0024` `RewardsView`, `0042` feed/share, `0043` `SessionEntryGate`, `0021` `SocialOnboarding` each
  call `AgeService.allows(...)` to **hide** their entry when disallowed, and handle the server **403
  `age_restricted`** (should the client be stale) by showing calm "not available for your age" copy +
  refreshing the band. `0043`'s `SessionEntryGate` already specifies "render nothing if ineligible" —
  it now sources eligibility from `AgeService` (adult-only).
- **Settings correction.** `Features/Settings` gains a guarded **"Date of birth"** row (FR-10):
  shows the current value, allows a correction subject to the server's rate-limit/review (a 409 is
  surfaced as "contact support"); never a free band toggle.
- **Tokens/tone.** All `Palette`/`Typo`/`Metrics`; VoiceOver labels; calm copy; Reduce-Motion safe.

### 6.7 Where it sits in onboarding (diagram)
```
OnboardingFlow (0010, TabView .page)
  [1 Welcome] ─► [1.5 AGE GATE: "What's your date of birth?"  (neutral DatePicker, no default)] ─►
        │ store birthYear/Month on local UserProfile (provisional band)        │
        ▼                                                                       ▼
  [2 How it works] ─► [3 Make it yours] ─► [4 Notifications] ─► [5 Sign in?] ─► [6 Finish]
                                                                   │ on sign-in / finish:
                                                                   ▼
                                              PUT /v1/me/age {birthYear, birthMonth}
                                                                   ▼
                                          server derives band → USER#<sub>/AGE (authoritative)
                                                                   ▼
        gated features (0023/0024/0042/0043/0021) call ageband.require(uid, cap) → allow | 403
Existing user (no AGE item): first gated surface → AgeGateInterstitial → PUT → band set → unblock
```

### 6.8 Enforcement points (the contract other specs honor)
- **`0023`** — `iap_purchase` (block under-13; teen per D-8) on `POST /v1/credits/purchase`;
  `credits_spend` (block under-13) on the `generate` spend hook. *(Note: under-13 don't reach the
  metered backend at all in v1, but the gate is belt-and-suspenders.)*
- **`0024`** — `rewards_redeem`/`rewards_giftcard` on `POST /v1/rewards/{id}/redeem` (under-13 block;
  teen restricted subset); `sweepstakes` already 18+.
- **`0042`** — `external_post` on `submit`/`feed`/`social-link` (under-13 block; **teen block** on
  public posting + arbitrary content; teen may get a vetted-content-only read per D-8).
- **`0043`** — `peer_session` on `request`/`respond`/`schedule` (**under-18 block**, matching its own
  G-1 hard gate; `0043` consumes *this* spec's adult flag).
- **`0021`** — `social` on the opt-in/`PUT /v1/social/me` (under-13 block).
- **`0025`** — push **marketing** suppressed for under-13 (transactional/learning reminders always
  allowed); the notification scheduler checks `push_marketing`.

### 6.9 International posture (designed-around; not localized in v1)
- **US-first.** v1 uses a **single under-13 line** (COPPA) + an **18+ line** for contact features. We
  **document** that GDPR-K consent age is **13–16 by member state** and the **UK is 13**, and that the
  **UK Children's Code** wants **high-privacy defaults + data minimization + proportionate age
  assurance** — all of which our band model + minors-restrictive defaults broadly satisfy.
- **Before any non-US launch (counsel-gated):** add a **jurisdiction-aware consent age** (a config
  map keyed by detected region) and, where required, a **parental-consent flow for EU minors** — a
  **future spec** (`0031c`), not built here (§10 R-7).

## 7. Acceptance criteria
- [ ] **AC-1 (neutral gate).** Onboarding shows a **DOB date picker** with **no pre-filled date** and
  **no "Are you 13+?" control**; the user must enter a date to pass the gate. *(iOS UI test + manual;
  grep asserts no "over 13"/"13+" boolean control in the age view.)*
- [ ] **AC-2 (server derives band; client never sets it).** `PUT /v1/me/age {birthYear, birthMonth}`
  stores a **server-derived** `ageBand`; a request body attempting to set `band` directly is ignored.
  *(pytest: post a DOB for 2009 → `teen`; post `band:"adult"` with an under-13 DOB → still `under13`.)*
- [ ] **AC-3 (three-band policy matrix).** `eligibility(uid).caps` matches FR-4 for a representative
  `under13`/`teen`/`adult` user. *(pytest table-test over `POLICY`; `AgeBandTests` for the pure
  derivation incl. the **18th-birthday transition** teen→adult.)*
- [ ] **AC-4 (under-13 block).** With an `under13` band, `POST /v1/credits/purchase`,
  `POST /v1/rewards/{id}/redeem`, `0042` submit, `0043` request, and `0021` opt-in each return
  **403 `age_restricted`** and perform **no** state change; the client **hides** those surfaces.
  *(pytest per gated handler asserting 403 + no write; iOS visibility test.)*
- [ ] **AC-5 (teen restrictions).** With a `teen` band, **`0043` request → 403**, **`0042` public
  post → 403**, **`0024` gift-card redeem → 403**, while **core learning + `0021` leagues** succeed.
  *(pytest per gate; iOS visibility test.)*
- [ ] **AC-6 (fail-closed on missing signal).** A user with **no `AGE` item** (`unknown` band) is
  **denied every gated capability** (`require` raises for all), and the **core app still works**.
  *(pytest: no AGE item → `require` 403 for each capability; smoke that profile/roadmap still 200.)*
- [ ] **AC-7 (persistence + server-authoritative).** The band survives reinstall (server-sourced on
  sign-in) and a **client that flips a local band flag still gets 403** from gated endpoints.
  *(pytest server gate ignores client; iOS test that local-only band change doesn't bypass a stubbed
  403.)*
- [ ] **AC-8 (retroactive gate).** An existing profile with no age, on reaching a gated surface, is
  shown the **one-time interstitial**; after submitting, the band is set and the feature unblocks.
  *(iOS flow test + manual; pytest that a profile lacking AGE returns `unknown` until PUT.)*
- [ ] **AC-9 (re-prompt rules).** A user who answered once is **not** re-prompted on subsequent
  launches (band present, current `policyVersion`); bumping `policyVersion` triggers exactly one
  re-ack. *(iOS test; pytest on the version check.)*
- [ ] **AC-10 (correction guardrails).** A second DOB change within the window is **rate-limited
  (409)** and a self-downgrade that removes a restriction is **flagged/most-restrictive-held**.
  *(pytest on `correctionCount` + downgrade flag.)*
- [ ] **AC-11 (data minimization).** Only `ageBand` + coarse birth ref (year+month per D-4) +
  metadata are stored; **no exact day** (unless counsel overrides); under-13 records carry **no other
  PII**; the analytics lake receives **no** age PII. *(pytest asserts stored item shape; code review of
  the events emitter.)*
- [ ] **AC-12 (float-free + Decimal-safe).** All age numerics persist as `int`; `Decimal`→`int` on
  read. *(pytest mirrors `profile.py` coercion test.)*
- [ ] **AC-13 (auth required + least privilege).** `/v1/me/age` returns **401** unauthenticated in
  prod/beta; `age_fn` has table access only (no Bedrock/S3/secrets). *(pytest auth test +
  `cdk synth` IAM inspection.)*
- [ ] **AC-14 (contract sync).** `openapi.yaml` defines `/v1/me/age` + `AgeState`/`AgeSubmit`/
  `AgeRestricted`; `DTOs.swift` mirrors them and decodes leniently (`unknown` fallback);
  `cdk synth -c stage=beta` passes. *(openapi lint + DTO decode test + synth.)*
- [ ] **AC-15 (offline-first preserved).** Fresh install, Mock AI, no network/auth: the **first
  sample lesson completes** without an age call; the DOB step stores locally and **backfills on
  sign-in**. *(manual offline run + iOS test of local→server backfill.)*
- [ ] **AC-16 (counsel sign-off recorded).** The §10 policy matrix + under-13 posture + retention
  statement are **reviewed and signed off by Legal** before `0023`/`0024`/`0042`/`0043` enable in
  prod. *(Process gate — recorded in §10; not code.)*

## 8. Test plan
**Backend — `pytest` (moto; offline), new `backend/tests/`:**
- `test_ageband.py` — the **pure** derivation: `under13/teen/adult` boundaries, the **18th-birthday**
  transition (year+month recompute), `unknown` on missing input (fail-closed); the `POLICY` table per
  capability per band (AC-3).
- `test_age_handler.py` — `PUT` derives + stores band; **ignores a client-sent `band`** (AC-2);
  validation (future/absurd dates → 400); correction rate-limit + downgrade flag (AC-10);
  Decimal→int (AC-12); auth-required in prod (AC-13); mirrors `test_progress.py` idioms.
- `test_age_gates.py` — for each gated handler (`credits.purchase`, `rewards.redeem`, an `0042`
  submit, an `0043` request, `0021` opt-in): `under13`/`teen`/`adult` → allow|403 and **no write on
  403** (AC-4/AC-5); **`unknown` → 403 everywhere** (AC-6); these import the real `ageband.require`.
- `test_contract.py` (extend) — new schemas/paths exist; a gated 403 decodes to `AgeRestricted`.
- `cdk synth -c stage=beta` — routes, secured flags, `age_fn` least-privilege grant.

**iOS — `MangoTests` (pure/fast) + flow:**
- `AgeBandTests` — the Swift twin of the derivation (must match the Python twin byte-for-byte on the
  same cases, incl. the birthday transition).
- `AgeGateTests` — `AgeService.allows(...)` maps server `caps` correctly; an `unknown`/absent band
  **hides** every gated surface; a stubbed server **403** is surfaced as calm copy + triggers a band
  refresh (AC-7).
- `OnboardingAgeGateTests` — the onboarding page requires a date to advance; no "13+" control exists
  (grep/UI); local store + backfill-on-sign-in (AC-1/AC-15).
- `AgeRetroactiveTests` — `unknown` band + gated surface → interstitial → submit → unblock (AC-8);
  answered-once → no re-prompt; `policyVersion` bump → one re-ack (AC-9).

**Manual / process:**
- Offline first-run sample lesson with Mock AI (no age call). VoiceOver + Dynamic-Type on the gate.
- **Legal review** of the policy matrix, under-13 posture, and retention statement (AC-16) — recorded.
- App Store Connect: the **13+** age-rating questionnaire + metadata reflect actual behavior (§11).

## 9. Rollout & migration
- **Dependency ordering.** This spec is a **blocker for prod monetization/social** (`ARCHITECTURE_REVIEW`
  §5 "before monetize"): land **before** `0023`/`0024` enable in prod and **before** `0042`/`0043`/
  `0021` ship their regulated surfaces. The shared `ageband` module + `/v1/me/age` should land first;
  the enforcing specs then add their one-line `require(...)` + 403 + client hide.
- **SwiftData migration.** Adding `birthYear/birthMonth/ageBandRaw/ageVerifiedAt` to `UserProfile` is a
  **lightweight, additive** migration (new optionals + a defaulted string) — no destructive change;
  existing installs migrate on launch with `ageBandRaw == "unknown"` (→ retroactive gate).
- **Server backfill.** No mass backfill/email. Existing users get `unknown` until they answer the
  **lazy, in-app, fail-closed** interstitial on first gated use (FR-8). Because gated features are
  **new** (none shipped yet), most users answer the gate the first time they touch a new paid/social
  surface — so day-1 friction is minimal.
- **Flags / config.** Behind `ageGateEnabled` (default **on** wherever a gated feature is enabled).
  `POLICY` thresholds are **overridable via `0035` remote config** so counsel can tighten (e.g.
  flip teen IAP) without an app release. `ageGatePolicyVersion` drives any re-ack.
- **Apple rating.** Submit the new **13+** rating via the Jan-31-2026 App Store Connect questionnaire;
  ensure metadata + behavior are consistent (under-13 block; not Kids Category). (§11.)
- **Backward-compat / teardown.** Additive everywhere; disabling `ageGateEnabled` (only acceptable if
  **no** regulated feature is live) hides the gate and the bands default permissive **only for
  non-regulated features** — the gated `require(...)` still fail-closes. No teardown of the age signal.

## 10. Risks & open decisions

### 10A. Compliance analysis & counsel gates (read before building)
> This is engineering's summary of **why counsel must drive the policy**, not a substitute for that
> advice. **The following gates block prod enablement of `0023`/`0024`/`0042`/`0043` and must be
> signed off by qualified children's-privacy counsel.**

- **G-1 (under-13 posture — the central decision).** v1 **blocks** under-13 from every regulated,
  data-collecting surface and **builds no VPC**, specifically to **stay outside** the amended COPPA
  Rule's heaviest obligations (VPC methods, written retention policy for child PII, written security
  program, separate third-party-disclosure consent). *Counsel must confirm* that (a) **block-by-default
  is sufficient** given how Mango is marketed (a self-help reading app — *not* child-directed; we must
  **not** market to children, or HoYoverse-style "directed to children" liability attaches **regardless
  of the gate**), and (b) whether to go further and **exclude under-13 from account creation entirely**
  until a VPC spec exists (**D-1**, recommended-to-consider). *Mitigation in design:* neutral gate +
  fail-closed + no under-13 PII collection.
- **G-2 (teen / under-16 + money + randomness).** **HoYoverse** drew an **under-16** line for loot
  boxes/virtual currency. Mango sells **credits** and has a **surprise-reward** mechanic. *Counsel must
  confirm* the **13–17 policy**: default-block teen **IAP** (D-8) and **restrict teen rewards** (no
  cash-equivalent) — and confirm the surprise reward stays an **honest, non-purchasable, published-odds
  bonus** (it already is, `0024` §6.4) so it is **not** a loot box. *Mitigation:* teen IAP off by
  default; teen gift-cards off; sweepstakes 18+.
- **G-3 (self-declared DOB is *assurance*, not *verification*).** A neutral self-declared DOB is the
  FTC-blessed **screening** mechanism, but a child can lie. *Counsel must confirm* self-declared
  assurance is acceptable for our risk level (the UK Children's Code explicitly allows **assurance
  proportionate to risk**, not mandatory hard verification). *Upgrade path (R-2):* if counsel/AppStore
  later require **age verification**, add a vendor satisfying the **FTC Feb-2026 policy** (single-purpose,
  tight retention, vetted processor, clear notice) — a separate spec.
- **G-4 (data-retention statement — amended Rule).** The amended Rule requires a **written retention
  policy disclosed in the privacy notice**. *Counsel must approve* the age-signal retention statement
  (what we keep — band + year/month — why, for how long, and that `DELETE /v1/me` erases it).
- **G-5 (Apple rating + Kids Category).** *Confirm* the **13+** self-rating is correct and that we do
  **not** opt into the Kids Category (our IAP/social behavior is inconsistent with it). The new
  questionnaire (due **Jan 31, 2026**) must reflect real behavior.
- **G-6 (international).** Non-US launch needs **jurisdiction-aware consent ages** (GDPR-K 13–16; UK 13)
  and possibly **EU parental-consent flows** — **out of scope**, **counsel-gated**, future `0031c`.

### 10B. Engineering / product risks
- **R-1 (kids lie about age / circumvention).** *Mitigation:* neutral gate (no signal which answer
  unlocks more), server-authoritative band, correction guardrails (FR-10), fail-closed; accept that
  **screening ≠ verification** and document the verification upgrade path (G-3/R-2). Critically, **do
  not market to children** — the gate does not cure child-directed marketing liability.
- **R-2 (assurance→verification upgrade).** If real AV is mandated, the Feb-2026 FTC policy gives a
  **single-purpose, tight-retention** safe path; design the `ageSource` field now (`self_declared` →
  future `verified_*`) so the schema absorbs it without migration pain.
- **R-3 (band staleness across a birthday).** A `teen` turning 18 must become `adult` without a
  re-prompt. *Mitigation:* store **year+month** and **recompute band on every gated read** (§6.2), so
  the transition is automatic; no nightly job required.
- **R-4 (over-blocking hurts UX / under-blocking risks compliance).** *Mitigation:* the matrix is
  **remote-config tunable** (`0035`) so counsel can adjust without a release; default **toward
  restriction** (fail-closed) and loosen only on sign-off.
- **R-5 (existing-user friction at retro-gate).** *Mitigation:* lazy/in-app/one-time/fail-closed; core
  app unaffected; gated features are new so most users meet the gate naturally on first paid/social use.
- **R-6 (privacy of the age signal itself).** Collecting DOB is itself data. *Mitigation:* minimize
  (D-4), single-purpose, no third-party disclosure, erasable, no analytics PII (NFR-3/4).
- **R-7 (analytics/marketing leakage for minors).** *Mitigation:* the events emitter must **drop**
  age/PII for under-13 and **suppress push-marketing**; coordinate with `0015`/`0025`/`0033`.

### Decisions needed (with recommendations)
- **D-1 (recommended: block-by-default; *consider* excluding under-13 from account creation until a
  VPC spec exists).** Whether v1 admits under-13 to a *core-only* account or excludes them entirely.
  **Recommend block-by-default for v1**, and put **full under-13 exclusion-until-VPC** to counsel as
  the safer alternative.
- **D-2 (recommended: dedicated `USER#<sub>/AGE` item).** Vs. folding onto `PROFILE`. Dedicated item =
  narrower IAM + cleaner retention/erase.
- **D-3 (recommended: store local first, PUT to server on sign-in/finish; server authoritative).** How
  the offline-first gate reconciles with the server signal.
- **D-4 (recommended: store birthYear + birthMonth + band; not the exact day).** Minimization vs.
  band-transition correctness. (Counsel may require exact-DOB for audit → both twins accept
  `dobEpochDay`.)
- **D-5 (recommended: rate-limited, logged corrections; self-downgrades flagged/most-restrictive-held).**
  Correction-path abuse resistance.
- **D-6 (recommended: mandatory DOB step in onboarding, early; core app still usable if skipped).**
  Gate placement/severity in `0010`.
- **D-7 (recommended: offline first-run unaffected; gate conditions only regulated features).** Confirm
  the bundled sample never blocks on age.
- **D-8 (recommended for v1: teen IAP **off**, teen gift-cards **off**, teen public-posting **off**;
  teen leagues + credits-spend **on**).** The exact teen matrix — **counsel-confirmed (G-2)**.
- **D-9 (recommended: `POLICY` defaults in code, overridable via `0035` remote config).** Where the
  thresholds live so counsel can tune without a release.

## 11. Tasks & estimate
1. **(S)** `shared/ageband.py` — pure `band_from`/`years_old`, `POLICY`, `eligibility`, `require`,
   `current_band` + `pytest` (boundaries, 18th-birthday transition, fail-closed). (FR-2/FR-4/FR-7)
2. **(S)** `handlers/age.py` (`GET`/`PUT /v1/me/age`) + `response.age_restricted` + validation +
   correction guardrails; wire `age_fn` + routes + least-privilege grant in `api_stack.py`; `pytest`
   (derive/ignore-client-band/auth/Decimal/correction). (FR-3/FR-10/FR-14)
3. **(S)** OpenAPI: `/v1/me/age` + `AgeState`/`AgeSubmit`/`AgeRestricted`; `DTOs.swift` mirrors
   (lenient decode). `cdk synth`. (FR-14)
4. **(S)** iOS `AgeBand`/`AgeService` (pure twin + `@Observable` service) + `UserProfile` fields +
   SwiftData additive migration; `AgeBandTests`/`AgeGateTests`. (FR-2/FR-7, NFR-7)
5. **(M)** Onboarding `AgeGatePage` (neutral `DatePicker`, no default, no "13+" control) added to the
   `0010` page enum after Welcome; local store + backfill-on-sign-in; `OnboardingAgeGateTests`.
   (FR-1/FR-13)
6. **(M)** Retroactive `AgeGateInterstitial` (one-time, fail-closed, gated-surface trigger) +
   re-prompt/version logic; `AgeRetroactiveTests`. (FR-8/FR-9)
7. **(M)** Wire the **per-feature gates** into the enforcing specs' handlers + client visibility:
   `0023` (iap_purchase/credits_spend), `0024` (rewards_redeem/giftcard/sweepstakes), `0042`
   (external_post), `0043` (peer_session), `0021` (social), `0025` (push_marketing) — each one line +
   403 + client hide + `test_age_gates.py`. (FR-4/FR-5/FR-6, §6.8) *(Coordinated edits land in those
   specs' PRs; this spec provides the module + tests.)*
8. **(S)** Settings "Date of birth" correction row (guarded, 409-aware). (FR-10)
9. **(S)** Data-minimization + analytics suppression: ensure under-13 PII never hits the lake;
   push-marketing suppressed for under-13; written **retention statement** drafted for the privacy
   notice. (NFR-3, FR-11)
10. **(S)** Remote-config override for `POLICY` via `0035`; `ageGateEnabled`/`ageGatePolicyVersion`
    flags. (D-9, §9)
11. **(S)** App Store Connect: complete the **13+** age-rating questionnaire + metadata; verify
    not-Kids-Category. (FR-12, G-5)
12. **(—) Legal sign-off gate** (process): policy matrix + under-13 posture + retention statement
    reviewed and recorded **before** prod enablement of the gated features. (AC-16, §10)

_Rough total: ~4 M + 7 S + 1 process gate._

## 12. References
**Repo (read for accuracy):**
- `working/ARCHITECTURE_REVIEW.md` §3 **G4** (the gap this spec fills) + §4/§5 (sequencing "before
  monetize").
- `working/0010-onboarding-redesign.md` (host flow + data-driven page enum where the gate slots in),
  `ios/Mango/Features/Onboarding/OnboardingFlow.swift` (current flow — **no** age step today).
- `working/0023-payments-and-credits.md` (credits/IAP — gated), `working/0024-rewards-and-coupons.md`
  (rewards + sweepstakes — gated; §10 promotion-law already 18+/AMOE),
  `working/0021-social-leagues.md` (social — gated), `working/0042-external-engagement-activities.md`
  (external/social — gated; already references **`0031` minors gating**),
  `working/0043-peer-and-human-activities.md` (peer/human — **hard 18+**, names *this* spec as its age
  source, §6.2 G-1).
- `ios/Mango/Models/UserProfile.swift` (single profile — **no DOB/age today**),
  `backend/src/handlers/profile.py` (thin GET/PUT pattern this spec mirrors; **no age field today**),
  `backend/src/shared/response.py` (`user_id` → `USER#<sub>`; 4xx helpers),
  `backend/mango_backend/{data_stack.py,api_stack.py}` (single table; least-privilege route wiring),
  `shared/api/openapi.yaml` (extend), `docs/specs/SPEC_TEMPLATE.md` (this format), `CLAUDE.md`
  (invariants).

**Regulatory research (web, June 2026) — accurate as engineering input; verify with counsel:**
- COPPA amended Rule (effective **Jun 23, 2025**; full compliance **Apr 22, 2026**; expanded PI,
  written retention policy, security program, tightened VPC) — FTC press release:
  https://www.ftc.gov/news-events/news/press-releases/2025/01/ftc-finalizes-changes-childrens-privacy-rule-limiting-companies-ability-monetize-kids-data ;
  Federal Register final rule: https://www.federalregister.gov/documents/2025/04/22/2025-05904/childrens-online-privacy-protection-rule
- Neutral age-screen mechanism + COPPA FAQ (ask DOB, not "are you 13?"; no defaulted/pre-filled
  dates) — FTC Business Guidance:
  https://www.ftc.gov/business-guidance/resources/complying-coppa-frequently-asked-questions ;
  BBB on age-screening: https://bbbprograms.org/media-center/bd/insights/2020/05/20/age-screening-coppa
- **HoYoverse / *Genshin Impact*** ($20M, Jan 2025 — gamified app + loot boxes + virtual currency,
  marketed to children, **no age gate**; settlement requires age-screening + under-16 parental consent
  + odds disclosure) — FTC:
  https://www.ftc.gov/news-events/news/press-releases/2025/01/genshin-impact-game-developer-will-be-banned-selling-lootboxes-teens-under-16-without-parental ;
  FTC business blog "Level up":
  https://www.ftc.gov/business-guidance/blog/2025/01/level-tips-businesses-ftcs-settlement-genshin-impact-developer-hoyoverse
- FTC **Feb-2026 age-verification enforcement-policy statement** (no action against operators
  collecting PI **solely** to determine age under single-purpose/tight-retention conditions;
  reiterates child-directed sites should assume under-13) — FTC:
  https://www.ftc.gov/news-events/news/press-releases/2026/02/ftc-issues-coppa-policy-statement-incentivize-use-age-verification-technologies-protect-children
- **Apple App Store age ratings** (new **13+/16+/18+** bands; questionnaire due **Jan 31, 2026**;
  under-13 apps must comply with COPPA; Kids Category rules) — Apple Developer news:
  https://developer.apple.com/news/?id=ks775ehf ; ratings reference:
  https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions/
- **UK Age-Appropriate Design Code / GDPR-K** (UK consent age **13**; EU **13–16**; high-privacy
  defaults, data minimization, **age assurance proportionate to risk**) — ICO Children's Code:
  https://ico.org.uk/for-organisations/uk-gdpr-guidance-and-resources/childrens-information/childrens-code-guidance-and-resources/
- Amended-Rule retention/data-minimization practitioner analysis — Fenwick:
  https://www.fenwick.com/insights/publications/what-the-amended-coppa-rule-means-for-data-retention-practices
