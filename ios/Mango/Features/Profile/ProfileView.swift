import SwiftData
import SwiftUI

struct ProfileView: View {
    @Query private var profiles: [UserProfile]
    @Query(sort: \Achievement.key) private var achievements: [Achievement]
    @Query private var activity: [ActivityDay]
    @Query private var books: [Book]
    @State private var showingSettings = false

    private var profile: UserProfile? { profiles.first }
    private let badgeColumns = [GridItem(.adaptive(minimum: 84), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.padL) {
                if let profile {
                    levelCard(profile)
                    statsRow(profile)
                    weekStrip
                    achievementsSection
                }
            }
            .padding(Metrics.padL)
        }
        .mangoBackground()
        .navigationTitle("Profile")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
            }
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
    }

    private func levelCard(_ profile: UserProfile) -> some View {
        let progress = LevelCurve.progress(forXP: profile.totalXP)
        return Card {
            HStack(spacing: 18) {
                ZStack {
                    ProgressRing(progress: progress.fraction, size: 86, lineWidth: 11)
                    VStack(spacing: 0) {
                        Text("Lv").font(.caption2).foregroundStyle(Palette.textSecondary)
                        Text("\(progress.level)").font(.title.weight(.bold)).foregroundStyle(Palette.textPrimary)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(profile.name.isEmpty ? "Reader" : profile.name)
                        .font(Typo.title3).foregroundStyle(Palette.textPrimary)
                    Text(profile.levelTitle).font(.subheadline).foregroundStyle(Palette.accent)
                    XPBar(value: progress.into, goal: progress.needed)
                    Text("\(progress.into)/\(progress.needed) XP to level \(progress.level + 1)")
                        .font(.caption).foregroundStyle(Palette.textSecondary)
                }
            }
        }
    }

    private func statsRow(_ profile: UserProfile) -> some View {
        HStack(spacing: 12) {
            StatTile(value: "\(profile.totalXP)", label: "Total XP", symbol: "star.fill", tint: Palette.xp)
            StatTile(value: "\(profile.currentStreak)", label: "Day streak", symbol: "flame.fill", tint: Palette.streak)
            StatTile(value: "\(profile.longestStreak)", label: "Longest", symbol: "trophy.fill", tint: Palette.success)
            StatTile(value: "\(books.count)", label: "Books", symbol: "books.vertical.fill", tint: Palette.info)
        }
    }

    private var weekStrip: some View {
        let calendar = Calendar.current
        let activeDays = Set(activity.filter { $0.lessonsCompleted > 0 || $0.xpEarned > 0 }.map { calendar.startOfDay(for: $0.day) })
        let today = calendar.startOfDay(for: .now)
        let days = (0..<7).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }

        return Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("This week").font(.headline).foregroundStyle(Palette.textPrimary)
                HStack(spacing: 8) {
                    ForEach(days, id: \.self) { day in
                        let isActive = activeDays.contains(day)
                        VStack(spacing: 6) {
                            Text(shortWeekday(day)).font(.caption2).foregroundStyle(Palette.textSecondary)
                            ZStack {
                                Circle()
                                    .fill(isActive ? Palette.streak.opacity(0.2) : Palette.surfaceAlt)
                                    .frame(width: 34, height: 34)
                                Image(systemName: isActive ? "flame.fill" : "circle")
                                    .font(.footnote)
                                    .foregroundStyle(isActive ? Palette.streak : Palette.textTertiary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private var achievementsSection: some View {
        let unlockedCount = achievements.filter(\.isUnlocked).count
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Achievements").font(Typo.title3).foregroundStyle(Palette.textPrimary)
                Spacer()
                Text("\(unlockedCount)/\(achievements.count)").font(.subheadline).foregroundStyle(Palette.textSecondary)
            }
            LazyVGrid(columns: badgeColumns, spacing: 16) {
                ForEach(achievements) { AchievementBadgeView(achievement: $0) }
            }
        }
    }

    private func shortWeekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEEE"
        return formatter.string(from: date)
    }
}

private struct StatTile: View {
    let value: String
    let label: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(value).font(.headline).foregroundStyle(Palette.textPrimary)
            Text(label).font(.caption2).foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.border))
    }
}

#Preview {
    NavigationStack { ProfileView() }
        .environment(AppModel())
        .modelContainer(MangoModelContainer.preview())
}
