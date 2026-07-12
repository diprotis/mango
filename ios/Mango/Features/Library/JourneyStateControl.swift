import SwiftData
import SwiftUI

/// The journey-status control (0008 #3): a state pill that opens a menu of the legal
/// manual transitions (from `JourneyStateMachine.manualEvents`). Used on BookDetail
/// and Today's continue card. State is user-controlled and orthogonal to activity
/// progress (ADR-0002). No confirmation dialogs — a mis-tap is one menu action away
/// from the previous state everywhere except leaving `notStarted`, which we accept:
/// it only ever reflects "I've engaged with this book".
struct JourneyStateControl: View {
    @Environment(\.modelContext) private var context
    let book: Book

    var body: some View {
        Menu {
            ForEach(JourneyStateMachine.manualEvents(from: book.journeyState), id: \.self) { event in
                Button(event.title, systemImage: event.symbol) {
                    dispatch(event)
                }
            }
        } label: {
            let state = book.journeyState
            Tag(
                state.title,
                systemImage: state.symbol,
                color: state.tint,
                trailingSystemImage: "chevron.up.chevron.down"
            )
        }
        .accessibilityLabel("Journey status: \(book.journeyState.title)")
    }

    private func dispatch(_ event: JourneyEvent) {
        book.journeyState = JourneyStateMachine.apply(event, to: book.journeyState)
        try? context.save()
        event == .markFinished ? Haptics.success() : Haptics.tap()
    }
}

#Preview {
    let container = MangoModelContainer.preview()
    let book = Book(id: "p", title: "Preview Book")
    container.mainContext.insert(book)
    return JourneyStateControl(book: book)
        .modelContainer(container)
        .padding()
}
