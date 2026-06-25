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
    var fullText: String

    var sourceKindRaw: String
    var sourceValue: String

    var addedAt: Date
    var isActive: Bool

    /// Fraction of the text read, 0...1.
    var readProgress: Double
    /// Character offset for resume.
    var lastReadOffset: Int

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
        self.readProgress = 0
        self.lastReadOffset = 0
        self.roadmap = nil
    }

    var sourceKind: BookSourceKind {
        get { BookSourceKind(rawValue: sourceKindRaw) ?? .text }
        set { sourceKindRaw = newValue.rawValue }
    }

    var hasRoadmap: Bool { roadmap != nil }
}
