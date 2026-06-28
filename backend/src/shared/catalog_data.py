"""Built-in starter catalog (dependency-free).

A tiny starter shelf the app (and the integration tests) can use without importing
a book first. The full ``text`` is bundled so it can be POSTed inline to
``/v1/roadmaps/generate``.

Two kinds of entries:
  * Short **public-domain excerpts** (Meditations, Aesop, Self-Reliance).
  * Original **educational summaries** that Mango wrote in its own words to teach a
    modern book's ideas (e.g. ``make-it-stick``). These paraphrase well-established
    concepts and cite the source work; they do not reproduce the book's prose.

Each book is::

    {
      "id": str,               # stable slug
      "title": str,
      "author": str,
      "excerpt": str,          # ~1 sentence preview
      "coverHue": int,         # 0-360 hue hint for a generated cover
      "wordCount": int,        # derived from ``text``
      "estimatedMinutes": int, # ~200 wpm reading estimate
      "text": str,             # public-domain excerpt OR original summary
    }

The canonical "dummy" book is :data:`DUMMY_BOOK_ID`.
"""

# The book the integration harness always picks; keep it stable.
DUMMY_BOOK_ID = "dummy-meditations"


def _word_count(text: str) -> int:
    return len(text.split())


def _estimated_minutes(words: int) -> int:
    # ~200 words/minute, rounded up, floor of 1.
    return max(1, round(words / 200))


