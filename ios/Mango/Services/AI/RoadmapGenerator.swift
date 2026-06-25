import Foundation
import SwiftData

/// Bridges the AI service and SwiftData: generates a roadmap for a book and
/// attaches it. Used by the add-book flow and book detail.
@MainActor
enum RoadmapGenerator {
    static func generate(for book: Book, profile: UserProfile?, app: AppModel, context: ModelContext) async throws {
        let bookContext = AIBookContext(
            title: book.title,
            author: book.author,
            excerpt: book.excerpt,
            fullText: book.fullText
        )
        let profileContext = AIProfileContext(
            goals: profile?.goals ?? [],
            interests: profile?.interests ?? [],
            readingLevel: profile?.readingLevel.rawValue ?? "focused",
            dailyGoalUnits: profile?.dailyGoalUnits ?? 2
        )
        let dto = try await app.ai.generateRoadmap(book: bookContext, profile: profileContext)
        RoadmapBuilder.attach(dto, to: book, in: context)
        try? context.save()
    }
}
