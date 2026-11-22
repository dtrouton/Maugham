import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// Shell p4 Task 10 (c): **the keys reach every fold row.** A fold's card,
/// region, palette pin and figure carry a tree-local tag
/// (`TreeRowTag.pullUp`), so the arrow keys land on them as on any row and
/// the landing pulls the row up beside; every other row's tag is today's
/// subject, through today's click rule. Pure where the rule is pure; one
/// mounted read through the `List`'s own selection; censuses for the wiring.
@MainActor
final class BinderTreeSelectionTests: XCTestCase {

    private let structure: [StructureItem] = [
        StructureItem(id: "ch-1", title: "One", type: .document, path: "one.md"),
        StructureItem(id: "ch-2", title: "Two", type: .document, path: "two.md"),
    ]
    private let research: [ResearchItem] = [
        ResearchItem(id: "res-1", title: "Tides", type: .asset, kind: .document,
                     path: "research/tides.md"),
    ]
    private let chapter = WindowSubject(open: .item("ch-1"), faces: .item("ch-1"))

    private func write(_ written: Set<TreeRowTag>, from subject: WindowSubject,
                       stored: Set<BinderSubject> = [], storedPullUp: PulledUp? = nil,
                       clickedAt: WindowSubject? = nil) -> BinderTreeSelection.TagWrite {
        BinderTreeSelection.resolvedTags(
            written: written, stored: stored, storedPullUp: storedPullUp,
            shown: BinderTreeSelection.shownTags(stored, pullUp: storedPullUp,
                                                  subject: subject, clickedAt: clickedAt),
            subject: subject, structure: structure, research: research, figures: [],
            projectType: .novel)
    }

    // MARK: - The pull-up tag

    func test_aPullUpTagWritePullsTheRowUp() {
        for pulled: PulledUp in [.canvasScrap(nodeId: "s1"), .canvasPhoto(path: "canvas_assets/a.png"),
                                 .canvasRegion(id: "r1"), .research("pal-1"), .figure("fig-1")] {
            let next = write([.pullUp(pulled)], from: chapter)
            XCTAssertEqual(next.subject.beside, pulled, "\(pulled) is pulled up beside")
            XCTAssertEqual(next.subject.open, chapter.open, "the centre never moves")
            XCTAssertEqual(next.subject.faces, chapter.faces, "the faces never move")
            XCTAssertEqual(next.pullUp, pulled, "and the List keeps drawing it selected")
            XCTAssertEqual(next.selection, [])
            // Drawn selected while the subject is the one the landing made.
            XCTAssertEqual(BinderTreeSelection.shownTags(next.selection, pullUp: next.pullUp,
                                                          subject: next.subject,
                                                          clickedAt: next.subject),
                           [.pullUp(pulled)])
        }
    }

    /// Landing on the row already up never puts it away (only a click on it,
    /// Return, or Close does).
    func test_aPullUpTagOnTheRowAlreadyUpKeepsItUp() {
        var up = chapter
        up.beside = .canvasRegion(id: "r1")
        let next = write([.pullUp(.canvasRegion(id: "r1"))], from: up)
        XCTAssertEqual(next.subject.beside, .canvasRegion(id: "r1"))
    }

    /// Arrowing off a fold row onto a chapter is today's click on the chapter.
    func test_aSubjectTagWriteIsTodaysClick() {
        var beside = chapter
        beside.beside = .canvasScrap(nodeId: "s1")
        let cases: [(written: BinderSubject, from: WindowSubject)] = [
            (.item("ch-2"), chapter),
            (.research("res-1"), chapter),
            (.project, chapter),
            (.canvas, chapter),
            (.item("ch-2"), beside),
            (.research("res-1"), beside),
        ]
        for (row, subject) in cases {
            let viaTags = write([.subject(row)], from: subject,
                                storedPullUp: .canvasScrap(nodeId: "s1"), clickedAt: subject)
            let today = BinderTreeSelection.resolved(
                written: [row], stored: [], shown: [], subject: subject,
                structure: structure, research: research, figures: [], projectType: .novel)
            XCTAssertEqual(viaTags.subject, today.subject, "\(row) from \(subject)")
            XCTAssertEqual(viaTags.selection, today.selection)
            XCTAssertNil(viaTags.pullUp, "a subject write lets the fold row go")
        }
    }

