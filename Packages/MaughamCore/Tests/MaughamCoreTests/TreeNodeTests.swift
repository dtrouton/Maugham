import XCTest
@testable import MaughamCore

final class TreeNodeTests: XCTestCase {

    // Minimal conforming node for testing the generic algorithms in isolation.
    struct Node: TreeNode, Equatable {
        var id: String
        var children: [Node]?
    }

    private func sample() -> [Node] {
        [Node(id: "a", children: [
            Node(id: "a1", children: nil),
            Node(id: "a2", children: [Node(id: "a2x", children: nil)]),
        ]),
         Node(id: "b", children: nil)]
    }

    func test_find_returnsDeepNode() {
        XCTAssertEqual(TreeWalk.find(id: "a2x", in: sample())?.id, "a2x")
        XCTAssertNil(TreeWalk.find(id: "nope", in: sample()))
    }

    func test_contains() {
        XCTAssertTrue(TreeWalk.contains(id: "a2", in: sample()))
        XCTAssertFalse(TreeWalk.contains(id: "zzz", in: sample()))
    }

    func test_collect_ids_preorder() {
        XCTAssertEqual(TreeWalk.collectIds(in: sample()),
                       ["a", "a1", "a2", "a2x", "b"])
    }

    func test_first_byPredicate_returnsDeepNode_preorder() {
        // Predicate matching a deep node.
        XCTAssertEqual(
            TreeWalk.first(in: sample()) { $0.id == "a2x" }?.id, "a2x")
        // No match → nil.
        XCTAssertNil(TreeWalk.first(in: sample()) { $0.id == "nope" })
        // Pre-order: parent "a" is visited before any of its children.
        XCTAssertEqual(
            TreeWalk.first(in: sample()) { $0.id.hasPrefix("a") }?.id, "a")
    }

    func test_collect_byPredicate_preorder_filtered() {
        // Filtered collect: only ids starting with "a".
        XCTAssertEqual(
            TreeWalk.collect(in: sample()) { $0.id.hasPrefix("a") }.map(\.id),
            ["a", "a1", "a2", "a2x"])
        // `{ _ in true }` flattens the whole tree, pre-order.
        XCTAssertEqual(
            TreeWalk.collect(in: sample()) { _ in true }.map(\.id),
            ["a", "a1", "a2", "a2x", "b"])
    }

    func test_mutate_returnsNewTree_leavesOthersUntouched() {
        let updated = TreeWalk.mutate(id: "a1", in: sample()) { node in
            var n = node; n.id = "a1-renamed"; return n
        }
        XCTAssertTrue(TreeWalk.contains(id: "a1-renamed", in: updated))
        XCTAssertFalse(TreeWalk.contains(id: "a1", in: updated))
        XCTAssertTrue(TreeWalk.contains(id: "b", in: updated))
    }

    func test_remove_dropsSubtree() {
        let after = TreeWalk.remove(id: "a2", in: sample())
        XCTAssertFalse(TreeWalk.contains(id: "a2", in: after))
        XCTAssertFalse(TreeWalk.contains(id: "a2x", in: after)) // subtree gone
        XCTAssertTrue(TreeWalk.contains(id: "a1", in: after))
    }

