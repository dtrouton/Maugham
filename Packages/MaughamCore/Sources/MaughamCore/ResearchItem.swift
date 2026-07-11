import Foundation

/// Marks items with app-level meaning that must survive rename/move
/// (ADR-0015-tolerant: unknown raw values decode to `.unknown`, which no
/// lookup matches — semantically equivalent to nil for old readers).
public enum ResearchRole: String, Codable, Sendable {
    case paletteGroup = "palette_group"
    case craftIntent = "craft_intent"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ResearchRole(rawValue: raw) ?? .unknown
    }
}

/// A node in a project's research tree.
/// Either a `group` (with `children`) or an `asset` (image, document, pdf, audio, link).
public struct ResearchItem: Codable, Equatable, Identifiable, Sendable, TreeNode {
    public enum ItemType: String, Codable, Sendable {
        case group, asset

        /// Cross-version forward-tolerance (ADR 0015): an unknown `type` from a
        /// newer build decodes to `.asset` (a benign leaf) rather than throwing
        /// and making the whole manifest unopenable. Defaulting (not a third
        /// case) preserves the binary group/asset invariant the research-tree
        /// switches rely on. See `StructureItem.ItemType` and the schemaVersion
        /// gate (`ProjectManifest.load`).
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = ItemType(rawValue: raw) ?? .asset
        }
    }

    public enum AssetKind: String, Codable, CaseIterable, Sendable {
        case image, document, pdf, audio, link

        /// Cross-version forward-tolerance (ADR 0015): an unknown asset `kind`
        /// from a newer build decodes to `.document` (a generic, previewable
        /// kind) rather than throwing. `kind` is optional and every consumer
        /// already handles the full set; degrading to `.document` keeps the
        /// manifest decodable without threading a new case through ~15 view
        /// switches. The schemaVersion gate handles genuinely-newer projects.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = AssetKind(rawValue: raw) ?? .document
        }
    }

    public var id: String
    public var title: String
    public var type: ItemType
    public var kind: AssetKind?
    public var path: String?
    public var url: String?
    public var caption: String?
    public var tags: [String]?
    public var links: [String]?
    public var addedAt: Date?
    public var children: [ResearchItem]?
    /// App-level identity that survives rename/move (see `ResearchRole`).
    /// Optional so legacy manifests decode with `nil`; a nil or `.unknown`
    /// role means "no durable marker" and falls back to path/filename.
    public var role: ResearchRole?

    public init(
        id: String,
        title: String,
        type: ItemType,
        kind: AssetKind? = nil,
        path: String? = nil,
        url: String? = nil,
        caption: String? = nil,
        tags: [String]? = nil,
        links: [String]? = nil,
        addedAt: Date? = nil,
        children: [ResearchItem]? = nil,
        role: ResearchRole? = nil
    ) {
        self.id = id
        self.title = title
        self.type = type
        self.kind = kind
        self.path = path
        self.url = url
        self.caption = caption
        self.tags = tags
        self.links = links
        self.addedAt = addedAt
        self.children = children
        self.role = role
    }
}
