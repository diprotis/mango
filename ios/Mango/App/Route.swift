import SwiftUI

/// Type-safe navigation routes shared by every tab's NavigationStack.
enum Route: Hashable {
    case bookDetail(Book)
    case journey(Book)
    case lesson(Lesson)
}

private struct MangoDestinations: ViewModifier {
    func body(content: Content) -> some View {
        content.navigationDestination(for: Route.self) { route in
            switch route {
            case let .bookDetail(book): BookDetailView(book: book)
            case let .journey(book): JourneyView(book: book)
            case let .lesson(lesson): LessonView(lesson: lesson)
            }
        }
    }
}

extension View {
    /// Registers Mango's navigation destinations on the enclosing stack.
    func mangoDestinations() -> some View { modifier(MangoDestinations()) }
}
