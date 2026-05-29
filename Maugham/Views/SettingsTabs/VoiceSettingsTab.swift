import SwiftUI

struct VoiceSettingsTab: View {
    @AppStorage("whisperModel") private var model = "openai_whisper-base"

    private static let models: [(id: String, label: String)] = [
        ("openai_whisper-base", "Base (~150 MB)"),
        ("openai_whisper-small", "Small (~500 MB)"),
        ("openai_whisper-large-v3", "Large v3 (~3 GB)"),
    ]

    var body: some View {
        Form {
            #if arch(arm64)
            Picker("Model", selection: $model) {
                ForEach(Self.models, id: \.id) { Text($0.label).tag($0.id) }
            }
            Text("Voice captures from MaughamPhone are re-transcribed locally with WhisperKit. The model downloads on first use.")
                .font(.caption).foregroundStyle(.secondary)
            #else
            Label("Apple Silicon required for local transcription.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            #endif
        }
        .formStyle(.grouped)
    }
}
