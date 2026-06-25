import SwiftUI

// MARK: - Buttons

struct MangoPrimaryButtonStyle: ButtonStyle {
    var enabled: Bool = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                (enabled ? Palette.accent : Palette.textTertiary)
                    .opacity(configuration.isPressed ? 0.85 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct MangoSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Palette.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Palette.border, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension ButtonStyle where Self == MangoPrimaryButtonStyle {
    static var mangoPrimary: MangoPrimaryButtonStyle { .init() }
    static func mangoPrimary(enabled: Bool) -> MangoPrimaryButtonStyle { .init(enabled: enabled) }
}

extension ButtonStyle where Self == MangoSecondaryButtonStyle {
    static var mangoSecondary: MangoSecondaryButtonStyle { .init() }
}

// MARK: - Card

struct Card<Content: View>: View {
    var padding: CGFloat = Metrics.pad
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                    .strokeBorder(Palette.border, lineWidth: Metrics.hairline)
            )
    }
}

// MARK: - Tag / Pill

struct Tag: View {
    var text: String
    var systemImage: String?
    var color: Color = Palette.accent

    init(_ text: String, systemImage: String? = nil, color: Color = Palette.accent) {
        self.text = text
        self.systemImage = systemImage
        self.color = color
    }

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.14))
        .clipShape(Capsule())
    }
}

// MARK: - Progress ring

struct ProgressRing: View {
    var progress: Double
    var size: CGFloat = 64
    var lineWidth: CGFloat = 9
    var tint: Color = Palette.accent

    var body: some View {
        ZStack {
            Circle().stroke(Palette.surfaceAlt, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.0001, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.5, dampingFraction: 0.85), value: progress)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - XP bar

struct XPBar: View {
    var value: Int
    var goal: Int
    var tint: Color = Palette.xp
    var height: CGFloat = 10

    private var fraction: CGFloat {
        guard goal > 0 else { return 0 }
        return CGFloat(min(value, goal)) / CGFloat(goal)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.surfaceAlt)
                Capsule().fill(tint).frame(width: geo.size.width * fraction)
                    .animation(.spring(response: 0.5, dampingFraction: 0.8), value: fraction)
            }
        }
        .frame(height: height)
    }
}

// MARK: - Streak pill

struct StreakPill: View {
    var days: Int
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "flame.fill").foregroundStyle(Palette.streak)
            Text("\(days)").font(.subheadline.weight(.bold)).foregroundStyle(Palette.textPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Palette.streak.opacity(0.14))
        .clipShape(Capsule())
        .accessibilityLabel("\(days) day streak")
    }
}

// MARK: - Section header

struct SectionHeader: View {
    var title: String
    var action: (() -> Void)?
    var actionLabel: String?

    init(_ title: String, actionLabel: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.actionLabel = actionLabel
        self.action = action
    }

    var body: some View {
        HStack {
            Text(title).font(Typo.title3).foregroundStyle(Palette.textPrimary)
            Spacer()
            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.accent)
            }
        }
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    var systemImage: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 38))
                .foregroundStyle(Palette.accent)
            Text(title).font(Typo.title3).foregroundStyle(Palette.textPrimary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - Book cover (generated from a hue, no image assets needed)

struct BookCover: View {
    var title: String
    var hue: Double
    var width: CGFloat = 64
    var height: CGFloat = 92

    private var base: Color { Color(hue: hue / 360, saturation: 0.45, brightness: 0.7) }

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [base, base.opacity(0.78)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .overlay(alignment: .topLeading) {
                Text(title)
                    .font(.system(size: 9, weight: .bold, design: .serif))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(3)
                    .padding(7)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.15), lineWidth: 1)
            )
            .frame(width: width, height: height)
            .shadow(color: .black.opacity(0.12), radius: 5, x: 0, y: 3)
    }
}
