import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **Focus between the manuscript text and the in-place grid, and every way
/// the grid folds** (report plan 7c Task 7, R7c-8). Keys go down the real
/// path — `NSEvent.keyEvent` delivered by `window.sendEvent` to whichever
/// view is first responder — and `window.firstResponder` is read
/// synchronously after each. The click in the text is the coordinator verb
/// `MaughamTextView.mouseDown` calls (`figureGridYieldsToText`); no click is
/// synthesised (tripwire 33). Nothing waits on a clock: a visit's writes and
/// a refused hand-over's reshow are awaited through their handles.
@MainActor
final class FigureGridFocusTests: FigureGridMountedTestCase {

    // MARK: - Keys

    private func key(_ m: Mounted, _ characters: String, code: UInt16 = 0) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: m.window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    private func press(_ m: Mounted, _ characters: String, code: UInt16 = 0) {
        m.window.sendEvent(key(m, characters, code: code))
    }

    private func type(_ m: Mounted, _ text: String) {
        for character in text { press(m, String(character)) }
    }

    private func escape(_ m: Mounted) { press(m, "\u{1B}", code: 53) }
    private func down(_ m: Mounted) { press(m, "\u{F701}", code: 125) }
    private func right(_ m: Mounted) { press(m, "\u{F703}", code: 124) }

    private func cellKey(_ c: FigureGridController, _ column: Int, _ row: Int) -> CellKey {
        let table = c.host.state.table
        return CellKey(row: table.rows[row - 1], column: table.columns[column - 1])
    }

    /// The grid open on the table's first line, its keys the grid's.
    private func expanded(_ m: Mounted) async throws -> (FigureGridExpansion, FigureGridController) {
        XCTAssertTrue(m.coordinator.expandFigureGrid(lineAt: location(m, "![Cash](")))
        let grid = try await opened(m)
        let controller = try XCTUnwrap(grid.controller)
        XCTAssertTrue(m.window.firstResponder === controller.gridView, "premise: the grid has the keys")
        return (grid, controller)
    }

    /// An edit open in A1, typed on the real key path.
    private func typeInFirstCell(_ m: Mounted, _ c: FigureGridController, _ text: String) {
        type(m, text)
        XCTAssertTrue(m.window.firstResponder === c.gridView.cellEditor.currentEditor(),
                      "premise: the cell editor has the keys")
        XCTAssertEqual(c.gridView.cellEditor.stringValue, text, "premise: the typing is in the cell")
    }

