import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The in-place grid's whole-branch review fixes** (report plan 7c final
/// wave), each on a mounted editor: no key the grid is sent edits the
/// manuscript behind it (C1); the bottom bar's open typing is written before
/// a fold (I1); the bottom bar follows the line's caption and number (I2);
/// and the room and the double-click before a card is cached (T6 M3, M6).
/// Keys go down the real path (`window.sendEvent` to the first responder);
/// no click is synthesised (tripwire 33) and nothing waits on a clock.
@MainActor
final class FigureGridFinalWaveTests: FigureGridMountedTestCase {

    // MARK: - Helpers

    private func send(_ m: Mounted, _ characters: String, code: UInt16, _ flags: NSEvent.ModifierFlags = []) {
        m.window.sendEvent(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: m.window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!)
    }

    private func expanded(_ m: Mounted) async throws -> (FigureGridExpansion, FigureGridController) {
        XCTAssertTrue(m.coordinator.expandFigureGrid(lineAt: location(m, "![Cash](")))
        let grid = try await opened(m)
        let controller = try XCTUnwrap(grid.controller)
        XCTAssertTrue(m.window.firstResponder === controller.gridView, "premise: the grid has the keys")
        return (grid, controller)
    }

    private func cellKey(_ c: FigureGridController, _ column: Int, _ row: Int) -> CellKey {
        let table = c.host.state.table
        return CellKey(row: table.rows[row - 1], column: table.columns[column - 1])
    }

