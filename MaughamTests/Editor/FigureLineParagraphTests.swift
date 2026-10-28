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

    /// `pickers`: a manuscript surface with the citation and cross-reference
    /// pickers over `CitationCompletionTests`' library, as `EditorHost` wires it.
    private func mount(_ text: String, mode: any WritingMode = ProseMode(), pickers: Bool = false,
                       onPostEditCursor: ((Int) -> Void)? = nil) throws -> Mounted {
        let box = Box(text)
        let binding = Binding(get: { box.text }, set: { box.text = $0 })
        var configuration = EditorSurfaceConfiguration(
            presentation: .init(theme: .light, typography: .defaults, mode: mode,
                                typewriterScroll: false, sentenceFocus: false,
                                paragraphFocus: false, showElementGutter: false),
            control: EditorControl())
        configuration.callbacks.onPostEditCursor = onPostEditCursor
        if pickers {
            let index = CitationCompletionTests.index()
            configuration.answersInsertCommands = true
            configuration.paragraphProviders.referenceIndex = { index }
        }
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

    // MARK: - Input methods (whole-branch review I1)

    /// A composition is never rewritten while it is open; its commit is
    /// judged as the insert it is — a dead key's é at a figure line's start
    /// goes into a paragraph above, in the commit's own event.
    func test_aCommitAtTheFigureLinesStart_isKeptApart() throws {
        let m = try mount("Prose.\n\n\(fig)")
        caret(m, at: at(m, "![Test"))
        asOneEvent(m) {
            m.textView.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0),
                                     replacementRange: m.textView.selectedRange())
        }
        XCTAssertTrue(m.textView.hasMarkedText(), "the composition is still open")
        XCTAssertEqual(m.string, "Prose.\n\n´\(fig)", "left as composed while open")
        let marked = m.textView.markedRange()
        asOneEvent(m) { m.textView.insertText("É", replacementRange: marked) }
        XCTAssertFalse(m.textView.hasMarkedText())
        XCTAssertEqual(m.string, "Prose.\n\nÉ\n\n\(fig)", "the commit is kept apart")
        XCTAssertEqual(m.caret, at(m, "É") + 1, "the caret right after the commit")
        XCTAssertEqual(m.box.text, m.string)
    }

    func test_aCommitOnTheEmptyLineAboveAFigure_isKeptApart() throws {
        let m = try mount("Prose.\n\n\n\(fig)")
        caret(m, at: at(m, "![Test") - 1)
        asOneEvent(m) {
            m.textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                                     replacementRange: m.textView.selectedRange())
        }
        XCTAssertEqual(m.string, "Prose.\n\nか\n\(fig)", "left as composed while open")
        let marked = m.textView.markedRange()
        asOneEvent(m) { m.textView.insertText("か", replacementRange: marked) }
        XCTAssertEqual(m.string, "Prose.\n\nか\n\n\(fig)")
        XCTAssertEqual(m.caret, at(m, "か") + 1)
    }

    // MARK: - A held key (whole-branch review I3)

    /// The first Backspace at a figure line's start moves the caret up; its
    /// repeats are refused where they are, so holding the key never deletes
    /// the paragraph above.
    func test_aHeldBackspaceAtTheFigureLinesStart_repeatsStayPut() throws {
        let start = "Prose.\n\n\(fig)"
        let m = try mount(start)
        var repeating = false
        m.coordinator.isKeyRepeat = { repeating }
        caret(m, at: at(m, "![Test"))
        repeating = true
        backspace(m)
        XCTAssertEqual(m.string, start)
        XCTAssertEqual(m.caret, at(m, "![Test"), "a repeat leaves the caret where it is")
        backspace(m)
        XCTAssertEqual(m.string, start)
        XCTAssertEqual(m.caret, at(m, "![Test"))
        repeating = false
        backspace(m)
        XCTAssertEqual(m.caret, ("Prose." as NSString).length, "a fresh press moves it up")
    }

    /// Below a figure the refusal leaves the caret at the paragraph's start,
    /// never on the figure line, where a held key would eat its label.
    func test_backspaceAtTheParagraphBelowAFigure_isRefusedInPlace() throws {
        let start = "Prose.\n\n\(fig)\n\nAfter."
        let m = try mount(start)
        caret(m, at: at(m, "After."))
        backspace(m)
        backspace(m)
        XCTAssertEqual(m.string, start)
        XCTAssertEqual(m.caret, at(m, "After."))
    }

    // MARK: - What the edit tells (whole-branch review M3)

    /// The host hears the final caret, not the one inside the rewritten edit.
    func test_thePostEditCursorIsTheFinalCaret() throws {
        var told: [Int] = []
        let m = try mount("Prose.\n\n\n\(fig)", onPostEditCursor: { told.append($0) })
        caret(m, at: at(m, "![Test") - 1)
        type("T", m)
        XCTAssertEqual(m.string, "Prose.\n\nT\n\n\(fig)")
        XCTAssertEqual(told, [at(m, "T") + 1], "told once, the caret after T")
    }

    /// A rewritten keystroke is still the writer's typing: `[@` opens the
    /// citation picker though its `@` was made with a break after it.
    func test_aRewrittenKeystrokeStillOpensCompletion() throws {
        let m = try mount("See [\n\n\(fig)", pickers: true)
        m.textView.setSelectedRange(NSRange(location: 5, length: 2))
        type("@", m)
        XCTAssertEqual(m.string, "See [@\n\n\(fig)")
        XCTAssertEqual(m.caret, 6)
        XCTAssertTrue(m.coordinator.isCompletionOpen, "the picker opened on the typed @")
    }

    // MARK: - Inline commands (whole-branch review M4)

    /// Insert ▸ Citation on the empty line directly above a figure writes
    /// `[@` with the figure kept apart, the picker open after it.
    func test_insertCitationAboveAFigure_keepsItApart() throws {
        let m = try mount("Prose.\n\n\n\(fig)", pickers: true)
        caret(m, at: at(m, "![Test") - 1)
        m.coordinator.insertCitation()
        XCTAssertEqual(m.string, "Prose.\n\n[@\n\n\(fig)")
        XCTAssertEqual(m.caret, at(m, "[@") + 2)
        XCTAssertTrue(m.coordinator.isCompletionOpen)
        m.undo.undo()
        XCTAssertEqual(m.string, "Prose.\n\n\n\(fig)", "one step")
    }

    // MARK: - Smart typography (whole-branch review M8)

    /// A smart quote is made through a nested insert; the figure is kept
    /// apart inside it, and one ⌘Z takes back both.
    func test_aSmartQuoteAboveAFigure_isKeptApart_oneUndo() throws {
        let start = "Prose.\n\n\n\(fig)"
        let m = try mount(start)
        caret(m, at: at(m, "![Test") - 1)
        type("\"", m)
        XCTAssertEqual(m.string, "Prose.\n\n\u{201C}\n\n\(fig)")
        XCTAssertEqual(m.caret, at(m, "\u{201C}") + 1)
        m.undo.undo()
        XCTAssertEqual(m.string, start)
        XCTAssertFalse(m.undo.canUndo)
    }
}

