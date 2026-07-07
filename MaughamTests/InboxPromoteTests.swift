import XCTest
import MaughamCore
@testable import Maugham

/// InboxStore.promoteToResearch — the shared logic behind both the InboxPane
/// "Promote to Research" action and the MCP `promote_inbox_entry` tool.
@MainActor
final class InboxPromoteTests: XCTestCase {

    // ProjectStore.documentStore is `weak`, so the test must hold the
    // DocumentStore strongly — addResearchAsset throws "DocumentStore not
    // available" if it's deallocated. Hence it's returned and bound per-test.
    private func openProject() async throws
        -> (URL, ProjectStore, InboxStore, DocumentStore) {
        // Manual temp dir (no auto-cleanup) — matching InboxStoreLastWinsTests.
        // A `TempDirectory` value would deinit when this helper returns and
        // delete the project (incl. seeded inbox assets) before the test runs.
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("promote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createNovelProject(named: "Promote", in: parent)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent(".maugham/inbox/audio"),
            withIntermediateDirectories: true)
        return (url, store, InboxStore(projectURL: url, deviceId: "mac"), ds)
    }

    private func seed(_ url: URL, _ entries: [InboxEntry]) async throws {
        let file = url.appendingPathComponent(".maugham/inbox/inbox.seed.jsonl")
        let s = JSONLAppendStore<InboxEntry>(fileURL: file)
        for e in entries { try await s.append(e) }
    }

    func test_promoteText_createsResearchNote_andHidesEntry() async throws {
        let (url, store, inbox, ds) = try await openProject()
        let beforeCount = store.manifest.research.count
        try await seed(url, [InboxEntry(
            id: "t1", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .text, inlineText: "Promote this idea.")])
        await inbox.refresh()
        let entry = try XCTUnwrap(inbox.entries.first { $0.id == "t1" })

        let created = try await inbox.promoteToResearch(entry, projectStore: store)

        XCTAssertEqual(store.manifest.research.count, beforeCount + 1,
                       "a research item is created")
        // The note body was written to disk.
        let body = try String(contentsOf: url.appendingPathComponent(created.path!),
                              encoding: .utf8)
        XCTAssertEqual(body, "Promote this idea.")
        // The entry left the pane (promoted is terminal).
        XCTAssertFalse(inbox.entries.contains { $0.id == "t1" })
        withExtendedLifetime(ds) {}   // documentStore is weak; keep it alive
    }

    func test_promoteAudio_copiesAssetIntoResearch_removesInboxOriginal_hidesEntry() async throws {
        let (url, store, inbox, ds) = try await openProject()
        let assetURL = url.appendingPathComponent(".maugham/inbox/audio/a1.m4a")
        try Data("fake-audio".utf8).write(to: assetURL)
        try await seed(url, [InboxEntry(
            id: "a1", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .audio, sourceFilename: "a1.m4a",
            transcript: "a dictated line", transcriptionState: .whisperFinal)])
        await inbox.refresh()
        let entry = try XCTUnwrap(inbox.entries.first { $0.id == "a1" })

        let created = try await inbox.promoteToResearch(entry, projectStore: store)

        // Asset copied into research/ …
        let researchAsset = url.appendingPathComponent(created.path!)
        XCTAssertTrue(FileManager.default.fileExists(atPath: researchAsset.path))
        // … and the inbox original removed to complete the move.
        XCTAssertFalse(FileManager.default.fileExists(atPath: assetURL.path),
                       "inbox original is removed after promote")
        XCTAssertFalse(inbox.entries.contains { $0.id == "a1" })
        withExtendedLifetime(ds) {}   // documentStore is weak; keep it alive
    }

    func test_promoteAudio_missingAsset_throws() async throws {
        let (url, store, inbox, ds) = try await openProject()
        try await seed(url, [InboxEntry(
            id: "gone", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .audio, sourceFilename: "missing.m4a")])
        await inbox.refresh()
        let entry = try XCTUnwrap(inbox.entries.first { $0.id == "gone" })
        do {
            _ = try await inbox.promoteToResearch(entry, projectStore: store)
            XCTFail("expected assetMissing")
        } catch InboxStore.InboxError.assetMissing { /* expected */ }
        withExtendedLifetime(ds) {}
    }