    private func notices(during body: () async throws -> Void) async rethrows -> [String] {
        var seen: [String] = []
        let token = NotificationCenter.default.addObserver( // adr-0021-ok: a test observing the production post, not a production subscription
            forName: .maughamDocumentNotice, object: nil, queue: nil
        ) { note in
            if let message = note.userInfo?[MaughamEvent.noticeMessageKey] as? String { seen.append(message) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        try await body()
        return seen
    }

    // MARK: - Review Focus 1

    /// **Review Focus 1**: a 40-row table expanded, arrows to B30, `=SUM(B2:B29)`
    /// typed, then Return, Esc, Esc. Return commits and moves down (the grid
    /// takes the keys back); the FIRST Esc, on a selected cell, folds (the
    /// model's rule: Esc cancels an open edit, and on a selected cell folds);
    /// the second Esc reaches the text and changes nothing. The viewport
    /// scrolled, the total computed, only the line re-laid out each way, the
    /// caret back at the end of the figure line, and no `applyExternalText`.
    func test_reviewFocus1_aFormulaTypedThenReturnEscEsc() async throws {
        let m = try await mount(rows: 40)
        let line = location(m, "![Cash](")
        let text = m.textView.string
        let externals = m.coordinator.applyExternalTextCallCount
        let refreshes = m.coordinator.figureRoomRefreshCount
        let (grid, c) = try await expanded(m)
        XCTAssertEqual(m.coordinator.figureRoomRefreshCount - refreshes, 1, "expand re-laid out the line only")
        var ones: [CellKey: Cell?] = [:]
        for row in 2...29 { ones[cellKey(c, 2, row)] = Cell(content: .value(.number(1))) }
        try await c.host.setCells(ones, actionName: "Fixture", undoManager: nil)
        XCTAssertEqual(c.bars.addressLabel.stringValue, "A1", "premise: the grid opens on A1")

        right(m)
        for _ in 1...29 { down(m) }
        XCTAssertEqual(c.bars.addressLabel.stringValue, "B30")
        XCTAssertGreaterThan(c.gridView.scrollOffset.y, 0, "the viewport scrolled to row 30")
        type(m, "=SUM(B2:B29)")
        XCTAssertEqual(c.gridView.cellEditor.stringValue, "=SUM(B2:B29)")

        press(m, "\r", code: 36)
        XCTAssertTrue(m.window.firstResponder === c.gridView, "Return committed: the grid has the keys back")
        XCTAssertEqual(c.bars.addressLabel.stringValue, "B31", "and moved down")
        await c.settleWrites()
        guard case .formula? = c.host.state.table[cellKey(c, 2, 30)]?.content else {
            return XCTFail("the formula was not written")
        }
        XCTAssertEqual(c.figureGridValue(at: cellKey(c, 2, 30)), .number(28), "the total computes")

        let folding = m.coordinator.figureRoomRefreshCount
        escape(m)
        XCTAssertNil(m.coordinator.figureGrid, "the first Esc, on a selected cell, folds")
        XCTAssertNil(grid.panel?.superview)
        XCTAssertEqual(m.coordinator.figureRoomRefreshCount - folding, 1, "fold re-laid out the line only")
        XCTAssertTrue(m.window.firstResponder === m.textView)
        let end = lineEnd(m, at: line)
        XCTAssertEqual(m.textView.selectedRange(), NSRange(location: end, length: 0),
                       "the caret returns to the end of the figure line")

        escape(m)
        XCTAssertNil(m.coordinator.figureGrid, "the second Esc reaches the text")
        XCTAssertTrue(m.window.firstResponder === m.textView)
        XCTAssertEqual(m.textView.selectedRange(), NSRange(location: end, length: 0))
        XCTAssertEqual(m.textView.string, text, "no keystroke wrote the text")
        XCTAssertEqual(m.coordinator.applyExternalTextCallCount, externals, "no applyExternalText")
    }

    /// Esc in an open edit discards it; the next Esc folds. Nothing written.
    func test_escDiscardsTheEdit_thenEscFolds() async throws {
        let m = try await mount()
        let (_, c) = try await expanded(m)
        typeInFirstCell(m, c, "9")
        escape(m)
        XCTAssertTrue(m.window.firstResponder === c.gridView, "the edit is discarded; the grid keeps the keys")
        XCTAssertNotNil(m.coordinator.figureGrid)
        escape(m)
        XCTAssertNil(m.coordinator.figureGrid)
        XCTAssertTrue(m.window.firstResponder === m.textView)
        await c.settleWrites()
        XCTAssertNil(c.host.state.table[cellKey(c, 1, 1)], "nothing written")
    }

    // MARK: - Review Focus 2: the text takes the focus

    /// **Review Focus 2, a task-list jump**: the jump selects in the text
    /// and makes it first responder; the grid folds with its open edit
    /// committed, and the caret is where the jump put it.
    func test_reviewFocus2_aTaskJumpFoldsTheGridWithItsEditCommitted() async throws {
        let m = try await mount()
        let target = location(m, "Middle prose")
        m.coordinator.paragraphRangeProvider = { _ in NSRange(location: target, length: 12) }
        let (grid, c) = try await expanded(m)
        typeInFirstCell(m, c, "7")

        MaughamEvent.post(.maughamNavigateToParagraph, to: .keyWindow, payload: ["paragraph_id": "k3m7"])

        XCTAssertNil(m.coordinator.figureGrid, "the grid folded")
        XCTAssertNil(grid.panel?.superview)
        XCTAssertTrue(m.window.firstResponder === m.textView, "the text has the focus")
        XCTAssertEqual(m.textView.selectedRange(), NSRange(location: target, length: 0), "where the jump put it")
        await c.settleWrites()
        XCTAssertEqual(c.host.state.table[cellKey(c, 1, 1)]?.content, .value(.number(7)), "the edit was committed")
    }

    /// **Review Focus 2, a find match**: the find selects the match in the
    /// text (the find field keeping the keys); the caret has left the line,
    /// so the grid folds with its edit committed, the match selected. A
    /// line jump (`navigateToLine`, the scene and find-line verb) folds too.
    func test_reviewFocus2_aFindMatchSelectedFoldsTheGridWithItsEditCommitted() async throws {
        let m = try await mount()
        let match = NSRange(location: location(m, "Paragraph 3 "), length: 9)
        let (_, c) = try await expanded(m)
        typeInFirstCell(m, c, "8")

        m.textView.setSelectedRange(match)   // what `.maughamFindMatchSelected` does

        XCTAssertNil(m.coordinator.figureGrid, "the caret left the line: the grid folded")
        XCTAssertEqual(m.textView.selectedRange(), match, "the match stays selected")
        XCTAssertTrue(m.window.firstResponder === m.textView, "the grid had the keys: the text takes them")
        await c.settleWrites()
        XCTAssertEqual(c.host.state.table[cellKey(c, 1, 1)]?.content, .value(.number(8)))

        let (_, again) = try await expanded(m)
        let scene = location(m, "Paragraph 5 ")
        m.coordinator.navigateToLine(at: scene, in: m.textView)
        XCTAssertNil(m.coordinator.figureGrid)
        XCTAssertTrue(m.window.firstResponder === m.textView)
        XCTAssertEqual(m.textView.selectedRange(), NSRange(location: scene, length: 0))
        await again.settleWrites()
    }

    /// **The text becoming first responder folds, whoever asks**: the bare
    /// `makeFirstResponder(textView)` every focus thief calls. The text's own
    /// selection is left as it was; the open edit is committed.
    func test_theTextBecomingFirstResponderFoldsTheGrid() async throws {
        let m = try await mount()
        let caret = location(m, "Middle prose") + 2
        m.textView.setSelectedRange(NSRange(location: caret, length: 0))
        let (_, c) = try await expanded(m)
        typeInFirstCell(m, c, "6")

        XCTAssertTrue(m.window.makeFirstResponder(m.textView))

        XCTAssertNil(m.coordinator.figureGrid)
        XCTAssertTrue(m.window.firstResponder === m.textView)
        XCTAssertEqual(m.textView.selectedRange(), NSRange(location: caret, length: 0), "the text's selection is its own")
        await c.settleWrites()
        XCTAssertEqual(c.host.state.table[cellKey(c, 1, 1)]?.content, .value(.number(6)))
    }

    /// An edit typed in the **formula bar** is committed when the text takes
    /// the focus, and the text keeps it: the bar, having given up the keys,
    /// hands none back to the grid.
    func test_aFormulaBarEditIsCommittedWhenTheTextTakesTheFocus() async throws {
        let m = try await mount()
        let (_, c) = try await expanded(m)
        XCTAssertTrue(m.window.makeFirstResponder(c.bars.formulaField))
        type(m, "3")
        XCTAssertEqual(c.bars.formulaField.stringValue, "3", "premise: typed in the bar")

        m.window.makeFirstResponder(m.textView)

        XCTAssertNil(m.coordinator.figureGrid)
        XCTAssertTrue(m.window.firstResponder === m.textView, "the text keeps the focus")
        await c.settleWrites()
        XCTAssertEqual(c.host.state.table[cellKey(c, 1, 1)]?.content, .value(.number(3)))
    }

    /// **A click in the text folds** — through the verb `mouseDown` calls
    /// first (the click itself may not be synthesised, tripwire 33): the
    /// click may go on into the text.
    func test_aClickInTheTextFoldsTheGrid() async throws {
        let m = try await mount()
        let (_, c) = try await expanded(m)
        typeInFirstCell(m, c, "5")
        XCTAssertTrue(m.coordinator.figureGridYieldsToText(), "the click goes on into the text")
        XCTAssertNil(m.coordinator.figureGrid)
        await c.settleWrites()
        XCTAssertEqual(c.host.state.table[cellKey(c, 1, 1)]?.content, .value(.number(5)))
    }

    /// **R7c-8: a formula that will not read keeps the grid** when the text
    /// asks for the focus: the text refuses it, nothing is written, and the
    /// edit shows its error again with the keys, the typing intact. A click
    /// is swallowed the same way (the verb answers false).
    func test_aFormulaThatWillNotReadKeepsTheGridWhenTheTextAsksForTheFocus() async throws {
        let m = try await mount()
        let (grid, c) = try await expanded(m)
        typeInFirstCell(m, c, "=SUM(")

        m.window.makeFirstResponder(m.textView)
        XCTAssertFalse(m.window.firstResponder === m.textView, "the text is refused the focus")
        XCTAssertTrue(m.coordinator.figureGrid === grid, "the grid stays open")
        await grid.reshowing?.value
        XCTAssertTrue(m.window.firstResponder === c.gridView.cellEditor.currentEditor(), "the edit has the keys again")
        XCTAssertEqual(c.gridView.cellEditor.stringValue, "=SUM(", "the typing is intact")
        XCTAssertNotNil(c.bars.errorMessage, "and its error is shown")

        XCTAssertFalse(m.coordinator.figureGridYieldsToText(), "a click in the text is swallowed")
        await grid.reshowing?.value
        XCTAssertTrue(m.coordinator.figureGrid === grid)
        await c.settleWrites()
        XCTAssertNil(c.host.state.table[cellKey(c, 1, 1)], "nothing written")

        // Fixed, the next hand-over folds as usual (as the grid's own Esc would after).
        c.gridView.cellEditor.currentEditor()?.insertText("1)")
        XCTAssertTrue(m.window.makeFirstResponder(m.textView))
        XCTAssertNil(m.coordinator.figureGrid)
    }

    // MARK: - Forced folds

    /// **Detach (a document switch) folds first**: an open formula that will
    /// not read cannot stay in a grid that is going away — a notice carries
    /// its text, and nothing is written.
    func test_detachFoldsFirst_anUnreadableFormulaIsSaidWithItsText() async throws {
        let m = try await mount()
        let (grid, c) = try await expanded(m)
        typeInFirstCell(m, c, "=SUM(")
        let said = await notices { m.coordinator.detach() }
        XCTAssertNil(m.coordinator.figureGrid, "the grid folded")
        XCTAssertNil(grid.panel?.superview)
        XCTAssertEqual(said.count, 1)
        XCTAssertTrue(said.first?.contains("=SUM(") == true, "the notice carries the typing: \(said)")
        await c.settleWrites()
        XCTAssertNil(c.host.state.table[cellKey(c, 1, 1)])
    }

    /// **The window closing folds**, its open edit committed — through the
    /// hook ⌘W reaches (`viewWillMove(toWindow: nil)`; SwiftUI never
    /// dismantles a closed scene's view), as `WindowTeardownScorchTests` drives it.
    func test_closingTheWindowFoldsWithTheEditCommitted() async throws {
        let m = try await mount()
        let (_, c) = try await expanded(m)
        typeInFirstCell(m, c, "4")
        let said = await notices { m.textView.viewWillMove(toWindow: nil) }
        XCTAssertNil(m.coordinator.figureGrid)
        XCTAssertEqual(said, [])
        await c.settleWrites()
        XCTAssertEqual(c.host.state.table[cellKey(c, 1, 1)]?.content, .value(.number(4)))
    }

    /// **The line leaving the text folds**, and an open formula that will not
    /// read is said as a notice with its text, never lost.
    func test_theLineLeavingWithAnUnreadableFormulaIsSaidWithItsText() async throws {
        let m = try await mount()
        let (_, c) = try await expanded(m)
        typeInFirstCell(m, c, "=1+")
        let said = await notices {
            m.coordinator.applyExternalText(
                m.textView.string.replacingOccurrences(of: "![Cash](../figures/t.csv){#tbl:t}\n\n", with: ""))
        }
        XCTAssertNil(m.coordinator.figureGrid, "the line is gone: the grid folds")
        XCTAssertTrue(said.contains { $0.contains("=1+") }, "the notice carries the typing: \(said)")
        XCTAssertTrue(m.window.firstResponder === m.textView, "the grid had the keys: the text takes them")
    }

    // MARK: - The caret leaving the line

    /// **Return expands while the visit opens with the text still holding
    /// the keys**: a caret moved along the line keeps the expansion; a caret
    /// moved off it (↓ on the real key path) folds it, and the visit, once
    /// open, mounts nothing.
    func test_aCaretLeavingTheLineBeforeTheGridHasTheKeysFolds() async throws {
        let m = try await mount()
        let line = location(m, "![Cash](")
        m.textView.setSelectedRange(NSRange(location: line + 3, length: 0))
        press(m, "\r", code: 36)
        let grid = try XCTUnwrap(m.coordinator.figureGrid, "premise: Return expanded")
        XCTAssertTrue(m.window.firstResponder === m.textView, "premise: the visit is still opening")

        press(m, "\u{F703}", code: 124)   // → along the line
        XCTAssertTrue(m.coordinator.figureGrid === grid, "a caret on the line keeps it")
        down(m)
        XCTAssertNil(m.coordinator.figureGrid, "a caret off the line folds it")
        await grid.opening?.value
        XCTAssertNil(grid.panel?.superview, "the visit mounts nothing")
        XCTAssertTrue(m.window.firstResponder === m.textView)
    }
}
