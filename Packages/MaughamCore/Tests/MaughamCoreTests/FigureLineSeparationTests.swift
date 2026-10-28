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
            // nil: the caret stays where it was (the edit's end for a
            // Backspace, its start for a Delete).
            return (text as String, c ?? caret, true, true)
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

    /// Below a figure the refusal never parks the caret on the figure line
    /// (whole-branch review I3): a held Backspace would eat its label.
    func test_backspaceAtTheStartOfTheParagraphBelow_isRefusedInPlace() {
        let r = edit("\(fig)\n\n|After.", before: 1, type: "")
        XCTAssertTrue(r.refused)
        XCTAssertEqual(FigureLineSeparation.decide(text: "\(fig)\n\nAfter." as NSString,
                                                   range: NSRange(location: (fig as NSString).length + 1, length: 1),
                                                   replacement: ""),
                       .refuse(caret: nil), "the caret stays at the paragraph's start")
        XCTAssertEqual(r.caret, at(r.text, "After."))
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

    /// Whole-branch review I2: a heading directly above a figure is "already
    /// glued" only for the heading itself; a line the edit makes between them
    /// is new, and is kept apart.
    func test_typingAtColumnZeroUnderAHeading_isKeptApartFromTheFigure() {
        let r = edit("# H\n|\(fig)", type: "x")
        XCTAssertEqual(r.text, "# H\nx\n\n\(fig)")
        XCTAssertEqual(r.caret, at(r.text, "x") + 1)
    }

    func test_editingAnOldGluedLineBelowAFigure_isLeftAlone() {
        XCTAssertFalse(edit("\(fig)\n|After.", type: "x").adjusted, "the same neighbour, edited")
    }

    // MARK: - Line endings (whole-branch review M1)

    func test_crlfTextGetsItsOwnLineEnding() {
        let r = edit("Prose.\r\n\r\n|\(fig)", type: "x")
        XCTAssertEqual(r.text, "Prose.\r\n\r\nx\r\n\r\n\(fig)")
        XCTAssertEqual(r.caret, at(r.text, "x") + 1)
        let below = edit("\(fig)\r\n|", type: "T")
        XCTAssertEqual(below.text, "\(fig)\r\n\r\nT")
    }

    func test_crlfBlankLineIsBlank_backspaceOverItIsRefused() {
        let r = edit("Prose.\r\n\r\n|\(fig)", before: 2, type: "")
        XCTAssertTrue(r.refused)
        XCTAssertEqual(r.caret, 6)
        XCTAssertFalse(edit("Prose.\r\n\r\n\r\n|\(fig)", before: 2, type: "").adjusted,
                       "an extra CRLF blank line deletes")
    }

    func test_aLineSeparatorEndsALine_andTheBreakAddedIsANewline() {
        let r = edit("\(fig)\u{2028}|", type: "T")
        XCTAssertEqual(r.text, "\(fig)\u{2028}\nT", "never a bare U+2028 blank line")
        XCTAssertFalse(edit("Prose.\u{2029}\u{2029}|\(fig)", type: "\n").adjusted)
    }

    // MARK: - Code (whole-branch review M2)

    func test_insideAFencedCodeBlock_nothingIsTouched() {
        XCTAssertFalse(edit("```\nProse.\n|\(fig)\n```", type: "x").adjusted)
        XCTAssertFalse(edit("```\n\(fig)\n|", type: "x").adjusted)
        XCTAssertTrue(edit("```\ncode\n```\n\nProse.\n\n|\(fig)", type: "x").adjusted,
                      "after the fence closes the rule applies")
    }

    func test_anIndentedCodeLineIsNotAFigureLine() {
        XCTAssertFalse(edit("    Prose.\n|    \(fig)", type: "x").adjusted)
        XCTAssertFalse(edit("Prose.\n|", type: "    \(fig)").adjusted)
        XCTAssertTrue(FigureLineSeparation.isInCode(lineAt: 2, in: "    \(fig)" as NSString))
        XCTAssertTrue(FigureLineSeparation.isInCode(lineAt: 5, in: "```\n\(fig)\n```" as NSString))
        XCTAssertFalse(FigureLineSeparation.isInCode(lineAt: 0, in: fig as NSString))
    }

    func test_whatCountsAsAFigureLine() {
        XCTAssertTrue(FigureLineSeparation.isFigureLine(fig))
        XCTAssertTrue(FigureLineSeparation.isFigureLine("![A](a.png)"))
        XCTAssertFalse(FigureLineSeparation.isFigureLine("x![A](a.png)"))
        XCTAssertFalse(FigureLineSeparation.isFigureLine("![A](a.png) ![B](b.png)"))
        XCTAssertFalse(FigureLineSeparation.isFigureLine("Prose."))
    }
}
