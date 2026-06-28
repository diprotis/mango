# Journey State and activity-gating are orthogonal

**Status:** accepted

A Book's **Journey State** (`notStarted → reading → finished`, user-set) and the
**read-gating** of its lessons (driven by self-confirmed Reading Checkpoints + prior-lesson
completion) are independent concerns that never couple.

- Journey State describes the *book* — the user's declared reading status, settable from any
  state (you can mark a book `finished` you never marked `reading`).
- Gating describes the *activities* — whether a lesson is shown, based on its milestone's
  `readingConfirmed` and prior-lesson completion.

Consequences we accept deliberately:
- A `finished` book can still have unconfirmed checkpoints and incomplete lessons; the
  Journey screen shows the real gating state regardless of Journey State.
- Marking `finished` does **not** mass-confirm checkpoints or reveal gated lessons.
- The "What to read next?" activity keys off `roadmap.progress == 1` (all activities done),
  **not** `journeyState == finished`.

**Why record it:** the obvious-but-wrong instinct is to make these agree (block "finish"
until all activities are done, or auto-confirm all checkpoints on finish). We rejected that:
a user genuinely can finish *reading* a book without doing every Mango activity, and
conflating the two harms the "you control the truth of where you are" product story.
Recording this stops a future change from "fixing" the apparent inconsistency.