    /// The `List` handing back what it drew moves nothing.
    func test_theListHandingBackItsOwnSelectionMovesNothing() {
        var up = chapter
        up.beside = .canvasScrap(nodeId: "s1")
        let next = write([.pullUp(.canvasScrap(nodeId: "s1"))], from: up,
                         storedPullUp: .canvasScrap(nodeId: "s1"), clickedAt: up)
        XCTAssertEqual(next.subject, up)
        XCTAssertEqual(next.pullUp, .canvasScrap(nodeId: "s1"))
    }

    /// A subject moved elsewhere (a mouse click on a row's button, Close) is
    /// drawn as today: the window's last-clicked row.
    func test_aSubjectMovedElsewhereDrawsTodaysRow() {
        var moved = chapter
        moved.faces = .item("ch-2")
        XCTAssertEqual(BinderTreeSelection.shownTags([], pullUp: .canvasScrap(nodeId: "s1"),
                                                     subject: moved, clickedAt: chapter),
                       [.subject(.item("ch-2"))])
    }

    // MARK: - The keys

    func test_whatEachKeyDoesOnEachRowKind() {
        let pulls: [PulledUp] = [.canvasScrap(nodeId: "s1"), .canvasRegion(id: "r1"),
                                 .research("pal-1"), .figure("fig-1")]
        for pulled in pulls {
            XCTAssertEqual(TreeRowKeys.act(.returnOrSpace, drawn: [.pullUp(pulled)]), .click(pulled))
            XCTAssertEqual(TreeRowKeys.act(.openInCentre, drawn: [.pullUp(pulled)]),
                           .openInCentre(.pullUp(pulled)))
        }
        for row: BinderSubject in [.item("ch-1"), .research("res-1"), .project, .canvas] {
            XCTAssertNil(TreeRowKeys.act(.returnOrSpace, drawn: [.subject(row)]),
                         "landing on \(row) already did what its click does")
            XCTAssertEqual(TreeRowKeys.act(.openInCentre, drawn: [.subject(row)]),
                           .openInCentre(.subject(row)))
        }
        XCTAssertNil(TreeRowKeys.act(.openInCentre, drawn: []))
        XCTAssertNil(TreeRowKeys.act(.openInCentre, drawn: [.subject(.item("ch-1")),
                                                            .subject(.item("ch-2"))]),
                     "a multi-selection is no one row to open")
    }

    func test_theKeysAreReturnSpaceAndCommandDown() {
        XCTAssertEqual(TreeRowKeys.key(.return, modifiers: []), .returnOrSpace)
        XCTAssertEqual(TreeRowKeys.key(.space, modifiers: []), .returnOrSpace)
        XCTAssertEqual(TreeRowKeys.key(.downArrow, modifiers: .command), .openInCentre)
        XCTAssertEqual(TreeRowKeys.key(.downArrow, modifiers: [.command, .numericPad]), .openInCentre)
        XCTAssertNil(TreeRowKeys.key(.downArrow, modifiers: []), "the List's own arrow")
        XCTAssertNil(TreeRowKeys.key(.return, modifiers: .command))
        XCTAssertNil(TreeRowKeys.key(.downArrow, modifiers: [.command, .option]))
    }

