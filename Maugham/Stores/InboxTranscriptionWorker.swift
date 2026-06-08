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
/// `.failed` entries are not *auto*-retried (avoids hammering a corrupt file);
/// the writer re-arms one explicitly via `DocumentStore.retranscribe` (the
/// "Transcribe Again" pane gesture), which resets it to `.onDeviceDraft` so this
/// worker picks it up with the current Settings model. An empty result is
/// treated as a failure (it does not throw) so it can't clobber the draft.
/// Long audio (>5 min) is not chunked in v1 — WhisperKit degrades past ~5 min.
@MainActor
final class InboxTranscriptionWorker {
    private let inboxStore: InboxStore
    private let transcriber: Transcriber?
    // Subsystem from the running bundle id so dev/stable logs separate without
    // hardcoding "com.maugham" (tripwire 13 spirit).
    private let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham",
        category: "transcription")

    private var running = false
    private var queued = false

    init(inboxStore: InboxStore, transcriber: Transcriber?) {
        self.inboxStore = inboxStore
        self.transcriber = transcriber
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
        // Read the model fresh each drain so a Settings change takes effect on the
        // next job (the worker is cached for the window's lifetime).
        let model = Self.configuredModel
        await inboxStore.refresh()
        let eligible = inboxStore.entries.filter {
            $0.kind == .audio
                && ($0.transcriptionState == .none || $0.transcriptionState == .onDeviceDraft)
        }
        for entry in eligible {
            guard let url = inboxStore.assetURL(for: entry) else { continue }
            let text: String
            let state: InboxEntry.TranscriptionState
            let error: String?
            do {
                let result = try await transcriber.transcribe(url, model: model)
                if result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // WhisperKit returns no segments for a silent/unclear clip and
                    // does NOT throw. Treat empty as a failure and preserve the
                    // on-device draft instead of overwriting it with empty text.
                    log.error("transcription empty for \(entry.id, privacy: .public)")
                    text = entry.transcript ?? ""
                    state = .failed
                    error = "WhisperKit produced no text for this clip — it may be "
                          + "silent or unclear. Try a larger model, or re-record."
                } else {
                    text = result
                    state = .whisperFinal
                    error = nil
                }
            } catch let thrown {
                log.error("transcription failed for \(entry.id, privacy: .public): \(thrown.localizedDescription, privacy: .public)")
                text = entry.transcript ?? ""   // preserve the on-device draft
                state = .failed
                error = thrown.localizedDescription
            }
            // Post-await eligibility re-check: refresh so an edit that landed
            // during `transcribe` (its row is already appended) is visible, then
            // skip the write if the entry is no longer a plain draft. This catches
            // the realistic case — a user edit (→ .userEdited) during the long
            // transcribe await. A sub-ms residual window remains (an edit Task
            // becoming ready exactly at the updateTranscript suspension below);
            // accepted for v1 since both run on the MainActor and the window is
            // practically unreachable. The durable fix would fold the predicate
            // into a conditional append.
            await inboxStore.refresh()
            let current = inboxStore.entries.first { $0.id == entry.id }?.transcriptionState
            guard current == .none || current == .onDeviceDraft else { continue }
            await inboxStore.updateTranscript(id: entry.id, text: text, state: state, error: error)
        }
    }
}