    /// The field editor now typing in `field`, after `text` is typed into it.
    private func typeInto(_ field: NSTextField, _ text: String, in m: Mounted) throws {
        XCTAssertTrue(m.window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView, "premise: the field is being edited")
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
        XCTAssertNotNil(field.currentEditor(), "premise: still editing — nothing has ended it")
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

    // MARK: - C1: no key reaches the manuscript

    /// **Every key the grid is sent stays in the grid** (final review C1).
    /// fn-⌫ clears the selected cell as ⌫ does; ⌘ arrows, Home and End go to
    /// the table's edge; a chord the grid has no meaning for (⌘⌫, ⌥⌫'s
    /// cousins ⌥← and ⌃K, Page Down) is swallowed. Through all of it the
    /// manuscript is byte-for-byte what it was, its caret where it was, and
    /// the grid still open with the keys. (In this harness the mounted text
    /// view, never first responder, does not act on a key passed up to it,
    /// so the responder-chain pins that go red without the fix are
    /// `FigureGridViewTests`' grid and panel tests over a plain text view.)
    func test_noKeyTheGridIsSentEditsOrMovesTheManuscript() async throws {
        let m = try await mount()
        // The text's caret mid-word, where a key passed on would delete or move it.
        park(m, caret: location(m, "Paragraph 40 of") + 12, showing: location(m, "![Cash]("))
        let (grid, c) = try await expanded(m)
        try await c.host.setCell(Cell(content: .value(.number(5))), at: cellKey(c, 1, 1), undoManager: nil)
        await c.hostSync?.value
        let text = m.textView.string
        let caret = m.textView.selectedRange()

        send(m, "\u{F728}", code: 117)                                   // fn-⌫
        await c.settleWrites()
        XCTAssertNil(c.host.state.table[cellKey(c, 1, 1)], "forward delete clears the cell")

        send(m, "\u{7F}", code: 51, .command)                             // ⌘⌫
        send(m, "\u{F702}", code: 123, .option)                           // ⌥←
        send(m, "\u{0B}", code: 40, .control)                             // ⌃K
        send(m, "\u{04}", code: 2, .control)                              // ⌃D: forward delete
        send(m, "\u{F72D}", code: 121)                                    // Page Down
        send(m, "\u{F703}", code: 124, .command)                          // ⌘→: the row's last cell
        XCTAssertEqual(c.bars.addressLabel.stringValue, "C1")
        send(m, "\u{F701}", code: 125, [.command, .shift])                // ⌘⇧↓: to the bottom edge
        XCTAssertEqual(c.bars.addressLabel.stringValue, "C1:C3")
        send(m, "\u{F729}", code: 115)                                    // Home: the row's first cell
        XCTAssertEqual(c.bars.addressLabel.stringValue, "A1")

        XCTAssertEqual(m.textView.string, text, "the manuscript is untouched")
        XCTAssertEqual(m.textView.selectedRange(), caret, "and its caret did not move")
        XCTAssertTrue(m.coordinator.figureGrid === grid, "the grid is still open")
        XCTAssertTrue(m.window.firstResponder === c.gridView, "with the keys")
    }

    // MARK: - I1: the bottom bar's typing is written before the fold

    /// **A caption typed and then Done** (a click takes no focus, so the
    /// field is still editing when the grid folds): the line's caption is
    /// written, as one ⌘Z, and the text takes the keys.
    func test_aCaptionStillBeingTypedIsWrittenByDone() async throws {
        let m = try await mount()
        let (_, c) = try await expanded(m)
        let original = m.textView.string
        try typeInto(c.bars.captionField, "Cash by month", in: m)

        c.perform(.done)

        XCTAssertNil(m.coordinator.figureGrid, "Done folded")
        XCTAssertTrue(m.textView.string.contains("![Cash by month](../figures/t.csv){#tbl:t}"),
                      "the caption typed in the bar reached the line")
        XCTAssertTrue(m.window.firstResponder === m.textView, "the text has the keys")
        XCTAssertEqual(m.textView.undoManager?.undoActionName, "Edit Caption")
        m.textView.undoManager?.undo()
        XCTAssertEqual(m.textView.string, original, "one ⌘Z")
    }

    /// The formula bar and the name too: a value typed in the formula bar is
    /// written at Done, and a name still being typed is renamed.
    func test_aFormulaBarEditAndANameStillBeingTypedAreWrittenByDone() async throws {
        let m = try await mount()
        let (_, d) = try await expanded(m)
        try typeInto(d.bars.formulaField, "42", in: m)
        d.perform(.done)
        XCTAssertNil(m.coordinator.figureGrid, "Done folded")
        await d.settleWrites()
        XCTAssertEqual(d.host.state.table[cellKey(d, 1, 1)]?.content, .value(.number(42)))

        let (_, c) = try await expanded(m)
        try typeInto(c.bars.nameField, "cash", in: m)
        c.perform(.done)
        XCTAssertNil(m.coordinator.figureGrid, "Done folded")
        await c.settleWrites()
        XCTAssertEqual(m.store.manifest.figures?.first { $0.id == c.figureId }?.name, "cash", "the name was renamed")
    }

    /// A caption refused at a forced fold (its line deleted under the grid)
    /// is said as a notice carrying its text — never written to the line
    /// the anchor fell onto.
    func test_aCaptionPendingWhenTheLineGoesIsSaid() async throws {
        let m = try await mount()
        let (_, c) = try await expanded(m)
        try typeInto(c.bars.captionField, "Lost caption", in: m)
        let said = await notices {
            m.coordinator.applyExternalText(
                m.textView.string.replacingOccurrences(of: "![Cash](../figures/t.csv){#tbl:t}\n\n", with: ""))
        }
        XCTAssertNil(m.coordinator.figureGrid, "the line went: the grid folded")
        XCTAssertTrue(said.contains { $0.contains("Lost caption") }, "the typed caption is said: \(said)")
        XCTAssertFalse(m.textView.string.contains("Lost caption"), "and written to no other line")
    }

    // MARK: - I2: the bottom bar follows the line

    /// **⌘Z of a caption while expanded** puts the bar's caption back, and a
    /// figure line added above renumbers its "Table N" (final review I2).
    func test_theBottomBarFollowsTheLinesCaptionAndNumber() async throws {
        let m = try await mount()
        m.coordinator.restyleSettleDelayMs = 0   // a settle runs on the next main-actor turn
        m.coordinator.figureNumbersBefore = { .init(tablesBefore: 0, figuresBefore: 0) }   // as EditorHost wires it
        let (grid, c) = try await expanded(m)
        XCTAssertEqual(c.bars.numberLabel.stringValue, "Table 1")
        c.perform(.caption("Renamed"))
        XCTAssertEqual(c.bars.captionField.stringValue, "Renamed")
        m.textView.undoManager?.undo()
        await m.coordinator.deferredRestyleTask?.value
        XCTAssertTrue(m.text.substring(from: grid.lineLocation).hasPrefix("![Cash]("), "premise: the text is back")
        XCTAssertEqual(c.bars.committedCaption, "Cash", "the bar follows the undo")
        XCTAssertEqual(c.bars.captionField.stringValue, "Cash")

        let top = location(m, "Paragraph 1 ")
        XCTAssertTrue(m.coordinator.applyCommandEdit(
            replacing: NSRange(location: top, length: 0), with: "![Other](../figures/t.csv){#tbl:o}\n\n",
            selecting: NSRange(location: top, length: 0), actionName: "Test",
            landing: .deferred(writerMoved: true)))
        await m.coordinator.deferredRestyleTask?.value
        XCTAssertTrue(m.coordinator.figureGrid === grid, "premise: still open")
        XCTAssertEqual(c.bars.numberLabel.stringValue, "Table 2", "a table line above renumbers it")
    }

    // MARK: - T6 carries: before the card is cached

    /// **A guessed room grows at mount** (T6 review M3): expanded before its
    /// card is cached, a 20-row table holds Insert's three-row room, and the
    /// visit's table grows it to fifteen rows when the grid mounts.
    func test_aRoomGuessedBeforeTheCardIsCachedGrowsWhenTheGridMounts() async throws {
        let m = try await mount(rows: 20)
        m.cards.attach(nil)   // no card yet
        XCTAssertTrue(m.coordinator.expandFigureGrid(lineAt: location(m, "![Cash](")))
        let grid = try XCTUnwrap(m.coordinator.figureGrid)
        XCTAssertEqual(grid.room, FigureGridPanel.room(rows: FigureGridExpansion.defaultRows, typography: .defaults))
        _ = try await opened(m)
        XCTAssertEqual(grid.room, FigureGridPanel.room(rows: 20, typography: .defaults))
    }

    /// **A table line whose card is not cached yet takes a double-click**
    /// (T6 review M6), as Return on the same line expands it.
    func test_anUncachedTableCardIsFoundUnderADoubleClick() async throws {
        let m = try await mount()
        let line = location(m, "![Cash](")
        park(m, caret: 0, showing: line)
        let inCard = CGPoint(x: m.textView.textContainerOrigin.x + 40, y: lineBottom(m, at: line) + 10)
        m.cards.attach(nil)
        XCTAssertNil(m.coordinator.figureCardModel?("../figures/t.csv"), "premise: no card cached")
        XCTAssertEqual(m.coordinator.figureCardLine(at: inCard), line)
    }
}
