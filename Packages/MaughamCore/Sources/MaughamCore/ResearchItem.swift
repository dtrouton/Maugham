import Foundation

/// Marks items with app-level meaning that must survive rename/move.
///
/// ADR-0015 safe round-trip: `role` is *identity-bearing*, so — unlike the
/// tolerant `ItemType`/`AssetKind` decoders that degrade to a benign default —
/// an unrecognised (future) value is preserved verbatim in `.unknown(raw)` and
/// re-encoded as that same raw string. This keeps a cross-version round-trip
/// lossless: an OLD build that decodes a NEWER build's role and later re-saves
/// the manifest (including a lazy heal) does NOT clobber the newer identity
/// marker down to the literal `"unknown"`. No lookup matches `.unknown`, so it
/// remains semantically equivalent to nil for old readers.
///
/// Not a `String`-raw enum: the associated value can't ride on `rawValue`, so
/// the conformance is hand-written. `Equatable`/`Sendable` synthesise (the
/// payload is `String`); no `CaseIterable` is declared (it would not synthesise
/// with an associated value, and nothing enumerates the cases).
public enum ResearchRole: Codable, Equatable, Sendable {
    case paletteGroup
    case craftIntent
    /// A role written by a newer build. Carries the original raw string so
    /// re-encode is lossless (see type doc).
    case unknown(String)

    private static let paletteGroupRaw = "palette_group"
    private static let craftIntentRaw = "craft_intent"

    /// The stable on-disk string. Known cases emit their canonical value; an
    /// `.unknown` emits the preserved original raw.
    public var rawValue: String {
        switch self {
        case .paletteGroup: return Self.paletteGroupRaw
        case .craftIntent: return Self.craftIntentRaw
        case .unknown(let raw): return raw
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case Self.paletteGroupRaw: self = .paletteGroup
        case Self.craftIntentRaw: self = .craftIntent
        default: self = .unknown(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
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
