import XCTest
import PDFKit
import MaughamCore
@testable import Maugham

/// **A piece's first paragraph, found in the typeset book** (shell p4 Task 5):
/// a real compile through the bundled tectonic, then `PDFAnchors` reads the
/// named destinations the `\hypertarget`s became.
@MainActor
final class PDFAnchorsTests: XCTestCase {

    private var tmp: URL!

    override func setUp() async throws {
        try await TectonicProbe.requireReady()
        tmp = TestTemp.root.appendingPathComponent("PDFAnchors-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try await PublishStarter.install(into: tmp, force: false)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Three chapters, each long enough to fill more than a page, so each
    /// starts on a page of its own and the anchors have somewhere to differ.
    private struct ThreeChapters: ProjectASTBuilder.Source {
        static let chapters: [(id: String, title: String, ids: [String])] = [
            ("c1", "One", ["aaaa", "aaab", "aaac"]),
            ("c2", "Two", ["bbba", "bbbb", "bbbc"]),
            ("c3", "Three", ["ccca", "cccb", "cccc"]),
        ]
        static func text(_ chapter: Int, _ paragraph: Int) -> String {
            Array(repeating: "Chapter \(chapter) paragraph \(paragraph) runs on and on.",
                  count: 40).joined(separator: " ")
        }
        func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
            Self.chapters.enumerated().map { index, chapter in
                let rows = chapter.ids.enumerated().map { (id: $1, text: Self.text(index, $0)) }
                return .init(pieceID: chapter.id, title: chapter.title, mode: .prose,
                             displayText: rows.map(\.text).joined(separator: "\n\n"),
                             paragraphs: rows)
            }
        }
    }

    private func compiledBook() async throws -> PDFDocument {
        var cfg = PublishConfig(metadata: .init(title: "Anchors", author: "Tester"))
        cfg.metadata.language = "en"
        let compiler = try PDFCompiler(
            projectURL: tmp, astSource: ThreeChapters(), config: cfg,
            jobManager: CompileJobManager(), maughamVersion: "0.0.0-test")
        let result = try await compiler.compile(label: nil)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors.map(\.message))\n\(result.logExcerpt)")
        let document = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: result.outputPath)),
                                     result.logExcerpt)
        return document
    }

    func test_aDestinationNamedForAPiecesFirstParagraphGivesItsPage() async throws {
        let book = try await compiledBook()
        let pages = ThreeChapters.chapters.map { chapter in
            PDFAnchors.pageIndex(
                of: PDFAnchors.pieceAnchors(docId: chapter.id, bodyTag: "en", sequence: chapter.ids),
                in: book)
        }
        let found = pages.compactMap { $0 }
        XCTAssertEqual(found.count, 3, "every chapter's first paragraph resolves: \(pages)")
        XCTAssertEqual(found, found.sorted(), "the chapters land in reading order: \(pages)")
        XCTAssertEqual(Set(found).count, 3, "each chapter starts on its own page: \(pages)")
        XCTAssertLessThan(found.last ?? .max, book.pageCount)

        // The file-taking door, which the centre calls off the main actor,
        // answers the same.
        let url = try XCTUnwrap(book.documentURL)
        XCTAssertEqual(PDFAnchors.pageIndex(
            of: PDFAnchors.pieceAnchors(docId: "c3", bodyTag: "en", sequence: ["ccca"]),
            inFileAt: url), found.last)
    }

    func test_aPieceWithNoAnchorAnswersNil() async throws {
        let book = try await compiledBook()
        // Another body's tag, and an id no paragraph has.
        XCTAssertNil(PDFAnchors.pageIndex(
            of: PDFAnchors.pieceAnchors(docId: "c1", bodyTag: "sr", sequence: ["aaaa"]), in: book))
        XCTAssertNil(PDFAnchors.pageIndex(
            of: PDFAnchors.pieceAnchors(docId: "c9", bodyTag: "en", sequence: ["zzzz"]), in: book))
        XCTAssertNil(PDFAnchors.pageIndex(of: [], in: book))
        // The first name that resolves wins: a missing lead is passed over.
        XCTAssertEqual(
            PDFAnchors.pageIndex(of: ["p-en-zzzz", "p-en-bbbb"], in: book),
            PDFAnchors.pageIndex(of: ["p-en-bbbb"], in: book))
        XCTAssertNotNil(PDFAnchors.pageIndex(of: ["p-en-bbbb"], in: book))
    }

    func test_theAnchorNamesAreTheContractsShape() {
        XCTAssertEqual(PDFAnchors.pieceAnchors(docId: "c1", bodyTag: "sr", sequence: ["k3wq", "m2ab"]),
                       ["p-sr-k3wq", "p-sr-m2ab"])
    }
}
