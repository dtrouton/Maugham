import Foundation

/// A node in an id-keyed tree whose children are the same type.
/// Both `StructureItem` and `ResearchItem` conform; the generic walkers in
/// `TreeWalk` replace the per-type hand-rolled recursion that had drifted
/// across the codebase. Cross-surface contract: MaughamCore owns this; the
/// phone shares it (do not re-implement — see cross-surface-contracts.md).
public protocol TreeNode: Identifiable where ID == String {
    var id: String { get }
    var children: [Self]? { get set }
}

public enum TreeWalk {

    /// Pre-order depth-first search for a node by id.
    public static func find<N: TreeNode>(id: String, in nodes: [N]) -> N? {
        for node in nodes {
            if node.id == id { return node }
            if let kids = node.children, let hit = find(id: id, in: kids) {
                return hit
            }
        }
        return nil
    }

    public static func contains<N: TreeNode>(id: String, in nodes: [N]) -> Bool {
        find(id: id, in: nodes) != nil
    }

    /// Pre-order id list (parent before children).
    public static func collectIds<N: TreeNode>(in nodes: [N]) -> [String] {
        var out: [String] = []
        for node in nodes {
            out.append(node.id)
            if let kids = node.children { out.append(contentsOf: collectIds(in: kids)) }
        }
        return out
    }

    /// Returns a new tree with the node matching `id` transformed by `body`.
    /// Non-matching nodes are returned unchanged. `body` sees the matched
    /// node (with its already-transformed children) and returns the replacement.
    public static func mutate<N: TreeNode>(
        id: String, in nodes: [N], _ body: (N) -> N
    ) -> [N] {
        nodes.map { node in
            var node = node
            if let kids = node.children {
                node.children = mutate(id: id, in: kids, body)
            }
            return node.id == id ? body(node) : node
        }
    }

    /// Returns a new tree with the node matching `id` (and its subtree) removed.
    public static func remove<N: TreeNode>(id: String, in nodes: [N]) -> [N] {
        nodes.compactMap { node -> N? in
            if node.id == id { return nil }
            var node = node
            if let kids = node.children { node.children = remove(id: id, in: kids) }
            return node
        }
    }
}
