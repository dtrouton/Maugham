import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class MoveResearchItemToolTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    private func makeRegistry() async throws
        -> (ProjectRegistry, ProjectStore, DocumentStore, StructureItem, String) {
        let url = try await ProjectFactory.createCollectionProject(
            named: "MCPMove", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let piece = try await store.addLoosePiece(title: "Story A", format: .markdown)
        let registry = ProjectRegistry()
        registry.register(url: url, store: store)
        let projectId = ProjectIdentifier.id(for: url)
        return (registry, store, ds, piece, projectId)
    }

    private func params(_ dict: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: dict)
    }

    /// **The assistant's move says whose the note now is** (closing round A,
    /// branch I1): out of a chapter's group to shared research it is
    /// whole-book; into it, that chapter's. Same rule as the tree's.
    func test_aMoveSaysWhoseTheNoteNowIs() async throws {
        let url = try await ProjectFactory.createNovelProject(named: "MCPMoveNovel", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let harbour = try await store.addResearchItem(parentId: nil, title: "Harbour", kind: nil)
        let tides = try await store.addResearchTextNote(parentId: harbour.id, title: "Tide tables")
        try await store.linkResearch(researchId: harbour.id, toDocumentId: chapter.id)
        let registry = ProjectRegistry()
        registry.register(url: url, store: store)
        let projectId = ProjectIdentifier.id(for: url)

        let out = try JSONDecoder().decode(MoveResearchItemTool.Result.self, from: try await MoveResearchItemTool.handle(
            paramsJSON: params(["project_id": projectId, "research_ids": [tides.id], "target": "shared"]),
            registry: registry))
        XCTAssertEqual(out.moved.map(\.home), ["whole-book"])
        XCTAssertEqual(out.moved.first?.left, [chapter.title],
                       "it left Chapter One, through the group it stood in (A3)")
        let back = try JSONDecoder().decode(MoveResearchItemTool.Result.self, from: try await MoveResearchItemTool.handle(
            paramsJSON: params(["project_id": projectId, "research_ids": [tides.id],
                                "target_group_id": harbour.id]),
            registry: registry))
        XCTAssertEqual(back.moved.map(\.home), ["\u{201C}\(chapter.title)\u{201D}\u{2019}s"])
        await ds.close()
    }

    /// **To shared research, a note's own links go** (closing round A2): the
    /// answer says whole-book and names the chapter it left.
    func test_aMoveToSharedResearchLeavesTheChaptersItWasLinkedTo() async throws {
        let url = try await ProjectFactory.createNovelProject(named: "MCPMoveLinks", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let group = try await store.addResearchItem(parentId: nil, title: "Harbour", kind: nil)
        let note = try await store.addResearchTextNote(parentId: group.id, title: "Hull")
        try await store.linkResearch(researchId: note.id, toDocumentId: chapter.id)
        let registry = ProjectRegistry()
        registry.register(url: url, store: store)
        let projectId = ProjectIdentifier.id(for: url)
        let saves = store.manifestSaveCount
        let out = try JSONDecoder().decode(MoveResearchItemTool.Result.self, from: try await MoveResearchItemTool.handle(
            paramsJSON: params(["project_id": projectId, "research_ids": [note.id], "target": "shared"]),
            registry: registry))
        XCTAssertEqual(out.moved.map(\.home), ["whole-book"])
        XCTAssertEqual(out.moved.first?.left, [chapter.title])
        XCTAssertEqual(store.manifestSaveCount, saves + 1, "the move and its unlink, one save")
        XCTAssertEqual(store.linkedResearchIds(forDocumentId: chapter.id), [])
        await ds.close()
    }

    func test_moveToPiece_movesFile() async throws {
        let (registry, store, ds, piece, projectId) = try await makeRegistry()
        let note = try await store.addResearchTextNote(parentId: nil, title: "Sarah")

        _ = try await MoveResearchItemTool.handle(
            paramsJSON: params([
                "project_id": projectId,
                "research_ids": [note.id],
                "target_document_id": piece.id]),
            registry: registry)

        let moved = TreeWalk.find(id: note.id, in: store.manifest.research)
        XCTAssertTrue(moved?.path?.hasPrefix("pieces/") == true)
        await ds.close()
    }

    func test_moveToShared() async throws {
        let (registry, store, ds, piece, projectId) = try await makeRegistry()
        let note = try await store.createResearchNote(
            scope: .document(piece.id), title: "Out")

        _ = try await MoveResearchItemTool.handle(
            paramsJSON: params([
                "project_id": projectId,
                "research_ids": [note.id],
                "target": "shared"]),
            registry: registry)

        XCTAssertEqual(
            TreeWalk.find(id: note.id, in: store.manifest.research)?.path,
            "research/out.md")
        await ds.close()
    }

    func test_multipleTargets_failsLoudly() async throws {
        let (registry, store, ds, piece, projectId) = try await makeRegistry()
        let note = try await store.addResearchTextNote(parentId: nil, title: "X")

        await XCTAssertThrowsErrorAsync(
            _ = try await MoveResearchItemTool.handle(
                paramsJSON: params([
                    "project_id": projectId,
                    "research_ids": [note.id],
                    "target": "shared",
                    "target_document_id": piece.id]),
                registry: registry))
        await ds.close()
    }

    func test_noTarget_failsLoudly() async throws {
        let (registry, store, ds, _, projectId) = try await makeRegistry()
        let note = try await store.addResearchTextNote(parentId: nil, title: "X")

        await XCTAssertThrowsErrorAsync(
            _ = try await MoveResearchItemTool.handle(
                paramsJSON: params([
                    "project_id": projectId,
                    "research_ids": [note.id]]),
                registry: registry))
        await ds.close()
    }

    func test_unknownResearchId_failsLoudly() async throws {
        let (registry, _, ds, piece, projectId) = try await makeRegistry()
        await XCTAssertThrowsErrorAsync(
            _ = try await MoveResearchItemTool.handle(
                paramsJSON: params([
                    "project_id": projectId,
                    "research_ids": ["res-nope"],
                    "target_document_id": piece.id]),
                registry: registry))
        await ds.close()
    }

    /// #148 D2: a move whose picture-link rewrite fails stands, and the
    /// result names the note and carries the writer's sentence.
    func test_aMoveWhosePictureLinkRewriteFails_namesTheNoteInTheResult() async throws {
        let (registry, store, ds, piece, projectId) = try await makeRegistry()
        ds.projectStore = store   // the note door finds notes through it
        let url = store.url
        let note = try await store.addResearchTextNote(parentId: nil, title: "Sarah")
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("research/sarah_assets"), withIntermediateDirectories: true)
        try await ds.coordinatedWrite(
            text: "![img](./sarah_assets/img.png)",
            to: url.appendingPathComponent("research/sarah.md"))
        let prefix = try XCTUnwrap(ProjectStore.pieceResearchPrefix(for: piece))
        try FileManager.default.createDirectory(   // dedups the stem: the refs need rewriting
            at: url.appendingPathComponent(prefix).appendingPathComponent("sarah_assets"),
            withIntermediateDirectories: true)
        var locked: URL?
        ds.researchNoteDoor.keepWillRunForTesting = { [store] in
            guard let path = TreeWalk.find(id: note.id, in: store.manifest.research)?.path else { return }
            let folder = url.appendingPathComponent(path).deletingLastPathComponent()
            try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
            locked = folder
        }
        defer {
            if let locked {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            }
        }

        let data = try await MoveResearchItemTool.handle(
            paramsJSON: params([
                "project_id": projectId,
                "research_ids": [note.id],
                "target_document_id": piece.id]),
            registry: registry)

        XCTAssertNotNil(locked, "premise: the rewrite reached the door's write")
        let result = try JSONDecoder().decode(MoveResearchItemTool.Result.self, from: data)
        XCTAssertEqual(result.moved.map(\.id), [note.id])
        XCTAssertTrue(result.moved.first?.path?.hasPrefix(prefix) == true, "the move stands")
        XCTAssertEqual(result.asset_refs_left_in, ["Sarah"])
        XCTAssertEqual(result.notice,
                       "Moved “Sarah”, but the picture links in “Sarah” could not be updated.")
        await ds.close()
    }

    /// A move that left nothing adds nothing to the result.
    func test_aCleanMoveAddsNoNotice() async throws {
        let (registry, store, ds, piece, projectId) = try await makeRegistry()
        let note = try await store.addResearchTextNote(parentId: nil, title: "Sarah")

        let data = try await MoveResearchItemTool.handle(
            paramsJSON: params([
                "project_id": projectId,
                "research_ids": [note.id],
                "target_document_id": piece.id]),
            registry: registry)

        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("asset_refs_left_in"), json)
        XCTAssertFalse(json.contains("notice"), json)
        await ds.close()
    }
}
