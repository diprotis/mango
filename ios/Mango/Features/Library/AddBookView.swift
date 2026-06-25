import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct AddBookView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AppModel.self) private var app
    @Query private var profiles: [UserProfile]

    enum Kind: String, CaseIterable, Identifiable {
        case url = "Web URL"
        case gutenberg = "Gutenberg"
        case text = "Paste"
        case pdf = "PDF"
        var id: String { rawValue }
    }

    @State private var kind: Kind = .url
    @State private var urlText = ""
    @State private var gutenbergText = ""
    @State private var pasteTitle = ""
    @State private var pasteText = ""
    @State private var working: String?
    @State private var errorMessage: String?
    @State private var showImporter = false

    private var profile: UserProfile? { profiles.first }
    private var isBusy: Bool { working != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.padL) {
                    Picker("Source", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    inputs

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(Palette.danger)
                    }

                    Button { start() } label: {
                        if let working {
                            HStack { ProgressView().tint(Palette.onAccent); Text(working) }
                        } else {
                            Label("Add & build journey", systemImage: "wand.and.stars")
                        }
                    }
                    .buttonStyle(.mangoPrimary(enabled: canSubmit && !isBusy))
                    .disabled(!canSubmit || isBusy)

                    Text("Mango fetches the text, then designs a gamified roadmap of lessons and exercises. Import material you have the rights to read.")
                        .font(.caption).foregroundStyle(Palette.textTertiary)
                }
                .padding(Metrics.padL)
            }
            .mangoBackground()
            .navigationTitle("Add a book")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isBusy)
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [UTType.pdf]) { result in
                handlePDF(result)
            }
        }
        .interactiveDismissDisabled(isBusy)
    }

    @ViewBuilder
    private var inputs: some View {
        switch kind {
        case .url:
            field("Article or book URL", text: $urlText, prompt: "https://…", keyboard: .URL)
        case .gutenberg:
            VStack(alignment: .leading, spacing: 8) {
                field("Project Gutenberg id or URL", text: $gutenbergText, prompt: "e.g. 1080 or gutenberg.org/ebooks/1080")
                Text("Find free public-domain books at gutenberg.org.")
                    .font(.caption).foregroundStyle(Palette.textTertiary)
            }
        case .text:
            VStack(alignment: .leading, spacing: 12) {
                field("Title (optional)", text: $pasteTitle, prompt: "Title")
                VStack(alignment: .leading, spacing: 6) {
                    Text("Text").font(.subheadline.weight(.medium)).foregroundStyle(Palette.textSecondary)
                    TextEditor(text: $pasteText)
                        .frame(minHeight: 180)
                        .padding(8)
                        .scrollContentBackground(.hidden)
                        .background(Palette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.border))
                }
            }
        case .pdf:
            Button { showImporter = true } label: {
                Label("Choose a PDF", systemImage: "doc.fill")
            }
            .buttonStyle(.mangoSecondary)
        }
    }

    private func field(_ title: String, text: Binding<String>, prompt: String, keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Palette.textSecondary)
            TextField(prompt, text: text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(14)
                .background(Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.border))
        }
    }

    private var canSubmit: Bool {
        switch kind {
        case .url: return !urlText.trimmingCharacters(in: .whitespaces).isEmpty
        case .gutenberg: return gutenbergText.contains(where: \.isNumber)
        case .text: return pasteText.trimmingCharacters(in: .whitespaces).count > 40
        case .pdf: return true
        }
    }

    private func start() {
        guard kind != .pdf else { showImporter = true; return }
        errorMessage = nil
        Task {
            do {
                working = "Fetching…"
                let parsed: ParsedBook
                switch kind {
                case .url: parsed = try await app.connectors.importURL(urlText)
                case .gutenberg: parsed = try await app.connectors.importGutenberg(gutenbergText)
                case .text: parsed = app.connectors.importText(pasteText, title: pasteTitle.isEmpty ? nil : pasteTitle)
                case .pdf: return
                }
                try await finish(with: parsed)
            } catch {
                fail(error)
            }
        }
    }

    private func handlePDF(_ result: Result<URL, Error>) {
        switch result {
        case let .success(url):
            Task {
                do {
                    working = "Reading PDF…"
                    guard url.startAccessingSecurityScopedResource() else { throw ConnectorError.pdfUnreadable }
                    defer { url.stopAccessingSecurityScopedResource() }
                    let data = try Data(contentsOf: url)
                    let parsed = try app.connectors.importPDF(data: data, name: url.lastPathComponent)
                    try await finish(with: parsed)
                } catch {
                    fail(error)
                }
            }
        case let .failure(error):
            fail(error)
        }
    }

    @MainActor
    private func finish(with parsed: ParsedBook) async throws {
        let all = (try? context.fetch(FetchDescriptor<Book>())) ?? []
        for book in all { book.isActive = false }

        let book = Book(
            id: parsed.id ?? UUID().uuidString,
            title: parsed.title,
            author: parsed.author,
            coverHue: parsed.coverHue,
            wordCount: parsed.wordCount,
            estimatedMinutes: parsed.estimatedMinutes,
            excerpt: parsed.excerpt,
            fullText: parsed.fullText,
            sourceKind: parsed.sourceKind,
            sourceValue: parsed.sourceValue,
            isActive: true
        )
        context.insert(book)
        try? context.save()

        working = "Designing your journey…"
        try? await RoadmapGenerator.generate(for: book, profile: profile, app: app, context: context)
        Haptics.success()
        working = nil
        dismiss()
    }

    private func fail(_ error: Error) {
        working = nil
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        Haptics.warning()
    }
}

#Preview {
    AddBookView()
        .environment(AppModel())
        .modelContainer(MangoModelContainer.preview())
}
