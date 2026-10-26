// MaughamTests/Editor/FigureIngestTests.swift
import XCTest
import AppKit
import UniformTypeIdentifiers
import MaughamCore
@testable import Maugham

/// The pure half of plan 3a Task 6 (R-3a-3, R-3a-4): the figure line's path,
/// its label, its text, where it goes, the open panel's configuration and the
/// drop decision. No window, no store.
final class FigureIngestTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUp() { temp = TempDirectory() }
    override func tearDown() { temp.cleanup(); temp = nil }

    // MARK: - relativePath round-trips through FigureImageResolver (review focus 5)

    private func assertResolves(document: String, research: String, expected: String,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let image = temp.url.appendingPathComponent(research)
        try FileManager.default.createDirectory(at: image.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        let path = FigureIngest.relativePath(fromDocument: document, toResearch: research)
        XCTAssertEqual(path, expected, file: file, line: line)
        let outcome = FigureImageResolver.resolve(path, piecePath: document,
                                                  projectURL: temp.url, allowed: ["png"])
        guard case .file(let url) = outcome else {
            return XCTFail("\(path) from \(document) did not resolve: \(outcome)",
                           file: file, line: line)
        }
        XCTAssertEqual(url.lastPathComponent, image.lastPathComponent, file: file, line: line)
    }

    // Image figures live in the project's figures/ (report plan 6a Task 9),
    // reached from every kind of document.

    func test_aRootStoryReachesFiguresDirectly() throws {
        try assertResolves(document: "story.md", research: "figures/chart.png",
                           expected: "figures/chart.png")
    }

    func test_aManuscriptChapterClimbsOnceToFigures() throws {
        try assertResolves(document: "manuscript/ch1.md", research: "figures/chart.png",
                           expected: "../figures/chart.png")
    }

    func test_aCollectionPieceClimbsToTheProjectsFigures() throws {
        try assertResolves(document: "pieces/01-one/one.md", research: "figures/chart.png",
                           expected: "../../figures/chart.png")
    }

    // Research-backed lines written before keep their paths (spec §4.4).

    func test_aRootStoryReachesResearchDirectly() throws {
        try assertResolves(document: "story.md", research: "research/chart.png",
                           expected: "research/chart.png")
    }

    func test_aManuscriptChapterClimbsOnceToResearch() throws {
        try assertResolves(document: "manuscript/ch1.md", research: "research/chart.png",
                           expected: "../research/chart.png")
    }

    func test_aNestedChapterClimbsToItsDepth() throws {
        try assertResolves(document: "manuscript/part-one/ch1.md",
                           research: "research/chart.png",
                           expected: "../../research/chart.png")
    }

    func test_aCollectionPieceReachesItsOwnResearch() throws {
        try assertResolves(document: "pieces/one/one.md",
                           research: "pieces/one/research/chart.png",
                           expected: "research/chart.png")
    }

    // MARK: - R-3a-4 labels

    func test_theLabelIsTheStemLowerCasedWithNonNameCharactersAsDashes() {
        XCTAssertEqual(FigureIngest.figureLabel(stem: "Revenue Chart", existing: []).reference,
                       "fig:revenue-chart")
        XCTAssertEqual(FigureIngest.figureLabel(stem: "2024 Q1 (final)!", existing: []).reference,
                       "fig:2024-q1-final")
        XCTAssertEqual(FigureIngest.figureLabel(stem: "Café über", existing: []).reference,
                       "fig:cafe-uber", "folded to ASCII, not dashed (M4)")
        XCTAssertEqual(FigureIngest.figureLabel(stem: "snake_case", existing: []).reference,
                       "fig:snake_case", "an underscore is a name character")
        XCTAssertEqual(FigureIngest.figureLabel(stem: "__lead", existing: []).reference,
                       "fig:lead", "a name starts with a letter or digit")
        XCTAssertEqual(FigureIngest.figureLabel(stem: "日本", existing: []).reference,
                       "fig:ri-ben", "a non-Latin stem is transliterated")
        XCTAssertEqual(FigureIngest.figureLabel(stem: "!!!", existing: []).reference,
                       "fig:figure", "a stem with no name character at all still names one")
    }

    func test_theLabelIsMadeUniqueByCounting() {
        XCTAssertEqual(FigureIngest.figureLabel(stem: "Chart", existing: ["chart"]).reference,
                       "fig:chart-2")
        XCTAssertEqual(FigureIngest.figureLabel(stem: "Chart",
                                                existing: ["chart", "chart-2", "chart-3"]).reference,
                       "fig:chart-4")
        XCTAssertEqual(FigureIngest.figureLabel(stem: "Chart", existing: ["chart-2"]).reference,
                       "fig:chart", "only a taken name counts")
    }

    func test_theTakenNamesAreThisTextsFiguresAndReferencesAndTheProjectsElsewhere() {
        let text = "![A](research/a.png){#fig:chart}\n\nSee @fig:chart-2.\n\n## H {#sec:chart-3}"
        let elsewhere: Set<ManuscriptLabel> = [ManuscriptLabel(reference: "fig:chart-4")!,
                                               ManuscriptLabel(reference: "tbl:chart-5")!]
        XCTAssertEqual(FigureIngest.existingFigureNames(in: text, elsewhere: elsewhere),
                       ["chart", "chart-2", "chart-4"],
                       "a sec: or tbl: label with the same name does not take a fig: name")
    }

    func test_theFigureLineIsTheSpecForm() {
        let label = ManuscriptLabel(reference: "fig:chart")!
        let line = FigureIngest.figureLine(path: "../research/chart.png", kind: .fig, name: "chart")
        XCTAssertEqual(line, "![Caption](../research/chart.png){#fig:chart}")
        guard case .figure(let caption, let path, let parsed)? = ManuscriptBlocks.parse(line).first?.block
        else { return XCTFail("the line does not parse as a figure") }
        XCTAssertEqual(caption, "Caption")
        XCTAssertEqual(path, "../research/chart.png")
        XCTAssertEqual(parsed, label)
    }

    /// Insert ▸ Table's line (report plan 7b Task 4, R7b-9): the same form,
    /// always labelled `tbl:`, so a table figure numbers as a table.
    func test_aTableFigureLineCarriesATblLabel() {
        let line = FigureIngest.figureLine(path: "figures/table.csv", kind: .tbl, name: "table")
        XCTAssertEqual(line, "![Caption](figures/table.csv){#tbl:table}")
        guard case .figure(_, _, let parsed)? = ManuscriptBlocks.parse(line).first?.block
        else { return XCTFail("the line does not parse as a figure") }
        XCTAssertEqual(parsed, ManuscriptLabel(reference: "tbl:table"))
    }

    func test_theTakenTblNamesAreThisTextsTablesAndReferencesAndTheProjectsElsewhere() {
        let text = "![T](figures/table.csv){#tbl:table}\n\nSee @tbl:table_2 and @fig:table_3."
        let elsewhere: Set<ManuscriptLabel> = [ManuscriptLabel(reference: "tbl:table_4")!,
                                               ManuscriptLabel(reference: "fig:table_5")!]
        XCTAssertEqual(FigureIngest.existingFigureNames(in: text, elsewhere: elsewhere, kind: .tbl),
                       ["table", "table_2", "table_4"],
                       "only tbl: labels take a table figure's name")
    }

    func test_theInsertedTableIsThreeByThreeWithAHeaderRow() {
        let table = FigureIngest.insertedTable()
        XCTAssertEqual(table.rows.count, 3)
        XCTAssertEqual(table.columns.count, 3)
        XCTAssertEqual(table.headerRows, 1)
        XCTAssertFalse(table.hasTotalRow)
    }

    // MARK: - Where the line goes

    private let line = "![Caption](research/c.png){#fig:c}"

    func test_mid_paragraphTheFigureSplitsItOntoABlockOfItsOwn() {
        let edit = FigureIngest.figureEdit(in: "One two.", at: 4, tableBlocks: [], line: line)
        let result = (("One two." as NSString)
            .replacingCharacters(in: edit.replacedRange, with: edit.replacement))
        XCTAssertEqual(result, "One\n\n" + line + "\n\ntwo.")
        XCTAssertEqual((result as NSString).substring(with: edit.selection), "Caption")
    }

    func test_atAParagraphsStartTheFigureGoesAboveIt() {
        let text = "One.\n\nTwo."
        let edit = FigureIngest.figureEdit(in: text, at: 6, tableBlocks: [], line: line)
        let result = (text as NSString).replacingCharacters(in: edit.replacedRange,
                                                            with: edit.replacement)
        XCTAssertEqual(result, "One.\n\n" + line + "\n\nTwo.")
        XCTAssertEqual((result as NSString).substring(with: edit.selection), "Caption")
    }

    func test_insideATableTheFigureGoesAfterIt() {
        let table = "| a | b |\n| - | - |\n| c | d |\nTable: T {#tbl:t}"
        let text = table + "\n\nAfter."
        let blocks = [NSRange(location: 0, length: (table as NSString).length)]
        let edit = FigureIngest.figureEdit(in: text, at: 4, tableBlocks: blocks, line: line)
        let result = (text as NSString).replacingCharacters(in: edit.replacedRange,
                                                            with: edit.replacement)
        XCTAssertEqual(result, table + "\n\n" + line + "\n\nAfter.")
    }

    // MARK: - The async insert point

    func test_untouchedTextKeepsTheOriginalPoint() {
        let anchor = FigureIngest.Anchor(point: 9, in: "One.\n\nTwo three.")
        XCTAssertEqual(anchor.location(in: "One.\n\nTwo three.", caret: 0), 9)
    }

    func test_afterTypingTheFigureGoesToTheStartOfTheParagraphThatHeldThePoint() {
        var anchor = FigureIngest.Anchor(point: 9, in: "One.\n\nTwo three.")
        // The writer typed "Zero. " at the very start of the text (an insert
        // of 6 before the paragraph) and "!" inside the paragraph.
        anchor.noteEdit(editedRange: NSRange(location: 0, length: 6), changeInLength: 6)
        anchor.noteEdit(editedRange: NSRange(location: 16, length: 1), changeInLength: 1)
        let now = "Zero. One.\n\nTwo! three."
        XCTAssertEqual(anchor.location(in: now, caret: 3), 12,
                       "the start of 'Two! three.', shifted by the typing above it")
    }

    func test_ifTheParagraphIsGoneTheFigureGoesToTheCaret() {
        var anchor = FigureIngest.Anchor(point: 9, in: "One.\n\nTwo three.")
        // Select-all and type: the paragraph's start was inside the replaced run.
        anchor.noteEdit(editedRange: NSRange(location: 0, length: 3), changeInLength: 3 - 16)
        XCTAssertEqual(anchor.location(in: "New", caret: 3), 3)
    }

    func test_joiningTheParagraphOntoTheOneAboveSnapsToTheJoinedParagraphsStart() {
        var anchor = FigureIngest.Anchor(point: 9, in: "One.\n\nTwo three.")
        // Delete the blank line between them ("\n\n" at 4..<6 → " ").
        anchor.noteEdit(editedRange: NSRange(location: 4, length: 1), changeInLength: -1)
        XCTAssertEqual(anchor.location(in: "One. Two three.", caret: 0), 0)
    }

    // MARK: - The panel (CLAUDE.md: a value, never a panel the test allocates)

    func test_theInsertFigurePanelTakesOneOrMoreImagesAndNoFolders() {
        XCTAssertEqual(FigureIngest.panelConfiguration,
                       FigureImagePanelConfiguration(allowedContentTypes: [.image, .pdf],
                                                     canChooseFiles: true,
                                                     canChooseDirectories: false,
                                                     allowsMultipleSelection: true,
                                                     prompt: "Insert"))
    }

    // MARK: - The drop decision

    private func file(_ name: String) throws -> URL {
        let url = temp.url.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    func test_anImageDropOnAWritableManuscriptIsAccepted() throws {
        let png = try file("a.png"), jpg = try file("b.jpg")
        XCTAssertEqual(FigureIngest.dropDecision(fileURLs: [png, jpg], answersFigures: true,
                                                 mayWrite: true), .accept([png, jpg]))
    }

    func test_aPDFIsAFigureFileThoughItIsNotAnImage() throws {
        let pdf = try file("chart.pdf")
        XCTAssertFalse(ImagePasteHandler.isIngestableImage(pdf), "the premise: .pdf is not .image")
        XCTAssertEqual(FigureIngest.dropDecision(fileURLs: [pdf], answersFigures: true,
                                                 mayWrite: true), .accept([pdf]))
    }

    func test_onlyTheOutputsFormatsAreKeptAsTheyAre() {
        XCTAssertEqual(FigureIngest.keptExtensions, ["png", "jpg", "jpeg", "gif", "pdf", "svg"])
    }

    /// R-S5: a format the outputs can't show becomes a PNG under the same
    /// stem, in a temporary folder `removeTemporary` takes away; a kept
    /// format is handed back untouched.
    func test_aTIFFIsConvertedToATemporaryPNGThatIsRemovedAfterwards() throws {
        let tiff = temp.url.appendingPathComponent("Site Plan.tiff")
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        try XCTUnwrap(image.tiffRepresentation).write(to: tiff)

        let converted = try FigureIngest.copyableFile(for: tiff)
        XCTAssertTrue(converted.isTemporary)
        XCTAssertEqual(converted.url.lastPathComponent, "Site Plan.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: converted.url.path))
        FigureIngest.removeTemporary(converted.url)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: converted.url.deletingLastPathComponent().path), "its folder is gone")

        let png = try file("kept.png")
        let kept = try FigureIngest.copyableFile(for: png)
        XCTAssertEqual(kept.url, png)
        XCTAssertFalse(kept.isTemporary)
        FigureIngest.removeTemporary(png)
        XCTAssertTrue(FileManager.default.fileExists(atPath: png.path),
                      "removeTemporary never deletes a file it did not write")
    }

    func test_anImageDropOnAReadOnlyManuscriptIsRefused() throws {
        let png = try file("a.png")
        XCTAssertEqual(FigureIngest.dropDecision(fileURLs: [png], answersFigures: true,
                                                 mayWrite: false), .refuse)
    }

    func test_anythingElseKeepsTodaysBehaviour() throws {
        let png = try file("a.png"), txt = try file("notes.txt")
        XCTAssertEqual(FigureIngest.dropDecision(fileURLs: [txt], answersFigures: true,
                                                 mayWrite: true), .notOurs)
        XCTAssertEqual(FigureIngest.dropDecision(fileURLs: [png, txt], answersFigures: true,
                                                 mayWrite: true), .notOurs,
                       "a mixed drop is not a figure drop")
        XCTAssertEqual(FigureIngest.dropDecision(fileURLs: [], answersFigures: true,
                                                 mayWrite: true), .notOurs)
        XCTAssertEqual(FigureIngest.dropDecision(fileURLs: [png], answersFigures: false,
                                                 mayWrite: true), .notOurs,
                       "a research note or statement keeps its own behaviour")
    }
}
