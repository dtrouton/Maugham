import SwiftUI
import MaughamCore

/// **An edition's Brief** (shell plan 3 Task 5; spec "Brief"): what the
/// edition is held to — its edition brief (the essay, its rulings and the
/// glossary those rulings hold), who is cast for it, and the book's visual
/// language, which pulls up.
///
/// **The brief is `StatementPane(kind: .editionBrief(language), subject:
/// .project)`**: one way to edit a statement, and the glossary is that pane's
/// own rulings stratum. A brief Claude proposed shows there, as the gate over
/// the editor, with Adopt and Discard.
///
/// **The cast is a fact of the edition, so it is changed here** (shell p4
/// Task 7, the desk gone): read by name (`EditionStatus`' non-minting
/// lookups) and changed through `EditionCastVerbs`, whose sheet names the
/// translator, the reader and the collator. Offered where this Mac may write
/// the edition's brief; hidden, never disabled.
///
/// **The Source edition is the book itself**: it has no brief. It names who
/// designs the book (changed here too), and a brief Claude proposed for a
/// language the book has no edition of yet shows here, with the way to add
/// that edition. Which language is the source is the publish config's
/// (`PublishImprint.sourceLanguage`, as the tree's edition rows ask it),
/// read in `.task`.
struct BriefEditionView: View {
    @Bindable var store: ProjectStore
    let documentStore: DocumentStore
    let language: String
    let onPullUp: (PulledUp) -> Void

    /// The book's own language, once read; nil until then (nothing is drawn
    /// over a guess, so the source edition never mounts a brief's editor).
    @State private var source: String?
    /// The editions the tree lists, read with `source`.
    @State private var editions: [String] = []
    /// Pending proposals, read in `.task` and re-read on their event.
    @State private var proposals: [StatementProposalStore.Proposal] = []
    @State private var proposalReloads = 0
    @State private var castPrompt: EditionCastPrompt?
    /// What the last cast verb said; cleared on the next.
    @State private var notice: String?
    @State private var window: NSWindow?

    static let sourceLine = "The source edition is the book itself."
    static let noBriefPrompt = "This edition has no brief yet. Write how it should read here."
    static let castHeading = "Cast"
    static let designerHeading = "Designer"
    static let noCastLine = "No one is cast for this edition yet."

    // MARK: - Pure

    /// Whether `language` is the source edition's. Tags compare
    /// case-insensitively.
    static func isSource(_ language: String, source: String) -> Bool {
        language.caseInsensitiveCompare(source) == .orderedSame
    }

    /// The parts an edition's Brief draws, in order.
    enum Part: Equatable { case sourceLine, designer, proposedEditions, brief, cast, visualLanguage }

    static func parts(isSource: Bool) -> [Part] {
        isSource ? [.sourceLine, .designer, .proposedEditions, .visualLanguage]
            : [.brief, .cast, .visualLanguage]
    }

    /// The prompt over a brief not yet written; nil once one exists.
    static func briefPrompt(hasBrief: Bool) -> String? {
        hasBrief ? nil : noBriefPrompt
    }

    struct CastLine: Equatable, Identifiable {
        let role: String
        let name: String
        var id: String { role }
    }

    /// Who is cast for `language`, by name, read without minting. A role
    /// nobody holds is left out.
    static func cast(language: String, in manifest: ProjectManifest) -> [CastLine] {
        [("Translator", EditionStatus.translatorName(for: language, in: manifest)),
         ("Reader", EditionStatus.readerName(for: language, in: manifest)),
         ("Collator", EditionStatus.collatorName(for: language, in: manifest))]
            .compactMap { role, name in name.map { CastLine(role: role, name: $0) } }
    }

    /// The source language, read as the tree's edition rows read it. `.task`
    /// only.
    @MainActor
    static func sourceLanguage(store: ProjectStore) -> String {
        let config = (try? PublishConfigStore.read(in: store.url)) ?? nil
        return PublishImprint.sourceLanguage(
            imprint: nil, in: config,
            pieceIDs: EditionStatus.manuscriptDocumentIds(in: store.manifest))
    }

    private struct ReadKey: Equatable {
        let language: String
        let manifest: Date
        let proposals: Int
        let windowResolved: Bool
    }

    // MARK: - The view

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let source {
                ForEach(Self.parts(isSource: Self.isSource(language, source: source)), id: \.self) { part in
                    draw(part)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WindowAccessor(window: $window))
        // One listing, one config read and one proposals read per key — never
        // on a body path (tripwire 4).
        .task(id: ReadKey(language: language, manifest: store.manifest.modified,
                          proposals: proposalReloads, windowResolved: window != nil)) {
            source = Self.sourceLanguage(store: store)
            editions = TreeEditionRows.languages(store: store)
            proposals = StatementProposalStore(projectURL: store.url).pendingAll()
        }
        .onProjectEvent(.maughamStatementProposalsChanged, url: store.url, window: window) { _ in
            proposalReloads += 1
        }
        .onChange(of: language) { _, _ in notice = nil }
        .sheet(item: $castPrompt) { prompt in
            EditionCastSheet(
                prompt: prompt,
                onConfirm: { answer in
                    castPrompt = nil
                    Task {
                        notice = await EditionCastVerbs.confirmRename(
                            answer, prompt: prompt, store: store, documentStore: documentStore)
                    }
                },
                onCancel: {
                    castPrompt = nil
                    notice = EditionCastVerbs.cancelledLine(prompt)
                })
        }
    }

