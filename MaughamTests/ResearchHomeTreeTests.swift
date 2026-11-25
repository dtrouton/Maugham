import XCTest
import MaughamCore
import SwiftUI
@testable import Maugham

/// **What the tree does with `ResearchHomes`** (shell p5 Task 4a): the row
/// menus that move research between the book and a chapter, a note in two
/// folds selecting one row, and a chapter's fold opening when the chapter is
/// selected — each a pure decision, asked here without a window.
@MainActor
final class ResearchHomeTreeTests: XCTestCase {

    private func chapter(_ id: String, links: [String]? = nil) -> StructureItem {
        StructureItem(id: id, title: "Chapter \(id)", type: .document,
                      path: "manuscript/\(id).md", linkedResearchIds: links)
    }

    private func note(_ id: String) -> ResearchItem {
        ResearchItem(id: id, title: id, type: .asset, kind: .document, path: "research/\(id).md")
    }

    /// `one` links `solo`, `both` and the group `grp`; `two` links `both`.
    private var homes: ResearchHomes {
        ResearchHomes.derive(
            structure: [chapter("one", links: ["solo", "both", "grp"]),
                        chapter("two", links: ["both"]), chapter("three")],
            research: [note("book"), note("solo"), note("both"),
                       ResearchItem(id: "grp", title: "Group", type: .group, path: "research/grp",
                                    children: [note("ingrp")])],
            projectType: .novel)
    }

    // MARK: - The menus (D)

    func test_aWholeBookRowMovesToAnyChapter() throws {
        let menu = try XCTUnwrap(ResearchHomeMenu.of(
            itemId: "book", inFold: nil, homes: homes, noun: "chapter", mayLink: { _ in true }))
        XCTAssertEqual(menu.moveTitle, "Move to Chapter")
        XCTAssertEqual(menu.moveTargets.map(\.verb), [
            .link(researchId: "book", to: "one"), .link(researchId: "book", to: "two"),
            .link(researchId: "book", to: "three")])
        XCTAssertEqual(menu.moveTargets.map(\.title), ["Chapter one", "Chapter two", "Chapter three"])
        XCTAssertNil(menu.makeWholeBook, "it already is")
        XCTAssertNil(menu.removeFromThis)
    }

    func test_aChaptersOnlyRowMovesOnOrBecomesWholeBook() throws {
        let menu = try XCTUnwrap(ResearchHomeMenu.of(
            itemId: "solo", inFold: "one", homes: homes, noun: "chapter", mayLink: { _ in true }))
        XCTAssertEqual(menu.moveTargets.map(\.verb), [
            .move(researchId: "solo", from: "one", to: "two"),
            .move(researchId: "solo", from: "one", to: "three")])
        XCTAssertEqual(menu.makeWholeBook,
                       .init(title: "Make Whole-Book", verb: .unlink(researchId: "solo", from: ["one"])))
        XCTAssertNil(menu.removeFromThis)
        XCTAssertNil(menu.alsoIn)
    }

    /// **Linked to several, the menu shows which**, and leaving this chapter
    /// is its own item.
    func test_aRowTwoChaptersLinkSaysWhichAndLeavesOne() throws {
        let menu = try XCTUnwrap(ResearchHomeMenu.of(
            itemId: "both", inFold: "one", homes: homes, noun: "chapter", mayLink: { _ in true }))
        XCTAssertEqual(menu.removeFromThis,
                       .init(title: "Remove from “Chapter one”",
                             verb: .unlink(researchId: "both", from: ["one"])))
        XCTAssertEqual(menu.alsoIn, "Also in “Chapter two”")
        XCTAssertEqual(menu.makeWholeBook?.verb, .unlink(researchId: "both", from: ["one", "two"]))
        XCTAssertEqual(menu.moveTargets.map(\.verb), [.move(researchId: "both", from: "one", to: "three")],
                       "a chapter already holding it is no target")
    }

    /// A note inside a group the chapter links moves with its group: its row
    /// offers no link verb of its own.
    func test_aRowInsideALinkedGroupOffersNoLinkVerb() {
        XCTAssertNil(ResearchHomeMenu.of(itemId: "ingrp", inFold: "one", homes: homes,
                                         noun: "chapter", mayLink: { _ in true }))
    }

