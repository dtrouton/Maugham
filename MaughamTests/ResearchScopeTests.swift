import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class ResearchScopeTests: XCTestCase {

    // MARK: - Fixtures

    /// Hand-built single-chapter project (LinkedResearchTests pattern) with one
    /// shared research item, for novel / shortStory / screenplay cases.
    private func makeProject(type: ProjectType) async throws -> (URL, ProjectStore) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("Scope-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research"), withIntermediateDirectories: true)
        try "Chapter 1 content\n".write(
            to: tmp.appendingPathComponent("manuscript/c1.md"),
            atomically: true, encoding: .utf8)
        try "Sarah\n".write(
            to: tmp.appendingPathComponent("research/sarah.md"),
            atomically: true, encoding: .utf8)
        let chapter = StructureItem(
            id: "ch-1", title: "Chapter 1", type: .document,
            path: "manuscript/c1.md")
        let sarah = ResearchItem(
            id: "res-sarah", title: "Sarah", type: .asset, kind: .document,
            path: "research/sarah.md", addedAt: Date())
        let manifest = ProjectManifest(
            type: type, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [chapter], research: [sarah])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        return (tmp, store)
    }

    /// Real collection with one loose piece (PieceResearchTests pattern).
    private func makeCollection() async throws -> (URL, ProjectStore, StructureItem) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScopeColl-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createCollectionProject(named: "T", in: tmp)
        let store = try await ProjectStore.load(from: url)
        let piece = try await store.addLoosePiece(title: "Story A", mode: .prose)
        return (url, store, piece)
    }

    // MARK: - createResearchNote routing

    func test_note_collectionPiece_landsInPieceFolder_noLink() async throws {
        let (_, store, piece) = try await makeCollection()
        let note = try await store.createResearchNote(
            scope: .document(piece.id), title: "Sarah Notes")
        XCTAssertTrue(note.path?.hasPrefix("pieces/01-story-a/research/") == true,
                      "got: \(note.path ?? "nil")")
        XCTAssertEqual(store.linkedResearchIds(forDocumentId: piece.id), [],
                       "containment must not also write linkedResearchIds")
    }

    func test_note_novelChapter_sharedPlusLink() async throws {
        let (_, store) = try await makeProject(type: .novel)
        let note = try await store.createResearchNote(
            scope: .document("ch-1"), title: "Backstory")
        XCTAssertTrue(note.path?.hasPrefix("research/") == true,
                      "got: \(note.path ?? "nil")")
        XCTAssertTrue(store.linkedResearchIds(forDocumentId: "ch-1").contains(note.id))
    }

    func test_note_shortStory_sharedOnly_noLink() async throws {
        let (_, store) = try await makeProject(type: .shortStory)
        let note = try await store.createResearchNote(
            scope: .document("ch-1"), title: "Backstory")
        XCTAssertTrue(note.path?.hasPrefix("research/") == true)
        XCTAssertEqual(store.linkedResearchIds(forDocumentId: "ch-1"), [],
                       "single-doc derivation covers it; no redundant link")
    }

    func test_note_sharedScope_matchesLegacyBehavior() async throws {
        let (_, store) = try await makeProject(type: .novel)
        let note = try await store.createResearchNote(scope: .shared, title: "Loose Idea")
        XCTAssertTrue(note.path?.hasPrefix("research/") == true)
        XCTAssertEqual(store.linkedResearchIds(forDocumentId: "ch-1"), [])
    }

    func test_note_unknownDocId_throws() async throws {
        let (_, store) = try await makeProject(type: .novel)
        do {
            _ = try await store.createResearchNote(scope: .document("nope"), title: "x")
            XCTFail("expected throw")
        } catch { /* expected — fail loudly, never fall back to shared */ }
    }

    func test_note_collectionReferencePiece_throws() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScopeRef-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let ref = StructureItem(
            id: "ref-1", title: "Elsewhere", type: .document,
            path: nil, pieceKind: .reference)
        let manifest = ProjectManifest(
            type: .collection, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [ref], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        do {
            _ = try await store.createResearchNote(scope: .document("ref-1"), title: "x")
            XCTFail("expected throw for reference piece")
        } catch { /* expected */ }
        XCTAssertFalse(store.isResearchScopeTarget("ref-1"))
    }

    // MARK: - createResearchLink routing

    func test_link_collectionPiece_syntheticPathUnderPieceFolder() async throws {
        let (_, store, piece) = try await makeCollection()
        let link = try await store.createResearchLink(
            scope: .document(piece.id), title: "Wiki", url: "https://example.com")
        XCTAssertTrue(link.path?.hasPrefix("pieces/01-story-a/research/") == true,
                      "got: \(link.path ?? "nil")")
        XCTAssertEqual(link.kind, .link)
    }

    // MARK: - derivedResearchItems

    func test_derived_collectionPiece_returnsContainmentItems() async throws {
        let (_, store, piece) = try await makeCollection()
        let note = try await store.addPieceResearchNote(pieceId: piece.id, title: "Owned")
        _ = try await store.addResearchTextNote(parentId: nil, title: "Shared Note")
        let derived = store.derivedResearchItems(forDocumentId: piece.id)
        XCTAssertEqual(derived.map(\.id), [note.id])
    }

    func test_derived_novelChapter_isEmpty() async throws {
        let (_, store) = try await makeProject(type: .novel)
        XCTAssertEqual(store.derivedResearchItems(forDocumentId: "ch-1"), [])
    }

    func test_derived_singleDoc_returnsAllAssets() async throws {
        let (_, store) = try await makeProject(type: .screenplay)
        let derived = store.derivedResearchItems(forDocumentId: "ch-1")
        XCTAssertEqual(derived.map(\.id), ["res-sarah"])
    }

    // MARK: - linkableResearchItems (picker exclusion)

    func test_linkable_excludesDerivedItems() async throws {
        let (_, store, piece) = try await makeCollection()
        let owned = try await store.addPieceResearchNote(pieceId: piece.id, title: "Owned")
        let shared = try await store.addResearchTextNote(parentId: nil, title: "Shared Note")
        let linkable = store.linkableResearchItems(forDocumentId: piece.id)
        XCTAssertFalse(linkable.contains { $0.id == owned.id },
                       "derived items must not be offered for linking")
        XCTAssertTrue(linkable.contains { $0.id == shared.id })
    }

    // MARK: - researchScopeTargets

    func test_scopeTargets_novel_listsDocuments() async throws {
        let (_, store) = try await makeProject(type: .novel)
        XCTAssertEqual(store.researchScopeTargets().map(\.id), ["ch-1"])
    }
}
