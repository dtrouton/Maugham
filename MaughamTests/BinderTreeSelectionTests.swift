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
                       storedFold: String = "ch-1",
                       clickedAt: WindowSubject? = nil,
                       gesture: TreeSelectionGesture = .pointer,
                       recentPress: @escaping (PulledUp) -> Bool = { _ in false })
        -> BinderTreeSelection.TagWrite {
        BinderTreeSelection.resolvedTags(
            written: written, stored: stored, storedFoldRow: row(storedPullUp, storedFold),
            storedRowFolds: [:],
            shown: BinderTreeSelection.shownTags(stored, foldRow: row(storedPullUp, storedFold),
                                                  subject: subject, clickedAt: clickedAt,
                                                  rowFold: { _ in nil }),
            subject: subject, structure: structure, research: research, figures: [],
            projectType: .novel, gesture: gesture, recentPress: recentPress)
    }

    /// A fold row of `piece` (default: chapter one's fold).
    private func row(_ pulled: PulledUp?, _ piece: String = "ch-1") -> TreeRowTag.FoldRow? {
        pulled.map { TreeRowTag.FoldRow(pulled: $0, piece: piece) }
    }

    /// The tag `pulled`'s row carries in `piece`'s fold.
    private func tag(_ pulled: PulledUp, _ piece: String = "ch-1") -> TreeRowTag {
        .pullUp(TreeRowTag.FoldRow(pulled: pulled, piece: piece))
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
        let guardLine = "guard !hostIsRenaming, state.renamingItemId == nil else { return .ignored }"
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
            let keys = write([tag(pulled)], from: chapter, gesture: .keys)
            XCTAssertEqual(keys.subject, chapter, "\(pulled): the setter moves nothing")
            XCTAssertEqual(keys.foldRow, row(pulled), "and the List draws it selected")
            XCTAssertEqual(keys.settle, pulled, "it waits to settle")
            XCTAssertEqual(BinderTreeSelection.shownTags(keys.selection, foldRow: keys.foldRow,
                                                          subject: keys.subject,
                                                          clickedAt: keys.subject, rowFold: { _ in nil }),
                           [tag(pulled)])
            let pointer = write([tag(pulled)], from: chapter, gesture: .pointer)
            XCTAssertEqual(pointer.subject, chapter)
            XCTAssertNil(pointer.settle, "a click's selection waits for nothing")
            let sameClick = write([tag(pulled)], from: chapter, gesture: .keys,
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
                let selected = write([tag(pulled)], from: before, gesture: gesture)
                let pressed = BinderPieceFold.buttonPress(
                    entry, at: 10.0, last: nil, interval: 0.5, subject: selected.subject,
                    structure: structure, projectType: .novel)
                XCTAssertEqual(pressed.subject, expected, "selection then button, \(gesture)")
                // The button clears what waits (`pressed` sets pendingSettle = nil).
                // The button first, then the selection.
                let first = BinderPieceFold.buttonPress(
                    entry, at: 10.0, last: nil, interval: 0.5, subject: before,
                    structure: structure, projectType: .novel)
                let then = write([tag(pulled)], from: first.subject!, gesture: gesture,
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
        let next = write([tag(.canvasRegion(id: "r1"))], from: up)
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
            XCTAssertNil(viaTags.foldRow, "a subject write lets the fold row go")
        }
    }

    /// The `List` handing back what it drew moves nothing.
    func test_theListHandingBackItsOwnSelectionMovesNothing() {
        var up = chapter
        up.beside = .canvasScrap(nodeId: "s1")
        let next = write([tag(.canvasScrap(nodeId: "s1"))], from: up,
                         storedPullUp: .canvasScrap(nodeId: "s1"), clickedAt: up)
        XCTAssertEqual(next.subject, up)
        XCTAssertEqual(next.foldRow, row(.canvasScrap(nodeId: "s1")))
    }

    /// A subject moved elsewhere (a mouse click on a row's button, Close) is
    /// drawn as today: the window's last-clicked row.
    func test_aSubjectMovedElsewhereDrawsTodaysRow() {
        var moved = chapter
        moved.faces = .item("ch-2")
        XCTAssertEqual(BinderTreeSelection.shownTags([], foldRow: row(.canvasScrap(nodeId: "s1")),
                                                     subject: moved, clickedAt: chapter,
                                                     rowFold: { _ in nil }),
                       [.subject(.item("ch-2"))])
    }

    // MARK: - The keys

    func test_whatEachKeyDoesOnEachRowKind() {
        let pulls: [PulledUp] = [.canvasScrap(nodeId: "s1"), .canvasRegion(id: "r1"),
                                 .research("pal-1"), .figure("fig-1")]
        for pulled in pulls {
            XCTAssertEqual(TreeRowKeys.act(.returnOrSpace, drawn: [tag(pulled)]),
                           .click(pulled, row: row(pulled)))
            XCTAssertEqual(TreeRowKeys.act(.openInCentre, drawn: [tag(pulled)]),
                           .openInCentre(tag(pulled)))
        }
        XCTAssertEqual(TreeRowKeys.act(.returnOrSpace, drawn: [.subject(.research("res-1"))]),
                       .click(.research("res-1"), row: nil), "a research row's Return pulls it up now")
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
        XCTAssertEqual(TreeRowKeys.key(.return, modifiers: [], typeSelecting: false), .returnOrSpace)
        XCTAssertEqual(TreeRowKeys.key(.space, modifiers: [], typeSelecting: false), .returnOrSpace)
        XCTAssertEqual(TreeRowKeys.key(.downArrow, modifiers: .command, typeSelecting: false), .openInCentre)
        XCTAssertEqual(TreeRowKeys.key(.downArrow, modifiers: [.command, .numericPad], typeSelecting: false), .openInCentre)
        XCTAssertNil(TreeRowKeys.key(.downArrow, modifiers: [], typeSelecting: false), "the List's own arrow")
        XCTAssertNil(TreeRowKeys.key(.return, modifiers: .command, typeSelecting: false))
        XCTAssertNil(TreeRowKeys.key(.downArrow, modifiers: [.command, .option], typeSelecting: false))
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
        XCTAssertEqual(BinderTreeSelection.shownTags([], foldRow: row(region),
                                                     subject: away.subject, clickedAt: away.subject,
                                                     rowFold: { _ in nil }),
                       [tag(region)], "the row stays the one selected")
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

    // MARK: - A card in two open folds (shell p5 Task 4)

    /// A palette card pinned to two chapters is two rows: each fold's tag
    /// names its piece, so selecting one draws one, the other row still
    /// draws its outline while the card is up, and Return keeps the row the
    /// keys are on.
    func test_aCardInTwoFoldsHasTwoTags() {
        let entry: PieceFoldEntry = .palette(id: "pal-1", title: "Fog")
        let one = BinderPieceFold.tag(of: entry, inFoldOf: "ch-1")
        let two = BinderPieceFold.tag(of: entry, inFoldOf: "ch-2")
        XCTAssertNotEqual(one, two, "two folds, two tags")
        XCTAssertEqual(one.pullUp, two.pullUp, "the same card either way")
        let landed = write([two], from: chapter, gesture: .keys)
        XCTAssertEqual(landed.foldRow, row(.research("pal-1"), "ch-2"))
        XCTAssertEqual(landed.settle, .research("pal-1"))
        let drawn = BinderTreeSelection.shownTags(landed.selection, foldRow: landed.foldRow,
                                                  subject: landed.subject, clickedAt: landed.subject, rowFold: { _ in nil })
        XCTAssertEqual(drawn, [two], "only the row landed on is drawn selected")
        XCTAssertEqual(TreeRowKeys.act(.returnOrSpace, drawn: drawn),
                       .click(.research("pal-1"), row: row(.research("pal-1"), "ch-2")))
        // Pulled up from chapter two's row: chapter one's row outlines.
        var up = chapter
        up.beside = .research("pal-1")
        let state = BinderTreeSectionsState()
        state.record(selection: [], subject: up, foldRow: landed.foldRow)
        XCTAssertFalse(BinderPieceFold.drawsOutline(entry, inFoldOf: "ch-2", subject: up, state: state),
                       "the selected row needs no outline")
        XCTAssertTrue(BinderPieceFold.drawsOutline(entry, inFoldOf: "ch-1", subject: up, state: state),
                      "its twin in the other fold still says it is up")
    }

    // MARK: - Space during type-select (shell p5 Task 4)

    /// A Space within type-select's interval of a collected key is the
    /// search's; a lone Space, or one after the interval or after an arrow
    /// ended the search, is the row's.
    func test_spaceDuringTypeSelectIsTypeSelects() {
        let interval = TreeTypeSelect.interval
        XCTAssertEqual(interval, 1.2, "measured on macOS 27 (see TreeTypeSelect)")
        XCTAssertTrue(TreeTypeSelect.collects("T", modifiers: .shift, collecting: false))
        XCTAssertTrue(TreeTypeSelect.collects("é", modifiers: [], collecting: false))
        XCTAssertFalse(TreeTypeSelect.collects(" ", modifiers: [], collecting: false),
                       "a lone Space starts no search")
        XCTAssertTrue(TreeTypeSelect.collects(" ", modifiers: [], collecting: true))
        XCTAssertFalse(TreeTypeSelect.collects("t", modifiers: .command, collecting: true))
        XCTAssertFalse(TreeTypeSelect.collects("\r", modifiers: [], collecting: true))
        let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        XCTAssertFalse(TreeTypeSelect.collects(down, modifiers: [], collecting: true),
                       "an arrow ends the search")

        XCTAssertTrue(TreeTypeSelect.isCollecting(at: 11.1, lastKey: 10, interval: interval))
        XCTAssertFalse(TreeTypeSelect.isCollecting(at: 11.3, lastKey: 10, interval: interval))
        XCTAssertFalse(TreeTypeSelect.isCollecting(at: 10, lastKey: nil, interval: interval))
        XCTAssertFalse(TreeTypeSelect.isCollecting(at: 9, lastKey: 10, interval: interval),
                       "a clock running backwards collects nothing")

        XCTAssertNil(TreeRowKeys.key(.space, modifiers: [], typeSelecting: true),
                     "type-select's Space")
        XCTAssertEqual(TreeRowKeys.key(.return, modifiers: [], typeSelecting: true), .returnOrSpace,
                       "Return is never the search's")
        XCTAssertEqual(TreeRowKeys.key(.space, modifiers: [], typeSelecting: false), .returnOrSpace)
    }

    /// The modifier asks the rule at every key-down and records what it
    /// collects; a deleted wiring line turns this red.
    func test_theTreeKeysAskTypeSelectFirst() throws {
        let keys = SourceScan.codeLines(of: try SourceTree.declaration(
            named: "struct TreeRowKeysModifier", under: "Maugham")).joined(separator: "\n")
        for wiring in ["content.onKeyPress(phases: .down)",
                       "TreeTypeSelect.isCollecting(",
                       "lastKey: state.lastTypeSelectKey, interval: TreeTypeSelect.interval",
                       "TreeTypeSelect.collects(press.characters",
                       "state.lastTypeSelectKey = now",
                       "state.lastTypeSelectKey = nil",
                       "typeSelecting: typeSelecting"] {
            XCTAssertTrue(keys.contains(wiring), wiring)
        }
        // A rename's keys start no search: the guard comes before the record.
        let renameGuard = try XCTUnwrap(keys.range(of: "guard !hostIsRenaming, state.renamingItemId == nil"))
        let record = try XCTUnwrap(keys.range(of: "state.lastTypeSelectKey = now"))
        XCTAssertLessThan(renameGuard.lowerBound, record.lowerBound,
                          "lastTypeSelectKey is recorded only after the rename guard")
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
        XCTAssertTrue(body.contains(".tag(Self.tag(of: entry, inFoldOf: documentId))"),
                      "a pull-up row is a List row the keys reach")
        XCTAssertEqual(source.components(separatedBy: ".tag(Self.tag(of:").count - 1, 1)
        // Every kind `pullUpRow` draws names what it pulls up.
        for entry: PieceFoldEntry in [
            .card(PinnedReference(id: "s1", kind: .scrap(nodeId: "s1"), title: "S")),
            .region(id: "r1", title: "R", cards: []), .palette(id: "p", title: "P"),
            .figure(id: "f", name: "F"),
        ] {
            XCTAssertNotNil(entry.pulledUp)
            XCTAssertEqual(BinderPieceFold.tag(of: entry, inFoldOf: "ch-1"), tag(entry.pulledUp!))
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

    /// **The `List` selects one row of a card listed in two open folds**
    /// (shell p5 Task 4): with one tag per card, selecting either row drew both.
    func test_selectingACardInTwoOpenFoldsSelectsOneRow() async throws {
        let temp = TempDirectory()
        defer { temp.cleanup() }
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: store.url)
        store.documentStore = ds
        let one = try XCTUnwrap(store.manifest.structure.first?.id)
        let two = try await store.addStructureItem(parentId: nil, title: "Two", kind: .document(.markdown)).id
        let card = try await store.addPaletteCard(title: "Fog", kind: .location)
        try await store.linkResearch(researchId: card.id, toDocumentId: one)
        try await store.linkResearch(researchId: card.id, toDocumentId: two)

        let probe = FoldKeysSubjectProbe(WindowSubject(open: .item(one), faces: .item(one)))
        let state = BinderTreeSectionsState()
        let window = TestWindow.mount(AnyView(FoldKeysProbeBinder(store: store, probe: probe,
                                                                  state: state)),
                                      size: CGSize(width: 320, height: 800),
                                      as: SilentTestWindow.self)
        defer {
            window.contentView = NSView(frame: .zero)
            Task { await ds.close() }
        }
        _ = await pumpUntil(deadline: 5) {
            state.foldIndex.entries[one]?.isEmpty == false && state.foldIndex.entries[two]?.isEmpty == false
        }
        let outline = try XCTUnwrap(outline(in: window))
        let first = TreeFurniture.firstManuscriptRow
        let oneItem = try XCTUnwrap(outline.item(atRow: first))
        XCTAssertTrue(outline.isExpandable(oneItem), "premise: chapter one has a fold")
        outline.expandItem(oneItem)
        pump(0.2)
        let twoItem = try XCTUnwrap(outline.item(atRow: first + 2))
        XCTAssertTrue(outline.isExpandable(twoItem), "premise: chapter two follows one fold row")
        outline.expandItem(twoItem)
        pump(0.2)

        outline.selectRowIndexes(IndexSet(integer: first + 3), byExtendingSelection: false)
        pump(0.2)
        XCTAssertEqual(state.selectedFoldRow,
                       TreeRowTag.FoldRow(pulled: .research(card.id), piece: two),
                       "the row selected is chapter two's")
        XCTAssertEqual(outline.selectedRowIndexes, IndexSet(integer: first + 3),
                       "and the List draws that row alone, not its twin in chapter one's fold")
    }

    /// **Space during type-select, on the production tree** (shell p5 Task 4
    /// fix round 1). The premises are read off the tree it got: this SwiftUI
    /// `List` type-selects (a "t" moves the selection to the "Tide" row), and
    /// the letter reaches `TreeRowKeysModifier` (`lastTypeSelectKey` set).
    /// Then a Space straight after belongs to the search, so the fold row
    /// the search landed on is not pulled up; the control, a Space once the
    /// search has lapsed (the recorded key cleared, standing in for the
    /// interval passing, with no wait), pulls it up. Measured on this List,
    /// real time: a second letter 1.22 s after the first extends the search,
    /// one at 1.25 s starts afresh; event timestamps play no part.
    func test_aSpaceStraightAfterALetterIsTheRealTreesTypeSelect() async throws {
        let temp = TempDirectory()
        defer { temp.cleanup() }
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: store.url)
        store.documentStore = ds
        let one = try XCTUnwrap(store.manifest.structure.first?.id)
        let card = try await store.addPaletteCard(title: "Tide", kind: .location)
        try await store.linkResearch(researchId: card.id, toDocumentId: one)
        let probe = FoldKeysSubjectProbe(WindowSubject(open: .item(one), faces: .item(one)))
        let state = BinderTreeSectionsState()
        let window = TestWindow.mount(AnyView(FoldKeysProbeBinder(store: store, probe: probe,
                                                                  state: state)),
                                      size: CGSize(width: 320, height: 800),
                                      as: SilentTestWindow.self)
        defer {
            window.contentView = NSView(frame: .zero)
            Task { await ds.close() }
        }
        _ = await pumpUntil(deadline: 5) { state.foldIndex.entries[one]?.isEmpty == false }
        let outline = try XCTUnwrap(outline(in: window))
        let first = TreeFurniture.firstManuscriptRow
        let chapter = try XCTUnwrap(outline.item(atRow: first))
        XCTAssertTrue(outline.isExpandable(chapter), "premise: the chapter has a fold")
        outline.expandItem(chapter)
        pump(0.2)
        outline.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
        pump(0.2)
        XCTAssertTrue(window.makeFirstResponder(outline), "premise: the tree has the keys")
        let tide = first + 1
        XCTAssertNil(state.selectedFoldRow, "premise: the chapter row, not the fold row, is selected")

        window.sendEvent(keyDown("t", keyCode: 17, window))
        XCTAssertEqual(outline.selectedRow, tide, "this List type-selects: \"t\" lands on Tide's fold row")
        XCTAssertNotNil(state.lastTypeSelectKey, "the letter reached the tree's key handler")
        let landed = TreeRowTag.FoldRow(pulled: .research(card.id), piece: one)
        XCTAssertEqual(state.selectedFoldRow, landed)

        window.sendEvent(keyDown(" ", keyCode: 49, window))
        XCTAssertNil(probe.subject.beside, "a Space inside the search does not pull the row up")
        XCTAssertEqual(outline.selectedRow, tide)

        // The control: the search lapsed, the same Space is the row's.
        state.lastTypeSelectKey = nil
        window.sendEvent(keyDown(" ", keyCode: 49, window))
        XCTAssertEqual(probe.subject.beside, .research(card.id), "a lone Space pulls the row up")
    }

    private func keyDown(_ characters: String, keyCode: UInt16, _ window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: keyCode)!
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
