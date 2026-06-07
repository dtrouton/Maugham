import SwiftUI
import AppKit

struct BackupSettingsTab: View {
    @Bindable var themeManager: UserPreferences

    var body: some View {
        Form {
            Section("Backup destinations") {
                if themeManager.backupDestinations.isEmpty {
                    Text("No destinations. Add a folder outside iCloud (a local folder, external drive, or a Dropbox/Drive-synced folder) to keep verified copies of your projects.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                ForEach(themeManager.backupDestinations) { cfg in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cfg.displayName).fontWeight(.medium)
                            if let path = displayPath(cfg) {
                                Text(path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(path)
                            }
                        }
                        Spacer(minLength: 8)
                        HStack(spacing: 6) {
                            Text("Keep \(cfg.retention)")
                                .font(.callout)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Stepper(value: retentionBinding(cfg), in: 1...50) { EmptyView() }
                                .labelsHidden()
                        }
                        Button(role: .destructive) { remove(cfg) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add destination…") { addDestination() }
            }
            Section {
                Text("Backups run automatically when you save (⌘S). A copy is verified, then written to each destination; a corrupt project is detected and skipped rather than backed up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Tip: local folders use copy-on-write, so keeping many generations is nearly free. For a cloud-synced folder (Dropbox, OneDrive, Drive) each generation re-uploads, so lower its count (2 is a good default) — Maugham can't tell a synced folder from a local one, so the choice is yours.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func addDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a backup folder (outside iCloud)."
        guard panel.runModal() == .OK, let url = panel.url,
              let bookmark = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil)
        else { return }
        // local folder → keep 10 generations by default (decision 2026-06-07).
        let cfg = BackupDestinationConfig(
            id: UUID().uuidString,
            displayName: url.lastPathComponent,
            path: url.path,
            bookmark: bookmark,
            retention: 10)
        themeManager.backupDestinations.append(cfg)
    }

    private func remove(_ cfg: BackupDestinationConfig) {
        themeManager.backupDestinations.removeAll { $0.id == cfg.id }
    }

    /// The destination's path with the home directory shown as `~`, or nil for
    /// configs saved before paths were recorded (they fall back to name only).
    private func displayPath(_ cfg: BackupDestinationConfig) -> String? {
        guard let path = cfg.path else { return nil }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    /// A binding to one destination's retention that writes back through the array
    /// element, so `UserPreferences.backupDestinations`' `didSet` persists the change.
    private func retentionBinding(_ cfg: BackupDestinationConfig) -> Binding<Int> {
        Binding(
            get: { themeManager.backupDestinations.first { $0.id == cfg.id }?.retention ?? cfg.retention },
            set: { newValue in
                guard let idx = themeManager.backupDestinations.firstIndex(where: { $0.id == cfg.id })
                else { return }
                themeManager.backupDestinations[idx].retention = newValue
            })
    }
}
