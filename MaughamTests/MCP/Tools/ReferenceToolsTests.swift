import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class ReferenceToolsTests: XCTestCase {
    fileprivate func makeProject(type: ProjectType = .novel) async throws -> (URL, ProjectRegistry) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RT-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let docURL = tmp.appendingPathComponent("manuscript/c1.md")
        try "She walked into the kitchen. He followed.\n\nKitchen scene continued.".write(
            to: docURL, atomically: true, encoding: .utf8)
        let ch = StructureItem(
            id: "ch-1", title: "Ch 1", type: .document,
            path: "manuscript/c1.md")
        let manifest = ProjectManifest(
            type: type, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [ch], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        // ADR 0018: seed the op log before any search_text MCP call.
        _ = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)
        return (tmp, reg)
    }

    func test_searchText_findsMatches() async throws {
        let (url, reg) = try await makeProject()
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\",\"query\":\"kitchen\"}"
        let json = try await SearchTextTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let matches = try JSONDecoder().decode(
            [SearchTextTool.Match].self, from: json)
        XCTAssertGreaterThanOrEqual(matches.count, 2)
    }

    func test_listScenes_nonScreenplay_returnsEmpty() async throws {
        let (url, reg) = try await makeProject(type: .novel)
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\"}"
        let json = try await ListScenesTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let scenes = try JSONDecoder().decode(
            [ListScenesTool.Scene].self, from: json)
        XCTAssertEqual(scenes.count, 0)
    }
}

