import Foundation
import PDFKit

enum ConnectorError: LocalizedError {
    case invalidURL
    case emptyContent
    case pdfUnreadable
    case fetchFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "That doesn't look like a valid web address."
        case .emptyContent: return "We couldn't find readable text there."
        case .pdfUnreadable: return "This PDF has no extractable text (it may be scanned images)."
        case let .fetchFailed(message): return "Couldn't fetch that: \(message)"
        }
    }
}

/// The "connectors" layer — pluggable importers that turn a source (web URL,
/// Project Gutenberg id, pasted text, or a PDF) into a normalized `ParsedBook`.
/// Parsing runs on-device so the app works offline; the same shapes map 1:1 to
/// the backend's `/content/parse` endpoint for a server-side path later.
final class ConnectorService {
    private let backendBaseURL: String?

    init(settings: AppSettings) {
        self.backendBaseURL = settings.effectiveBackendURL?.absoluteString
    }

    // MARK: Web URL

    func importURL(_ urlString: String) async throws -> ParsedBook {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true else {
            throw ConnectorError.invalidURL
        }
        let html = try await fetchString(url)
        let text = HTMLText.extract(html)
        guard text.count >= 50 else { throw ConnectorError.emptyContent }
        let title = HTMLText.title(html, fallback: url.host ?? "Web Article")
        return makeBook(title: title, author: nil, text: text, kind: .url, value: trimmed)
    }

    // MARK: Project Gutenberg

    func importGutenberg(_ idOrURL: String) async throws -> ParsedBook {
        let digits = idOrURL.filter(\.isNumber)
        guard !digits.isEmpty, let url = URL(string: "https://www.gutenberg.org/cache/epub/\(digits)/pg\(digits).txt") else {
            throw ConnectorError.invalidURL
        }
        let text = try await fetchString(url)
        guard text.count >= 50 else { throw ConnectorError.emptyContent }
        let title = gutenbergTitle(in: text) ?? "Gutenberg #\(digits)"
        let author = gutenbergField("Author", in: text)
        return makeBook(title: title, author: author, text: text, kind: .gutenberg, value: digits)
    }

    // MARK: Pasted text

    func importText(_ text: String, title: String?) -> ParsedBook {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = title?.isEmpty == false
            ? title!
            : (trimmed.split(separator: "\n").first.map { String($0.prefix(80)) } ?? "Pasted Text")
        return makeBook(title: resolvedTitle, author: nil, text: trimmed, kind: .text, value: "")
    }

    // MARK: PDF

    func importPDF(data: Data, name: String) throws -> ParsedBook {
        guard let document = PDFDocument(data: data) else { throw ConnectorError.pdfUnreadable }
        var pieces: [String] = []
        for index in 0..<document.pageCount {
            if let page = document.page(at: index), let text = page.string {
                pieces.append(text)
            }
        }
        let text = pieces.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 50 else { throw ConnectorError.pdfUnreadable }
        let title = name.replacingOccurrences(of: ".pdf", with: "", options: .caseInsensitive)
        return makeBook(title: title, author: nil, text: text, kind: .pdf, value: name)
    }

    // MARK: Helpers

    private func makeBook(title: String, author: String?, text: String, kind: BookSourceKind, value: String) -> ParsedBook {
        let words = TextStats.wordCount(text)
        return ParsedBook(
            id: nil,
            title: String(title.prefix(200)),
            author: author,
            wordCount: words,
            estimatedMinutes: TextStats.estimatedMinutes(words: words),
            coverHue: TextStats.coverHue(title),
            excerpt: TextStats.excerpt(text),
            fullText: text,
            sourceKind: kind,
            sourceValue: value
        )
    }

    private func fetchString(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("MangoApp/0.1 (iOS reading companion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
        } catch {
            throw ConnectorError.fetchFailed(error.localizedDescription)
        }
    }

    private func gutenbergTitle(in text: String) -> String? {
        gutenbergField("Title", in: text)
    }

    private func gutenbergField(_ field: String, in text: String) -> String? {
        for line in text.prefix(3000).split(separator: "\n") {
            if line.hasPrefix("\(field): ") {
                return line.replacingOccurrences(of: "\(field): ", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
