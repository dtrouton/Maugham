import Foundation

/// The seam between InboxTranscriptionWorker and a concrete speech-to-text
/// engine. The worker depends only on this; WhisperKit is wired behind it
/// (WhisperKitTranscriber) in an isolated commit so its CoreML fetch can't
/// break the rest of the build. `model` is the engine's model identifier
/// (e.g. "openai_whisper-base"). See spec §3.5.
public protocol Transcriber: Sendable {
    func transcribe(_ audio: URL, model: String) async throws -> String
}
