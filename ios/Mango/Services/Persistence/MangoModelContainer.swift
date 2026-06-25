import SwiftData

enum MangoSchema {
    static let models: [any PersistentModel.Type] = [
        UserProfile.self,
        Book.self,
        Roadmap.self,
        Milestone.self,
        Lesson.self,
        Exercise.self,
        Achievement.self,
        ActivityDay.self,
    ]
}

enum MangoModelContainer {
    /// Builds the container. Seeding happens once on first appearance (RootView)
    /// so this stays free of main-actor requirements and is safe in `App.init`.
    static func make(inMemory: Bool = false) -> ModelContainer {
        let schema = Schema(MangoSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create the Mango ModelContainer: \(error)")
        }
    }

    /// An in-memory container with seed data, for SwiftUI previews.
    @MainActor
    static func preview() -> ModelContainer {
        let container = make(inMemory: true)
        SeedData.ensureSeeded(in: container.mainContext)
        return container
    }
}
