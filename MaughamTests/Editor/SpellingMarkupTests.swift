import XCTest
import AppKit
import MaughamCore
@testable import Maugham

/// **Spelling skips markup** (Denver's smoke: a figure line's path and its
/// `{#tbl:…}` label drew red dots): `EditorCoordinator`'s
/// `textView(_:shouldSetSpellingState:range:)` refuses a mark on markup the
/// tokenizer recognised, and lets a caption's, a link's and the prose's
/// misspellings through. No synthesised event (tripwire 33): the delegate is
/// asked directly, and the real checker is run synchronously.
@MainActor
final class SpellingMarkupTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()   // styles through ProseMode
    }

    private static let text = """
        Our resuls held.

        ![Tabel of results](figures/tabel_4xq.csv){#tbl:tabel_4xq}

        As [@smithqq2020] showed, see [the sitee](https://exmple.com/qqzz), `codez`, @tbl:tabel_4xq and a note[^qqnote].

        ## Methods {#sec:methqq}

        ```
        fenzed wrds
        ```

        Closing wordz.
        """

    private func mount(_ text: String = text, mode: any WritingMode = ProseMode()) -> EditorIntegrationHarness {
        EditorIntegrationHarness(mode: mode, initialText: text, cursorLocation: 0)
    }

    /// The `occurrence`th range of `needle` in `text` (0-based).
    private func range(of needle: String, _ occurrence: Int = 0, in text: String = text) -> NSRange {
        let ns = text as NSString
        var search = NSRange(location: 0, length: ns.length)
        var found = NSRange(location: NSNotFound, length: 0)
        for _ in 0...occurrence {
            found = ns.range(of: needle, range: search)
            precondition(found.location != NSNotFound, "\(needle) #\(occurrence) not in the text")
            search = NSRange(location: NSMaxRange(found), length: ns.length - NSMaxRange(found))
        }
        return found
    }

    private func asks(_ harness: EditorIntegrationHarness, _ range: NSRange, value: Int = 1) -> Int {
        harness.coordinator.textView(harness.textView, shouldSetSpellingState: value, range: range)
    }

    func test_markupIsNeverMarkedMisspelled() {
        let harness = mount()
        let markup: [(String, Int)] = [
            ("tabel_4xq", 0),   // the figure's path
            ("csv", 0),
            ("tabel_4xq", 1),   // its {#tbl:…} label
            ("smithqq2020", 0), // a citation key
            ("exmple", 0),      // a link's URL
            ("qqzz", 0),
            ("codez", 0),       // inline code
            ("tabel_4xq", 2),   // a cross-reference
            ("qqnote", 0),      // a footnote id
            ("methqq", 0),      // a heading's {#sec:…} label
            ("fenzed", 0),      // a fenced code block
            ("wrds", 0),
        ]
        for (word, n) in markup {
            XCTAssertEqual(asks(harness, range(of: word, n)), 0, "\(word) #\(n) is markup")
        }
    }

    func test_wordsStayChecked() {
        let harness = mount()
        for word in ["resuls", "Tabel", "sitee", "wordz", "Methods"] {
            XCTAssertEqual(asks(harness, range(of: word)), 1, "\(word) is a word")
        }
        // Grammar's value passes through as given.
        XCTAssertEqual(asks(harness, range(of: "resuls"), value: 2), 2)
    }

    func test_clearingAMarkIsNeverRefused() {
        let harness = mount()
        XCTAssertEqual(asks(harness, range(of: "tabel_4xq"), value: 0), 0)
        XCTAssertEqual(asks(harness, range(of: "smithqq2020"), value: 0), 0)
    }

    /// Between a character edit and its retokenize the tokens describe the
    /// text before it: they are not asked (a stale token must never hide a
    /// real misspelling), and the next check after the retokenize decides.
    func test_staleTokensAreNotAsked() {
        let harness = mount()
        let citation = range(of: "smithqq2020")
        harness.textView.textStorage!.replaceCharacters(in: NSRange(location: 0, length: 0), with: "X")
        XCTAssertTrue(harness.coordinator.tokensDescribeAnEarlierText)
        XCTAssertEqual(asks(harness, NSRange(location: citation.location + 1, length: citation.length)), 1)
        harness.coordinator.textDidChange(Notification(name: NSText.didChangeNotification,
                                                       object: harness.textView))
        XCTAssertFalse(harness.coordinator.tokensDescribeAnEarlierText)
        XCTAssertEqual(asks(harness, NSRange(location: citation.location + 1, length: citation.length)), 0)
    }

    /// A screenplay's task anchor is markup too; its notes and dialogue are words.
    func test_screenplayAnchorIsMarkup() {
        let script = "INT. HOUSE - DAY\n\nShe enterz. [[todo: fix thiss]]<!--t-abcdef-->\n"
        let harness = mount(script, mode: ScreenplayMode())
        XCTAssertEqual(asks(harness, range(of: "abcdef", in: script)), 0)
        XCTAssertEqual(asks(harness, range(of: "enterz", in: script)), 1)
        XCTAssertEqual(asks(harness, range(of: "thiss", in: script)), 1)
    }

    /// The real checker, run synchronously over the whole text, its results
    /// handed to the text view's own `setSpellingState(_:range:)` (what the
    /// continuous checker does with them): the markup carries no spelling
    /// mark, the caption's and the prose's misspellings do.
    func test_theRealCheckerMarksWordsAndNotMarkup() {
        let harness = mount()
        let tv = harness.textView
        let results = NSSpellChecker.shared.check(
            Self.text, range: NSRange(location: 0, length: (Self.text as NSString).length),
            types: NSTextCheckingResult.CheckingType.spelling.rawValue,
            options: [.orthography: NSOrthography.defaultOrthography(forLanguage: "en")],
            inSpellDocumentWithTag: tv.spellCheckerDocumentTag,
            orthography: nil, wordCount: nil)
        for result in results where result.resultType == .spelling {
            tv.setSpellingState(NSAttributedString.SpellingState.spelling.rawValue, range: result.range)
        }
        func marked(_ r: NSRange) -> Bool {
            let lm = tv.layoutManager!
            for i in r.location..<NSMaxRange(r) {
                if let v = lm.temporaryAttribute(.spellingState, atCharacterIndex: i, effectiveRange: nil)
                    as? Int, v != 0 { return true }
            }
            return false
        }
        XCTAssertTrue(marked(range(of: "resuls")), "control: the checker marks a prose misspelling")
        XCTAssertTrue(marked(range(of: "Tabel")), "the caption is checked")
        for (word, n) in [("tabel_4xq", 0), ("tabel_4xq", 1), ("smithqq2020", 0),
                          ("exmple", 0), ("qqnote", 0), ("fenzed", 0)] {
            XCTAssertFalse(marked(range(of: word, n)), "\(word) #\(n) is markup")
        }
    }
}
