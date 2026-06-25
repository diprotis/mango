import Foundation
import SwiftData

@Model
final class Achievement {
    @Attribute(.unique) var key: String
    var title: String
    var detail: String
    var symbol: String
    var unlockedAt: Date?

    init(key: String, title: String, detail: String, symbol: String, unlockedAt: Date? = nil) {
        self.key = key
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.unlockedAt = unlockedAt
    }

    var isUnlocked: Bool { unlockedAt != nil }
}