    /// Return on the row up puts it away and keeps it selected, so a second
    /// Return brings it back.
    func test_returnTogglesThePulledUpRow() {
        let up = TreeRowKeys.clicked(.canvasRegion(id: "r1"), subject: chapter)
        XCTAssertEqual(up.beside, .canvasRegion(id: "r1"))
        let away = TreeRowKeys.clicked(.canvasRegion(id: "r1"), subject: up)
        XCTAssertNil(away.beside)
        XCTAssertEqual(away.open, chapter.open)
        XCTAssertEqual(BinderTreeSelection.shownTags([], pullUp: .canvasRegion(id: "r1"),
                                                     subject: away, clickedAt: away),
                       [.pullUp(.canvasRegion(id: "r1"))],
                       "the row stays the one selected")
        // The same act the mouse's click makes.
        let entry: PieceFoldEntry = .region(id: "r1", title: "Fog", cards: [])
        XCTAssertEqual(BinderPieceFold.clicked(entry, subject: up, structure: structure,
                                               projectType: .novel), away)
    }

    func test_voiceOverNamesEachRowAndWhatActivatingItDoes() {
        let scrap: PieceFoldEntry = .card(PinnedReference(id: "s1", kind: .scrap(nodeId: "s1"),
                                                          title: "A thought"))
        XCTAssertEqual(BinderPieceFold.accessibilityLabel(scrap, title: "A thought"), "Card: A thought")
        XCTAssertEqual(BinderPieceFold.accessibilityLabel(
            .region(id: "r1", title: "Fog", cards: []), title: "Fog"), "Region: Fog")
        XCTAssertEqual(BinderPieceFold.accessibilityLabel(
            .palette(id: "p", title: "Rust"), title: "Rust"), "Palette card: Rust")
        XCTAssertEqual(BinderPieceFold.accessibilityLabel(
            .figure(id: "f", name: "Map"), title: "Map"), "Figure: Map")
        XCTAssertEqual(BinderPieceFold.accessibilityLabel(
            .card(PinnedReference(id: "a.png", kind: .photo(path: "a.png"), title: "Picture")),
            title: "Picture"), "Picture: Picture")
        XCTAssertTrue(BinderPieceFold.accessibilityHint(scrap, subject: chapter)
            .hasPrefix("Activate to pull it up beside"))
        var up = chapter
        up.beside = .canvasScrap(nodeId: "s1")
        XCTAssertTrue(BinderPieceFold.accessibilityHint(scrap, subject: up)
            .contains("put it away"))
    }

    // MARK: - Census

    /// Every row `pullUpRow` draws carries the tag, and nothing else in the
    /// fold tags a pull-up — the disable experiment's first witness.
    func test_everyFoldPullUpRowCarriesATag() throws {
        let source = try CanvasSourceCensus.source(at: "Maugham/Views/BinderPieceFold.swift")
        let start = try XCTUnwrap(source.range(of: "private func pullUpRow("))
        let end = try XCTUnwrap(source.range(of: "private func thumbnailSource(",
                                             range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound])
        XCTAssertTrue(body.contains(".tag(Self.tag(of: entry))"),
                      "a pull-up row is a List row the keys reach")
        XCTAssertEqual(source.components(separatedBy: ".tag(Self.tag(of:").count - 1, 1)
        // Every kind `pullUpRow` draws names what it pulls up.
        for entry: PieceFoldEntry in [
            .card(PinnedReference(id: "s1", kind: .scrap(nodeId: "s1"), title: "S")),
            .region(id: "r1", title: "R", cards: []), .palette(id: "p", title: "P"),
            .figure(id: "f", name: "F"),
        ] {
            XCTAssertNotNil(entry.pulledUp)
            XCTAssertEqual(BinderPieceFold.tag(of: entry), .pullUp(entry.pulledUp!))
        }
        // The rows that travel carry none.
        XCTAssertEqual(source.components(separatedBy: "\n").filter { $0.contains(".tag(") }.count, 1,
                       "link and scene rows stay buttons")
    }

