import XCTest
@testable import MaughamCore

/// **A figure line always stands as its own paragraph** (Denver's smoke,
/// 2026-10-28): the pure rule the editor applies to each edit.
final class FigureLineSeparationTests: XCTestCase {

    private let fig = "![Test Table](figures/table.csv){#tbl:table}"

    /// The edit as the rule makes it: the text after it and the caret, and
    /// whether the rule stepped in at all. `|` in `text` marks the caret
    /// (an insertion there, or the start of `deleting` characters).
    private func edit(_ marked: String, deleting: Int = 0, before: Int = 0, type replacement: String)
        -> (text: String, caret: Int, adjusted: Bool, refused: Bool) {
        let caret = (marked as NSString).range(of: "|").location
        let text = (marked as NSString).replacingOccurrences(of: "|", with: "") as NSString
        let range = NSRange(location: caret - before, length: deleting + before)
        switch FigureLineSeparation.decide(text: text, range: range, replacement: replacement) {
        case nil:
            let out = text.replacingCharacters(in: range, with: replacement)
            return (out, range.location + (replacement as NSString).length, false, false)
        case .replace(let r, let with, let c)?:
            XCTAssertEqual(r, range, "the rule keeps the edit's own range")
            return (text.replacingCharacters(in: r, with: with), c, true, false)
        case .refuse(let c)?:
            return (text as String, c, true, true)
        }
    }

    private func at(_ text: String, _ needle: String) -> Int { (text as NSString).range(of: needle).location }

    // MARK: - Typing beside a figure line

    /// The smoke's case: Return at the figure line's start, then typing on
    /// the new line, which sits directly above the figure.
    func test_typingOnTheEmptyLineDirectlyAboveAFigure_keepsABlankLineBetween() {
        let r = edit("This is me testing.\n\n|\n\(fig)", type: "T")
        XCTAssertEqual(r.text, "This is me testing.\n\nT\n\n\(fig)")
        XCTAssertEqual(r.caret, at(r.text, "\nT\n") + 2, "the caret right after T, not after the break")
    }

    func test_typingAtColumnZeroOfTheFigureLine_goesIntoAParagraphAbove() {
        let r = edit("Prose.\n\n|\(fig)", type: "x")
        XCTAssertEqual(r.text, "Prose.\n\nx\n\n\(fig)")
        XCTAssertEqual(r.caret, at(r.text, "x") + 1)
    }

    func test_typingAtColumnZeroOfAFigureAtTheDocumentStart() {
        let r = edit("|\(fig)\n\nAfter.", type: "x")
        XCTAssertEqual(r.text, "x\n\n\(fig)\n\nAfter.")
        XCTAssertEqual(r.caret, 1)
    }

    func test_typingOnTheLineDirectlyBelowAFigure_keepsABlankLineBetween() {
        // Return at the figure line's end made the empty line below it.
        let r = edit("\(fig)\n|", type: "T")
        XCTAssertEqual(r.text, "\(fig)\n\nT")
        XCTAssertEqual(r.caret, (r.text as NSString).length, "the caret after T")
    }

    func test_pastingTextEndingInANewlineAtColumnZero_getsTheBlankLine() {
        let r = edit("Prose.\n\n|\(fig)", type: "one\ntwo\n")
        XCTAssertEqual(r.text, "Prose.\n\none\ntwo\n\n\(fig)")
        XCTAssertEqual(r.caret, at(r.text, "two") + 4, "the caret after what was pasted")
    }

    func test_pastingAFigureLineDirectlyUnderText_separatesIt() {
        let r = edit("Prose.\n|", type: fig)
        XCTAssertEqual(r.text, "Prose.\n\n\(fig)")
        XCTAssertEqual(r.caret, (r.text as NSString).length)
    }

    // MARK: - Deleting the blank line

    func test_backspaceAtAFigureLinesStartOverTheOneBlankLine_isRefused_caretToTheParagraphAbove() {
        let r = edit("Prose.\n\n|\(fig)", before: 1, type: "")
        XCTAssertTrue(r.refused)
        XCTAssertEqual(r.text, "Prose.\n\n\(fig)")
        XCTAssertEqual(r.caret, ("Prose." as NSString).length)
    }

    func test_backspaceOverAnExtraBlankLine_isAnOrdinaryDelete() {
        let r = edit("Prose.\n\n\n|\(fig)", before: 1, type: "")
        XCTAssertFalse(r.adjusted)
        XCTAssertEqual(r.text, "Prose.\n\n\(fig)")
    }

