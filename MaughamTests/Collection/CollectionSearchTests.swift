import XCTest
@testable import Maugham

@MainActor
final class CollectionSearchTests: XCTestCase {
    func test_search_findsMatchesAcrossPieces() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CS-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createCollectionProject(
            named: "T", in: tmp)
        let store = try await ProjectStore.load(from: url)
        let p1 = try await store.addLoosePiece(title: "Lighthouse", mode: .prose)
        let p1URL = url.appendingPathComponent(p1.path!)
        try "The lighthouse keeper watched the storm.\n".write(
            to: p1URL, atomically: true, encoding: .utf8)
        // ADR 0018: bootstrap so the op log is seeded before search runs.
        _ = try await Document.load(url: p1URL, device: "test", session: "s", presenter: nil)

        let p2 = try await store.addLoosePiece(title: "Storm", mode: .prose)
        let p2URL = url.appendingPathComponent(p2.path!)
        try "Another storm story altogether.\n".write(
            to: p2URL, atomically: true, encoding: .utf8)
        _ = try await Document.load(url: p2URL, device: "test", session: "s", presenter: nil)

        // Flush any pending writes before search reads from disk
        try await store.documentStore?.flushPendingSave()

        let engine = ProjectSearchEngine()
        let results = try await engine.search(
            query: "storm",
            options: SearchOptions(caseSensitive: false, wholeWord: false),
            in: store)
        XCTAssertGreaterThanOrEqual(results.matches.count, 2,
            "got: \(results.matches.map { $0.linePreview })")
        let docTitles = Set(results.matches.map { $0.documentTitle })
        XCTAssertTrue(docTitles.contains("Lighthouse"))
        XCTAssertTrue(docTitles.contains("Storm"))
    }
}
