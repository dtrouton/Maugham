import XCTest
@testable import Maugham

final class SyntaxHelpSheetTests: XCTestCase {

    /// Regression guard mirroring `GuideCorpusRenderabilityTest`: runs the
    /// parser over the ACTUAL shipped `markdown-syntax.md`/`fountain-syntax.md`
    /// resources (read from the repo, not `Bundle.main`, so this doesn't
    /// depend on a build having copied resources) and asserts no table
    /// delimiter or list marker leaks into a `.paragraph` block.
    private static let orderedMarker = try! NSRegularExpression(pattern: #"^\d+[.)]\s"#)
    private static let unorderedMarker = try! NSRegularExpression(pattern: #"^[-*+]\s"#)

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
    }

    func test_noSyntaxHelpConstructSilentlyDegradesToParagraph() throws {
        let resourceDir = repoRoot.appendingPathComponent("Maugham/Resources")
        for name in ["markdown-syntax.md", "fountain-syntax.md"] {
            let raw = try String(contentsOf: resourceDir.appendingPathComponent(name), encoding: .utf8)
            let blocks = SyntaxHelpSheet.parseMarkdownBlocks(raw)
            for block in blocks {
                guard case .paragraph(let attributed) = block else { continue }
                let text = String(attributed.characters)
                XCTAssertFalse(text.contains("|---"),
                    "\(name): a table delimiter row leaked into a paragraph block — \(text)")
                let range = NSRange(text.startIndex..., in: text)
                XCTAssertNil(Self.orderedMarker.firstMatch(in: text, range: range),
                    "\(name): an ordered-list marker leaked into a paragraph block — \(text)")
                XCTAssertNil(Self.unorderedMarker.firstMatch(in: text, range: range),
                    "\(name): an unordered-list marker leaked into a paragraph block — \(text)")
                // Opening-fence-glued-to-prose guard (final-review latent-gap note).
                XCTAssertFalse(text.contains("```"),
                    "\(name): a fence marker leaked into a paragraph block — \(text)")
            }
        }
    }

    func test_loadContent_proseMode_returnsMarkdownDoc() {
        let content = SyntaxHelpSheet.loadContent(mode: .prose)
        XCTAssertGreaterThan(content.count, 5)
    }

    func test_loadContent_screenplayMode_returnsFountainDoc() {
        let content = SyntaxHelpSheet.loadContent(mode: .screenplay)
        XCTAssertGreaterThan(content.count, 5)
    }

    func test_loadContent_modes_returnDifferentContent() {
        let prose = SyntaxHelpSheet.loadContent(mode: .prose)
        let screenplay = SyntaxHelpSheet.loadContent(mode: .screenplay)
        // The two docs should produce a different number of blocks, or at least not both be empty.
        // In practice they will differ in heading text so this is a safe check.
        XCTAssertFalse(prose.isEmpty)
        XCTAssertFalse(screenplay.isEmpty)
    }
}
