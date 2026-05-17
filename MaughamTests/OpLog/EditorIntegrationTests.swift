import XCTest
@testable import Maugham

@MainActor
final class EditorIntegrationTests: XCTestCase {
    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("EIT-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [], research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func test_recordParagraphChange_buffersInPending() async throws {
        let store = try await DocumentStore.open(url: tmp)
        store.beginOpLogContext(docId: "doc-1", device: "m", session: "s")
        store.recordParagraphChange(
            paragraphId: "a3f9", prior: nil, next: "First.")
        XCTAssertFalse(store.opLogPendingIsEmpty(),
            "pending buffer should hold the change")
    }

    func test_flushBurst_appendsOpAndClearsPending() async throws {
        let store = try await DocumentStore.open(url: tmp)
        store.beginOpLogContext(docId: "doc-1", device: "m", session: "s")
        store.recordParagraphChange(paragraphId: "a3f9", prior: nil, next: "x")
        store.recordParagraphChange(paragraphId: "b21c", prior: nil, next: "y")
        try await store.flushBurstNow()

        let log = OpLogStore(projectURL: tmp)
        let ops = try await log.load(docId: "doc-1")
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops[0].kind, .typingBurst)
        XCTAssertEqual(Set(ops[0].changes.map(\.paragraphId)), ["a3f9", "b21c"])
        XCTAssertTrue(store.opLogPendingIsEmpty())
    }
}
