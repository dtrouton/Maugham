import SwiftUI
import AppKit

/// **What the Publish persona's centre column puts over the manuscript stack**
/// (shell-finish stage 3b Task 5, revised by Denver's rulings of 2026-08-12).
///
/// One value with two arms, answered by `ProjectWindow.publishCentre`, so the
/// window has a single question to ask rather than one gate per surface. Two
/// gates would be two answers free to disagree about what is in the centre
/// column — and here that disagreement would be a "nothing published yet"
/// notice sitting on top of the writer's compiled book.
///
/// **Neither arm is reachable over a chapter.** Denver, 2026-08-12: *"a
/// chapter/piece subject in Publish ALWAYS opens the editor — I might tweak
/// something for layout."* The preview and its notices are PROJECT-level
/// surfaces, which is why the rule now asks the subject question at all (it
/// took none until this revision).
enum PublishCentre: Equatable {
    /// Every readable PDF, newest first and non-empty. WHICH of them is drawn is
    /// the header picker's business — a window-transient choice — and
    /// deliberately not this rule's: a rule that carried the selection would be
    /// re-decided on every keystroke of window state.
    case books([Publication])
    /// Nothing to draw, and the reason kept — see `PublishCentreNotice`.
    case notice(PublishCentreNotice)
}

/// **The two ways Publish has no book to show, kept apart on screen.**
///
/// RULING-7's shape ("unreadable is never presented as empty") is why
/// `PublishPreviewResolution` carries a reason rather than an optional; until
/// Denver's 2026-08-12 ruling that distinction lived only in the value and both
/// degrades looked identical to the writer — a bare corkboard, which is what
/// read to him as *"basically Author"*. Each now says its own thing, and they
/// are DIFFERENT things: one is a project that has not been compiled, the other
/// is a project whose catalog is sitting right there and cannot be read.
enum PublishCentreNotice: Equatable {
    /// The catalog was read and holds no PDF this column can draw.
    case neverCompiled
    /// The catalog exists and could not be read, carrying the failure's own
    /// sentence — which already NAMES the file (`PublicationStore.ReadError
    /// .unreadableFile`), so the banner does not have to invent a name for it.
    case unreadableCatalog(reason: String)

    var headline: String {
        switch self {
        case .neverCompiled:
            return "No compiled book yet"
        case .unreadableCatalog:
            return "Preview unavailable — the publications catalog can't be read"
        }
    }

    var detail: String {
        switch self {
        case .neverCompiled:
            return "Your published output will appear here."
        case .unreadableCatalog(let reason):
            return reason
        }
    }

    /// Distinct at a glance, which is the point of keeping the two cases: a
    /// writer must never mistake "your book can't be read from here" for "you
    /// haven't made one yet".
    var symbol: String {
        switch self {
        case .neverCompiled: return "book.closed"
        case .unreadableCatalog: return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .neverCompiled: return .secondary
        case .unreadableCatalog: return .orange
        }
    }
}

/// **The centre column of the Publish persona: the book itself** (shell-finish
/// stage 3b Task 5, spec §4's Publish column).
///
/// Denver's rulings, recorded: the compiled book is a PROJECT-level surface (a
/// chapter subject opens the editor, because a writer in Publish still tweaks
/// things for layout), and the header carries a picker over every readable PDF
/// publication so a writer can put the previous version — or another language
/// edition — on screen. Which one is showing is window-transient and never
/// persisted: a relaunch is the newest book, always.
///
/// A header over `PDFPreview` (`Maugham/Views/research/PDFPreview.swift`),
/// reused rather than copied: one `PDFView` configuration in the app, so the
/// research preview and the book cannot come to scroll differently.
///
/// **Opaque and full-frame on purpose.** This is the third layer of
/// `ProjectWindow.manuscriptEditor`'s `ZStack` — `EditorHost` is still mounted
/// underneath it (and the altitude view is too, since both are project-level),
/// and anything translucent would read the corkboard through the page.
///
/// `title` is the PROJECT's, not the publication's: a `Publication` carries a
/// version, a language and a date, and none of them says which book this is.
struct PublishPreviewCentre: View {
    /// Newest first, non-empty — `PublishCentre.books`' own contract.
    let publications: [Publication]
    let projectURL: URL
    let title: String
    /// The writer's pick, by `publicationID`. `nil` is "the newest", which is
    /// also what a new compile resets it to (`PublishPreviewModifier`).
    @Binding var selectedPublicationID: String?

