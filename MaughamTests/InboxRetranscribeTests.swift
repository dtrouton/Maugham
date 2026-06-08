import XCTest
import MaughamCore
@testable import Maugham

/// Store-level re-transcribe mechanics: requestRetranscription resets a
/// finished/failed entry to a worker-eligible draft and clears the stored
/// error; updateTranscript's error param sets/clears it.
@MainActor
final class InboxRetranscribeTests: XCTestCase {

    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("retx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".maugham/inbox"),
            withIntermediateDirectories: true)
        return root
    }

    private func seed(_ root: URL, _ entry: InboxEntry) async throws {
        let url = root.appendingPathComponent(".maugham/inbox/inbox.seed.jsonl")
        let store = JSONLAppendStore<InboxEntry>(fileURL: url)
        try await store.append(entry)
    }

    func test_requestRetranscription_resetsToDraft_keepsTranscript_clearsError() async throws {
        let root = try makeProject()
        try await seed(root, InboxEntry(
            id: "a1", createdAt: Date(timeIntervalSince1970: 100), deviceId: "phone",
            kind: .audio, sourceFilename: "a1.m4a", transcript: "old result",
            transcriptionState: .whisperFinal, status: .new,
            transcriptionError: "boom"))
        let store = InboxStore(projectURL: root, deviceId: "mac")
        await store.refresh()

        await store.requestRetranscription(id: "a1")
        await store.refresh()

        let e = store.entries.first { $0.id == "a1" }
        XCTAssertEqual(e?.transcriptionState, .onDeviceDraft, "reset to a worker-eligible state")
        XCTAssertEqual(e?.transcript, "old result", "transcript preserved as the draft")
        XCTAssertNil(e?.transcriptionError, "error cleared on retry request")
    }

    func test_requestRetranscription_unknownId_isNoOp() async throws {
        let root = try makeProject()
        let store = InboxStore(projectURL: root, deviceId: "mac")
        await store.refresh()
        await store.requestRetranscription(id: "nope")  // must not crash
        await store.refresh()
        XCTAssertTrue(store.entries.isEmpty)
    }

    func test_updateTranscript_setsAndClearsError() async throws {
        let root = try makeProject()
        try await seed(root, InboxEntry(
            id: "a1", createdAt: Date(timeIntervalSince1970: 100), deviceId: "phone",
            kind: .audio, sourceFilename: "a1.m4a", transcript: "draft",
            transcriptionState: .onDeviceDraft, status: .new))
        let store = InboxStore(projectURL: root, deviceId: "mac")
        await store.refresh()

        await store.updateTranscript(id: "a1", text: "draft", state: .failed, error: "no text")
        await store.refresh()
        XCTAssertEqual(store.entries.first?.transcriptionError, "no text")

        await store.updateTranscript(id: "a1", text: "WHISPER", state: .whisperFinal)
        await store.refresh()
        XCTAssertNil(store.entries.first?.transcriptionError, "success clears the error")
    }
}
