import XCTest
@testable import Maugham

@MainActor
final class DocumentStoreConflictResolutionTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    private func setupConflict() async throws -> (URL, DocumentStore, String) {
        let url = try await ProjectFactory.createNovelProject(
            named: "Resolve", in: temp.url)
        let path = "manuscript/01-chapter-1.md"
        try "initial".write(
            to: url.appendingPathComponent(path),
            atomically: true, encoding: .utf8)
        let store = try await DocumentStore.open(url: url)
        _ = try await store.openDocument(at: path)
        store.currentDocumentText = "local edits"

        // Simulate external write
        try "external content".write(
            to: url.appendingPathComponent(path),
            atomically: true, encoding: .utf8)
        try await store.waitForConflictState({ $0 != nil })
        return (url, store, path)
    }

    func test_keepMine_writesLocal_preservesExternal() async throws {
        let (url, store, path) = try await setupConflict()

        try await store.resolveConflictKeepMine()

        let onDisk = try String(contentsOf: url.appendingPathComponent(path),
                                encoding: .utf8)
        XCTAssertEqual(onDisk, "local edits")
        XCTAssertNil(store.pendingConflict)

        // .maugham/conflicts/ should contain the cloud version
        let conflictsDir = url.appendingPathComponent(".maugham/conflicts")
        let files = try FileManager.default.contentsOfDirectory(atPath: conflictsDir.path)
        XCTAssertEqual(files.count, 1)
        let cloudFile = files[0]
        XCTAssertTrue(cloudFile.contains("cloud-"))
        let cloudContent = try String(
            contentsOf: conflictsDir.appendingPathComponent(cloudFile),
            encoding: .utf8)
        XCTAssertEqual(cloudContent, "external content")
        await store.close()
    }

    func test_useCloud_writesExternal_preservesLocal() async throws {
        let (url, store, path) = try await setupConflict()

        try await store.resolveConflictUseCloud()

        let onDisk = try String(contentsOf: url.appendingPathComponent(path),
                                encoding: .utf8)
        XCTAssertEqual(onDisk, "external content")
        XCTAssertEqual(store.lastWrittenText, "external content")
        XCTAssertNil(store.pendingConflict)

        let conflictsDir = url.appendingPathComponent(".maugham/conflicts")
        let files = try FileManager.default.contentsOfDirectory(atPath: conflictsDir.path)
        XCTAssertEqual(files.count, 1)
        let localFile = files[0]
        XCTAssertTrue(localFile.contains("local-"))
        let localContent = try String(
            contentsOf: conflictsDir.appendingPathComponent(localFile),
            encoding: .utf8)
        XCTAssertEqual(localContent, "local edits")
        await store.close()
    }
}
