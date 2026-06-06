import XCTest
@testable import MaughamCore

private struct Item: Codable, Equatable, Sendable { let id: String }

final class ParseDiagnosticsTests: XCTestCase {
    private func tempFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pd-\(UUID().uuidString).jsonl")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @MainActor
    func test_loadDiagnosed_reportsSkippedMidFileLine() async throws {
        let url = try tempFile(#"{"id":"a"}"# + "\n" + "NOT JSON\n" + #"{"id":"b"}"# + "\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = JSONLAppendStore<Item>(fileURL: url)
        let result = try await store.loadDiagnosed()
        XCTAssertEqual(result.elements, [Item(id: "a"), Item(id: "b")])
        XCTAssertEqual(result.diagnostics.skipped.count, 1)
        XCTAssertEqual(result.diagnostics.skipped.first?.raw, "NOT JSON")
        XCTAssertFalse(result.diagnostics.isClean)
    }

    @MainActor
    func test_load_stillReturnsElementsAndIgnoresDiagnostics() async throws {
        let url = try tempFile(#"{"id":"a"}"# + "\n" + "garbage\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = JSONLAppendStore<Item>(fileURL: url)
        let elements = try await store.load()
        XCTAssertEqual(elements, [Item(id: "a")])
    }

    @MainActor
    func test_blankLinesAreNotCorruption() async throws {
        let url = try tempFile(#"{"id":"a"}"# + "\n\n" + #"{"id":"b"}"# + "\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = JSONLAppendStore<Item>(fileURL: url)
        let result = try await store.loadDiagnosed()
        XCTAssertEqual(result.elements.count, 2)
        XCTAssertTrue(result.diagnostics.isClean)
    }
}
