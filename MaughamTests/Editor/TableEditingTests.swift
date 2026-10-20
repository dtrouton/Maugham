// MaughamTests/Editor/TableEditingTests.swift
import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// Tables in the manuscript editor (plan 3a Task 5): Tab and Shift-Tab move by
/// cell, Return at a body row's end adds a row, and the table re-aligns on each
/// of those and when the caret leaves it — one ⌘Z step each, the writer's
/// earlier typing still undoable, never mid-composition. Driven through
/// `NSTextView.doCommand(by:)`, the path a key binding takes (the delegate first,
/// then AppKit's default), with no synthesised keys and no waits: the
/// leave-tidy's runloop hop is run by hand with `performPendingTableTidy()`.
@MainActor
final class TableEditingTests: XCTestCase {
    override class func setUp() { FontWarmup.ensure() }

    // MARK: - Fixture

    final class Box {
        var text: String
        init(_ text: String) { self.text = text }
    }

    struct Mounted {
        let box: Box
        let window: KeyTestWindow
        let textView: NSTextView
        let coordinator: EditorCoordinator
        var undo: UndoManager { textView.undoManager! }
        var string: String { textView.string }
        var selected: String { (textView.string as NSString).substring(with: textView.selectedRange()) }
    }

    private func mount(_ text: String) throws -> Mounted {
        let box = Box(text)
        let binding = Binding(get: { box.text }, set: { box.text = $0 })
        var configuration = EditorSurfaceConfiguration(
            presentation: .init(theme: .light, typography: .defaults, mode: ProseMode(),
                                typewriterScroll: false, sentenceFocus: false,
                                paragraphFocus: false, showElementGutter: false),
            control: EditorControl())
        configuration.answersInsertCommands = true
        let window = TestWindow.mount(EditorSurface(text: binding, configuration: configuration),
                                      size: CGSize(width: 700, height: 500),
                                      as: KeyTestWindow.self)
        addTeardownBlock { @MainActor in
            window.reportsKey = false
            window.close()
        }
        let textView = try XCTUnwrap(Self.textView(in: window.contentView))
        let coordinator = try XCTUnwrap(textView.delegate as? EditorCoordinator)
        window.makeFirstResponder(textView)
        textView.undoManager?.groupsByEvent = false
        textView.undoManager?.removeAllActions()
        return Mounted(box: box, window: window, textView: textView, coordinator: coordinator)
    }

