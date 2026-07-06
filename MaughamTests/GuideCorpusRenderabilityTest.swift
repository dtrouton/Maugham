import XCTest
@testable import Maugham

/// Permanent regression guard for audit finding A3 (Help window mis-renders
/// shipped guide content): runs `GuideMarkdownView`'s parser over EVERY file
/// in the shipped `docs/guide/*.md` corpus and asserts no construct silently
/// degrades into a paragraph.
///
/// Heuristic (deliberately narrow, not a full CommonMark conformance check):
/// a `.paragraph` block should never contain a raw table delimiter row
/// (`|---`) or start with an ordered-list marker (`1.` / `1)`). Either
/// pattern surfacing inside a `.paragraph` means the table or ordered-list
/// parser failed to claim a construct the corpus actually uses — exactly how
/// A3 was originally found (reference.md's table, claude-desktop.md's steps).
/// If a future guide page adds a NEW construct outside this parser's subset,
/// prefer teaching the parser (or rewriting the page to its documented
/// subset) over loosening this heuristic.
final class GuideCorpusRenderabilityTest: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
    }

    private static let orderedMarker = try! NSRegularExpression(pattern: #"^\d+[.)]\s"#)
    /// Unordered markers (`- `, `* `, `+ `) — the shared parser's paragraph
    /// loop doesn't break on a list marker mid-accumulation (unlike heading/
    /// thematic-break/quote), so a bullet glued directly to a preceding text
    /// line with no blank line in between gets swallowed into that paragraph
    /// (exactly how the `claude-desktop.md` "Read:"/"Write:" sections were
    /// found and fixed — see task-7 report). Guarded here permanently.
    private static let unorderedMarker = try! NSRegularExpression(pattern: #"^[-*+]\s"#)

    func test_noGuideConstructSilentlyDegradesToParagraph() throws {
        let guideDir = repoRoot.appendingPathComponent("docs/guide")
        let mdFiles = try FileManager.default
            .contentsOfDirectory(at: guideDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(mdFiles.isEmpty, "expected at least one docs/guide/*.md file")

        for file in mdFiles {
            let md = try String(contentsOf: file, encoding: .utf8)
            let blocks = GuideMarkdownView.parse(md)
            for block in blocks {
                guard case .paragraph(let text) = block else { continue }
                XCTAssertFalse(text.contains("|---"),
                    "\(file.lastPathComponent): a table delimiter row leaked into a paragraph block " +
                    "(pipe table not claimed by the table parser) — \(text)")
                let range = NSRange(text.startIndex..., in: text)
                let orderedLeaked = Self.orderedMarker.firstMatch(in: text, range: range) != nil
                XCTAssertFalse(orderedLeaked,
                    "\(file.lastPathComponent): an ordered-list marker leaked into a paragraph block " +
                    "(not claimed by the ordered-list parser) — \(text)")
                let unorderedLeaked = Self.unorderedMarker.firstMatch(in: text, range: range) != nil
                XCTAssertFalse(unorderedLeaked,
                    "\(file.lastPathComponent): an unordered-list marker leaked into a paragraph block " +
                    "(not claimed by the list parser) — \(text)")
                // An OPENING fence glued to preceding prose (no blank line)
                // would be swallowed into the paragraph the same way — the
                // paragraph loop doesn't break on a fence line. Guarded here
                // per the final whole-branch review's latent-gap note.
                XCTAssertFalse(text.contains("```"),
                    "\(file.lastPathComponent): a fence marker leaked into a paragraph block " +
                    "(opening fence glued to prose?) — \(text)")
            }
        }
    }
}
