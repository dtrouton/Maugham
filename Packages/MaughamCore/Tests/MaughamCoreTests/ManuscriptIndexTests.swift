import XCTest
@testable import MaughamCore

/// The project index: labels, cited keys and diagnostics across documents.
final class ManuscriptIndexTests: XCTestCase {

    private func label(_ reference: String) -> ManuscriptLabel {
        ManuscriptLabel(reference: reference)!
    }

    private func diag(_ kind: ManuscriptDiagnostic.Kind, _ doc: String, _ line: Int)
        -> ManuscriptDiagnostic {
        ManuscriptDiagnostic(kind: kind, docID: doc, line: line)
    }

    // MARK: - Review focus 5: one bad element must not hide the rest

    /// Every element of a healthy document, indexed with no diagnostics.
    private let healthy = [
        "# Introduction {#sec:intro}",          // 0
        "",                                     // 1
        "Revenue grew[^1] as @fig:rev shows [@smith, p. 4].", // 2
        "",                                     // 3
        "![Revenue](../research/rev.png){#fig:rev}", // 4
        "",                                     // 5
        "| Q | Sales |",                        // 6
        "|---|---|",                            // 7
        "| 3 | 10 |",                           // 8
        "Table: Quarterly sales {#tbl:q}",      // 9
        "",                                     // 10
        "See @tbl:q and @sec:intro.",           // 11
        "",                                     // 12
        "[^1]: A note citing [@jones].",        // 13
    ]

    private func index(_ lines: [String], keys: Set<String> = ["smith", "jones"])
        -> ManuscriptIndex {
        ManuscriptIndex(docs: [.init(id: "a", text: lines.joined(separator: "\n"))],
                        citationKeys: keys)
    }

    private func assertHealthyLabelsIndexed(_ idx: ManuscriptIndex,
                                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(idx.labels[label("sec:intro")]?.line, 0, file: file, line: line)
        XCTAssertEqual(idx.labels[label("fig:rev")]?.line, 4, file: file, line: line)
        XCTAssertEqual(idx.labels[label("tbl:q")]?.line, 9, file: file, line: line)
        XCTAssertEqual(idx.labels[label("fig:rev")]?.docID, "a", file: file, line: line)
        XCTAssertEqual(idx.citedKeys, ["smith", "jones"], file: file, line: line)
    }

    func test_focus5_theHealthyDocumentIndexesEverythingWithNoDiagnostic() {
        let idx = index(healthy)
        assertHealthyLabelsIndexed(idx)
        XCTAssertEqual(idx.labels.count, 3)
        XCTAssertEqual(idx.diagnostics, [])
    }

    func test_focus5_aMalformedFigureLineGivesOneDiagnostic() {
        let idx = index(healthy + ["", "![Broken](x.png){#fig:}"])  // line 15
        assertHealthyLabelsIndexed(idx)
        XCTAssertEqual(idx.diagnostics, [diag(.malformedLabel("{#fig:}"), "a", 15)])
    }

    func test_focus5_anUnknownKindOnAFigureLineGivesOneDiagnostic() {
        let idx = index(healthy + ["", "![Eq](eq.png) {#eq:x}"])
        assertHealthyLabelsIndexed(idx)
        XCTAssertEqual(idx.diagnostics, [diag(.malformedLabel("{#eq:x}"), "a", 15)])
    }

    func test_focus5_malformedHeadingAndCaptionLabels() {
        let idx = index(healthy + ["", "## Methods {#sec:}", "",
                                   "| a |", "|---|", "Table: Bad {#tbl:a b}"])
        assertHealthyLabelsIndexed(idx)
        XCTAssertEqual(idx.diagnostics, [diag(.malformedLabel("{#sec:}"), "a", 15),
                                         diag(.malformedLabel("{#tbl:a b}"), "a", 19)])
    }

    func test_focus5_anUnreferencedFootnoteDefinitionGivesOneDiagnostic() {
        let idx = index(healthy + ["[^orphan]: Nobody points here."])  // line 14
        assertHealthyLabelsIndexed(idx)
        XCTAssertEqual(idx.diagnostics,
                       [diag(.unusedFootnoteDefinition(label: "orphan"), "a", 14)])
    }

    func test_focus5_aDuplicateLabelGivesOneDiagnostic() {
        let idx = index(healthy + ["", "![Again](again.png){#fig:rev}"])
        assertHealthyLabelsIndexed(idx)
        XCTAssertEqual(idx.diagnostics, [diag(.duplicateLabel(label("fig:rev")), "a", 15)])
    }