extension ReferenceToolsTests {
    func test_findReferences_byResearchId_returnsLinkedChapters() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("FR-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research"), withIntermediateDirectories: true)
        try "x".write(to: tmp.appendingPathComponent("manuscript/c1.md"),
                       atomically: true, encoding: .utf8)
        try "Sarah\n".write(to: tmp.appendingPathComponent("research/sarah.md"),
                             atomically: true, encoding: .utf8)
        let chapter = StructureItem(
            id: "ch-1", title: "Ch 1", type: .document,
            path: "manuscript/c1.md")
        let sarah = ResearchItem(
            id: "res-sarah", title: "Sarah", type: .asset, kind: .document,
            path: "research/sarah.md", addedAt: Date())
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [chapter], research: [sarah])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        try await store.linkResearch(researchId: "res-sarah", toDocumentId: "ch-1")
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)

        let id = ProjectIdentifier.id(for: tmp)
        let req = "{\"project_id\":\"\(id)\",\"target\":\"res-sarah\"}"
        let json = try await FindReferencesTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let refs = try JSONDecoder().decode(
            [FindReferencesTool.Reference].self, from: json)
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs[0].from_id, "ch-1")
        XCTAssertEqual(refs[0].kind, "linked_research")
    }

    func test_findReferences_byResearchTitle_resolvesAndReturnsLinkedChapters() async throws {
        // Same fixture shape as test_findReferences_byResearchId_returnsLinkedChapters,
        // but pass the title "Sarah" instead of the id "res-sarah".
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("FRT-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research"), withIntermediateDirectories: true)
        try "x".write(to: tmp.appendingPathComponent("manuscript/c1.md"),
                       atomically: true, encoding: .utf8)
        try "Sarah".write(to: tmp.appendingPathComponent("research/sarah.md"),
                           atomically: true, encoding: .utf8)
        let chapter = StructureItem(
            id: "ch-1", title: "Ch 1", type: .document, path: "manuscript/c1.md")
        let sarah = ResearchItem(
            id: "res-sarah", title: "Sarah", type: .asset, kind: .document,
            path: "research/sarah.md", addedAt: Date())
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [chapter], research: [sarah])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        try await store.linkResearch(researchId: "res-sarah", toDocumentId: "ch-1")
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)

        let id = ProjectIdentifier.id(for: tmp)
        let req = "{\"project_id\":\"\(id)\",\"target\":\"Sarah\"}"
        let json = try await FindReferencesTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let refs = try JSONDecoder().decode(
            [FindReferencesTool.Reference].self, from: json)
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs[0].from_id, "ch-1")
        XCTAssertEqual(refs[0].kind, "linked_research")
    }

    func test_getSessionStats_returnsAggregate() async throws {
        let (url, reg) = try await makeProject()
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\"}"
        let json = try await GetSessionStatsTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let stats = try JSONDecoder().decode(
            GetSessionStatsTool.SessionStats.self, from: json)
        XCTAssertGreaterThanOrEqual(stats.daily.count, 0)
        XCTAssertGreaterThanOrEqual(stats.total_minutes, 0)
    }

    /// Three-document screenplay project; each .fountain has its own scene
    /// heading. list_scenes should aggregate across all docs.
    func test_listScenes_walksAllDocuments() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LS3-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try "INT. KITCHEN - DAY\n\nSarah pours coffee.\n".write(
            to: tmp.appendingPathComponent("manuscript/s1.fountain"),
            atomically: true, encoding: .utf8)
        try "EXT. PARK - NIGHT\n\nJames waits on a bench.\n".write(
            to: tmp.appendingPathComponent("manuscript/s2.fountain"),
            atomically: true, encoding: .utf8)
        try "INT. CAR - DAY\n\nDriving in silence.\n".write(
            to: tmp.appendingPathComponent("manuscript/s3.fountain"),
            atomically: true, encoding: .utf8)
        let s1 = StructureItem(id: "doc-1", title: "Scene 1", type: .document,
                                path: "manuscript/s1.fountain")
        let s2 = StructureItem(id: "doc-2", title: "Scene 2", type: .document,
                                path: "manuscript/s2.fountain")
        let s3 = StructureItem(id: "doc-3", title: "Scene 3", type: .document,
                                path: "manuscript/s3.fountain")
        let manifest = ProjectManifest(
            type: .screenplay, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [s1, s2, s3], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        // ADR 0018: seed the op log for each doc before any MCP call.
        _ = try await Document.load(
            url: tmp.appendingPathComponent("manuscript/s1.fountain"),
            device: "test", session: "s", presenter: nil)
        _ = try await Document.load(
            url: tmp.appendingPathComponent("manuscript/s2.fountain"),
            device: "test", session: "s", presenter: nil)
        _ = try await Document.load(
            url: tmp.appendingPathComponent("manuscript/s3.fountain"),
            device: "test", session: "s", presenter: nil)
        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)

        let id = ProjectIdentifier.id(for: tmp)
        let req = "{\"project_id\":\"\(id)\"}"
        let json = try await ListScenesTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let scenes = try JSONDecoder().decode(
            [ListScenesTool.Scene].self, from: json)
        XCTAssertEqual(scenes.count, 3,
            "expected 3 scenes across 3 docs, got: \(scenes)")
        // document_id is preserved per-scene
        XCTAssertEqual(Set(scenes.map(\.document_id)),
                       Set(["doc-1", "doc-2", "doc-3"]))
        // headings preserved
        XCTAssertTrue(scenes.contains { $0.heading.contains("KITCHEN") })
        XCTAssertTrue(scenes.contains { $0.heading.contains("PARK") })
        XCTAssertTrue(scenes.contains { $0.heading.contains("CAR") })
    }

    /// Short screenplay (well under 1 page total): page_start must start at
    /// 0.0 and page_length must be the fractional length actually occupied
    /// by the scene's lines. The pre-fix behavior was page_start: 1.0,
    /// page_length: 0 — useless for "where am I against page target".
    func test_listScenes_shortScript_hasFractionalPagePositions() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LSF-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try "INT. KITCHEN - DAY\n\nA brief scene.\n".write(
            to: tmp.appendingPathComponent("manuscript/s1.fountain"),
            atomically: true, encoding: .utf8)
        let s1 = StructureItem(id: "doc-1", title: "Scene 1", type: .document,
                                path: "manuscript/s1.fountain")
        let manifest = ProjectManifest(
            type: .screenplay, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [s1], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        // ADR 0018: seed the op log before any MCP call.
        _ = try await Document.load(
            url: tmp.appendingPathComponent("manuscript/s1.fountain"),
            device: "test", session: "s", presenter: nil)
        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)

        let id = ProjectIdentifier.id(for: tmp)
        let req = "{\"project_id\":\"\(id)\"}"
        let json = try await ListScenesTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let scenes = try JSONDecoder().decode(
            [ListScenesTool.Scene].self, from: json)
        XCTAssertEqual(scenes.count, 1)
        // First scene starts at the very top — page 0.0, not 1.0.
        XCTAssertEqual(scenes[0].page_start, 0.0, accuracy: 0.0001,
            "first scene should start at 0.0, got \(scenes[0].page_start)")
        // Length must be positive (fractional, since total < 1 page).
        XCTAssertGreaterThan(scenes[0].page_length, 0.0,
            "short scene should still have positive length")
        XCTAssertLessThan(scenes[0].page_length, 1.0,
            "short scene should not exceed 1 page")
    }
}

