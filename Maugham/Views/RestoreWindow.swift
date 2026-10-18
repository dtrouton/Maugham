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
    /// **The last resort** (#92): every generation in every backup folder,
    /// whatever book it belongs to, offered only when none were found for this
    /// project. The writer picks by title — nothing matches a book to a
    /// generation by title or folder name, because titles collide.
    @State private var showingAll = false
    /// Each listed generation's own title, read once with the list.
    @State private var titles: [URL: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Restore \(projectURL.lastPathComponent)").font(.headline)
                .padding(12)
            Divider()
            if generations.isEmpty {
                ContentUnavailableView {
                    Label("No backups found", systemImage: "externaldrive.badge.questionmark")
                } description: {
                    Text(showingAll
                         ? "Your backup folders hold no backups."
                         : "No backups were found for this project. If its settings file was lost, its backups may be filed under another name.")
                } actions: {
                    if !showingAll {
                        Button("Show All Backups") { Task { await load(all: true) } }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(generations, id: \.directory, selection: $selection) { gen in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            if showingAll {
                                Text(titles[gen.directory] ?? "Untitled")
                            }
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

    private func load(all: Bool = false) async {
        let gens = all
            ? backupCoordinator.allGenerations()
            : backupCoordinator.generations(forProject: projectURL)
        var ok: Set<URL> = []
        var named: [URL: String] = [:]
        for gen in gens {
            if BackupRestore.verify(gen).isEmpty { ok.insert(gen.directory) }
            if all, let title = BackupCoordinator.title(of: gen) { named[gen.directory] = title }
        }
        showingAll = all
        titles = named
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
            try RestoreTarget.clearPlaceholder(at: target)
            let restored = try BackupRestore.restoreBeside(gen, to: target)
            NSWorkspace.shared.activateFileViewerSelecting([restored])
            dismiss()
        } catch {
            self.error = "Restore failed: \(error.localizedDescription)"
        }
    }
}

/// What a restore may do with the name the save panel returned. The panel can
/// leave an EMPTY placeholder at the target, and `restoreBeside` refuses an
/// existing target, so an empty folder is removed. Anything
/// with content is refused: a writer who picked an existing folder's name and
/// pressed Replace must never lose that folder (issue #56 finding — the old
/// code removed whatever was there, the open project included).
enum RestoreTarget {
    struct Occupied: LocalizedError {
        let name: String
        var errorDescription: String? {
            "Something named “\(name)” is already there, so nothing was restored. Choose a new name — a restore never replaces anything."
        }
    }

    static func clearPlaceholder(at target: URL, fileManager fm: FileManager = .default) throws {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: target.path, isDirectory: &isDirectory) else { return }
        // Only an empty FOLDER is a placeholder; any file (even an empty one)
        // is the writer's and is refused. Finder's .DS_Store doesn't count.
        guard isDirectory.boolValue,
              let contents = try? fm.contentsOfDirectory(atPath: target.path),
              contents.filter({ $0 != ".DS_Store" }).isEmpty
        else { throw Occupied(name: target.lastPathComponent) }
        try fm.removeItem(at: target)
    }
}
