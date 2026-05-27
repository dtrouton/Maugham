import SwiftUI
import AppKit

/// Binder footer section listing files in the project's `Exports/` directory.
/// Click to open in the default macOS handler (Preview.app for PDF, default
/// EPUB reader for .epub). Right-click for reveal-in-Finder / delete.
///
/// Refresh is driven by:
/// - `.onAppear`
/// - `.maughamPublicationCompleted` notification (posted by
///   `CompileOrchestrator` on successful publish)
///
/// Sort is lexically descending by filename, which puts newer versions first
/// for simple "v0.N" suffixes but mis-sorts across the v0.9 → v0.10 boundary.
/// Acceptable for v1; sort by mtime is a follow-up.
struct ExportsListView: View {

    let projectURL: URL

    @State private var entries: [Model.Entry] = []
    @State private var isExpanded: Bool = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if entries.isEmpty {
                Text("No publications yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(entries) { entry in
                    Button {
                        NSWorkspace.shared.open(entry.url)
                    } label: {
                        HStack {
                            Image(systemName: entry.icon)
                            Text(entry.name).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(entry.size)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                        }
                        Button("Delete…", role: .destructive) {
                            try? FileManager.default.removeItem(at: entry.url)
                            refresh()
                        }
                    }
                }
            }
        } label: {
            Label("Exports", systemImage: "square.and.arrow.up")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(
            for: .maughamPublicationCompleted)) { _ in refresh() }
    }

    private func refresh() {
        entries = Model(projectURL: projectURL).scan()
    }
}

extension ExportsListView {

    struct Model {
        let projectURL: URL

        struct Entry: Identifiable {
            let url: URL
            var name: String { url.lastPathComponent }
            var icon: String {
                url.pathExtension.lowercased() == "epub" ? "book" : "doc.richtext"
            }
            var size: String {
                let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
                let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            }
            var id: String { url.path }
        }

        func scan() -> [Entry] {
            let exports = projectURL.appendingPathComponent("Exports", isDirectory: true)
            guard FileManager.default.fileExists(atPath: exports.path) else { return [] }
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: exports,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles])) ?? []
            return urls
                .filter { ["pdf", "epub"].contains($0.pathExtension.lowercased()) }
                .map(Entry.init)
                .sorted { $0.name > $1.name }   // newest-first by name (lexical)
        }
    }
}

extension Notification.Name {
    static let maughamPublicationCompleted = Notification.Name("maughamPublicationCompleted")
}
