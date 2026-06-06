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
}
