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
                       clickedAt: WindowSubject? = nil,
                       gesture: TreeSelectionGesture = .pointer,
                       recentPress: @escaping (PulledUp) -> Bool = { _ in false })
        -> BinderTreeSelection.TagWrite {
        BinderTreeSelection.resolvedTags(
            written: written, stored: stored, storedPullUp: storedPullUp,
            shown: BinderTreeSelection.shownTags(stored, pullUp: storedPullUp,
                                                  subject: subject, clickedAt: clickedAt),
            subject: subject, structure: structure, research: research, figures: [],
            projectType: .novel, gesture: gesture, recentPress: recentPress)
    }

    // MARK: - The pull-up tag

    /// The arrow ruling: a key landing on a fold row SELECTS at once, moves
    /// nothing, and waits to settle; a pointer's selection only selects (the
    /// row's button is the click's act).
    /// **Closing review M6, verified**: Return or Space during a research
    /// row's inline rename never pulls the row up — every research row the
    /// tree draws renames through `state.renamingItemId`, the flag the keys'
    /// guard reads.
    func test_aResearchRenameInTheTreeHoldsTheRowKeys() throws {
        let guardLine = "guard !hostIsRenaming, state.renamingItemId == nil,"
        let keys = SourceScan.codeLines(of: try SourceTree.declaration(
            named: "struct TreeRowKeysModifier", under: "Maugham")).joined(separator: "\n")
        XCTAssertTrue(keys.contains(guardLine))
        for file in ["Maugham/Views/BinderTreeSections.swift", "Maugham/Views/BinderPieceFold.swift"] {
            let code = SourceScan.codeLines(of: try SourceTree.read(file))
            for (index, line) in code.enumerated() where line.contains("ResearchTreeNode(") {
                let call = code[index..<min(index + 4, code.count)].joined(separator: " ")
                XCTAssertTrue(call.contains("renamingItemId: $state.renamingItemId"),
                              "\(file): a research row renames through the tree's state")
            }
        }
    }

    func test_aKeyLandingOnAPullUpRowSelectsAndWaitsToSettle() {
        for pulled: PulledUp in [.canvasScrap(nodeId: "s1"), .canvasPhoto(path: "canvas_assets/a.png"),
                                 .canvasRegion(id: "r1"), .research("pal-1"), .figure("fig-1")] {
            let keys = write([.pullUp(pulled)], from: chapter, gesture: .keys)
            XCTAssertEqual(keys.subject, chapter, "\(pulled): the setter moves nothing")
            XCTAssertEqual(keys.pullUp, pulled, "and the List draws it selected")
            XCTAssertEqual(keys.settle, pulled, "it waits to settle")
            XCTAssertEqual(BinderTreeSelection.shownTags(keys.selection, pullUp: keys.pullUp,
                                                          subject: keys.subject,
                                                          clickedAt: keys.subject),
                           [.pullUp(pulled)])
            let pointer = write([.pullUp(pulled)], from: chapter, gesture: .pointer)
            XCTAssertEqual(pointer.subject, chapter)
            XCTAssertNil(pointer.settle, "a click's selection waits for nothing")
            let sameClick = write([.pullUp(pulled)], from: chapter, gesture: .keys,
                                  recentPress: { $0 == pulled })
            XCTAssertNil(sameClick.settle, "the same click's other arrival waits for nothing")
        }
    }

    /// Research rows follow the same rule from the keys; a pointer's click on
    /// one is today's click.
    func test_aKeyLandingOnAResearchRowSelectsAndWaitsToSettle() {
        let keys = write([.subject(.research("res-1"))], from: chapter, gesture: .keys)
        XCTAssertEqual(keys.subject, chapter)
        XCTAssertEqual(keys.selection, [.research("res-1")])
        XCTAssertEqual(keys.settle, .research("res-1"))
        let click = write([.subject(.research("res-1"))], from: chapter, gesture: .pointer)
        XCTAssertEqual(click.subject.beside, .research("res-1"), "a click pulls it up at once")
        XCTAssertNil(click.settle)
        // A chapter from the keys is today's click (the faces move).
        let chapterTwo = write([.subject(.item("ch-2"))], from: chapter, gesture: .keys)
        XCTAssertEqual(chapterTwo.subject.faces, .item("ch-2"))
        XCTAssertNil(chapterTwo.settle)
    }

    /// The settle: pulled up only where the column already shows the
    /// pulled-up position; otherwise the selection alone moved.
    func test_aSettledLandingPullsUpOnlyWhereTheColumnShowsThePulledUpPosition() {
        let pulled = PulledUp.canvasScrap(nodeId: "s1")
        XCTAssertEqual(TreeRowSettle.settled(pulled, subject: chapter, columnShowsPulledUp: true)?.beside,
                       pulled)
        XCTAssertNil(TreeRowSettle.settled(pulled, subject: chapter, columnShowsPulledUp: false),
                     "never reveals a hidden column nor swaps To resolve or Brief away")
        var up = chapter
        up.beside = pulled
        XCTAssertNil(TreeRowSettle.settled(pulled, subject: up, columnShowsPulledUp: true),
                     "already up: nothing moves (and Back records nothing)")
        XCTAssertTrue(TreeRowSettle.columnShowsPulledUp(showInspector: true, position: .pulledUp))
        XCTAssertFalse(TreeRowSettle.columnShowsPulledUp(showInspector: false, position: .pulledUp))
        XCTAssertFalse(TreeRowSettle.columnShowsPulledUp(showInspector: true, position: .resolve))
        XCTAssertEqual(TreeRowSettle.delay, .milliseconds(300))
    }

    func test_aSelectionsGestureIsReadOffTheEvent() {
        XCTAssertEqual(TreeSelectionGesture.of(.keyDown), .keys)
        XCTAssertEqual(TreeSelectionGesture.of(nil), .pointer, "a selection set in code is a click's")
        XCTAssertEqual(TreeSelectionGesture.of(.flagsChanged), .pointer)
    }

    /// **Review I1: a click on a fold row is one act, whichever of the
    /// table's selection and the button's action arrives first** — the
    /// outcome is decided from the state before the click, the second
    /// arrival is a no-op, and nothing waits to settle afterwards. Both
    /// orders, both readings of the selection's gesture, a row up and not.
    func test_aClickOnAFoldRowIsOneActInEitherOrder() {
        let entry: PieceFoldEntry = .card(PinnedReference(id: "s1", kind: .scrap(nodeId: "s1"),
                                                          title: "A thought"))
        let pulled = entry.pulledUp!
        var up = chapter
        up.beside = pulled
        for before in [chapter, up] {
            let expected = BinderPieceFold.clicked(entry, subject: before, structure: structure,
                                                   projectType: .novel)
            for gesture: TreeSelectionGesture in [.pointer, .keys] {
                // The selection first, then the button.
                let selected = write([.pullUp(pulled)], from: before, gesture: gesture)
                let pressed = BinderPieceFold.buttonPress(
                    entry, at: 10.0, last: nil, interval: 0.5, subject: selected.subject,
                    structure: structure, projectType: .novel)
                XCTAssertEqual(pressed.subject, expected, "selection then button, \(gesture)")
                // The button clears what waits (`pressed` sets pendingSettle = nil).
                // The button first, then the selection.
                let first = BinderPieceFold.buttonPress(
                    entry, at: 10.0, last: nil, interval: 0.5, subject: before,
                    structure: structure, projectType: .novel)
                let then = write([.pullUp(pulled)], from: first.subject!, gesture: gesture,
                                 recentPress: {
                                     BinderPieceFold.pressedJustNow($0, last: first.rowPress,
                                                                    now: 10.1, interval: 0.5)
                                 })
                XCTAssertEqual(then.subject, expected, "button then selection, \(gesture)")
                XCTAssertNil(then.settle, "and nothing pulls it back up later")
            }
            // The double-click: the pair's second press opens in the centre.
            let one = BinderPieceFold.buttonPress(entry, at: 10.0, last: nil, interval: 0.5,
                                                  subject: before, structure: structure,
                                                  projectType: .novel)
            let two = BinderPieceFold.buttonPress(entry, at: 10.2, last: one.lastFoldPress,
                                                  interval: 0.5, subject: one.subject!,
                                                  structure: structure, projectType: .novel)
            XCTAssertEqual(two.press, .double)
            XCTAssertNil(two.subject, "the view opens it in the centre")
        }
        XCTAssertFalse(BinderPieceFold.pressedJustNow(
            pulled, last: .init(pulled: pulled, at: 10), now: 11, interval: 0.5), "too late")
        XCTAssertFalse(BinderPieceFold.pressedJustNow(
            .canvasRegion(id: "r1"), last: .init(pulled: pulled, at: 10), now: 10.1, interval: 0.5),
            "another row")
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
        XCTAssertEqual(TreeRowKeys.act(.returnOrSpace, drawn: [.subject(.research("res-1"))]),
                       .click(.research("res-1")), "a research row's Return pulls it up now")
        for row: BinderSubject in [.item("ch-1"), .project, .canvas] {
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

    /// Return / Space pulls up NOW and shows the column; on the row up and
    /// shown it puts it away. The row stays selected (the modifier records it).
    func test_returnPullsUpNowAndShowsTheColumn() {
        let region = PulledUp.canvasRegion(id: "r1")
        let hidden = TreeRowKeys.returned(region, subject: chapter, columnShowsPulledUp: false)
        XCTAssertEqual(hidden.subject.beside, region)
        XCTAssertTrue(hidden.reveals, "the explicit act shows the column")
        var up = chapter
        up.beside = region
        let behind = TreeRowKeys.returned(region, subject: up, columnShowsPulledUp: false)
        XCTAssertEqual(behind.subject.beside, region, "up but not shown: shown, never put away")
        XCTAssertTrue(behind.reveals)
        let away = TreeRowKeys.returned(region, subject: up, columnShowsPulledUp: true)
        XCTAssertNil(away.subject.beside)
        XCTAssertFalse(away.reveals)
        XCTAssertEqual(away.subject.open, chapter.open)
        XCTAssertEqual(BinderTreeSelection.shownTags([], pullUp: region,
                                                     subject: away.subject, clickedAt: away.subject),
                       [.pullUp(region)], "the row stays the one selected")
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
        for call in ["resolvedTags(", "state.record(", "drawnTags(", "drawnFigureOrder(",
                     "state.pendingSettle", "TreeSelectionGesture.current"] {
            XCTAssertTrue(body.contains(call), call)
        }
        for forbidden in ["Task", "await", "perform", "post("] {
            XCTAssertFalse(body.contains(forbidden), "the setter does \(forbidden)")
        }
        // The settle is performed outside the setter, by the window.
        let wiring = try CanvasSourceCensus.source(at: "Maugham/Views/TreeWindowWiring.swift")
        XCTAssertTrue(wiring.contains(".task(id: state.pendingSettle)"))
        XCTAssertTrue(wiring.contains("try? await Task.sleep(for: TreeRowSettle.delay)"))
        XCTAssertTrue(wiring.contains("TreeRowSettle.settled("))
        XCTAssertTrue(wiring.contains("ProjectWindow.revealPulledUp(subject: subject,"))
        let window = try CanvasSourceCensus.source(at: "Maugham/Views/ProjectWindow.swift")
        XCTAssertTrue(window.contains("position: $rightColumnPosition))"),
                      "the window hands the wiring its column")
        // The button clears what waits and records the row (Minor 8).
        let fold = try CanvasSourceCensus.source(at: "Maugham/Views/BinderPieceFold.swift")
        XCTAssertTrue(fold.contains("state.pendingSettle = nil"))
        XCTAssertTrue(fold.contains("state.lastRowPress = outcome.rowPress"))
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

    func test_selectingAFoldCardRowSelectsItAndMovesNothing() async throws {
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
        XCTAssertEqual(state.selectedPullUp, .canvasScrap(nodeId: scrap.raw),
                       "the List's own selection reaches the card row")
        XCTAssertEqual(probe.subject, before, "a landing moves nothing at once")
        XCTAssertNil(state.pendingSettle,
                     "a selection set in code is a click's: the row's button is the act")
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
