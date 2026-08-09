import XCTest
import MaughamCore
@testable import Maugham

/// CHARACTERISATION of the capture inbox (`InboxStore` + its promote siblings,
/// the pane's transitions, and the surfaces' failure honesty) — the register's
/// M8-IN claims, `register/reconciliation/Inbox.{claims,filings}.json`.
///
/// Much of this module was already pinned by its production suites
/// (`InboxStoreLastWinsTests`, `InboxMonotonicWrittenAtTests`,
/// `InboxPromoteTests`, `InboxToCanvasTests`, `InboxTranscriptionWorkerTests`)
/// — several claims cite those pins rather than duplicating them. This file
/// pins what was NOT pinned: the failure exits after a mutation, the sibling
/// asymmetries, and the inbox-local disposal state.
@MainActor
final class InboxCharacterization: XCTestCase {

    private var keepAlive: [DocumentStore] = []

    override func tearDown() async throws {
        for ds in keepAlive { await ds.close() }
        keepAlive = []
    }

    private func openProject() async throws -> (URL, ProjectStore, InboxStore) {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-char-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createNovelProject(named: "InboxChar", in: parent)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        keepAlive.append(ds)
        for sub in ["audio", "images"] {
            try FileManager.default.createDirectory(
                at: url.appendingPathComponent(".maugham/inbox/\(sub)"),
                withIntermediateDirectories: true)
        }
        return (url, store, InboxStore(projectURL: url, deviceId: "mac"))
    }

    private func seed(_ url: URL, _ entries: [InboxEntry]) async throws {
        let file = url.appendingPathComponent(".maugham/inbox/inbox.seed.jsonl")
        let s = JSONLAppendStore<InboxEntry>(fileURL: file)
        for e in entries { try await s.append(e) }
    }

    /// This Mac's own manifest path for the "mac" device id the tests use.
    private func ownManifest(_ url: URL) -> URL {
        InboxManifest.inboxManifestURL(forDeviceSlug: DeviceSlug.make(from: "mac"),
                                       in: url)
    }