    /// **What linking needs**: a chapter the posture refuses is offered
    /// nowhere — not as a target, not as the chapter to leave.
    func test_aChapterThePostureRefusesIsNotOffered() throws {
        let menu = try XCTUnwrap(ResearchHomeMenu.of(
            itemId: "book", inFold: nil, homes: homes, noun: "chapter", mayLink: { $0 != "two" }))
        XCTAssertEqual(menu.moveTargets.map(\.verb), [
            .link(researchId: "book", to: "one"), .link(researchId: "book", to: "three")])
        XCTAssertNil(ResearchHomeMenu.of(itemId: "solo", inFold: "one", homes: homes,
                                         noun: "chapter", mayLink: { $0 != "one" }))
        let both = try XCTUnwrap(ResearchHomeMenu.of(
            itemId: "both", inFold: "one", homes: homes, noun: "chapter", mayLink: { $0 != "two" }))
        XCTAssertNil(both.makeWholeBook, "leaving both chapters needs both")
        XCTAssertNotNil(both.removeFromThis)
        XCTAssertNil(ResearchHomeMenu.of(itemId: "book", inFold: nil, homes: homes,
                                         noun: "chapter", mayLink: { _ in false }),
                     "nothing permitted: no menu")
    }

    /// The menu's items are drawn by the row and performed by the tree's one
    /// verb value — the delivery path, read (a context menu cannot be opened
    /// headless).
    func test_theRowDrawsTheMenuAndTheVerbsPerformIt() throws {
        let node = SourceScan.codeLines(of: try SourceTree.read("Maugham/Views/ResearchTree.swift"))
            .joined(separator: "\n")
        XCTAssertTrue(node.contains("if acting.count == 1, let home = actions.homeMenu(item, inFold)"))
        XCTAssertTrue(node.contains("ResearchHomeMoveItems(nodes: home.moveTree, perform: actions.performHome)"))
        XCTAssertTrue(node.contains("Button(target.title) { perform(target.verb) }"))
        XCTAssertTrue(node.contains("actions.performHome(whole.verb)"))
        XCTAssertTrue(node.contains("actions.performHome(remove.verb)"))
        let verbs = SourceScan.codeLines(of: try SourceTree.read("Maugham/Views/BinderTreeSections.swift"))
            .joined(separator: "\n")
        XCTAssertTrue(verbs.contains("homeMenu: { item, fold in homeMenu(for: item, inFold: fold) }"))
        XCTAssertTrue(verbs.contains("performHome: { verb in performHome(verb) }"))
        XCTAssertTrue(verbs.contains("mayLink: { mayEditResearchLinks(of: $0) })"))
    }

    /// **Move to Chapter ▸ nests by Part** (M10): in a book with Parts the
    /// chooser is the tree's own shape, a submenu per Part; in a book without,
    /// a flat list.
    func test_moveToChapterNestsByPart() throws {
        let structure = [
            chapter("one"),
            StructureItem(id: "p1", title: "Part One", type: .group, children: [
                chapter("two"),
                StructureItem(id: "pa", title: "Part A", type: .group, children: [chapter("three")]),
            ]),
            chapter("four"),
        ]
        let homes = ResearchHomes.derive(structure: structure, research: [note("book")], projectType: .novel)
        let menu = try XCTUnwrap(ResearchHomeMenu.of(itemId: "book", inFold: nil, homes: homes,
                                                     noun: "chapter", mayLink: { _ in true }))
        func item(_ id: String) -> ResearchHomeMenu.MoveNode {
            .target(.init(title: "Chapter \(id)", verb: .link(researchId: "book", to: id)))
        }
        XCTAssertEqual(menu.moveTree, [
            item("one"),
            .part(id: "p1", title: "Part One", children: [
                item("two"), .part(id: "pa", title: "Part A", children: [item("three")])]),
            item("four"),
        ])
        let flat = try XCTUnwrap(ResearchHomeMenu.of(itemId: "book", inFold: nil, homes: self.homes,
                                                     noun: "chapter", mayLink: { _ in true }))
        XCTAssertEqual(flat.moveTree, flat.moveTargets.map { .target($0) }, "no Parts: a flat list")
    }

