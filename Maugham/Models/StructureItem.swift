import Foundation

/// A node in a project's manuscript structure tree.
/// Either a `group` (with `children`) or a `document` (with `path`).
public struct StructureItem: Codable, Equatable, Identifiable, Sendable {
    public enum ItemType: String, Codable, Sendable {
        case group, document
    }

    public var id: String
    public var title: String
    public var type: ItemType
    public var path: String?
    public var synopsis: String?
    public var status: String?
    public var wordTarget: Int?
    public var children: [StructureItem]?

    public init(
        id: String,
        title: String,
        type: ItemType,
        path: String? = nil,
        synopsis: String? = nil,
        status: String? = nil,
        wordTarget: Int? = nil,
        children: [StructureItem]? = nil
    ) {
        self.id = id
        self.title = title
        self.type = type
        self.path = path
        self.synopsis = synopsis
        self.status = status
        self.wordTarget = wordTarget
        self.children = children
    }
}
