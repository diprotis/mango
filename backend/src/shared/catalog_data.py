"""Built-in public-domain catalog (dummy data).

A tiny, dependency-free starter shelf the app (and the integration tests) can use
without importing a book first. Every entry is short public-domain text, so the
full ``text`` can be POSTed inline to ``/v1/roadmaps/generate``.

Each book is::

    {
      "id": str,               # stable slug
      "title": str,
      "author": str,
      "excerpt": str,          # ~1 sentence preview
      "coverHue": int,         # 0-360 hue hint for a generated cover
      "wordCount": int,        # derived from ``text``
      "estimatedMinutes": int, # ~200 wpm reading estimate
      "text": str,             # SHORT public-domain excerpt
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