    private static func textView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let tv = view as? NSTextView { return tv }
        for sub in view.subviews { if let tv = textView(in: sub) { return tv } }
        return nil
    }

    /// One user event in its own undo group, as `NSApplication` brackets a
    /// keystroke (the test host runs no event loop; see `InsertCommandTests`).
    private func asOneEvent(_ m: Mounted, _ body: () -> Void) {
        m.undo.beginUndoGrouping()
        body()
        m.undo.endUndoGrouping()
    }

    /// A key command. `edits: false` runs it OUTSIDE any undo group: with
    /// `groupsByEvent` off, an undo registration there raises, so a command
    /// that must make no undo step is proved to make none (an empty bracket
    /// would itself count as a step — `canUndo` is true after one).
    private func command(_ selector: Selector, _ m: Mounted, edits: Bool) {
        if edits {
            asOneEvent(m) { m.textView.doCommand(by: selector) }
        } else {
            m.textView.doCommand(by: selector)
        }
    }

    private func tab(_ m: Mounted, edits: Bool = true) {
        command(#selector(NSResponder.insertTab(_:)), m, edits: edits)
    }
    private func backtab(_ m: Mounted, edits: Bool = true) {
        command(#selector(NSResponder.insertBacktab(_:)), m, edits: edits)
    }
    private func newline(_ m: Mounted, edits: Bool = true) {
        command(#selector(NSResponder.insertNewline(_:)), m, edits: edits)
    }

    /// The leave-tidy's runloop hop, run now, as its own event.
    private func runTheTidy(_ m: Mounted, edits: Bool = true) {
        if edits { asOneEvent(m) { m.coordinator.performPendingTableTidy() } }
        else { m.coordinator.performPendingTableTidy() }
    }

    private func compose(_ s: String, _ m: Mounted) {
        asOneEvent(m) {
            m.textView.setMarkedText(s, selectedRange: NSRange(location: 1, length: 0),
                                     replacementRange: m.textView.selectedRange())
        }
    }

    private func caret(_ m: Mounted, at location: Int) {
        m.textView.setSelectedRange(NSRange(location: location, length: 0))
    }

    private func caret(_ m: Mounted, before needle: String) {
        caret(m, at: (m.string as NSString).range(of: needle).location)
    }

    private func type(_ s: String, _ m: Mounted) {
        asOneEvent(m) { m.textView.insertText(s, replacementRange: m.textView.selectedRange()) }
    }

    private func assertInATable(_ m: Mounted, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotNil(MarkdownTokenizer.tableBlockRange(containing: m.textView.selectedRange().location,
                                                          in: m.coordinator.lastTokens),
                        "precondition: the caret is not in a table, so this proves nothing",
                        file: file, line: line)
    }

    static let tidy = """
        | A   | B   |
        | --- | --- |
        | c   | d   |
        """

    // MARK: - Tab and Shift-Tab

    func test_tabAndShiftTabMoveByCellSkippingTheDelimiterRow() throws {
        let m = try mount(Self.tidy)
        caret(m, before: "A")
        assertInATable(m)

        tab(m, edits: false);     XCTAssertEqual(m.selected, "B")
        tab(m, edits: false);     XCTAssertEqual(m.selected, "c", "the next row's first cell, past the delimiter")
        tab(m, edits: false);     XCTAssertEqual(m.selected, "d")
        let last = m.textView.selectedRange()
        tab(m, edits: false);     XCTAssertEqual(m.textView.selectedRange(), last, "Tab at the last cell does nothing")
        backtab(m, edits: false); XCTAssertEqual(m.selected, "c")
        backtab(m, edits: false); XCTAssertEqual(m.selected, "B", "the previous row's last cell")
        backtab(m, edits: false); XCTAssertEqual(m.selected, "A")
        backtab(m, edits: false); XCTAssertEqual(m.selected, "A", "Shift-Tab at the first cell does nothing")

        XCTAssertEqual(m.string, Self.tidy, "a tidy table moved without an edit")
        XCTAssertFalse(m.undo.canUndo, "a move with nothing to re-align made an undo step")
    }

    func test_tabIntoAnEmptyCellPutsTheCaretAtItsText() throws {
        let m = try mount(ReportInsert.table(nextLabelNumber: 1))
        caret(m, before: "Column 3")
        tab(m, edits: false)
        let row = (m.string as NSString).range(of: "|          |").location
        XCTAssertEqual(m.textView.selectedRange(), NSRange(location: row + 2, length: 0))
        XCTAssertEqual(m.string, ReportInsert.table(nextLabelNumber: 1),
                       "a freshly inserted table is already tidy — Tab must not re-align it")
        XCTAssertFalse(m.undo.canUndo)
    }

    func test_tabReAlignsAsOneUndoStepAndTheTypingBeforeItSurvives() throws {
        let m = try mount(Self.tidy)
        caret(m, before: "c ")
        m.textView.setSelectedRange(NSRange(location: m.textView.selectedRange().location, length: 1))
        type("carrots", m)
        let typed = m.string
        XCTAssertEqual(typed, "| A   | B   |\n| --- | --- |\n| carrots   | d   |")

        tab(m)
        XCTAssertEqual(m.string, "| A       | B   |\n| ------- | --- |\n| carrots | d   |")
        XCTAssertEqual(m.selected, "d", "the caret maps to the next cell of the re-aligned table")
        XCTAssertEqual(m.box.text, m.string, "the re-align reached the binding — the op log's door")

        m.undo.undo()
        XCTAssertEqual(m.string, typed, "one ⌘Z takes back the re-align alone")
        XCTAssertTrue(m.undo.canUndo, "the typing is still undoable")
        m.undo.undo()
        XCTAssertEqual(m.string, Self.tidy, "and the next ⌘Z takes back the typing")
    }

    func test_tabAtTheLastCellOfAnUntidyTableReAlignsAndKeepsTheCaretInItsCell() throws {
        let m = try mount("|A|B|\n|-|-|\n|c|dog|")
        caret(m, before: "og")
        tab(m)
        XCTAssertEqual(m.string, "| A   | B   |\n| --- | --- |\n| c   | dog |")
        XCTAssertEqual(m.textView.selectedRange(),
                       NSRange(location: (m.string as NSString).range(of: "og").location, length: 0))
    }

    func test_tabOutsideATableStillInsertsATab() throws {
        let m = try mount("Hello\n\n" + Self.tidy)
        caret(m, at: 5)
        tab(m)
        XCTAssertEqual(m.string, "Hello\t\n\n" + Self.tidy)
    }

    func test_tabOnTheCaptionLineIsAnOrdinaryTab() throws {
        let m = try mount(Self.tidy + "\nTable: Cap")
        caret(m, before: "Cap")
        assertInATable(m)
        tab(m)
        XCTAssertEqual(m.string, Self.tidy + "\nTable: \tCap")
    }

    // MARK: - Return

    func test_returnAtTheEndOfABodyRowAddsARowAsOneUndoStep() throws {
        let m = try mount("Intro.\n\n" + Self.tidy + "\nTable: Veg {#tbl:veg}")
        caret(m, before: "| c")
        m.textView.setSelectedRange(NSRange(location: NSMaxRange(
            (m.string as NSString).lineRange(for: m.textView.selectedRange())) - 1, length: 0))
        assertInATable(m)

        newline(m)
        XCTAssertEqual(m.string, "Intro.\n\n| A   | B   |\n| --- | --- |\n| c   | d   |\n|     |     |\n"
                       + "Table: Veg {#tbl:veg}", "the new row goes above the caption")
        let newRow = (m.string as NSString).range(of: "|     |     |").location
        XCTAssertEqual(m.textView.selectedRange(), NSRange(location: newRow + 2, length: 0),
                       "the caret waits in the new row's first cell")

        m.undo.undo()
        XCTAssertEqual(m.string, "Intro.\n\n" + Self.tidy + "\nTable: Veg {#tbl:veg}")
    }

    func test_returnAtTheEndOfTheLastRowWithNoCaptionAddsARow() throws {
        let m = try mount(Self.tidy)
        caret(m, at: (m.string as NSString).length)
        newline(m)
        XCTAssertEqual(m.string, Self.tidy + "\n|     |     |")
    }

    func test_returnElsewhereIsAnOrdinaryNewline() throws {
        let m = try mount(Self.tidy)
        caret(m, before: " d")
        newline(m)
        XCTAssertEqual(m.string, "| A   | B   |\n| --- | --- |\n| c   |\n d   |",
                       "mid-row Return is AppKit's")

        let header = try mount(Self.tidy)
        caret(header, at: ("| A   | B   |" as NSString).length)
        newline(header)
        XCTAssertEqual(header.string, "| A   | B   |\n\n| --- | --- |\n| c   | d   |",
                       "Return at the header's end is AppKit's")
    }

    // MARK: - Leaving the table

    func test_leavingAnUntidyTableTidiesItOnTheNextRunloopAsOneUndoStep() throws {
        let untidy = "|A|B|\n|-|-|\n|c|d|\n\nAfter."
        let m = try mount(untidy)
        caret(m, at: (untidy as NSString).length)
        type("!", m)                                   // the writer's typing, outside the table
        caret(m, before: "c")
        assertInATable(m)
        caret(m, before: "After")

        XCTAssertEqual(m.string, untidy + "!", "the tidy ran inside the selection callback's stack")
        XCTAssertTrue(m.coordinator.hasPendingTableTidy, "leaving scheduled nothing")
        runTheTidy(m)

        let tidied = "| A   | B   |\n| --- | --- |\n| c   | d   |\n\nAfter.!"
        XCTAssertEqual(m.string, tidied)
        XCTAssertEqual(m.textView.selectedRange(),
                       NSRange(location: (tidied as NSString).range(of: "After").location, length: 0),
                       "the caret keeps its place in the text after the table")
        XCTAssertEqual(m.box.text, tidied)

        m.undo.undo()
        XCTAssertEqual(m.string, untidy + "!", "one ⌘Z takes the tidy back")
        m.undo.undo()
        XCTAssertEqual(m.string, untidy, "and the next takes back the typing before it")
        // That second ⌘Z moved the selection out of the (untidy) table. Had it
        // scheduled a tidy, the tidy would land on top of the undo stack, eat
        // the redo, and the writer could never ⌘Z past it.
        XCTAssertFalse(m.coordinator.hasPendingTableTidy,
                       "an undo's selection change scheduled a tidy")
        runTheTidy(m, edits: false)
        XCTAssertEqual(m.string, untidy)
        XCTAssertTrue(m.undo.canRedo, "the redo stack survived")
    }

    func test_leavingATidyTableEditsNothing() throws {
        let m = try mount(Self.tidy + "\n\nAfter.")
        caret(m, before: "c")
        caret(m, before: "After")
        runTheTidy(m, edits: false)
        XCTAssertEqual(m.string, Self.tidy + "\n\nAfter.")
        XCTAssertFalse(m.undo.canUndo)
    }

    func test_comingBackBeforeTheRunloopCancelsTheTidy() throws {
        let m = try mount("|A|B|\n|-|-|\n|c|d|\n\nAfter.")
        caret(m, before: "c")
        caret(m, before: "After")
        caret(m, before: "d")
        XCTAssertFalse(m.coordinator.hasPendingTableTidy)
        runTheTidy(m, edits: false)
        XCTAssertEqual(m.string, "|A|B|\n|-|-|\n|c|d|\n\nAfter.", "the caret is back in the table")
    }

    func test_leavingTheTableIntoTextBeforeItKeepsTheCaret() throws {
        let m = try mount("Before.\n\n|A|B|\n|-|-|\n|c|d|")
        caret(m, before: "c")
        caret(m, at: 3)
        runTheTidy(m)
        XCTAssertEqual(m.string, "Before.\n\n| A   | B   |\n| --- | --- |\n| c   | d   |")
        XCTAssertEqual(m.textView.selectedRange(), NSRange(location: 3, length: 0))
    }

    func test_theTidyNeverTakesTheFocusFromElsewhere() throws {
        let untidy = "|A|B|\n|-|-|\n|c|d|\n\nAfter."
        let m = try mount(untidy)
        caret(m, before: "c")
        caret(m, before: "After")                      // as a find jump would move it
        m.window.makeFirstResponder(nil)               // the focus is elsewhere
        runTheTidy(m, edits: false)
        XCTAssertEqual(m.string, untidy)
        XCTAssertFalse(m.window.firstResponder === m.textView, "the tidy took the focus")

        // Back in the editor, the next move tidies the table it still remembers.
        m.window.makeFirstResponder(m.textView)
        caret(m, before: "fter")
        XCTAssertTrue(m.coordinator.hasPendingTableTidy)
        runTheTidy(m)
        XCTAssertEqual(m.string, "| A   | B   |\n| --- | --- |\n| c   | d   |\n\nAfter.")
    }

    // MARK: - IME

    func test_aCompositionInACellIsNeitherInterceptedNorReAligned() throws {
        let untidy = "|A|B|\n|-|-|\n|c|d|\n\nAfter."
        let m = try mount(untidy)
        caret(m, before: "c")
        compose("か", m)
        XCTAssertTrue(m.textView.hasMarkedText(), "precondition: no composition is active")
        let composing = m.string
        let marked = m.textView.markedRange()

        let selectors = [#selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)),
                         #selector(NSResponder.insertNewline(_:))]
        for selector in selectors {
            XCTAssertFalse(m.coordinator.textView(m.textView, doCommandBy: selector),
                           "\(selector) was intercepted mid-composition")
        }
        XCTAssertEqual(m.string, composing)
        XCTAssertEqual(m.textView.markedRange(), marked, "the composition was disturbed")
        XCTAssertTrue(m.textView.hasMarkedText())
    }

    func test_aCompositionOutsideTheTableHoldsTheLeaveTidy() throws {
        let untidy = "|A|B|\n|-|-|\n|c|d|\n\nAfter."
        let m = try mount(untidy)
        caret(m, before: "c")
        caret(m, before: "After")
        XCTAssertTrue(m.coordinator.hasPendingTableTidy)
        compose("か", m)
        let composing = m.string
        let marked = m.textView.markedRange()

        runTheTidy(m, edits: false)
        XCTAssertEqual(m.string, composing, "the table re-aligned while an input method was composing")
        XCTAssertEqual(m.textView.markedRange(), marked)
    }

    // MARK: - The membrane

    func test_aReadOnlyPostureNeverReAlignsButTabStillMoves() throws {
        let untidy = "|A|B|\n|-|-|\n|c|d|\n\nAfter."
        let m = try mount(untidy)
        m.coordinator.setLockEditing(true)
        let writes = m.box.text
        caret(m, before: "A")
        tab(m, edits: false)
        XCTAssertEqual(m.selected, "B", "a refused re-align still moves the caret")
        caret(m, before: "After")
        runTheTidy(m, edits: false)
        caret(m, at: (untidy as NSString).range(of: "|c|d|").location + 5)
        newline(m, edits: false)
        XCTAssertEqual(m.string, untidy, "a read-only posture let a table edit through")
        XCTAssertEqual(m.box.text, writes)
        XCTAssertFalse(m.undo.canUndo)
    }
}