    @ViewBuilder
    private func draw(_ part: Part) -> some View {
        switch part {
        case .sourceLine:
            Text(Self.sourceLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .designer:
            designerSection
        case .proposedEditions:
            proposedEditions
        case .brief:
            VStack(alignment: .leading, spacing: 0) {
                if let prompt = Self.briefPrompt(hasBrief: store.statement(
                    kind: .editionBrief(language), scope: .project) != nil) {
                    Text(prompt)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                }
                // An edition brief is project-scope by construction. No
                // bible — a brief establishes nothing about the manuscript.
                StatementPane(
                    store: store, documentStore: documentStore,
                    kind: .editionBrief(language),
                    subject: .project)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .layoutPriority(1)
        case .cast:
            castSection
        case .visualLanguage:
            BriefPullUpLines(
                store: store,
                lines: [BriefBookView.PullUpLine(title: BriefBookView.visualLanguageTitle,
                                                 request: .visualLanguage)],
                onPullUp: onPullUp)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A section's heading with its door at the trailing edge.
    private func heading(_ title: String, door: String?, label: String,
                         action: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            BriefPane.sectionHeading(title)
            Spacer(minLength: 6)
            if let door {
                Button(door, action: action)
                    .buttonStyle(.link)
                    .font(.caption)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityLabel(label)
                    .help(label)
            }
        }
    }

    @ViewBuilder
    private var noticeLine: some View {
        if let notice {
            Text(notice)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("brief.edition.notice")
        }
    }

    private var castSection: some View {
        let lines = Self.cast(language: language, in: store.manifest)
        let mayCast = EditionCastVerbs.mayCast(language: language, store: store,
                                               documentStore: documentStore)
        return VStack(alignment: .leading, spacing: 4) {
            Divider().padding(.bottom, 6)
            heading(Self.castHeading,
                    door: mayCast ? EditionCastVerbs.castDoorTitle(hasCast: !lines.isEmpty) : nil,
                    label: EditionCastVerbs.castDoorLabel(language: language)) {
                notice = nil
                castPrompt = EditionCastVerbs.renamePrompt(language: language, in: store.manifest)
            }
            if lines.isEmpty {
                Text(Self.noCastLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(line.role)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(line.name)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            noticeLine
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var designerSection: some View {
        let name = store.designerRole().effectiveName
        let mayName = EditionCastVerbs.mayNameTheDesigner(store: store, documentStore: documentStore)
        return VStack(alignment: .leading, spacing: 4) {
            Divider().padding(.bottom, 6)
            heading(Self.designerHeading,
                    door: mayName ? EditionCastVerbs.changeCastTitle : nil,
                    label: DesignRoundState.renameTitle(designerName: name)) {
                notice = nil
                castPrompt = EditionCastVerbs.designerPrompt(store: store)
            }
            Text(name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
            noticeLine
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Proposed briefs for languages with no edition yet: a line each, Add
    /// (the Editions `+`'s sheet, opened on that language) and Discard, each
    /// asked of its own posture.
    @ViewBuilder
    private var proposedEditions: some View {
        let languages = EditionCastVerbs.proposalsWithoutAnEdition(proposals, editions: editions)
        if !languages.isEmpty {
            let mayAdd = EditionCastVerbs.mayAddLanguage(documentStore: documentStore)
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                ForEach(languages, id: \.self) { tag in
                    let mayDiscard = EditionCastVerbs.mayCast(language: tag, store: store,
                                                              documentStore: documentStore)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(EditionCastVerbs.proposedWithoutAnEditionLine(language: tag))
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if mayAdd || mayDiscard {
                            FlowLayout(spacing: 6) {
                                if mayAdd {
                                    Button(EditionCastVerbs.addProposedTitle(language: tag)) {
                                        MaughamEvent.postAddLanguage(proposing: tag)
                                    }
                                    .controlSize(.small)
                                    .fixedSize()
                                }
                                if mayDiscard {
                                    Button(EditionCastVerbs.discardProposalTitle) {
                                        Task {
                                            notice = await EditionCastVerbs.discardProposal(
                                                language: tag, store: store, documentStore: documentStore)
                                        }
                                    }
                                    .controlSize(.small)
                                    .fixedSize()
                                    .accessibilityLabel(EditionCastVerbs.discardProposalLabel(language: tag))
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
