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
                    HStack {
                        VStack(alignment: .leading) {
                            Text(cfg.displayName)
                            Text("Keep \(cfg.retention) generations")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
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
            bookmark: bookmark,
            retention: 10)
        themeManager.backupDestinations.append(cfg)
    }

    private func remove(_ cfg: BackupDestinationConfig) {
        themeManager.backupDestinations.removeAll { $0.id == cfg.id }
    }
}
