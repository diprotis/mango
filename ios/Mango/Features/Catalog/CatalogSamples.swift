import Foundation

/// A tiny bundled catalog used when no backend is reachable (Offline/Mock), so
/// the Catalog → "Create roadmap" flow still works fully on-device through the
/// mock/direct AI service. All texts are public domain.
///
/// When a real backend is configured these are ignored in favour of
/// `GET /v1/catalog`; the ids are namespaced (`sample-…`) so they never collide
/// with backend ids.
enum CatalogSamples {
    static let all: [CatalogBook] = details.map { detail in
        CatalogBook(
            id: detail.id,
            title: detail.title,
            author: detail.author,
            excerpt: detail.excerpt,
            coverHue: detail.coverHue,
            wordCount: detail.wordCount,
            estimatedMinutes: detail.estimatedMinutes
        )
    }

    static func detail(for id: String) -> CatalogBookDetail? {
        details.first { $0.id == id }
    }

    private static let details: [CatalogBookDetail] = [
        makeDetail(
            id: "sample-meditations",
            title: "Meditations",
            author: "Marcus Aurelius",
            coverHue: 28,
            text: meditationsText
        ),
        makeDetail(
            id: "sample-art-of-war",
            title: "The Art of War",
            author: "Sun Tzu",
            coverHue: 200,
            text: artOfWarText
        ),
    ]

    /// Build a detail with derived word count / minutes / excerpt so the bundled
    /// rows look just like backend rows.
    private static func makeDetail(
        id: String,
        title: String,
        author: String,
        coverHue: Double,
        text: String
    ) -> CatalogBookDetail {
        let words = text.split { $0 == " " || $0.isNewline }.count
        let excerpt = String(text.prefix(180)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        return CatalogBookDetail(
            id: id,
            title: title,
            author: author,
            excerpt: excerpt,
            coverHue: coverHue,
            wordCount: words,
            estimatedMinutes: max(1, words / 200),
            text: text
        )
    }

    private static let meditationsText = """
    Begin the morning by saying to thyself, I shall meet with the busy-body, the \
    ungrateful, arrogant, deceitful, envious, unsocial. All these things happen to them \
    by reason of their ignorance of what is good and evil. But I who have seen the nature \
    of the good that it is beautiful, and of the bad that it is ugly, can neither be \
    injured by any of them, nor be angry with my kinsman.

    Do every act of thy life as if it were thy last, free from all rashness, and from \
    passionate aversion to the commands of reason, and from hypocrisy, and self-love, and \
    discontent with the portion which has been given to thee.

    Nowhere, either with more quiet or more freedom from trouble, does a man retire than \
    into his own soul. Constantly then give to thyself this retreat, and renew thyself.

    The impediment to action advances action. What stands in the way becomes the way.
    """

    private static let artOfWarText = """
    The art of war is of vital importance to the State. It is a matter of life and death, \
    a road either to safety or to ruin. Hence it is a subject of inquiry which can on no \
    account be neglected.

    All warfare is based on deception. Hence, when able to attack, we must seem unable; \
    when using our forces, we must seem inactive; when we are near, we must make the enemy \
    believe we are far away.

    Supreme excellence consists in breaking the enemy's resistance without fighting. \
    Therefore the skilful leader subdues the enemy's troops without any fighting.

    If you know the enemy and know yourself, you need not fear the result of a hundred \
    battles. If you know yourself but not the enemy, for every victory gained you will \
    also suffer a defeat.
    """
}