/// The M4 arm of `handleFigureGridCommand` on the path (whole-branch review
/// M8): a real `FigureGridOpening` and figure marks, Return at a table
/// figure line's start opens a line above it, and typing there is kept apart.
@MainActor
final class FigureLineParagraphGridTests: FigureGridMountedTestCase {
    func test_returnAtATableFiguresStartThenTyping_withTheGridWired() async throws {
        let m = try await mount()
        XCTAssertNotNil(m.coordinator.figureGridOpening, "precondition: the grid is wired")
        let line = location(m, "![Cash](")
        XCTAssertFalse(m.coordinator.figureThumbnailMarks.isEmpty, "precondition: the figure has its mark")
        m.textView.setSelectedRange(NSRange(location: line, length: 0))
        m.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertNil(m.coordinator.figureGrid, "Return at the line's start expands nothing")
        XCTAssertEqual(location(m, "![Cash]("), line + 1, "it opened a line above")
        XCTAssertEqual(m.textView.selectedRange().location, line + 1, "the caret stays on the figure line")
        m.textView.insertText("T", replacementRange: m.textView.selectedRange())
        XCTAssertEqual(m.text.substring(with: NSRange(location: line, length: 8)), "\nT\n\n![Ca",
                       "T in a paragraph of its own above the figure")
        XCTAssertEqual(m.textView.selectedRange().location, line + 2, "the caret after T")
    }
}
