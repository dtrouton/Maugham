import Foundation
import MaughamCore
import os

/// Serial-queue worker that re-transcribes inbox voice captures with an injected
/// `Transcriber` (WhisperKitTranscriber in production), replacing the phone's
/// on-device draft. Owned by DocumentStore (one per window). Eligibility is
/// `.none`/`.onDeviceDraft` only, so it never overwrites a `.whisperFinal` or
/// `.userEdited` transcript. One transcription at a time. On failure the draft
/// is preserved (worst case: the Mac didn't improve on it). See spec §3.5.
///
/// `.failed` entries are not auto-retried (avoids hammering a corrupt file);
/// re-dropping audio or the Settings "Download now" path cover recovery.
/// Long audio (>5 min) is not chunked in v1 — WhisperKit degrades past ~5 min.
@MainActor
final class InboxTranscriptionWorker {
    private let inboxStore: InboxStore
    private let transcriber: Transcriber?
    private let model: String
    private let log = Logger(subsystem: "com.maugham", category: "transcription")

    private var running = false
    private var queued = false

    init(inboxStore: InboxStore, transcriber: Transcriber?, model: String) {
        self.inboxStore = inboxStore
        self.transcriber = transcriber
        self.model = model
    }

    /// Convenience for production wiring: read the configured model from defaults.
    static var configuredModel: String {
        UserDefaults.standard.string(forKey: "whisperModel") ?? "openai_whisper-base"
    }

    /// Called by DocumentStore's `.inbox` presenter arm for `kind == .audio`.
    /// Coalesces bursts: if a scan is already running, marks a re-scan instead
    /// of starting a second (keeps transcriptions strictly serial).
    func onInboxChanged() {
        guard transcriber != nil else { return }
        if running { queued = true; return }
        running = true
        Task { @MainActor in
            repeat { queued = false; await processEligible() } while queued
            running = false
        }
    }

    /// Test entry point — runs one drain synchronously.
    func processForTest() async { await processEligible() }

    private func processEligible() async {
        guard let transcriber else { return }
        await inboxStore.refresh()
        let eligible = inboxStore.entries.filter {
            $0.kind == .audio
                && ($0.transcriptionState == .none || $0.transcriptionState == .onDeviceDraft)
        }
        for entry in eligible {
            guard let url = inboxStore.assetURL(for: entry) else { continue }
            do {
                let text = try await transcriber.transcribe(url, model: model)
                await inboxStore.updateTranscript(id: entry.id, text: text, state: .whisperFinal)
            } catch {
                log.error("transcription failed for \(entry.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                // Preserve the on-device draft; only the state changes.
                await inboxStore.updateTranscript(
                    id: entry.id, text: entry.transcript ?? "", state: .failed)
            }
        }
    }
}
