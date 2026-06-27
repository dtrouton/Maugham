import Foundation

/// Pure decision: can a project folder be offered to iCloud Collaborate sharing,
/// and if not, why? Used by the Mac "Share for Review…" command to choose
/// between presenting the share sheet and showing the move-to-iCloud explanation.
///
/// The decision is split from the OS probe so it stays unit-testable: the caller
/// supplies whether the folder lives in iCloud Drive (a ubiquity check) and the
/// already-resolved `ShareMetadata` snapshot; this enum folds them into an
/// outcome.
public enum ProjectShareEligibility {

    public enum Outcome: Equatable, Sendable {
        /// In iCloud Drive — present the Collaborate share sheet. `alreadyShared`
        /// is `true` when the project is already a share the user can manage.
        case shareable(alreadyShared: Bool)
        /// Not in iCloud Drive — can't be Collaborate-shared. Show the
        /// move-to-iCloud explanation instead of failing silently.
        case notInICloud
    }

    /// - Parameters:
    ///   - isInICloudDrive: whether the project folder is a ubiquitous (iCloud
    ///     Drive) item. A non-ubiquitous folder cannot be Collaborate-shared.
    ///   - metadata: the resolved share snapshot (may be `nil` if unresolved).
    ///     Used only to report whether an in-iCloud project is already shared.
    public static func evaluate(
        isInICloudDrive: Bool,
        metadata: ShareMetadata?
    ) -> Outcome {
        guard isInICloudDrive else { return .notInICloud }
        return .shareable(alreadyShared: metadata?.isShared ?? false)
    }
}