    /// Never resolved locally — `PublishPreviewResolver.shown` owns the fallback
    /// so that a pick whose row has left the list still draws the newest book
    /// rather than an empty column.
    private var shown: Publication? {
        PublishPreviewResolver.shown(selectedPublicationID, in: publications)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let shown {
                PDFPreview(fileURL: PublishPreviewResolver.fileURL(
                    of: shown, in: projectURL))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "book.closed")
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if publications.count > 1 {
                picker
            } else if let shown {
                stamp(for: shown)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityLabel(accessibilityLabel)
    }

    /// **Every readable PDF, newest first** — EPUBs are the Exports footer's
    /// business, since this column draws pages. Shown only when there is a
    /// choice to make: a one-entry menu is chrome about nothing, which is the
    /// same argument the language capsule below already makes for itself.
    private var picker: some View {
        Picker("Publication", selection: Binding(
            get: { shown?.publicationID },
            set: { selectedPublicationID = $0 })) {
                ForEach(publications, id: \.publicationID) { publication in
                    Text(Self.label(for: publication))
                        .tag(Optional(publication.publicationID))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityLabel("Publication")
    }

    /// The single-publication header: what this column showed before there was
    /// anything to choose between.
    @ViewBuilder
    private func stamp(for publication: Publication) -> some View {
        HStack(spacing: 8) {
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
            Text(Self.compiled.string(from: publication.compiledAt))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var accessibilityLabel: String {
        guard let shown else { return title }
        return "\(title), \(Self.label(for: shown))"
    }

    /// One row of the menu, and the header's own sentence: version, language
    /// when there is one, and when it was compiled — the three facts that tell
    /// two publications of the same book apart.
    static func label(for publication: Publication) -> String {
        var parts = ["v\(publication.version)"]
        if let language = publication.language { parts.append(language.uppercased()) }
        parts.append(compiled.string(from: publication.compiledAt))
        return parts.joined(separator: " · ")
    }

    private static let compiled: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

/// **The standing notice over the project at altitude** (Denver, 2026-08-12).
///
/// A BANNER rather than a `ContentUnavailableView`, because the centre column is
/// not empty: the corkboard/outline is underneath and is real, usable content.
/// The banner names why there is no book over it — the bare unexplained
/// altitude is what read as *"basically Author"* and sent Denver looking for the
/// missing feature.
///
/// **`allowsHitTesting(false)` is load-bearing, not tidiness.** The banner fills
/// the column (top-aligned) so it can sit at the head of whatever is beneath it;
/// without this, that frame would swallow every click meant for the altitude
/// view's cards and rows — the surface the notice exists to explain.
struct PublishCentreNoticeBanner: View {
    let notice: PublishCentreNotice

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: notice.symbol)
                .foregroundStyle(notice.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.headline)
                    .font(.callout.weight(.medium))
                Text(notice.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.secondary.opacity(0.25)))
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(notice.headline). \(notice.detail)")
    }
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
/// **It is also where a new compile takes the writer's manual pick away**
/// (Denver, 2026-08-12: *"a NEW compile snaps the preview back to the
/// newest"*). The reset is keyed on the NEWEST publication changing rather than
/// on the refresh happening, so walking out of Publish and back keeps whatever
/// the writer was looking at — a refresh is not news, a new book is.
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
    /// The header picker's window-transient choice, cleared when a new book
    /// arrives. Never persisted — a relaunch is always the newest.
    @Binding var selectedPublicationID: String?

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
        let next = await PublishPreviewResolver.readablePDFs(
            store: stores.publicationStore, projectURL: projectURL)
        if next.publication?.publicationID
            != publishPreview.publication?.publicationID {
            selectedPublicationID = nil
        }
        publishPreview = next
    }
}
