import Foundation

/// Offline generator that produces a believable, book-specific roadmap so the app
/// is fully usable with no backend and no API key.
struct MockAIService: AIService {
    func generateRoadmap(book: AIBookContext, profile: AIProfileContext) async throws -> RoadmapDTO {
        try? await Task.sleep(nanoseconds: 600_000_000)
        let topic = book.title
        let goal = profile.goals.first ?? "grow"

        func quiz(_ q: String, _ opts: [String], _ idx: Int) -> ExerciseDTO {
            ExerciseDTO(kind: "quiz", prompt: q, options: opts, answerIndex: idx, xp: 15)
        }
        func reflect(_ p: String) -> ExerciseDTO {
            ExerciseDTO(kind: "reflection", prompt: p, options: nil, answerIndex: nil, xp: 25)
        }
        func apply(_ p: String) -> ExerciseDTO {
            ExerciseDTO(kind: "application", prompt: p, options: nil, answerIndex: nil, xp: 40)
        }

        return RoadmapDTO(
            title: "Your \(topic) Journey",
            summary: "A hands-on path to absorb \(topic) and actually use it to \(goal).",
            milestones: [
                MilestoneDTO(
                    title: "Core Ideas",
                    subtitle: "Grasp the foundation",
                    lessons: [
                        LessonDTO(
                            title: "The Big Idea",
                            readingSummary: "Read the opening of \(topic) and capture its central claim.",
                            estimatedMinutes: 5,
                            exercises: [
                                quiz("What is the author's central promise?",
                                     ["A quick fix", "A repeatable practice", "A list of facts", "Entertainment"], 1),
                                reflect("In one sentence, what do you most want from \(topic)?"),
                            ]
                        ),
                        LessonDTO(
                            title: "Why It Matters To You",
                            readingSummary: "Connect the first ideas to your own goal of \(goal).",
                            estimatedMinutes: 6,
                            exercises: [
                                reflect("Where in your life would this idea make the biggest difference?"),
                                apply("Try the simplest version of this idea once today, then note what happened."),
                            ]
                        ),
                    ]
                ),
                MilestoneDTO(
                    title: "Make It Stick",
                    subtitle: "From insight to habit",
                    lessons: [
                        LessonDTO(
                            title: "Turn Insight Into Action",
                            readingSummary: "Translate the next section into a tiny daily practice.",
                            estimatedMinutes: 6,
                            exercises: [
                                quiz("What makes a new habit most likely to stick?",
                                     ["Willpower", "Making it tiny and obvious", "Big goals", "Punishment"], 1),
                                apply("Design a 2-minute version of this practice and schedule it for tomorrow."),
                            ]
                        ),
                    ]
                ),
                MilestoneDTO(
                    title: "Go Deeper",
                    subtitle: "Own the material",
                    lessons: [
                        LessonDTO(
                            title: "Teach It Back",
                            readingSummary: "Explaining an idea is the fastest way to truly learn it.",
                            estimatedMinutes: 5,
                            exercises: [
                                reflect("Explain the most useful idea from \(topic) as if to a friend."),
                            ]
                        ),
                    ]
                ),
            ]
        )
    }

    func grade(kind: ExerciseKind, prompt: String, answer: String) async throws -> GradeResultDTO {
        try? await Task.sleep(nanoseconds: 400_000_000)
        let words = answer.split { $0 == " " || $0.isNewline }.count
        let score = min(1.0, 0.55 + Double(min(words, 40)) / 80.0)
        let feedback: String
        switch kind {
        case .application:
            feedback = "Love that you put it into practice — notice what felt different and do it once more tomorrow."
        case .reflection:
            feedback = words < 8
                ? "Good start — try adding a concrete example from your own week to go deeper."
                : "Thoughtful and specific. Naming a next step would make it even stronger."
        case .quiz:
            feedback = "Nice work."
        }
        return GradeResultDTO(correct: nil, score: score, feedback: feedback, xpAwarded: Int(Double(kind.baseXP) * (0.5 + 0.5 * score)))
    }
}
