import XCTest
@testable import MaughamCore

/// Pins `ProjectType`'s capability answers (`ProjectType+Capabilities.swift`)
/// for every case, `.unknown` included (ADR 0015).
final class ProjectTypeCapabilityTests: XCTestCase {

    private struct Row {
        let type: ProjectType
        let primaryFormat: DocumentFormat
        let holdsPieces: Bool
        let symbolName: String
    }

    private let table: [Row] = [
        Row(type: .shortStory, primaryFormat: .markdown, holdsPieces: false, symbolName: "doc.text"),
        Row(type: .novel, primaryFormat: .markdown, holdsPieces: false, symbolName: "book.closed"),
        Row(type: .screenplay, primaryFormat: .fountain, holdsPieces: false, symbolName: "film"),
        Row(type: .collection, primaryFormat: .markdown, holdsPieces: true, symbolName: "books.vertical"),
        Row(type: .unknown, primaryFormat: .markdown, holdsPieces: false, symbolName: "questionmark.folder"),
    ]

    func test_everyCase_answersEveryCapability() {
        let cases = ProjectType.allCases + [.unknown]
        XCTAssertEqual(table.map(\.type), cases, "the table covers every case, .unknown included")
        for row in table {
            XCTAssertEqual(row.type.primaryFormat, row.primaryFormat, "\(row.type).primaryFormat")
            XCTAssertEqual(row.type.holdsPieces, row.holdsPieces, "\(row.type).holdsPieces")
            XCTAssertEqual(row.type.symbolName, row.symbolName, "\(row.type).symbolName")
        }
    }

    func test_forPromotedPiece_mapsEachFormatToItsKind() {
        XCTAssertEqual(ProjectType.forPromotedPiece(format: .fountain), .screenplay)
        XCTAssertEqual(ProjectType.forPromotedPiece(format: .markdown), .shortStory)
    }
}
