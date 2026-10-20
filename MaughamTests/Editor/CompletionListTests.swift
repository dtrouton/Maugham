// MaughamTests/Editor/CompletionListTests.swift
import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// The in-editor completion list (plan 3b Task 2): the shared infrastructure
/// the citation and cross-reference pickers stand on. Pure where it can be
/// (the placement maths, the `complete:` arm), mounted where the seam is the
/// point — the typed-character trigger, the keys routed first in `doCommandBy`
/// (before the table arms), the one-step accept, and every close path. Driven
/// through `doCommand(by:)` and `insertText`, as a key binding drives them,
/// with no synthesised keys or clicks and no waits (tripwire 33): the runloop
/// hop after a caret move is run by hand (`completionCaretSettled`).
@MainActor
final class CompletionListTests: XCTestCase {
    override class func setUp() { FontWarmup.ensure() }

    // MARK: - Fixture

    /// A source that opens on `[@` (from the `[`) or on ` @` (from the `@`),
    /// followed by letters and digits — enough shape to prove the protocol.
    final class FakeSource: CompletionSource {
        var entries: [CompletionItem]
        private(set) var itemsAsked = 0
        let emptyMessage = "No matching sources"
        let actionName = "Insert Citation"

        init(_ entries: [CompletionItem]) { self.entries = entries }
        convenience init() { self.init(FakeSource.library) }

        static let library = [
            CompletionItem(title: "Smith 2026 — Markets", subtitle: "smith2026", insertion: "[@smith2026]"),
            CompletionItem(title: "Smythe 2019 — Rivers", subtitle: "smythe2019", insertion: "[@smythe2019]"),
            CompletionItem(title: "Jones 2020 — Bridges", subtitle: "jones2020", insertion: "[@jones2020]"),
        ]

        func triggerRange(in text: NSString, caret: Int) -> NSRange? {
            var i = caret
            while i > 0, let scalar = UnicodeScalar(text.character(at: i - 1)),
                  CharacterSet.alphanumerics.contains(scalar) { i -= 1 }
            guard i >= 1, text.character(at: i - 1) == UInt16(UInt8(ascii: "@")) else { return nil }
            if i >= 2, text.character(at: i - 2) == UInt16(UInt8(ascii: "[")) {
                return NSRange(location: i - 2, length: caret - (i - 2))
            }
            if i == 1 || text.character(at: i - 2) == UInt16(UInt8(ascii: " ")) {
                return NSRange(location: i - 1, length: caret - (i - 1))
            }
            return nil
        }

        func query(inTrigger trigger: String) -> String {
            String(trigger.drop(while: { $0 != "@" }).dropFirst())
        }

        func items(matching query: String) -> [CompletionItem] {
            itemsAsked += 1
            return entries.filter { query.isEmpty || $0.subtitle.hasPrefix(query.lowercased()) }
        }
    }

    final class Box {
        var text: String
        init(_ text: String) { self.text = text }
    }

    @MainActor struct Mounted {
        let window: KeyTestWindow
        let textView: NSTextView
        let coordinator: EditorCoordinator
        let source: FakeSource
        var undo: UndoManager { textView.undoManager! }
        var string: String { textView.string }
        var list: CompletionListView { coordinator.completionList! }
        var scrollView: NSScrollView { textView.enclosingScrollView! }
    }

    private func mount(_ text: String, answersInsertCommands: Bool = true,
                       typewriterScroll: Bool = false) throws -> Mounted {
        let box = Box(text)
        let binding = Binding(get: { box.text }, set: { box.text = $0 })
        var configuration = EditorSurfaceConfiguration(
            presentation: .init(theme: .light, typography: .defaults, mode: ProseMode(),
                                typewriterScroll: typewriterScroll, sentenceFocus: false,
                                paragraphFocus: false, showElementGutter: false),
            control: EditorControl())
        configuration.answersInsertCommands = answersInsertCommands
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
        let source = FakeSource()
        coordinator.completionSources = [source]
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        return Mounted(window: window, textView: textView, coordinator: coordinator, source: source)
    }

