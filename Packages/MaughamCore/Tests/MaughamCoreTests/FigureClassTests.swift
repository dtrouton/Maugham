import Foundation
import XCTest
@testable import MaughamCore

/// **Which stream is a figure, and whose** (report plan 6a Task 2, ruling D-b;
/// Denver's ruling of 2026-10-24: a figure belongs to the piece it was created
/// in). The registry decides the piece; the id's prefix keeps a figure the
/// registry lost from ever being read as a piece.
final class FigureClassTests: XCTestCase {

    private static let record = FigureRecord(
        id: "fig-1a2b3c4d", name: "cashflow", kind: .table,
        piece: "d_chapter1", path: "figures/cashflow.csv")

    private func manifest(figures: [FigureRecord]?) -> ProjectManifest {
        ProjectManifest(
            type: .novel, title: "Book", author: "Denver",
            created: Date(timeIntervalSince1970: 0), modified: Date(timeIntervalSince1970: 0),
            structure: [
                StructureItem(id: "d_chapter1", title: "Chapter One", type: .document,
                              path: "manuscript/chapter1.md")
            ],
            research: [],
            figures: figures)
    }

    // MARK: - Resolution

    func test_aRegisteredFigureIsItsPiecesFigure() {
        XCTAssertEqual(
            DocumentClass.resolve(docId: "fig-1a2b3c4d", manifest: manifest(figures: [Self.record])),
            .figure(id: "fig-1a2b3c4d", piece: "d_chapter1"))
    }

    func test_aRegisteredFigureOfNoPieceIsTheWholeBooks() {
        var bookWide = Self.record
        bookWide.piece = nil
        XCTAssertEqual(
            DocumentClass.resolve(docId: "fig-1a2b3c4d", manifest: manifest(figures: [bookWide])),
            .figure(id: "fig-1a2b3c4d", piece: nil))
    }

    /// **The registry lost it — and it is still a figure, the book's.** Never
    /// `.piece`: a scoped author's figure would be nobody's, and the deriver
    /// would read its stream as prose.
    func test_aFigureIdTheRegistryDoesNotCarryIsAFigureOfTheWholeBook() {
        for figures in [nil, [], [Self.record]] as [[FigureRecord]?] {
            XCTAssertEqual(
                DocumentClass.resolve(docId: "fig-99999999", manifest: manifest(figures: figures)),
                .figure(id: "fig-99999999", piece: nil))
        }
    }

    func test_anIdThatIsNotAFigureIsUntouched() {
        let m = manifest(figures: [Self.record])
        XCTAssertEqual(DocumentClass.resolve(docId: "d_chapter1", manifest: m), .piece("d_chapter1"))
        XCTAssertEqual(DocumentClass.resolve(docId: "doc-1a2b3c4d", manifest: m), .piece("doc-1a2b3c4d"))
        XCTAssertEqual(DocumentClass.resolve(docId: "figure", manifest: m), .piece("figure"),
                       "the prefix is `fig-`, dash and all")
        XCTAssertEqual(DocumentClass.resolve(docId: "__project__", manifest: m), .projectStream)
        XCTAssertEqual(DocumentClass.figureDocIdPrefix, "fig")
    }

    /// The facts a looping reader hands over are the manifest's — both halves.
    func test_theFactsCarryTheFiguresAsWellAsTheStatements() {
        let facts = DocumentClass.Facts(manifest(figures: [Self.record]))
        XCTAssertEqual(facts.figures, [Self.record])
        XCTAssertEqual(
            DocumentClass.resolve(docId: "fig-1a2b3c4d", facts: facts),
            .figure(id: "fig-1a2b3c4d", piece: "d_chapter1"))
        XCTAssertEqual(DocumentClass.Facts(manifest(figures: nil)).figures, [])
    }

    /// The one-URL door reads the registry off disk.
    func test_theDiskDoorReadsTheRegistry() throws {
        let root = TestTemp.root
        try ProjectManifest.encodeForDisk(manifest(figures: [Self.record]))
            .write(to: root.appendingPathComponent(ProjectManifest.fileName))
        XCTAssertEqual(
            OpLogStore.documentClass(forDocId: "fig-1a2b3c4d", in: root),
            .figure(id: "fig-1a2b3c4d", piece: "d_chapter1"))
        XCTAssertEqual(
            ManifestPlacement(docId: "fig-1a2b3c4d", in: root).documentClass,
            .figure(id: "fig-1a2b3c4d", piece: "d_chapter1"))
    }

    // MARK: - The manifest's bytes

    /// **A book with no figures keeps its bytes**: no `figures` key, whether
    /// the registry is nil or empty.
    func test_aManifestWithoutFiguresEncodesByteIdentically() throws {
        let golden = try ProjectManifest.encodeForDisk(manifest(figures: nil))
        XCTAssertEqual(try ProjectManifest.encodeForDisk(manifest(figures: [])), golden)
        let text = try XCTUnwrap(String(data: golden, encoding: .utf8))
        XCTAssertFalse(text.contains("figures"), text)
        XCTAssertEqual(text, """
            {
              "author" : "Denver",
              "coachVacated" : false,
              "created" : "1970-01-01T00:00:00Z",
              "modified" : "1970-01-01T00:00:00Z",
              "productionRoles" : [

              ],
              "research" : [

              ],
              "reviewPasses" : [

              ],
              "schemaVersion" : 10,
              "statements" : [

              ],
              "structure" : [
                {
                  "id" : "d_chapter1",
                  "path" : "manuscript\\/chapter1.md",
                  "title" : "Chapter One",
                  "type" : "document"
                }
              ],
              "title" : "Book",
              "type" : "novel"
            }
            """)
    }

    /// **A kind word from a later build never shuts the book** (ADR 0015,
    /// ruling R-6a-3): the manifest decodes, the record keeps the word, and a
    /// re-save writes the same bytes back.
    func test_aFigureOfAnUnknownKindDecodesAndReEncodesByteIdentically() throws {
        var chart = Self.record
        chart.kind = .unknown("chart")
        let original = try ProjectManifest.encodeForDisk(manifest(figures: [chart]))
        let text = try XCTUnwrap(String(data: original, encoding: .utf8))
        XCTAssertTrue(text.contains(#""kind" : "chart""#), text)
        let decoded = try ProjectManifest.decodeGuardingSchema(original)
        XCTAssertEqual(decoded.figures?.first?.kind, .unknown("chart"))
        XCTAssertEqual(try ProjectManifest.encodeForDisk(decoded), original)
        XCTAssertEqual(DocumentClass.resolve(docId: chart.id, manifest: decoded),
                       .figure(id: chart.id, piece: "d_chapter1"),
                       "whose figure it is does not turn on what it is")
    }

    func test_aManifestWithFiguresRoundTripsThem() throws {
        var bookWide = Self.record
        bookWide.id = "fig-00000001"
        bookWide.piece = nil
        bookWide.kind = .image
        bookWide.path = "figures/map.png"
        let original = manifest(figures: [Self.record, bookWide])
        let data = try ProjectManifest.encodeForDisk(original)
        let decoded = try ProjectManifest.decodeGuardingSchema(data)
        XCTAssertEqual(decoded.figures, [Self.record, bookWide])
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"figures\""), text)
    }
}
