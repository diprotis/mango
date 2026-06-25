import Foundation

/// Lightweight, dependency-free HTML → readable-text extraction.
enum HTMLText {
    static func extract(_ html: String) -> String {
        var text = html
        text = replace(text, pattern: "<(script|style)[^>]*>[\\s\\S]*?</\\1>", with: " ")
        text = replace(text, pattern: "<br\\s*/?>", with: "\n")
        text = replace(text, pattern: "</(p|div|h[1-6]|li)>", with: "\n\n")
        text = replace(text, pattern: "<[^>]+>", with: " ")
        text = unescape(text)
        text = replace(text, pattern: "[ \\t\\x0B\\f\\r]+", with: " ")
        text = replace(text, pattern: "\\n{3,}", with: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func title(_ html: String, fallback: String) -> String {
        if let range = html.range(of: "<title[^>]*>[\\s\\S]*?</title>", options: .regularExpression) {
            let raw = String(html[range])
            let inner = replace(raw, pattern: "<[^>]+>", with: "")
            let cleaned = unescape(inner).trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { return cleaned }
        }
        return fallback
    }

    private static func replace(_ text: String, pattern: String, with replacement: String) -> String {
        text.replacingOccurrences(
            of: pattern,
            with: replacement,
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private static func unescape(_ text: String) -> String {
        var result = text
        let entities = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&mdash;": "—",
            "&ndash;": "–", "&hellip;": "…", "&rsquo;": "’", "&lsquo;": "‘",
            "&ldquo;": "“", "&rdquo;": "”",
        ]
        for (entity, value) in entities {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        return result
    }
}
