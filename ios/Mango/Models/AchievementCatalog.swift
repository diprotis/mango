import Foundation

/// Canonical list of achievements. Keys are referenced by the gamification rules
/// engine and seeded (locked) on first launch.
enum AchievementCatalog {
    struct Definition {
        let key: String
        let title: String
        let detail: String
        let symbol: String
    }

    // Keys
    static let firstStep = "first_step"
    static let firstReflection = "first_reflection"
    static let firstQuiz = "first_quiz"
    static let appliedIt = "applied_it"
    static let finishedLesson = "finished_lesson"
    static let weekOne = "week_one"
    static let level5 = "level_5"
    static let nightOwl = "night_owl"
    static let deepDiver = "deep_diver"
    static let comeback = "comeback"

    static let all: [Definition] = [
        .init(key: firstStep, title: "First Step", detail: "Completed your very first exercise.", symbol: "shoeprints.fill"),
        .init(key: firstReflection, title: "Deep Thinker", detail: "Wrote your first reflection.", symbol: "bubble.left.and.text.bubble.right.fill"),
        .init(key: firstQuiz, title: "Sharp Mind", detail: "Aced your first quiz.", symbol: "checkmark.seal.fill"),
        .init(key: appliedIt, title: "Applied It", detail: "Took an idea into the real world.", symbol: "figure.walk.motion"),
        .init(key: finishedLesson, title: "Lesson Learned", detail: "Finished a full lesson.", symbol: "book.closed.fill"),
        .init(key: weekOne, title: "Week One", detail: "Kept a 7-day streak.", symbol: "flame.fill"),
        .init(key: level5, title: "Scholar", detail: "Reached level 5.", symbol: "graduationcap.fill"),
        .init(key: nightOwl, title: "Night Owl", detail: "Learned after 10pm.", symbol: "moon.stars.fill"),
        .init(key: deepDiver, title: "Deep Dive", detail: "Finished 3 lessons in one day.", symbol: "arrow.down.circle.fill"),
        .init(key: comeback, title: "Comeback", detail: "A streak freeze saved your run.", symbol: "snowflake"),
    ]
}
