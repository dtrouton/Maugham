import Foundation

/// The root of a `project.maugham.json` manifest file.
///
/// Schema is versioned via `schemaVersion`. Phase 1a is at version 1.
/// Future versions add fields rather than rename them; older Maugham
/// builds tolerate unknown fields rather than corrupting them.
public struct ProjectManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var type: ProjectType
    public var title: String
    public var author: String
    public var created: Date
    public var modified: Date
    public var structure: [StructureItem]
    public var research: [ResearchItem]
    public var targets: ProjectTargets?

    public init(
        schemaVersion: Int = ProjectManifest.currentSchemaVersion,
        type: ProjectType,
        title: String,
        author: String,
        created: Date,
        modified: Date,
        structure: [StructureItem],
        research: [ResearchItem],
        targets: ProjectTargets? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.type = type
        self.title = title
        self.author = author
        self.created = created
        self.modified = modified
        self.structure = structure
        self.research = research
        self.targets = targets
    }
}
