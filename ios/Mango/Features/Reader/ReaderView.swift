import SwiftData
import SwiftUI

struct ReaderView: View {
    @Environment(\.modelContext) private var context
    let book: Book

    @AppStorage("mango.readerFontSize") private var fontSize: Double = 18

    private var firstLesson: Lesson? {
        book.roadmap?.allLessons.first { !$0.isCompleted } ?? book.roadmap?.allLessons.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(book.title).font(Typo.title).foregroundStyle(Palette.textPrimary)
                if let author = book.author {
                    Text(author).font(.subheadline).foregroundStyle(Palette.textSecondary)
                }
                Divider().background(Palette.border)

                Text(book.fullText.isEmpty ? "No text available." : book.fullText)
                    .font(.system(size: fontSize, design: .serif))
                    .lineSpacing(7)
                    .foregroundStyle(Palette.textPrimary)
                    .textSelection(.enabled)

                Color.clear.frame(height: 1).onAppear { markReadToEnd() }

                if let lesson = firstLesson {
                    NavigationLink(value: Route.lesson(lesson)) {
                        Label("Begin the lessons", systemImage: "checklist")
                    }
                    .buttonStyle(.mangoPrimary)
                    .padding(.top, 8)
                }
            }
            .padding(Metrics.padL)
        }
        .mangoBackground()
        .navigationTitle("Reader")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { fontSize = max(14, fontSize - 2); Haptics.tap() } label: {
                    Image(systemName: "textformat.size.smaller")
                }
                .accessibilityLabel("Decrease text size")
                Button { fontSize = min(28, fontSize + 2); Haptics.tap() } label: {
                    Image(systemName: "textformat.size.larger")
                }
                .accessibilityLabel("Increase text size")
            }
        }
    }

    private func markReadToEnd() {
        guard book.readProgress < 1 else { return }
        book.readProgress = 1
        book.lastReadOffset = book.fullText.count
        try? context.save()
    }
}