    // MARK: - Creation lands where its row is drawn (G)

    /// **A fold's New Note lands in that fold**: at its top, the piece's own;
    /// in a group the piece holds, there; beside a linked note whose group is
    /// the book's, in that group AND linked — never in the Research section,
    /// where it would seem to vanish from the fold it was asked from.
    func test_aFoldsNewNoteLandsInThatFold() {
        let novel = ResearchHomes.derive(
            structure: [chapter("one", links: ["grp", "inner"])],
            research: [ResearchItem(id: "grp", title: "Group", type: .group, path: "research/grp",
                                    children: [note("ingrp")]),
                       ResearchItem(id: "world", title: "World", type: .group, path: "research/world",
                                    children: [note("inner")])],
            projectType: .novel)
        XCTAssertEqual(BinderPieceFold.creation(under: nil, inFoldOf: "one", homes: novel), .piecesScope)
        XCTAssertEqual(BinderPieceFold.creation(under: "grp", inFoldOf: "one", homes: novel), .asAsked)
        XCTAssertEqual(BinderPieceFold.creation(under: "world", inFoldOf: "one", homes: novel),
                       .inGroupLinked("world"))
        let piece = StructureItem(id: "pA", title: "A", type: .document, path: "pieces/01-a/01-a.md",
                                  pieceKind: .loose, linkedResearchIds: ["shared"])
        let collection = ResearchHomes.derive(
            structure: [piece],
            research: [ResearchItem(id: "box", title: "Box", type: .group, path: "research/box",
                                    children: [note("shared")])],
            projectType: .collection)
        XCTAssertEqual(BinderPieceFold.creation(under: "box", inFoldOf: "pA", homes: collection),
                       .piecesScope, "a Collection files in the piece's own folder")
        let story = ResearchHomes.derive(
            structure: [chapter("doc")],
            research: [ResearchItem(id: "box", title: "Box", type: .group, path: "research/box")],
            projectType: .shortStory)
        XCTAssertEqual(BinderPieceFold.creation(under: "box", inFoldOf: "doc", homes: story), .asAsked,
                       "a single document's fold lists the book's research: every group is its")
    }

    // MARK: - Two folds, two rows (the lead's note on Task 4)

    /// **A note two chapters link is two rows that select apart**: a click in
    /// chapter two's fold draws THAT row selected, never chapter one's too.
    func test_aNoteInTwoFoldsSelectsOneRow() {
        let start = WindowSubject(open: .item("one"), faces: .item("one"))
        let inTwo = TreeRowTag.inFold(.research("both"), piece: "two")
        let write = BinderTreeSelection.resolvedTags(
            written: [inTwo], stored: [], storedFoldRow: nil, storedRowFolds: [:],
            shown: [.subject(.item("one"))], subject: start,
            structure: [chapter("one"), chapter("two")], research: [note("both")],
            figures: [], projectType: .novel)
        XCTAssertEqual(write.selection, [.research("both")])
        XCTAssertEqual(write.rowFolds, ["both": "two"])
        let drawn = BinderTreeSelection.shownTags(
            write.selection, foldRow: nil, subject: write.subject, clickedAt: write.subject,
            rowFold: { BinderTreeSelection.rowFold(of: $0, chosen: write.rowFolds, homes: self.homes,
                                                   openPiece: write.subject.openPieceId) })
        XCTAssertEqual(drawn, [inTwo], "the row clicked, and only it")
    }

