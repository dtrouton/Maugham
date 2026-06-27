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
    /// `true` when this project is an iCloud Collaborate share (owned or
    /// participated-in). `false` for the writer's own unshared copy and for the
    /// still-resolving `.unknown` case. Lets consumers distinguish "owns a
    /// share" from "own unshared copy" without reaching for the raw
    /// `ShareMetadata`.
    public let isShared: Bool
    /// `true` only when this is a share the current user OWNS. Implies
    /// `isShared`. `false` for a participant, an unshared copy, or unknown.
    public let isOwner: Bool

    public init(
        role: CollaborationRole,
        currentUserName: String?,
        ownerName: String?,
        canWrite: Bool,
        isShared: Bool,
        isOwner: Bool
    ) {
        self.role = role
        self.currentUserName = currentUserName
        self.ownerName = ownerName
        self.canWrite = canWrite
        self.isShared = isShared
        self.isOwner = isOwner
    }

    /// The author predicate: only an `.author` may mutate the manuscript text.
    /// Reviewers (and the still-resolving `.unknown` posture) cannot.
    public var canEditManuscript: Bool { role == .author }
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
                canWrite: false, isShared: false, isOwner: false)
        }

        // Not shared → the writer's own copy. Author, fully writable.
        if !meta.isShared {
            return Collaborator(
                role: .author, currentUserName: meta.currentUserName,
                ownerName: nil, canWrite: true,
                isShared: false, isOwner: false)
        }

        // Shared. Owner → author; participant (or role-not-yet-known) → reviewer.
        let isOwner = meta.isOwner ?? false
        return Collaborator(
            role: isOwner ? .author : .reviewer,
            currentUserName: meta.currentUserName,
            ownerName: meta.ownerName,
            // iCloud's default grant on a Collaborate share is read-write;
            // absent an explicit read-only signal we don't lock the user out.
            canWrite: meta.canWrite ?? true,
            isShared: true,
            isOwner: isOwner)
    }
}

/// Pure decision: given the resolved collaboration `role` and whether the user
/// has manually entered review (⌘⌥R), what is the effective review posture?
///
/// This sits ABOVE the low-level `EditorEditPolicy` membrane (Mac-side). It
/// answers two questions:
///   - `isReviewMode`: should the review RENDER be shown (marks + rail +
///     focus/typewriter suppressed)?
///   - `lockEditing`: must manuscript text mutation be HARD-blocked regardless
///     of the manual toggle — i.e. the user is not an author?
///
/// `lockEditing` is the safety floor: for a `.reviewer` or the still-resolving
/// `.unknown` posture it is always `true`, so even if the manual review render
/// is toggled off, the membrane keeps the manuscript read-only. Only an
/// `.author` can ever have `lockEditing == false`.
public enum ReviewPosturePolicy {

    public struct Effective: Equatable, Sendable {
        /// Whether the crafted review render is shown.
        public let isReviewMode: Bool
        /// Whether manuscript text mutation is hard-blocked (non-author).
        public let lockEditing: Bool

        public init(isReviewMode: Bool, lockEditing: Bool) {
            self.isReviewMode = isReviewMode
            self.lockEditing = lockEditing
        }
    }

    /// - `.author`   + not-manual → editable (no review render, no lock).
    /// - `.author`   + manual     → review render on; still no lock (they may
    ///                              leave review and edit).
    /// - `.reviewer`              → review render FORCED on, editing LOCKED,
    ///                              regardless of the manual toggle.
    /// - `.unknown`               → cautious: review render on + LOCKED until the
    ///                              real role resolves (don't flash author
    ///                              affordances, then yank them).
    public static func effective(
        role: CollaborationRole,
        manualReview: Bool
    ) -> Effective {
        switch role {
        case .author:
            return Effective(isReviewMode: manualReview, lockEditing: false)
        case .reviewer:
            return Effective(isReviewMode: true, lockEditing: true)
        case .unknown:
            return Effective(isReviewMode: true, lockEditing: true)
        }
    }
}
