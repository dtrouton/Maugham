import XCTest
@testable import Maugham

@MainActor
final class AddNoteToolTests: XCTestCase {
    private func makeProject() async throws -> (URL, ProjectStore, ProjectRegistry) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AN-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research"), withIntermediateDirectories: true)
        try "x".write(to: tmp.appendingPathComponent("manuscript/c1.md"),
                       atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)
        return (tmp, store, reg)
    }

    func test_addNote_createsFileAndManifestEntry() async throws {
        let (url, store, reg) = try await makeProject()
        let id = ProjectIdentifier.id(for: url)
        let req = """
        {"project_id":"\(id)","title":"Sarah notes","body":"# Sarah\\n\\n32 years old."}
        """
        let json = try await AddNoteTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let result = try JSONDecoder().decode(
            AddNoteTool.Result.self, from: json)
        XCTAssertEqual(result.title, "Sarah notes")
        XCTAssertEqual(store.manifest.research.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(result.path).path))
        // Verify body actually written
        let written = try String(
            contentsOfFile: url.appendingPathComponent(result.path).path, encoding: .utf8)
        XCTAssertTrue(written.contains("32 years old"))
    }

    func test_addNote_postsNotification() async throws {
        let (url, _, reg) = try await makeProject()
        let id = ProjectIdentifier.id(for: url)
        let exp = expectation(forNotification: .maughamMCPNoteAdded, object: nil)
        let req = "{\"project_id\":\"\(id)\",\"title\":\"x\",\"body\":\"y\"}"
        _ = try await AddNoteTool.handle(paramsJSON: Data(req.utf8), registry: reg)
        await fulfillment(of: [exp], timeout: 2)
    }

    func test_addNote_validatesParentGroup() async throws {
        let (url, _, reg) = try await makeProject()
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\",\"title\":\"x\",\"body\":\"y\",\"parent_group_id\":\"nope\"}"
        do {
            _ = try await AddNoteTool.handle(paramsJSON: Data(req.utf8), registry: reg)
            XCTFail()
        } catch MCPError.invalidArgument {
            // ok
        } catch {
            XCTFail("wrong: \(error)")
        }
    }
}
