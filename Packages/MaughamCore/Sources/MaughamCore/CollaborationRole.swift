import Foundation

/// The reviewer-vs-author posture of the current user for a given project, as
/// derived from the operating system's iCloud-share metadata.
///
/// This is the gating type for real multi-person review: the editor membrane
/// (a later task) consults the resolved `Collaborator.role` to decide whether
/// the writing surface is the manuscript author's (full edit) or a participant
/// reviewer's (annotation-only) posture. `.unknown` means the OS metadata is
/// still resolving — callers should treat it as "not yet known", never as a
/// licence to write.
public enum CollaborationRole: String, Equatable, Sendable {
    /// The owner of the manuscript (or a writer working on their own,
    /// unshared copy). Full edit authority.
    case author
    /// A participant on someone else's shared manuscript. Review posture.
    case reviewer
    /// The OS share metadata isn't available yet (still resolving).
    case unknown
}

/// The resolved collaboration identity for the current user against one project.
///
/// `currentUserName` / `ownerName` are carried for provenance (annotation
/// authorship later) and "shared by X" UI. `canWrite` reflects iCloud's
/// read-write vs read-only grant — distinct from `role`: a participant may have
/// read-write at the iCloud layer while Maugham still posts them in a reviewer
/// posture.
public struct Collaborator: Equatable, Sendable {
    public let role: CollaborationRole
    /// The signed-in user's display name, if the OS exposed it. For provenance.
    public let currentUserName: String?
    /// The share owner's display name, if known. For "shared by X" UI.
    public let ownerName: String?
    /// iCloud read-write (`true`) vs read-only (`false`) grant.
    public let canWrite: Bool

    public init(
        role: CollaborationRole,
        currentUserName: String?,
        ownerName: String?,
        canWrite: Bool
    ) {
        self.role = role
        self.currentUserName = currentUserName
        self.ownerName = ownerName
        self.canWrite = canWrite
    }
}

/// Platform-agnostic snapshot of the OS share metadata. The Mac
/// (`ICloudShareMetadataReader`) and, later, the phone fill this in from their
/// respective platform APIs; the mapper below is pure and shared.
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
/// Returns `nil` when the metadata isn't available *yet* (still resolving) so
/// the mapper yields `.unknown`. Returns a value — possibly `isShared: false` —
/// once the answer is known (including "definitely not a share", i.e. a plain
/// local project = the writer's own copy).
public protocol ShareMetadataReading: Sendable {
    func read(for url: URL) -> ShareMetadata?
}

/// Pure mapping from raw OS share metadata to a `Collaborator` posture.
public enum ShareIdentityMapper {

    public static func resolve(_ meta: ShareMetadata?) -> Collaborator {
        // Still resolving → unknown, never write-presumptive.
        guard let meta else {
            return Collaborator(
                role: .unknown, currentUserName: nil, ownerName: nil,
                canWrite: false)
        }

        // Not shared → the writer's own copy. Author, fully writable.
        if !meta.isShared {
            return Collaborator(
                role: .author, currentUserName: meta.currentUserName,
                ownerName: nil, canWrite: true)
        }

        // Shared. Owner → author; participant (or role-not-yet-known) → reviewer.
        let isOwner = meta.isOwner ?? false
        return Collaborator(
            role: isOwner ? .author : .reviewer,
            currentUserName: meta.currentUserName,
            ownerName: meta.ownerName,
            // iCloud's default grant on a Collaborate share is read-write;
            // absent an explicit read-only signal we don't lock the user out.
            canWrite: meta.canWrite ?? true)
    }
}
