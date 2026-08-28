import SwiftUI
import MaughamCore
import AppKit

/// Binder footer section listing files in the project's `Exports/` directory.
/// Click to open in the default macOS handler (Preview.app for PDF, default
/// EPUB reader for .epub). Right-click for reveal-in-Finder / delete.
///
/// Refresh is driven by:
/// - `.onAppear`
/// - `.maughamPublicationCompleted` — scope declared at the post
///   (`CompileOrchestrator`, `.project(for: projectURL)`); the `.onProjectEvent`
///   helper filters to this project and drops closed windows (ADR 0021).
///
/// Sort is by file modification date, newest first — the most recently
/// compiled publication is always at the top, regardless of version-string
/// quirks (e.g. v0.9 → v0.10).
struct ExportsListView: View {

    let projectURL: URL

    @State private var entries: [Model.Entry] = []
    @State private var isExpanded: Bool = true
    /// Hosting window for the ADR 0021 project scope + closed-window liveness
    /// guard on `.maughamPublicationCompleted`.
    @State private var window: NSWindow?

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if entries.isEmpty {
                Text("No publications yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Bounded, scrollable list so a long publication history
                // stays scrollable within the binder section instead of
                // pushing the rest of the pane off-screen.
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(entries) { entry in
                            Button {
                                NSWorkspace.shared.open(entry.url)
                            } label: {
                                HStack {
                                    Image(systemName: entry.icon)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(entry.name).lineLimit(1).truncationMode(.middle)
                                        // The catalog record's own identity, when
                                        // there is one — read off the RECORD
                                        // rather than the filename (spec §6), so
                                        // the imprint and languages show even
                                        // when the file's own name says nothing
                                        // about them.
                                        if let record = entry.record {
                                            Text(PublishPreviewCentre.parts(for: record)
                                                .joined(separator: " \u{00B7} "))
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                                .lineLimit(1)
                                        }
                                    }
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
                }
                .frame(maxHeight: 220)
            }
        } label: {
            Label("Exports", systemImage: "square.and.arrow.up")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(WindowAccessor(window: $window))
        .onAppear(perform: refresh)
        .onProjectEvent(.maughamPublicationCompleted,
                        url: projectURL, window: window) { _ in refresh() }
    }

    private func refresh() {
        Task { @MainActor in
            entries = await Model(projectURL: projectURL).scan()
        }
    }
}

extension ExportsListView {

    struct Model {
        let projectURL: URL

        struct Entry: Identifiable {
            let url: URL
            let modified: Date
            /// The catalog row this file's path matches, when there is one —
            /// joined by `outputPath`, never by parsing the filename (spec §6):
            /// a filename is written once at compile time and a writer can
            /// rename the file on disk without touching what the catalog says
            /// it is.
            let record: Publication?
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

        /// **Reads the publications catalog once per scan, off the main path**
        /// — `try?` so an unreadable catalog (RULING-54's own failure mode)
        /// costs entries their secondary line and nothing else: every file
        /// still lists by its bare name, and a corrupt device file must never
        /// take this footer down.
        @MainActor
        func scan() async -> [Entry] {
            let exports = projectURL.appendingPathComponent("Exports", isDirectory: true)
            guard FileManager.default.fileExists(atPath: exports.path) else { return [] }
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: exports,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [])) ?? []
            let records = (try? await PublishingStores.sharedFor(
                projectID: ProjectIdentifier.id(for: projectURL),
                projectURL: projectURL).publicationStore.load()) ?? []
            return urls
                .filter { !DotfileScan.isDotfile($0) }
                .filter { ["pdf", "epub"].contains($0.pathExtension.lowercased()) }
                .map { url in
                    let mod = (try? url.resourceValues(
                        forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                    let relativePath = "Exports/\(url.lastPathComponent)"
                    let record = records.first { $0.outputPath == relativePath }
                    return Entry(url: url, modified: mod, record: record)
                }
                .sorted { $0.modified > $1.modified }   // most recently compiled first
        }
    }
}

extension Notification.Name {
    static let maughamPublicationCompleted = Notification.Name("maughamPublicationCompleted")
}
