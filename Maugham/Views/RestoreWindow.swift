import SwiftUI
import AppKit
import MaughamCore

struct RestoreWindow: View {
    let projectURL: URL
    @Environment(BackupCoordinator.self) private var backupCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var generations: [RestoreGeneration] = []
    /// Generation directories that verified intact — computed once on load, not in
    /// the row body (verifying re-hashes the whole generation; doing it per render
    /// span­s an AttributeGraph cycle on large backups).
    @State private var intact: Set<URL> = []
    /// The selected generation's directory. A generation *directory* is unique;
    /// its `id` (the ULID) is NOT — a single backup run stamps the same id into
    /// every destination — so the list keys on `directory`, not `id`.
    @State private var selection: URL?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Restore \(projectURL.lastPathComponent)").font(.headline)
                .padding(12)
            Divider()
            if generations.isEmpty {
                ContentUnavailableView("No backups found",
                    systemImage: "externaldrive.badge.questionmark",
                    description: Text("No backup generations exist for this project yet."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(generations, id: \.directory, selection: $selection) { gen in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(gen.builtAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? gen.id)
                            Text(gen.destination.deletingLastPathComponent().lastPathComponent)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if intact.contains(gen.directory) {
                            Label("Verified", systemImage: "checkmark.seal").labelStyle(.iconOnly)
                                .foregroundStyle(.green).help("Integrity verified")
                        } else {
                            Label("Corrupt", systemImage: "exclamationmark.triangle").labelStyle(.iconOnly)
                                .foregroundStyle(.orange).help("This generation failed verification")
                        }
                    }
                }
            }
            Divider()
            if let error { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 12) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Restore a Copy…") { restore() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }.padding(12)
        }
        .frame(minWidth: 520, minHeight: 420)
        .task { await load() }
    }

    private func load() async {
        let gens = backupCoordinator.generations(forProject: projectURL)
        var ok: Set<URL> = []
        for gen in gens where BackupRestore.verify(gen).isEmpty { ok.insert(gen.directory) }
        generations = gens
        intact = ok
    }

    private func restore() {
        guard let dir = selection,
              let gen = generations.first(where: { $0.directory == dir }) else { return }
        let panel = NSSavePanel()
        panel.message = "Choose where to restore a copy of this project."
        panel.nameFieldStringValue = projectURL.lastPathComponent + " (restored)"
        panel.directoryURL = projectURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do {
            // NSSavePanel may have created/cleared the target; restoreBeside refuses an
            // existing target, so remove an empty placeholder the panel made.
            try? FileManager.default.removeItem(at: target)
            let restored = try BackupRestore.restoreBeside(gen, to: target)
            NSWorkspace.shared.activateFileViewerSelecting([restored])
            dismiss()
        } catch {
            self.error = "Restore failed: \(error.localizedDescription)"
        }
    }
}
