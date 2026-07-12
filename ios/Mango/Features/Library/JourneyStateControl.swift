import SwiftData
import SwiftUI

/// The journey-status control (0008 #3): a state pill that opens a menu of the legal
/// manual transitions (from `JourneyStateMachine.manualEvents`). Used on BookDetail
/// and, in compact form, on Today's continue card. State is user-controlled and
/// orthogonal to activity progress (ADR-0002) — no confirmation dialogs, every
/// transition is recoverable.
struct JourneyStateControl: View {
    @Environment(\.modelContext) private var context
    let book: Book
    var compact: Bool = false

    var body: some View {
        Menu {
            ForEach(JourneyStateMachine.manualEvents(from: book.journeyState), id: \.self) { event in
                Button(label(for: event), systemImage: symbol(for: event)) {
                    dispatch(event)
                }
            }
        } label: {
            pill
        }
        .accessibilityLabel("Journey status: \(book.journeyState.title)")
    }

    private var pill: some View {
        let state = book.journeyState
        return HStack(spacing: 4) {
            Image(systemName: state.symbol)
            Text(state.title)
            Image(systemName: "chevron.up.chevron.down").font(.caption2)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(state.tint)
        .padding(.horizontal, compact ? 10 : 12)
        .padding(.vertical, compact ? 5 : 7)
        .background(state.tint.opacity(0.14))
        .clipShape(Capsule())
    }

    private func dispatch(_ event: JourneyEvent) {
        book.journeyState = JourneyStateMachine.apply(event, to: book.journeyState)
        try? context.save()
        event == .markFinished ? Haptics.success() : Haptics.tap()
    }

    private func label(for event: JourneyEvent) -> String {
        switch event {
        case .start: return "Start journey"
        case .activityCompleted: return ""  // never offered manually
        case .markFinished: return "Mark finished"
        case .reopen: return "Reopen"
        }
    }

    private func symbol(for event: JourneyEvent) -> String {
        switch event {
        case .start: return "play.fill"
        case .activityCompleted: return ""
        case .markFinished: return "checkmark.seal"
        case .reopen: return "arrow.uturn.backward"
        }
    }
}

#Preview {
    JourneyStateControl(book: Book(id: "p", title: "Preview Book"))
        .modelContainer(MangoModelContainer.preview())
        .padding()
}
