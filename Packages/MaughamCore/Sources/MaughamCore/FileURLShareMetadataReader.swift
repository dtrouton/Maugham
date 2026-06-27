import Foundation

/// Shared `ShareMetadataReading` backed by the OS's iCloud-Drive share resource
/// keys. Reads the documented `URLResourceKey`s on a project folder URL and
/// folds them into a platform-agnostic `ShareMetadata` for `ShareIdentityMapper`.
///
/// The `URLResourceKey` family used here is available on BOTH macOS and iOS, so
/// this single implementation is the source of truth for share-metadata reading
/// on every surface — the Mac (`Maugham`) and the phone (`MaughamPhone`) both
/// consume it directly rather than re-implementing the key reads. Keeping one
/// reader avoids the cross-surface divergence the contract registry warns about.
///
/// Keys read (Swift-bridged spellings, confirmed against the SDK):
///   - `.ubiquitousItemIsSharedKey`                    (Bool)
///   - `.ubiquitousSharedItemCurrentUserRoleKey`       → `URLUbiquitousSharedItemRole`
///   - `.ubiquitousSharedItemCurrentUserPermissionsKey`→ `URLUbiquitousSharedItemPermissions`
///   - `.ubiquitousSharedItemOwnerNameComponentsKey`   → `PersonNameComponents`
///   - `.ubiquitousSharedItemMostRecentEditorNameComponentsKey` → `PersonNameComponents`
///
/// nil-vs-not-shared rule:
///   - Resource read throws, or the keys are simply absent (a plain local /
///     non-iCloud path) → `ShareMetadata(isShared: false, …)`. A non-shared
///     item is a *known* answer (the writer's own copy), so the mapper yields
///     `.author`, NOT `.unknown`.
///   - We only return `nil` (→ mapper `.unknown`, "still resolving") when the
///     item reports itself shared (`isShared == true`) but the per-user role
///     key hasn't been populated yet. That is the genuine "I can't tell yet"
///     case that should read as "Checking…" in the UI.
///
/// This reader is intentionally read-only and side-effect-free: it does a
/// single `resourceValues(forKeys:)`. Callers must NOT poll it per-render —
/// resource reads can lag on a freshly-mounted ubiquitous item.
public struct FileURLShareMetadataReader: ShareMetadataReading {

    public init() {}

    private static let keys: Set<URLResourceKey> = [
        .ubiquitousItemIsSharedKey,
        .ubiquitousSharedItemCurrentUserRoleKey,
        .ubiquitousSharedItemCurrentUserPermissionsKey,
        .ubiquitousSharedItemOwnerNameComponentsKey,
        .ubiquitousSharedItemMostRecentEditorNameComponentsKey,
    ]

    public func read(for url: URL) -> ShareMetadata? {
        // A throw here means the keys aren't supported on this path (a plain
        // local folder, an unmounted volume, etc.) → treat as "not shared".
        guard let values = try? url.resourceValues(forKeys: Self.keys) else {
            return ShareMetadata(
                isShared: false, isOwner: nil, canWrite: nil,
                ownerName: nil, currentUserName: nil)
        }

        let isShared = values.ubiquitousItemIsShared ?? false

        guard isShared else {
            return ShareMetadata(
                isShared: false, isOwner: nil, canWrite: nil,
                ownerName: nil, currentUserName: nil)
        }

        let role = values.ubiquitousSharedItemCurrentUserRole

        // Shared, but the role key hasn't populated → genuinely still resolving.
        guard let role else { return nil }

        let isOwner = (role == .owner)

        let canWrite: Bool?
        switch values.ubiquitousSharedItemCurrentUserPermissions {
        case .some(.readWrite): canWrite = true
        case .some(.readOnly):  canWrite = false
        default:                canWrite = nil   // unresolved → mapper defaults to true
        }

        // `ownerNameComponents` is nil when the current user IS the owner, so it
        // doubles as the "shared by X" name only for participants.
        let ownerName = Self.formatted(values.ubiquitousSharedItemOwnerNameComponents)

        // No OS key gives the signed-in user's own name directly; the most-recent
        // editor key is nil when the current user is that editor. We leave
        // currentUserName nil here — callers fall back to the user's configured
        // collaborator display name for provenance/UI.
        return ShareMetadata(
            isShared: true,
            isOwner: isOwner,
            canWrite: canWrite,
            ownerName: ownerName,
            currentUserName: nil)
    }

    private static let nameFormatter = PersonNameComponentsFormatter()

    private static func formatted(_ components: PersonNameComponents?) -> String? {
        guard let components else { return nil }
        let s = nameFormatter.string(from: components)
        return s.isEmpty ? nil : s
    }
}
