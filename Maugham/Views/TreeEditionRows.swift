import SwiftUI
import MaughamCore

/// **The Editions rows** (shell p1 Task 3, spec "The tree"): one row per
/// language, the source language first. There is no stored "edition" to list
/// — a row is a language the book has, and `.edition(language:)` is the
/// subject it selects.
///
/// Drawn last in `BinderTreeSections`, so every tree host has them. The rows
/// are cached on `BinderTreeSectionsState.editionRows`, read once per
/// manifest change or translation write (tripwire 4); a row does no work.
struct TreeEditionRows: View {
    /// One edition row, with its title worked out when the rows are read.
    struct Row: Equatable, Identifiable {
        let language: String
        let title: String
        let isSource: Bool
        var id: String { language }
    }

    let rows: [Row]
    /// Whether this Mac may start an edition (`EditionCastVerbs.mayAddLanguage`):
    /// the header's `+` and the Source row's Add Language… are hidden where
    /// it may not.
    var mayAddLanguage: Bool = false

    /// The window's marks — an edition row carries the dot while its To
    /// resolve holds anything (shell p4 Task 6).
    @Environment(\.resolvePresence) private var presence

    /// **Whether the Editions section is drawn**: while there is an edition
    /// to list, or while this Mac may add one — a book with no edition yet
    /// still has the header and its `+` (fix round I1: the first language
    /// must be reachable). Pure.
    static func drawsSection(rows: [Row], mayAddLanguage: Bool) -> Bool {
        !rows.isEmpty || mayAddLanguage
    }

