# Mango

Mango is **not a reading app**, but it **manages the whole reading journey**. Users read the
real book wherever they already read (print, Kindle, library); Mango curates that reading
into slices and threads them through a single roadmap, interleaved with the **active-learning
loop** — quizzes, reflections, real-world application tasks. The product competes on *doing*
(reading included as a thing you do), not on rendering book text or summarizing.

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
A unit of doing inside Mango — a **reading** slice, quiz, reflection, or application task
(the `ExerciseKind`s), and by extension the "What to read next?" choice card. The thing Mango
is *for*. **Reading is a first-class activity** (ADR-0003): each lesson leads with a reading
slice, then its practice. (Reading is the one self-attested activity — completed by an "I've
read this" tap, not graded.)
_Avoid_: Exercise (internal model name; "activity" is the product term), task.

**Reading Slice**:
A curated chunk of the book to read in the user's own copy, rendered as the first activity of
a lesson and threaded through the whole roadmap (read a slice → practice it → read the next).
The generator decides slice boundaries per book. Its prompt *instructs what to read* and may
carry a short "in this section…" cue — but Mango **never renders the book's full text**
(ADR-0001). Completed by self-attestation.
_Avoid_: Reading phase, the text, content, chapter (slices need not equal chapters).
