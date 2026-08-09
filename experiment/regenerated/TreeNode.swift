import Foundation

/// A node in a forest of string-identified, optionally-branching values.
///
/// The protocol is deliberately narrow: an id and a mutable, optional list of
/// children of the same type. Anything else a walker needs about a node —
/// a file path, a kind, a title — is reached through a caller-supplied closure
/// rather than by widening this protocol.
///
/// `children` distinguishes three states, and the distinction is load-bearing:
/// `nil` (this node cannot have children), `[]` (it can, but has none), and a
/// non-empty array. Leaf-ness is defined by emptiness, so both `nil` and `[]`
/// are leaves.
public protocol TreeNode: Identifiable where ID == String {
    /// The node's identity. Ids are expected to be unique within a forest;
    /// the walkers do not enforce that and behave predictably when it is broken.
    var id: String { get }

    /// This node's children, or `nil` when the node holds no child list at all.
    var children: [Self]? { get set }
}

/// The single implementation of tree walking over `TreeNode` forests.
///
/// Every walker visits **pre-order** — a parent before its children, siblings in
/// array order — and every walker descends into a node regardless of whether that
/// node itself matched: filtering a parent out never prunes its children.
///
/// The traversals are plain recursion with no depth guard. They handle the depths
/// a manuscript binder reaches comfortably; the depth at which they exhaust the
/// stack depends on thread stack size and optimisation level and is not bounded here.
public enum TreeWalk {

    // MARK: - Searching by id

    /// Returns the first node in pre-order carrying `id`, at any depth, or `nil`.
    ///
    /// When several nodes share an id — which the forest invariant forbids but the
    /// walker tolerates — the first in pre-order wins. Pre-order is depth-first, so a
    /// deep match under an earlier sibling beats a shallow match under a later one.
    public static func find<N: TreeNode>(id: String, in nodes: [N]) -> N? {
        for node in nodes {
            if node.id == id { return node }
            if let children = node.children,
               let hit = find(id: id, in: children) {
                return hit
            }
        }
        return nil
    }

    /// Whether any node in the forest carries `id`, at any depth.
    public static func contains<N: TreeNode>(id: String, in nodes: [N]) -> Bool {
        find(id: id, in: nodes) != nil
    }

    // MARK: - Searching by predicate

    /// Returns the first node in pre-order satisfying `predicate`, at any depth, or `nil`.
    ///
    /// Because the visit is pre-order, when both a parent and one of its descendants
    /// satisfy the predicate the **parent** is returned. Equivalent to
    /// `collect(in:where:).first`, but stops at the first match.
    ///
    /// `predicate` is invoked at most once per visited node, and not at all on an
    /// empty forest.
    public static func first<N: TreeNode>(
        in nodes: [N], where predicate: (N) -> Bool
    ) -> N? {
        for node in nodes {
            if predicate(node) { return node }
            if let children = node.children,
               let hit = first(in: children, where: predicate) {
                return hit
            }
        }
        return nil
    }

    /// Returns every node satisfying `predicate`, in pre-order, at any depth.
    ///
    /// A node that fails the predicate is still descended into, so a filtered-out
    /// parent does not hide a matching child. Each returned node carries its entire
    /// original subtree — including descendants that failed the predicate — because
    /// this is a selection, not a pruning.
    ///
    /// With an always-true predicate this flattens the whole forest and agrees,
    /// element for element, with ``collectIds(in:)``.
    public static func collect<N: TreeNode>(
        in nodes: [N], where predicate: (N) -> Bool
    ) -> [N] {
        var found: [N] = []
        collect(in: nodes, where: predicate, into: &found)
        return found
    }

    private static func collect<N: TreeNode>(
        in nodes: [N], where predicate: (N) -> Bool, into found: inout [N]
    ) {
        for node in nodes {
            if predicate(node) { found.append(node) }
            if let children = node.children {
                collect(in: children, where: predicate, into: &found)
            }
        }
    }

    // MARK: - Flattening

    /// Returns every node with no children, in pre-order.
    ///
    /// Leaf-ness is decided by children-**emptiness**, not by node type: a node whose
    /// `children` is `nil` *and* a node whose `children` is `[]` are both leaves. A node
    /// with a non-empty child list is omitted, but its descendants still surface.
    ///
    /// No kind-filtering happens here. Callers that want only some sort of leaf filter
    /// the result.
    public static func leaves<N: TreeNode>(in nodes: [N]) -> [N] {
        var found: [N] = []
        leaves(in: nodes, into: &found)
        return found
    }

    private static func leaves<N: TreeNode>(in nodes: [N], into found: inout [N]) {
        for node in nodes {
            guard let children = node.children, !children.isEmpty else {
                found.append(node)
                continue
            }
            leaves(in: children, into: &found)
        }
    }

    /// Returns every id in the forest, in pre-order: a parent before its children,
    /// siblings in array order.
    ///
    /// Ids are emitted once per occurrence. Duplicates are not collapsed, so the
    /// result's count is the node count of the forest.
    public static func collectIds<N: TreeNode>(in nodes: [N]) -> [String] {
        var ids: [String] = []
        collectIds(in: nodes, into: &ids)
        return ids
    }

