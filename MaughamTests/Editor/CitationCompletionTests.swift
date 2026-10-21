// MaughamTests/Editor/CitationCompletionTests.swift
import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// The citation picker (plan 3b Task 3, rulings R-3b-5 and R-3b-6): `[@`
/// opens it over the project's sources, `;` inside an open citation bracket
/// reopens it for the next key, and Insert ▸ Citation… writes `[@` and opens
/// it. The trigger and the filter are pure; the seam — the registered source
/// on a manuscript surface, the insertion shapes, the menu command — is
/// mounted and driven through `insertText` and `doCommand(by:)`, with no
/// synthesised keys and no waits (tripwire 33).
@MainActor
final class CitationCompletionTests: XCTestCase {
    override class func setUp() { FontWarmup.ensure() }

    // MARK: - Fixture

    private static func source(_ id: String, key: String, authors: [String], year: Int?,
                               title: String) -> ResearchItem {
        ResearchItem(id: id, title: "Item \(id)", type: .asset, kind: .link,
                     url: "https://example.com/\(id)",
                     citation: CitationInfo(key: key, authors: authors, sourceTitle: title, year: year))
    }

    /// Four sources, sorted by the index as authors: Jones, Müller, Smith, Smythe.
    static let library: [ResearchItem] = [
        source("1", key: "smith2026", authors: ["Smith, Jane"], year: 2026, title: "Markets"),
        source("2", key: "smythe2019", authors: ["Smythe, Ann"], year: 2019, title: "Rivers of the North"),
        source("3", key: "jones2020", authors: ["Jones, Bo"], year: 2020, title: "Bridges"),
        source("4", key: "muller2021", authors: ["Müller, Jörg"], year: 2021, title: "Ökonomie der Städte"),
    ]

    static func index(_ research: [ResearchItem] = library) -> ReferenceIndex {
        ReferenceIndex.build(pieces: [], research: research, words: .english).versioned(1)
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
        var titles: [String] { coordinator.completion?.items.map(\.title) ?? [] }
        var keys: [String] { coordinator.completion?.items.map(\.subtitle) ?? [] }
    }

    /// An `EditorSurface` as `EditorHost` builds a manuscript's, the window's
    /// cached index handed in through the provider. The pickers are what the
    /// surface registers on its own — the test registers nothing.
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
    private static let esc = #selector(NSResponder.cancelOperation(_:))

    /// `text` with a `|` where the caret is: the trigger there, or nil.
    private func locate(_ marked: String) -> CompletionTrigger? {
        let caret = (marked as NSString).range(of: "|").location
        let text = (marked as NSString).replacingCharacters(in: NSRange(location: caret, length: 1),
                                                            with: "")
        return CitationCompletion.locate(in: text as NSString, caret: caret)
    }

    private func replaced(_ marked: String) -> String? {
        let caret = (marked as NSString).range(of: "|").location
        let text = (marked as NSString).replacingCharacters(in: NSRange(location: caret, length: 1),
                                                            with: "") as NSString
        guard let t = CitationCompletion.locate(in: text, caret: caret) else { return nil }
        return text.substring(with: t.replaceRange)
    }

    // MARK: - The trigger (pure)

    func test_openingBracketAtSignOpensAFreshCitation() throws {
        let t = try XCTUnwrap(locate("See [@|"))
        XCTAssertEqual(t.query, "")
        XCTAssertEqual(t.replaceRange, NSRange(location: 6, length: 0), "the key goes after the @")
        XCTAssertEqual(t.context, AnyHashable(CitationCompletion.Context.fresh(closed: false)))

        let typed = try XCTUnwrap(locate("See [@sm|"))
        XCTAssertEqual(typed.query, "sm")
        XCTAssertEqual(typed.replaceRange, NSRange(location: 6, length: 2))
        XCTAssertEqual(try XCTUnwrap(locate("[-@sm|")).query, "sm", "an author-suppressed citation")
        XCTAssertEqual(try XCTUnwrap(locate("[@Mü|")).query, "Mü", "the query may hold any letter")
    }

