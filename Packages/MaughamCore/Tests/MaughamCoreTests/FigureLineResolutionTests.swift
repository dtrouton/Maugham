import XCTest
@testable import MaughamCore

final class FigureLineResolutionTests: XCTestCase {

    private func rec(_ id: String, _ path: String, kind: FigureKind = .table) -> FigureRecord {
        FigureRecord(id: id, name: id, kind: kind, piece: nil, path: path)
    }

    func test_pieceFolderLineReachesFigureRecord() {
        let r = rec("fig-00000001", "figures/x.csv")
        XCTAssertEqual(
            FigureLineResolution.record(forLinePath: "../../figures/x.csv",
                documentPath: "pieces/p1/x.md", records: [r]), .figure(r))
    }

    func test_rootLevelDocumentAndDotSlash() {
        let r = rec("fig-00000001", "figures/x.csv")
        XCTAssertEqual(FigureLineResolution.record(forLinePath: "figures/x.csv",
            documentPath: "story.md", records: [r]), .figure(r))
        XCTAssertEqual(FigureLineResolution.record(forLinePath: "./figures/x.csv",
            documentPath: "story.md", records: [r]), .figure(r))
        XCTAssertEqual(FigureLineResolution.record(forLinePath: "../figures/x.csv",
            documentPath: "manuscript/ch1.md", records: [r]), .figure(r))
    }

    func test_caseInsensitive() {
        let r = rec("fig-00000001", "figures/Cash.CSV")
        XCTAssertEqual(FigureLineResolution.record(forLinePath: "figures/cash.csv",
            documentPath: "story.md", records: [r]), .figure(r))
    }

    func test_twoRecordsOnOnePathAreAmbiguous() {
        let a = rec("fig-00000001", "figures/x.csv"), b = rec("fig-00000002", "figures/X.csv")
        XCTAssertEqual(FigureLineResolution.record(forLinePath: "figures/x.csv",
            documentPath: "story.md", records: [a, b]), .ambiguous([a, b]))
    }

    func test_percentEncodedNamesAreNotDecoded() {
        let plain = rec("fig-00000001", "figures/my fig.png", kind: .image)
        let literal = rec("fig-00000002", "figures/my%20fig.png", kind: .image)
        XCTAssertEqual(FigureLineResolution.record(forLinePath: "figures/my%20fig.png",
            documentPath: "story.md", records: [plain, literal]), .figure(literal))
        XCTAssertEqual(FigureLineResolution.record(forLinePath: "figures/my%20fig.png",
            documentPath: "story.md", records: [plain]), .none)
    }

    func test_escapesAndForeignFoldersAreNone() {
        let r = rec("fig-00000001", "figures/x.csv")
        for (line, doc) in [("../../figures/x.csv", "story.md"),
                            ("/figures/x.csv", "story.md"),
                            ("file:figures/x.csv", "story.md"),
                            ("https://a/figures/x.csv", "story.md"),
                            ("notes/x.csv", "story.md"),
                            ("../../../figures/x.csv", "pieces/p1/x.md")] {
            XCTAssertEqual(FigureLineResolution.record(forLinePath: line,
                documentPath: doc, records: [r]), .none, line)
        }
    }

    func test_noRecordIsNone() {
        XCTAssertEqual(FigureLineResolution.record(forLinePath: "figures/x.csv",
            documentPath: "story.md", records: []), .none)
    }

    func test_lexicalRule() {
        XCTAssertEqual(FigurePathRule.lexical("../research/a.png", piecePath: "manuscript/ch1.md"),
                       .inside(target: ["research", "a.png"], root: ["research"]))
        XCTAssertEqual(FigurePathRule.lexical("research/a.png", piecePath: "pieces/p1/x.md"),
                       .inside(target: ["pieces", "p1", "research", "a.png"],
                               root: ["pieces", "p1", "research"]))
        XCTAssertEqual(FigurePathRule.lexical("../p2/research/a.png", piecePath: "pieces/p1/x.md"), .notLocal)
    }
}
