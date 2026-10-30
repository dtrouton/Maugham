// MaughamTests/Editor/ReportInsertTests.swift
import XCTest
import MaughamCore
@testable import Maugham

/// The Insert menu's pure text builders (plan 3a Task 4, R-3a-6): where a
/// figure line goes (`blockEdit`), what Insert Footnote writes, and where the
/// caret lands — no view, no window.
final class ReportInsertTests: XCTestCase {

    // MARK: - Labels elsewhere

    /// I1: the walk over the project's OTHER documents — two chapters, one of
    /// them the document being edited, plus a screenplay.
    func test_labelsElsewhereReadsEveryOtherManuscriptAndSkipsThisOne() {
        let structure = [
            StructureItem(id: "ch1", title: "One", type: .document, path: "manuscript/ch1.md"),
            StructureItem(id: "grp", title: "Part", type: .group, children: [
                StructureItem(id: "ch2", title: "Two", type: .document, path: "manuscript/ch2.md"),
            ]),
            StructureItem(id: "sp", title: "Script", type: .document, path: "script.fountain"),
        ]
        let texts = [
            "ch1": "## One {#sec:one}\n\n| a |\n|---|\n| b |\nTable: T {#tbl:table-1}",
            "ch2": "![Fig](x.png){#fig:map}\n\n| a |\n|---|\n| b |\nTable: U {#tbl:table-2}",
            "sp": "INT. HOUSE {#tbl:table-9}",
        ]
        let elsewhere = ReportInsert.labelsElsewhere(in: structure, excluding: "ch2") { item, _ in
            texts[item.id]
        }
        XCTAssertEqual(elsewhere, [ManuscriptLabel(reference: "sec:one")!,
                                   ManuscriptLabel(reference: "tbl:table-1")!],
                       "ch2 is the document being edited; the screenplay defines nothing")
    }

    // MARK: - Where a block goes (`blockEdit`, every figure line's placement)

    /// A one-paragraph block, and the run inside it the placement selects.
    private static let block = "![Caption](figures/table.csv){#tbl:table}"
    private static let caption = NSRange(location: 2, length: 7)

    private static func blockEdit(in text: String, at location: Int,
                                  tableBlocks: [NSRange] = []) -> ReportInsert.Edit {
        ReportInsert.blockEdit(in: text, at: location, tableBlocks: tableBlocks,
                               block: block, selectionInBlock: caption)
    }

    func test_aBlockAtTheStartOfAParagraphGoesAboveIt() {
        let edit = Self.blockEdit(in: "Two.", at: 0)
        XCTAssertEqual(Self.apply(edit, to: "Two."), Self.block + "\n\nTwo.")
        XCTAssertEqual(edit.selection, NSRange(location: 2, length: 7))
    }

    func test_aBlockMidParagraphSplitsItOntoItsOwnBlock() {
        let text = "Before the table after."
        let caret = ("Before the" as NSString).length
        let edit = Self.blockEdit(in: text, at: caret)
        let result = Self.apply(edit, to: text)
        XCTAssertEqual(result, "Before the\n\n" + Self.block + "\n\ntable after.")
        XCTAssertEqual(ParagraphParser.parse(result).count, 3)
        XCTAssertEqual((result as NSString).substring(with: edit.selection), "Caption",
                       "the selection lands on the block's selected run")
    }

    func test_aBlockOnAnEmptyLineBetweenParagraphsAddsOnlyTheBlankLinesItNeeds() {
        let text = "One.\n\n\n\nTwo."
        let edit = Self.blockEdit(in: text, at: 6)
        XCTAssertEqual(Self.apply(edit, to: text), "One.\n\n" + Self.block + "\n\nTwo.")
    }

    func test_aBlockAtTheEndOfAParagraphLineFollowsItAfterABlankLine() {
        let text = "One.\nTwo."
        let edit = Self.blockEdit(in: text, at: 4)
        XCTAssertEqual(Self.apply(edit, to: text), "One.\n\n" + Self.block + "\n\nTwo.")
    }

    func test_aBlockInAnEmptyDocumentIsTheWholeDocument() {
        let edit = Self.blockEdit(in: "", at: 0)
        XCTAssertEqual(Self.apply(edit, to: ""), Self.block)
        XCTAssertEqual(edit.selection, NSRange(location: 2, length: 7))
    }

