# Remove the in-app Reader; Mango is an activity tracker, not a reader

**Status:** accepted

Mango deletes the in-app book Reader (`ReaderView`, `Route.reader`, `readProgress`/
`lastReadOffset`, `markReadToEnd()`) outright — not behind a flag, not demoted. Users read
the real book wherever they already read; inside Mango they do the active-learning loop and
track a manually-set reading journey.

**Why record it:** A future reader will see that `Book.fullText` is still persisted and
ingested for generation, and reasonably wonder why an app that "isn't a reader" keeps full
book text and once had a reader. This is deliberate: generation already grounds only on a
≤12k-char excerpt of `fullText` (`AIPrompts.roadmapUser`, `prompts.py`, `RemoteAIService`),
so removing the *display* changes nothing about generation quality. The text is retained as
a **non-displayed generation cache** (never rendered).

**Trade-off:** We considered (and rejected for v1) trimming `fullText` to a smaller
generation-input field or dropping on-device text entirely and regenerating via the
server-side `contentRef`. Both break the offline-first invariant or the Direct-Claude /
Catalog generation paths (Direct has no server; Catalog/sample books have no `contentRef`),
so we kept the text as-is and only stopped displaying it. Revisit trimming under a privacy/
storage review.

**Hard to reverse:** restoring a reader means re-introducing display UI, reading-progress
fields, and the reading-centric navigation we deleted.
