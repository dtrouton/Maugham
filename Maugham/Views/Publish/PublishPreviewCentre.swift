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
    /// **A design proposal the writer asked to look at** (publish-department P4
    /// Task 5) — the department desk's Show, answered in this column.
    ///
    /// It outranks the two arms below while it is selected, for the reason the
    /// book outranks altitude: the writer asked for the proposal, and a compiled
    /// PDF drawn over the thing they asked to see is the truth table upside
    /// down. Deselecting hands the column straight back — this arm carries no
    /// state of its own, so there is nothing for leaving it to cost.
    ///
    /// The proposal travels whole rather than by id: it was just read off disk
    /// by the desk that offered the Show, and a second read here would be a
    /// second answer about the same file.
    case designProposal(DesignProposalStore.Proposal)
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

    /// **The header, and the one place this view branches on VoiceOver rather
    /// than on layout.**
    ///
    /// With a single publication the row is four labels and no control, so it is
    /// COMBINED into one sentence — *"The Novel, v1.0 · ES · 12 Aug 2026 at
    /// 15:04"* — which is what this column read before the picker existed and is
    /// the right reading: four fragments swept past one arrow key at a time say
    /// less than the sentence they make together.
    ///
    /// With a choice to make the row must NOT combine, and that is the whole
    /// reason for the branch: `.combine` flattens its children into one static
    /// element, and the child it would flatten here is the `Picker` — the only
    /// way to reach another publication without a mouse. Combining it away
    /// would trade a slightly better sentence for a control a VoiceOver user
    /// cannot operate. Uncombined, the title reads itself and the picker
    /// announces its own label and value.
    @ViewBuilder
    private var header: some View {
        if publications.count > 1 {
            headerRow
        } else {
            headerRow
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel)
        }
    }

    private var headerRow: some View {
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
        PublishNoticeLine(headline: notice.headline, detail: notice.detail,
                          symbol: notice.symbol, tint: notice.tint)
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
    }
}

/// **The house shape for "Maugham couldn't read this"** — a symbol, a headline
/// and the failure's own sentence under it, in a bordered card.
///
/// Extracted from `PublishCentreNoticeBanner` when Publish grew a second place
/// to say it (issue #43, F-D: the department desk names a chapter whose history
/// file it could not open). Plain strings rather than `PublishCentreNotice`,
/// because the desk's line is about one document rather than about the centre
/// column's two ways of having no book — and two hand-built cards that looked
/// almost alike would be the writer learning the same signal twice.
///
/// The banner keeps its own outer frame, `allowsHitTesting(false)` and padding:
/// those are about standing over the altitude view, which is that surface's
/// concern and not this shape's.
struct PublishNoticeLine: View {
    let headline: String
    let detail: String
    /// Defaults to the warning triangle, which is what every caller so far is:
    /// something present that cannot be read.
    var symbol: String = "exclamationmark.triangle.fill"
    var tint: Color = .orange

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.callout.weight(.medium))
                Text(detail)
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(headline). \(detail)")
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
    /// **The design proposal the desk's Show put in this column** (P4 Task 5),
    /// cleared by any persona change.
    ///
    /// Here rather than in a modifier of its own because this is already the one
    /// place that owns the Publish centre's transient picks, and the body it
    /// hangs off has no expression budget (the Release type-check ceiling).
    ///
    /// **It clears where `selectedPublicationID` deliberately does not**, and
    /// the asymmetry is the point. The publication pick is a place in a
    /// *reading* — Denver's ruling keeps it across a walk out of Publish and
    /// back. The gate is a place in a *decision*: the writer entered it by
    /// pressing Show and a persona change is them leaving. Coming back to
    /// Publish should show the book, which is what Publish is for, and pressing
    /// Show again is one click.
    @Binding var selectedProposal: DesignProposalStore.Proposal?

    func body(content: Content) -> some View {
        content
            .task(id: projectURL) { await refresh() }
            .onProjectEvent(.maughamPublicationCompleted,
                            url: projectURL, window: window) { _ in
                Task { await refresh() }
            }
            .onChange(of: persona) { _, next in
                // Before the arrival guard: leaving Publish is a persona change
                // too, and it is the one that most needs the gate let go of.
                selectedProposal = nil
                guard next.previewsThePublishedBook else { return }
                Task { await refresh() }
            }
            // **The gate's proposal goes stale where it sits** (the final-review
            // wave). It is a VALUE the writer opened with, and three things move
            // the record underneath it: a new round stages and supersedes it, a
            // promotion rewrites its status from the desk or another window, and
            // `.maugham/design/` is derived — a writer who clears it deletes the
            // very folder the gate is describing. `.project`-scoped through the
            // ADR 0021 helper, which drops the post for a closed window.
            .onProjectEvent(.maughamDesignProposalsChanged,
                            url: projectURL, window: window) { _ in
                rereadSelectedProposal()
            }
    }

    /// **The selected proposal as the store now holds it** — or nothing, when
    /// the store no longer holds it at all.
    ///
    /// Re-read BY ID rather than re-derived from the listing: which round the
    /// writer is looking at is their own choice, and no event may move them to a
    /// different one. What an event can change is what that round IS —
    /// `.superseded` and `.rejected` draw `DesignGate.settledNote` and no verbs,
    /// which is already a pure function of the status, so the whole of "the gate
    /// stops offering verdicts on a round that is past deciding" is this one
    /// write.
    ///
    /// **An unreadable proposal clears the selection**, which is the honest
    /// answer rather than a defensive one: the record is gone or unparseable, so
    /// there is nothing for the gate to describe and the column hands itself
    /// back to the book. Keeping the stale value would leave four verbs standing
    /// over a proposal that no longer exists.
    private func rereadSelectedProposal() {
        guard let id = selectedProposal?.id else { return }
        selectedProposal = try? DesignProposalStore(projectURL: projectURL)
            .load(id: id)
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