    /// With nothing chosen (a reveal, a Find), the open chapter's row, else
    /// the first; the book's research is the section's row; a chosen fold that
    /// no longer holds the note gives way.
    func test_whichRowARevealedNoteIsDrawnIn() {
        let homes = homes
        XCTAssertEqual(BinderTreeSelection.rowFold(of: .research("both"), chosen: [:], homes: homes,
                                                    openPiece: "two"), "two")
        XCTAssertEqual(BinderTreeSelection.rowFold(of: .research("both"), chosen: [:], homes: homes,
                                                    openPiece: nil), "one")
        XCTAssertNil(BinderTreeSelection.rowFold(of: .research("book"), chosen: [:], homes: homes,
                                                  openPiece: "one"))
        XCTAssertEqual(BinderTreeSelection.rowFold(of: .research("solo"), chosen: ["solo": "three"],
                                                    homes: homes, openPiece: nil), "one",
                       "chapter three does not draw it")
        XCTAssertNil(BinderTreeSelection.rowFold(of: .item("one"), chosen: [:], homes: homes,
                                                  openPiece: nil))
    }

    func test_aKeyLandingInAFoldRemembersItsFold() {
        let start = WindowSubject(open: .item("one"), faces: .item("one"))
        let inOne = TreeRowTag.inFold(.research("both"), piece: "one")
        let write = BinderTreeSelection.resolvedTags(
            written: [inOne], stored: [], storedFoldRow: nil, storedRowFolds: [:],
            shown: [.subject(.item("one"))], subject: start,
            structure: [chapter("one")], research: [note("both")],
            figures: [], projectType: .novel, gesture: .keys)
        XCTAssertEqual(write.settle, .research("both"))
        XCTAssertEqual(write.rowFolds, ["both": "one"])
    }

    // MARK: - A click on a chapter opens its fold, for a while (E; the owner's ruling)

    private typealias Folds = TreeFoldAutoOpen.Folds

    private func landed(_ folds: Folds, on piece: String, _ gesture: TreeSelectionGesture = .pointer,
                        holds: Bool = true) -> Folds {
        TreeFoldAutoOpen.next(folds, on: .landed(piece: piece, gesture: gesture, holdsAnything: holds))
    }

    /// **The owner's table** (fix round 1, I3 + I7): a pointer click on a
    /// chapter opens its fold whatever it holds; the arrows never do; an
    /// auto-opened fold is transient — the next chapter closes it — unless
    /// the writer opened it or acted in it; a fold the writer closed stays
    /// closed on every return until they open it; ⌘⌥E opens; nothing is
    /// written to the writer's own fold state by the open itself.
    func test_theAutoOpenTable() {
        let start = Folds()
        // A click opens, for anything in the fold.
        let clicked = landed(start, on: "one")
        XCTAssertTrue(clicked.isOpen("one"))
        XCTAssertEqual(clicked.open, [], "the writer's own fold state is untouched")
        XCTAssertEqual(clicked.autoOpened, "one")
        XCTAssertFalse(landed(start, on: "one", holds: false).isOpen("one"), "nothing in it: no fold")
        // The arrows never open one.
        XCTAssertFalse(landed(start, on: "one", .keys).isOpen("one"), "arrow travel opens nothing")
        // Click away: the auto-opened fold closes; the arrows close it too.
        let away = landed(clicked, on: "two")
        XCTAssertFalse(away.isOpen("one"), "moving to another chapter closes the one opened for a click")
        XCTAssertTrue(away.isOpen("two"))
        XCTAssertFalse(landed(clicked, on: "two", .keys).isOpen("one"))
        XCTAssertFalse(landed(clicked, on: "two", .keys).isOpen("two"))
        // A fold the writer opened stays.
        let writerOpened = TreeFoldAutoOpen.next(start, on: .set(piece: "one", open: true))
        XCTAssertTrue(landed(landed(writerOpened, on: "one"), on: "two").isOpen("one"))
        // An auto-opened fold the writer then opens by hand is theirs.
        let adopted = TreeFoldAutoOpen.next(clicked, on: .set(piece: "one", open: true))
        XCTAssertTrue(landed(adopted, on: "two").isOpen("one"))
        // A fold the writer closed stays closed on every return…
        let closed = TreeFoldAutoOpen.next(clicked, on: .set(piece: "one", open: false))
        XCTAssertFalse(closed.isOpen("one"))
        let back = landed(landed(closed, on: "two"), on: "one")
        XCTAssertFalse(back.isOpen("one"), "the writer closed it: a return does not reopen it")
        // …until they open it.
        let reopened = TreeFoldAutoOpen.next(back, on: .set(piece: "one", open: true))
        XCTAssertTrue(landed(landed(reopened, on: "two"), on: "one").isOpen("one"))
        // Acting inside an auto-opened fold keeps it.
        let acted = TreeFoldAutoOpen.next(clicked, on: .actedIn(piece: "one"))
        XCTAssertTrue(landed(acted, on: "two").isOpen("one"), "selected, pulled up, dragged or made in it")
        XCTAssertEqual(TreeFoldAutoOpen.next(start, on: .actedIn(piece: "one")), start,
                       "acting in a fold the click did not open changes nothing")
        // ⌘⌥E opens (a writer's open), even one the writer closed before.
        let shown = TreeFoldAutoOpen.next(closed, on: .set(piece: "one", open: true))
        XCTAssertTrue(shown.isOpen("one"))
        // Re-landing on the open chapter changes nothing.
        XCTAssertEqual(landed(clicked, on: "one"), clicked)
    }

