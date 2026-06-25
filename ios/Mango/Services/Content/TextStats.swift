import Foundation

/// Pure reading-stat helpers (mirrors the backend's text utilities).
enum TextStats {
    static func wordCount(_ text: String) -> Int {
        text.split { $0 == " " || $0.isNewline || $0 == "\t" }.count
    }

    static func estimatedMinutes(words: Int, wpm: Int = 200) -> Int {
        words > 0 ? max(1, Int((Double(words) / Double(wpm)).rounded())) : 1
    }

    /// Stable 0...360 hue derived from a seed (FNV-1a) — deterministic across runs.
    static func coverHue(_ seed: String) -> Double {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return Double(hash % 360)
    }

    static func excerpt(_ text: String, length: Int = 220) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > length ? String(flat.prefix(length)) + "…" : flat
    }
}
