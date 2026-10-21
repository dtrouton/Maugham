// MaughamTests/Editor/CrossReferenceCompletionTests.swift
import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// The cross-reference picker (plan 3b Task 4, rulings R-3b-5 and R-3b-6): `@`
/// and a letter at a word start opens it over the project's labelled figures,
/// tables and sections, in publishing order; Insert ▸ Cross-Reference… writes
/// `@` and opens it with every target. The trigger and the filter are pure;
/// the seam is mounted and driven through `insertText` and `doCommand(by:)`,
/// with no synthesised keys and no waits (tripwire 33).
@MainActor
final class CrossReferenceCompletionTests: XCTestCase {
    override class func setUp() { FontWarmup.ensure() }

    // MARK: - Fixture

    static let chapterOne = """
        # Introduction {#sec:intro}

        ![Revenue by year](r.png){#fig:revenue}

        | a | b |
        |---|---|
        | 1 | 2 |
        Table: Final costs {#tbl:costs}
        """
    static let chapterTwo = """
        ## Method {#sec:method}

        ![Site map](m.png){#fig:map}
        """

    /// Two chapters, in publishing order: sec:intro, fig:revenue (Figure 1),
    /// tbl:costs (Table 1), then sec:method and fig:map (Figure 2) from the
    /// second document.
    static func index(sources: [ResearchItem] = []) -> ReferenceIndex {
        ReferenceIndex.build(pieces: [
            ("ch-one", ReferenceIndex.PieceSummary(text: chapterOne)),
            ("ch-two", ReferenceIndex.PieceSummary(text: chapterTwo)),
        ], research: sources, words: .english).versioned(1)
    }

    final class Box {
        var text: String
        init(_ text: String) { self.text = text }
    }

    @MainActor struct Mounted {
        let window: KeyTestWindow
        let textView: NSTextView
        let coordinator: EditorCoordinator
        var undo: UndoManager { textView.undoManager! }
        var string: String { textView.string }
        var list: CompletionListView { coordinator.completionList! }
        var isCrossReference: Bool { coordinator.completion?.source is CrossReferenceCompletion }
        var labels: [String] { coordinator.completion?.items.map(\.subtitle) ?? [] }
        var titles: [String] { coordinator.completion?.items.map(\.title) ?? [] }
    }

    private func mount(_ text: String, caret: Int? = nil, answersInsertCommands: Bool = true,
                       index given: ReferenceIndex? = nil) throws -> Mounted {
        let index = given ?? Self.index()
        let box = Box(text)
        let binding = Binding(get: { box.text }, set: { box.text = $0 })
        var configuration = EditorSurfaceConfiguration(
            presentation: .init(theme: .light, typography: .defaults, mode: ProseMode(),
                                typewriterScroll: false, sentenceFocus: false,
                                paragraphFocus: false, showElementGutter: false),
            control: EditorControl())
        configuration.answersInsertCommands = answersInsertCommands
        configuration.paragraphProviders.referenceIndex = { index }
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
        textView.setSelectedRange(NSRange(location: caret ?? (textView.string as NSString).length,
                                          length: 0))
        return Mounted(window: window, textView: textView, coordinator: coordinator)
    }