    // MARK: - Path rewrite (Task 3.2)
    //
    // STEP-1 RECONCILIATION FINDINGS (the latent +1 divergence):
    //
    // Two store copies both rewrite a group's descendant paths when the group's
    // folder moves from `oldPrefix` to `newPrefix`. Both gate on the SAME
    // condition — `p.hasPrefix(oldPrefix + "/")` — so both assume child paths
    // are shaped `oldPrefix + "/" + rest` (e.g. oldPrefix="research/grp",
    // child path="research/grp/note.md", rest="note.md"). They differ only in
    // how they re-attach the suffix:
    //
    //   ProjectStore+Structure.rewriteChildPaths:
    //       newPrefix + p.dropFirst(oldPrefix.count)
    //     dropFirst(count) drops "research/grp", KEEPING the leading "/".
    //     → "research/grp/note.md" → newPrefix + "/note.md".
    //
    //   ProjectStore+Research.researchRewriteChildPaths:
    //       newPrefix + "/" + p.dropFirst(oldPrefix.count + 1)
    //     dropFirst(count+1) drops "research/grp/" (incl. the slash), then the
    //     literal "/" is re-prepended.
    //     → "note.md" → newPrefix + "/" + "note.md".
    //
    // CONCLUSION: both produce the IDENTICAL result ("new/place/note.md") for
    // the same-shaped input. Neither is buggy; the "+1" is NOT compensating for
    // differently-shaped stored paths — it is merely a second spelling of the
    // same rule (strip-the-slash-then-re-add vs. keep-the-slash). The callers
    // (group rename in +Structure, cross-group move + duplicate in +Research)
    // all pass child paths that contain the full prefix with a "/" boundary.
    //
    // Canonical rule encoded once in TreeWalk.rewritePaths:
    //   p == oldPrefix            → newPrefix                  (exact node)
    //   p == oldPrefix + "/" + r  → newPrefix + "/" + r        (descendant)
    //   match on (p == oldPrefix || p.hasPrefix(oldPrefix + "/")),
    //   suffix = p.dropFirst(oldPrefix.count)  (keeps the leading "/" for
    //   descendants, empty for the exact match). No double slash, no eaten char.
    //   (The existing store copies only handle the descendant case because the
    //   group node's own path is rewritten separately by their callers; the
    //   generic additionally handles the exact-match node for completeness.)

    func test_rewritePaths_replacesPrefix_noDoubleSlash_noEatenChar() {
        struct PNode: TreeNode, Equatable {
            var id: String
            var path: String?
            var children: [PNode]?
        }
        let tree = [PNode(id: "g", path: "old/group", children: [
            PNode(id: "d", path: "old/group/chapter.md", children: nil),
        ])]
        let rewritten = TreeWalk.rewritePaths(
            in: tree, replacingPrefix: "old/group", with: "new/place",
            path: { $0.path }, setPath: { $0.path = $1 })
        XCTAssertEqual(TreeWalk.find(id: "d", in: rewritten)?.path, "new/place/chapter.md")
        XCTAssertEqual(TreeWalk.find(id: "g", in: rewritten)?.path, "new/place")
    }

    func test_rewritePaths_leavesNonMatchingPathsUntouched() {
        struct PNode: TreeNode, Equatable {
            var id: String
            var path: String?
            var children: [PNode]?
        }
        // "old/groupie" must NOT match "old/group" (prefix-but-not-boundary),
        // and an unrelated path is left alone.
        let tree = [
            PNode(id: "x", path: "old/groupie/n.md", children: nil),
            PNode(id: "y", path: "elsewhere/n.md", children: nil),
        ]
        let rewritten = TreeWalk.rewritePaths(
            in: tree, replacingPrefix: "old/group", with: "new/place",
            path: { $0.path }, setPath: { $0.path = $1 })
        XCTAssertEqual(TreeWalk.find(id: "x", in: rewritten)?.path, "old/groupie/n.md")
        XCTAssertEqual(TreeWalk.find(id: "y", in: rewritten)?.path, "elsewhere/n.md")
    }

    func test_idsByPath_mapsPathToId_skipsNilPaths() {
        struct PNode: TreeNode, Equatable {
            var id: String
            var path: String?
            var children: [PNode]?
        }
        let tree = [PNode(id: "g", path: "grp", children: [
            PNode(id: "d", path: "grp/chapter.md", children: nil),
            PNode(id: "link", path: nil, children: nil), // link asset: no path
        ])]
        let map = TreeWalk.idsByPath(in: tree, path: { $0.path })
        XCTAssertEqual(map["grp"], "g")
        XCTAssertEqual(map["grp/chapter.md"], "d")
        XCTAssertNil(map["__missing__"])
        XCTAssertEqual(map.count, 2) // nil-path node excluded
    }
}
