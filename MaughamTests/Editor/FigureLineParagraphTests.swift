// MaughamTests/Editor/FigureLineParagraphTests.swift
import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **A figure line always stands as its own paragraph** (Denver's smoke,
/// 2026-10-28: Return at a table figure's line start, then typing, glued the
/// sentence onto the figure and the card vanished). The editor applies
/// `FigureLineSeparation` in `shouldChangeTextIn`; these drive the real key
/// path — `insertText`, and `doCommand(by:)` for Return, Backspace and
/// Delete, as a key binding sends them — and read the text and the caret
/// synchronously. No presses, no waits (tripwire 33).
@MainActor
final class FigureLineParagraphTests: XCTestCase {
    override class func setUp() { FontWarmup.ensure() }

    private static let fig = "![Test Table](figures/table.csv){#tbl:table}"
    private let fig = FigureLineParagraphTests.fig

    // MARK: - Fixture

    final class Box {
        var text: String
        init(_ text: String) { self.text = text }
    }

    @MainActor
    struct Mounted {
        let box: Box
        let window: KeyTestWindow
        let textView: NSTextView
        let coordinator: EditorCoordinator
        var undo: UndoManager { textView.undoManager! }
        var string: String { textView.string }
        var caret: Int { textView.selectedRange().location }
    }

    private func mount(_ text: String, mode: any WritingMode = ProseMode()) throws -> Mounted {
        let box = Box(text)
        let binding = Binding(get: { box.text }, set: { box.text = $0 })
        let configuration = EditorSurfaceConfiguration(
            presentation: .init(theme: .light, typography: .defaults, mode: mode,
                                typewriterScroll: false, sentenceFocus: false,
                                paragraphFocus: false, showElementGutter: false),
            control: EditorControl())
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
    /// keystroke (the test host runs no event loop).
    private func asOneEvent(_ m: Mounted, _ body: () -> Void) {
        m.undo.beginUndoGrouping()
        body()
        m.undo.endUndoGrouping()
    }

    private func caret(_ m: Mounted, at location: Int) {
        m.textView.setSelectedRange(NSRange(location: location, length: 0))
    }
    private func type(_ s: String, _ m: Mounted) {
        asOneEvent(m) { m.textView.insertText(s, replacementRange: m.textView.selectedRange()) }
    }
    private func command(_ selector: Selector, _ m: Mounted) {
        asOneEvent(m) { m.textView.doCommand(by: selector) }
    }
    private func newline(_ m: Mounted) { command(#selector(NSResponder.insertNewline(_:)), m) }
    private func backspace(_ m: Mounted) { command(#selector(NSResponder.deleteBackward(_:)), m) }
    private func forwardDelete(_ m: Mounted) { command(#selector(NSResponder.deleteForward(_:)), m) }
    private func at(_ m: Mounted, _ needle: String) -> Int { (m.string as NSString).range(of: needle).location }

    // MARK: - The smoke's case, on the real key path

    /// Return at the figure line's start (ruling M4) opens a line above it;
    /// typing there keeps a blank line between, the caret after the text.
    func test_returnAtTheFigureLinesStartThenTyping_keepsTheFigureItsOwnParagraph() throws {
        let m = try mount("This is me testing.\n\n\(fig)")
        caret(m, at: at(m, "![Test"))
        newline(m)
        XCTAssertEqual(m.string, "This is me testing.\n\n\n\(fig)", "M4: Return opens a line above")
        caret(m, at: at(m, "![Test") - 1)
        type("T", m)
        XCTAssertEqual(m.string, "This is me testing.\n\nT\n\n\(fig)")
        XCTAssertEqual(m.caret, at(m, "\nT\n") + 2, "the caret right after T")
        XCTAssertEqual(m.box.text, m.string, "the binding wrote what the editor shows")
    }

    /// Return leaves the caret on the figure line itself: typing there goes
    /// into a new paragraph above the card, the figure line untouched.
    func test_typingAtColumnZeroOfTheFigureLine_goesIntoAParagraphAbove() throws {
        let m = try mount("Prose.\n\n\(fig)\n\nAfter.")
        caret(m, at: at(m, "![Test"))
        type("Hi", m)
        XCTAssertEqual(m.string, "Prose.\n\nHi\n\n\(fig)\n\nAfter.")
        XCTAssertEqual(m.caret, at(m, "Hi") + 2)
        type("!", m)
        XCTAssertEqual(m.string, "Prose.\n\nHi!\n\n\(fig)\n\nAfter.", "the next keystroke is ordinary typing")
    }

    func test_returnAtTheFigureLinesEndThenTyping_landsInAParagraphBelow() throws {
        let m = try mount("Prose.\n\n\(fig)")
        caret(m, at: (m.string as NSString).length)
        newline(m)
        XCTAssertEqual(m.string, "Prose.\n\n\(fig)\n")
        type("Below", m)
        XCTAssertEqual(m.string, "Prose.\n\n\(fig)\n\nBelow")
        XCTAssertEqual(m.caret, (m.string as NSString).length)
    }

    /// One ⌘Z takes back the typed text and the break the editor added.
    func test_oneUndoRemovesTheTypedTextAndTheAddedBreak() throws {
        let start = "Prose.\n\n\n\(fig)"
        let m = try mount(start)
        caret(m, at: at(m, "![Test") - 1)
        type("T", m)
        XCTAssertEqual(m.string, "Prose.\n\nT\n\n\(fig)")
        m.undo.undo()
        XCTAssertEqual(m.string, start, "one undo, both gone")
        XCTAssertFalse(m.undo.canUndo)
        m.undo.redo()
        XCTAssertEqual(m.string, "Prose.\n\nT\n\n\(fig)", "redo is not judged again")
    }

    /// An undo restores the text that was, even one the rule would never
    /// make: an old file's glued figure line comes back as it was.
    func test_undoIsNeverJudged_anOldGluedLineComesBack() throws {
        let start = "Prose.\n\(fig)"
        let m = try mount(start)
        caret(m, at: at(m, "![Test"))
        newline(m)
        XCTAssertEqual(m.string, "Prose.\n\n\(fig)", "Return at its start separates it")
        m.undo.undo()
        XCTAssertEqual(m.string, start, "⌘Z puts back the text as it was")
    }

    /// A command places its own text (Route A) and is never rewritten.
    func test_aCommandsEditIsNeverJudged() throws {
        let m = try mount("Prose.\n\n\n\(fig)")
        let blank = at(m, "![Test") - 1
        XCTAssertTrue(m.coordinator.applyCommandEdit(replacing: NSRange(location: blank, length: 0), with: "X",
                                                     selecting: NSRange(location: blank + 1, length: 0),
                                                     actionName: "Test"))
        XCTAssertEqual(m.string, "Prose.\n\nX\n\(fig)", "written as the command asked")
    }

    // MARK: - Deleting the blank line

    func test_backspaceAtTheFigureLinesStart_movesTheCaretUpAndChangesNothing() throws {
        let start = "Prose.\n\n\(fig)"
        let m = try mount(start)
        caret(m, at: at(m, "![Test"))
        m.textView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))   // outside a group: no undo step may register
        XCTAssertEqual(m.string, start)
        XCTAssertEqual(m.caret, ("Prose." as NSString).length, "the caret at the end of the paragraph above")
        XCTAssertFalse(m.undo.canUndo, "no undo step")
    }

    func test_backspaceOverAnExtraBlankLine_deletesIt() throws {
        let m = try mount("Prose.\n\n\n\(fig)")
        caret(m, at: at(m, "![Test"))
        backspace(m)
        XCTAssertEqual(m.string, "Prose.\n\n\(fig)")
    }

    func test_forwardDeleteOfTheBlankLine_keepsIt() throws {
        let start = "Prose.\n\n\(fig)"
        let m = try mount(start)
        caret(m, at: 6)
        m.textView.doCommand(by: #selector(NSResponder.deleteForward(_:)))
        XCTAssertEqual(m.string, start)
        XCTAssertEqual(m.caret, 6)
    }

    func test_aSelectionDeleteReachingTheFigureLine_keepsItApart() throws {
        let m = try mount("Prose.\n\n\(fig)")
        m.textView.setSelectedRange(NSRange(location: 5, length: 3))   // ".\n\n"
        backspace(m)
        XCTAssertEqual(m.string, "Prose\n\n\(fig)")
        XCTAssertEqual(m.caret, 5)
    }

    func test_aReplacementOverTheBlankLine_addsItBack() throws {
        let m = try mount("Prose.\n\n\(fig)")
        asOneEvent(m) { m.textView.insertText("more", replacementRange: NSRange(location: 7, length: 1)) }
        XCTAssertEqual(m.string, "Prose.\nmore\n\n\(fig)")
        XCTAssertEqual(m.caret, at(m, "more") + 4)
    }

    // MARK: - Untouched

    func test_ordinaryProseIsUntouched() throws {
        let m = try mount("Prose.\n\n\(fig)")
        caret(m, at: 6)
        type(" More", m)
        newline(m)
        type("Next", m)
        XCTAssertEqual(m.string, "Prose. More\nNext\n\n\(fig)", "Return in prose is one newline")
    }

    func test_screenplayIsNotAffected() throws {
        let m = try mount("INT. ROOM - DAY\n\n\(fig)", mode: ScreenplayMode())
        caret(m, at: at(m, "![Test"))
        type("x", m)
        XCTAssertEqual(m.string, "INT. ROOM - DAY\n\nx\(fig)")
    }

    func test_aReadOnlyEditorStillRefusesFirst() throws {
        let start = "Prose.\n\n\n\(fig)"
        let m = try mount(start)
        m.coordinator.setLockEditing(true)
        caret(m, at: at(m, "![Test") - 1)
        m.textView.insertText("T", replacementRange: m.textView.selectedRange())
        XCTAssertEqual(m.string, start)
        XCTAssertFalse(m.undo.canUndo)
    }

    /// An input method's composition is never rewritten, start to commit:
    /// the marked text sits where the writer composes it.
    func test_aCompositionIsLeftAsComposed() throws {
        let m = try mount("Prose.\n\n\(fig)")
        caret(m, at: at(m, "![Test"))
        asOneEvent(m) {
            m.textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                                     replacementRange: m.textView.selectedRange())
        }
        XCTAssertTrue(m.textView.hasMarkedText(), "the composition is still open")
        XCTAssertEqual(m.string, "Prose.\n\nか\(fig)")
        let marked = m.textView.markedRange()
        asOneEvent(m) { m.textView.insertText("か", replacementRange: marked) }
        XCTAssertFalse(m.textView.hasMarkedText())
        XCTAssertEqual(m.string, "Prose.\n\nか\(fig)", "the commit is not rewritten either")
    }
}
