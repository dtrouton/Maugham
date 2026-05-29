import XCTest
import MaughamCore
@testable import Maugham

/// InboxStore's cross-file/cross-row last-wins merge (spec §3.3). Status
/// transitions append same-id rows; readers must keep the newest by createdAt,
/// and only `.new` entries surface. This is the opposite of the op log's
/// immutable first-wins, so it's worth pinning down.
@MainActor
final class InboxStoreLastWinsTests: XCTestCase {

    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".maugham/inbox"),
            withIntermediateDirectories: true)
        return root
    }

    private func seed(_ root: URL, file: String, _ entries: [InboxEntry]) async throws {
        let url = root.appendingPathComponent(".maugham/inbox/\(file)")
        let store = JSONLAppendStore<InboxEntry>(fileURL: url)
        for e in entries { try await store.append(e) }
    }

    private func entry(_ id: String, _ status: InboxEntry.Status,
                       at seconds: TimeInterval, text: String,
                       transcript: String? = nil,
                       state: InboxEntry.TranscriptionState = .none,
                       kind: InboxEntry.Kind = .text) -> InboxEntry {
        InboxEntry(id: id, createdAt: Date(timeIntervalSince1970: seconds),
                   deviceId: "dev", kind: kind, inlineText: text,
                   transcript: transcript, transcriptionState: state, status: status)
    }

    func test_statusTransition_acrossFiles_promotedWins_andIsHidden() async throws {
        let root = try makeProject()
        // Phone created it (new); Mac later promoted it (newer createdAt).
        try await seed(root, file: "inbox.phone.jsonl",
                       [entry("id1", .new, at: 100, text: "a note")])
        try await seed(root, file: "inbox.mac.jsonl",
                       [entry("id1", .promoted, at: 200, text: "a note")])

        let store = InboxStore(projectURL: root, deviceId: "mac")
        await store.refresh()

        XCTAssertTrue(store.entries.isEmpty,
                      "promoted (newest row) wins, so the entry is filtered out of the pane")
    }

    func test_inFileTransition_keepsNewestRow_notFirst() async throws {
        let root = try makeProject()
        // One file, same id: new (draft) then a newer row with the final
        // transcript. The op-log first-wins dedup would keep the draft; inbox
        // must keep the newest.
        try await seed(root, file: "inbox.mac.jsonl", [
            entry("id1", .new, at: 100, text: "", transcript: "draft",
                  state: .onDeviceDraft, kind: .audio),
            entry("id1", .new, at: 150, text: "", transcript: "Final transcript.",
                  state: .whisperFinal, kind: .audio),
        ])

        let store = InboxStore(projectURL: root, deviceId: "mac")
        await store.refresh()

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.transcript, "Final transcript.")
        XCTAssertEqual(store.entries.first?.transcriptionState, .whisperFinal)
    }

    func test_multipleNewEntries_sortedNewestFirst() async throws {
        let root = try makeProject()
        try await seed(root, file: "inbox.mac.jsonl", [
            entry("old", .new, at: 100, text: "older"),
            entry("new", .new, at: 300, text: "newer"),
            entry("mid", .new, at: 200, text: "middle"),
        ])
        let store = InboxStore(projectURL: root, deviceId: "mac")
        await store.refresh()
        XCTAssertEqual(store.entries.map(\.id), ["new", "mid", "old"])
    }

    func test_trashed_isHidden() async throws {
        let root = try makeProject()
        try await seed(root, file: "inbox.mac.jsonl", [
            entry("id1", .new, at: 100, text: "x"),
            entry("id1", .trashed, at: 110, text: "x"),
        ])
        let store = InboxStore(projectURL: root, deviceId: "mac")
        await store.refresh()
        XCTAssertTrue(store.entries.isEmpty)
    }

    func test_sameCreatedAt_acrossFiles_newerWrittenAtWins() async throws {
        // The real phone-draft-vs-Mac-transcript case: both rows share the
        // entry's createdAt (it's the entry's birth, copied onto transitions),
        // so only writtenAt can order them. Phone wrote the draft early; the
        // Mac wrote the Whisper transcript later — Mac must win.
        let root = try makeProject()
        var draft = entry("id1", .new, at: 100, text: "", transcript: "draft",
                          state: .onDeviceDraft, kind: .audio)
        draft.writtenAt = Date(timeIntervalSince1970: 100)
        var final = entry("id1", .new, at: 100, text: "", transcript: "Whisper final.",
                          state: .whisperFinal, kind: .audio)
        final.writtenAt = Date(timeIntervalSince1970: 500)   // same createdAt, later write
        try await seed(root, file: "inbox.phone.jsonl", [draft])
        try await seed(root, file: "inbox.mac.jsonl", [final])

        let store = InboxStore(projectURL: root, deviceId: "mac")
        await store.refresh()
        XCTAssertEqual(store.entries.first?.transcript, "Whisper final.",
                       "newer writtenAt wins even when createdAt ties across files")
    }

    func test_updateTranscript_appendsRowAndRefreshes() async throws {
        let root = try makeProject()
        try await seed(root, file: "inbox.mac.jsonl", [
            entry("id1", .new, at: 100, text: "", transcript: "draft",
                  state: .onDeviceDraft, kind: .audio),
        ])
        let store = InboxStore(projectURL: root, deviceId: "mac")
        await store.refresh()
        await store.updateTranscript(id: "id1", text: "Whisper output.", state: .whisperFinal)

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.transcript, "Whisper output.")
        XCTAssertEqual(store.entries.first?.transcriptionState, .whisperFinal)
    }

    func test_userEdited_decodesAndRoundTrips() throws {
        let json = #"{"id":"e","created_at":"2026-05-29T00:00:00Z","device_id":"d","kind":"audio","transcription_state":"user_edited","status":"new"}"#
            .data(using: .utf8)!
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let entry = try dec.decode(InboxEntry.self, from: json)
        XCTAssertEqual(entry.transcriptionState, .userEdited)
    }
}
