import XCTest
import MaughamCore
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
        XCTAssertTrue(node.contains("actions.performHome(target.verb)"))
        XCTAssertTrue(node.contains("actions.performHome(whole.verb)"))
        XCTAssertTrue(node.contains("actions.performHome(remove.verb)"))
        let verbs = SourceScan.codeLines(of: try SourceTree.read("Maugham/Views/BinderTreeSections.swift"))
            .joined(separator: "\n")
        XCTAssertTrue(verbs.contains("homeMenu: { item, fold in homeMenu(for: item, inFold: fold) }"))
        XCTAssertTrue(verbs.contains("performHome: { verb in performHome(verb) }"))
        XCTAssertTrue(verbs.contains("mayLink: { mayEditResearchLinks(of: $0) })"))
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

    // MARK: - Selecting a chapter opens its fold (E)

    private let one = WindowSubject(open: .item("one"), faces: .item("one"))
    private let two = WindowSubject(open: .item("two"), faces: .item("two"))

    func test_aPointersLandingOpensTheFoldAtOnce() throws {
        let landing = try XCTUnwrap(TreeFoldAutoOpen.landing(from: one, to: two, gesture: .pointer, at: 10))
        XCTAssertFalse(landing.settles)
        XCTAssertTrue(TreeFoldAutoOpen.opens(landing, now: 10, subject: two,
                                             foldHoldsAnything: true, foldIsOpen: false))
    }

    /// **Holding ↓ never pops folds open**: a key's landing opens only once
    /// the settle delay has passed with the chapter still the one open.
    func test_aKeysLandingOpensOnlyOnceItSettles() throws {
        let landing = try XCTUnwrap(TreeFoldAutoOpen.landing(from: one, to: two, gesture: .keys, at: 10))
        XCTAssertTrue(landing.settles)
        XCTAssertFalse(TreeFoldAutoOpen.opens(landing, now: 10.1, subject: two,
                                              foldHoldsAnything: true, foldIsOpen: false),
                       "within the delay: not yet")
        XCTAssertTrue(TreeFoldAutoOpen.opens(landing, now: 10 + TreeFoldAutoOpen.settleSeconds,
                                             subject: two, foldHoldsAnything: true, foldIsOpen: false))
        let three = WindowSubject(open: .item("three"), faces: .item("three"))
        XCTAssertFalse(TreeFoldAutoOpen.opens(landing, now: 11, subject: three,
                                              foldHoldsAnything: true, foldIsOpen: false),
                       "the keys moved on: chapter two's fold stays shut")
        XCTAssertEqual(TreeFoldAutoOpen.settleSeconds, 0.3, accuracy: 0.0001,
                       "the arrows' own settle delay (`TreeRowSettle.delay`)")
    }

    /// One rule for the fold, not research alone: anything in it opens it;
    /// nothing in it opens nothing.
    func test_anEmptyFoldDoesNotOpen() throws {
        let landing = try XCTUnwrap(TreeFoldAutoOpen.landing(from: one, to: two, gesture: .pointer, at: 0))
        XCTAssertFalse(TreeFoldAutoOpen.opens(landing, now: 0, subject: two,
                                              foldHoldsAnything: false, foldIsOpen: false))
    }

    /// **A fold the writer closed stays closed while the chapter stays
    /// selected**: only a landing — a change of the open piece — opens one, so
    /// a write that re-selects the open chapter (or selects within it) is none.
    func test_reselectingTheOpenChapterIsNoLanding() {
        XCTAssertNil(TreeFoldAutoOpen.landing(from: two, to: two, gesture: .pointer, at: 0))
        var beside = two
        beside.beside = .research("both")
        XCTAssertNil(TreeFoldAutoOpen.landing(from: two, to: beside, gesture: .pointer, at: 0),
                     "pulling a note up beside is no landing")
        XCTAssertNil(TreeFoldAutoOpen.landing(
            from: two, to: WindowSubject(open: .project, faces: .project), gesture: .pointer, at: 0))
    }

    /// The setter records the landing and the window opens it — outside the
    /// setter (tripwire 3), on the settle rule's own clock.
    func test_theLandingIsRecordedInTheSetterAndOpenedByTheWindow() throws {
        let tree = try CanvasSourceCensus.source(at: "Maugham/Views/BinderTreeSections.swift")
        XCTAssertTrue(tree.contains("if let landing = TreeFoldAutoOpen.landing(from: current, to: next.subject,"))
        let wiring = try CanvasSourceCensus.source(at: "Maugham/Views/TreeWindowWiring.swift")
        XCTAssertTrue(wiring.contains(".task(id: state.pendingFoldOpen)"))
        XCTAssertTrue(wiring.contains("if TreeFoldAutoOpen.opens("))
        XCTAssertTrue(wiring.contains("state.expandedPieceFolds.insert(pending.piece)"))
        XCTAssertFalse(wiring.contains("expandedPieceFolds.remove"), "it only ever opens")
    }
}
