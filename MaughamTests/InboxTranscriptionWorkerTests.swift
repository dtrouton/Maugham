import XCTest
import MaughamCore
@testable import Maugham

/// Tracks max concurrency and records calls; result is configurable.
final class MockTranscriber: Transcriber, @unchecked Sendable {
    enum Mode { case success(String), failure }
    var mode: Mode = .success("WHISPER")
    /// Invoked at the start of each transcribe — lets a test mutate inbox state
    /// mid-transcription (to exercise the in-flight edit-protection re-check).
    var onStart: (@Sendable () async -> Void)?
    private(set) var calls: [URL] = []
    private(set) var maxConcurrent = 0
    private var current = 0
    private let lock = NSLock()
    func transcribe(_ audio: URL, model: String) async throws -> String {
        await onStart?()
        lock.lock(); calls.append(audio); current += 1
        maxConcurrent = max(maxConcurrent, current); lock.unlock()
        try? await Task.sleep(nanoseconds: 20_000_000) // 20ms to expose overlap
        lock.lock(); current -= 1; lock.unlock()
        switch mode {
        case .success(let s): return s
        case .failure: throw NSError(domain: "mock", code: 1)
        }
    }
}

@MainActor
final class InboxTranscriptionWorkerTests: XCTestCase {

    private func project() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("worker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".maugham/inbox/audio"),
            withIntermediateDirectories: true)
        return root
    }

    private func seedAudio(_ root: URL, id: String,
                           state: InboxEntry.TranscriptionState) async throws {
        let asset = root.appendingPathComponent(".maugham/inbox/audio/\(id).m4a")
        try Data("audio".utf8).write(to: asset)
        let file = root.appendingPathComponent(".maugham/inbox/inbox.seed.jsonl")
        let s = JSONLAppendStore<InboxEntry>(fileURL: file)
        try await s.append(InboxEntry(
            id: id, createdAt: Date(timeIntervalSince1970: 100), deviceId: "phone",
            kind: .audio, sourceFilename: "\(id).m4a",
            transcript: "draft", transcriptionState: state))
    }

    func test_transcribesEligibleAudio_setsWhisperFinal() async throws {
        let root = try project()
        try await seedAudio(root, id: "a1", state: .onDeviceDraft)
        let inbox = InboxStore(projectURL: root, deviceId: "mac")
        let mock = MockTranscriber()
        let worker = InboxTranscriptionWorker(
            inboxStore: inbox, transcriber: mock)
        await worker.processForTest()
        await inbox.refresh()
        XCTAssertEqual(inbox.entries.first?.transcript, "WHISPER")
        XCTAssertEqual(inbox.entries.first?.transcriptionState, .whisperFinal)
    }

    func test_failure_marksFailed_keepsDraft() async throws {
        let root = try project()
        try await seedAudio(root, id: "a1", state: .onDeviceDraft)
        let inbox = InboxStore(projectURL: root, deviceId: "mac")
        let mock = MockTranscriber(); mock.mode = .failure
        let worker = InboxTranscriptionWorker(inboxStore: inbox, transcriber: mock)
        await worker.processForTest()
        await inbox.refresh()
        XCTAssertEqual(inbox.entries.first?.transcriptionState, .failed)
        XCTAssertEqual(inbox.entries.first?.transcript, "draft", "draft preserved on failure")
    }

    func test_skipsIneligible_whisperFinalAndUserEdited() async throws {
        let root = try project()
        try await seedAudio(root, id: "done", state: .whisperFinal)
        try await seedAudio(root, id: "mine", state: .userEdited)
        let inbox = InboxStore(projectURL: root, deviceId: "mac")
        let mock = MockTranscriber()
        let worker = InboxTranscriptionWorker(inboxStore: inbox, transcriber: mock)
        await worker.processForTest()
        XCTAssertTrue(mock.calls.isEmpty, "worker must not touch whisperFinal/userEdited")
    }

    func test_serial_oneTranscriptionAtATime() async throws {
        let root = try project()
        for i in 0..<4 { try await seedAudio(root, id: "a\(i)", state: .onDeviceDraft) }
        let inbox = InboxStore(projectURL: root, deviceId: "mac")
        let mock = MockTranscriber()
        let worker = InboxTranscriptionWorker(inboxStore: inbox, transcriber: mock)
        await worker.processForTest()
        XCTAssertEqual(mock.calls.count, 4)
        XCTAssertEqual(mock.maxConcurrent, 1, "transcriptions run serially")
    }

    func test_nilTranscriber_isInert() async throws {
        let root = try project()
        try await seedAudio(root, id: "a1", state: .onDeviceDraft)
        let inbox = InboxStore(projectURL: root, deviceId: "mac")
        let worker = InboxTranscriptionWorker(inboxStore: inbox, transcriber: nil)
        await worker.processForTest()
        await inbox.refresh()
        XCTAssertEqual(inbox.entries.first?.transcriptionState, .onDeviceDraft,
                       "no transcriber → worker leaves entries untouched")
    }

    func test_userEditDuringTranscription_isNotClobbered() async throws {
        // The writer edits the transcript while Whisper is running. The worker's
        // post-await re-check must see the .userEdited row and skip the
        // .whisperFinal write, or last-wins-by-writtenAt would clobber the edit.
        let root = try project()
        try await seedAudio(root, id: "a1", state: .onDeviceDraft)
        let inbox = InboxStore(projectURL: root, deviceId: "mac")
        let mock = MockTranscriber()
        mock.onStart = { [inbox] in
            await inbox.updateTranscript(id: "a1", text: "my edit", state: .userEdited)
        }
        let worker = InboxTranscriptionWorker(inboxStore: inbox, transcriber: mock)
        await worker.processForTest()
        await inbox.refresh()
        let entry = inbox.entries.first { $0.id == "a1" }
        XCTAssertEqual(entry?.transcriptionState, .userEdited,
                       "a user edit during transcription must not be clobbered")
        XCTAssertEqual(entry?.transcript, "my edit")
    }

    func test_emptyResult_marksFailed_keepsDraft_setsError() async throws {
        let root = try project()
        try await seedAudio(root, id: "a1", state: .onDeviceDraft)
        let inbox = InboxStore(projectURL: root, deviceId: "mac")
        let mock = MockTranscriber(); mock.mode = .success("")   // empty transcript
        let worker = InboxTranscriptionWorker(inboxStore: inbox, transcriber: mock)
        await worker.processForTest()
        await inbox.refresh()
        let e = inbox.entries.first { $0.id == "a1" }
        XCTAssertEqual(e?.transcriptionState, .failed, "empty result is a failure, not a success")
        XCTAssertEqual(e?.transcript, "draft", "draft preserved, not clobbered with empty")
        XCTAssertNotNil(e?.transcriptionError, "a diagnostic error is recorded")
    }

    func test_thrownFailure_setsError() async throws {
        let root = try project()
        try await seedAudio(root, id: "a1", state: .onDeviceDraft)
        let inbox = InboxStore(projectURL: root, deviceId: "mac")
        let mock = MockTranscriber(); mock.mode = .failure
        let worker = InboxTranscriptionWorker(inboxStore: inbox, transcriber: mock)
        await worker.processForTest()
        await inbox.refresh()
        let e = inbox.entries.first { $0.id == "a1" }
        XCTAssertEqual(e?.transcriptionState, .failed)
        XCTAssertNotNil(e?.transcriptionError, "thrown error is surfaced")
    }

    func test_userEditDuringFailingTranscription_isNotClobbered() async throws {
        // Same protection as the success path, but for a failing transcription:
        // a concurrent user edit must not be overwritten by a .failed write.
        let root = try project()
        try await seedAudio(root, id: "a1", state: .onDeviceDraft)
        let inbox = InboxStore(projectURL: root, deviceId: "mac")
        let mock = MockTranscriber(); mock.mode = .failure
        mock.onStart = { [inbox] in
            await inbox.updateTranscript(id: "a1", text: "my edit", state: .userEdited)
        }
        let worker = InboxTranscriptionWorker(inboxStore: inbox, transcriber: mock)
        await worker.processForTest()
        await inbox.refresh()
        let e = inbox.entries.first { $0.id == "a1" }
        XCTAssertEqual(e?.transcriptionState, .userEdited,
                       "a user edit during a failing transcription must survive")
        XCTAssertEqual(e?.transcript, "my edit")
    }

    func test_success_clearsPriorError() async throws {
        // An eligible draft that still carries a stale error (e.g. re-armed after
        // a prior failure). A successful transcription must clear the error.
        let root = try project()
        let asset = root.appendingPathComponent(".maugham/inbox/audio/a1.m4a")
        try Data("audio".utf8).write(to: asset)
        let file = root.appendingPathComponent(".maugham/inbox/inbox.seed.jsonl")
        let s = JSONLAppendStore<InboxEntry>(fileURL: file)
        try await s.append(InboxEntry(
            id: "a1", createdAt: Date(timeIntervalSince1970: 100), deviceId: "phone",
            kind: .audio, sourceFilename: "a1.m4a", transcript: "draft",
            transcriptionState: .onDeviceDraft, transcriptionError: "old failure"))
        let inbox = InboxStore(projectURL: root, deviceId: "mac")
        let mock = MockTranscriber()   // default .success("WHISPER")
        let worker = InboxTranscriptionWorker(inboxStore: inbox, transcriber: mock)
        await worker.processForTest()
        await inbox.refresh()
        let e = inbox.entries.first { $0.id == "a1" }
        XCTAssertEqual(e?.transcriptionState, .whisperFinal)
        XCTAssertEqual(e?.transcript, "WHISPER")
        XCTAssertNil(e?.transcriptionError, "successful transcription clears a stale error")
    }
}
