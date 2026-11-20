import XCTest
import AppKit
import SwiftUI
@testable import MaughamCore
@testable import Maugham

/// **The old Inspector's controls in the tree's row menu and the Outline**
/// (shell p3 Task 8): Tags…, Add Link…, Publishing… offered by the row's own
/// `TreeStructureVerbs`; the Outline's Tags column. Pure decisions and
/// censuses — nothing is pressed (tripwire 33).
@MainActor
final class PieceRowMenusTests: XCTestCase {

    private let chapter = StructureItem(id: "doc-a", title: "A", type: .document,
                                        path: "manuscript/a.md")

    private func verbs(_ posture: Posture, for item: StructureItem) -> TreeStructureVerbs {
        TreeStructureVerbs.decide(for: item, postureOf: { _ in posture })
    }

    func test_theRowMenuOffersTagsLinksAndPublishingWhereTheVerbsAllow() {
        let mine = verbs(.author, for: chapter)
        XCTAssertEqual(PieceRowMenus.items(for: chapter, verbs: mine, publishingIsSetUp: true),
                       [.tags, .addLink, .publishing])
        XCTAssertEqual(PieceRowMenus.items(for: chapter, verbs: mine, publishingIsSetUp: false),
                       [.tags, .addLink], "the inspector drew Publishing only once it was set up")
        XCTAssertEqual(PieceRowMenus.Item.allCases.map(\.title),
                       ["Tags…", "Add Link…", "Target…", "Publishing…"])
        // Target… where the status line would offer one — so a target can be
        // set with the status bar hidden — between the links and Publishing.
        XCTAssertEqual(PieceRowMenus.items(for: chapter, verbs: mine, publishingIsSetUp: true,
                                           offersTarget: true),
                       [.tags, .addLink, .target, .publishing])
        XCTAssertEqual(PieceRowSheet(.target, pieceId: "doc-a"), .target("doc-a"))
        XCTAssertEqual(PieceRowSheet.target("doc-a").pieceId, "doc-a")
        XCTAssertEqual(Set(PieceRowMenus.Item.allCases.map { PieceRowSheet($0, pieceId: "doc-a").id }).count,
                       PieceRowMenus.Item.allCases.count, "each sheet has an identity of its own")

        // A Collection's loose piece: the same three.
        var loose = StructureItem(id: "pc01", title: "One", type: .document, path: "pieces/one/one.md")
        loose.pieceKind = .loose
        XCTAssertEqual(PieceRowMenus.items(for: loose, verbs: verbs(.author, for: loose),
                                           publishingIsSetUp: true),
                       [.tags, .addLink, .publishing])

        // A group has none of these fields; a reference piece is another
        // project's.
        var group = StructureItem(id: "grp-a", title: "Part", type: .group, path: nil)
        group.children = [chapter]
        XCTAssertEqual(PieceRowMenus.items(for: group, verbs: verbs(.author, for: group),
                                           publishingIsSetUp: true), [])
        var reference = loose
        reference.pieceKind = .reference
        XCTAssertEqual(PieceRowMenus.items(for: reference, verbs: verbs(.author, for: reference),
                                           publishingIsSetUp: true), [])
    }

    /// Hidden, never disabled: the verbs a reviewer (or an undecided posture)
    /// gets offer no Rename, and so none of the items.
    func test_aRefusingPostureHidesTheMenuItems() throws {
        XCTAssertEqual(PieceRowMenus.items(for: chapter, verbs: .none, publishingIsSetUp: true), [])
        XCTAssertEqual(PieceRowMenus.items(for: chapter, verbs: verbs(.settling, for: chapter),
                                           publishingIsSetUp: true), [])
        // Every tree draws the items through the one view, handed the verbs
        // the row already decided — a screenplay's script row included.
        for file in Self.rowFiles {
            let code = try SourceTree.read(file)
            XCTAssertTrue(code.contains("PieceRowMenuButtons("),
                          "\(file) offers the row menu's items")
            XCTAssertTrue(code.contains("offersTarget: PieceRowMenus.target(for:"),
                          "\(file) asks the status line's own decision for Target…")
            XCTAssertFalse(code.contains(".sheet("),
                           "\(file): a row sheet is presented from the sections, never a row")
        }
        let sections = try SourceTree.read("Maugham/Views/BinderTreeSections.swift")
        XCTAssertTrue(sections.contains(".sheet(item: $state.pieceRowSheet)"))
    }

    /// The files whose rows carry the piece menu: both trees, and the
    /// screenplay's navigator (its one script row).
    static let rowFiles = ["Maugham/Views/BinderView.swift", "Maugham/Views/CollectionPiecesPane.swift",
                           "Maugham/Views/SceneNavigatorPane.swift"]