    func test_backspaceAtTheStartOfTheParagraphBelow_isRefused() {
        let r = edit("\(fig)\n\n|After.", before: 1, type: "")
        XCTAssertTrue(r.refused)
        XCTAssertEqual(r.caret, (fig as NSString).length, "the caret to the end of the figure line")
    }

    func test_forwardDeleteOfTheBlankLine_isRefused_theCaretStays() {
        let r = edit("Prose.|\n\n\(fig)", deleting: 1, type: "")
        XCTAssertTrue(r.refused)
        XCTAssertEqual(r.caret, 6)
    }

    func test_forwardDeleteAtAFigureLinesEnd_keepsTheBreak() {
        let r = edit("\(fig)|\n\nAfter.", deleting: 1, type: "")
        XCTAssertTrue(r.refused)
        let s = edit("\(fig)|\n\nAfter.", deleting: 2, type: "")
        XCTAssertTrue(s.refused, "deleting both breaks would pull the text onto the figure line")
        XCTAssertEqual(s.text, "\(fig)\n\nAfter.")
    }

    func test_aSelectionDeleteOfTheBlankLine_keepsIt() {
        let r = edit("Prose.|\n\n\(fig)", deleting: 2, type: "")
        XCTAssertTrue(r.refused)
        XCTAssertEqual(r.text, "Prose.\n\n\(fig)")
    }

    func test_aPasteOverTheBlankLine_addsItBack() {
        let r = edit("Prose.\n|\n\(fig)", deleting: 1, type: "more")
        XCTAssertEqual(r.text, "Prose.\nmore\n\n\(fig)")
        XCTAssertEqual(r.caret, at(r.text, "more") + 4)
    }

    func test_aSelectionDeleteThatLeavesTextOnTheFigureLine_keepsItApart() {
        let r = edit("Prose|.\n\n\(fig)", deleting: 3, type: "")
        XCTAssertEqual(r.text, "Prose\n\n\(fig)")
        XCTAssertEqual(r.caret, 5)
    }

    // MARK: - Untouched

    func test_ordinaryEditsAreUntouched() {
        XCTAssertNil(FigureLineSeparation.decide(text: "Hello", range: NSRange(location: 5, length: 0),
                                                 replacement: "\n"), "Return in prose")
        XCTAssertFalse(edit("Prose|.\n\n\(fig)", type: "x").adjusted, "typing in the paragraph above")
        XCTAssertFalse(edit("Prose.|\n\n\(fig)", type: "\n").adjusted, "Return in the paragraph above")
        XCTAssertFalse(edit("Prose.\n\n|\(fig)", type: "\n").adjusted, "Return at the figure's start (M4)")
        XCTAssertFalse(edit("\(fig)|\n\nAfter.", type: "\n").adjusted, "Return at the figure's end")
        XCTAssertFalse(edit("\(fig)\n\n|After.", type: "x").adjusted, "typing in the paragraph below")
        XCTAssertFalse(edit("Prose.\n\n|\(fig)", type: " ").adjusted, "a space keeps the figure a figure")
    }

    func test_editingTheFigureLineItselfIsUntouched() {
        XCTAssertFalse(edit("Prose.\n\n![Te|st](figures/t.csv)", type: "x").adjusted, "the caption")
        XCTAssertFalse(edit("Prose.\n\n![T](figures/t.csv)|", type: "{").adjusted, "a label being typed")
    }

    func test_aFigureAlreadyBesideAHeading_isLeftAlone() {
        XCTAssertFalse(edit("# Hea|d\n\(fig)", type: "x").adjusted)
        XCTAssertFalse(edit("# Head|\n\(fig)", type: "x").adjusted, "typing at the heading's end")
    }

    func test_anOldGluedLineIsLeftAloneByEditsAwayFromIt() {
        XCTAssertFalse(edit("Pro|se.\n\(fig)", type: "x").adjusted)
    }

    func test_whatCountsAsAFigureLine() {
        XCTAssertTrue(FigureLineSeparation.isFigureLine(fig))
        XCTAssertTrue(FigureLineSeparation.isFigureLine("![A](a.png)"))
        XCTAssertFalse(FigureLineSeparation.isFigureLine("x![A](a.png)"))
        XCTAssertFalse(FigureLineSeparation.isFigureLine("![A](a.png) ![B](b.png)"))
        XCTAssertFalse(FigureLineSeparation.isFigureLine("Prose."))
    }
}
