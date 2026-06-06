import Foundation

/// A node in a project's research tree.
/// Either a `group` (with `children`) or an `asset` (image, document, pdf, audio, link).
public struct ResearchItem: Codable, Equatable, Identifiable, Sendable, TreeNode {
    public enum ItemType: String, Codable, Sendable {
        case group, asset
    }

    public enum AssetKind: String, Codable, CaseIterable, Sendable {
        case image, document, pdf, audio, link
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
        children: [ResearchItem]? = nil
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
    }
}