    func test_insideAClosedBracketTheTriggerRunsThroughTheRestOfTheKeyOnly() throws {
        XCTAssertEqual(replaced("See [@smi|th2019] here"), "smith2019")
        XCTAssertEqual(replaced("See [@smi|th2019, p. 12] here"), "smith2019",
                       "the locator is not the key")
        XCTAssertEqual(try XCTUnwrap(locate("[@smi|th2019, p. 12]")).context,
                       AnyHashable(CitationCompletion.Context.fresh(closed: true)))
        XCTAssertEqual(replaced("[@|]"), "")
    }

    /// An unclosed `[@` typed before a word never claims the word: only a
    /// closed bracket holds a key to re-pick.
    func test_anUnclosedBracketNeverEatsTheWordAfterTheCaret() {
        XCTAssertEqual(replaced("See [@|Smith on rivers"), "")
        XCTAssertEqual(replaced("See [@sm|ith on rivers"), "sm")
    }

    func test_whatNeverOpensACitation() {
        for marked in ["write to me@exam|", "me@|", "@sarah|", "Hi @sa|", "[x @sa|", "\\[@|",
                       "[[@|", "[@a] ; @b|", "see; @b|", "[@a, p. 3|", "[@fig:m|", "(@x|"] {
            XCTAssertNil(locate(marked), "\(marked) opened the citation picker")
        }
    }

    func test_aSemicolonInsideAnOpenCitationBracketReopensForTheNextKey() throws {
        let fresh = try XCTUnwrap(locate("See [@smith2026;|"))
        XCTAssertEqual(fresh.query, "")
        XCTAssertEqual(fresh.replaceRange, NSRange(location: 16, length: 0), "after the ;")
        XCTAssertEqual(fresh.context, AnyHashable(CitationCompletion.Context.continuation))

        let spaced = try XCTUnwrap(locate("See [@smith2026; |"))
        XCTAssertEqual(spaced.start, 16, "the start stays put as the writer types the space")
        let at = try XCTUnwrap(locate("See [@smith2026; @jo|"))
        XCTAssertEqual(at.start, 16)
        XCTAssertEqual(at.query, "jo")
        XCTAssertEqual(replaced("[@smith2026; @jo|nes2020]"), " @jones2020")
        XCTAssertEqual(replaced("[see @smith2026, p. 4;|]"), "", "a prefix and a locator before it")
        XCTAssertNil(locate("[@smith2026; jo|"), "a continuation key starts with @")
        XCTAssertNil(locate("[@smith2026]; @jo|"), "the bracket is already closed")
    }

    // MARK: - Insertion shapes (pure)

    func test_theInsertionShapes() throws {
        let source = CitationCompletion(index: { Self.index() })
        let item = CompletionItem(title: "Jones 2020 — Bridges", subtitle: "jones2020",
                                  insertion: "jones2020")
        func insert(_ marked: String) throws -> String {
            let caret = (marked as NSString).range(of: "|").location
            let text = (marked as NSString).replacingCharacters(
                in: NSRange(location: caret, length: 1), with: "") as NSString
            let trigger = try XCTUnwrap(CitationCompletion.locate(in: text, caret: caret))
            return text.replacingCharacters(in: trigger.replaceRange,
                                            with: source.insertion(for: item, trigger: trigger))
        }
        XCTAssertEqual(try insert("See [@jo|"), "See [@jones2020]", "a fresh [@ closes its bracket")
        XCTAssertEqual(try insert("See [@jo|] here"), "See [@jones2020] here",
                       "inside a closed bracket only the key")
        XCTAssertEqual(try insert("See [@smi|th2019, p. 12] here"), "See [@jones2020, p. 12] here",
                       "the locator survives a re-pick")
        XCTAssertEqual(try insert("[@smith2026;|]"), "[@smith2026; @jones2020]",
                       "after a ; only the next key")
        XCTAssertEqual(try insert("[@smith2026; @jo|"), "[@smith2026; @jones2020",
                       "a continuation adds no bracket")
    }

    // MARK: - The filter (pure)

    private func keys(_ query: String) -> [String] {
        CitationCompletion.matching(Self.index().sources, query: query).map(\.key)
    }

    func test_anEmptyQueryListsEverySourceInTheIndexsOrder() {
        XCTAssertEqual(keys(""), ["jones2020", "muller2021", "smith2026", "smythe2019"])
    }

