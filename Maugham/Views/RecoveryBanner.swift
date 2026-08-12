import SwiftUI
import MaughamCore

/// The read-only partial view's standing banner (spec §4). The model owns
/// the readability watch; the view renders `message` + a Reopen button when
/// `offersReopen` — pressed, the HOST closes the recovery doc and retries
/// the normal load. Nothing here reloads anything by itself.
///
/// `beginWatching()` deliberately takes NO completion closure: a callback on
/// the watcher would be a reload hook waiting to be misused, and the writer's
/// press is the only thing allowed to reload. `offersReopen` is the model's
/// single output — the return is an OFFER, never a yank (ruling 2). This is
/// where it differs from `RecoveryPaneModel`, whose watch auto-opens: there
/// the writer is looking at a refusal, here at their own words.
@MainActor
@Observable
final class RecoveryBannerModel {
    let unreadableFiles: [CheckpointLoad.UnreadableFile]
    private let opsDirectory: URL
    private let probeInterval: Duration
    private let blockageCleared: (URL) -> Bool
    private(set) var offersReopen = false
    private(set) var emphasised = false
    private var watcher: Task<Void, Never>?

    init(unreadableFiles: [CheckpointLoad.UnreadableFile], opsDirectory: URL,
         probeInterval: Duration = .seconds(5),
         blockageCleared: @escaping (URL) -> Bool = RecoveryPaneModel.defaultBlockageClearedProbe) {
        self.unreadableFiles = unreadableFiles
        self.opsDirectory = opsDirectory
        self.probeInterval = probeInterval
        self.blockageCleared = blockageCleared
    }

    var message: String {
        let names = unreadableFiles.map(\.name).joined(separator: ", ")
        let plural = unreadableFiles.count == 1 ? "file" : "files"
        return "Read-only — \(unreadableFiles.count) history \(plural) can’t be read "
             + "(\(names)). What you see may be missing recent work."
    }

    /// Detail for the tooltip: per-file reasons (the checkpoint notice's shape).
    var detail: String {
        unreadableFiles.map { "\($0.name) — \($0.reason)" }.joined(separator: "\n")
    }

    /// Typing was refused (Task 4's signal): emphasise. Plan A's copy stays
    /// on the message; the writer is told the surface is read-only, and is
    /// promised nothing this ladder does not build.
    func noteTypingRefused() { emphasised = true }

    /// Poll the named files until every one of them reads, then OFFER the
    /// reopen. Idempotent — a second call while a watch is live is a no-op,
    /// so the view's `.task` can re-run without stacking pollers.
    func beginWatching() {
        guard watcher == nil else { return }
        watcher = Task { [probeInterval, blockageCleared, opsDirectory, unreadableFiles] in
            while !Task.isCancelled {
                try? await Task.sleep(for: probeInterval)
                if Task.isCancelled { return }
                let allCleared = unreadableFiles.allSatisfy {
                    blockageCleared(opsDirectory.appendingPathComponent($0.name))
                }
                if allCleared {
                    await MainActor.run {
                        self.offersReopen = true
                        // The flare's job is done the moment the offer is up:
                        // the banner is no longer saying "you can't type here",
                        // it is saying "come back". Left set, one refused
                        // keystroke tints the offer for the rest of the session.
                        self.emphasised = false
                    }
                    return
                }
            }
        }
    }

    func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }
}

struct RecoveryBanner: View {
    let model: RecoveryBannerModel
    let onReopen: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11, weight: .semibold))
            Text(model.offersReopen ? "Full history is back." : model.message)
                .font(.caption)
                .help(model.detail)
            Spacer(minLength: 4)
            if model.offersReopen {
                Button("Reopen") { onReopen() }
                    .controlSize(.small).buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(model.emphasised ? Color.orange.opacity(0.25) : Color.orange.opacity(0.12))
        // NO fixedSize(horizontal: false, vertical: true) — see
        // ViewOnlyShareNotice's warning: an unbreakable minimum height on a
        // top inset grows the whole split view past the window. Held to it by
        // `DetailPaneColumnHeightCensusTests
        // .test_theRecoveryBannerDoesNotGrowTheColumnsEither`, which measured
        // 3951pt in a 732pt window with the modifier planted back.
        .task { model.beginWatching() }
        .onDisappear { model.stopWatching() }
    }
}