extension ReferenceToolsTests {
    /// find_references should also accept a relative path string (the form an
    /// agent gets from list_research or os-level file listings).
    func test_findReferences_byResearchPath_resolvesAndReturnsLinkedChapters() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("FRP-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research"), withIntermediateDirectories: true)
        try "x".write(to: tmp.appendingPathComponent("manuscript/c1.md"),
                       atomically: true, encoding: .utf8)
        try "Sarah".write(to: tmp.appendingPathComponent("research/sarah.md"),
                           atomically: true, encoding: .utf8)
        let chapter = StructureItem(id: "ch-1", title: "Ch 1", type: .document,
                                     path: "manuscript/c1.md")
        let sarah = ResearchItem(id: "res-sarah", title: "Sarah", type: .asset,
                                  kind: .document, path: "research/sarah.md",
                                  addedAt: Date())
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [chapter], research: [sarah])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        try await store.linkResearch(researchId: "res-sarah", toDocumentId: "ch-1")
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)

        let id = ProjectIdentifier.id(for: tmp)
        let req = "{\"project_id\":\"\(id)\",\"target\":\"research/sarah.md\"}"
        let json = try await FindReferencesTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let refs = try JSONDecoder().decode(
            [FindReferencesTool.Reference].self, from: json)
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs[0].from_id, "ch-1")
        XCTAssertEqual(refs[0].kind, "linked_research")
    }
}

extension ReferenceToolsTests {
    /// Multi-document screenplay: page_start values must be monotonically
    /// increasing across documents (script-relative), not document-relative
    /// where each doc restarts at 0.
    func test_listScenes_pagesAreScriptRelative() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LSP-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        // Each doc has one scene heading. Bodies are intentionally non-empty
        // so doc 1 has measurable length and doc 2's scene appears past 0.
        try "INT. KITCHEN - DAY\n\nSarah pours coffee. She stares out the window. The morning light is harsh.\n".write(
            to: tmp.appendingPathComponent("manuscript/s1.fountain"),
            atomically: true, encoding: .utf8)
        try "EXT. PARK - NIGHT\n\nJames waits on a bench. The fog rolls in. He checks his watch.\n".write(
            to: tmp.appendingPathComponent("manuscript/s2.fountain"),
            atomically: true, encoding: .utf8)
        try "INT. CAR - DAY\n\nDriving in silence. The radio plays softly.\n".write(
            to: tmp.appendingPathComponent("manuscript/s3.fountain"),
            atomically: true, encoding: .utf8)
        let s1 = StructureItem(id: "doc-1", title: "Scene 1", type: .document,
                                path: "manuscript/s1.fountain")
        let s2 = StructureItem(id: "doc-2", title: "Scene 2", type: .document,
                                path: "manuscript/s2.fountain")
        let s3 = StructureItem(id: "doc-3", title: "Scene 3", type: .document,
                                path: "manuscript/s3.fountain")
        let manifest = ProjectManifest(
            type: .screenplay, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [s1, s2, s3], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        // ADR 0018: seed the op log for each doc before any MCP call.
        _ = try await Document.load(
            url: tmp.appendingPathComponent("manuscript/s1.fountain"),
            device: "test", session: "s", presenter: nil)
        _ = try await Document.load(
            url: tmp.appendingPathComponent("manuscript/s2.fountain"),
            device: "test", session: "s", presenter: nil)
        _ = try await Document.load(
            url: tmp.appendingPathComponent("manuscript/s3.fountain"),
            device: "test", session: "s", presenter: nil)
        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)