    // MARK: - Scoped promotion (spec 2026-07-07)

    private func openCollection() async throws
        -> (URL, ProjectStore, InboxStore, DocumentStore, StructureItem) {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("promote-coll-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createCollectionProject(named: "PC", in: parent)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let piece = try await store.addLoosePiece(title: "Story A", mode: .prose)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent(".maugham/inbox/audio"),
            withIntermediateDirectories: true)
        return (url, store, InboxStore(projectURL: url, deviceId: "mac"), ds, piece)
    }

    func test_promoteText_pieceScope_landsInPieceFolder() async throws {
        let (url, store, inbox, ds, piece) = try await openCollection()
        try await seed(url, [InboxEntry(
            id: "tp1", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .text, inlineText: "Piece-scoped idea.")])
        await inbox.refresh()
        let entry = try XCTUnwrap(inbox.entries.first { $0.id == "tp1" })

        let created = try await inbox.promoteToResearch(
            entry, projectStore: store, scope: .document(piece.id))

        XCTAssertTrue(created.path?.hasPrefix("pieces/01-story-a/research/") == true,
                      "got: \(created.path ?? "nil")")
        let body = try String(contentsOf: url.appendingPathComponent(created.path!),
                              encoding: .utf8)
        XCTAssertEqual(body, "Piece-scoped idea.")
        XCTAssertFalse(inbox.entries.contains { $0.id == "tp1" })
        withExtendedLifetime(ds) {}
    }

    func test_promoteAudio_pieceScope_assetLandsInPieceFolder_originalRemoved() async throws {
        let (url, store, inbox, ds, piece) = try await openCollection()
        let assetURL = url.appendingPathComponent(".maugham/inbox/audio/p1.m4a")
        try Data("fake-audio".utf8).write(to: assetURL)
        try await seed(url, [InboxEntry(
            id: "pa1", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .audio, sourceFilename: "p1.m4a",
            transcript: "dictated", transcriptionState: .whisperFinal)])
        await inbox.refresh()
        let entry = try XCTUnwrap(inbox.entries.first { $0.id == "pa1" })

        let created = try await inbox.promoteToResearch(
            entry, projectStore: store, scope: .document(piece.id))

        XCTAssertTrue(created.path?.hasPrefix("pieces/01-story-a/research/") == true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(created.path!).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: assetURL.path))
        withExtendedLifetime(ds) {}
    }

    func test_promoteText_novelChapterScope_createsLink() async throws {
        let (url, store, inbox, ds) = try await openProject()
        let chapterId = try XCTUnwrap(
            TreeWalk.collect(in: store.manifest.structure,
                             where: { $0.type == .document }).first?.id)
        try await seed(url, [InboxEntry(
            id: "tn1", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .text, inlineText: "Chapter-scoped idea.")])
        await inbox.refresh()
        let entry = try XCTUnwrap(inbox.entries.first { $0.id == "tn1" })

        let created = try await inbox.promoteToResearch(
            entry, projectStore: store, scope: .document(chapterId))

        XCTAssertTrue(created.path?.hasPrefix("research/") == true)
        XCTAssertTrue(store.linkedResearchIds(forDocumentId: chapterId).contains(created.id))
        withExtendedLifetime(ds) {}
    }

    func test_promote_unknownTargetId_throws_andEntryStaysNew() async throws {
        let (url, store, inbox, ds) = try await openProject()
        try await seed(url, [InboxEntry(
            id: "tx1", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .text, inlineText: "Orphan idea.")])
        await inbox.refresh()
        let entry = try XCTUnwrap(inbox.entries.first { $0.id == "tx1" })
        do {
            _ = try await inbox.promoteToResearch(
                entry, projectStore: store, scope: .document("doc-nope"))
            XCTFail("expected throw")
        } catch { /* expected — fail loudly, no shared fallback */ }
        XCTAssertTrue(inbox.entries.contains { $0.id == "tx1" },
                      "failed promote must leave the entry in the inbox")
        withExtendedLifetime(ds) {}
    }
}
