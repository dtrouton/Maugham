// MaughamTests/Editor/ReportInsertTests.swift
import XCTest
import MaughamCore
@testable import Maugham

/// The Insert menu's pure text builders (plan 3a Task 4, R-3a-5 and R-3a-6):
/// what Insert Table and Insert Footnote write, where, and where the caret
/// lands — no view, no window.
final class ReportInsertTests: XCTestCase {

    // MARK: - R-3a-5 the table

    func test_theTableIsThreeColumnsADelimiterOneEmptyRowAndACaption() {
        XCTAssertEqual(ReportInsert.table(nextLabelNumber: 4), """
            | Column 1 | Column 2 | Column 3 |
            | -------- | -------- | -------- |
            |          |          |          |
            Table: Caption {#tbl:table-4}
            """)
    }

    func test_theWrittenTableReadsBackAsACaptionedLabelledTable() throws {
        let parsed = ManuscriptBlocks.parse(ReportInsert.table(nextLabelNumber: 2))
        XCTAssertEqual(parsed.count, 1, "the table and its caption are one block")
        guard case .table(let header, _, let rows, let caption, let label) = parsed[0].block else {
            return XCTFail("Insert Table wrote something that is not a table: \(parsed)")
        }
        XCTAssertEqual(header, ["Column 1", "Column 2", "Column 3"])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(caption, "Caption")
        XCTAssertEqual(label, ManuscriptLabel(reference: "tbl:table-2"))
    }

    func test_theTableHasNoBlankLineSoItIsOneParagraph() {
        let table = ReportInsert.table(nextLabelNumber: 1)
        XCTAssertFalse(table.contains("\n\n"))
        XCTAssertEqual(ParagraphParser.parse(table).count, 1)
    }

    func test_theTableNumberSkipsEveryTblLabelTheDocumentUses() {
        let text = """
            | a |
            |---|
            | b |
            Table: First {#tbl:table-1}

            See @tbl:table-2 elsewhere.

            ## A heading {#tbl:table-3}
            """
        XCTAssertEqual(ReportInsert.nextTableLabelNumber(in: text), 4)
        XCTAssertEqual(ReportInsert.nextTableLabelNumber(in: "No tables."), 1)
        XCTAssertEqual(ReportInsert.nextTableLabelNumber(in: "@tbl:table-2"), 1,
                       "the lowest free number, not one past the highest")
    }

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
        // ch2 inserting a table: its own table-2 and ch1's table-1 are both taken.
        XCTAssertEqual(ReportInsert.nextTableLabelNumber(in: texts["ch2"]!, elsewhere: elsewhere), 3)
        XCTAssertEqual(ReportInsert.nextTableLabelNumber(
            in: "", elsewhere: [ManuscriptLabel(reference: "fig:table-1")!]), 1,
            "only tbl: labels elsewhere count")
    }

    // MARK: - Where the table goes

    func test_aTableAtTheStartOfAParagraphGoesAboveIt() {
        let edit = ReportInsert.tableEdit(in: "Two.", at: 0, tableBlocks: [])
        XCTAssertEqual(Self.apply(edit, to: "Two."),
                       ReportInsert.table(nextLabelNumber: 1) + "\n\nTwo.")
        XCTAssertEqual(edit.selection, NSRange(location: 2, length: 8))
    }

    func test_aTableMidParagraphSplitsItOntoItsOwnBlock() {
        let text = "Before the table after."
        let caret = ("Before the" as NSString).length
        let edit = ReportInsert.tableEdit(in: text, at: caret, tableBlocks: [])
        let result = Self.apply(edit, to: text)
        XCTAssertEqual(result, "Before the\n\n" + ReportInsert.table(nextLabelNumber: 1)
                       + "\n\ntable after.")
        XCTAssertEqual(ParagraphParser.parse(result).count, 3)
        XCTAssertEqual((result as NSString).substring(with: edit.selection), "Column 1",
                       "the caret lands in the first header cell with its text selected")
    }

    func test_aTableOnAnEmptyLineBetweenParagraphsAddsOnlyTheBlankLinesItNeeds() {
        let text = "One.\n\n\n\nTwo."
        let edit = ReportInsert.tableEdit(in: text, at: 6, tableBlocks: [])
        XCTAssertEqual(Self.apply(edit, to: text),
                       "One.\n\n" + ReportInsert.table(nextLabelNumber: 1) + "\n\nTwo.")
    }

    func test_aTableAtTheEndOfAParagraphLineFollowsItAfterABlankLine() {
        let text = "One.\nTwo."
        let edit = ReportInsert.tableEdit(in: text, at: 4, tableBlocks: [])
        XCTAssertEqual(Self.apply(edit, to: text),
                       "One.\n\n" + ReportInsert.table(nextLabelNumber: 1) + "\n\nTwo.")
    }

    func test_aTableInAnEmptyDocumentIsTheWholeDocument() {
        let edit = ReportInsert.tableEdit(in: "", at: 0, tableBlocks: [])
        XCTAssertEqual(Self.apply(edit, to: ""), ReportInsert.table(nextLabelNumber: 1))
        XCTAssertEqual(edit.selection, NSRange(location: 2, length: 8))
    }

    func test_aTableAskedForInsideATableGoesAfterIt() {
        let existing = "| a |\n|---|\n| b |\nTable: T {#tbl:table-1}"
        let text = existing + "\n\nAfter."
        let inside = ("| a |\n|-" as NSString).length
        let block = NSRange(location: 0, length: (existing as NSString).length)
        let edit = ReportInsert.tableEdit(in: text, at: inside, tableBlocks: [block])
        XCTAssertEqual(Self.apply(edit, to: text),
                       existing + "\n\n" + ReportInsert.table(nextLabelNumber: 2) + "\n\nAfter.")
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