    func test_aBlockAskedForInsideATableGoesAfterIt() {
        let existing = "| a |\n|---|\n| b |\nTable: T {#tbl:table-1}"
        let text = existing + "\n\nAfter."
        let inside = ("| a |\n|-" as NSString).length
        let table = NSRange(location: 0, length: (existing as NSString).length)
        let edit = Self.blockEdit(in: text, at: inside, tableBlocks: [table])
        XCTAssertEqual(Self.apply(edit, to: text), existing + "\n\n" + Self.block + "\n\nAfter.")
    }

    /// Report plan 8b Task 3 review: a caret inside a figure line places the
    /// block after that line, never splitting it into two lines that are no
    /// longer a figure — for Insert ▸ Table, Insert Figure… and Insert ▸
    /// Existing Figure… alike, which all place through `blockEdit`.
    func test_aBlockAskedForInsideAFigureLineGoesAfterIt() {
        let figure = "![Cash flows](figures/cash.csv){#tbl:cash}"
        let text = "Intro.\n\n" + figure + "\n\nAfter."
        let inside = ("Intro.\n\n![Cash" as NSString).length
        let edit = Self.blockEdit(in: text, at: inside)
        let result = Self.apply(edit, to: text)
        XCTAssertEqual(result, "Intro.\n\n" + figure + "\n\n" + Self.block + "\n\nAfter.")
        XCTAssertEqual((result as NSString).substring(with: edit.selection), "Caption")

        // At the line's last character too, and with prose glued below it.
        let glued = figure + "\nAfter."
        let last = (figure as NSString).length - 1
        XCTAssertEqual(Self.apply(Self.blockEdit(in: glued, at: last), to: glued),
                       figure + "\n\n" + Self.block + "\n\nAfter.")
    }

    /// The control: at a figure line's very start the block still goes above
    /// it (the line stays whole), and inside a line that is not a figure it
    /// still splits.
    func test_aBlockAtAFigureLinesStartStillGoesAboveIt() {
        let figure = "![Cash flows](figures/cash.csv){#tbl:cash}"
        let text = "Intro.\n\n" + figure
        let start = ("Intro.\n\n" as NSString).length
        XCTAssertEqual(Self.apply(Self.blockEdit(in: text, at: start), to: text),
                       "Intro.\n\n" + Self.block + "\n\n" + figure)
        XCTAssertNil(ReportInsert.endOfFigureLine(containing: 3, in: "Not a figure." as NSString))
    }

    // MARK: - R-3a-6 the footnote

    func test_theFootnoteRefGoesAtTheCaretAndItsDefinitionFollowsTheParagraph() {
        let paragraph = "A claim here and more."
        let caret = ("A claim" as NSString).length
        let r = ReportInsert.footnote(in: paragraph, caret: caret, existingLabels: [])
        let rebuilt = (paragraph as NSString).replacingCharacters(in: r.replacedRange,
                                                                  with: r.replacement)
        XCTAssertEqual(rebuilt, "A claim[^1] here and more.\n\n[^1]: ")
        XCTAssertEqual(r.caret, NSRange(location: (rebuilt as NSString).length, length: 0),
                       "the caret waits at the definition")
    }

    /// M4: a caret at or past a line's trailing `{#…}` block puts the ref
    /// before the block, so the label stays the line's last thing.
    func test_aFootnoteRefGoesBeforeAHeadingsLabel() {
        let heading = "## Results {#sec:results}"
        for caret in [(heading as NSString).length, ("## Results {#se" as NSString).length,
                      ("## Results " as NSString).length] {
            let r = ReportInsert.footnote(in: heading, caret: caret, existingLabels: [])
            let rebuilt = (heading as NSString).replacingCharacters(in: r.replacedRange,
                                                                    with: r.replacement)
            XCTAssertEqual(rebuilt, "## Results[^1] {#sec:results}\n\n[^1]: ", "caret \(caret)")
            guard case .heading(_, let text, let label)? = ManuscriptBlocks.parse(rebuilt).first?.block
            else { return XCTFail("no longer a heading") }
            XCTAssertEqual(text, "Results[^1]")
            XCTAssertEqual(label, ManuscriptLabel(reference: "sec:results"), "the heading keeps its label")
        }
        let mid = ReportInsert.footnote(in: heading, caret: 3, existingLabels: [])
        XCTAssertEqual(mid.replacement.prefix(4), "[^1]", "before the block, the caret stands")
    }

