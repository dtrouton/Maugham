import XCTest
import MaughamCore
@testable import Maugham

/// Regression: `list_all_links`, `find_references`, and `list_scenes` must
/// derive manuscript content from the op log, not the on-disk `.md`/`.fountain`
/// (which can be stale). ADR 0018.
///
/// Each test:
///   1. Creates a project, writes initial content to the manuscript file,
///      and calls Document.load so Bootstrap seeds the op log.
///   2. Overwrites the on-disk file with stale content that LACKS the
///      op-log content (a wiki-link or a scene heading).
///   3. Runs the MCP tool.
///   4. Asserts the tool surfaces the op-log content (not the stale file).
@MainActor
final class ReferenceOpLogSourceTests: XCTestCase {

    // MARK: - list_all_links: closed doc must scan op log for [[wiki]] tokens

    func test_listAllLinks_closedDoc_usesOpLogNotStaleMd() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ROLS-LAL-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)

        let docURL = tmp.appendingPathComponent("manuscript/c1.md")
        // Initial content contains the wiki link that should be surfaced.
        try "She met [[OpLogWikiTarget]] in the square.".write(
            to: docURL, atomically: true, encoding: .utf8)

        let ch1 = StructureItem(
            id: "ch-rols-1", title: "Ch 1", type: .document,
            path: "manuscript/c1.md")
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [ch1], research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        // Bootstrap: seeds op log with the initial content (incl. the wiki link).
        _ = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)

        // Corrupt the on-disk .md — the wiki link is now absent on disk.
        try "No links here.".write(to: docURL, atomically: true, encoding: .utf8)

        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)
        let projectId = ProjectIdentifier.id(for: tmp)

        let paramsData = Data("{\"project_id\":\"\(projectId)\"}".utf8)
        let result = try await ListAllLinksTool.handle(paramsJSON: paramsData, registry: reg)
        let edges = try JSONDecoder().decode([ListAllLinksTool.Edge].self, from: result)

        // The wiki edge must be found via the op log (not the stale .md).
        XCTAssertTrue(
            edges.contains { $0.from_id == "ch-rols-1" && $0.to_title == "OpLogWikiTarget" },
            "list_all_links must derive wiki tokens from op log, not stale .md; edges: \(edges)")
        // The stale content must not produce a false hit.
        XCTAssertFalse(
            edges.contains { $0.to_title.contains("No links") },
            "stale .md content must not appear in edges; edges: \(edges)")
    }

    // MARK: - find_references: closed doc must scan op log for [[wiki]] refs

    func test_findReferences_closedDoc_usesOpLogNotStaleMd() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ROLS-FR-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)

        let docURL = tmp.appendingPathComponent("manuscript/c1.md")
        // Initial content contains the wiki link to "OpLogRefTarget".
        try "Evidence points to [[OpLogRefTarget]] as the culprit.".write(
            to: docURL, atomically: true, encoding: .utf8)

        let ch1 = StructureItem(
            id: "ch-rols-fr", title: "Ch 1", type: .document,
            path: "manuscript/c1.md")
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [ch1], research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        // Bootstrap: seeds op log with the initial content (incl. the wiki link).
        _ = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)

        // Corrupt the on-disk .md — the wiki link is now absent on disk.
        try "No references here.".write(to: docURL, atomically: true, encoding: .utf8)

        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)
        let projectId = ProjectIdentifier.id(for: tmp)

        // Target is "OpLogRefTarget" — no research item with this name; it will
        // be scanned for as a literal [[OpLogRefTarget]] wiki token.
        let paramsData = Data(
            "{\"project_id\":\"\(projectId)\",\"target\":\"OpLogRefTarget\"}".utf8)
        let result = try await FindReferencesTool.handle(paramsJSON: paramsData, registry: reg)
        let refs = try JSONDecoder().decode([FindReferencesTool.Reference].self, from: result)

        // ch-rols-fr must be found as a wiki back-reference via the op log.
        XCTAssertEqual(refs.count, 1,
            "find_references must surface the op-log wiki ref; refs: \(refs)")
        guard refs.count >= 1 else { return }
        XCTAssertEqual(refs[0].from_id, "ch-rols-fr")
        XCTAssertEqual(refs[0].kind, "wiki")
    }

    // MARK: - list_scenes: closed doc must parse op log for scene headings

    func test_listScenes_closedDoc_usesOpLogNotStaleFountain() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ROLS-LS-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)

        let docURL = tmp.appendingPathComponent("manuscript/s1.fountain")
        // Initial content has a scene heading that must appear in the op log.
        try "INT. OP LOG SCENE - DAY\n\nThe room is empty.\n".write(
            to: docURL, atomically: true, encoding: .utf8)

        let s1 = StructureItem(
            id: "doc-rols-ls", title: "Scene 1", type: .document,
            path: "manuscript/s1.fountain")
        let manifest = ProjectManifest(
            type: .screenplay, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [s1], research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        // Bootstrap: seeds op log with the fountain content (incl. the scene heading).
        _ = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)

        // Corrupt the on-disk .fountain — the scene heading is now absent on disk.
        try "No scenes here. Just action.".write(
            to: docURL, atomically: true, encoding: .utf8)

        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)
        let projectId = ProjectIdentifier.id(for: tmp)

        let paramsData = Data("{\"project_id\":\"\(projectId)\"}".utf8)
        let result = try await ListScenesTool.handle(paramsJSON: paramsData, registry: reg)
        let scenes = try JSONDecoder().decode([ListScenesTool.Scene].self, from: result)

        // The scene from the op log must be found, not the stale file.
        XCTAssertEqual(scenes.count, 1,
            "list_scenes must derive from op log, not stale .fountain; scenes: \(scenes)")
        guard scenes.count >= 1 else { return }
        XCTAssertTrue(scenes[0].heading.contains("OP LOG SCENE"),
            "scene heading must come from op log; got: \(scenes[0].heading)")
    }
}
