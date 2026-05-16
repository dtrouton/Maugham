import Foundation

/// Distinguishes a Collection piece that's a loose document (with its own
/// folder + main doc + optional research/) from one that's a reference to
/// a standalone Maugham project elsewhere on disk.
public enum PieceKind: String, Codable, Equatable, Sendable {
    case loose
    case reference
}