    func test_aFootnoteRefGoesBeforeACaptionsLabel() {
        let table = "| a |\n|---|\n| b |\nTable: Sales {#tbl:sales}"
        let r = ReportInsert.footnote(in: table, caret: (table as NSString).length,
                                      existingLabels: [])
        let rebuilt = (table as NSString).replacingCharacters(in: r.replacedRange,
                                                              with: r.replacement)
        XCTAssertEqual(rebuilt, "| a |\n|---|\n| b |\nTable: Sales[^1] {#tbl:sales}\n\n[^1]: ")
        guard case .table(_, _, _, let caption, let label) = ManuscriptBlocks.parse(rebuilt)[0].block
        else { return XCTFail("no longer a table") }
        XCTAssertEqual(caption, "Sales[^1]")
        XCTAssertEqual(label, ManuscriptLabel(reference: "tbl:sales"))
    }

    func test_footnoteNumberingSkipsEveryLabelAlreadyUsed() {
        XCTAssertEqual(ReportInsert.lowestFreeFootnoteLabel(existing: ["1", "2", "4", "note"]), "3")
        XCTAssertEqual(ReportInsert.lowestFreeFootnoteLabel(existing: []), "1")
        let r = ReportInsert.footnote(in: "Text", caret: 4, existingLabels: ["1", "2"])
        XCTAssertEqual(r.replacement, "[^3]\n\n[^3]: ")
    }

    func test_theUsedFootnoteLabelsAreTheRefsAndTheDefinitions() {
        let text = """
            One[^1] and two[^x].

            [^2]: A definition with no reference.

            `[^9]` in code is not a footnote.
            """
        XCTAssertEqual(ReportInsert.footnoteLabels(in: text), ["1", "x", "2"])
    }

    func test_aFootnoteInTheMiddleOfADocumentLeavesTheNextParagraphAlone() {
        let text = "First para.\n\nSecond para."
        let edit = ReportInsert.footnoteEdit(in: text, at: 5)
        XCTAssertEqual(Self.apply(edit, to: text),
                       "First[^1] para.\n\n[^1]: \n\nSecond para.")
        XCTAssertEqual(edit.selection.location, ("First[^1] para.\n\n[^1]: " as NSString).length)
        XCTAssertEqual(ParagraphParser.parse(Self.apply(edit, to: text)).map(\.text),
                       ["First[^1] para.", "[^1]: ", "Second para."])
    }

    func test_aFootnoteOnABlankLineBelongsToTheParagraphAboveIt() {
        let text = "First.\n\n\nSecond."
        let edit = ReportInsert.footnoteEdit(in: text, at: 8)
        XCTAssertEqual(Self.apply(edit, to: text), "First.[^1]\n\n[^1]: \n\n\nSecond.")
    }

    func test_aFootnoteInAnEmptyDocument() {
        let edit = ReportInsert.footnoteEdit(in: "", at: 0)
        XCTAssertEqual(Self.apply(edit, to: ""), "[^1]\n\n[^1]: ")
    }

    func test_aFootnoteOnLeadingBlankLinesDoesNotRunIntoTheTextBelow() {
        let text = "\nBody."
        let result = Self.apply(ReportInsert.footnoteEdit(in: text, at: 0), to: text)
        XCTAssertEqual(ParagraphParser.parse(result).map(\.text), ["[^1]", "[^1]: ", "Body."])
    }

    func test_aFootnoteCountsTheLabelsOfTheWholeDocument() {
        let text = "One[^1].\n\nTwo.\n\n[^2]: Defined."
        let edit = ReportInsert.footnoteEdit(in: text, at: ("One[^1].\n\nTwo" as NSString).length)
        XCTAssertEqual(Self.apply(edit, to: text), "One[^1].\n\nTwo[^3].\n\n[^3]: \n\n[^2]: Defined.")
    }

    // MARK: - Helpers

    static func apply(_ edit: ReportInsert.Edit, to text: String) -> String {
        (text as NSString).replacingCharacters(in: edit.replacedRange, with: edit.replacement)
    }
}
