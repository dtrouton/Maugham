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
    /// Has the writer been stopped from typing here? Plan B's third rung is
    /// raised by that refusal and by nothing else: a reader who never tried to
    /// write is not being held up by anything, and an offer to move part of
    /// their history is not something to leave lying around unasked-for.
    private(set) var setAsideOffered = false
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

    /// The offer that replaces the message once typing has been refused. Two
    /// promises, both load-bearing and both made HERE rather than in a sheet
    /// the writer may never open: the unreadable file is **kept** (moved, never
    /// deleted — `OpLogQuarantine` writes a record beside the bytes), and it
    /// **comes back** by itself when it reads again. Without the second, this
    /// button reads as a choice between writing today and keeping what is in
    /// that file, which is not the choice being offered.
    var setAsideOffer: String {
        "Keep writing anyway — set the unreadable history aside "
        + "(kept safe, merged back when it returns)"
    }

    /// Typing was refused: emphasise, and raise the offer. Plan A emphasised
    /// and stopped there because it had nothing to offer — the refused
    /// keystroke is precisely the moment the writer has said they want to
    /// write, so it is the moment Plan B's rung appears.
    func noteTypingRefused() {
        emphasised = true
        setAsideOffered = true
    }

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
                        // And the set-aside offer goes with it, for a harder
                        // reason than tint: the history is BACK. Pressing it
                        // now would move a file that reads perfectly well, out
                        // of a document that is one press from whole.
                        self.setAsideOffered = false
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
    let onSetAside: () -> Void

    /// One line, three postures, in the order they can arrive. The return wins
    /// over the offer: once the history is back there is nothing to set aside,
    /// and the model has already dropped `setAsideOffered` — this ordering is
    /// belt to that brace, and keeps the banner from ever showing two answers.
    private var line: String {
        if model.offersReopen { return "Full history is back." }
        if model.setAsideOffered { return model.setAsideOffer }
        return model.message
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11, weight: .semibold))
            // `detail` — the file names and their reasons — stays on the
            // tooltip through all three postures, so the swap to the offer
            // copy hides nothing: what is missing is still one hover away.
            Text(line)
                .font(.caption)
                .help(model.detail)
            Spacer(minLength: 4)
            if model.offersReopen {
                Button("Reopen") { onReopen() }
                    .controlSize(.small).buttonStyle(.borderedProminent)
            } else if model.setAsideOffered {
                Button("Set Aside and Keep Writing") { onSetAside() }
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
