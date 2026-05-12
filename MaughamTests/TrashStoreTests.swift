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

    static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone.current
        return f
    }()
}
