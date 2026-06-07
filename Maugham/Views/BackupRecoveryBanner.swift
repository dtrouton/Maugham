import SwiftUI
import AppKit

/// Shown across the top of a project window when the last backup was refused
/// because the project failed its integrity check — pairs the warning with the
/// Restore remedy. Mirrors `UpdateBannerView`.
struct BackupRecoveryBanner: View {
    let projectURL: URL
    @Environment(BackupCoordinator.self) private var backupCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if case .integrityFailed = backupCoordinator.lastResult {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Backups paused — this project failed an integrity check")
                        .font(.callout)
                    Text("New saves aren't being backed up until this is resolved.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Restore…") { openWindow(id: "backup-restore", value: projectURL) }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.95))
            .overlay(Divider(), alignment: .bottom)
        }
    }
}
