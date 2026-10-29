import XCTest
@testable import MaughamCore

/// Pins `ProjectType`'s capability answers (`ProjectType+Capabilities.swift`)
/// for every case, `.unknown` included (ADR 0015).
final class ProjectTypeCapabilityTests: XCTestCase {

    private struct Row {
        let type: ProjectType
        let primaryFormat: DocumentFormat
        let holdsPieces: Bool
        let holdsFigures: Bool
        let symbolName: String
    }

    private let table: [Row] = [
        Row(type: .shortStory, primaryFormat: .markdown, holdsPieces: false, holdsFigures: true, symbolName: "doc.text"),
        Row(type: .novel, primaryFormat: .markdown, holdsPieces: false, holdsFigures: true, symbolName: "book.closed"),
        Row(type: .screenplay, primaryFormat: .fountain, holdsPieces: false, holdsFigures: false, symbolName: "film"),
        Row(type: .collection, primaryFormat: .markdown, holdsPieces: true, holdsFigures: true, symbolName: "books.vertical"),
        Row(type: .unknown, primaryFormat: .markdown, holdsPieces: false, holdsFigures: false, symbolName: "questionmark.folder"),
    ]

    func test_everyCase_answersEveryCapability() {
        let cases = ProjectType.allCases + [.unknown]
        XCTAssertEqual(table.map(\.type), cases, "the table covers every case, .unknown included")
        for row in table {
            XCTAssertEqual(row.type.primaryFormat, row.primaryFormat, "\(row.type).primaryFormat")
            XCTAssertEqual(row.type.holdsPieces, row.holdsPieces, "\(row.type).holdsPieces")
            XCTAssertEqual(row.type.holdsFigures, row.holdsFigures, "\(row.type).holdsFigures")
            XCTAssertEqual(row.type.symbolName, row.symbolName, "\(row.type).symbolName")
        }
    }

    /// The two rewrites plan 7 Task 8 made at every kind site, stated as the
    /// identities they rely on: `holdsPieces` is exactly "is a collection", and
    /// `primaryFormat.isScreenplay` is exactly "is a screenplay" — for every
    /// case, `.unknown` included.
    func test_theCapabilityPredicatesAnswerExactlyWhatTheEqualitiesDid() {
        for type in ProjectType.allCases + [.unknown] {
            XCTAssertEqual(type.holdsPieces, type == .collection, "\(type).holdsPieces")
            XCTAssertEqual(type.primaryFormat.isScreenplay, type == .screenplay,
                           "\(type).primaryFormat.isScreenplay")
        }
    }

    func test_forPromotedPiece_mapsEachFormatToItsKind() {
        XCTAssertEqual(ProjectType.forPromotedPiece(format: .fountain), .screenplay)
        XCTAssertEqual(ProjectType.forPromotedPiece(format: .markdown), .shortStory)
    }
}
