import Foundation

/// Distinguishes a Collection piece that's a loose document (with its own
/// folder + main doc + optional research/) from one that's a reference to
/// a standalone Maugham project elsewhere on disk.
public enum PieceKind: String, Codable, Equatable, Sendable {
    case loose
    case reference

    /// Cross-version forward-tolerance (ADR 0015): an unknown `pieceKind` from a
    /// newer build decodes to `.loose` rather than throwing and making the whole
    /// collection manifest unopenable. `.loose` is the benign default (a piece
    /// with its own folder + doc); consumers already group `.loose, .none`. The
    /// schemaVersion gate refuses a genuinely-newer-schema project up front.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PieceKind(rawValue: raw) ?? .loose
    }
}
