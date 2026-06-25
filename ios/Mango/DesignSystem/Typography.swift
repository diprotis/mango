import SwiftUI

/// Type tokens. Serif (New York) for display/titles to echo Claude's editorial
/// feel; SF Pro for UI and body. All relative to Dynamic Type text styles so the
/// app scales with the user's accessibility settings.
enum Typo {
    static let display = Font.system(.largeTitle, design: .serif).weight(.bold)
    static let title = Font.system(.title, design: .serif).weight(.semibold)
    static let title2 = Font.system(.title2, design: .serif).weight(.semibold)
    static let title3 = Font.system(.title3, design: .serif).weight(.semibold)
    static let headline = Font.system(.headline)
    static let body = Font.system(.body)
    static let bodyEmphasis = Font.system(.body).weight(.semibold)
    static let callout = Font.system(.callout)
    static let subheadline = Font.system(.subheadline)
    static let footnote = Font.system(.footnote)
    static let caption = Font.system(.caption)
}