    /// **A screenplay's script row offers Tags…, Target… and Publishing… by
    /// posture** (Task 8's review: the old Inspector showed all three for the
    /// script, and a screenplay mounts neither other tree). No Add Link… —
    /// there is no other document to link to.
    func test_theScriptRowOffersTagsTargetAndPublishingByPosture() throws {
        let script = StructureItem(id: "script", title: "Script", type: .document,
                                   path: "script.fountain")
        func items(_ posture: Posture, publishing: Bool = true) -> [PieceRowMenus.Item] {
            let target = PieceTargetMenu.decide(
                piece: script, projectType: .screenplay, projectPageTarget: 110,
                postureOf: { _ in posture })
            return PieceRowMenus.items(
                for: script, verbs: verbs(posture, for: script), publishingIsSetUp: publishing,
                offersTarget: target != nil, offersLinks: false)
        }
        XCTAssertEqual(items(.author), [.tags, .target, .publishing])
        XCTAssertEqual(items(.author, publishing: false), [.tags, .target],
                       "Publishing… only once publishing is set up")
        XCTAssertEqual(items(.settling), [], "an undecided posture is offered nothing")
        // The script's target is the PROJECT's page target.
        XCTAssertEqual(PieceTargetMenu.decide(piece: script, projectType: .screenplay,
                                              projectPageTarget: 110, postureOf: { _ in .author }),
                       PieceTargetMenu(write: .projectPages, current: 110))

        // The wiring: the script row carries the menu, with no links.
        let pane = try SourceTree.read("Maugham/Views/SceneNavigatorPane.swift")
        let flat = SourceScan.codeLines(of: pane).joined(separator: "\n")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        XCTAssertTrue(flat.contains(
            ".contextMenu { if let script = TreeWalk.find(id: documentID, in: store.manifest.structure) { "
            + "PieceRowMenuButtons( item: script, verbs: structureVerbs(for: script), state: treeState, "
            + "offersTarget: PieceRowMenus.target(for: script, store: store) != nil, offersLinks: false) } }"),
            "the script row lost its menu")
        XCTAssertTrue(flat.contains(".binderTreeSections(store: store, state: treeState,"),
                      "premise: the navigator mounts the sections, whose sheets the menu opens")
        // And the sheet for Target… is the status line's own field.
        let menus = try SourceTree.read("Maugham/Views/PieceRowMenus.swift")
        XCTAssertTrue(menus.contains("PieceTargetField("), "Target… opens the same field")
        XCTAssertTrue(menus.contains("PieceTargetMenu.perform(menu.write, value: value, store: store)"))
    }

    /// Adding a link appends once (the inspector's rule).
    func test_addingALinkAppendsOnce() {
        XCTAssertEqual(PieceRowMenus.links(adding: "b", to: nil), ["b"])
        XCTAssertEqual(PieceRowMenus.links(adding: "b", to: ["a"]), ["a", "b"])
        XCTAssertEqual(PieceRowMenus.links(adding: "a", to: ["a"]), ["a"])
        let structure = [chapter,
                         StructureItem(id: "doc-b", title: "Bridge", type: .document, path: "b.md"),
                         StructureItem(id: "doc-c", title: "Coda", type: .document, path: "c.md")]
        XCTAssertEqual(PieceLinkSearch.candidates(in: structure, currentItemId: "doc-a",
                                                  existing: ["doc-c"], query: "").map(\.id),
                       ["doc-b"], "not itself, not one already linked")
        XCTAssertEqual(PieceLinkSearch.candidates(in: structure, currentItemId: "doc-a",
                                                  existing: [], query: "co").map(\.id), ["doc-c"])
    }

    /// **Census**: nothing on the row menu or the status line writes a pass
    /// state (`PassStateWriterCensusTests` gains no file).
    func test_noRowMenuItemWritesAPassState() throws {
        for file in ["Maugham/Views/PieceRowMenus.swift", "Maugham/Views/PieceTargetMenu.swift",
                     "Maugham/Views/EditorStatusFooter.swift",
                     "Maugham/Views/Publish/PiecePublishSettings.swift"] {
            let code = try SourceTree.read(file)
            let lines = code.split(separator: "\n").filter {
                !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
            }
            XCTAssertFalse(lines.contains { $0.contains("setPassState(") },
                           "\(file) writes a pass state")
            XCTAssertFalse(lines.contains { $0.contains("passStates") }, "\(file) touches passStates")
        }
        // The census can fail: the right column, which hosts To resolve's
        // ladder and nudge, writes one.
        let column = try SourceTree.read("Maugham/Views/RightColumn.swift")
        XCTAssertTrue(column.contains("store.setPassState("))
    }

