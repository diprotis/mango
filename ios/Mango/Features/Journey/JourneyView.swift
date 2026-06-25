import SwiftData
import SwiftUI

struct JourneyView: View {
    @Query(sort: \Book.addedAt, order: .reverse) private var books: [Book]
    private let passedBook: Book?

    init(book: Book? = nil) {
        self.passedBook = book
    }

    private var book: Book? { passedBook ?? books.first { $0.isActive } ?? books.first }

    var body: some View {
        Group {
            if let book, let roadmap = book.roadmap {
                content(book: book, roadmap: roadmap)
            } else if let book {
                VStack(spacing: 16) {
                    EmptyStateView(
                        systemImage: "map",
                        title: "No journey yet",
                        message: "Build a gamified roadmap of lessons for \(book.title)."
                    )
                    NavigationLink(value: Route.bookDetail(book)) {
                        Label("Build the journey", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.mangoPrimary)
                    .padding(.horizontal, Metrics.padL)
                }
            } else {
                EmptyStateView(
                    systemImage: "books.vertical",
                    title: "No active book",
                    message: "Add a book in the Library tab to start a journey."
                )
            }
        }
        .mangoBackground()
        .navigationTitle("Journey")
    }

    private func content(book: Book, roadmap: Roadmap) -> some View {
        let lessons = roadmap.allLessons
        let firstIncompleteID = lessons.first { !$0.isCompleted }?.persistentModelID

        func status(_ lesson: Lesson) -> LessonStatus {
            if lesson.isCompleted { return .completed }
            return lesson.persistentModelID == firstIncompleteID ? .available : .locked
        }

        return ScrollView {
            VStack(alignment: .leading, spacing: Metrics.padL) {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(roadmap.title).font(Typo.title3).foregroundStyle(Palette.textPrimary)
                        Text(roadmap.summary).font(.subheadline).foregroundStyle(Palette.textSecondary)
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: roadmap.progress).tint(Palette.accent)
                            Text("\(roadmap.completedLessonCount) of \(lessons.count) lessons")
                                .font(.caption).foregroundStyle(Palette.textSecondary)
                        }
                        .padding(.top, 4)
                    }
                }

                ForEach(roadmap.orderedMilestones) { milestone in
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(milestone.title).font(Typo.title3).foregroundStyle(Palette.textPrimary)
                            Text(milestone.subtitle).font(.subheadline).foregroundStyle(Palette.textSecondary)
                        }
                        ForEach(milestone.orderedLessons) { lesson in
                            JourneyRow(lesson: lesson, status: status(lesson))
                        }
                    }
                }
            }
            .padding(Metrics.padL)
        }
    }
}

private struct JourneyRow: View {
    let lesson: Lesson
    let status: LessonStatus

    var body: some View {
        if status == .locked {
            row.opacity(0.55)
        } else {
            NavigationLink(value: Route.lesson(lesson)) { row }
                .buttonStyle(.plain)
        }
    }

    private var row: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(indicatorColor.opacity(0.16)).frame(width: 44, height: 44)
                Image(systemName: indicatorSymbol).foregroundStyle(indicatorColor).font(.headline)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(lesson.title).font(.headline).foregroundStyle(Palette.textPrimary).lineLimit(2)
                Text("\(lesson.estimatedMinutes) min · \(lesson.totalXP) XP")
                    .font(.caption).foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: 0)
            if status != .locked {
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(14)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(status == .available ? Palette.accent.opacity(0.5) : Palette.border, lineWidth: status == .available ? 2 : 1)
        )
    }

    private var indicatorColor: Color {
        switch status {
        case .completed: return Palette.success
        case .available: return Palette.accent
        case .locked: return Palette.textTertiary
        }
    }

    private var indicatorSymbol: String {
        switch status {
        case .completed: return "checkmark"
        case .available: return "play.fill"
        case .locked: return "lock.fill"
        }
    }
}

#Preview {
    NavigationStack { JourneyView().mangoDestinations() }
        .environment(AppModel())
        .modelContainer(MangoModelContainer.preview())
}
