import SwiftUI
import MaughamCore

/// The recovery ladder's brain (spec §3), separated from the view so the
/// per-cause behaviour — what's offered, what's watched, what auto-opens —
/// is unit-testable without a window. The view below is deliberately thin.
@MainActor
@Observable
final class RecoveryPaneModel {
    let cause: RecoveryCause
    let projectURL: URL
    private let probeInterval: Duration
    private let isReadable: (URL) -> Bool
    private let startDownload: (URL) -> Void
    private let onOpenEditable: () -> Void
    let onOpenReadOnly: () -> Void
    private var watcher: Task<Void, Never>?

    init(cause: RecoveryCause, projectURL: URL,
         probeInterval: Duration = .seconds(2),
         isReadable: @escaping (URL) -> Bool = RecoveryPaneModel.defaultReadableProbe,
         startDownload: @escaping (URL) -> Void = RecoveryPaneModel.defaultStartDownload,
         onOpenEditable: @escaping () -> Void,
         onOpenReadOnly: @escaping () -> Void) {
        self.cause = cause
        self.projectURL = projectURL
        self.probeInterval = probeInterval
        self.isReadable = isReadable
        self.startDownload = startDownload
        self.onOpenEditable = onOpenEditable
        self.onOpenReadOnly = onOpenReadOnly
    }

    var offersReadOnly: Bool {
        if case .unreadableFile = cause { return true }
        return false
    }
    var offersRestore: Bool { true }

    var headline: String {
        switch cause {
        case .icloudNotDownloaded:
            return "iCloud hasn’t downloaded part of this document’s history yet"
        case .unreadableFile(let name, _, _):
            return "The history file “\(name)” exists but can’t be read"
        case .unlistableOpsDirectory:
            return "The document’s history folder can’t be listed"
        }
    }

    var detail: String {
        switch cause {
        case .icloudNotDownloaded(let name, _):
            return "Maugham asked iCloud to download “\(name)” and will open the "
                 + "document automatically the moment it arrives. Your words are intact."
        case .unreadableFile(_, _, let reason):
            return "\(reason). Your words are intact inside it — Maugham won’t open a "
                 + "shortened version over them. You can read what’s available, or "
                 + "restore from a backup."
        case .unlistableOpsDirectory(let reason):
            return "\(reason). Check the folder’s permissions (.maugham/ops), then "
                 + "reopen — or restore from a backup."
        }
    }

    /// Start the readability watch. For the stub cause the download is
    /// triggered once, first. The watch auto-opens EDITABLE on readability —
    /// Denver's ruling: auto from the refusal pane, offer from an open view.
    func beginWatching() {
        guard watcher == nil else { return }
        let watchedURL: URL?
        switch cause {
        case .icloudNotDownloaded(_, let url): startDownload(url); watchedURL = url
        case .unreadableFile(_, let url, _): watchedURL = url
        case .unlistableOpsDirectory: watchedURL = nil   // Retry is manual here.
        }
        guard let watchedURL else { return }
        watcher = Task { [probeInterval, isReadable, onOpenEditable] in
            while !Task.isCancelled {
                try? await Task.sleep(for: probeInterval)
                if Task.isCancelled { return }
                if isReadable(watchedURL) { onOpenEditable(); return }
            }
        }
    }

    func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    /// Cheap readability probe: open-for-reading + read one byte. Never a
    /// whole-file read (a poll must not cost megabytes), never a write.
    nonisolated static func defaultReadableProbe(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false } // adr-0018-ok: an op-log file's readability, one byte — never manuscript text
        defer { try? handle.close() }
        // Zero-length is readable (a truthfully empty file); a stub or a
        // permissions break throws above or here.
        return (try? handle.read(upToCount: 1)) != nil
    }

    nonisolated static func defaultStartDownload(_ url: URL) {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }
}

/// The ladder rendered (spec §3). Thin: every behaviour lives on the model.
struct DocumentRecoveryPane: View {
    let model: RecoveryPaneModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28)).foregroundStyle(.orange)
            Text(model.headline).font(.headline)
                .multilineTextAlignment(.center)
            Text(model.detail).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 8) {
                if model.offersReadOnly {
                    Button("Open Read-Only") { model.onOpenReadOnly() }
                }
                if model.offersRestore {
                    Button("Restore from Backup…") {
                        openWindow(id: "backup-restore", value: model.projectURL)
                    }
                }
            }
            if case .icloudNotDownloaded = model.cause {
                ProgressView().controlSize(.small)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { model.beginWatching() }
        .onDisappear { model.stopWatching() }
    }
}
