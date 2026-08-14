import Foundation

/// A node in a project's manuscript structure tree.
/// Either a `group` (with `children`) or a `document` (with `path`).
public struct StructureItem: Codable, Equatable, Identifiable, Sendable, TreeNode {
    public enum ItemType: String, Codable, Sendable {
        case group, document

        /// Cross-version forward-tolerance (ADR 0015). An item `type` written by
        /// a newer Maugham decodes to `.document` (a benign leaf) rather than
        /// throwing — which, because the whole `project.maugham.json` is one JSON
        /// object, would make the ENTIRE project unopenable on the older build.
        /// Defaulting to `.document` (not a third `.unknown` state) keeps the
        /// binary group/document invariant the tree-walk + ~15 exhaustive
        /// switches rely on. The manifest `schemaVersion` gate refuses a
        /// genuinely newer-schema project up front, so this only fires for a
        /// same-schema file with an unexpected value — graceful degradation.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = ItemType(rawValue: raw) ?? .document
        }
    }

    public var id: String
    public var title: String
    public var type: ItemType
    public var path: String?
    public var synopsis: String?
    public var status: String?
    public var wordTarget: Int?
    public var pageTarget: Int?
    public var pieceKind: PieceKind?
    public var linkedProjectPath: String?
    public var linkedProjectBookmark: Data?
    public var tags: [String]?
    public var links: [String]?
    public var children: [StructureItem]?
    public var linkedResearchIds: [String]?
    /// Where this piece stands on each named review pass, keyed by the
    /// `ReviewPass.id` (M3 P1). OPTIONAL on purpose — the synthesized decoder
    /// stays untouched, so a manifest written before this milestone (no key at
    /// all) still opens; a non-optional field would throw `keyNotFound` on
    /// every existing project. An absent dictionary and an absent key both mean
    /// untouched, which is why `PassState` has no `notStarted` case.
    public var passStates: [String: PassState]?

    public init(
        id: String,
        title: String,
        type: ItemType,
        path: String? = nil,
        synopsis: String? = nil,
        status: String? = nil,
        wordTarget: Int? = nil,
        pageTarget: Int? = nil,
        pieceKind: PieceKind? = nil,
        linkedProjectPath: String? = nil,
        linkedProjectBookmark: Data? = nil,
        tags: [String]? = nil,
        links: [String]? = nil,
        children: [StructureItem]? = nil,
        linkedResearchIds: [String]? = nil,
        passStates: [String: PassState]? = nil
    ) {
        self.id = id
        self.title = title
        self.type = type
        self.path = path
        self.synopsis = synopsis
        self.status = status
        self.wordTarget = wordTarget
        self.pageTarget = pageTarget
        self.pieceKind = pieceKind
        self.linkedProjectPath = linkedProjectPath
        self.linkedProjectBookmark = linkedProjectBookmark
        self.tags = tags
        self.links = links
        self.children = children
        self.linkedResearchIds = linkedResearchIds
        self.passStates = passStates
    }
}
