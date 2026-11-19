import SwiftUI
import MaughamCore

/// **An edition's Brief** (shell plan 3 Task 5; spec "Brief"): what the
/// edition is held to — its edition brief (the essay, its rulings and the
/// glossary those rulings hold), who is cast for it, and the book's visual
/// language, which pulls up.
///
/// **Today's views, mounted unchanged.** The brief is `StatementPane(kind:
/// .editionBrief(language), subject: .project)`, the very call the
/// Department desk's Edition Brief door makes (`DepartmentPaneHost.brief`):
/// one way to edit a statement, and the glossary is that pane's own rulings
/// stratum. The cast is READ here — `EditionStatus`'s non-minting name
/// lookups — and changed only on the desk (`DepartmentCastSheet`); nothing
/// in this file writes the manifest (`BriefEditionTests.test_theCastIsReadNotWritten`).
///
/// **The source edition is the book itself**: it has no brief. Which
/// language is the source is the publish config's (`DepartmentPaneHost
/// .sourceLanguage`, as the tree's edition rows ask it), read in `.task`.
struct BriefEditionView: View {
    @Bindable var store: ProjectStore
    let documentStore: DocumentStore
    let language: String
    let onPullUp: (PulledUp) -> Void

    /// The book's own language, once read; nil until then (nothing is drawn
    /// over a guess, so the source edition never mounts a brief's editor).
    @State private var source: String?

    static let sourceLine = "The source edition is the book itself."
    static let noBriefPrompt = "This edition has no brief yet. Write how it should read here."
    static let castHeading = "Cast"
    static let castOnTheDesk = "The cast is changed on the Department desk."
    static let noCastLine = "No one is cast for this edition yet."

    // MARK: - Pure

    /// Whether `language` is the source edition's. Tags compare as the desk
    /// compares them, case-insensitively.
    static func isSource(_ language: String, source: String) -> Bool {
        language.caseInsensitiveCompare(source) == .orderedSame
    }

    /// The parts an edition's Brief draws, in order.
    enum Part: Equatable { case sourceLine, brief, cast, visualLanguage }

    static func parts(isSource: Bool) -> [Part] {
        isSource ? [.sourceLine, .visualLanguage] : [.brief, .cast, .visualLanguage]
    }

    /// The prompt over a brief not yet written; nil once one exists. The way
    /// to write one is the editor beneath it, which mints on the first
    /// keystroke, as everywhere a statement is written.
    static func briefPrompt(hasBrief: Bool) -> String? {
        hasBrief ? nil : noBriefPrompt
    }

    struct CastLine: Equatable, Identifiable {
        let role: String
        let name: String
        var id: String { role }
    }

    /// Who is cast for `language`, by name, read without minting
    /// (`EditionStatus.translatorName` and its siblings). A role nobody holds
    /// is left out.
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
        return DepartmentPaneHost.sourceLanguage(
            imprint: nil, in: config,
            pieceIDs: EditionStatus.manuscriptDocumentIds(in: store.manifest))
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
        .task(id: language) { source = Self.sourceLanguage(store: store) }
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
                // The desk's own call: an edition brief is project-scope by
                // construction. No bible — a brief establishes nothing about
                // the manuscript (`DepartmentPaneHost.brief`'s reason).
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

    private var castSection: some View {
        let lines = Self.cast(language: language, in: store.manifest)
        return VStack(alignment: .leading, spacing: 4) {
            Divider().padding(.bottom, 6)
            BriefPane.sectionHeading(Self.castHeading)
            if lines.isEmpty {
                Text(Self.noCastLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
            Text(Self.castOnTheDesk)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