    func test_focus5_aWrongKindLabelGivesOneDiagnosticAndIsNotRegistered() {
        let idx = index(healthy + ["", "## Results {#fig:results}"])
        assertHealthyLabelsIndexed(idx)
        XCTAssertNil(idx.labels[label("fig:results")])
        XCTAssertEqual(idx.diagnostics,
                       [diag(.labelOnWrongElement(label("fig:results")), "a", 15)])
    }

    // MARK: - Each other diagnostic

    func test_unresolvedCrossReferenceAndUnknownKey() {
        let idx = index(["See @fig:nope and [@ghost; @smith]."])
        XCTAssertEqual(idx.diagnostics, [diag(.unresolvedCrossRef(label("fig:nope")), "a", 0),
                                         diag(.unknownCitationKey("ghost"), "a", 0)])
        XCTAssertEqual(idx.citedKeys, ["ghost", "smith"])
    }

    func test_footnoteDiagnostics() {
        let idx = index(["One[^1] two[^2].", "", "[^1]: First.", "[^1]: Again."])
        XCTAssertEqual(idx.diagnostics,
                       [diag(.missingFootnoteDefinition(label: "2"), "a", 0),
                        diag(.duplicateFootnoteDefinition(label: "1"), "a", 3)])
    }

    func test_footnotesAreScopedPerDocument() {
        let idx = ManuscriptIndex(docs: [.init(id: "a", text: "Ref[^1]."),
                                         .init(id: "b", text: "[^1]: Def in b.")],
                                  citationKeys: [])
        XCTAssertEqual(idx.diagnostics,
                       [diag(.missingFootnoteDefinition(label: "1"), "a", 0),
                        diag(.unusedFootnoteDefinition(label: "1"), "b", 0)])
    }

    func test_figurePathsThatAreNotLocal() {
        let idx = index(["![Web](https://example.com/a.png)", "",
                         "![Abs](/Users/x/a.png)", "",
                         "![Ok](../research/a.png)"])
        XCTAssertEqual(idx.diagnostics,
                       [diag(.figurePathNotLocal("https://example.com/a.png"), "a", 0),
                        diag(.figurePathNotLocal("/Users/x/a.png"), "a", 2)])
    }

    func test_nothingInsideAFenceIsScanned() {
        let idx = index(["```", "@fig:nope [@ghost] [^9]", "![X](/abs.png){#fig:}", "```"])
        XCTAssertEqual(idx.diagnostics, [])
        XCTAssertEqual(idx.citedKeys, [])
    }

    func test_aMarkerOnAContinuationLineReportsThatLine() {
        let idx = index(["First line,", "second @fig:nope line."])
        XCTAssertEqual(idx.diagnostics, [diag(.unresolvedCrossRef(label("fig:nope")), "a", 1)])
    }

    // MARK: - Two documents

    func test_docBCrossReferencesDocAsFigure() {
        let a = "# Part A\n\n![Chart](../research/c.png){#fig:chart}"
        let b = "As @fig:chart shows, and again [@fig:chart]."
        let idx = ManuscriptIndex(docs: [.init(id: "A", text: a), .init(id: "B", text: b)],
                                  citationKeys: [])
        XCTAssertEqual(idx.labels[label("fig:chart")]?.docID, "A")
        XCTAssertEqual(idx.labels[label("fig:chart")]?.line, 2)
        XCTAssertEqual(idx.diagnostics, [])
    }

    func test_aDuplicateAcrossDocumentsNamesTheSecondDocAndFirstWins() {
        let idx = ManuscriptIndex(docs: [.init(id: "A", text: "# A {#sec:x}"),
                                         .init(id: "B", text: "\n# B {#sec:x}")],
                                  citationKeys: [])
        XCTAssertEqual(idx.labels[label("sec:x")]?.docID, "A")
        XCTAssertEqual(idx.diagnostics, [diag(.duplicateLabel(label("sec:x")), "B", 1)])
    }

    func test_diagnosticsAreInDocThenLineOrder() {
        // The unresolved reference (found after the pass) sits on line 0,
        // ahead of the missing-definition diagnostic on line 2.
        let idx = ManuscriptIndex(docs: [.init(id: "A", text: "@sec:gone\n\nx[^1]"),
                                         .init(id: "B", text: "[@nokey]")],
                                  citationKeys: [])
        XCTAssertEqual(idx.diagnostics,
                       [diag(.unresolvedCrossRef(label("sec:gone")), "A", 0),
                        diag(.missingFootnoteDefinition(label: "1"), "A", 2),
                        diag(.unknownCitationKey("nokey"), "B", 0)])
    }
}