    private static func textView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let tv = view as? NSTextView { return tv }
        for sub in view.subviews { if let tv = textView(in: sub) { return tv } }
        return nil
    }

    /// One user event in its own undo group (the test host runs no event loop;
    /// see `InsertCommandTests`).
    private func asOneEvent(_ m: Mounted, _ body: () -> Void) {
        m.undo.beginUndoGrouping()
        body()
        m.undo.endUndoGrouping()
    }

    /// Types `s` a character at a time, each its own keystroke.
    private func type(_ s: String, _ m: Mounted) {
        for character in s {
            asOneEvent(m) {
                m.textView.insertText(String(character), replacementRange: m.textView.selectedRange())
            }
        }
    }

    private func command(_ selector: Selector, _ m: Mounted) {
        asOneEvent(m) { m.textView.doCommand(by: selector) }
    }

    private func caret(_ m: Mounted, at location: Int) {
        m.textView.setSelectedRange(NSRange(location: location, length: 0))
    }

    private static let down = #selector(NSResponder.moveDown(_:))
    private static let up = #selector(NSResponder.moveUp(_:))
    private static let newline = #selector(NSResponder.insertNewline(_:))
    private static let tab = #selector(NSResponder.insertTab(_:))
    private static let esc = #selector(NSResponder.cancelOperation(_:))
    private static let complete = #selector(NSTextView.complete(_:))

    private func assertOpen(_ m: Mounted, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(m.coordinator.isCompletionOpen, "the list should be open", file: file, line: line)
        XCTAssertFalse(m.list.isHidden, "an open list shows", file: file, line: line)
    }

    private func assertClosed(_ m: Mounted, _ why: String = "",
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(m.coordinator.isCompletionOpen, "the list should be closed. \(why)",
                       file: file, line: line)
        XCTAssertTrue(m.list.isHidden, "a closed list hides. \(why)", file: file, line: line)
    }

    // MARK: - Placement (pure)

    func test_theListGoesUnderTheCaretInAYUpParent() {
        let caret = NSRect(x: 100, y: 300, width: 1, height: 18)
        let frame = CompletionListLayout.frame(size: NSSize(width: 400, height: 100), caret: caret,
                                               in: NSRect(x: 0, y: 0, width: 800, height: 600),
                                               flipped: false)
        XCTAssertEqual(frame, NSRect(x: 100, y: 300 - 4 - 100, width: 400, height: 100))
    }

    func test_theListGoesUnderTheCaretInAFlippedParent() {
        let caret = NSRect(x: 100, y: 300, width: 1, height: 18)
        let frame = CompletionListLayout.frame(size: NSSize(width: 400, height: 100), caret: caret,
                                               in: NSRect(x: 0, y: 0, width: 800, height: 600),
                                               flipped: true)
        XCTAssertEqual(frame, NSRect(x: 100, y: 318 + 4, width: 400, height: 100))
    }

    func test_nearTheBottomEdgeTheListFlipsAboveTheCaret() {
        let bounds = NSRect(x: 0, y: 0, width: 800, height: 600)
        let yUp = CompletionListLayout.frame(size: NSSize(width: 400, height: 100),
                                             caret: NSRect(x: 100, y: 40, width: 1, height: 18),
                                             in: bounds, flipped: false)
        XCTAssertEqual(yUp.minY, 58 + 4, "y-up: no room below, so above the caret's top")
        let flipped = CompletionListLayout.frame(size: NSSize(width: 400, height: 100),
                                                 caret: NSRect(x: 100, y: 540, width: 1, height: 18),
                                                 in: bounds, flipped: true)
        XCTAssertEqual(flipped.maxY, 540 - 4, "flipped: no room below, so above the caret's top")
    }

    func test_theListStaysInsideANarrowParent() {
        let frame = CompletionListLayout.frame(size: NSSize(width: 400, height: 100),
                                               caret: NSRect(x: 280, y: 300, width: 1, height: 18),
                                               in: NSRect(x: 0, y: 0, width: 320, height: 600),
                                               flipped: false)
        XCTAssertEqual(frame.width, 320 - 16, "the width shrinks to the parent less its margins")
        XCTAssertEqual(frame.minX, 8, "and it slides left to fit")
    }

    func test_theListMountsUnderTheTriggerInsideTheScrollView() throws {
        let m = try mount("Some prose ")
        type("[@", m)
        assertOpen(m)
        let parent = try XCTUnwrap(m.list.superview)
        XCTAssertTrue(parent === m.scrollView, "the list is a scroll-view subview, as the toolbar is")
        XCTAssertTrue(parent.subviews.last === m.list, "above every other scroll-view subview")
        XCTAssertTrue(parent.bounds.contains(m.list.frame))
        let layoutManager = try XCTUnwrap(m.textView.layoutManager)
        let glyph = layoutManager.glyphIndexForCharacter(at: 11)
        var line = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        line.origin.x += m.textView.textContainerOrigin.x
        line.origin.y += m.textView.textContainerOrigin.y
        let lineInParent = m.textView.convert(line, to: parent)
        XCTAssertFalse(m.list.frame.intersects(lineInParent), "the list never covers the trigger's line")
        if parent.isFlipped {
            XCTAssertGreaterThan(m.list.frame.minY, lineInParent.midY, "below the line")
        } else {
            XCTAssertLessThan(m.list.frame.maxY, lineInParent.midY, "below the line")
        }
    }

    // MARK: - The trigger

    func test_typingTheTriggerOpensTheListAndTypingFilters() throws {
        let m = try mount("See ")
        type("[", m)
        assertClosed(m, "a lone [ opens nothing")
        type("@", m)
        assertOpen(m)
        XCTAssertEqual(m.coordinator.completion?.items.count, 3)
        type("sm", m)
        XCTAssertEqual(m.coordinator.completion?.query, "sm")
        XCTAssertEqual(m.coordinator.completion?.items.map(\.subtitle), ["smith2026", "smythe2019"])
        XCTAssertEqual(m.coordinator.completion?.triggerRange, NSRange(location: 4, length: 4))
        asOneEvent(m) { m.textView.deleteBackward(nil) }
        assertOpen(m)
        XCTAssertEqual(m.coordinator.completion?.query, "s", "a deletion filters too")
    }

    func test_aTriggerThatEndsClosesAndAnotherOpensAtItsOwnStart() throws {
        let m = try mount("")
        type("[@ab", m)
        assertOpen(m)
        type(" ", m)
        assertClosed(m, "a space ends the query")
        type("@", m)
        assertOpen(m)
        XCTAssertEqual(m.coordinator.completion?.triggerRange.location, 5)
    }

    func test_theFirstRegisteredSourceThatAnswersDecides() throws {
        let m = try mount("")
        let second = FakeSource([CompletionItem(title: "x", subtitle: "x", insertion: "x")])
        m.coordinator.completionSources = [m.source, second]
        type("[@", m)
        assertOpen(m)
        XCTAssertEqual(m.coordinator.completion?.items.count, 3, "the first source's rows")
        XCTAssertEqual(second.itemsAsked, 0)
    }

    func test_noTriggerInsideACodeSpan() throws {
        let m = try mount("Use `the code ` here")
        caret(m, at: 14)           // inside the backticks, after "code "
        type("[@", m)
        assertClosed(m, "`[@` typed inside backticks is code, not a citation")
    }

    func test_noTriggerOnASurfaceThatIsNotAManuscript() throws {
        let m = try mount("A research note ", answersInsertCommands: false)
        type("[@", m)
        assertClosed(m, "a research note or statement never opens the list")
        XCTAssertFalse(m.coordinator.openCompletion(source: m.source,
                                                    triggerRange: NSRange(location: 16, length: 2)),
                       "nor may a command open it there")
    }

    func test_noTriggerWhileAnInputMethodComposes() throws {
        let m = try mount("")
        type("[", m)
        asOneEvent(m) {
            m.textView.setMarkedText("@", selectedRange: NSRange(location: 1, length: 0),
                                     replacementRange: m.textView.selectedRange())
        }
        XCTAssertTrue(m.textView.hasMarkedText())
        assertClosed(m, "a composition never opens the list")
    }

    func test_aCompositionClosesAnOpenListAndItsKeysGoToTheInputMethod() throws {
        let m = try mount("")
        type("[@", m)
        assertOpen(m)
        asOneEvent(m) {
            m.textView.setMarkedText("s", selectedRange: NSRange(location: 1, length: 0),
                                     replacementRange: m.textView.selectedRange())
        }
        assertClosed(m, "a composition is never interrupted by the list")
    }

    func test_aCommandsEditNeverOpensTheList() throws {
        let m = try mount("[")
        m.coordinator.applyCommandEdit(replacing: NSRange(location: 1, length: 0), with: "@",
                                       selecting: NSRange(location: 2, length: 0), actionName: "Test")
        assertClosed(m, "Route A's one-character edit is not typing")
    }

    func test_undoAndRedoNeverOpenTheList() throws {
        let m = try mount("")
        type("[@a", m)
        assertOpen(m)
        m.textView.doCommand(by: Self.esc)      // no undo group: Esc makes no step
        assertClosed(m)
        m.undo.undo()
        XCTAssertEqual(m.string, "[@")
        assertClosed(m, "an undo is not typing")
        m.undo.redo()
        XCTAssertEqual(m.string, "[@a")
        assertClosed(m, "a redo is not typing")
    }

    // MARK: - The keys

    func test_downAndUpMoveAndReturnAcceptsTheChosenRow() throws {
        let m = try mount("As shown ")
        type("[@sm", m)
        command(Self.down, m)
        XCTAssertEqual(m.coordinator.completion?.selectedIndex, 1)
        command(Self.down, m)
        XCTAssertEqual(m.coordinator.completion?.selectedIndex, 1, "the last row holds")
        command(Self.up, m)
        command(Self.up, m)
        XCTAssertEqual(m.coordinator.completion?.selectedIndex, 0, "the first row holds")
        command(Self.down, m)
        command(Self.newline, m)
        XCTAssertEqual(m.string, "As shown [@smythe2019]")
        XCTAssertEqual(m.textView.selectedRange(), NSRange(location: 22, length: 0))
        assertClosed(m, "an accept closes the list")
    }

    func test_tabAccepts() throws {
        let m = try mount("")
        type("[@jo", m)
        command(Self.tab, m)
        XCTAssertEqual(m.string, "[@jones2020]")
    }

    func test_escClosesAndLeavesTheTypedTextExactlyAsTyped() throws {
        let m = try mount("Text ")
        type("[@smi", m)
        assertOpen(m)
        command(Self.esc, m)
        assertClosed(m)
        XCTAssertEqual(m.string, "Text [@smi")
        command(Self.newline, m)
        XCTAssertEqual(m.string, "Text [@smi\n", "with the list closed, Return is Return again")
    }

    func test_withNothingToAcceptReturnClosesAndIsReturn() throws {
        let m = try mount("")
        type("[@zz", m)
        assertOpen(m)
        XCTAssertEqual(m.coordinator.completion?.items, [])
        XCTAssertEqual(m.list.visibleRows.map(\.title), ["No matching sources"])
        command(Self.newline, m)
        assertClosed(m)
        XCTAssertEqual(m.string, "[@zz\n")
    }

    func test_completeIsSwallowedInProseOpenOrClosed() throws {
        let m = try mount("")
        XCTAssertTrue(m.coordinator.textView(m.textView, doCommandBy: Self.complete),
                      "closed: AppKit's completion window must never open")
        type("[@", m)
        XCTAssertTrue(m.coordinator.textView(m.textView, doCommandBy: Self.complete))
        assertOpen(m)
    }

    func test_completeIsLeftAloneInAScreenplay() {
        let coordinator = EditorCoordinator(text: .constant(""), mode: ScreenplayMode(),
                                            theme: .light, typography: .defaults,
                                            typewriterScroll: false, sentenceFocus: false,
                                            paragraphFocus: false)
        XCTAssertFalse(coordinator.textView(NSTextView(), doCommandBy: Self.complete))
    }

    /// A `complete:` that reaches AppKit by another road (a direct call; F5
    /// through a menu) asks the delegate for words — measured: 20 for this
    /// text — and gets none in prose, so its window has nothing to show.
    func test_appKitsOwnCompletionIsOfferedNothingInProse() throws {
        let m = try mount("Some words here")
        XCTAssertEqual(m.coordinator.textView(m.textView, completions: ["here", "hereby"],
                                              forPartialWordRange: NSRange(location: 11, length: 4),
                                              indexOfSelectedItem: nil), [])
        let screenplay = EditorCoordinator(text: .constant(""), mode: ScreenplayMode(),
                                           theme: .light, typography: .defaults,
                                           typewriterScroll: false, sentenceFocus: false,
                                           paragraphFocus: false)
        XCTAssertEqual(screenplay.textView(NSTextView(), completions: ["INT."],
                                           forPartialWordRange: NSRange(location: 0, length: 0),
                                           indexOfSelectedItem: nil), ["INT."],
                       "a screenplay keeps AppKit's behaviour")
    }

    func test_withTheListClosedTheKeysFallThrough() throws {
        let m = try mount("One\nTwo")
        XCTAssertFalse(m.coordinator.handleCompletionCommand(Self.down, in: m.textView))
        XCTAssertFalse(m.coordinator.handleCompletionCommand(Self.newline, in: m.textView))
        XCTAssertFalse(m.coordinator.handleCompletionCommand(Self.tab, in: m.textView))
        XCTAssertFalse(m.coordinator.handleCompletionCommand(Self.esc, in: m.textView))
    }

    static let table = """
        | A   | B   |
        | --- | --- |
        | c   | d   |
        """

    func test_inATableCellTabAndReturnAcceptWhileTheListIsOpen() throws {
        let m = try mount(Self.table)
        caret(m, at: (m.string as NSString).range(of: "c").location + 1)
        type(" [@sm", m)
        assertOpen(m)
        command(Self.tab, m)
        XCTAssertTrue(m.string.contains("c [@smith2026]"), "Tab accepted, not moved cells: \(m.string)")
        assertClosed(m)
        type(" [@jo", m)
        command(Self.newline, m)
        XCTAssertTrue(m.string.contains("[@smith2026] [@jones2020]"),
                      "Return accepted, not added a row: \(m.string)")
        XCTAssertEqual(m.string.components(separatedBy: "\n").count, 3, "no row was added")
    }

    func test_inATableCellWithTheListClosedTabMovesCellsAsBefore() throws {
        let m = try mount(Self.table)
        caret(m, at: (m.string as NSString).range(of: "c").location + 1)
        command(Self.tab, m)
        XCTAssertEqual((m.string as NSString).substring(with: m.textView.selectedRange()), "d",
                       "the table's own Tab still moves to the next cell")
    }

    // MARK: - Accept is one undo step

    func test_acceptIsOneUndoStepAndTheTypingStaysItsOwn() throws {
        let m = try mount("")
        type("[@smi", m)
        command(Self.newline, m)
        XCTAssertEqual(m.string, "[@smith2026]")
        m.undo.undo()
        XCTAssertEqual(m.string, "[@smi", "one ⌘Z takes back the accept, and only it")
        m.undo.undo()
        XCTAssertEqual(m.string, "[@sm", "the typing before it is still its own steps")
        assertClosed(m, "an undo reopens nothing")
    }

    func test_aReadOnlyPostureRefusesTheAcceptAndTheOpen() throws {
        let m = try mount("")
        type("[@", m)
        assertOpen(m)
        m.coordinator.setLockEditing(true)
        assertClosed(m, "a posture that refuses text closes the list")
        XCTAssertFalse(m.coordinator.openCompletion(source: m.source,
                                                    triggerRange: NSRange(location: 0, length: 2)))
    }

    // MARK: - Closing

    func test_theCaretLeavingTheTriggerCloses() throws {
        let m = try mount("Text ")
        type("[@smi", m)
        caret(m, at: 9)
        assertOpen(m)
        XCTAssertEqual(m.coordinator.completion?.query, "sm", "a caret inside the query follows it")
        caret(m, at: 2)
        assertClosed(m, "the caret left the trigger")
    }

    func test_applyExternalTextCloses() throws {
        let m = try mount("")
        type("[@", m)
        assertOpen(m)
        m.coordinator.applyExternalText("Another text")
        assertClosed(m)
    }

    func test_reviewAndTranslationReviewClose() throws {
        let m = try mount("")
        type("[@", m)
        assertOpen(m)
        m.coordinator.setReviewMode(true)
        assertClosed(m, "review mode")
        m.coordinator.setReviewMode(false)
        type("x [@", m)
        assertOpen(m)
        m.coordinator.setTranslationReview(true)
        assertClosed(m, "translation review")
    }

    func test_escRoutedThroughTheTextViewCloses() throws {
        let m = try mount("")
        type("[@", m)
        assertOpen(m)
        command(Self.esc, m)
        assertClosed(m)
    }

    func test_theWritersScrollCloses() throws {
        let m = try mount(String(repeating: "A line of prose.\n", count: 200))
        caret(m, at: 0)
        type("[@", m)
        assertOpen(m)
        m.coordinator.completionCaretSettled()
        m.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 300))
        assertClosed(m, "a scroll the writer made")
    }

    func test_aScrollThatFollowsTheCaretMovesTheList() throws {
        let m = try mount(String(repeating: "A line of prose.\n", count: 200))
        caret(m, at: 0)
        type("[@", m)
        let before = m.list.frame
        XCTAssertTrue(m.coordinator.completionCaretIsMoving, "the keystroke's turn is still open")
        m.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 10))
        assertOpen(m)
        XCTAssertNotEqual(m.list.frame.origin.y, before.origin.y, "the list moved with the text")
    }

    func test_aResizeCloses() throws {
        let m = try mount("")
        type("[@", m)
        assertOpen(m)
        let size = m.scrollView.frame.size
        m.scrollView.setFrameSize(NSSize(width: size.width - 40, height: size.height))
        assertClosed(m)
    }

    func test_theWindowResigningKeyCloses() throws {
        let m = try mount("")
        type("[@", m)
        assertOpen(m)
        // AppKit's own window notification, as the window posts it when it resigns key.
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: m.window) // adr-0021-ok: AppKit's resign-key notification, not a maugham.* event
        assertClosed(m)
    }

    func test_theTextViewLosingTheFocusCloses() throws {
        let m = try mount("")
        type("[@", m)
        assertOpen(m)
        m.window.makeFirstResponder(nil)
        assertClosed(m)
    }

    func test_detachClosesAndStopsListening() throws {
        let m = try mount("")
        type("[@", m)
        assertOpen(m)
        let list = m.list
        m.coordinator.detach()
        XCTAssertFalse(m.coordinator.isCompletionOpen)
        XCTAssertTrue(list.isHidden)
        XCTAssertTrue(m.coordinator.completionObservers.isEmpty)
    }

    // MARK: - Accessibility

    func test_theListIsAVoiceOverListOfTitledRows() throws {
        let m = try mount("")
        type("[@", m)
        XCTAssertEqual(m.list.accessibilityRole(), .list)
        let rows = try XCTUnwrap(m.list.accessibilityChildren() as? [CompletionRowView])
        XCTAssertEqual(rows.map { $0.accessibilityLabel() }, FakeSource.library.map(\.title))
        XCTAssertEqual(rows.first?.accessibilityRole(), .staticText)
        command(Self.down, m)
        let selected = try XCTUnwrap(m.list.accessibilitySelectedChildren() as? [CompletionRowView])
        XCTAssertEqual(selected.map(\.title), ["Smythe 2019 — Rivers"])
    }

    func test_atMostEightRowsShowAndTheSelectionScrollsIntoView() throws {
        let m = try mount("")
        m.source.entries = (0..<20).map {
            CompletionItem(title: "Source \($0)", subtitle: "k\($0)", insertion: "[@k\($0)]")
        }
        type("[@", m)
        XCTAssertEqual(m.list.visibleRows.count, CompletionListView.maxVisibleRows)
        XCTAssertEqual(m.list.frame.height,
                       CGFloat(CompletionListView.maxVisibleRows) * CompletionListView.rowHeight
                           + 2 * CompletionListView.padding)
        for _ in 0..<10 { command(Self.down, m) }
        XCTAssertEqual(m.list.topRow, 3, "row 10 is the last in view")
        XCTAssertTrue(m.list.visibleRows.contains { $0.title == "Source 10" && $0.isSelected })
    }
}