    private static func collectIds<N: TreeNode>(in nodes: [N], into ids: inout [String]) {
        for node in nodes {
            ids.append(node.id)
            if let children = node.children {
                collectIds(in: children, into: &ids)
            }
        }
    }

    // MARK: - Rewriting

    /// Returns a new forest in which every node carrying `id` has been replaced by
    /// `body`'s result. The input forest is untouched.
    ///
    /// Children are transformed **before** the parent's match is tested, so `body`
    /// receives a node whose own children have already been rewritten. Nothing
    /// constrains `body` to preserve the node's id; a body that changes it is applied
    /// once, on the way out, and the new id is not re-matched.
    ///
    /// An id present nowhere is the identity, and `body` is never invoked.
    public static func mutate<N: TreeNode>(
        id: String, in nodes: [N], _ body: (N) -> N
    ) -> [N] {
        nodes.map { node in
            var rewritten = node
            if let children = node.children {
                rewritten.children = mutate(id: id, in: children, body)
            }
            return node.id == id ? body(rewritten) : rewritten
        }
    }

    /// Returns a new forest with every node carrying `id` — and that node's entire
    /// subtree — dropped. The input forest is untouched.
    ///
    /// Nodes outside a removed subtree survive unchanged. An id present nowhere is
    /// the identity; conversely, if every root carries the id the result is empty.
    public static func remove<N: TreeNode>(id: String, in nodes: [N]) -> [N] {
        nodes.compactMap { node in
            guard node.id != id else { return nil }
            var kept = node
            if let children = node.children {
                kept.children = remove(id: id, in: children)
            }
            return kept
        }
    }

    /// Returns a new forest in which every node whose path is `oldPrefix`, or lies
    /// beneath it, has been re-rooted at `newPrefix`.
    ///
    /// The rule is exactly:
    ///
    /// - `p == oldPrefix` becomes `newPrefix`;
    /// - `oldPrefix + "/" + rest` becomes `newPrefix + "/" + rest`;
    /// - anything else is left alone.
    ///
    /// The `/` is a boundary, not a character comparison: with `oldPrefix` of
    /// `"old/group"`, the path `"old/groupie"` is untouched. No double slash is
    /// produced and no character of `rest` is eaten.
    ///
    /// A node whose `path` closure returns `nil` is never assigned one, and the walk
    /// still descends into its children — as it does for any node whose own path
    /// did not match. The matched node and its descendants are handled in the same
    /// single pass.
    ///
    /// - Parameters:
    ///   - path: reads a node's path, or `nil` if it has none. Invoked once per node.
    ///   - setPath: writes a rewritten path back into a copy of the node. Invoked only
    ///     for nodes whose path matched.
    public static func rewritePaths<N: TreeNode>(
        in nodes: [N],
        replacingPrefix oldPrefix: String,
        with newPrefix: String,
        path: (N) -> String?,
        setPath: (inout N, String) -> Void
    ) -> [N] {
        nodes.map { node in
            var rewritten = node
            if let current = path(node),
               let updated = rerooting(current, from: oldPrefix, to: newPrefix) {
                setPath(&rewritten, updated)
            }
            if let children = node.children {
                rewritten.children = rewritePaths(
                    in: children,
                    replacingPrefix: oldPrefix,
                    with: newPrefix,
                    path: path,
                    setPath: setPath
                )
            }
            return rewritten
        }
    }

    /// The reconciled prefix rule, in one place. Returns `nil` when `path` is neither
    /// `oldPrefix` itself nor a path beneath it.
    private static func rerooting(
        _ path: String, from oldPrefix: String, to newPrefix: String
    ) -> String? {
        if path == oldPrefix { return newPrefix }
        let boundary = oldPrefix + "/"
        guard path.hasPrefix(boundary) else { return nil }
        return newPrefix + "/" + String(path.dropFirst(boundary.count))
    }

    // MARK: - Indexing

    /// Maps every non-`nil` path in the forest to the id of the node carrying it.
    ///
    /// Nodes whose `path` closure returns `nil` are excluded from the map entirely; an
    /// empty-string path is a perfectly good key and is distinct from an absent one.
    ///
    /// Callers are expected to hold paths unique, which makes the contest moot. When
    /// it is broken the last node visited in pre-order wins — so where a parent and a
    /// child share a path, the child's id is the one recorded.
    ///
    /// The returned `Dictionary` has no meaningful iteration order, and that order
    /// varies from process to process. Subscript it; do not iterate it and expect
    /// stability.
    public static func idsByPath<N: TreeNode>(
        in nodes: [N],
        path: (N) -> String?
    ) -> [String: String] {
        var map: [String: String] = [:]
        idsByPath(in: nodes, path: path, into: &map)
        return map
    }

    private static func idsByPath<N: TreeNode>(
        in nodes: [N],
        path: (N) -> String?,
        into map: inout [String: String]
    ) {
        for node in nodes {
            if let key = path(node) { map[key] = node.id }
            if let children = node.children {
                idsByPath(in: children, path: path, into: &map)
            }
        }
    }
}
