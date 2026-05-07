import XCTest
@testable import Maugham

@MainActor
final class DocumentStoreSaveTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    private func createNovelWithChapter1() async throws -> URL {
        try await ProjectFactory.createNovelProject(
            named: "Save", in: temp.url)
    }

    func test_openDocument_readsDiskAndSetsLastWritten() async throws {
        let url = try await createNovelWithChapter1()
        let chapterPath = "manuscript/01-chapter-1.md"
        try "initial content".write(
            to: url.appendingPathComponent(chapterPath),
            atomically: true, encoding: .utf8)

        let store = try await DocumentStore.open(url: url)
        let text = try await store.openDocument(at: chapterPath)

        XCTAssertEqual(text, "initial content")
        XCTAssertEqual(store.lastWrittenText, "initial content")
        XCTAssertEqual(store.openDocumentPath, chapterPath)
        await store.close()
    }

    func test_scheduleSave_writesAfterDebounce() async throws {
        let url = try await createNovelWithChapter1()
        let chapterPath = "manuscript/01-chapter-1.md"
        let store = try await DocumentStore.open(url: url)
        _ = try await store.openDocument(at: chapterPath)

        store.scheduleSave(for: chapterPath, text: "edited")
        try await Task.sleep(for: .milliseconds(900))  // > 750ms debounce

        let onDisk = try String(contentsOf: url.appendingPathComponent(chapterPath),
                                encoding: .utf8)
        XCTAssertEqual(onDisk, "edited")
        XCTAssertEqual(store.lastWrittenText, "edited")
        await store.close()
    }

    func test_rapidScheduleSaves_onlyLastWritten() async throws {
        let url = try await createNovelWithChapter1()
        let chapterPath = "manuscript/01-chapter-1.md"
        let store = try await DocumentStore.open(url: url)
        _ = try await store.openDocument(at: chapterPath)

        store.scheduleSave(for: chapterPath, text: "first")
        try await Task.sleep(for: .milliseconds(100))
        store.scheduleSave(for: chapterPath, text: "second")
        try await Task.sleep(for: .milliseconds(100))
        store.scheduleSave(for: chapterPath, text: "third")
        try await Task.sleep(for: .milliseconds(900))

        let onDisk = try String(contentsOf: url.appendingPathComponent(chapterPath),
                                encoding: .utf8)
        XCTAssertEqual(onDisk, "third")
        await store.close()
    }

    func test_flushPendingSave_writesImmediately() async throws {
        let url = try await createNovelWithChapter1()
        let chapterPath = "manuscript/01-chapter-1.md"
        let store = try await DocumentStore.open(url: url)
        _ = try await store.openDocument(at: chapterPath)

        store.scheduleSave(for: chapterPath, text: "needs flush")
        try await store.flushPendingSave()

        let onDisk = try String(contentsOf: url.appendingPathComponent(chapterPath),
                                encoding: .utf8)
        XCTAssertEqual(onDisk, "needs flush")
        await store.close()
    }

    func test_close_flushesPendingSave() async throws {
        let url = try await createNovelWithChapter1()
        let chapterPath = "manuscript/01-chapter-1.md"
        let store = try await DocumentStore.open(url: url)
        _ = try await store.openDocument(at: chapterPath)

        store.scheduleSave(for: chapterPath, text: "must persist on close")
        await store.close()

        let onDisk = try String(contentsOf: url.appendingPathComponent(chapterPath),
                                encoding: .utf8)
        XCTAssertEqual(onDisk, "must persist on close")
    }
}