    func test_theFilterMatchesKeyAuthorAndTitlePrefixesIgnoringCaseAndAccents() {
        XCTAssertEqual(keys("sm"), ["smith2026", "smythe2019"], "key and author prefix")
        XCTAssertEqual(keys("SMI"), ["smith2026"], "case-insensitive")
        XCTAssertEqual(keys("jane"), ["smith2026"], "an author's given name, a word prefix")
        XCTAssertEqual(keys("riv"), ["smythe2019"], "a title word prefix")
        XCTAssertEqual(keys("north"), ["smythe2019"], "a later title word")
        XCTAssertEqual(keys("mül"), ["muller2021"], "as written")
        XCTAssertEqual(keys("mul"), ["muller2021"], "diacritic-insensitive")
        XCTAssertEqual(keys("oko"), ["muller2021"], "Ökonomie without its umlaut")
        XCTAssertEqual(keys("arkets"), [], "a prefix, never a substring")
        XCTAssertEqual(keys("zzz"), [])
    }

    /// An exact key, then a key or label ("Smith 2026") prefix, then the rest.
    func test_exactKeyAndLabelPrefixMatchesRankFirst() {
        let research = [
            Self.source("a", key: "rivera", authors: ["Abbot, Al"], year: 2001, title: "A study"),
            Self.source("b", key: "abbot2001", authors: ["Abbot, Al"], year: 2002, title: "Rivera's town"),
            Self.source("c", key: "riv", authors: ["Zed, Z"], year: 2003, title: "Last"),
        ]
        let sources = ReferenceIndex.build(pieces: [], research: research, words: .english).sources
        XCTAssertEqual(sources.map(\.key), ["rivera", "abbot2001", "riv"], "premise: index order")
        XCTAssertEqual(CitationCompletion.matching(sources, query: "riv").map(\.key),
                       ["riv", "rivera", "abbot2001"],
                       "exact key, then a key prefix, then a title word")
        XCTAssertEqual(CitationCompletion.matching(sources, query: "abbot").map(\.key),
                       ["rivera", "abbot2001"],
                       "two label prefixes keep the index's order")
    }

    func test_aRowIsAuthorYearDashTitleAndTheKey() throws {
        let smith = try XCTUnwrap(Self.index().source(forKey: "smith2026"))
        let row = CitationCompletion.row(for: smith)
        XCTAssertEqual(row.title, "Smith 2026 — Markets")
        XCTAssertEqual(row.subtitle, "smith2026")
        XCTAssertEqual(row.insertion, "smith2026")
    }

    // MARK: - Mounted: the registered picker

    func test_typingBracketAtOpensThePickerOverTheProjectsSources() throws {
        let m = try mount("See ")
        XCTAssertTrue(m.coordinator.completionSources.first is CitationCompletion,
                      "a manuscript surface registers the citation picker first")
        type("[@", m)
        XCTAssertTrue(m.coordinator.isCompletionOpen)
        XCTAssertFalse(m.list.isHidden)
        XCTAssertEqual(m.keys, ["jones2020", "muller2021", "smith2026", "smythe2019"])
        XCTAssertEqual(m.titles.first, "Jones 2020 — Bridges")

        type("sm", m)
        XCTAssertEqual(m.keys, ["smith2026", "smythe2019"], "typing filters")
        command(Self.down, m)
        command(Self.newline, m)
        XCTAssertEqual(m.string, "See [@smythe2019]")
        XCTAssertEqual(m.textView.selectedRange(), NSRange(location: 17, length: 0))
        XCTAssertFalse(m.coordinator.isCompletionOpen)

        m.undo.undo()
        XCTAssertEqual(m.string, "See [@sm", "the pick is one undo step; the typing is the writer's own")
    }

    func test_rePickingInsideAClosedBracketKeepsTheLocator() throws {
        let text = "See [@smythe2019, p. 12] here."
        let m = try mount(text, caret: 8)    // after "[@sm"
        type("i", m)
        XCTAssertTrue(m.coordinator.isCompletionOpen)
        XCTAssertEqual(m.keys, ["smith2026"])
        command(Self.newline, m)
        XCTAssertEqual(m.string, "See [@smith2026, p. 12] here.")
        XCTAssertEqual(m.textView.selectedRange(), NSRange(location: 15, length: 0),
                       "the caret after the key, before the locator")
    }

