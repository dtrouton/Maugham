import XCTest
import PDFKit
@testable import Maugham

/// End-to-end guard for the body-emitter overhaul: compiles a markdown-rich
/// prose piece plus an anchor-bearing screenplay through the REAL PDFCompiler
/// and asserts the rendered PDF text contains the words but NOT the raw
/// markdown markers or op-log anchors. The original bug only surfaced in the
/// rendered PDF, never in emitter unit tests — this closes that gap.
final class PublishBodyRenderingEndToEndTests: XCTestCase {

    var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PublishBodyE2E-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try await PublishStarter.install(into: tmp, force: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testRenderedPDF_hasFormattingNotRawMarkdownOrAnchors() async throws {
        // Same tectonic-availability guard the compiler uses.
        let testBundlePath = Bundle(for: type(of: self)).bundlePath
        let appPath = testBundlePath.replacingOccurrences(
            of: "/Contents/PlugIns/MaughamTests.xctest", with: "")
        guard (try? TectonicLocator.locateInBundle(
            at: URL(fileURLWithPath: appPath))) != nil else {
            throw XCTSkip("tectonic binary not bundled in test host")
        }

        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [
                    .init(pieceID: "p1", title: "Tribute", mode: .prose,
                          displayText: """
                          This has *italicword* and **boldword** in it.

                          ## Dayheading

                          More prose follows the heading.

                          > Quotedline inside a blockquote.
                          """),
                    .init(pieceID: "p2", title: "Good Luck Babe", mode: .fountain,
                          displayText: "<!-- ¶abcd -->Aaron pours coffee."),
                ]
            }
        }

        let cfg = PublishConfig(metadata: .init(title: "Playlist", author: "Tester"))
        let compiler = try PDFCompiler(
            projectURL: tmp,
            astSource: Src(),
            config: cfg,
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test")

        let result = try await compiler.compile(label: nil)
        XCTAssertTrue(result.errors.isEmpty, "errors: \(result.errors.map(\.message))")

        let text = Self.extractText(from: URL(fileURLWithPath: result.outputPath))
        XCTAssertFalse(text.isEmpty, "no text extracted from PDF")

        // Words survive (formatting applied, content preserved).
        XCTAssertTrue(text.contains("italicword"), "italic content missing")
        XCTAssertTrue(text.contains("boldword"), "bold content missing")
        XCTAssertTrue(text.contains("Dayheading"), "heading content missing")
        XCTAssertTrue(text.contains("Quotedline"), "blockquote content missing")
        XCTAssertTrue(text.contains("Aaron pours coffee"), "screenplay action missing")

        // Raw syntax never leaks into the rendered artifact.
        XCTAssertFalse(text.contains("*"), "literal asterisk leaked: \(text)")
        XCTAssertFalse(text.contains("##"), "literal ATX marker leaked: \(text)")
        XCTAssertFalse(text.contains("<!--"), "HTML-comment anchor leaked: \(text)")
        XCTAssertFalse(text.contains("¶"), "paragraph-anchor pilcrow leaked: \(text)")
    }

    private static func extractText(from url: URL) -> String {
        guard let doc = PDFDocument(url: url) else { return "" }
        var s = ""
        for i in 0..<doc.pageCount {
            s += doc.page(at: i)?.string ?? ""
        }
        return s
    }
}
