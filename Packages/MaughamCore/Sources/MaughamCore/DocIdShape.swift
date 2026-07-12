import Foundation

/// Shape contract for a minted document id: `<prefix>-<8 lowercase hex>`,
/// exactly what `ProjectStore.newId(prefix:)` (Mac-only; the minter itself
/// stays Mac-local by design) guarantees.
///
/// The phone never mints ids, but its op-log filename parsing and any
/// id-shaped literal in its tests must agree with the Mac's real output.
/// Before this type existed, `MaughamPhoneTests/OpLogFilenameContractTests`
/// hand-reproduced the shape as a literal — a Mac-side format change to
/// `newId` would not have failed the phone test (see
/// docs/superpowers/notes/2026-07-11-maintainability-review.md §2 E5(b)).
/// Both surfaces now assert against this single contract instead: the Mac
/// test checks `newId`'s real output against `isValid`; the phone test uses
/// `example`/`isValid` instead of a hand-typed literal.
public enum DocIdShape {
    /// `true` iff `id` is `<non-empty prefix>-<8 lowercase hex digits>`.
    public static func isValid(_ id: String) -> Bool {
        let parts = id.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let suffix = parts[1]
        guard suffix.count == 8 else { return false }
        return suffix.allSatisfy { "0123456789abcdef".contains($0) }
    }

    /// A golden example matching the shape — for tests that need a
    /// production-shaped doc id without minting a real one.
    public static let example = "doc-a1b2c3d4"
}
