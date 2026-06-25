import SwiftUI

/// Mango's visual language — warm, calm, and Claude-like: cream surfaces, a
/// terracotta accent, generous whitespace, soft rounded cards with hairline
/// borders (not heavy shadows). All semantic colors adapt to light/dark and are
/// chosen for AA contrast. This is the ONLY place raw hex lives.
enum Palette {
    // Brand
    static let terracotta = Color(hex: "#D97757")
    static let terracottaDeep = Color(hex: "#C15F3C")

    // Adaptive surfaces
    static let background = Color(light: Color(hex: "#FAF9F5"), dark: Color(hex: "#1A1A18"))
    static let surface = Color(light: Color(hex: "#FFFFFF"), dark: Color(hex: "#262624"))
    static let surfaceAlt = Color(light: Color(hex: "#F1F0E9"), dark: Color(hex: "#302F2C"))

    // Text
    static let textPrimary = Color(light: Color(hex: "#1F1E1D"), dark: Color(hex: "#ECEAE3"))
    static let textSecondary = Color(light: Color(hex: "#6B6A64"), dark: Color(hex: "#A8A69D"))
    static let textTertiary = Color(light: Color(hex: "#8A887F"), dark: Color(hex: "#74726B"))

    // Lines
    static let border = Color(light: Color(hex: "#E7E5DB"), dark: Color(hex: "#3A3A36"))

    // Accent + the readable color placed on it
    static let accent = terracotta
    static let accentPressed = terracottaDeep
    static let onAccent = Color.white

    // Semantics (kept colorblind-distinguishable; always paired with an icon or label)
    static let success = Color(light: Color(hex: "#5F7345"), dark: Color(hex: "#9CB37A"))
    static let info = Color(light: Color(hex: "#4F7CA8"), dark: Color(hex: "#8FB4D9"))
    static let warning = Color(light: Color(hex: "#B5832F"), dark: Color(hex: "#E0B25E"))
    static let danger = Color(light: Color(hex: "#A93F30"), dark: Color(hex: "#D98373"))

    // Gamification
    static let streak = Color(hex: "#E8835A")
    static let xp = Color(light: Color(hex: "#B5832F"), dark: Color(hex: "#E0B25E"))

    // Elevation (used sparingly — Mango prefers hairline borders)
    static let shadow = Color(light: Color(hex: "#1F1E1D").opacity(0.12), dark: Color(hex: "#000000").opacity(0.5))
}

/// Spacing, radius, and line tokens.
enum Metrics {
    static let pad: CGFloat = 16
    static let padL: CGFloat = 24
    static let gap: CGFloat = 12
    static let radius: CGFloat = 18
    static let radiusButton: CGFloat = 14
    static let radiusSmall: CGFloat = 12
    static let radiusXS: CGFloat = 8
    static let radiusPill: CGFloat = 999
    static let hairline: CGFloat = 1
}

extension View {
    /// Standard Mango screen background.
    func mangoBackground() -> some View {
        background(Palette.background.ignoresSafeArea())
    }
}
