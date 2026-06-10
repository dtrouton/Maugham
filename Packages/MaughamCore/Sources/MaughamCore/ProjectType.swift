import Foundation

/// One of the four first-class writing forms supported by Maugham.
/// Raw values are stable snake_case strings used as the `type` field
/// in `project.maugham.json`. Never rename these.
public enum ProjectType: String, Codable, CaseIterable, Equatable, Sendable {
    case shortStory = "short_story"
    case novel = "novel"
    case screenplay = "screenplay"
    case collection = "collection"

    /// Cross-version forward-tolerance (ADR 0015). A `type` written by a newer
    /// Maugham decodes here instead of throwing — which, because the whole
    /// `project.maugham.json` is one JSON object (no per-line quarantine), would
    /// otherwise make the WHOLE project unopenable on the older build. Paired
    /// with the manifest `schemaVersion` gate (`ProjectManifest.load`): a
    /// genuinely newer-schema project is REFUSED up front, so `.unknown` only
    /// arises for a same-schema file carrying an unexpected value — graceful
    /// degradation of one project, not a brick. Excluded from `allCases` so it
    /// never appears in pickers.
    ///
    /// SCHEMA CONTRACT (ADR 0015, audit N4): **adding a case ⇒ bump
    /// `ProjectManifest.currentSchemaVersion`.** `decodeGuardingSchema` is the
    /// real protection; this tolerance is the within-version net. `.unknown`
    /// re-encodes LOSSILY as the literal `"unknown"` — and the manifest IS
    /// rewritten on every structural edit, so without the bump an old build that
    /// opened a newer manifest could permanently degrade its `type` on the next
    /// save. The schemaVersion gate is what prevents that.
    case unknown

    public static var allCases: [ProjectType] {
        [.shortStory, .novel, .screenplay, .collection]
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ProjectType(rawValue: raw) ?? .unknown
    }
}
