import XCTest
@testable import Maugham

@MainActor
final class TrashStoreTests: XCTestCase {
    private func makeProject() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrashStore-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    func test_list_emptyProject_returnsEmpty() async throws {
        let project = try makeProject()
        let store = TrashStore(projectURL: project)
        let entries = try await store.list()
        XCTAssertTrue(entries.isEmpty)
    }

    func test_sweep_removesEntriesOlderThan30Days() async throws {
        let project = try makeProject()
        let trash = project.appendingPathComponent(".trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)

        // Old entry (31 days ago)
        let oldDate = Calendar.current.date(byAdding: .day, value: -31, to: Date())!
        let oldFolder = trash.appendingPathComponent(
            "\(Self.timestampFormatter.string(from: oldDate))-old-id")
        try FileManager.default.createDirectory(at: oldFolder, withIntermediateDirectories: true)
        let oldMeta = """
        {
          "originalRelativePath": "manuscript/old.md",
          "displayTitle": "Old",
          "itemMetadata": "",
          "originalParentId": null,
          "originalIndex": 0
        }
        """
        try oldMeta.write(
            to: oldFolder.appendingPathComponent("meta.json"),
            atomically: true, encoding: .utf8)

        // Fresh entry
        let freshFolder = trash.appendingPathComponent(
            "\(Self.timestampFormatter.string(from: Date()))-fresh-id")
        try FileManager.default.createDirectory(at: freshFolder, withIntermediateDirectories: true)
        let freshMeta = """
        {
          "originalRelativePath": "manuscript/fresh.md",
          "displayTitle": "Fresh",
          "itemMetadata": "",
          "originalParentId": null,
          "originalIndex": 0
        }
        """
        try freshMeta.write(
            to: freshFolder.appendingPathComponent("meta.json"),
            atomically: true, encoding: .utf8)

        let store = TrashStore(projectURL: project)
        try await store.sweep()

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFolder.path),
                       "expected old entry swept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshFolder.path),
                      "expected fresh entry preserved")
    }

    func test_moveToTrash_movesFileAndWritesMetadata() async throws {
        let project = try makeProject()
        let originalFile = project.appendingPathComponent("manuscript/chapter7.md")
        try FileManager.default.createDirectory(
            at: originalFile.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try "Chapter 7 content".write(to: originalFile, atomically: true, encoding: .utf8)

        let store = TrashStore(projectURL: project)
        let metadata = Data("{\"id\":\"x\"}".utf8)
        let entry = try await store.moveToTrash(
            fileRelativePath: "manuscript/chapter7.md",
            itemMetadata: metadata,
            originalParentId: nil,
            originalIndex: 0,
            displayTitle: "Chapter 7")

        // Original is gone
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalFile.path))

        // Trash entry exists
        let trashFolder = project.appendingPathComponent(".trash/\(entry.id)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashFolder.path))
        let trashedFile = trashFolder.appendingPathComponent("chapter7.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashedFile.path))
        let trashedContent = try String(contentsOf: trashedFile, encoding: .utf8)
        XCTAssertEqual(trashedContent, "Chapter 7 content")

        // meta.json exists and parses
        let metaURL = trashFolder.appendingPathComponent("meta.json")
        let metaData = try Data(contentsOf: metaURL)
        let meta = try JSONDecoder().decode(TrashStore.TrashMeta.self, from: metaData)
        XCTAssertEqual(meta.originalRelativePath, "manuscript/chapter7.md")
        XCTAssertEqual(meta.displayTitle, "Chapter 7")
        XCTAssertEqual(meta.itemMetadata, metadata)
    }

    static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone.current
        return f
    }()
}
