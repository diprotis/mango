import SwiftUI

enum ReadingLevel: String, CaseIterable, Codable, Identifiable {
    case casual, focused, deep
    var id: String { rawValue }

    var title: String {
        switch self {
        case .casual: return "Casual"
        case .focused: return "Focused"
        case .deep: return "Deep"
        }
    }

    var subtitle: String {
        switch self {
        case .casual: return "A little, often"
        case .focused: return "Steady daily progress"
        case .deep: return "All in — go deep"
        }
    }

    var suggestedDailyUnits: Int {
        switch self {
        case .casual: return 1
        case .focused: return 2
        case .deep: return 3
        }
    }
}

enum BookSourceKind: String, Codable {
    case url, gutenberg, text, pdf, sample

    var label: String {
        switch self {
        case .url: return "Web"
        case .gutenberg: return "Gutenberg"
        case .text: return "Pasted"
        case .pdf: return "PDF"
        case .sample: return "Sample"
        }
    }
}

enum ExerciseKind: String, CaseIterable, Codable, Identifiable {
    case quiz, reflection, application
    var id: String { rawValue }

    var title: String {
        switch self {
        case .quiz: return "Quick Check"
        case .reflection: return "Reflect"
        case .application: return "Apply It"
        }
    }

    var symbol: String {
        switch self {
        case .quiz: return "checkmark.circle"
        case .reflection: return "bubble.left.and.text.bubble.right"
        case .application: return "figure.walk.motion"
        }
    }

    var tint: Color {
        switch self {
        case .quiz: return Palette.info
        case .reflection: return Palette.accent
        case .application: return Palette.success
        }
    }

    var baseXP: Int {
        switch self {
        case .quiz: return 15
        case .reflection: return 25
        case .application: return 40
        }
    }
}

/// Visual/logical state of a lesson node in the journey path.
enum LessonStatus {
    case locked, available, completed
}

/// The user-controlled lifecycle of a Book's journey: `notStarted → reading →
/// finished`. Set manually by the user — **never** inferred from any in-app
/// reading signal (Mango has no in-app reader). Orthogonal to activity progress:
/// a book can be `finished` with activities incomplete, or `reading` with all done.
enum JourneyState: String, CaseIterable, Codable, Identifiable {
    case notStarted, reading, finished
    var id: String { rawValue }

    var title: String {
        switch self {
        case .notStarted: return "Not started"
        case .reading: return "Reading"
        case .finished: return "Finished"
        }
    }

    var symbol: String {
        switch self {
        case .notStarted: return "bookmark"
        case .reading: return "book"
        case .finished: return "checkmark.seal.fill"
        }
    }

    var tint: Color {
        switch self {
        case .notStarted: return Palette.textTertiary
        case .reading: return Palette.accent
        case .finished: return Palette.success
        }
    }
}
