import Foundation

/// Scope of a rewind action. v1 only ships `.thisDoc`; the single-case
/// shape is deliberate — when `.project` lands in v2, every consumer
/// that switches over RewindScope becomes a compile error and we don't
/// miss a code path.
///
/// Why not a Bool: `isProjectScope: Bool` lacks the exhaustive-switch
/// guarantee. Why not omit entirely: callers would need to add the
/// distinction later under time pressure; the enum makes the shape
/// explicit from day one.
internal enum RewindScope: Equatable, Sendable {
    case thisDoc
    // case project — v2
}
