import SwiftData
import SwiftUI

struct LibraryView: View {
    @Query(sort: \Book.addedAt, order: .reverse) private var books: [Book]
    @State private var showingAdd = false

    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.padL) {
                if books.isEmpty {
                    EmptyStateView(
                        systemImage: "books.vertical",
                        title: "Build your library",
                        message: "Add a book, article, or PDF and Mango turns it into a guided journey."
                    )
                    Button { showingAdd = true } label: {
                        Label("Add your first book", systemImage: "plus")
                    }
                    .buttonStyle(.mangoPrimary)
                } else {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(books) { book in
                            NavigationLink(value: Route.bookDetail(book)) {
                                LibraryCard(book: book)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(Metrics.padL)
        }
        .mangoBackground()
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAdd = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add book")
            }
        }
        .sheet(isPresented: $showingAdd) { AddBookView() }
    }
}

private struct LibraryCard: View {
    let book: Book

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(hue: book.coverHue / 360, saturation: 0.45, brightness: 0.72),
                            Color(hue: book.coverHue / 360, saturation: 0.5, brightness: 0.55),
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .frame(height: 150)
                .overlay(alignment: .topLeading) {
                    Text(book.title)
                        .font(.system(size: 15, weight: .bold, design: .serif))
                        .foregroundStyle(Palette.onAccent)
                        .lineLimit(4)
                        .padding(12)
                }
                .overlay(alignment: .bottomTrailing) {
                    if book.isActive {
                        Image(systemName: "bookmark.fill")
                            .foregroundStyle(Palette.onAccent)
                            .padding(8)
                    }
                }

            Text(book.title).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.textPrimary).lineLimit(1)
            if let author = book.author {
                Text(author).font(.caption).foregroundStyle(Palette.textSecondary).lineLimit(1)
            }
            if let roadmap = book.roadmap {
                ProgressView(value: roadmap.progress).tint(Palette.accent)
            } else {
                Text("Tap to build a journey").font(.caption2).foregroundStyle(Palette.textTertiary)
            }
        }
    }
}

#Preview {
    NavigationStack { LibraryView().mangoDestinations() }
        .environment(AppModel())
        .modelContainer(MangoModelContainer.preview())
}
