import SwiftData
import SwiftUI

struct BookDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppModel.self) private var app
    @Query private var profiles: [UserProfile]

    let book: Book
    @State private var isGenerating = false
    @State private var errorMessage: String?

    private var profile: UserProfile? { profiles.first }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.padL) {
                header
                summaryCard
                actions
                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(Palette.danger)
                }
            }
            .padding(Metrics.padL)
        }
        .mangoBackground()
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            BookCover(title: book.title, hue: book.coverHue, width: 92, height: 132)
            VStack(alignment: .leading, spacing: 8) {
                Text(book.title).font(Typo.title3).foregroundStyle(Palette.textPrimary)
                if let author = book.author {
                    Text(author).font(.subheadline).foregroundStyle(Palette.textSecondary)
                }
                HStack(spacing: 8) {
                    Tag("\(book.estimatedMinutes) min", systemImage: "clock", color: Palette.info)
                    Tag(book.sourceKind.label, systemImage: "antenna.radiowaves.left.and.right", color: Palette.textSecondary)
                }
                if book.isActive {
                    Tag("Active", systemImage: "bookmark.fill", color: Palette.success)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var summaryCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text(book.roadmap?.title ?? "About this book")
                    .font(.headline).foregroundStyle(Palette.textPrimary)
                Text(book.roadmap?.summary ?? book.excerpt)
                    .font(.system(.body, design: .serif))
                    .foregroundStyle(Palette.textSecondary)
                if let roadmap = book.roadmap {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: roadmap.progress).tint(Palette.accent)
                        Text("\(roadmap.completedLessonCount)/\(roadmap.allLessons.count) lessons")
                            .font(.caption).foregroundStyle(Palette.textSecondary)
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if book.roadmap != nil {
            NavigationLink(value: Route.journey(book)) {
                Label("Open journey", systemImage: "map.fill")
            }
            .buttonStyle(.mangoPrimary)
        } else {
            Button {
                generate()
            } label: {
                if isGenerating {
                    HStack { ProgressView().tint(Palette.onAccent); Text("Designing your journey…") }
                } else {
                    Label("Build my journey", systemImage: "wand.and.stars")
                }
            }
            .buttonStyle(.mangoPrimary(enabled: !isGenerating))
            .disabled(isGenerating)
        }

        NavigationLink(value: Route.reader(book)) {
            Label("Read the book", systemImage: "book")
        }
        .buttonStyle(.mangoSecondary)

        if !book.isActive {
            Button { makeActive() } label: {
                Label("Make this my active book", systemImage: "bookmark")
            }
            .buttonStyle(.mangoSecondary)
        }
    }

    private func generate() {
        isGenerating = true
        errorMessage = nil
        Task {
            do {
                try await RoadmapGenerator.generate(for: book, profile: profile, app: app, context: context)
                Haptics.success()
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isGenerating = false
        }
    }

    private func makeActive() {
        let all = (try? context.fetch(FetchDescriptor<Book>())) ?? []
        for other in all { other.isActive = (other.id == book.id) }
        try? context.save()
        Haptics.tap()
    }
}
