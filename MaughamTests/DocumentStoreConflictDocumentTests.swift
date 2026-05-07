import XCTest
@testable import Maugham

@MainActor
final class DocumentStoreConflictDocumentTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    func test_externalChange_noPendingEdits_silentReload() async throws {
        let url = try await ProjectFactory.createNovelProject(
            named: "ConfA", in: temp.url)
        let path = "manuscript/01-chapter-1.md"
        try "initial".write(
            to: url.appendingPathComponent(path),
            atomically: true, encoding: .utf8)

        let store = try await DocumentStore.open(url: url)
        _ = try await store.openDocument(at: path)
        store.currentDocumentText = "initial"  // matches lastWrittenText

        // Simulate external write
        try "external version".write(
            to: url.appendingPathComponent(path),
            atomically: true, encoding: .utf8)

        // Wait for NSFilePresenter callback + Case A silent reload to update
        // lastWrittenText. Timeout is 2s — well above typical fire times.
        try await store.waitForLastWrittenText({ $0 == "external version" })

        XCTAssertNil(store.pendingConflict)
        XCTAssertEqual(store.lastWrittenText, "external version")
        await store.close()
    }

    func test_externalChange_withPendingEdits_pendingConflict() async throws {
        let url = try await ProjectFactory.createNovelProject(
            named: "ConfB", in: temp.url)
        let path = "manuscript/01-chapter-1.md"
        try "initial".write(
            to: url.appendingPathComponent(path),
            atomically: true, encoding: .utf8)

        let store = try await DocumentStore.open(url: url)
        _ = try await store.openDocument(at: path)
        store.currentDocumentText = "user typed something local"

        // Simulate external write
        try "external version".write(
            to: url.appendingPathComponent(path),
            atomically: true, encoding: .utf8)

        try await store.waitForConflictState({ $0 != nil })
        let conflict = try XCTUnwrap(store.pendingConflict)
        XCTAssertEqual(conflict.path, path)
        XCTAssertEqual(conflict.localText, "user typed something local")
        XCTAssertEqual(conflict.externalText, "external version")
        await store.close()
    }

    func test_ourCoordinatedWrite_doesNotTriggerConflict() async throws {
        let url = try await ProjectFactory.createNovelProject(
            named: "ConfC", in: temp.url)
        let path = "manuscript/01-chapter-1.md"
        let store = try await DocumentStore.open(url: url)
        _ = try await store.openDocument(at: path)
        store.currentDocumentText = "initial"

        // Our own coordinated save, scheduled and flushed
        store.scheduleSave(for: path, text: "our own change")
        try await store.flushPendingSave()
        // Generous wait to let any presenter callback fire if it would.
        try await Task.sleep(for: .seconds(1))

        XCTAssertNil(store.pendingConflict)
        XCTAssertEqual(store.lastWrittenText, "our own change")
        await store.close()
    }
}
