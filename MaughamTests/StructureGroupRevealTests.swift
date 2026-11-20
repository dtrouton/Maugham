import XCTest
import SwiftUI
import MaughamCore
@testable import Maugham

/// **⌘⌥E opens the Parts above the chapter it shows** (shell p3 final wave,
/// ruled in Task 9's fix round). A structure group was a binding-less
/// `DisclosureGroup`, so nothing outside could open one, and ⌘⌥E on a
/// chapter inside a closed Part opened its fold and scrolled to a row that
/// was not drawn.
@MainActor
final class StructureGroupRevealTests: XCTestCase {

    private let structure: [StructureItem] = [
        StructureItem(id: "part-1", title: "Part One", type: .group, path: "manuscript/one",
                      children: [
                        StructureItem(id: "part-1a", title: "Book A", type: .group,
                                      path: "manuscript/one/a",
                                      children: [StructureItem(id: "ch-deep", title: "Deep",
                                                               type: .document,
                                                               path: "manuscript/one/a/deep.md")]),
                        StructureItem(id: "ch-1", title: "One", type: .document,
                                      path: "manuscript/one/one.md"),
                      ]),
        StructureItem(id: "part-2", title: "Part Two", type: .group, path: "manuscript/two",
                      children: []),
        StructureItem(id: "ch-top", title: "Top", type: .document, path: "manuscript/top.md"),
    ]

    func test_aChaptersPartsAreOpenedAndNothingElse() {
        let state = BinderTreeSectionsState()
        state.openStructureAncestors(of: "ch-deep", in: structure)
        XCTAssertEqual(state.expandedStructureGroups, ["part-1", "part-1a"],
                       "every Part above it, and no other")
        XCTAssertTrue(state.groupExpansion(of: "part-1a").wrappedValue)
        XCTAssertFalse(state.groupExpansion(of: "part-2").wrappedValue)

        // It only ever opens: a writer's own open Part stays open.
        state.groupExpansion(of: "part-2").wrappedValue = true
        state.openStructureAncestors(of: "ch-top", in: structure)
        XCTAssertEqual(state.expandedStructureGroups, ["part-1", "part-1a", "part-2"])

        // The binding closes as the writer's click does.
        state.groupExpansion(of: "part-1").wrappedValue = false
        XCTAssertFalse(state.expandedStructureGroups.contains("part-1"))
    }

    func test_theTreesPartsAreBoundAndTheKeyOpensThem() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let binder = try String(contentsOf: root.appendingPathComponent("Maugham/Views/BinderView.swift"),
                                encoding: .utf8)
        XCTAssertTrue(binder.contains("DisclosureGroup(isExpanded: treeState.groupExpansion(of: item.id))"),
                      "a Part's flag is the tree state's, so a key can open it")
        let window = try String(contentsOf: root.appendingPathComponent("Maugham/Views/ProjectWindow.swift"),
                                encoding: .utf8)
        let receiver = try XCTUnwrap(window.range(of: ".onKeyWindowCommand(.maughamShowPieceFold"))
        let body = String(window[receiver.lowerBound...].prefix(1200))
        let open = try XCTUnwrap(body.range(of: "treeState.openStructureAncestors(of: id,"),
                                 "⌘⌥E opens the Parts above its piece")
        let scroll = try XCTUnwrap(body.range(of: "treeState.scrollRequest = .row(.item(id))"))
        XCTAssertLessThan(open.lowerBound, scroll.lowerBound, "before it scrolls to the row")
    }
}
