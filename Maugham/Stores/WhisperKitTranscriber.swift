import Foundation
import MaughamCore
import WhisperKit

/// Production Transcriber backed by WhisperKit (Apple-Silicon CoreML). Loads /
/// lazily downloads the model on first use into the variant-scoped model dir,
/// then transcribes. Apple-Silicon only — DocumentStore.makeTranscriber()
/// returns nil on Intel so the worker stays inert there. See spec §3.5.
///
/// NOTE: WhisperKit's init/transcribe API surface targets ~0.9; if resolution
/// pulls a different version, adjust to the resolved API.
actor WhisperKitTranscriber: Transcriber {
    private var pipe: WhisperKit?
    private var loadedModel: String?

    private static var modelFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(BuildVariant.current.supportFolderName)
            .appendingPathComponent("WhisperModels")
    }

    func transcribe(_ audio: URL, model: String) async throws -> String {
        if pipe == nil || loadedModel != model {
            let config = WhisperKitConfig(
                model: model,
                downloadBase: Self.modelFolder,
                download: true)
            pipe = try await WhisperKit(config)
            loadedModel = model
        }
        let results = try await pipe!.transcribe(audioPath: audio.path)
        return results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
