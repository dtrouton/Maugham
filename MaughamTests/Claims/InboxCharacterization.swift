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

    /// M8-IN-001 — fixed under RULING-7 (2026-08-09): the text arm's body
    /// write is on the throwing path, BEFORE the flip — a failed write is a
    /// failed promotion, never an empty note reported as a success.
    func test_theResearchTextPromoteBodyWriteThrows() throws {
        let source = try String(
            contentsOf: repoRoot().appendingPathComponent("Maugham/Stores/InboxStore.swift"),
            encoding: .utf8)
        XCTAssertFalse(source.contains("try? (entry.inlineText ?? \"\").write("),
                       "the swallow is gone")
        XCTAssertTrue(source.contains("try (entry.inlineText ?? \"\").write("),
                      "M8-IN-001: the write throws — a failed body write fails "
                      + "the promotion before the flip")
    }

    /// M8-IN-002 — fixed under RULING-7 (2026-08-09): the asset arm adopts
    /// the palette sibling's ordering — copy, THROWING flip, retire. A failed
    /// flip throws, the original stays in place, and the retry succeeds.
    /// (Also pinned in production: `InboxPromoteTests
    /// .test_aFailedStatusFlipThrowsAndLeavesTheOriginalSoARetrySucceeds`.)
    func test_aResearchAssetPromoteWhoseFlipFailsThrowsAndTheRetryLives() async throws {
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
        do {
            _ = try await inbox.promoteToResearch(entry, projectStore: store)
            XCTFail("a failed terminal flip throws — never a silent success")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(".maugham/inbox/audio/a1.m4a").path),
            "the original is still in place — the retry is alive")

        try healAppends(url)
        await inbox.refresh()
        let retryEntry = try XCTUnwrap(inbox.entries.first { $0.id == "a1" })
        _ = try await inbox.promoteToResearch(retryEntry, projectStore: store)
        await inbox.refresh()
        XCTAssertFalse(inbox.entries.contains { $0.id == "a1" },
                       "the retry completes")
    }

    // MARK: - The retry asymmetries (M8-IN-003, M8-IN-004)

    /// M8-IN-003 — fixed under RULING-8 (2026-08-09): the image arm converges
    /// on retry exactly as the note arm does.
    func test_aPaletteImageRetryConverges() async throws {
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
        XCTAssertEqual(after.imagePaths.count, 1,
                       "M8-IN-003, fixed under RULING-8 (2026-08-09): the image "
                       + "arm converges on retry like the note arm — byte-equal "
                       + "dedup against the well's most recent image")
    }

    /// M8-IN-004 — fixed under RULING-8 (2026-08-09): the capture node id is
    /// derived, so the only reachable second send (the failed-flip retry)
    /// converges. (Detached route — no canvas open — the sidecar is the scene.)
    func test_aCanvasRetryConvergesOnTheSameCard() async throws {
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
        XCTAssertEqual(scene.count, 1,
                       "M8-IN-004, fixed under RULING-8 (2026-08-09): the node id "
                       + "is derived from the entry id, so the retry lands on the "
                       + "same card")
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

    /// M8-IN-012 — fixed under RULING-7 (2026-08-09): an unreadable device
    /// manifest is recorded (`unreadableManifests`, via the strict read
    /// `JSONLAppendStore.loadStrict`) and the pane shows a notice. The
    /// lenient `load()` remains the shared-layer default — a register
    /// residual records that its other consumers should decide deliberately.
    func test_anUnreadableDeviceManifestIsRecordedNotSilent() async throws {
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
                      "the device's rows cannot be read, so the lists are empty")
        XCTAssertEqual(inbox.unreadableManifests, ["inbox.seed.jsonl"],
                       "M8-IN-012, fixed under RULING-7 (2026-08-09): the "
                       + "unreadable file is RECORDED — never presented as "
                       + "silently empty — and the pane says so")
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