        let id = ProjectIdentifier.id(for: tmp)
        let req = "{\"project_id\":\"\(id)\"}"
        let json = try await ListScenesTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let scenes = try JSONDecoder().decode(
            [ListScenesTool.Scene].self, from: json)
        XCTAssertEqual(scenes.count, 3)
        // Document order should match manifest order
        XCTAssertEqual(scenes[0].document_id, "doc-1")
        XCTAssertEqual(scenes[1].document_id, "doc-2")
        XCTAssertEqual(scenes[2].document_id, "doc-3")
        // First scene starts at the very top of the script
        XCTAssertEqual(scenes[0].page_start, 0.0, accuracy: 0.0001)
        // Subsequent scenes must start strictly after the previous one.
        XCTAssertGreaterThan(scenes[1].page_start, scenes[0].page_start,
            "scene 2 must start past scene 1's start (script-relative)")
        XCTAssertGreaterThan(scenes[2].page_start, scenes[1].page_start,
            "scene 3 must start past scene 2's start (script-relative)")
        // page_length is the delta to the next scene; all lengths positive
        for s in scenes {
            XCTAssertGreaterThan(s.page_length, 0.0,
                "every scene should have positive length")
        }
    }

    /// First scene in each of multiple documents currently collides on
    /// id="scene-0". Compound the doc id into the scene id so it's actually
    /// unique across the script.
    func test_listScenes_idsAreUniqueAcrossDocs() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LSU-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try "INT. KITCHEN - DAY\n\nBeat.\n".write(
            to: tmp.appendingPathComponent("manuscript/s1.fountain"),
            atomically: true, encoding: .utf8)
        try "EXT. PARK - NIGHT\n\nBeat.\n".write(
            to: tmp.appendingPathComponent("manuscript/s2.fountain"),
            atomically: true, encoding: .utf8)
        let s1 = StructureItem(id: "doc-A", title: "A", type: .document,
                                path: "manuscript/s1.fountain")
        let s2 = StructureItem(id: "doc-B", title: "B", type: .document,
                                path: "manuscript/s2.fountain")
        let manifest = ProjectManifest(
            type: .screenplay, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [s1, s2], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        // ADR 0018: seed the op log for each doc before any MCP call.
        _ = try await Document.load(
            url: tmp.appendingPathComponent("manuscript/s1.fountain"),
            device: "test", session: "s", presenter: nil)
        _ = try await Document.load(
            url: tmp.appendingPathComponent("manuscript/s2.fountain"),
            device: "test", session: "s", presenter: nil)
        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)

        let id = ProjectIdentifier.id(for: tmp)
        let req = "{\"project_id\":\"\(id)\"}"
        let json = try await ListScenesTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let scenes = try JSONDecoder().decode(
            [ListScenesTool.Scene].self, from: json)
        XCTAssertEqual(scenes.count, 2)
        XCTAssertNotEqual(scenes[0].id, scenes[1].id,
            "scene ids must be unique across documents, got: \(scenes.map(\.id))")
    }
}

extension ReferenceToolsTests {
    /// When the underlying document id already starts with "scene-",
    /// the composite scene id shouldn't double the prefix.
    func test_listScenes_compositeId_doesNotDoublePrefix() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LSDP-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try "INT. KITCHEN - DAY\n\nBeat.\n".write(
            to: tmp.appendingPathComponent("manuscript/s1.fountain"),
            atomically: true, encoding: .utf8)
        // Document id deliberately uses the "scene-" prefix.
        let s = StructureItem(id: "scene-f8c9644e", title: "Scene 1", type: .document,
                               path: "manuscript/s1.fountain")
        let manifest = ProjectManifest(
            type: .screenplay, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [s], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        // ADR 0018: seed the op log before any MCP call.
        _ = try await Document.load(
            url: tmp.appendingPathComponent("manuscript/s1.fountain"),
            device: "test", session: "s", presenter: nil)
        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)

