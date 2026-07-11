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
        XCTAssertFalse(inbox.entries.contains { $0.id == "pa1" })
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
        } catch is ProjectStoreError { /* expected — fail loudly, no shared fallback */ }
        XCTAssertTrue(inbox.entries.contains { $0.id == "tx1" },
                      "failed promote must leave the entry in the inbox")
        withExtendedLifetime(ds) {}
    }

    // MARK: - Promote into a palette card (Task 7)

    /// Seed an inbox image asset under `.maugham/inbox/images/`.
    private func seedImageAsset(_ url: URL, name: String) throws -> URL {
        let dir = url.appendingPathComponent(".maugham/inbox/images")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let asset = dir.appendingPathComponent(name)
        try Data("fake-image".utf8).write(to: asset)
        return asset
    }

    func test_promoteText_toPaletteCard_appendsTaggedNote_andHidesEntry() async throws {
        let (url, store, inbox, ds) = try await openProject()
        let card = try await store.addPaletteCard(title: "The Flat", kind: .location)
        try await seed(url, [InboxEntry(
            id: "pt1", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .text, inlineText: "turpentine and cold ash",
            paletteSubject: "The Flat", sense: "smell")])
        await inbox.refresh()
        let entry = try XCTUnwrap(inbox.entries.first { $0.id == "pt1" })

        let result = try await inbox.promoteToPaletteCard(
            entry, projectStore: store, cardId: card.id)

        let note = try XCTUnwrap(result.notes.last)
        XCTAssertEqual(note.sense, .smell)
        XCTAssertEqual(note.text, "turpentine and cold ash")
        // Persisted, not just returned.
        let reloaded = try XCTUnwrap(
            store.loadPaletteCards().first { $0.researchItemId == card.id })
        XCTAssertEqual(reloaded.notes.last?.sense, .smell)
        XCTAssertEqual(reloaded.notes.last?.text, "turpentine and cold ash")
        XCTAssertFalse(inbox.entries.contains { $0.id == "pt1" })
        withExtendedLifetime(ds) {}
    }

    func test_promoteText_toPaletteCard_noSense_appendsUntaggedNote() async throws {
        let (url, store, inbox, ds) = try await openProject()
        let card = try await store.addPaletteCard(title: "The Flat", kind: .location)
        try await seed(url, [InboxEntry(
            id: "pt2", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .text, inlineText: "just a plain observation",
            paletteSubject: "The Flat")])
        await inbox.refresh()
        let entry = try XCTUnwrap(inbox.entries.first { $0.id == "pt2" })

        let result = try await inbox.promoteToPaletteCard(
            entry, projectStore: store, cardId: card.id)

        XCTAssertNil(result.notes.last?.sense, "no/absent sense → untagged")
        XCTAssertEqual(result.notes.last?.text, "just a plain observation")
        withExtendedLifetime(ds) {}
    }

    func test_promoteImage_toPaletteCard_landsInAssets_removesInboxOriginal() async throws {
        let (url, store, inbox, ds) = try await openProject()
        let card = try await store.addPaletteCard(title: "Marlowe", kind: .character)
        let asset = try seedImageAsset(url, name: "img1.png")
        try await seed(url, [InboxEntry(
            id: "pi1", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .image, sourceFilename: "img1.png",
            paletteSubject: "Marlowe")])
        await inbox.refresh()
        let entry = try XCTUnwrap(inbox.entries.first { $0.id == "pi1" })

        let result = try await inbox.promoteToPaletteCard(
            entry, projectStore: store, cardId: card.id)

        let addedPath = try XCTUnwrap(result.imagePaths.last)
        XCTAssertTrue(addedPath.contains("_assets/"), "got: \(addedPath)")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(addedPath).path),
            "image copied into the card's asset well")
        XCTAssertFalse(FileManager.default.fileExists(atPath: asset.path),
                       "inbox original removed to complete the move")
        XCTAssertFalse(inbox.entries.contains { $0.id == "pi1" })
        withExtendedLifetime(ds) {}
    }

    func test_promoteAudio_toPaletteCard_withTranscript_appendsNote() async throws {
        let (url, store, inbox, ds) = try await openProject()
        let card = try await store.addPaletteCard(title: "The Flat", kind: .location)
        try await seed(url, [InboxEntry(
            id: "pa1", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .audio, sourceFilename: "pa1.m4a",
            transcript: "tram-rattle through the shutters",
            transcriptionState: .whisperFinal,
            paletteSubject: "The Flat", sense: "sound")])
        await inbox.refresh()
        let entry = try XCTUnwrap(inbox.entries.first { $0.id == "pa1" })

        let result = try await inbox.promoteToPaletteCard(
            entry, projectStore: store, cardId: card.id)

        XCTAssertEqual(result.notes.last?.sense, .sound)
        XCTAssertEqual(result.notes.last?.text, "tram-rattle through the shutters")
        XCTAssertFalse(inbox.entries.contains { $0.id == "pa1" })
        withExtendedLifetime(ds) {}
    }

    func test_promoteAudio_toPaletteCard_emptyTranscript_throws_andEntryStaysNew() async throws {
        let (url, store, inbox, ds) = try await openProject()
        let card = try await store.addPaletteCard(title: "The Flat", kind: .location)
        try await seed(url, [InboxEntry(
            id: "pa2", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .audio, sourceFilename: "pa2.m4a",
            transcript: "   ", transcriptionState: .none,
            paletteSubject: "The Flat")])
        await inbox.refresh()
        let entry = try XCTUnwrap(inbox.entries.first { $0.id == "pa2" })
        do {
            _ = try await inbox.promoteToPaletteCard(
                entry, projectStore: store, cardId: card.id)
            XCTFail("expected nothingToPromote")
        } catch InboxStore.InboxError.nothingToPromote { /* expected */ }
        XCTAssertTrue(inbox.entries.contains { $0.id == "pa2" },
                      "empty-transcript promote must leave the entry .new")
        // The card gained no note from the failed attempt.
        let reloaded = try XCTUnwrap(
            store.loadPaletteCards().first { $0.researchItemId == card.id })
        XCTAssertTrue(reloaded.notes.isEmpty)
        withExtendedLifetime(ds) {}
    }

    func test_promote_toPaletteCard_unknownCardId_throws_andEntryStaysNew() async throws {
        let (url, store, inbox, ds) = try await openProject()
        try await seed(url, [InboxEntry(
            id: "px1", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .text, inlineText: "orphan")])
        await inbox.refresh()
        let entry = try XCTUnwrap(inbox.entries.first { $0.id == "px1" })
        do {
            _ = try await inbox.promoteToPaletteCard(
                entry, projectStore: store, cardId: "card-nope")
            XCTFail("expected throw")
        } catch is ProjectStoreError { /* expected — fail loudly */ }
        XCTAssertTrue(inbox.entries.contains { $0.id == "px1" })
        withExtendedLifetime(ds) {}
    }
}