    private static func textView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let tv = view as? NSTextView { return tv }
        for sub in view.subviews { if let tv = textView(in: sub) { return tv } }
        return nil
    }

    private func asOneEvent(_ m: Mounted, _ body: () -> Void) {
        m.undo.beginUndoGrouping()
        body()
        m.undo.endUndoGrouping()
    }

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

    private static let down = #selector(NSResponder.moveDown(_:))
    private static let newline = #selector(NSResponder.insertNewline(_:))

    private func locate(_ marked: String) -> CompletionTrigger? {
        let caret = (marked as NSString).range(of: "|").location
        let text = (marked as NSString).replacingCharacters(in: NSRange(location: caret, length: 1),
                                                            with: "")
        return CrossReferenceCompletion.locate(in: text as NSString, caret: caret)
    }

    private func replaced(_ marked: String) -> String? {
        let caret = (marked as NSString).range(of: "|").location
        let text = (marked as NSString).replacingCharacters(in: NSRange(location: caret, length: 1),
                                                            with: "") as NSString
        guard let t = CrossReferenceCompletion.locate(in: text, caret: caret) else { return nil }
        return text.substring(with: t.replaceRange)
    }

    private func labels(_ query: String) -> [String] {
        CrossReferenceCompletion.matching(Self.index().targets, query: query).map(\.label.reference)
    }

    // MARK: - The trigger (pure)

    func test_atAndALetterAtAWordStartOpens() throws {
        for marked in ["@fi|", "See @fi|", "(@fi|", "[@fi|", "[@a; @fi|", "x\n@fi|", "See\t@fi|"] {
            let t = try XCTUnwrap(locate(marked), "\(marked) did not open")
            XCTAssertEqual(t.query, "fi")
        }
        let label = try XCTUnwrap(locate("See @fig:re|"))
        XCTAssertEqual(label.query, "fig:re", "the query runs through the colon")
        XCTAssertEqual(replaced("See @fig:re|"), "@fig:re", "an accept replaces the @ and the query")
        XCTAssertEqual(try XCTUnwrap(locate("See @|")).query, "", "the menu's bare @")
    }

    /// R-3b-5: never after an email-like character.
    func test_neverAfterAnEmailLikeCharacter() {
        for marked in ["me@fi|", "write to jo.smith@fi|", "a-@fi|", "a_@fi|", "a+@fi|", "a%@fi|",
                       "7@fi|", "é@fi|", "x.@fi|", "@1|", "@-x|", "@:fig|"] {
            XCTAssertNil(locate(marked), "\(marked) opened the cross-reference picker")
        }
    }

    /// Re-picking inside a label replaces the whole label; a word after an
    /// `@` that is not a label is never claimed.
    func test_theTriggerRunsThroughTheRestOfALabelOnly() {
        XCTAssertEqual(replaced("See @fig:ma|p here"), "@fig:map")
        XCTAssertEqual(replaced("See @fig:ma|p. Then"), "@fig:map", "the full stop is not the label")
        XCTAssertEqual(replaced("See @m|ethod here"), "@m", "no colon: not a label to re-pick")
    }

    // MARK: - The filter (pure)

    func test_anEmptyQueryListsEveryTargetInPublishingOrderAcrossDocuments() {
        XCTAssertEqual(labels(""), ["sec:intro", "fig:revenue", "tbl:costs", "sec:method", "fig:map"])
        XCTAssertEqual(Self.index().targets.map(\.docId),
                       ["ch-one", "ch-one", "ch-one", "ch-two", "ch-two"], "premise: two documents")
    }

    func test_theQueryMatchesTheLabelThenTheCaptionAndTheText() {
        XCTAssertEqual(labels("fi"), ["fig:revenue", "fig:map", "tbl:costs"],
                       "fig: labels first, in publishing order, then a caption word (Final costs)")
        XCTAssertEqual(labels("fig:m"), ["fig:map"])
        XCTAssertEqual(labels("m"), ["sec:method", "fig:map"], "a label's name")
        XCTAssertEqual(labels("site"), ["fig:map"], "a caption word")
        XCTAssertEqual(labels("INTRO"), ["sec:intro"], "case-insensitive")
        XCTAssertEqual(labels("table"), ["tbl:costs"], "the element's word (\"Table 1\")")
        XCTAssertEqual(labels("year"), ["fig:revenue"])
        XCTAssertEqual(labels("sarah"), [])
        XCTAssertEqual(labels("evenue"), [], "a prefix, never a substring")
    }

    func test_rowsShowTheNumberAndCaptionOrTheSectionTitleAndTheLabel() {
        let rows = Self.index().targets.map(CrossReferenceCompletion.row(for:))
        XCTAssertEqual(rows.map(\.title), ["Introduction", "Figure 1 — Revenue by year",
                                           "Table 1 — Final costs", "Method", "Figure 2 — Site map"])
        XCTAssertEqual(rows.map(\.subtitle),
                       ["sec:intro", "fig:revenue", "tbl:costs", "sec:method", "fig:map"])
        XCTAssertEqual(rows[1].insertion, "@fig:revenue")
    }

    func test_aTableWithNoCaptionShowsItsNumberAlone() throws {
        let index = ReferenceIndex.build(pieces: [
            ("ch", ReferenceIndex.PieceSummary(text: "| a |\n|---|\n| 1 |\nTable: {#tbl:bare}")),
        ], research: [], words: .english)
        let target = try XCTUnwrap(index.targets.first, "premise: a label with no caption")
        XCTAssertEqual(CrossReferenceCompletion.row(for: target).title, "Table 1")
    }

    // MARK: - Mounted

    func test_typingAtAndALetterOpensThePickerAndAcceptWritesTheLabel() throws {
        let m = try mount("As ")
        XCTAssertTrue(m.coordinator.completionSources.last is CrossReferenceCompletion,
                      "a manuscript surface registers the cross-reference picker after the citation picker")
        type("@", m)
        XCTAssertFalse(m.coordinator.isCompletionOpen, "a bare @ typed opens nothing")
        type("f", m)
        XCTAssertTrue(m.isCrossReference)
        XCTAssertEqual(m.labels, ["fig:revenue", "fig:map", "tbl:costs"])
        XCTAssertEqual(m.titles.first, "Figure 1 — Revenue by year")
        command(Self.down, m)
        command(Self.newline, m)
        XCTAssertEqual(m.string, "As @fig:map", "a label from the other document")
        XCTAssertEqual(m.textView.selectedRange(), NSRange(location: 11, length: 0))
        m.undo.undo()
        XCTAssertEqual(m.string, "As @f", "the pick is one undo step")
    }

    /// Review focus 5: an address, code and a digit never open it, at any
    /// keystroke.
    func test_noMisfires() throws {
        let m = try mount("")
        for character in "write to me@fig.com `@fi` @1fi " {
            type(String(character), m)
            XCTAssertFalse(m.coordinator.isCompletionOpen, "\(m.string) opened a picker")
        }
        type("@fi", m)
        XCTAssertTrue(m.isCrossReference, "control: the same mount does open")
    }

    /// `[@fig:` is a cross-reference in brackets: the citation picker, asked
    /// first, lets go at the colon and the cross-reference picker takes it.
    func test_aBracketedLabelHandsOverToTheCrossReferencePickerAtTheColon() throws {
        let m = try mount("See ")
        type("[@fig", m)
        XCTAssertTrue(m.coordinator.completion?.source is CitationCompletion, "premise: [@ is a citation")
        type(":", m)
        XCTAssertTrue(m.isCrossReference)
        XCTAssertEqual(m.labels, ["fig:revenue", "fig:map"])
        command(Self.newline, m)
        XCTAssertEqual(m.string, "See [@fig:revenue")
    }

    /// A handle: `@s` opens the list while a `sec:` label starts with s (R-3b-5:
    /// `@` and a letter), and the first letter nothing matches closes it, so
    /// `@sarah` ends as typed with no list. With no target starting s it
    /// never opens at all.
    func test_aHandleClosesAtTheFirstLetterNothingMatches() throws {
        let m = try mount("Ask ")
        type("@s", m)
        XCTAssertTrue(m.isCrossReference, "premise: sec: labels start with s")
        type("a", m)
        XCTAssertFalse(m.coordinator.isCompletionOpen, "nothing matches \"sa\"")
        type("rah ", m)
        XCTAssertFalse(m.coordinator.isCompletionOpen)
        XCTAssertEqual(m.string, "Ask @sarah ", "the text exactly as typed")

        let figures = try mount("Ask ", index: ReferenceIndex.build(pieces: [
            ("ch", ReferenceIndex.PieceSummary(text: "![Map](m.png){#fig:map}")),
        ], research: [], words: .english))
        for character in "@sarah" {
            type(String(character), figures)
            XCTAssertFalse(figures.coordinator.isCompletionOpen, "\(figures.string) opened the picker")
        }
    }

    func test_aSurfaceThatIsNotAManuscriptNeverOpensIt() throws {
        let note = try mount("Note ", answersInsertCommands: false)
        type("@fi", note)
        XCTAssertFalse(note.coordinator.isCompletionOpen)
    }

    // MARK: - Insert ▸ Cross-Reference…

    func test_theMenuCommandWritesAtAndListsEveryTarget() throws {
        let m = try mount("As  shows.", caret: 3)
        asOneEvent(m) { MaughamEvent.post(.maughamInsertCrossReference, to: .keyWindow) }
        XCTAssertEqual(m.string, "As @ shows.")
        XCTAssertTrue(m.isCrossReference)
        XCTAssertEqual(m.labels, ["sec:intro", "fig:revenue", "tbl:costs", "sec:method", "fig:map"],
                       "every target, in publishing order")
        m.coordinator.completionSelectionDidChange(in: m.textView)    // a caret re-assert
        XCTAssertTrue(m.coordinator.isCompletionOpen, "a caret that stays on the bare @ keeps it open")
        type("m", m)
        XCTAssertEqual(m.labels, ["sec:method", "fig:map"])
        command(Self.newline, m)
        XCTAssertEqual(m.string, "As @sec:method shows.")
    }

    func test_theMenuCommandWithNoTargetsShowsTheEmptyState() throws {
        let m = try mount("As ", index: ReferenceIndex.empty)
        MaughamEvent.post(.maughamInsertCrossReference, to: .keyWindow)
        XCTAssertTrue(m.isCrossReference)
        XCTAssertEqual(m.labels, [])
        XCTAssertEqual(m.list.emptyMessage, "No matching figures, tables or sections")
    }

    func test_theMenuCommandIsRefusedInAReadOnlyPostureAndOffAManuscript() throws {
        let m = try mount("Text.")
        m.coordinator.setReviewMode(true)
        MaughamEvent.post(.maughamInsertCrossReference, to: .keyWindow)
        XCTAssertEqual(m.string, "Text.")
        XCTAssertFalse(m.coordinator.isCompletionOpen)
        m.window.reportsKey = false

        let note = try mount("Note.", answersInsertCommands: false)
        MaughamEvent.post(.maughamInsertCrossReference, to: .keyWindow)
        XCTAssertEqual(note.string, "Note.")
        note.window.reportsKey = false

        let control = try mount("Text. ")
        MaughamEvent.post(.maughamInsertCrossReference, to: .keyWindow)
        XCTAssertEqual(control.string, "Text. @", "control: a writable manuscript answers")
    }
}
