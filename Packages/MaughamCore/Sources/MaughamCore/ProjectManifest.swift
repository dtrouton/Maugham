import Foundation

/// The root of a `project.maugham.json` manifest file.
///
/// Schema is versioned via `schemaVersion`. Phase 1a was at version 1; 1d
/// adds an optional `typography` override field while keeping schema 1
/// (older Maugham tolerates unknown fields rather than corrupting them).
/// The iPhone-companion milestone adds an optional `id` the same way —
/// additive optional field, schema stays 1, no migration. Decodes as nil
/// for pre-`id` manifests; `ProjectStore.load` backfills a minted ULID.
public struct ProjectManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int

    /// Stable logical project identifier, minted once (ULID) and persisted.
    /// Survives folder rename/move within a projects root — unlike the path.
    /// The iPhone companion keys capture-target selection and recents on it.
    /// Optional on disk for backward compatibility; `ProjectStore.load`
    /// mints + persists one when absent. New in the iPhone-companion milestone.
    public var id: String?

    public var type: ProjectType
    public var title: String
    public var author: String
    public var created: Date
    public var modified: Date
    public var structure: [StructureItem]
    public var research: [ResearchItem]
    public var targets: ProjectTargets?

    /// Per-project typography override. When non-nil, takes precedence over
    /// the user-level UserPreferences.typography.
    public var typography: TypographySettings?

    /// Per-project toggle for the element-type gutter (3b). Nil = use default
    /// (show for screenplay projects). Set explicitly to false to hide.
    public var showElementGutter: Bool?

    public init(
        schemaVersion: Int = ProjectManifest.currentSchemaVersion,
        id: String? = nil,
        type: ProjectType,
        title: String,
        author: String,
        created: Date,
        modified: Date,
        structure: [StructureItem],
        research: [ResearchItem],
        targets: ProjectTargets? = nil,
        typography: TypographySettings? = nil,
        showElementGutter: Bool? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.type = type
        self.title = title
        self.author = author
        self.created = created
        self.modified = modified
        self.structure = structure
        self.research = research
        self.targets = targets
        self.typography = typography
        self.showElementGutter = showElementGutter
    }
}