    var body: some View {
        if Self.drawsSection(rows: rows, mayAddLanguage: mayAddLanguage) {
            Section {
                ForEach(rows) { row in
                    HStack(spacing: 6) {
                        Label(row.title, systemImage: "book.closed")
                            .lineLimit(1)
                            // The LABEL LEAF, before `.tag` (tripwire 9).
                            .treeTravelOnDoubleClick(.edition(language: row.language))
                        Spacer()
                        if row.isSource {
                            Text("Source")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        // A brief Claude proposed for this edition: a word in
                        // a capsule, never a second dot (fix round I4).
                        if ResolvePresence.proposalMark(.edition(row.language), in: presence) {
                            ProposedBriefBadge()
                        }
                        ResolvePresenceMark(ResolvePresence.rowMark(.edition(row.language), in: presence))
                    }
                    // Under the title, as Research's and the Palette's are.
                    .padding(.leading, ProjectRowLabel.childIndent)
                    .contentShape(Rectangle())
                    // The Source row offers a new edition beside it, as the
                    // header's `+` does (shell p4 Task 7).
                    .contextMenu {
                        if row.isSource && mayAddLanguage { addLanguageItem }
                        // A translated edition can be removed (closing round):
                        // hidden, its translations kept; asked first.
                        if Self.offersRemove(row, mayAddLanguage: mayAddLanguage) {
                            Button(EditionCastVerbs.removeEditionTitle) {
                                MaughamEvent.postRemoveEdition(row.language)
                            }
                            .help(EditionCastVerbs.removeEditionHelp)
                        }
                    }
                    .tag(TreeRowTag.subject(.edition(language: row.language)))
                    .id(BinderSubject.edition(language: row.language))
                }
            } header: {
                HStack {
                    // No chevron, so the text starts in the titles' column
                    // rather than the chevrons' (`TreeSectionColumn`).
                    Text("Editions")
                        .treeSectionTitle()
                        .padding(.leading, TreeSectionColumn.chevronlessHeaderInset)
                    Spacer()
                    // **Adding a language is something done to the list of
                    // editions** (shell p4 Task 7): the header's `+`, one
                    // press — a plain button, since it has one thing to do —
                    // its glyph where Research's menu draws its own
                    // (`TreeTopLevelAlignmentTests`).
                    if mayAddLanguage {
                        Button { MaughamEvent.postAddLanguage() } label: {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.borderless)
                        .fixedSize()
                        .padding(.trailing, Self.plusTrailing)
                        .help(EditionCastVerbs.addLanguageHelp)
                        .accessibilityLabel(EditionCastVerbs.addLanguageTitle)
                    }
                }
                .contentShape(Rectangle())
                .contextMenu {
                    if mayAddLanguage { addLanguageItem }
                }
            }
        }
    }

    /// **Whether a row's menu offers Remove Edition…**: a translated edition,
    /// where this Mac may add one (the same door, asked again at the act).
    /// Never the Source. Pure.
    static func offersRemove(_ row: Row, mayAddLanguage: Bool) -> Bool {
        mayAddLanguage && !row.isSource
    }

    /// The `+` button's trailing inset, so its glyph ends where Research's
    /// menu glyph does (measured, `TreeTopLevelAlignmentTests`).
    static let plusTrailing: CGFloat = 17

    /// The one Add Language… item: the window's sheet (`EditionWiring`).
    private var addLanguageItem: some View {
        Button(EditionCastVerbs.addLanguageTitle) { MaughamEvent.postAddLanguage() }
    }

    // MARK: - Which languages

    /// **The book's editions, source first**: the source language, then each
    /// language `EditionStatus.languageRows` reports, in its order — a
    /// translation file for a manuscript document or a table, or a stored
    /// translator (`EditionStatus.editionLanguages`). Empty until publishing
    /// is initialised or a translation exists.
    ///
    /// **What it reads**: one listing of the translations folder, the
    /// manifest, and the publish config — never a document. So a language
    /// known only from an open question (`EditionStatus`'s query union, which
    /// needs every document opened) is not listed until a file or a
    /// translator names it.
    ///
    /// **The source language is the publish config's `metadata.language`**,
    /// resolved with no imprint (`PublishImprint.sourceLanguage`, the one
    /// spelling) — the book's own tag, `en` where there is no config.
    @MainActor
    static func languages(store: ProjectStore) -> [String] {
        let byDoc = TranslationStore.languagesByDocId(in: store.url)
        let manuscript = EditionStatus.manuscriptDocumentIds(in: store.manifest)
        let tables = (store.manifest.figures ?? []).filter { $0.kind == .table }.map(\.id)
        let files = (manuscript + tables).reduce(into: Set<String>()) {
            $0.formUnion(byDoc[$1] ?? [])
        }
        let translated = EditionStatus.editionLanguages(
            files: files, queries: [],
            roles: EditionStatus.storedTranslatorLanguages(in: store.manifest),
            removed: store.manifest.removedEditions)
        let config = (try? PublishConfigStore.read(in: store.url)) ?? nil
        let source = PublishImprint.sourceLanguage(
            imprint: nil, in: config, pieceIDs: manuscript)
        let briefProposed = StatementProposalStore(projectURL: store.url).pendingAll().contains {
            if case .editionBrief = $0.kind { return true }
            return false
        }
        return languages(source: source,
                         publishingInitialised: PublishStarter.isInitialized(in: store.url),
                         translated: translated, briefProposed: briefProposed)
    }

    /// The fold, pure: the source first, then every other language in the
    /// order given, the source not repeated; nothing at all until publishing
    /// is initialised or another language exists.
    nonisolated static func languages(source: String, publishingInitialised: Bool,
                                      translated: [String],
                                      briefProposed: Bool = false) -> [String] {
        let others = translated.filter {
            $0.caseInsensitiveCompare(source) != .orderedSame
        }
        // A brief Claude proposed for an edition the book has not got lists
        // the Source, whose Brief offers to add it (fix round I1).
        guard publishingInitialised || briefProposed || !others.isEmpty else { return [] }
        return [source] + others
    }

    /// The rows, titled: a language's name in the writer's locale, else its
    /// tag.
    @MainActor
    static func rows(store: ProjectStore) -> [Row] {
        let languages = languages(store: store)
        return languages.enumerated().map { index, tag in
            Row(language: tag, title: title(forLanguage: tag), isSource: index == 0)
        }
    }

    /// An edition's title: its language's name in the writer's locale, else
    /// its tag. The tree's rows and the Book's Brief name an edition alike.
    nonisolated static func title(forLanguage tag: String) -> String {
        LanguageName.title(tag)
    }
}

/// The Editions rows' load key: the manifest's stamp and the translation
/// writes heard since the tree mounted.
struct EditionRowsKey: Hashable {
    let manifest: Date
    let translations: Int
    /// Whether publishing is initialised — initialising it on an older
    /// project stamps no manifest, and it is what brings the source row.
    var publishing: Bool = false
}

/// **A brief Claude proposed for this edition** (fix round I4): the desk's
/// "Proposed" word in its capsule, on the edition's row — words, so it can
/// never be read as the "something to resolve" dot beside it.
struct ProposedBriefBadge: View {
    static let title = "Proposed"
    static let label = "A proposed brief waits on its Brief"

    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Text(Self.title)
            .font(.caption2)
            .foregroundStyle(prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
            .fixedSize()
            .accessibilityElement()
            .accessibilityLabel(Self.label)
            .help(Self.label)
    }
}