    /// **Through the tree's own setter**: a click on a chapter row (the
    /// `List`'s write; a test has no key event, so the gesture is the
    /// pointer's) opens its fold; a click on the next chapter closes it; a
    /// row selected inside an auto-opened fold keeps it.
    func test_theSetterOpensOnAClickAndClosesOnTheNext() async throws {
        let temp = TempDirectory()
        defer { temp.cleanup() }
        let url = try await ProjectFactory.createNovelProject(named: "Folds", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let one = try XCTUnwrap(store.manifest.structure.first)
        let two = try await store.addStructureItem(parentId: nil, title: "Two", kind: .document(.markdown))
        let tides = try await store.addResearchTextNote(parentId: nil, title: "Tides")
        let ships = try await store.addResearchTextNote(parentId: nil, title: "Ships")
        try await store.linkResearch(researchId: tides.id, toDocumentId: one.id)
        try await store.linkResearch(researchId: ships.id, toDocumentId: two.id)
        let state = BinderTreeSectionsState()
        var subject = WindowSubject.book
        let binding = Binding(get: { subject }, set: { subject = $0 })
        func click(_ tag: TreeRowTag) {
            BinderTreeSelection.write([tag], state: state, subject: binding, store: store)
        }
        click(.subject(.item(one.id)))
        XCTAssertTrue(state.folds.isOpen(one.id), "a click on the chapter opens its fold")
        XCTAssertFalse(state.expandedPieceFolds.contains(one.id), "…without writing the writer's own")
        click(.subject(.item(two.id)))
        XCTAssertFalse(state.folds.isOpen(one.id), "the next chapter closes it")
        XCTAssertTrue(state.folds.isOpen(two.id))
        click(.inFold(.research(ships.id), piece: two.id))
        click(.subject(.item(one.id)))
        XCTAssertTrue(state.folds.isOpen(two.id), "a row selected in it kept it open")
        XCTAssertTrue(state.foldExpansion(of: two.id).wrappedValue, "and the chevron reads the same")
    }

    /// **Who may land a fold open**: the tree's setter alone (a restore,
    /// a Find or navigation writes the subject, never a landing), and it
    /// calls the pure rule — no timer, no task (tripwire 3). The writer's
    /// chevron and ⌘⌥E go through the same rule as a writer's open.
    func test_onlyTheSetterLandsAFold() throws {
        var landings: [String: Int] = [:]
        for file in try SourceTree.swiftFiles(under: "Maugham") {
            let count = SourceScan.codeLines(of: try SourceTree.read(file))
                .filter { $0.contains("TreeFoldAutoOpen.afterWrite(") }.count
            if count > 0 { landings[file] = count }
        }
        XCTAssertEqual(landings, ["Maugham/Views/BinderTreeSections.swift": 1])
        let window = try CanvasSourceCensus.source(at: "Maugham/Views/ProjectWindow.swift")
        XCTAssertTrue(window.contains("treeState.setFold(id, open: true)"), "⌘⌥E is a writer's open")
        let wiring = try CanvasSourceCensus.source(at: "Maugham/Views/TreeWindowWiring.swift")
        XCTAssertFalse(wiring.contains("FoldOpen"), "no fold waits on a timer")
    }
}
