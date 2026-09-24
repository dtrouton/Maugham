import Foundation

/// Platform-agnostic snapshot of the OS's iCloud-share metadata for one
/// project folder. The Mac (`ICloudShareMetadataReader`) and the phone fill it
/// in through the one shared `FileURLShareMetadataReader`.
///
/// **An indicator, never a role** (signed op log P3c, Task 4). Until P3c the
/// WF1 share-role system folded this snapshot into an author/reviewer posture;
/// that system is retired — what a device may write is its permit's, asked
/// through `Posture`. What survives here is what the OS can honestly say: that
/// the folder is shared, who owns it, and whether iCloud lets this user write
/// into it at all. A read-only grant (`canWrite == false`) is an OS-level lock
/// the editor honours on its own, claiming no role.
///
/// - `isOwner` / `canWrite` are optional because the OS can report a share as
///   present (`isShared == true`) before the per-user role/permission keys are
///   populated. `nil` means "shared, but this facet not yet known".
public struct ShareMetadata: Equatable, Sendable {
    public let isShared: Bool
    /// `true` if the current user is the share owner, `false` if a participant,
    /// `nil` if the role hasn't been resolved yet. Meaningless when `!isShared`.
    public let isOwner: Bool?
    /// iCloud read-write (`true`) vs read-only (`false`); `nil` if unresolved.
    public let canWrite: Bool?
    public let ownerName: String?
    public let currentUserName: String?

    public init(
        isShared: Bool,
        isOwner: Bool?,
        canWrite: Bool?,
        ownerName: String?,
        currentUserName: String?
    ) {
        self.isShared = isShared
        self.isOwner = isOwner
        self.canWrite = canWrite
        self.ownerName = ownerName
        self.currentUserName = currentUserName
    }
}

/// Reads platform share metadata for a given on-disk location.
///
/// Returns `nil` when the metadata isn't available *yet* (still resolving).
/// Returns a value — possibly `isShared: false` — once the answer is known
/// (including "definitely not a share", i.e. a plain local project).
public protocol ShareMetadataReading: Sendable {
    func read(for url: URL) -> ShareMetadata?
}
