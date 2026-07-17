import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class ListAllLinksToolTests: XCTestCase {
    private func makeProject() async throws -> (URL, ProjectStore, ProjectRegistry) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LAL-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research"), withIntermediateDirectories: true)
        // ch-1 wiki-links to "Sarah" and "Ch 2"; ch-2 has no wiki links.
        try "Sarah arrives. See [[Sarah]] for backstory. Also [[Ch 2]].".write(
            to: tmp.appendingPathComponent("manuscript/c1.md"),
            atomically: true, encoding: .utf8)
        try "Continued.".write(
            to: tmp.appendingPathComponent("manuscript/c2.md"),
            atomically: true, encoding: .utf8)
        try "Sarah profile.".write(
            to: tmp.appendingPathComponent("research/sarah.md"),
            atomically: true, encoding: .utf8)
        let ch1 = StructureItem(id: "ch-1", title: "Ch 1", type: .document,
                                 path: "manuscript/c1.md")
        let ch2 = StructureItem(id: "ch-2", title: "Ch 2", type: .document,
                                 path: "manuscript/c2.md")
        let sarah = ResearchItem(id: "res-sarah", title: "Sarah", type: .asset,
                                  kind: .document, path: "research/sarah.md",
                                  addedAt: Date())
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [ch1, ch2], research: [sarah])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        // ADR 0018: seed the op log before any wiki-scan MCP call.
        _ = try await Document.load(
            url: tmp.appendingPathComponent("manuscript/c1.md"),
            device: "test", session: "s", presenter: nil)
        _ = try await Document.load(
            url: tmp.appendingPathComponent("manuscript/c2.md"),
            device: "test", session: "s", presenter: nil)
        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)
        return (tmp, store, reg)
    }

    func test_listAllLinks_emitsLinkedResearchEdges() async throws {
        let (url, store, reg) = try await makeProject()
        try await store.linkResearch(researchId: "res-sarah", toDocumentId: "ch-1")
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\"}"
        let json = try await ListAllLinksTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let edges = try JSONDecoder().decode(
            [ListAllLinksTool.Edge].self, from: json)
        XCTAssertTrue(edges.contains {
            $0.from_id == "ch-1" && $0.to_id == "res-sarah" && $0.kind == "linked_research"
        })
    }

    func test_listAllLinks_emitsWikiEdges_resolvedAndUnresolved() async throws {
        let (url, _, reg) = try await makeProject()
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\"}"
        let json = try await ListAllLinksTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let edges = try JSONDecoder().decode(
            [ListAllLinksTool.Edge].self, from: json)
        // ch-1's body contains [[Sarah]] (resolves to res-sarah) and [[Ch 2]] (resolves to ch-2).
        XCTAssertTrue(edges.contains {
            $0.from_id == "ch-1" && $0.to_id == "res-sarah" && $0.kind == "wiki"
        }, "expected wiki edge ch-1 → res-sarah")
        XCTAssertTrue(edges.contains {
            $0.from_id == "ch-1" && $0.to_id == "ch-2" && $0.kind == "wiki"
        }, "expected wiki edge ch-1 → ch-2")
    }

    func test_listAllLinks_unresolvedWikiLink_emittedAsUnresolved() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LALU-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try "References to [[Nonexistent]] linger here.".write(
            to: tmp.appendingPathComponent("manuscript/c1.md"),
            atomically: true, encoding: .utf8)
        let ch1 = StructureItem(id: "ch-1", title: "Ch 1", type: .document,
                                 path: "manuscript/c1.md")
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [ch1], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        // ADR 0018: seed the op log before any wiki-scan MCP call.
        _ = try await Document.load(
            url: tmp.appendingPathComponent("manuscript/c1.md"),
            device: "test", session: "s", presenter: nil)
        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)
        let id = ProjectIdentifier.id(for: tmp)
        let req = "{\"project_id\":\"\(id)\"}"
        let json = try await ListAllLinksTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let edges = try JSONDecoder().decode(
            [ListAllLinksTool.Edge].self, from: json)
        // An unresolved wiki target is reported with kind "wiki_unresolved"
        // and the literal target title in to_title; to_id is null.
        XCTAssertTrue(edges.contains {
            $0.from_id == "ch-1" &&
            $0.to_id == nil &&
            $0.to_title == "Nonexistent" &&
            $0.kind == "wiki_unresolved"
        }, "expected unresolved wiki edge for [[Nonexistent]], got: \(edges)")
    }

    /// Smoke caught a chapter linked to a research GROUP returning the group's
    /// id as to_title (group titles weren't indexed). Resolve via group title.
    func test_listAllLinks_linkToResearchGroup_resolvesGroupTitle() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LALG-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research"), withIntermediateDirectories: true)
        try "x".write(to: tmp.appendingPathComponent("manuscript/c1.md"),
                       atomically: true, encoding: .utf8)
        let ch1 = StructureItem(id: "ch-1", title: "Ch 1", type: .document,
                                 path: "manuscript/c1.md")
        let location = ResearchItem(id: "res-grp-loc", title: "Location",
                                     type: .group, kind: nil,
                                     path: nil, addedAt: Date(),
                                     children: nil)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [ch1], research: [location])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        try await store.linkResearch(researchId: "res-grp-loc", toDocumentId: "ch-1")
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)
        let id = ProjectIdentifier.id(for: tmp)
        let req = "{\"project_id\":\"\(id)\"}"
        let json = try await ListAllLinksTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let edges = try JSONDecoder().decode(
            [ListAllLinksTool.Edge].self, from: json)
        let groupEdge = try XCTUnwrap(edges.first { $0.to_id == "res-grp-loc" })
        XCTAssertEqual(groupEdge.to_title, "Location",
            "group link should resolve to group title, not raw id")
        XCTAssertEqual(groupEdge.kind, "linked_research")
    }

    func test_listAllLinks_emitsPieceResearchEdges_forCollections() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LAL-PR-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createCollectionProject(named: "C", in: tmp)
        let store = try await ProjectStore.load(from: url)
        let piece = try await store.addLoosePiece(title: "Story A", mode: .prose)
        let owned = try await store.addPieceResearchNote(
            pieceId: piece.id, title: "Owned Note")
        _ = try await store.addResearchTextNote(parentId: nil, title: "Shared Note")
        // A group moved into the piece: its nested asset must surface as a
        // piece_research edge (containment is flattened to contained assets).
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let group = try await store.addResearchItem(
            parentId: nil, title: "Setting", kind: nil)
        let nested = try await store.addResearchTextNote(
            parentId: group.id, title: "Harbor")
        try await store.moveResearchItems(ids: [group.id], to: .piece(piece.id))
        let reg = ProjectRegistry()
        reg.register(url: url, store: store)
        let projectId = ProjectIdentifier.id(for: url)

        let json = try await ListAllLinksTool.handle(
            paramsJSON: Data("{\"project_id\":\"\(projectId)\"}".utf8), registry: reg)
        let edges = try JSONDecoder().decode([ListAllLinksTool.Edge].self, from: json)

        XCTAssertTrue(edges.contains {
            $0.kind == "piece_research" && $0.from_id == piece.id && $0.to_id == owned.id
        }, "containment must surface as a piece_research edge; edges: \(edges)")
        XCTAssertFalse(edges.contains {
            $0.kind == "piece_research" && $0.to_title == "Shared Note"
        }, "shared research must not appear as piece_research")
        XCTAssertTrue(edges.contains {
            $0.kind == "piece_research" && $0.from_id == piece.id && $0.to_id == nested.id
        }, "a nested asset of a group moved into the piece is contained; edges: \(edges)")
        XCTAssertFalse(edges.contains {
            $0.kind == "piece_research" && $0.to_id == group.id
        }, "the group node itself is not an asset edge")
        await ds.close()
    }

    /// A dormant manual link (a hand-added link that was then moved into the
    /// piece, so containment now covers it too) must NOT emit both a
    /// `linked_research` AND a `piece_research` edge for the same (piece,
    /// research) pair. Mirror the UI redundancy rule: containment wins, the
    /// linked_research edge is skipped.
    func test_listAllLinks_dormantManualLink_emitsOnlyPieceResearch() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LAL-DORM-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createCollectionProject(named: "C", in: tmp)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let piece = try await store.addLoosePiece(title: "Story A", mode: .prose)
        let note = try await store.addResearchTextNote(parentId: nil, title: "Sarah")
        // Hand-add a manual link, THEN move the note into the piece so
        // containment now covers the same association (link goes dormant).
        try await store.linkResearch(researchId: note.id, toDocumentId: piece.id)
        try await store.moveResearchItems(ids: [note.id], to: .piece(piece.id))
        // Sanity: the dormant manual link is still recorded on the piece.
        XCTAssertTrue(store.linkedResearchIds(forDocumentId: piece.id).contains(note.id))

        let reg = ProjectRegistry()
        reg.register(url: url, store: store)
        let projectId = ProjectIdentifier.id(for: url)
        let json = try await ListAllLinksTool.handle(
            paramsJSON: Data("{\"project_id\":\"\(projectId)\"}".utf8), registry: reg)
        let edges = try JSONDecoder().decode([ListAllLinksTool.Edge].self, from: json)

        let pairEdges = edges.filter { $0.from_id == piece.id && $0.to_id == note.id }
        XCTAssertEqual(pairEdges.count, 1,
            "exactly one edge for the (piece, research) pair; edges: \(edges)")
        XCTAssertEqual(pairEdges.first?.kind, "piece_research",
            "containment wins — the redundant linked_research edge is skipped")
        await ds.close()
    }
}
