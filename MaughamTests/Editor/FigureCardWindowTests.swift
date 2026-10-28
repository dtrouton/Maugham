import XCTest
import AppKit
import SwiftUI
@testable import MaughamCore
@testable import Maugham

/// **The in-place card and the figure window** (report plan 7d Task 9,
/// R7d-9, R7d-7): one grid per host — a figure open in a window draws
/// "Editing in window" on its card and a double-click or Return brings that
/// window front; ⤢ folds the in-place grid first (its visit collapsed into
/// its step) and asks for the window; Send to Research folds first, with no
/// step, and the line leaves the text as plan 6b's send removes it.
@MainActor
final class FigureCardWindowTests: FigureGridMountedTestCase {

    private func expanded(_ m: Mounted) async throws -> FigureGridController {
        XCTAssertTrue(m.coordinator.expandFigureGrid(lineAt: location(m, "![Cash](")))
        let grid = try await opened(m)
        return try XCTUnwrap(grid.controller)
    }

    private func cell(_ c: FigureGridController, _ column: Int, _ row: Int) -> CellKey {
        let table = c.host.state.table
        return CellKey(row: table.rows[row - 1], column: table.columns[column - 1])
    }

    private func cardsInWindow(_ m: Mounted) throws -> Int {
        let overlay = try XCTUnwrap(m.coordinator.figureThumbnailOverlay)
        overlay.display()
        return overlay.lastCardsInWindow
    }

    /// **R7d-9**: while a window is open on the figure, its cards say
    /// "Editing in window", and a double-click on the card or Return on its
    /// line brings that window front instead of expanding; once the window
    /// closes, the card is a card again and expands.
    func test_aFigureInAWindow_saysSo_andItsCardFocusesTheWindow() async throws {
        let windows = FigureWindows()
        let m = try await mount(windows: windows)
        let figureId = try XCTUnwrap(m.figure?.id)
        let line = location(m, "![Cash](")
        park(m, caret: location(m, "Middle prose"), showing: line)
        XCTAssertEqual(try cardsInWindow(m), 0, "premise: no window")

        var focused = 0
        let registration = windows.opened(figureId, focus: { focused += 1 }, close: {})
        let overlay = try XCTUnwrap(m.coordinator.figureThumbnailOverlay)
        let before = overlay.displayRequests
        let repainted = await RunLoopPump.until(deadline: 2) { overlay.displayRequests > before }
        XCTAssertTrue(repainted, "the window's opening repaints the cards")
        XCTAssertGreaterThan(try cardsInWindow(m), 0, "the card says “Editing in window”")
        XCTAssertEqual(FigureThumbnailOverlay.editingInWindow, "Editing in window")

        // A double-click on the card.
        let point = CGPoint(x: m.textView.textContainerOrigin.x + 24, y: lineBottom(m, at: line) + 12)
        XCTAssertEqual(m.coordinator.figureCardLine(at: point), line, "premise: the point is in the card")
        XCTAssertTrue(m.coordinator.expandFigureGrid(atCardPoint: point))
        XCTAssertEqual(focused, 1, "the window comes front")
        XCTAssertNil(m.coordinator.figureGrid, "never expanded twice")

        // Return inside the line.
        m.textView.setSelectedRange(NSRange(location: line + 3, length: 0))
        XCTAssertTrue(m.coordinator.handleFigureGridCommand(#selector(NSResponder.insertNewline(_:)),
                                                            in: m.textView))
        XCTAssertEqual(focused, 2)
        XCTAssertNil(m.coordinator.figureGrid)

        windows.closed(registration)
        let cleared = await RunLoopPump.until(deadline: 2) { (try? self.cardsInWindow(m)) == 0 }
        XCTAssertTrue(cleared, "the card is a card again")
        XCTAssertTrue(m.coordinator.expandFigureGrid(lineAt: line), "and expands")
        XCTAssertNotNil(m.coordinator.figureGrid)
    }

    /// **⤢**: the in-place grid folds first — its open edit committed and its
    /// visit collapsed into one step as Done's would be — then what only this
    /// editor knows is handed over and the window is asked for.
    func test_openInWindowFoldsFirst_collapsesTheVisit_andAsksForTheWindow() async throws {
        let windows = FigureWindows()
        var asked: [String] = []
        let m = try await mount(windows: windows, openWindow: { asked.append($0) })
        let figureId = try XCTUnwrap(m.figure?.id)
        let chapter = try XCTUnwrap(m.store.manifest.structure.first)
        let c = try await expanded(m)
        XCTAssertFalse(c.bars.openInWindow.isHidden, "⤢ is offered where a window can open")
        let number = c.line.number
        let b2 = cell(c, 2, 2)
        c.handle(.click(b2, extend: false))
        c.handle(.type("4"))
        c.handle(.editTextChanged("4"))

        c.perform(.openInWindow)

        XCTAssertNil(m.coordinator.figureGrid, "the in-place grid folded first")
        XCTAssertEqual(asked, [figureId], "then the window was asked for")
        XCTAssertNotNil(m.coordinator.lastFigureVisitStep, "the visit collapsed into its step, as usual")
        XCTAssertEqual(windows.handoff(for: figureId), FigureWindows.Handoff(
            number: number, caption: "Cash", piece: chapter.id, typography: .defaults,
            isReviewMode: false, from: ObjectIdentifier(m.coordinator)))
        await m.coordinator.figureGridFolding?.value
        XCTAssertEqual(c.host.state.table[b2]?.content, .value(.number(4)), "the open edit was committed")
    }

