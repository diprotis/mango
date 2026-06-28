import Foundation
import SwiftData

@Model
final class Book {
    @Attribute(.unique) var id: String
    var title: String
    var author: String?
    var coverHue: Double
    var wordCount: Int
    var estimatedMinutes: Int
    var excerpt: String
    /// Non-displayed generation cache: the ingested book text used only to ground
    /// AI roadmap/lesson generation (≤12k-char excerpt is sent to the model). Mango
    /// is not a reader — this is **never** rendered to the user. See ADR-0001.
    var fullText: String

    var sourceKindRaw: String
    var sourceValue: String

    var addedAt: Date
    var isActive: Bool

    /// The user-controlled journey lifecycle, stored as a raw string (see `journeyState`).
    var journeyStateRaw: String = JourneyState.notStarted.rawValue

    @Relationship(deleteRule: .cascade, inverse: \Roadmap.book)
    var roadmap: Roadmap?

    init(
        id: String,
        title: String,
        author: String? = nil,
        coverHue: Double = 28,
        wordCount: Int = 0,
        estimatedMinutes: Int = 0,
        excerpt: String = "",
        fullText: String = "",
        sourceKind: BookSourceKind = .text,
        sourceValue: String = "",
        isActive: Bool = false
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.coverHue = coverHue
        self.wordCount = wordCount
        self.estimatedMinutes = estimatedMinutes
        self.excerpt = excerpt
        self.fullText = fullText
        self.sourceKindRaw = sourceKind.rawValue
        self.sourceValue = sourceValue
        self.addedAt = .now
        self.isActive = isActive
        self.journeyStateRaw = JourneyState.notStarted.rawValue
        self.roadmap = nil
    }

    var sourceKind: BookSourceKind {
        get { BookSourceKind(rawValue: sourceKindRaw) ?? .text }
        set { sourceKindRaw = newValue.rawValue }
    }

    var journeyState: JourneyState {
        get { JourneyState(rawValue: journeyStateRaw) ?? .notStarted }
        set { journeyStateRaw = newValue.rawValue }
    }

    var hasRoadmap: Bool { roadmap != nil }
}