    /// Make every append to this device's manifest fail: a directory squats on
    /// the JSONL path. Reads survive (`try?` per file), so `refresh()` still
    /// sees the seed file.
    private func sabotageAppends(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: ownManifest(url), withIntermediateDirectories: true)
    }

    private func healAppends(_ url: URL) throws {
        try FileManager.default.removeItem(at: ownManifest(url))
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    // MARK: - The research promote's failure honesty (M8-IN-001, M8-IN-002)

    /// M8-IN-001 — the text arm's body write is a swallowed `try?`: a failed
    /// write produces an EMPTY research note with the entry flipped
    /// `.promoted` and both surfaces told success — the capture's words then
    /// survive only in the promoted-hidden manifest history. Pinned as a
    /// source census (there is no injection seam between the note's creation
    /// and the body write); the fix makes the write part of the throwing path.
    func test_theResearchTextPromoteBodyWriteIsSwallowed() throws {
        let source = try String(
            contentsOf: repoRoot().appendingPathComponent("Maugham/Stores/InboxStore.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains("try? (entry.inlineText ?? \"\").write("),
                      "M8-IN-001: the body write is swallowed — if this census "
                      + "fails, the write has a throwing channel now; restate the "
                      + "claim and flip its filing")
    }

    /// M8-IN-002 — the asset arm trashes the inbox original BEFORE a
    /// NON-throwing status flip. When the flip's append fails, the promote
    /// still returns the created item (success on both surfaces), the entry
    /// stays `.new` in the pane, and — the original being gone — every retry
    /// hits `assetMissing` permanently. The palette and canvas siblings both
    /// order copy → throwing flip → remove; this is the one that does not.
    func test_aResearchAssetPromoteWhoseFlipFailsReportsSuccessAndStrandsTheEntry() async throws {
        let (url, store, inbox) = try await openProject()
        try Data([0x52, 0x49, 0x46, 0x46]).write(
            to: url.appendingPathComponent(".maugham/inbox/audio/a1.m4a"))
        try await seed(url, [InboxEntry(
            id: "a1", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .audio, sourceFilename: "a1.m4a",
            transcript: "the fog came in")])
        await inbox.refresh()
        let entry = try XCTUnwrap(inbox.entries.first { $0.id == "a1" })

        try sabotageAppends(url)
        // No throw: the promote reports SUCCESS while its terminal flip failed.
        let created = try await inbox.promoteToResearch(entry, projectStore: store)
        XCTAssertNotNil(created.path, "the research copy exists")

        await inbox.refresh()
        XCTAssertTrue(inbox.entries.contains { $0.id == "a1" },
                      "the entry is still .new in the pane — the flip never landed")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(".maugham/inbox/audio/a1.m4a").path),
            "while the inbox original is already gone (trashed before the flip)")

        // And the stranding is permanent: the retry the pane invites fails.
        try healAppends(url)
        do {
            _ = try await inbox.promoteToResearch(entry, projectStore: store)
            XCTFail("expected assetMissing on retry")
        } catch InboxStore.InboxError.assetMissing {}
    }

    // MARK: - The retry asymmetries (M8-IN-003, M8-IN-004)

    /// M8-IN-003 — the palette NOTE arm converges on retry (last-note dedup);
    /// the palette IMAGE arm does not: a retry after a failed flip appends a
    /// SECOND copy of the picture to the card's well.
    func test_aPaletteImageRetryAppendsASecondImage() async throws {
        let (url, store, inbox) = try await openProject()
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        try Data(png).write(to: url.appendingPathComponent(".maugham/inbox/images/p1.png"))
        try await seed(url, [InboxEntry(
            id: "p1", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .image, sourceFilename: "p1.png")])
        await inbox.refresh()
        let entry = try XCTUnwrap(inbox.entries.first { $0.id == "p1" })
        let card = try await store.addPaletteCard(title: "Fog", kind: .location)

        try sabotageAppends(url)
        do {
            _ = try await inbox.promoteToPaletteCard(
                entry, projectStore: store, cardId: card.id)
            XCTFail("expected the throwing flip to fail")
        } catch {}
        try healAppends(url)
        await inbox.refresh()
        let retryEntry = try XCTUnwrap(inbox.entries.first { $0.id == "p1" })
        _ = try await inbox.promoteToPaletteCard(
            retryEntry, projectStore: store, cardId: card.id)

        let after = try XCTUnwrap(store.loadPaletteCards()
            .first { $0.researchItemId == card.id })
        XCTAssertEqual(after.imagePaths.count, 2,
                       "M8-IN-003: the retry appended a second copy — the note "
                       + "arm's dedup has no image twin")
    }

    /// M8-IN-004 — the canvas sibling has the same retry shape: a failed flip
    /// leaves the card on the canvas, and the retry lands a SECOND one.
    /// (Detached route — no canvas open — so the sidecar is the scene.)
    func test_aCanvasRetryLandsASecondNode() async throws {
        let (url, store, inbox) = try await openProject()
        try await seed(url, [InboxEntry(
            id: "t1", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .text, inlineText: "A thought.")])
        await inbox.refresh()
        let entry = try XCTUnwrap(inbox.entries.first { $0.id == "t1" })

        try sabotageAppends(url)
        do {
            _ = try await inbox.sendToCanvas(entry, projectStore: store, placement: .loose)
            XCTFail("expected the throwing flip to fail")
        } catch {}
        try healAppends(url)
        await inbox.refresh()
        let retryEntry = try XCTUnwrap(inbox.entries.first { $0.id == "t1" })
        _ = try await inbox.sendToCanvas(retryEntry, projectStore: store, placement: .loose)

        let scene = CanvasStore(projectRoot: url).load().scene
        XCTAssertEqual(scene.count, 2,
                       "M8-IN-004: two cards carry the one capture's words")
    }

    // MARK: - The silent pane transitions (M8-IN-006)

    /// M8-IN-006 — a pane transition (trash here; restore and the transcript
    /// edit share the channel) whose manifest append fails completes silently:
    /// `updateStatus` has no throwing path, the row springs back on refresh,
    /// and nothing tells the writer why their click did not take.
    func test_aTrashClickWhoseAppendFailsIsSilent() async throws {
        let (url, _, inbox) = try await openProject()
        try await seed(url, [InboxEntry(
            id: "t1", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .text, inlineText: "Keep me.")])
        await inbox.refresh()

        try sabotageAppends(url)
        await inbox.updateStatus(id: "t1", to: .trashed)   // completes, no signal

        await inbox.refresh()
        XCTAssertTrue(inbox.entries.contains { $0.id == "t1" },
                      "the row is still .new — the click did not take, and the "
                      + "only witness is an os_log line")
        XCTAssertTrue(inbox.trashedEntries.isEmpty)
    }

    // MARK: - The inbox-local disposal state (M8-IN-011)

    /// M8-IN-011 — a trashed capture is a THIRD disposal state: a status flip
    /// only. The asset never leaves `inbox/`, the project Trash never sees it,
    /// no retention sweep reaches it, and restore is a clean flip back. (The
    /// project trash's 30-day sweep is `TrashStore`'s; nothing enumerates
    /// `trashedEntries` for disposal anywhere.)
    func test_aTrashedCaptureIsAnInboxLocalStateTheProjectTrashNeverSees() async throws {
        let (url, store, inbox) = try await openProject()
        try Data([0x00]).write(
            to: url.appendingPathComponent(".maugham/inbox/audio/a1.m4a"))
        try await seed(url, [InboxEntry(
            id: "a1", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .audio, sourceFilename: "a1.m4a",
            transcript: "hold this")])
        await inbox.refresh()

        await inbox.updateStatus(id: "a1", to: .trashed)
        await inbox.refresh()

        XCTAssertTrue(inbox.trashedEntries.contains { $0.id == "a1" })
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(".maugham/inbox/audio/a1.m4a").path),
            "the asset never moves")
        XCTAssertTrue(store.trashEntries.isEmpty,
                      "the project Trash holds nothing for it")

        await inbox.restore(id: "a1")
        await inbox.refresh()
        XCTAssertTrue(inbox.entries.contains { $0.id == "a1" },
                      "restore is a clean flip back to .new")
    }

    // MARK: - The unreadable manifest (M8-IN-012)

    /// M8-IN-012 — an unreadable per-device manifest is presented as EMPTY:
    /// `refresh()` wraps each file's load in `try? … ?? []`, so every capture
    /// from that device vanishes from the pane with nothing said anywhere.
    /// RULING-7's clause is literal about this shape: unreadable is never
    /// presented as empty.
    func test_anUnreadableDeviceManifestVanishesSilently() async throws {
        let (url, _, inbox) = try await openProject()
        try await seed(url, [InboxEntry(
            id: "t1", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .text, inlineText: "From the phone.")])
        await inbox.refresh()
        XCTAssertEqual(inbox.entries.count, 1, "fixture: the capture is visible")

        // The device file becomes unreadable (a directory squats on its path —
        // the same failure shape as a permissions break or an iCloud stub).
        let seedFile = url.appendingPathComponent(".maugham/inbox/inbox.seed.jsonl")
        try FileManager.default.removeItem(at: seedFile)
        try FileManager.default.createDirectory(at: seedFile, withIntermediateDirectories: true)

        await inbox.refresh()
        XCTAssertTrue(inbox.entries.isEmpty,
                      "M8-IN-012: the device's captures are gone from the pane")
        XCTAssertTrue(inbox.trashedEntries.isEmpty, "nowhere else either")
        // And no API carries the failure: the store exposes only the two lists.
    }

    // MARK: - Census pins (M8-IN-005, M8-IN-007, M8-IN-008)

    /// M8-IN-005 — `trashPromotedAsset` is non-throwing and log-only by
    /// design: the promotion has succeeded and a failed retirement leaves a
    /// duplicate rather than a loss. The residue the filing records: the
    /// leftover original is invisible forever — `.promoted` rows are filtered
    /// from both pane lists, so no surface will ever show it.
    func test_theAssetRetirementIsBestEffortByDesign() throws {
        let source = try String(
            contentsOf: repoRoot().appendingPathComponent("Maugham/Stores/InboxStore.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains("private func trashPromotedAsset("),
                      "the retirement helper exists")
        XCTAssertFalse(source.contains("private func trashPromotedAsset(") &&
                       source.range(of: "private func trashPromotedAsset")
                        .map { source[$0.lowerBound...].prefix(200).contains("throws") } ?? false,
                       "and it is non-throwing — a failure is logged, never thrown "
                       + "over a promotion that succeeded")
    }

    /// M8-IN-007 — the phone writer's image/audio ingest writes the asset
    /// BEFORE the manifest row, so a crash between the two leaves an orphan
    /// asset no surface will ever list and nothing sweeps.
    func test_thePhoneIngestWritesTheAssetBeforeTheManifestRow() throws {
        let source = try String(
            contentsOf: repoRoot().appendingPathComponent(
                "MaughamPhone/Capture/InboxCaptureWriter.swift"),
            encoding: .utf8)
        // Scoped to the image arm: writeImage's body runs from its declaration
        // to writeAudio's, and inside it the asset write precedes the row.
        let imageArm = try XCTUnwrap(source.range(of: "func writeImage("))
        let audioArm = try XCTUnwrap(source.range(of: "func writeAudio("))
        let body = source[imageArm.lowerBound..<audioArm.lowerBound]
        let assetWrite = try XCTUnwrap(body.range(of: "coordinatedWrite("))
        let manifestAppend = try XCTUnwrap(body.range(of: "appendManifest("))
        XCTAssertLessThan(assetWrite.lowerBound, manifestAppend.lowerBound,
                          "asset first, row second — the orphan window is the "
                          + "gap between them (the audio arm shares the shape)")
    }

    /// M8-IN-008 — the MCP tools resolve entries against the `.new` list
    /// only, so a TRASHED capture — visible and restorable in the pane —
    /// answers "not found or already resolved" through `promote_inbox_entry`.
    /// Deliberate scope (read + promote only, no trash access), pinned so the
    /// divergence is a decision rather than a surprise.
    func test_theMCPToolsCannotSeeATrashedCaptureThePaneCanRestore() async throws {
        let (url, _, inbox) = try await openProject()
        try await seed(url, [InboxEntry(
            id: "t1", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .text, inlineText: "Trashed.")])
        await inbox.refresh()
        await inbox.updateStatus(id: "t1", to: .trashed)
        await inbox.refresh()

        XCTAssertTrue(inbox.trashedEntries.contains { $0.id == "t1" },
                      "the pane's trash view can see and restore it")
        XCTAssertFalse(inbox.entries.contains { $0.id == "t1" },
                       "while `entries` — the ONLY list the MCP tools read "
                       + "(ListInboxTool / PromoteInboxEntryTool) — cannot")
        let source = try String(
            contentsOf: repoRoot().appendingPathComponent("Maugham/MCP/Tools/InboxTools.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains("not found or already resolved")
                        || source.contains("entryNotFound"),
                      "and the tool's answer for it is the not-found refusal")
    }
}
