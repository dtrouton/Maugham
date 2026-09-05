import XCTest
import MaughamCore
import AppKit
@testable import Maugham

/// Pins the P1-editor perf fix (hardening plan task 4.7): `retokenizeAndStyle`
/// parses the Fountain document EXACTLY ONCE per keystroke and threads the one
/// `FountainScript` through token derivation + styling, instead of the prior
/// three full-document parses (tokenize, lastParsedScript, applyTypography).
///
/// `FountainTokenizer` is a concrete struct with no injectable parse seam, so a
/// direct parse-counter at the coordinator isn't available without widening the
/// fragile Editor seam. Instead these tests pin the two structural facts that
/// guarantee the collapse and that it stays behavior-preserving:
///  1. `tokens(from:)` derives the SAME tokens `tokenize` did (so deriving from
///     a pre-parsed script is identical — parse #1/#2 collapse).
///  2. `applyTypography(parsedScript:)` CONSUMES the passed script and does NOT
///     re-parse storage (parse #3 removed) — and produces output identical to
///     the legacy self-parsing path when given the script for the same text.
final class ScreenplaySingleParseTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // The parallel-worker fontd cold-start window (CLAUDE.md): this suite
        // styles real text through production typography, and
        // test_applyTypography_usesPassedScript_notReparse crashed at 0.000s
        // twice in that window (2026-08-09, 2026-08-13), green in isolation.
        FontWarmup.ensure()
    }
    private let mode = ScreenplayMode()
    private let parser = FountainTokenizer()

    // MARK: - Token derivation collapses to one parse

    func test_tokensFromScript_matchesTokenize() {
        let samples = [
            "INT. KITCHEN - DAY\n\nLarry sits.\n\nBARRY\nHello there.",
            "Title: My Script\nAuthor: Me\n\nFADE IN:\n\nEXT. STREET - NIGHT",
            "BRICK ^\nHi.\n\n[[todo: fix this]]\n\n# Act One\n\n= a synopsis",
            "",
        ]
        for text in samples {
            let viaTokenize = mode.tokenize(text)
            let viaScript = mode.tokens(from: parser.parse(text), text: text)
            XCTAssertEqual(viaScript.count, viaTokenize.count,
                           "token count diverged for: \(text.prefix(20))")
            for (a, b) in zip(viaScript, viaTokenize) {
                XCTAssertEqual(a.range, b.range)
                XCTAssertEqual(a.kind, b.kind)
            }
        }
    }

    // MARK: - applyTypography consumes the passed script (no internal re-parse)

    /// If `applyTypography` re-parsed `storage.string` it would ignore the
    /// passed `parsedScript`. We pass a script parsed from text WITH a title
    /// page while the storage holds text WITHOUT one. The title-page detection
    /// drives `paragraphSpacingBefore` on the first body line — an observable
    /// that follows whichever script `applyTypography` actually used. It must
    /// follow the PASSED script, proving the internal parse is gone.
    func test_applyTypography_usesPassedScript_notReparse() {
        let bodyOnly = "Larry sits at the bar."
        let withTitle = "Title: X\n\n" + bodyOnly

        // Storage holds body-only text; we hand it a script parsed from the
        // title-page version. The first body line's spacing-before should be
        // non-zero (title-page branch fired) because we passed that script.
        let storage = NSTextStorage(string: bodyOnly)
        let titleScript = parser.parse(withTitle)
        let tokens = mode.tokens(from: parser.parse(bodyOnly), text: bodyOnly)
        mode.applyTypography(in: storage, theme: .light,
                             typography: .screenplayDefaults,
                             tokens: tokens, parsedScript: titleScript)
        let spacing = (storage.attributes(at: 0, effectiveRange: nil)[.paragraphStyle]
            as? NSParagraphStyle)?.paragraphSpacingBefore ?? 0
        XCTAssertGreaterThan(spacing, 0,
            "applyTypography ignored the passed script and re-parsed storage")

        // Control: same storage, but pass the body-only script → no title page,
        // so no first-body spacing-before. Confirms the observable is driven by
        // the passed script, not something else.
        let storage2 = NSTextStorage(string: bodyOnly)
        mode.applyTypography(in: storage2, theme: .light,
                             typography: .screenplayDefaults,
                             tokens: tokens, parsedScript: parser.parse(bodyOnly))
        let spacing2 = (storage2.attributes(at: 0, effectiveRange: nil)[.paragraphStyle]
            as? NSParagraphStyle)?.paragraphSpacingBefore ?? 0
        XCTAssertEqual(spacing2, 0, accuracy: 0.001,
            "body-only script should not stamp first-body spacing-before")
    }

    // MARK: - Threaded path is byte-for-byte equivalent to the legacy path

    func test_applyTypography_threadedEqualsSelfParsed() {
        let text = """
        Title: Equivalence
        Author: Tester

        INT. KITCHEN - DAY

        Larry sits at the bar.

        BARRY
        (quietly)
        Hello there.

        CUT TO:
        """
        let tokens = mode.tokenize(text)

        // Legacy path: applyTypography parses storage.string itself.
        let legacy = NSTextStorage(string: text)
        mode.applyTypography(in: legacy, theme: .light,
                             typography: .screenplayDefaults, tokens: tokens)

        // Threaded path: hand it the script parsed once up front.
        let threaded = NSTextStorage(string: text)
        mode.applyTypography(in: threaded, theme: .light,
                             typography: .screenplayDefaults, tokens: tokens,
                             parsedScript: parser.parse(text))

        XCTAssertEqual(legacy.length, threaded.length)
        // Walk every attribute run; the two must be attribute-identical.
        var loc = 0
        while loc < legacy.length {
            var rangeA = NSRange(), rangeB = NSRange()
            let attrsA = legacy.attributes(at: loc, effectiveRange: &rangeA)
            let attrsB = threaded.attributes(at: loc, effectiveRange: &rangeB)
            XCTAssertEqual(rangeA, rangeB, "attribute-run boundary diverged at \(loc)")
            XCTAssertEqual(attrsA[.font] as? NSFont, attrsB[.font] as? NSFont,
                           "font diverged at \(loc)")
            XCTAssertEqual(attrsA[.foregroundColor] as? NSColor,
                           attrsB[.foregroundColor] as? NSColor,
                           "color diverged at \(loc)")
            XCTAssertEqual(attrsA[.paragraphStyle] as? NSParagraphStyle,
                           attrsB[.paragraphStyle] as? NSParagraphStyle,
                           "paragraph style diverged at \(loc)")
            loc = NSMaxRange(rangeA)
        }
    }
}
