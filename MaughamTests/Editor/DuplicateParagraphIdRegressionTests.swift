import XCTest
@testable import Maugham
@testable import MaughamCore

/// Regression pins for the 2026-06-10 paste crash: duplicate paragraph ids
/// reached `TaskAnchorAlignment.align`'s `Dictionary(uniqueKeysWithValues:)`
/// and trapped mid-`setFullText`. Root cause fixed at the mint sites
/// (`ParagraphID.mintUnique` in restorePairs / Bootstrap / insertParagraph);
/// these tests pin BOTH the root fix's observable contract (large pastes
/// yield unique ids) and the defense-in-depth (align tolerates legacy
/// duplicate ids written by pre-fix builds without crashing).
@MainActor
final class DuplicateParagraphIdRegressionTests: XCTestCase {

    // Defense-in-depth: align must not trap on duplicate ids (legacy docs
    // written before mintUnique can carry them). First occurrence wins.
    func test_align_toleratesDuplicateNextParagraphIds() {
        let dup = "abcd"
        let result = TaskAnchorAlignment.align(
            priorById: [dup: "one"],
            nextParagraphs: [
                (id: dup, text: "one"),
                (id: "efgh", text: "two"),
                (id: dup, text: "three (legacy duplicate)"),
            ],
            priorSequence: [dup],
            nextSequence: [dup, "efgh", dup],
            preEditCursor: 0,
            postEditCursor: 4)
        // Reaching here without a trap IS the regression assertion; sanity:
        XCTAssertNotNil(result.restoredById[dup])
    }

    // Root-fix contract at crash scale: paste thousands of new paragraphs
    // into a doc that already has thousands of ids. Pre-fix, a mint
    // collision in this configuration was near-certain (birthday over the
    // ~1.05M id space) and produced duplicate ids in the document. Post-fix
    // every id is unique.
    func test_largePaste_mintsUniqueIdsOnly() async throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dup-id-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: projectURL) }
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        let url = projectURL.appendingPathComponent("manuscript/doc.md")

        // 2,000 existing paragraphs (Bootstrap mints these — also through
        // mintUnique now), then paste 2,000 more via setFullText.
        let existing = (0..<2_000).map { "Existing paragraph \($0)." }
            .joined(separator: "\n\n")
        try existing.write(to: url, atomically: true, encoding: .utf8)
        let doc = try await Document.load(
            url: url, device: "test-mac", session: "s1", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
        XCTAssertEqual(doc.sequence.count, 2_000)
        XCTAssertEqual(Set(doc.sequence).count, 2_000,
                       "bootstrap must mint unique ids at scale")

        let pasted = (0..<2_000).map { "Pasted paragraph \($0)!" }
            .joined(separator: "\n\n")
        doc.setFullText(doc.displayText + "\n\n" + pasted)

        XCTAssertEqual(doc.sequence.count, 4_000)
        XCTAssertEqual(Set(doc.sequence).count, 4_000,
                       "paste-path mints must be unique against the whole doc")
        XCTAssertEqual(Set(doc.sequence).count, doc.paragraphs.count)
        await doc.close()
    }
}
