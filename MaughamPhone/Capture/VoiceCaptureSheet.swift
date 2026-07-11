import SwiftUI
import AVFoundation
import Speech
import MaughamCore

/// Voice capture: record an `.m4a` clip while live-transcribing on-device, then
/// confirm (play back + edit the draft transcript) before committing it to the
/// inbox as an `.audio` entry.
///
/// Robustness contract (from the task): if speech recognition is denied or
/// unavailable, recording STILL proceeds and saves — the draft just stays empty.
/// Only a denied *microphone* permission blocks recording.
struct VoiceCaptureSheet: View {
    let writer: InboxCaptureWriter
    /// The current palette aim (nil = plain inbox), threaded into the write.
    var aim: PaletteAim?
    let onCommit: () -> Void

    @State private var recorder = VoiceRecorder()
    @State private var isSaving = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .navigationTitle("Voice Note")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            recorder.discard()
                            dismiss()
                        }
                    }
                }
                .alert(
                    "Couldn't Save",
                    isPresented: Binding(
                        get: { errorMessage != nil },
                        set: { if !$0 { errorMessage = nil } })
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(errorMessage ?? "")
                }
                .onDisappear { recorder.teardown() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch recorder.phase {
        case .idle, .recording:
            recordingView
        case .recorded:
            confirmationView
        }
    }

    // MARK: - Recording phase

    private var recordingView: some View {
        VStack(spacing: 28) {
            Spacer()

            // Live draft while recording (empty until speech yields anything).
            if !recorder.draft.isEmpty {
                ScrollView {
                    Text(recorder.draft)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
            }

            if let notice = recorder.permissionNotice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                Task { await toggleRecording() }
            } label: {
                Image(systemName: recorder.phase == .recording ? "stop.circle.fill" : "mic.circle.fill")
                    .resizable()
                    .frame(width: 88, height: 88)
                    .foregroundStyle(recorder.phase == .recording ? Color.red : Color.accentColor)
            }
            .accessibilityLabel(recorder.phase == .recording ? "Stop recording" : "Start recording")

            Text(recorder.phase == .recording ? "Recording… tap to stop" : "Tap to record")
                .foregroundStyle(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func toggleRecording() async {
        if recorder.phase == .recording {
            recorder.stop()
        } else {
            await recorder.start()
        }
    }

    // MARK: - Confirmation phase

    private var confirmationView: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Button {
                    recorder.togglePlayback()
                } label: {
                    Label(
                        recorder.isPlaying ? "Pause" : "Play",
                        systemImage: recorder.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.bordered)
                Spacer()
            }

            Text("Transcript")
                .font(.headline)
            // Editable draft — the writer can fix mishearings before it syncs.
            TextEditor(text: $recorder.draft)
                .frame(minHeight: 160)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(.separator)))

            HStack {
                Button(role: .destructive) {
                    recorder.discard()
                    dismiss()
                } label: {
                    Label("Discard", systemImage: "trash")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button {
                    save()
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Label("Save to Inbox", systemImage: "tray.and.arrow.down")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func save() {
        guard let tempURL = recorder.recordingURL else {
            errorMessage = "The recording is missing."
            return
        }
        isSaving = true
        Task {
            do {
                // Empty draft → nil (so the entry stays `.none`, not a blank
                // `.onDeviceDraft`); the Mac's worker can transcribe from scratch.
                let trimmed = recorder.draft.trimmingCharacters(in: .whitespacesAndNewlines)
                try await writer.writeAudio(
                    from: tempURL,
                    transcriptDraft: trimmed.isEmpty ? nil : trimmed,
                    paletteSubject: aim?.subject,
                    sense: aim?.sense)
                recorder.cleanupAfterCommit()
                onCommit()
                dismiss()
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                isSaving = false
            }
        }
    }
}

/// Drives `AVAudioRecorder` (the saved artifact) alongside a live
/// `SFSpeechAudioBufferRecognitionRequest` fed from an `AVAudioEngine` tap (the
/// on-device draft), plus `AVAudioPlayer` for pre-commit playback.
///
/// Recording and transcription are deliberately decoupled: the engine tap feeds
/// the recognizer, and a separate `AVAudioRecorder` writes the durable `.m4a`.
/// If speech is denied/unavailable we simply never build the recognizer — the
/// recorder runs regardless, satisfying the "saves with empty draft" contract.
@MainActor
@Observable
final class VoiceRecorder: NSObject {
    enum Phase { case idle, recording, recorded }

    private(set) var phase: Phase = .idle
    var draft: String = ""
    private(set) var isPlaying = false
    /// User-facing note when a permission was denied (mic blocks; speech only
    /// disables the transcript).
    private(set) var permissionNotice: String?
    private(set) var recordingURL: URL?

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    // MARK: - Start / stop

    /// Request mic (required) + speech (optional) on first tap, then begin
    /// recording to a fresh temp `.m4a`. Returns early with a notice if the mic
    /// is denied.
    func start() async {
        permissionNotice = nil

        let mic = await CapturePermissions.requestMicrophone()
        guard mic == .granted else {
            permissionNotice = "Microphone access is off. Enable it in Settings to record voice notes."
            return
        }

        let speech = await CapturePermissions.requestSpeech()
        let speechGranted = (speech == .granted)
        if !speechGranted {
            // Non-fatal: recording proceeds, the draft just stays empty.
            permissionNotice = "Live transcript is off (Speech Recognition disabled in Settings). Your recording will still save."
        }

        do {
            try beginRecording(withTranscript: speechGranted)
            phase = .recording
        } catch {
            permissionNotice = "Couldn't start recording: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
        }
    }

    /// Stop recording + transcription and move to the confirmation phase. The
    /// `.m4a` at `recordingURL` is now the durable artifact.
    func stop() {
        recorder?.stop()
        recorder = nil
        stopTranscription()
        deactivateSession()
        phase = .recorded
    }

    // MARK: - Recording engine

    private func beginRecording(withTranscript wantsTranscript: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        // Temp scratch file; moved into the inbox by the writer on save.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString).m4a")
        recordingURL = url

        // AAC mono ~64kbps — small, plenty for a voice note.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        let rec = try AVAudioRecorder(url: url, settings: settings)
        rec.record()
        recorder = rec

        if wantsTranscript {
            startTranscription(session: session)
        }
    }

    /// Build the recognizer + engine tap. Failure here is swallowed to a notice:
    /// the durable recording is unaffected.
    private func startTranscription(session: AVAudioSession) {
        let speechRecognizer = SFSpeechRecognizer()
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            permissionNotice = "Live transcript isn't available right now; your recording will still save."
            return
        }
        recognizer = speechRecognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // On-device when supported — captures shouldn't ship audio off the phone.
        if speechRecognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            // Engine failed — drop the transcript, keep recording.
            inputNode.removeTap(onBus: 0)
            recognitionRequest = nil
            recognizer = nil
            permissionNotice = "Live transcript couldn't start; your recording will still save."
            return
        }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let self, let result else { return }
            // Hop to main: this view-model is @MainActor and `draft` drives UI.
            Task { @MainActor in
                self.draft = result.bestTranscription.formattedString
            }
        }
    }

    private func stopTranscription() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        recognizer = nil
    }

    // MARK: - Playback

    func togglePlayback() {
        if isPlaying {
            player?.pause()
            isPlaying = false
            return
        }
        guard let url = recordingURL else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.play()
            player = p
            isPlaying = true
        } catch {
            permissionNotice = "Couldn't play the recording."
        }
    }

    // MARK: - Teardown

    /// Discard the recording (user cancelled / pressed Discard): stop everything
    /// and delete the temp file.
    func discard() {
        teardown()
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordingURL = nil
        phase = .idle
        draft = ""
    }

    /// After a successful inbox write the writer has already copied the bytes, so
    /// we just remove our temp scratch.
    func cleanupAfterCommit() {
        teardown()
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordingURL = nil
    }

    /// Stop any in-flight recording/transcription/playback without deleting the
    /// file. Idempotent; safe from `onDisappear`.
    func teardown() {
        recorder?.stop()
        recorder = nil
        player?.stop()
        player = nil
        isPlaying = false
        stopTranscription()
        deactivateSession()
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

extension VoiceRecorder: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.isPlaying = false }
    }
}
