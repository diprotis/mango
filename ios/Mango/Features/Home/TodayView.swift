import SwiftData
import SwiftUI

struct TodayView: View {
    @Environment(\.modelContext) private var context
    @Query private var profiles: [UserProfile]
    @Query(sort: \Book.addedAt, order: .reverse) private var books: [Book]
    @Query private var todays: [ActivityDay]

    init() {
        let start = Calendar.current.startOfDay(for: .now)
        _todays = Query(filter: #Predicate<ActivityDay> { $0.day == start })
    }

    private var profile: UserProfile? { profiles.first }
    private var activeBook: Book? { books.first { $0.isActive } ?? books.first }
    private var nextLesson: Lesson? { activeBook?.roadmap?.allLessons.first { !$0.isCompleted } }
    private var doneToday: Int { todays.first?.lessonsCompleted ?? 0 }
    private var goalUnits: Int { max(1, profile?.dailyGoalUnits ?? 1) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.padL) {
                header
                    dailyGoalCard
                    if let book = activeBook {
                        continueCard(book)
                    } else {
                        EmptyStateView(
                            systemImage: "books.vertical",
                            title: "Your shelf is empty",
                            message: "Add a book in the Library tab to begin your first journey."
                        )
                    }
                insightCard
            }
            .padding(Metrics.padL)
        }
        .mangoBackground()
        .navigationTitle("Today")
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(greeting)
                    .font(Typo.title)
                    .foregroundStyle(Palette.textPrimary)
                if let level = profile {
                    Text("Level \(level.level) · \(level.levelTitle)")
                        .font(.subheadline)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            Spacer()
            StreakPill(days: profile?.currentStreak ?? 0)
        }
    }

    private var dailyGoalCard: some View {
        Card {
            HStack(spacing: 18) {
                ZStack {
                    ProgressRing(progress: Double(doneToday) / Double(goalUnits), size: 72, lineWidth: 10)
                    VStack(spacing: 0) {
                        Text("\(doneToday)/\(goalUnits)").font(.headline).foregroundStyle(Palette.textPrimary)
                        Text("today").font(.caption2).foregroundStyle(Palette.textSecondary)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(doneToday >= goalUnits ? "Daily goal complete 🎉" : "Daily goal")
                        .font(.headline).foregroundStyle(Palette.textPrimary)
                    Text(doneToday >= goalUnits
                         ? "Beautiful work. Rest is part of learning."
                         : "Finish \(goalUnits - doneToday) more lesson\(goalUnits - doneToday > 1 ? "s" : "") to close your ring.")
                        .font(.subheadline).foregroundStyle(Palette.textSecondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func continueCard(_ book: Book) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    BookCover(title: book.title, hue: book.coverHue)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(book.title).font(Typo.title3).foregroundStyle(Palette.textPrimary).lineLimit(2)
                        if let author = book.author {
                            Text(author).font(.subheadline).foregroundStyle(Palette.textSecondary)
                        }
                        if let roadmap = book.roadmap {
                            Tag("\(Int(roadmap.progress * 100))% complete", systemImage: "map", color: Palette.accent)
                        }
                    }
                    Spacer(minLength: 0)
                }
                if let lesson = nextLesson {
                    NavigationLink(value: Route.lesson(lesson)) {
                        Label("Start: \(lesson.title)", systemImage: "play.fill")
                    }
                    .buttonStyle(.mangoPrimary)
                } else if book.roadmap == nil {
                    NavigationLink(value: Route.bookDetail(book)) {
                        Label("Build my journey", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.mangoPrimary)
                } else {
                    Text("You've finished every lesson here. 🌱").font(.subheadline).foregroundStyle(Palette.success)
                }
                Label("Read this book on your own — Mango coaches the practice.", systemImage: "book.closed")
                    .font(.footnote)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var insightCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("Insight", systemImage: "quote.opening").font(.caption.weight(.semibold)).foregroundStyle(Palette.accent)
                Text(activeBook.map { String($0.excerpt.prefix(160)) } ?? "Small steps, repeated, become who you are.")
                    .font(.system(.body, design: .serif))
                    .foregroundStyle(Palette.textPrimary)
            }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let part = hour < 12 ? "Good morning" : (hour < 18 ? "Good afternoon" : "Good evening")
        let name = profile?.name ?? ""
        return name.isEmpty ? part : "\(part), \(name)"
    }
}

#Preview {
    TodayView()
        .environment(AppModel())
        .modelContainer(MangoModelContainer.preview())
}