    func test_theSemicolonContinuationReopensForTheNextKey() throws {
        let m = try mount("See [@smith2026] here.", caret: 15)    // before "]"
        type(";", m)
        XCTAssertTrue(m.coordinator.isCompletionOpen, "; inside an open citation bracket reopens")
        type(" @jon", m)
        XCTAssertTrue(m.coordinator.isCompletionOpen, "the space and the @ keep it open")
        XCTAssertEqual(m.keys, ["jones2020"])
        command(Self.newline, m)
        XCTAssertEqual(m.string, "See [@smith2026; @jones2020] here.")
    }

    func test_escLeavesTheTextExactlyAsTyped() throws {
        let m = try mount("See ")
        type("[@sm", m)
        XCTAssertTrue(m.coordinator.isCompletionOpen, "precondition: the picker is open")
        command(Self.esc, m)
        XCTAssertFalse(m.coordinator.isCompletionOpen)
        XCTAssertEqual(m.string, "See [@sm")
    }

    /// Review focus 5.
    func test_noMisfires() throws {
        let m = try mount("")
        for typed in ["write to me@example.com ", "@sarah ", "`[@x` ", "[x @sa "] {
            type(typed, m)
            XCTAssertFalse(m.coordinator.isCompletionOpen, "\(typed) opened the picker")
        }
        type("[@", m)
        XCTAssertTrue(m.coordinator.isCompletionOpen, "control: the same mount does open")
    }

    /// A research note or a statement registers no picker.
    func test_aSurfaceThatIsNotAManuscriptRegistersNoPicker() throws {
        let note = try mount("Note ", answersInsertCommands: false)
        XCTAssertTrue(note.coordinator.completionSources.isEmpty)
        type("[@", note)
        XCTAssertFalse(note.coordinator.isCompletionOpen)
    }

    func test_theEmptyStateNamesWhereCitationDetailsGo() throws {
        let m = try mount("See ", index: Self.index([]))
        type("[@", m)
        XCTAssertTrue(m.coordinator.isCompletionOpen, "an empty library still answers")
        XCTAssertEqual(m.keys, [])
        XCTAssertEqual(m.list.emptyMessage,
                       "No matching sources — add citation details in the research inspector")
        XCTAssertGreaterThanOrEqual(m.list.preferredSize.width,
                                    m.list.emptyRowWidth(for: m.list.emptyMessage),
                                    "the list is wide enough to read the sentence")

        let n = try mount("See ")
        type("[@zzz", n)
        XCTAssertTrue(n.coordinator.isCompletionOpen)
        XCTAssertEqual(n.keys, [])
    }

    // MARK: - Insert ▸ Citation…

    func test_theMenuCommandWritesBracketAtAndOpensThePicker() throws {
        let m = try mount("See  here.", caret: 4)
        asOneEvent(m) { MaughamEvent.post(.maughamInsertCitation, to: .keyWindow) }
        XCTAssertEqual(m.string, "See [@ here.")
        XCTAssertTrue(m.coordinator.isCompletionOpen)
        XCTAssertEqual(m.keys.count, 4, "every source")
        command(Self.newline, m)
        XCTAssertEqual(m.string, "See [@jones2020] here.")
        m.undo.undo()
        XCTAssertEqual(m.string, "See [@ here.", "the pick is its own step")
        m.undo.undo()
        XCTAssertEqual(m.string, "See  here.", "and the [@ is one step")
    }

    func test_theMenuCommandIsRefusedInAReadOnlyPostureAndOffAManuscript() throws {
        let m = try mount("Text.")
        m.coordinator.setLockEditing(true)
        MaughamEvent.post(.maughamInsertCitation, to: .keyWindow)
        XCTAssertEqual(m.string, "Text.")
        XCTAssertFalse(m.coordinator.isCompletionOpen)
        XCTAssertFalse(m.undo.canUndo)
        m.window.reportsKey = false

        let note = try mount("Note.", answersInsertCommands: false)
        MaughamEvent.post(.maughamInsertCitation, to: .keyWindow)
        XCTAssertEqual(note.string, "Note.")
        note.window.reportsKey = false

        let control = try mount("Text.")
        MaughamEvent.post(.maughamInsertCitation, to: .keyWindow)
        XCTAssertEqual(control.string, "Text.[@", "control: a writable manuscript answers")
    }
}