    /// The binding's setter calls only the rule and the record (tripwire 3).
    func test_theBindingSetterCallsOnlyTheRule() throws {
        let source = try CanvasSourceCensus.source(at: "Maugham/Views/BinderTreeSections.swift")
        let start = try XCTUnwrap(source.range(of: "    static func write(_ written: Set<TreeRowTag>"))
        let end = try XCTUnwrap(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound])
        for call in ["resolvedTags(", "state.record(", "drawnTags(", "drawnFigureOrder("] {
            XCTAssertTrue(body.contains(call), call)
        }
        for forbidden in ["Task", "await", "perform", "post("] {
            XCTAssertFalse(body.contains(forbidden), "the setter does \(forbidden)")
        }
        XCTAssertTrue(source.contains("ClickRule.pullUp(one, current: subject)"),
                      "a pull-up landing is ClickRule.pullUp")
    }

    /// Each host's `List` selects over tags, and each carries the keys.
    func test_everyTreeHostSelectsOverTagsAndCarriesTheKeys() throws {
        for path in ["Maugham/Views/BinderView.swift", "Maugham/Views/CollectionPiecesPane.swift",
                     "Maugham/Views/SceneNavigatorPane.swift"] {
            let source = try CanvasSourceCensus.source(at: path)
            XCTAssertTrue(source.contains(".treeRowKeys(store: store, state: treeState"), path)
            XCTAssertFalse(source.contains(".tag(BinderSubject."), "\(path) tags a bare subject")
        }
    }

    // MARK: - Mounted: the List's own selection

    func test_selectingAFoldCardRowPullsItUpAndMovesNothingElse() async throws {
        let temp = TempDirectory()
        defer { temp.cleanup() }
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: store.url)
        store.documentStore = ds
        let chapterId = try XCTUnwrap(store.manifest.structure.first?.id)
        var scene = CanvasScene()
        let scrap = CanvasNodeID("s1")
        scene.insert(CanvasNode(id: scrap, kind: .scrap, origin: .zero, width: 240, cachedHeight: 80))
        scene.setBoundPiece(chapterId, for: scrap)
        CanvasStore(projectRoot: store.url).save(scene: scene, scraps: [scrap: "A thought"])

        let probe = FoldKeysSubjectProbe(WindowSubject(open: .item(chapterId), faces: .item(chapterId)))
        let state = BinderTreeSectionsState()
        let window = TestWindow.mount(AnyView(FoldKeysProbeBinder(store: store, probe: probe,
                                                                         state: state)),
                                      size: CGSize(width: 320, height: 800),
                                      as: SilentTestWindow.self)
        defer {
            window.contentView = NSView(frame: .zero)
            Task { await ds.close() }
        }
        _ = await pumpUntil(deadline: 5) { state.foldIndex.entries[chapterId]?.isEmpty == false }
        let outline = try XCTUnwrap(outline(in: window))
        let chapterRow = TreeFurniture.firstManuscriptRow
        let item = try XCTUnwrap(outline.item(atRow: chapterRow))
        XCTAssertTrue(outline.isExpandable(item), "premise: the chapter has a fold")
        outline.expandItem(item)
        pump(0.2)

        let before = probe.subject
        outline.selectRowIndexes(IndexSet(integer: chapterRow + 1), byExtendingSelection: false)
        XCTAssertEqual(probe.subject.beside, .canvasScrap(nodeId: scrap.raw),
                       "the List's own selection on the card row pulls the card up")
        XCTAssertEqual(probe.subject.open, before.open)
        XCTAssertEqual(probe.subject.faces, before.faces)
        XCTAssertEqual(state.selectedPullUp, .canvasScrap(nodeId: scrap.raw))
    }

    private func outline(in window: NSWindow) -> NSOutlineView? {
        var stack: [NSView] = window.contentView.map { [$0] } ?? []
        while let next = stack.popLast() {
            if let found = next as? NSOutlineView { return found }
            stack.append(contentsOf: next.subviews)
        }
        return nil
    }
}

@MainActor
private final class FoldKeysSubjectProbe {
    var subject: WindowSubject
    init(_ subject: WindowSubject) { self.subject = subject }
}

@MainActor
private struct FoldKeysProbeBinder: View {
    let store: ProjectStore
    let probe: FoldKeysSubjectProbe
    let state: BinderTreeSectionsState

    var body: some View {
        TreeHostFixture.binder(store: store,
                               subject: Binding(get: { probe.subject }, set: { probe.subject = $0 }),
                               treeState: state)
    }
}
