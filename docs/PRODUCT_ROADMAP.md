# Product Roadmap

Mango's north star is **durable, healthy engagement that converts reading into
doing**. Education apps have famously weak retention because the payoff is delayed
by weeks, so every roadmap item is judged by whether it strengthens the near-term
reward loop (XP, streaks, levels, achievements) without resorting to dark patterns
(see [GAMIFICATION.md](GAMIFICATION.md)).

## v0.1 — shipped

The current build is a complete, offline-capable product. It ships onboarding that
builds a profile and seeds a library (with a bundled public-domain sample), book
import via web URL / Project Gutenberg / pasted text / PDF, an immersive reader,
and AI-generated gamified roadmaps — running on an on-device mock generator, or on
real Claude (direct on-device key, or the deployed backend). The lesson loop
(reading summary → quiz / reflection / application) awards XP and feeds the
gamification engine: levels with titles, a day-granular streak with a streak-freeze
safety valve, a daily goal ring, achievements, and a profile with a weekly streak
strip. The AWS backend is deployable with 29 passing tests and clean `cdk synth`
on both beta and prod. The most important known gap: **the app has no sign-in yet**,
so "Mango Backend" AI mode can't authenticate against the deployed API — backend
calls today rely on a dev identity header that production stages reject.

## Prioritized next milestones

**1. Cognito sign-in (unblocks the backend).** The user pool and JWT authorizer
already exist server-side; the app needs a sign-in/sign-up flow that obtains a
Cognito token and stores it for `APIClient`'s `Authorization` header. This is the
gating dependency for every server feature — without it, the deployed backend
(and the server-held Anthropic key, the secure production path) is unreachable
from the app.

**2. Progress sync.** With auth in place, push and pull gamification state through
the existing `GET`/`PUT /v1/me/progress` endpoint so XP, level, streak, and freezes
survive reinstalls and follow the user across devices. Losing a hard-won streak to
a new phone is exactly the loss-aversion the streak mechanic is meant to *protect*,
so persistence directly defends retention.

**3. Social leagues — phase 2 (needs backend).** Weekly XP leagues, friend
streaks, and reading buddies add the Relatedness pillar of Self-Determination
Theory and the social comparison that drove large engagement lifts elsewhere. This
requires server-side leaderboards, identity, and anti-cheat — hence it follows
auth and sync. It stays opt-in, with a non-competitive mode and no public shaming.

**4. Spaced-repetition "Insight Review."** A daily 60-second flashcard set drawn
from past chapters, with intervals that expand on correct recall. Retrieval
practice beats re-reading for long-term retention, and a light review keeps the
streak alive on a busy day — turning the loss-aversion mechanic into a learning
win rather than a chore.

**5. EPUB import.** Extend the connectors layer (which already handles URL,
Gutenberg, text, and PDF) with EPUB so users can bring their own library. More
import paths means more books in the funnel and more reasons to return.

**6. Offload PDF parsing off the main thread.** Today `ConnectorService.importPDF`
walks pages with PDFKit synchronously; large PDFs can hitch the UI. Moving parsing
to a background context keeps import smooth and protects the first-run experience,
where a stutter can cost activation.

**7. App Store prep.** App icon and launch polish, screenshots, privacy nutrition
labels (notably the on-device-key vs backend distinction), the single-reminder
notification rationale, and store metadata — the work to take v0.1 from
"runs in the simulator" to shippable.

Throughout, the ethical guardrails hold: notifications stay capped at roughly one
a day, surprise rewards remain honest bonuses on top of guaranteed XP, and the app
keeps optimizing for *ideas applied and habits built* rather than raw time on app.