    /// An edit that will not read keeps the grid here, its error shown, and
    /// no window opens; with no figure windows to open, ⤢ is not offered.
    func test_openInWindowStopsOnAnUnreadableEdit_andIsHiddenWithoutWindows() async throws {
        var asked: [String] = []
        let m = try await mount(windows: FigureWindows(), openWindow: { asked.append($0) })
        let c = try await expanded(m)
        c.handle(.click(cell(c, 1, 1), extend: false))
        c.handle(.type("="))
        c.handle(.editTextChanged("=SUM("))
        c.perform(.openInWindow)
        XCTAssertNotNil(m.coordinator.figureGrid, "the grid stays")
        XCTAssertEqual(asked, [], "no window")
        XCTAssertNotNil(c.bars.errorMessage)

        let plain = try await mount()
        let other = try await expanded(plain)
        XCTAssertTrue(other.bars.openInWindow.isHidden, "no figure windows: no ⤢")
    }

    /// A window opened on the figure from elsewhere (another project window)
    /// while it is expanded here folds this grid: never two grids on one host.
    func test_aWindowOpenedElsewhereFoldsTheInPlaceGrid() async throws {
        let windows = FigureWindows()
        let m = try await mount(windows: windows)
        _ = try await expanded(m)
        _ = windows.opened(try XCTUnwrap(m.figure?.id), close: {})
        let folded = await RunLoopPump.until(deadline: 2) { m.coordinator.figureGrid == nil }
        XCTAssertTrue(folded)
    }

    /// **Send to Research from the in-place grid** (R7d-7, ruling P1): the
    /// grid folds first — its open edit committed — with no step on the
    /// window's stack and the text given the keys; the figure is parked in
    /// the piece's Research (a novel's chapter: shared, linked) and its line
    /// leaves the manuscript as plan 6b's send removes it.
    func test_sendToResearchFoldsFirstWithNoStep_andTheLineLeaves() async throws {
        let m = try await mount()
        let figureId = try XCTUnwrap(m.figure?.id)
        let ds = try XCTUnwrap(m.store.documentStore)
        let chapter = try XCTUnwrap(m.store.manifest.structure.first)
        let chapterURL = m.store.url.appendingPathComponent(try XCTUnwrap(chapter.path))
        let doc = try await Document.load(url: chapterURL, actor: .author, session: "t", presenter: nil)
        doc.setFullText("Intro.\n\n![Cash](../figures/t.csv){#tbl:t}\n\nAfter.")
        await doc.close()

        let c = try await expanded(m)
        let b2 = cell(c, 2, 2)
        c.handle(.click(b2, extend: false))
        c.handle(.type("7"))
        c.handle(.editTextChanged("7"))

        c.performTableCommand(.sendTo(.piece))

        XCTAssertNil(m.coordinator.figureGrid, "it folds first")
        XCTAssertNil(m.coordinator.lastFigureVisitStep, "not undoable: no step (ruling P1)")
        XCTAssertTrue(m.window.firstResponder === m.textView, "the text takes the keys")
        await m.coordinator.figureGridFolding?.value
        let parked = try await ds.figureIsParked(figureId)
        XCTAssertTrue(parked, "the figure is in Research")
        XCTAssertEqual(c.host.state.table[b2]?.content, .value(.number(7)), "the open edit went with it")
        let item = try XCTUnwrap(m.store.manifest.research.first { $0.kind == .table })
        XCTAssertEqual(m.store.manifest.structure.first?.linkedResearchIds ?? [], [item.id],
                       "in the chapter's Research")
        let after = try await Document.load(url: chapterURL, actor: .author, session: "t", presenter: nil)
        let text = after.displayText
        await after.close()
        XCTAssertFalse(text.contains("![Cash]"), "the line left the text: \(text)")
        XCTAssertTrue(text.contains("Intro.") && text.contains("After."))
    }

    /// **The editor keeps the figure windows current** (concerns 1 and 4):
    /// the share as its control plane says, and at each `ReferenceIndex`
    /// version each open figure's "Table N" and caption from the whole book
    /// when the editor does not show the figure's line itself.
    func test_theEditorTellsTheWindowsTheShareAndTheLine() async throws {
        let windows = FigureWindows()
        // The figure's line is in no text this editor shows: the index tells it.
        let m = try await mount("Intro.\n\nThe end.", windows: windows)
        let figureId = try XCTUnwrap(m.figure?.id)
        XCTAssertFalse(windows.shareIsReadOnly)
        m.coordinator.setShareIsReadOnly(true)
        XCTAssertTrue(windows.shareIsReadOnly, "the share flipped is told")
        m.coordinator.setShareIsReadOnly(false)
        XCTAssertFalse(windows.shareIsReadOnly)

        var told: [String] = []
        let listener = windows.listen(figureId, line: { told.append("\($0) · \($1)") }, access: {})
        defer { windows.stopListening(listener) }
        _ = windows.opened(figureId, close: {})
        let index = ReferenceIndex.build(
            structure: m.store.manifest.structure, research: [],
            text: { [chapter = m.store.manifest.structure.first?.id] piece in
                piece.id == chapter ? "Intro.\n\n![Cash flow](../figures/t.csv){#tbl:t}\n" : "Words.\n"
            }, words: .english)
        XCTAssertNotNil(index.target(for: try XCTUnwrap(ManuscriptLabel(reference: "tbl:t"))),
                        "premise: the line is a target")
        m.coordinator.referenceIndex = { index }
        m.coordinator.setReferenceIndexVersion(m.coordinator.referenceIndexVersion + 1)
        XCTAssertEqual(told, ["Table 1 · Cash flow"])
    }
}
