import SwiftUI

struct AchievementBadgeView: View {
    let achievement: Achievement
    var size: CGFloat = 64

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(achievement.isUnlocked ? Palette.accent.opacity(0.16) : Palette.surfaceAlt)
                    .frame(width: size, height: size)
                Image(systemName: achievement.symbol)
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(achievement.isUnlocked ? Palette.accent : Palette.textTertiary)
            }
            Text(achievement.title)
                .font(.caption2)
                .foregroundStyle(achievement.isUnlocked ? Palette.textPrimary : Palette.textTertiary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .opacity(achievement.isUnlocked ? 1 : 0.65)
        .accessibilityLabel("\(achievement.title), \(achievement.isUnlocked ? "unlocked" : "locked")")
    }
}
