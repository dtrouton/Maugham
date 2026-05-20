import Foundation

/// Where the Rewind modal's scrub cursor currently sits in the op log.
///
/// `.now` and `.atOp(latestOpId, latestDate)` are not equivalent:
/// - `.now` means "writer hasn't scrubbed yet" — the modal opens in this state.
/// - `.atOp(id, _)` means "writer scrubbed to op `id` and chose to land there",
///   even if `id` happens to be the latest op. The action footer changes its
///   behaviour based on this distinction — Restore is disabled on `.now` but
///   enabled on `.atOp(latestOpId, _)` (where it's a no-op restore).
public enum RewindCursor: Equatable, Sendable {
    case now
    case atOp(opId: String, at: Date)
}
