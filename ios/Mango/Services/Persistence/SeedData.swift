import Foundation
import SwiftData

/// Seeds first-run content so the app is alive immediately: a player profile,
/// the locked achievement set, and one sample public-domain book with a ready
/// gamified roadmap (Marcus Aurelius — *Meditations*, George Long translation).
@MainActor
enum SeedData {
    static func ensureSeeded(in context: ModelContext) {
        seedAchievements(context)
        seedProfile(context)
        seedSampleBook(context)
        try? context.save()
    }

    private static func seedAchievements(_ context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<Achievement>())) ?? []
        guard existing.isEmpty else { return }
        for def in AchievementCatalog.all {
            context.insert(
                Achievement(key: def.key, title: def.title, detail: def.detail, symbol: def.symbol)
            )
        }
    }

    private static func seedProfile(_ context: ModelContext) {
        let profiles = (try? context.fetch(FetchDescriptor<UserProfile>())) ?? []
        guard profiles.isEmpty else { return }
        context.insert(UserProfile())
    }

    private static func seedSampleBook(_ context: ModelContext) {
        let books = (try? context.fetch(FetchDescriptor<Book>())) ?? []
        guard books.isEmpty else { return }

        let text = sampleText
        let words = text.split { $0 == " " || $0.isNewline }.count
        let book = Book(
            id: "sample-meditations",
            title: "Meditations",
            author: "Marcus Aurelius",
            coverHue: 28,
            wordCount: words,
            estimatedMinutes: max(1, words / 200),
            excerpt: String(text.prefix(220)) + "…",
            fullText: text,
            sourceKind: .sample,
            sourceValue: "bundled-sample",
            isActive: true
        )

        let roadmap = Roadmap(
            title: "The Stoic Operating System",
            summary: "Turn Marcus Aurelius's private notes into a daily practice for a calmer, more deliberate mind."
        )
        book.roadmap = roadmap

        let m1 = Milestone(title: "The Inner Citadel", subtitle: "What is — and isn't — up to you", order: 0)
        let l1 = Lesson(
            title: "The Dichotomy of Control",
            readingSummary: "Some things are within our power; many are not. Peace begins by telling them apart.",
            estimatedMinutes: 4,
            order: 0
        )
        l1.exercises = [
            Exercise(
                kind: .quiz,
                prompt: "According to the Stoics, what is truly 'up to us'?",
                options: ["Our reputation", "Our judgments and actions", "Other people's choices", "The weather"],
                answerIndex: 1,
                xp: ExerciseKind.quiz.baseXP,
                order: 0
            ),
            Exercise(
                kind: .reflection,
                prompt: "Name one thing draining you right now. Which part is in your control, and which isn't?",
                xp: ExerciseKind.reflection.baseXP,
                order: 1
            ),
        ]
        let l2 = Lesson(
            title: "Morning Preparation",
            readingSummary: "Marcus rehearsed the day's difficulties in advance so nothing could ambush his composure.",
            estimatedMinutes: 5,
            order: 1
        )
        l2.exercises = [
            Exercise(
                kind: .reflection,
                prompt: "What is one difficulty likely today? Write how your best self would meet it.",
                xp: ExerciseKind.reflection.baseXP,
                order: 0
            ),
            Exercise(
                kind: .application,
                prompt: "Tomorrow morning, take 60 seconds to preview your day before reaching for your phone. Come back and note what changed.",
                xp: ExerciseKind.application.baseXP,
                order: 1
            ),
        ]
        m1.lessons = [l1, l2]

        let m2 = Milestone(title: "Obstacle Into Way", subtitle: "Turning friction into fuel", order: 1)
        let l3 = Lesson(
            title: "The Impediment to Action",
            readingSummary: "“The impediment to action advances action. What stands in the way becomes the way.”",
            estimatedMinutes: 4,
            order: 0
        )
        l3.exercises = [
            Exercise(
                kind: .quiz,
                prompt: "What does Marcus suggest an obstacle can become?",
                options: ["A reason to quit", "The way forward", "Someone else's problem", "Proof of bad luck"],
                answerIndex: 1,
                xp: ExerciseKind.quiz.baseXP,
                order: 0
            ),
            Exercise(
                kind: .application,
                prompt: "Pick one obstacle today and ask: what virtue (patience, courage, creativity) does this let me practice? Act on it once.",
                xp: ExerciseKind.application.baseXP,
                order: 1
            ),
        ]
        m2.lessons = [l3]

        roadmap.milestones = [m1, m2]
        context.insert(book)
    }

    private static let sampleText = """
    Book II

    Begin the morning by saying to thyself, I shall meet with the busy-body, the \
    ungrateful, arrogant, deceitful, envious, unsocial. All these things happen to them \
    by reason of their ignorance of what is good and evil. But I who have seen the nature \
    of the good that it is beautiful, and of the bad that it is ugly, and the nature of \
    him who does wrong, that it is akin to me — I can neither be injured by any of them, \
    for no one can fix on me what is ugly, nor can I be angry with my kinsman, nor hate \
    him.

    Do every act of thy life as if it were thy last, free from all rashness, and from \
    passionate aversion to the commands of reason, and from hypocrisy, and self-love, and \
    discontent with the portion which has been given to thee.

    Book IV

    Men seek retreats for themselves, houses in the country, sea-shores, and mountains; \
    and thou too art wont to desire such things very much. But this is altogether a mark \
    of the most common sort of men, for it is in thy power whenever thou shalt choose to \
    retire into thyself. For nowhere either with more quiet or more freedom from trouble \
    does a man retire than into his own soul.

    Such as are thy habitual thoughts, such also will be the character of thy mind; for \
    the soul is dyed by the thoughts. Dye it then with a continuous series of such \
    thoughts as these: that where a man can live, there he can also live well.

    The impediment to action advances action. What stands in the way becomes the way.

    Book V

    In the morning when thou risest unwillingly, let this thought be present — I am rising \
    to the work of a human being. Why then am I dissatisfied if I am going to do the \
    things for which I exist and for which I was brought into the world? Or have I been \
    made for this, to lie in the bed-clothes and keep myself warm?
    """
}