    /// **The Outline's Tags column**: the manifest's tags, comma-joined, read
    /// from the row's own value.
    func test_theOutlineHasATagsColumn() throws {
        var tagged = chapter
        tagged.tags = ["winter", "Ada"]
        XCTAssertEqual(OutlineTable.tagsCell(tagged), "winter, Ada")
        XCTAssertEqual(OutlineTable.tagsCell(chapter), "")
        XCTAssertEqual(OutlineTable.tagsColumnTitle, "Tags")
        let code = try SourceTree.read("Maugham/Views/OutlineTable.swift")
        XCTAssertTrue(code.contains("TableColumn(Self.tagsColumnTitle)"))
        XCTAssertTrue(code.contains("Text(Self.tagsCell(item))"),
                      "the cell is the pure value, no per-row work (tripwire 4)")
    }

    func test_tagSuggestionsAreEveryTagInTheBookSorted() {
        var a = chapter
        a.tags = ["winter", "Ada"]
        var b = StructureItem(id: "doc-b", title: "B", type: .document, path: "b.md")
        b.tags = ["Ada", "sea"]
        var group = StructureItem(id: "grp", title: "G", type: .group, path: nil)
        group.children = [b]
        XCTAssertEqual(PieceRowMenus.tagSuggestions(in: [a, group]), ["Ada", "sea", "winter"])
    }
}

/// **Whose piece this is, at the head of To resolve** (shell p3 Task 8; the
/// old Inspector's *Written by* row, moved under the ladder).
@MainActor
final class ResolveWhoseLineTests: XCTestCase {

    private var temp: TempDirectory!

    override func setUp() async throws { temp = TempDirectory() }

    override func tearDown() async throws {
        PieceWriterFixture.reset()
        temp.cleanup()
        temp = nil
    }

    /// The line is drawn only where `PieceWriters` draws a sentence: a book
    /// whose permits name pieces, on the pieces they name.
    func test_whoseLineIsInTheHeadOnlyWhereThereAreSeveralWriters() async throws {
        let alone = try await PieceWriterFixture.oneAuthor(named: "Alone", in: temp.url)
        let aloneWriters = await PieceWriters.read(
            projectURL: alone.url,
            pieces: PermitControl.pieces(in: alone.store.manifest.structure))
        for id in alone.pieceIDs {
            XCTAssertNil(ResolveHead.whoseLine(aloneWriters, docId: id),
                         "a book with one writer names nobody")
        }
        PieceWriterFixture.reset()

        let shared = try await PieceWriterFixture.narrowed(
            named: "Shared", in: temp.url, scopedTo: { [$0.pieceIDs[0]] })
        let writers = await PieceWriters.read(
            projectURL: shared.url,
            pieces: PermitControl.pieces(in: shared.store.manifest.structure))
        XCTAssertEqual(ResolveHead.whoseLine(writers, docId: shared.pieceIDs[0]), "Sam")
        if shared.pieceIDs.count > 1 {
            XCTAssertNil(ResolveHead.whoseLine(writers, docId: shared.pieceIDs[1]),
                         "a chapter nobody's scope names has no line")
        }

        // The head reads it once per project, under the ladder.
        let code = try SourceTree.read("Maugham/Views/Resolve/ResolveHead.swift")
        XCTAssertTrue(code.contains("ResolveWhoseLineHost(store: store, docId: docId)"))
        XCTAssertTrue(code.contains("if let by = ResolveHead.whoseLine(writers, docId: docId)"))
        XCTAssertTrue(code.contains(".task(id: store.url)"))
    }

    /// **A measurement** (allow-listed shape, tripwire 33): the line fits To
    /// resolve's head in a 240pt column, wrapping a long list of names.
    func test_theWhoseLineFitsTheHeadAt240() {
        let names = PieceWriters.sentence(naming: [
            "Alexandria Montgomery-Featherstonehaugh", "Bartholomew Quince",
            "Cordelia Wainwright", "Dmitri"]) ?? ""
        let pane = 240 - RightColumn.resizeHandleWidth - 24  // the head's 12pt insets
        let size = NSHostingController(rootView: ResolveWhoseLine(sentence: names))
            .sizeThatFits(in: CGSize(width: pane, height: 400))
        XCTAssertLessThanOrEqual(size.width, pane + 0.5, "the line fits a 240pt column")
        XCTAssertGreaterThan(size.height, 30, "a long list wraps rather than truncating")
    }
}
