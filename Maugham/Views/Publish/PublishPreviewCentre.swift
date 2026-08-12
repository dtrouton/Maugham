import SwiftUI
import AppKit

/// **The centre column of the Publish persona: the book itself** (shell-finish
/// stage 3b Task 5, spec §4's Publish column).
///
/// Denver's decision, recorded: the most recent compiled PDF, and a piece
/// subject shows the SAME preview rather than a slice of it — which is why
/// nothing about the window's subject reaches this view. It is handed a
/// `Publication` and draws it.
///
/// A header over `PDFPreview` (`Maugham/Views/research/PDFPreview.swift`),
/// reused rather than copied: one `PDFView` configuration in the app, so the
/// research preview and the book cannot come to scroll differently.
///
/// **Opaque and full-frame on purpose.** This is the third layer of
/// `ProjectWindow.manuscriptEditor`'s `ZStack` — `EditorHost` is still mounted
/// underneath it (and the altitude view may be too), and anything translucent
/// would read the placeholder through the page.
///
/// `title` is the PROJECT's, not the publication's: a `Publication` carries a
/// version, a language and a date, and none of them says which book this is.
struct PublishPreviewCentre: View {
    let publication: Publication
    let projectURL: URL
    let title: String

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            PDFPreview(fileURL: PublishPreviewResolver.fileURL(
                of: publication, in: projectURL))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "book.closed")
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("v\(publication.version)")
                .font(.caption)
                .foregroundStyle(.secondary)
            // Only when there is one: a source-language publication has no
            // language tag, and an empty capsule beside every book would be
            // chrome about nothing.
            if let language = publication.language {
                Text(language.uppercased())
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
            Spacer()
            Text(Self.compiled.string(from: publication.compiledAt))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(title), version \(publication.version), compiled "
            + Self.compiled.string(from: publication.compiledAt))
    }

    private static let compiled: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

/// **Keeping the centre column's book current**, with no watcher and no poll.
///
/// Three triggers, and each answers a way the answer can go stale:
///
/// - **The window opens** (`.task(id:)`) — the writer relaunches into Publish.
/// - **A compile completes** — `CompileOrchestrator` posts
///   `.maughamPublicationCompleted` AFTER appending to the catalog, scoped
///   `.project`; received through the ADR 0021 helper, which filters to this
///   project and drops closed windows.
/// - **Arriving in Publish** (`.onChange(of: persona)`) — which also covers the
///   export a writer deleted in the Finder while they were elsewhere. That is
///   deliberately not a directory watcher: the staleness only matters when the
///   book is about to be on screen, and a watcher would be a second source of
///   truth about a file the resolver already checks.
///
/// A modifier rather than lines in `ProjectWindow.body`, which has no expression
/// budget under the Release type-checker. Delete the one line that applies it
/// and every token in this file is still present, every decision test still
/// green, and the writer's compile never reaches the centre column.
struct PublishPreviewModifier: ViewModifier {
    let projectURL: URL
    /// Hosting window for ADR 0021's project scope + closed-window liveness
    /// guard, the `ExportsListView` idiom.
    let window: NSWindow?
    /// Read, never written: which persona the writer is in is their own choice,
    /// and this only wants to know when they arrive.
    let persona: Persona
    @Binding var publishPreview: PublishPreviewResolution

    func body(content: Content) -> some View {
        content
            .task(id: projectURL) { await refresh() }
            .onProjectEvent(.maughamPublicationCompleted,
                            url: projectURL, window: window) { _ in
                Task { await refresh() }
            }
            .onChange(of: persona) { _, next in
                guard next.previewsThePublishedBook else { return }
                Task { await refresh() }
            }
    }

    private func refresh() async {
        let stores = PublishingStores.sharedFor(
            projectID: ProjectIdentifier.id(for: projectURL),
            projectURL: projectURL)
        publishPreview = await PublishPreviewResolver.latestReadablePDF(
            store: stores.publicationStore, projectURL: projectURL)
    }
}
