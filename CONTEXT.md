# Mango

Mango is **not a reading app**. Users read the real book wherever they already read
(print, Kindle, library); inside Mango they do the **active-learning loop** — quizzes,
reflections, real-world application tasks — and track their reading journey. The product
competes on *doing*, not on in-app reading or summarizing.

## Language

**Journey**:
A user's progression through one book: discover it, mark that they're reading it, and
work through the activity roadmap built for it. "Start journey" (not "read", not "create
roadmap") is how a journey begins from the Catalog.
_Avoid_: Reading session, course.

**Journey State**:
The user-controlled lifecycle of a Book: `notStarted → reading → finished`. Set manually
by the user; **never** inferred from any in-app reading signal (there is no in-app
reading). One Journey State per user per book. **Orthogonal to activity progress** — a
book can be `finished` with activities still incomplete, or `reading` with everything done.
Journey State describes the *book*; gating describes the *activities*. The two never couple.
_Avoid_: Reading status, read progress.

**Reading Checkpoint**:
A self-confirmed, reversible "Have you read up to *‹milestone›*?" gate on a Milestone.
Until confirmed, all of that milestone's lessons are Read-Gated. Honor-system — Mango
trusts the user's word, matching the self-attested application-task pattern.
_Avoid_: Quiz gate, unlock test.

**Read-Gated**:
A Lesson hidden behind an unconfirmed Reading Checkpoint. Distinct from **Locked** (hidden
because a prior lesson in the same milestone isn't complete). A lesson is shown only when
its milestone is checkpoint-confirmed AND it's the first incomplete lesson.
_Avoid_: Blocked, disabled.

**Activity**:
A unit of doing inside Mango — a quiz, reflection, or application task (the existing
`ExerciseKind`s), and by extension the "What to read next?" choice card. The thing Mango is
*for*. Reading the book is explicitly **not** an activity.
_Avoid_: Exercise (internal model name; "activity" is the product term), task.

**Reading Recap** (lesson reading phase):
The orientation text shown before a lesson's activities — a short "in this section…"
summary plus a "read this section in your own copy" cue. It is explicitly **not** the
source text; Mango never renders the book's full text.
_Avoid_: Reading phase, the text, content.
