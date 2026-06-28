# Reading is a first-class activity threaded through the roadmap

**Status:** accepted (2026-06-28) · supersedes the milestone-level Reading Checkpoint in the
0008 roadmap

Mango curates and manages the *entire* reading journey: reading is a **first-class activity**
woven through the roadmap, not a passive checkpoint sitting above a milestone's lessons. Each
lesson leads with a **reading slice** (a curated chunk to read in the user's own copy),
followed by that lesson's practice activities (quiz / reflection / application). The user
reads a slice, practices it, then reads the next — small reading steps threaded end-to-end
across the whole roadmap (~one per lesson).

## Decisions

- **Reading is an `ExerciseKind`.** We added `ExerciseKind.reading` rather than a new model
  type. Reading rides every rail activities already have — the gamification engine, the
  activity runner, completion/persistence, and `Roadmap.progress`. No parallel machinery.
- **Curate, don't display.** A reading activity *instructs* what to read; Mango never renders
  the book's full text (ADR-0001 still holds). It is **self-attested** — completed by an
  "I've read this" tap, never graded, no answer.
- **Generation decides slice boundaries.** The roadmap generator already chooses lesson
  boundaries; each lesson *is* a slice. The reading activity is synthesized client-side in
  `RoadmapBuilder` from the lesson's existing `readingSummary`, so it works across all three
  AI services (Remote / Direct / Mock) and **offline** — with **no backend, prompt, or
  `openapi.yaml` change**. `SeedData` uses the same factory so the bundled sample demonstrates
  it offline.
- **Read-gates the lesson.** Reading is activity `order == 0`; because the lesson runner plays
  activities in order, practice is reached only after the reading step — "read first, then
  practice" with no extra gating code.
- **XP = 10.** Reading counts and is rewarded, but practice (15/25/40) still dominates the XP
  economy, keeping Mango's "competes on *doing*" balance and the existing level curve intact.

## Consequences

- **Supersedes** 0008's milestone-level, passive **Reading Checkpoint** ("Have you read up to
  ‹milestone›?") — reading confirmation is now finer (per lesson) and active (an activity).
  [ADR-0002](0002-journey-state-orthogonal-to-activity-gating.md) still holds for the *book's*
  Journey State; only the milestone-checkpoint gating mechanism is replaced. The 0008 roadmap
  slices that built the milestone checkpoint (#4) are re-scoped accordingly.
- **Migration:** existing on-device roadmaps generated before this change have no reading
  activity. A backfill (folded into the 0008 migration pass) prepends one per lesson from the
  stored `readingSummary`. Fresh installs get it via seed/generation immediately.
- **`CONTEXT.md` reversed:** "reading is explicitly **not** an activity" → reading **is** the
  first activity of every lesson.

**Why record it:** an app that "isn't a reader" now makes reading its leading activity — a
future reader will see the tension. It is deliberate: Mango manages the *process* of reading
(what to read, in what order, paired with practice) without *being* the surface you read on.
