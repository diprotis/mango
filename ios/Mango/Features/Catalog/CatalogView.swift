import SwiftData
import SwiftUI

/// Browse the backend's curated public-domain catalog and turn any title into a
/// gamified journey in one tap — the minimal end-to-end path:
/// *signed-in user → pick a book → roadmap via the real backend.*
///
/// Degrades gracefully: with a real backend it lists `GET /v1/catalog`; offline
/// (Mock) it shows a small bundled catalog so the flow still works on-device.
/// Tapping **Create roadmap** while signed out (and pointed at a real backend)
/// presents sign-in first; otherwise it fetches the book's text, seeds a `Book`,
/// builds the roadmap (through `app.ai`), and routes to the Journey.
struct CatalogView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query private var profiles: [UserProfile]

    @State private var books: [CatalogBook] = []
    @State private var isLoading = false
    @State private var loadError: String?

    /// The id of the book currently being turned into a journey (drives the
    /// per-row spinner and disables the rest).
    @State private var creatingID: String?
    @State private var createError: String?

    /// Sign-in sheet, shown when a real backend needs auth before creating.
    @State private var showingAuth = false
    /// The book to resume creating once sign-in completes.
    @State private var pendingBook: CatalogBook?

    /// Pushed once a roadmap is built, to open the journey.
    @State private var createdBook: Book?

    private var profile: UserProfile? { profiles.first }
    private var isBusy: Bool { creatingID != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.padL) {
                intro
                if let loadError {
                    errorRow(loadError)
                }
                if isLoading && books.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                } else if books.isEmpty {
                    EmptyStateView(
                        systemImage: "books.vertical",
                        title: "Catalog unavailable",
                        message: "Connect a backend in Settings to browse curated books."
                    )
                } else {
                    ForEach(books) { book in
                        CatalogRow(
                            book: book,
                            isCreating: creatingID == book.id,
                            isDisabled: isBusy && creatingID != book.id,
                            onCreate: { create(book) }
                        )
                    }
                }
                if let createError {
                    errorRow(createError)
                }
            }
            .padding(Metrics.padL)
        }
        .mangoBackground()
        .navigationTitle("Catalog")
        .navigationDestination(item: $createdBook) { book in
            // Reader/Lesson destinations reachable from here are already
            // registered by the enclosing stack's `.mangoDestinations()`.
            JourneyView(book: book)
        }
        .sheet(isPresented: $showingAuth, onDismiss: resumePendingCreate) {
            AuthView()
        }
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: - Pieces

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Browse the catalog")
                .font(Typo.title3)
                .foregroundStyle(Palette.textPrimary)
            Text("Pick a public-domain classic and Mango builds a gamified roadmap of lessons and exercises.")
                .font(.subheadline)
                .foregroundStyle(Palette.textSecondary)
        }
    }

    private func errorRow(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(Palette.danger)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Loading

    @MainActor
    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            books = try await app.catalog().list()
        } catch {
            // Offline/Mock (or an unreachable backend): fall back to the bundled
            // catalog so the screen is still usable on-device.
            books = CatalogSamples.all
            if app.settings.isRealBackend {
                loadError = "Showing offline picks — couldn't reach the catalog."
            }
        }
    }

    // MARK: - Create roadmap

    private func create(_ book: CatalogBook) {
        // Gate on sign-in only when we're actually pointed at a real backend;
        // Offline/Mock proceeds straight to on-device generation.
        if app.settings.isRealBackend && !app.auth.isSignedIn {
            pendingBook = book
            showingAuth = true
            return
        }
        startCreate(book)
    }

    /// Resume a create that was waiting on sign-in (sheet dismissed). Only
    /// proceeds if the user actually signed in.
    private func resumePendingCreate() {
        guard let book = pendingBook else { return }
        pendingBook = nil
        guard app.auth.isSignedIn else { return }
        startCreate(book)
    }

    private func startCreate(_ catalogBook: CatalogBook) {
        creatingID = catalogBook.id
        createError = nil
        Task {
            do {
                let detail = try await fetchDetail(for: catalogBook)
                let book = try await buildAndGenerate(from: detail)
                await MainActor.run {
                    creatingID = nil
                    Haptics.success()
                    createdBook = book
                }
            } catch {
                await MainActor.run {
                    creatingID = nil
                    createError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    Haptics.warning()
                }
            }
        }
    }

    /// Fetch the full text from the backend; fall back to a bundled detail when
    /// offline so the flow completes on-device.
    private func fetchDetail(for book: CatalogBook) async throws -> CatalogBookDetail {
        do {
            return try await app.catalog().detail(book.id)
        } catch {
            if let local = CatalogSamples.detail(for: book.id) { return local }
            throw error
        }
    }

    /// Insert a `Book` (as the active book), then build its roadmap. Roadmap
    /// generation routes through `app.ai` — `RemoteAIService` when a real backend
    /// + token are set, otherwise the on-device mock/direct service.
    @MainActor
    private func buildAndGenerate(from detail: CatalogBookDetail) async throws -> Book {
        let all = (try? context.fetch(FetchDescriptor<Book>())) ?? []
        for existing in all where existing.id != detail.id { existing.isActive = false }

        let book = bookFromDetail(detail, existing: all.first { $0.id == detail.id })
        if book.modelContext == nil { context.insert(book) }
        try? context.save()

        try await RoadmapGenerator.generate(for: book, profile: profile, app: app, context: context)
        return book
    }

    /// Map a catalog detail onto a `Book` (reusing an existing row with the same
    /// id so re-adding doesn't duplicate). Catalog books are tagged `.sample`.
    private func bookFromDetail(_ detail: CatalogBookDetail, existing: Book?) -> Book {
        let words = detail.wordCount > 0
            ? detail.wordCount
            : detail.text.split { $0 == " " || $0.isNewline }.count
        let minutes = detail.estimatedMinutes > 0 ? detail.estimatedMinutes : max(1, words / 200)

        if let book = existing {
            book.title = detail.title
            book.author = detail.author
            book.coverHue = detail.coverHue
            book.wordCount = words
            book.estimatedMinutes = minutes
            book.excerpt = detail.excerpt
            book.fullText = detail.text
            book.sourceKind = .sample
            book.sourceValue = "catalog:\(detail.id)"
            book.isActive = true
            return book
        }

        return Book(
            id: detail.id,
            title: detail.title,
            author: detail.author,
            coverHue: detail.coverHue,
            wordCount: words,
            estimatedMinutes: minutes,
            excerpt: detail.excerpt,
            fullText: detail.text,
            sourceKind: .sample,
            sourceValue: "catalog:\(detail.id)",
            isActive: true
        )
    }
}

