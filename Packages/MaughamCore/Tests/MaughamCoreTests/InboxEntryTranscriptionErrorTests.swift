import XCTest
@testable import MaughamCore

/// `transcriptionError` is a later, optional addition to the cross-surface
/// `InboxEntry` contract. Older rows (and the phone, which never writes it)
/// omit the `transcription_error` key entirely — decoding MUST tolerate that
/// as `nil` rather than throwing (tripwire 19).
final class InboxEntryTranscriptionErrorTests: XCTestCase {

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = JSONLAppendStore<InboxEntry>.dateDecoding
        return d
    }

    func test_decodesMissingTranscriptionError_asNil() throws {
        let json = """
        {"id":"x","created_at":"2026-01-01T00:00:00Z","device_id":"d",\
        "kind":"audio","transcription_state":"failed","status":"new"}
        """.data(using: .utf8)!
        let entry = try decoder().decode(InboxEntry.self, from: json)
        XCTAssertNil(entry.transcriptionError)
    }

    func test_roundTripsTranscriptionError() throws {
        let json = """
        {"id":"x","created_at":"2026-01-01T00:00:00Z","device_id":"d",\
        "kind":"audio","transcription_state":"failed","status":"new",\
        "transcription_error":"no speech detected"}
        """.data(using: .utf8)!
        let entry = try decoder().decode(InboxEntry.self, from: json)
        XCTAssertEqual(entry.transcriptionError, "no speech detected")
    }
}