# Raw entries — wordCount/estimatedMinutes are derived below so they never drift.
_RAW = [
    {
        "id": DUMMY_BOOK_ID,
        "title": "Meditations (Selections)",
        "author": "Marcus Aurelius",
        "excerpt": "Begin each day by telling yourself what you may meet, and meet it with reason.",
        "coverHue": 28,
        "text": (
            "Begin the morning by saying to thyself, I shall meet with the busybody, "
            "the ungrateful, arrogant, deceitful, envious, unsocial. All these things "
            "happen to them by reason of their ignorance of what is good and evil. But "
            "I who have seen the nature of the good that it is beautiful, and of the bad "
            "that it is ugly, and the nature of him who does wrong, that it is akin to me, "
            "can neither be injured by any of them, nor be angry with my kinsman, nor hate "
            "him. We are made for cooperation, like feet, like hands, like eyelids, like "
            "the rows of the upper and lower teeth. To act against one another then is "
            "contrary to nature; and it is acting against one another to be vexed and to "
            "turn away. Confine thyself to the present. Waste no more time arguing about "
            "what a good man should be. Be one."
        ),
    },
    {
        "id": "dummy-aesop",
        "title": "Aesop's Fables (Selections)",
        "author": "Aesop",
        "excerpt": "Slow and steady wins the race — three short fables and their morals.",
        "coverHue": 122,
        "text": (
            "The Hare was once boasting of his speed before the other animals. I have "
            "never yet been beaten, said he, when I put forth my full speed. The Tortoise "
            "said quietly, I accept your challenge. That is a good joke, said the Hare; I "
            "could dance round you all the way. The race began; the Hare darted almost out "
            "of sight, then lay down to nap. The Tortoise plodded on, and plodded on, and "
            "when the Hare awoke, the Tortoise had reached the goal. Slow and steady wins "
            "the race. A Crow, dying of thirst, found a pitcher with a little water, but "
            "could not reach it. He dropped in pebbles one by one until the water rose to "
            "the brim, and so quenched his thirst. Necessity is the mother of invention."
        ),
    },
    {
        "id": "make-it-stick",
        "title": "Make It Stick: How Learning Really Works",
        "author": "A Mango summary of the work by Brown, Roediger & McDaniel",
        "excerpt": "The science of durable learning: why effortful practice beats rereading.",
        "coverHue": 14,
        # Original educational summary written by Mango in its own words. It teaches
        # the well-established cognitive-science principles popularized by the book
        # "Make It Stick" (Peter C. Brown, Henry L. Roediger III, Mark A. McDaniel,
        # 2014); it paraphrases those ideas and does not reproduce the book's text.
        "text": (
            "How Learning Really Works: A Practical Summary of the Science\n\n"
            "Most of us study in ways that feel productive but aren't. We reread "
            "highlighted passages, review our notes, and mistake the resulting sense "
            "of familiarity for real understanding. Decades of cognitive-science "
            "research show that the techniques that feel hardest in the moment are "
            "usually the ones that build the most durable, flexible knowledge. The "
            "central lesson is counterintuitive: learning that feels easy tends to be "
            "shallow and quickly forgotten, while learning that feels effortful tends "
            "to last.\n\n"
            "1. Retrieval practice (testing yourself). The single most powerful study "
            "tool is trying to recall information from memory rather than reviewing "
            "it. Every act of retrieval strengthens the memory and makes it easier to "
            "find later. This is why low-stakes self-quizzing, flashcards, and writing "
            "down what you remember after reading beat passively rereading the same "
            "text. Researchers call this the testing effect: a test is not just a "
            "measurement of learning, it is one of the best ways to produce it.\n\n"
            "2. Spaced practice (don't cram). Studying in spaced sessions over days or "
            "weeks produces far stronger long-term retention than massing all your "
            "practice into one block. Cramming can win a quiz tomorrow, but the "
            "knowledge fades fast. Letting a little forgetting set in between sessions "
            "makes the next retrieval more effortful and therefore more powerful.\n\n"
            "3. Interleaving (mix it up). Instead of practicing one type of problem "
            "over and over before moving on, mix related topics or problem types "
            "within a session. Interleaving feels more confusing and slower, and your "
            "performance during practice may look worse, but it produces better "
            "learning and a stronger ability to tell which approach a new problem "
            "actually calls for.\n\n"
            "4. Elaboration (explain it in your own words). Deepen understanding by "
            "putting new ideas into your own language and connecting them to what you "
            "already know. Asking how and why something works, and relating it to "
            "personal experience or other concepts, gives a new idea more mental hooks "
            "and makes it easier to retrieve.\n\n"
            "5. Generation (try before you're taught). Attempting to solve a problem "
            "or answer a question before being shown the solution leads to better "
            "learning, even when your first attempt is wrong. The struggle primes your "
            "mind to absorb the answer when it arrives.\n\n"
            "6. Reflection (review the experience). Taking a few minutes to ask what "
            "happened, what went well, what you would do differently, and what it "
            "connects to combines retrieval and elaboration into a single durable "
            "habit. Reflection turns raw experience into transferable lessons.\n\n"
            "7. Calibration (beat the illusion of knowing). We are poor judges of our "
            "own learning. Fluency with a text — the ease of rereading something "
            "familiar — creates a false confidence that we have mastered it. Use "
            "objective checks like quizzes and practice problems to see what you "
            "actually know, not what you merely recognize.\n\n"
            "The unifying idea is desirable difficulty: challenges that slow you down "
            "during practice, like retrieving, spacing, and interleaving, are exactly "
            "the conditions that make learning stick. Effort is not a sign that "
            "learning is failing; it is often the sign that it is working. A simple "
            "system follows from this: test yourself instead of rereading, space your "
            "practice out over time, mix up what you practice, explain ideas in your "
            "own words, attempt problems before seeing answers, and reflect on what "
            "you have learned. Embrace the difficulty, and your knowledge will last."
        ),
    },
    {
        "id": "dummy-self-reliance",
        "title": "Self-Reliance (Opening)",
        "author": "Ralph Waldo Emerson",
        "excerpt": "Trust thyself: every heart vibrates to that iron string.",
        "coverHue": 268,
        "text": (
            "There is a time in every man's education when he arrives at the conviction "
            "that envy is ignorance; that imitation is suicide; that he must take himself "
            "for better, for worse, as his portion. Trust thyself: every heart vibrates to "
            "that iron string. Accept the place the divine providence has found for you, "
            "the society of your contemporaries, the connection of events. Great men have "
            "always done so, and confided themselves childlike to the genius of their age, "
            "betraying their perception that the absolutely trustworthy was seated at their "
            "heart, working through their hands, predominating in all their being. A "
            "foolish consistency is the hobgoblin of little minds, adored by little "
            "statesmen and philosophers and divines. Speak what you think now in hard "
            "words, and tomorrow speak what tomorrow thinks in hard words again, though it "
            "contradict every thing you said today."
        ),
    },
]


def _build_catalog():
    catalog = []
    for entry in _RAW:
        words = _word_count(entry["text"])
        catalog.append(
            {
                "id": entry["id"],
                "title": entry["title"],
                "author": entry["author"],
                "excerpt": entry["excerpt"],
                "coverHue": entry["coverHue"],
                "wordCount": words,
                "estimatedMinutes": _estimated_minutes(words),
                "text": entry["text"],
            }
        )
    return catalog


#: The public catalog. Full ``text`` included — handlers strip it for list views.
CATALOG = _build_catalog()

# Fast id -> item lookup for the detail endpoint.
_BY_ID = {item["id"]: item for item in CATALOG}


def list_items() -> list:
    """Return catalog entries WITHOUT the heavy ``text`` field (for list views)."""
    return [{k: v for k, v in item.items() if k != "text"} for item in CATALOG]


def get_item(book_id: str):
    """Return the full catalog entry (incl. ``text``) for ``book_id`` or ``None``."""
    return _BY_ID.get(book_id)