// MARK: - Row

private struct CatalogRow: View {
    let book: CatalogBook
    let isCreating: Bool
    let isDisabled: Bool
    let onCreate: () -> Void

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: Metrics.pad) {
                BookCover(title: book.title, hue: book.coverHue, width: 60, height: 86)
                VStack(alignment: .leading, spacing: 6) {
                    Text(book.title)
                        .font(.headline)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(2)
                    if let author = book.author {
                        Text(author)
                            .font(.subheadline)
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                    }
                    if !book.excerpt.isEmpty {
                        Text(book.excerpt)
                            .font(.footnote)
                            .foregroundStyle(Palette.textTertiary)
                            .lineLimit(2)
                    }
                    if book.estimatedMinutes > 0 {
                        Tag("\(book.estimatedMinutes) min", systemImage: "clock", color: Palette.info)
                            .padding(.top, 2)
                    }

                    Button(action: onCreate) {
                        HStack(spacing: 6) {
                            if isCreating {
                                ProgressView().tint(Palette.onAccent)
                                Text("Designing…")
                            } else {
                                Image(systemName: "wand.and.stars")
                                Text("Create roadmap")
                            }
                        }
                    }
                    .buttonStyle(.mangoPrimary(enabled: !isCreating && !isDisabled))
                    .disabled(isCreating || isDisabled)
                    .padding(.top, 6)
                }
            }
        }
    }
}

#Preview {
    NavigationStack { CatalogView().mangoDestinations() }
        .environment(AppModel())
        .modelContainer(MangoModelContainer.preview())
}
