import Foundation

/// Typed replacement for the prior `String?` field on `Op.Provenance`.
/// The raw values are the snake_case strings used on disk; existing op
/// logs decode without migration via RawRepresentable Codable.
///
/// `rewind` is new in milestone-history-rewind; the other three predate it.
public enum SynthesisSource: String, Codable, Equatable, Hashable, Sendable {
    case paragraphDeleted = "paragraph_deleted"
    case diskAtIngest = "disk_at_ingest"
    case useCloudResolution = "use_cloud_resolution"
    case rewind

    /// Cross-version forward-tolerance (ADR 0014): a synthesis source written
    /// by a newer build decodes to `.unknown` rather than throwing — which
    /// would quarantine the whole `Op` and silently drop the edits it carries.
    /// `synthesisSource` is forensic/provenance metadata (consumed only by the
    /// HistoryPane display, which already has `default:` arms), so an unknown
    /// cause degrades to a generic label, never to data loss.
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SynthesisSource(rawValue: raw) ?? .unknown
    }
}
