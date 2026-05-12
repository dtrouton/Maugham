import Foundation

/// One trashed item, recoverable via TrashStore.
public struct TrashEntry: Identifiable, Equatable, Sendable {
    public let id: String                  // Folder name: "YYYYMMDD-HHMMSS-originalId"
    public let trashedAt: Date
    public let originalRelativePath: String
    public let displayTitle: String
    public let itemMetadata: Data

    public init(
        id: String,
        trashedAt: Date,
        originalRelativePath: String,
        displayTitle: String,
        itemMetadata: Data
    ) {
        self.id = id
        self.trashedAt = trashedAt
        self.originalRelativePath = originalRelativePath
        self.displayTitle = displayTitle
        self.itemMetadata = itemMetadata
    }

    /// Days remaining before the 30-day sweep removes this entry.
    public var daysRemaining: Int {
        let elapsed = Date().timeIntervalSince(trashedAt)
        let daysElapsed = Int(elapsed / 86_400)
        return max(0, 30 - daysElapsed)
    }
}