        let id = ProjectIdentifier.id(for: tmp)
        let req = "{\"project_id\":\"\(id)\"}"
        let json = try await ListScenesTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let scenes = try JSONDecoder().decode(
            [ListScenesTool.Scene].self, from: json)
        XCTAssertEqual(scenes.count, 1)
        XCTAssertFalse(scenes[0].id.hasPrefix("scene-scene-"),
            "composite id must not double-prefix; got: \(scenes[0].id)")
    }

    func test_findReferences_pieceOwnedResearch_returnsOwningPiece() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("FR-PR-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createCollectionProject(named: "C", in: tmp)
        let store = try await ProjectStore.load(from: url)
        let piece = try await store.addLoosePiece(title: "Story A", mode: .prose)
        let owned = try await store.addPieceResearchNote(
            pieceId: piece.id, title: "Owned Note")
        let reg = ProjectRegistry()
        reg.register(url: url, store: store)
        let projectId = ProjectIdentifier.id(for: url)

        let params = #"{"project_id":"\#(projectId)","target":"\#(owned.id)"}"#
        let json = try await FindReferencesTool.handle(
            paramsJSON: Data(params.utf8), registry: reg)
        let refs = try JSONDecoder().decode(
            [FindReferencesTool.Reference].self, from: json)

        XCTAssertTrue(refs.contains {
            $0.kind == "piece_research" && $0.from_id == piece.id
        }, "owning piece must back-reference its research; refs: \(refs)")
    }
}

extension ReferenceToolsTests {
    /// A project whose links live in RESEARCH notes rather than in the
    /// manuscript — which is the only shape canvas promotion can produce.
    private func makeResearchLinkedProject() async throws -> (URL, ProjectRegistry) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RTLR-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research"), withIntermediateDirectories: true)
        try "The falls at night.\n\n[[October's doctor]] — because of the ponchos\n".write(
            to: tmp.appendingPathComponent("research/falls.md"),
            atomically: true, encoding: .utf8)
        try "October's doctor was kind about it.\n\n[[Nobody]]\n".write(
            to: tmp.appendingPathComponent("research/doctor.md"),
            atomically: true, encoding: .utf8)
        let falls = ResearchItem(id: "res-falls", title: "The falls at night", type: .asset,
                                 kind: .document, path: "research/falls.md", addedAt: Date())
        let doctor = ResearchItem(id: "res-doctor", title: "October's doctor", type: .asset,
                                  kind: .document, path: "research/doctor.md", addedAt: Date())
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [], research: [falls, doctor])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: tmp.appendingPathComponent("project.maugham.json"))
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: try await ProjectStore.load(from: tmp))
        return (tmp, reg)
    }

    func test_findReferencesSeesALinkMadeFromAResearchNote() async throws {
        let (url, reg) = try await makeResearchLinkedProject()
        let req = "{\"project_id\":\"\(ProjectIdentifier.id(for: url))\","
            + "\"target\":\"October's doctor\"}"
        let refs = try JSONDecoder().decode(
            [FindReferencesTool.Reference].self,
            from: try await FindReferencesTool.handle(paramsJSON: Data(req.utf8), registry: reg))
        XCTAssertTrue(refs.contains { $0.from_id == "res-falls" && $0.kind == "wiki" },
                      "a promoted line's link is a reference, and this is the tool "
                      + "a writer asks 'what points at this'")
    }

    func test_findReferencesDoesNotReportANoteAsAReferenceToItself() async throws {
        let (url, reg) = try await makeResearchLinkedProject()
        let req = "{\"project_id\":\"\(ProjectIdentifier.id(for: url))\","
            + "\"target\":\"The falls at night\"}"
        let refs = try JSONDecoder().decode(
            [FindReferencesTool.Reference].self,
            from: try await FindReferencesTool.handle(paramsJSON: Data(req.utf8), registry: reg))
        XCTAssertFalse(refs.contains { $0.from_id == "res-falls" })
    }
}
