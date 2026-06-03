import XCTest
import MaughamCore
@testable import Maugham

/// Pins the cross-surface write rule: `InboxStore.append` stamps `writtenAt` as
/// `max(now, basis + 1ms)`, so every status/transcript transition row
/// out-ranks the prior row's `writtenAt` in the last-wins merge — even when the
/// prior row carries a future-dated `writtenAt` from a device with clock skew.
///
/// Without this invariant, a phone-drafted capture with a future `writtenAt` can
/// win the last-wins merge forever and the transcription worker loops. (Tripwire 17.)
@MainActor
final class InboxMonotonicWrittenAtTests: XCTestCase {

    // MARK: - Fixtures

    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-monotonic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".maugham/inbox"),
            withIntermediateDirectories: true)
        return root
    }

    private func seed(_ root: URL, slug: String = "phone",
                      _ entries: [InboxEntry]) async throws {
        let url = root.appendingPathComponent(".maugham/inbox/inbox.\(slug).jsonl")
        let store = JSONLAppendStore<InboxEntry>(fileURL: url)
        for e in entries { try await store.append(e) }
    }

    /// Load every row from the Mac's own manifest file (before last-wins collapse)
    /// so we can inspect the raw `writtenAt` stamps the transition wrote.
    private func rawRows(in root: URL, deviceId: String) async throws -> [InboxEntry] {
        let slug = DeviceSlug.make(from: deviceId)
        let url = InboxManifest.inboxManifestURL(forDeviceSlug: slug, in: root)
        let store = JSONLAppendStore<InboxEntry>(fileURL: url)
        return (try? await store.load()) ?? []
    }

    // MARK: - 1. Transition writtenAt strictly greater than prior writtenAt

    /// Seed an entry with a known `writtenAt`, call `updateStatus` (one of the
    /// public transition APIs that routes through the private `append`), then read
    /// the raw rows back and assert the second row's `writtenAt` is strictly
    /// greater than the first's. This is the monotonicity invariant.
    func test_statusTransition_writtenAt_isStrictlyGreaterThanPriorRow() async throws {
        let root = try makeProject()
        let priorWrittenAt = Date(timeIntervalSince1970: 1_000)

        var original = InboxEntry(
            id: "e1", createdAt: Date(timeIntervalSince1970: 900),
            writtenAt: priorWrittenAt,
            deviceId: "phone", kind: .text, inlineText: "capture text")
        original.writtenAt = priorWrittenAt

        try await seed(root, slug: "phone", [original])

        let macDeviceId = "mac-test"
        let store = InboxStore(projectURL: root, deviceId: macDeviceId)
        await store.refresh()

        // Transition: mark the entry as trashed (any status transition works).
        await store.updateStatus(id: "e1", to: .trashed)

        // Read back the raw rows written to the Mac's own manifest.
        let rows = try await rawRows(in: root, deviceId: macDeviceId)
        XCTAssertEqual(rows.count, 1,
                       "the Mac appended exactly one transition row to its own manifest")
        let transitionRow = try XCTUnwrap(rows.first)
        let transitionWrittenAt = try XCTUnwrap(transitionRow.writtenAt,
                                                "transition row must have a writtenAt stamp")

        XCTAssertGreaterThan(transitionWrittenAt, priorWrittenAt,
                             "transition writtenAt must be strictly greater than the prior row's writtenAt (monotonic invariant)")
    }

    // MARK: - 2. Future-dated prior writtenAt is still out-ranked

    /// When the phone sends a row with a writtenAt 1 hour in the future (clock
    /// skew), the Mac's next transition must still produce a strictly greater
    /// writtenAt — meaning it uses `basis + 1ms`, not wall clock alone.
    func test_futureDatedPrior_transitionStillWins() async throws {
        let root = try makeProject()
        let futureWrittenAt = Date().addingTimeInterval(3600) // 1h ahead

        var draft = InboxEntry(
            id: "e2", createdAt: Date(timeIntervalSince1970: 100),
            writtenAt: futureWrittenAt,
            deviceId: "phone", kind: .audio,
            transcript: "on-device draft",
            transcriptionState: .onDeviceDraft)

        try await seed(root, slug: "phone", [draft])

        let macDeviceId = "mac-test-2"
        let store = InboxStore(projectURL: root, deviceId: macDeviceId)
        await store.refresh()

        // Mac writes the Whisper transcript: this calls append which must out-rank
        // the future-dated phone row.
        await store.updateTranscript(id: "e2", text: "Whisper final.", state: .whisperFinal)

        // The last-wins merge should now show the Whisper result.
        XCTAssertEqual(store.entries.first?.transcriptionState, .whisperFinal,
                       "Mac's transcript transition must win over a future-dated phone row")
        XCTAssertEqual(store.entries.first?.transcript, "Whisper final.")

        // And the raw written row must have a writtenAt > the future-dated basis.
        let rows = try await rawRows(in: root, deviceId: macDeviceId)
        let transitionRow = try XCTUnwrap(rows.first)
        let transitionWrittenAt = try XCTUnwrap(transitionRow.writtenAt,
                                                "transition row must have writtenAt")
        XCTAssertGreaterThan(transitionWrittenAt, futureWrittenAt,
                             "append must use basis + 1ms, not wall clock, so it out-ranks a future-dated prior row")
    }

    // MARK: - 3. Multiple transitions are each monotonically increasing

    /// Two successive transitions on the same entry must each produce a strictly
    /// greater writtenAt than the one before — the invariant holds across a chain.
    func test_twoTransitions_eachWrittenAtStrictlyIncreases() async throws {
        let root = try makeProject()
        let originalWrittenAt = Date(timeIntervalSince1970: 500)

        var original = InboxEntry(
            id: "e3", createdAt: Date(timeIntervalSince1970: 400),
            writtenAt: originalWrittenAt,
            deviceId: "phone", kind: .audio,
            transcript: "draft", transcriptionState: .onDeviceDraft)

        try await seed(root, slug: "phone", [original])

        let macDeviceId = "mac-test-3"
        let store = InboxStore(projectURL: root, deviceId: macDeviceId)
        await store.refresh()

        // First transition: Whisper transcript.
        await store.updateTranscript(id: "e3", text: "Whisper output.", state: .whisperFinal)

        // Second transition: trash.
        await store.updateStatus(id: "e3", to: .trashed)

        // Two rows should be in the Mac's manifest (first and second transitions).
        let rows = try await rawRows(in: root, deviceId: macDeviceId)
        XCTAssertEqual(rows.count, 2,
                       "two transitions appended two rows to the Mac manifest")

        let writtenAts = rows.compactMap(\.writtenAt)
        XCTAssertEqual(writtenAts.count, 2, "both rows must have writtenAt stamps")
        XCTAssertGreaterThan(writtenAts[0], originalWrittenAt,
                             "first transition out-ranks the original")
        XCTAssertGreaterThan(writtenAts[1], writtenAts[0],
                             "second transition out-ranks the first (chain monotonicity)")
    }
}
