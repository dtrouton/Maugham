import Foundation

/// One trashed item, recoverable via TrashStore.
public struct TrashEntry: Identifiable, Equatable, Sendable {
    public let id: String                  // Folder name: "YYYYMMDD-HHMMSS-originalId"
    public let trashedAt: Date
    public let originalRelativePath: String
    public let displayTitle: String
    public let itemMetadata: Data

    /// The manifest id of the parent node (group or nil = root) at the time of
    /// deletion. Used by `ProjectStore.restoreTrashEntry` to re-insert the item
    /// at its original position rather than appending to root (finding 1.8).
    public let originalParentId: String?

    /// The index within the parent's children (or root) at the time of deletion.
    /// `restoreTrashEntry` clamps this to the current child count on restore.
    public let originalIndex: Int

    /// What this is a deletion OF, as recorded at delete time. `nil` for an
    /// entry written before the field existed — the readers fall back to
    /// sniffing the metadata's shape for those. See `TrashSubject`.
    public let subject: TrashSubject?

    /// False for a manifest-only entry (a research link, RULING-45): the
    /// entry folder holds a `meta.json` and no file, by design.
    public let carriesFile: Bool

    /// Where the file actually landed, project-relative. Set only on the entry
    /// returned by `TrashStore.restore` — it differs from
    /// `originalRelativePath` when the restore had to land beside an occupant
    /// (RULING-38) or follow the binder to a new parent (RULING-41), and it is
    /// nil for a manifest-only entry, which puts no file anywhere.
    public let restoredRelativePath: String?

    public init(
        id: String,
        trashedAt: Date,
        originalRelativePath: String,
        displayTitle: String,
        itemMetadata: Data,
        originalParentId: String? = nil,
        originalIndex: Int = 0,
        subject: TrashSubject? = nil,
        carriesFile: Bool = true,
        restoredRelativePath: String? = nil
    ) {
        self.id = id
        self.trashedAt = trashedAt
        self.originalRelativePath = originalRelativePath
        self.displayTitle = displayTitle
        self.itemMetadata = itemMetadata
        self.originalParentId = originalParentId
        self.originalIndex = originalIndex
        self.subject = subject
        self.carriesFile = carriesFile
        self.restoredRelativePath = restoredRelativePath
    }

    /// Days remaining before the 30-day sweep removes this entry.
    public var daysRemaining: Int {
        let elapsed = Date().timeIntervalSince(trashedAt)
        let daysElapsed = Int(elapsed / 86_400)
        return max(0, 30 - daysElapsed)
    }
}
