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

    /// Pre-order depth-first search for the first node satisfying `predicate`.
    /// The generic counterpart to `find(id:in:)` for non-id keys (e.g. by-path
    /// lookup, where `path` is not part of the `TreeNode` protocol). Returns the
    /// node, not just its id; callers wanting the id use `.map(\.id)`.
    public static func first<N: TreeNode>(
        in nodes: [N], where predicate: (N) -> Bool
    ) -> N? {
        for node in nodes {
            if predicate(node) { return node }
            if let kids = node.children, let hit = first(in: kids, where: predicate) {
                return hit
            }
        }
        return nil
    }

    /// Pre-order (parent before children) flat list of every node satisfying
    /// `predicate`. The generic counterpart to `collectIds(in:)` when callers
    /// need to filter on, or read more than the id of, each node (e.g. collect
    /// only `.document` nodes, then map to ids or build an `[id: path]` map).
    /// Pass `{ _ in true }` to flatten the whole tree.
    public static func collect<N: TreeNode>(
        in nodes: [N], where predicate: (N) -> Bool
    ) -> [N] {
        var out: [N] = []
        for node in nodes {
            if predicate(node) { out.append(node) }
            if let kids = node.children {
                out.append(contentsOf: collect(in: kids, where: predicate))
            }
        }
        return out
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

    /// Rewrite the `path` of every node whose path begins with `oldPrefix`,
    /// replacing that prefix with `newPrefix`.
    ///
    /// `path` is not part of the `TreeNode` protocol (StructureItem and
    /// ResearchItem both carry `path: String?` but the protocol doesn't require
    /// it), so access is supplied via closures.
    ///
    /// Prefix semantics (the reconciled rule — see `TreeNodeTests` for the
    /// derivation of the old `rewriteChildPaths` / `researchRewriteChildPaths`
    /// `dropFirst(+1)` divergence, which were two spellings of this one rule):
    ///   - a path EQUAL to `oldPrefix`            → `newPrefix`
    ///   - a path of form `oldPrefix + "/" + r`   → `newPrefix + "/" + r`
    ///   - any other path (incl. `oldPrefix` as a non-boundary prefix such as
    ///     `oldPrefix + "ie"`, and nil paths)     → left untouched
    /// We match on `p == oldPrefix || p.hasPrefix(oldPrefix + "/")` and take
    /// `suffix = p.dropFirst(oldPrefix.count)` — which keeps the leading "/"
    /// for descendants and is empty for the exact match. No double slash, no
    /// eaten character.
    public static func rewritePaths<N: TreeNode>(
        in nodes: [N],
        replacingPrefix oldPrefix: String,
        with newPrefix: String,
        path: (N) -> String?,
        setPath: (inout N, String) -> Void
    ) -> [N] {
        nodes.map { node in
            var node = node
            if let p = path(node), p == oldPrefix || p.hasPrefix(oldPrefix + "/") {
                let suffix = p.dropFirst(oldPrefix.count)
                setPath(&node, newPrefix + suffix)
            }
            if let kids = node.children {
                node.children = rewritePaths(
                    in: kids, replacingPrefix: oldPrefix, with: newPrefix,
                    path: path, setPath: setPath)
            }
            return node
        }
    }

    /// Build a `[path: id]` map over the whole tree (pre-order). Nodes with a
    /// nil path are skipped. On duplicate paths, last-writer-wins (pre-order),
    /// which the store invariant — unique on-disk paths — makes moot.
    /// `path` access is supplied via a closure (see `rewritePaths`).
    public static func idsByPath<N: TreeNode>(
        in nodes: [N],
        path: (N) -> String?
    ) -> [String: String] {
        var out: [String: String] = [:]
        func walk(_ nodes: [N]) {
            for node in nodes {
                if let p = path(node) { out[p] = node.id }
                if let kids = node.children { walk(kids) }
            }
        }
        walk(nodes)
        return out
    }
}
