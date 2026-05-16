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
        try "The lighthouse keeper watched the storm.\n".write(
            to: url.appendingPathComponent(p1.path!),
            atomically: true, encoding: .utf8)
        let p2 = try await store.addLoosePiece(title: "Storm", mode: .prose)
        try "Another storm story altogether.\n".write(
            to: url.appendingPathComponent(p2.path!),
            atomically: true, encoding: .utf8)
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
