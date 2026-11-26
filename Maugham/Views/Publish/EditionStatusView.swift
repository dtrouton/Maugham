import SwiftUI
import AppKit
import MaughamCore

/// **An edition's Status** (shell p4 Task 5; the design's "The centre, by
/// subject"): the book's pieces down the side, and across each, this
/// edition's translation, its latest round, open questions, changes to look
/// at, a short trend and its publishing settings. The Source edition's Status
/// has the publishing column only (a call recorded in the plan).
///
/// It is the Book's Status for an edition, and feels like it: the same row
/// style (`ReviewBoardRowButtonStyle`), the same keys (`StatusKeyHolder`
/// over `ReviewBoardKeys`), the same keep-your-place memory. A click on a
/// piece opens it read in this edition's language (`EditionStatusRows
/// .opening`); a group heading is a heading.
///
/// **The host reads; the view draws values** (tripwire 4). One
/// `EditionStatus.documentRows` read, one rounds ledger read and one config
/// read per key, in `.task`; a row does dictionary lookups.
struct EditionStatusHost: View {
    let store: ProjectStore
    let language: String
    let isSource: Bool
    let window: NSWindow?
    let remembered: Binding<String?>
    let faces: BinderSubject
    let keyboardRequest: Int
    /// The book's open questions, from the window's presence read
    /// (`BinderTreeSectionsState.bookReading`) — so no chapter is loaded.
    let reading: ResolvePresence.BookReading
    /// Whether this Mac may change `item`'s publishing settings — what the
    /// tree's row menu offers Publishing… on (`PieceRowMenus.items`). Asked
    /// once per read, never per row.
    let publishingOffered: (StructureItem, Bool) -> Bool
    /// A row opened: the piece, and whether it has anything translated to
    /// read (`EditionStatusRows.hasTranslation`).
    let onOpen: (String, Bool) -> Void
    let onOpenPublishing: (String) -> Void

    @State private var loaded = EditionStatusView.Loaded()
    /// Translation writes and annotation changes heard while mounted — the
    /// halves of the key no file date carries.
    @State private var revisions = 0

    /// What the read is a function of: the edition, the manifest, the writes
    /// heard, the presence read's questions, and the modified times of the
    /// rounds ledger, the config and the translations folder (a peer's file).
    struct Key: Equatable {
        let language: String
        let manifest: Date
        let revisions: Int
        let rounds: Date?
        let config: Date?
        let translations: Date?
        let reading: ResolvePresence.BookReading
    }

    private var key: Key {
        Key(language: language, manifest: store.manifest.modified, revisions: revisions,
            rounds: Self.modified(TranslationRoundStore.fileURL(language: language, in: store.url)),
            config: PublishImprint.configModified(in: store.url),
            translations: Self.modified(TranslationStore.directoryURL(in: store.url)),
            reading: reading)
    }

    /// How long a burst of changes waits before its one read.
    static let coalesce: Duration = .milliseconds(250)

    var body: some View {
        EditionStatusView(structure: store.manifest.structure, noun: PieceNoun.of(nil, in: store.manifest),
                          isSource: isSource,
                          loaded: loaded, remembered: remembered, faces: faces,
                          keyboardRequest: keyboardRequest,
                          publishingOffered: { loaded.publishingOffered.contains($0.id) },
                          onOpen: { id in
                              onOpen(id, EditionStatusRows.hasTranslation(
                                loaded.rows.first { $0.id == id }))
                          },
                          onOpenPublishing: onOpenPublishing)
            .task(id: key) { await load() }
            .onProjectEvent(.maughamTranslationDidUpdate, url: store.url, window: window) { _ in
                revisions &+= 1
            }
            .onProjectEvent(.maughamAnnotationsChanged, url: store.url, window: window) { _ in
                revisions &+= 1
            }
            // A change settled from To resolve or the report moves the count.
            .onProjectEvent(.maughamTranslationRoundChanged, url: store.url, window: window) { _ in
                revisions &+= 1
            }
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// **The one read per key.** The Source edition reads the config alone:
    /// it has nothing translated to count.
    private func load() async {
        // A burst (a round's ingests, a sync) settles first: one read, not one
        // per event. The first read does not wait.
        if loaded.isLoaded {
            try? await Task.sleep(for: Self.coalesce)
            guard !Task.isCancelled else { return }
        }
        let config = (try? PublishConfigStore.read(in: store.url)) ?? nil
        var next = EditionStatusView.Loaded()
        next.sections = config?.sections ?? [:]
        next.publishingIsSetUp = PublishStarter.isInitialized(in: store.url)
        let structure = store.manifest.structure
        next.publishingOffered = Set(TreeWalk.collect(in: structure, where: { $0.type == .document })
            .filter { publishingOffered($0, next.publishingIsSetUp) }.map(\.id))
        guard !isSource else {
            next.rows = EditionStatusRows.rows(structure: structure, report: [], rounds: [:], trends: [:])
            next.isLoaded = true
            loaded = next
            return
        }
        // This edition's language only; its questions from the presence read;
        // a walk that yields per chapter and stops when the key moves on.
        let report = await EditionStatus.documentRows(
            documentIds: EditionStatus.manuscriptDocumentIds(in: store.manifest),
            store: store, projectURL: store.url,
            options: .init(openQuestions: .init(byDoc: reading.openQuestions,
                                                unreadable: reading.unreadable),
                           languages: [language], yieldsAndStops: true))
        guard !Task.isCancelled else { return }
        // The ledger: ONE decode, off the main actor (fix round 2, N5).
        let rounds = TranslationRoundStore(projectURL: store.url)
        let language = language
        let ledger = await Task.detached(priority: .userInitiated) {
            rounds.latestFinishedAndTrendsByPiece(language: language)
        }.value
        guard !Task.isCancelled else { return }
        next.rows = EditionStatusRows.rows(
            structure: structure,
            report: report.rows.filter { $0.language.caseInsensitiveCompare(language) == .orderedSame },
            rounds: ledger.latest, trends: ledger.trends)
        next.unreadable = report.unreadable
        next.isLoaded = true
        loaded = next
    }
}

/// The drawing half: values in.
struct EditionStatusView: View {

    /// What the host read, as one value.
    struct Loaded: Equatable {
        var rows: [EditionStatusRows.Row] = []
        var unreadable: [EditionStatus.UnreadableDocument] = []
        var sections: [String: PublishConfig.Section] = [:]
        var publishingIsSetUp = false
        /// The pieces whose Publishing… this Mac offers, asked once per read.
        var publishingOffered: Set<String> = []
        var isLoaded = false
    }

    let structure: [StructureItem]
    /// What the project calls a piece (`PieceNoun`), for the empty grid.
    let noun: PieceNoun
    let isSource: Bool
    let loaded: Loaded
    let remembered: Binding<String?>
    let faces: BinderSubject
    let keyboardRequest: Int
    let publishingOffered: (StructureItem) -> Bool
    let onOpen: (String) -> Void
    let onOpenPublishing: (String) -> Void

    @FocusState private var holdsTheKeys: Bool

    /// The empty edition, in the project's word for a piece.
    static func emptyDescription(_ noun: PieceNoun) -> String {
        "Add \(noun.plural) and Status shows where each one stands in this edition."
    }

    // MARK: - Columns

    /// **The columns, as a pure function of the width the grid has**: the
    /// long wording ("In contents · right page", "3 missing · 5 stale",
    /// "2 questions", worded headers) wherever it fits, the terse form only
    /// near the centre's floor.
    struct Columns: Equatable {
        let wide: Bool
        let translation: CGFloat
        let round: CGFloat
        let questions: CGFloat
        let changes: CGFloat
        let trend: CGFloat
        let publishing: CGFloat

        static let narrow = Columns(wide: false, translation: 76, round: 84, questions: 34,
                                    changes: 34, trend: 48, publishing: 72)
        static let long = Columns(wide: true, translation: 120, round: 150, questions: 80,
                                  changes: 80, trend: 80, publishing: 140)

        func fixedWidth(isSource: Bool) -> CGFloat {
            isSource ? publishing : translation + round + questions + changes + trend + publishing
        }
    }

    /// The Source edition's one line to the Book's Status.
    static let bookStatusLine = "Stage, passes, notes and to-dos are in the Book\u{2019}s Status"
    static let bookStatusHelp = "Show the Book\u{2019}s Status"

    static let minimumTitleColumnWidth: CGFloat = 110
    /// The piece column's width before the long wording takes the slack.
    static let comfortableTitleColumnWidth: CGFloat = 130
    private static let horizontalPadding: CGFloat = 10
    private static let groupIndent: CGFloat = 14

    /// The long columns where the width holds them and a comfortable title;
    /// else the terse ones.
    static func columns(width: CGFloat, isSource: Bool) -> Columns {
        width >= Columns.long.fixedWidth(isSource: isSource) + comfortableTitleColumnWidth
            ? .long : .narrow
    }

    /// **The width the grid needs** — the terse columns at the floor, at most
    /// the centre column's (`ProjectWindow.centreColumnFloor`), so the
    /// edition's Status needs no horizontal scroll at the window's minimum.
    static func intrinsicWidth(isSource: Bool) -> CGFloat {
        Columns.narrow.fixedWidth(isSource: isSource) + minimumTitleColumnWidth
    }

    // MARK: - Body

    var body: some View {
        let layout = ReviewBoardRows.derive(structure: structure)
        let ids = layout.filter { $0.kind == .piece }.map(\.id)
        let current = ReviewBoardKeys.current(remembered: remembered.wrappedValue, faces: faces, in: ids)
        let byId = Dictionary(loaded.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let unreadable = Set(loaded.unreadable.map(\.documentId))
        return VStack(alignment: .leading, spacing: 6) {
            // The Source's Status is publishing only; the rest is the Book's
            // (owner's answer 11, 2026-11-22): one quiet line that goes there.
            if isSource {
                Button(Self.bookStatusLine) { CentreViewSwitch.go(to: .bookStatus) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help(Self.bookStatusHelp)
                    .padding(.horizontal, Self.horizontalPadding)
                    .padding(.top, 6)
                    .accessibilityIdentifier("editionStatus.bookStatus")
            }
            ForEach(Array(EditionStatusRows.notices(loaded.unreadable).enumerated()), id: \.offset) { _, notice in
                PublishNoticeLine(headline: notice.headline, detail: notice.detail)
                    .padding(.horizontal, 10)
            }
            if ids.isEmpty {
                ContentUnavailableView {
                    Label(ReviewBoardPane.emptyTitle(noun), systemImage: "checklist")
                } description: {
                    Text(Self.emptyDescription(noun))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                grid(layout: layout, byId: byId, unreadable: unreadable, current: current)
            }
        }
        .padding(.top, loaded.unreadable.isEmpty ? 0 : 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            StatusKeyHolder(ids: ids, current: current, remembered: remembered,
                            keyboardRequest: keyboardRequest, onOpen: onOpen,
                            holdsTheKeys: $holdsTheKeys)
        }
    }

    private func grid(layout: [ReviewBoardRows.Row], byId: [String: EditionStatusRows.Row],
                      unreadable: Set<String>, current: String?) -> some View {
        GeometryReader { proxy in
            let width = max(Self.intrinsicWidth(isSource: isSource), proxy.size.width)
            let columns = Self.columns(width: width, isSource: isSource)
            let titleWidth = width - columns.fixedWidth(isSource: isSource)
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    headers(columns, titleWidth: titleWidth)
                    Divider()
                    ScrollViewReader { reader in
                        ScrollView(.vertical) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(layout) { row in
                                    switch row.kind {
                                    case .group(let depth):
                                        heading(row.item, depth: depth, width: width)
                                    case .piece:
                                        pieceRow(row.item, row: byId[row.id],
                                                 isUnreadable: unreadable.contains(row.id),
                                                 columns: columns, titleWidth: titleWidth, width: width)
                                            .background(fill(isCurrent: row.id == current))
                                    case .reference:
                                        EmptyView()
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .onAppear {
                            guard let current else { return }
                            DispatchQueue.main.async { reader.scrollTo(current, anchor: .center) }
                        }
                        .onChange(of: current) { _, next in
                            if let next { reader.scrollTo(next) }
                        }
                    }
                }
                .frame(width: width, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func fill(isCurrent: Bool) -> some View {
        if isCurrent {
            Color.accentColor.opacity(holdsTheKeys ? 0.2 : 0.1)
        } else {
            Color.clear
        }
    }

    private func headers(_ columns: Columns, titleWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text("Piece")
                .padding(.horizontal, Self.horizontalPadding)
                .frame(width: titleWidth, alignment: .leading)
            if !isSource {
                Text("Translation").frame(width: columns.translation, alignment: .leading)
                Text(columns.wide ? "Latest round" : "Round").frame(width: columns.round, alignment: .leading)
                header("Questions", symbol: "questionmark.bubble", "Open questions",
                       wide: columns.wide, width: columns.questions)
                header(TranslationVocabulary.toLookAt, symbol: "arrow.triangle.swap",
                       TranslationVocabulary.toLookAtColumnName,
                       wide: columns.wide, width: columns.changes)
                Text(columns.wide ? "Notes per round" : "Trend").frame(width: columns.trend, alignment: .leading)
            }
            Text("Publishing").frame(width: columns.publishing, alignment: .leading)
        }
        .lineLimit(1)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.vertical, 5)
    }

    /// A header in words where it fits; a symbol, named in its help, at the floor.
    @ViewBuilder
    private func header(_ word: String, symbol: String, _ name: String, wide: Bool,
                        width: CGFloat) -> some View {
        if wide {
            Text(word).frame(width: width, alignment: .leading).help(name)
        } else {
            Image(systemName: symbol)
                .frame(width: width)
                .help(name)
                .accessibilityLabel(name)
        }
    }

    /// A Part's heading: where the writer is in the book. A heading, not a
    /// control — opening a Part would leave the edition.
    private func heading(_ item: StructureItem, depth: Int, width: CGFloat) -> some View {
        Text(item.title)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .padding(.leading, Self.horizontalPadding + Self.groupIndent * CGFloat(depth))
            .padding(.trailing, Self.horizontalPadding)
            .padding(.top, 10)
            .padding(.bottom, 3)
            .frame(width: width, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    private func pieceRow(_ item: StructureItem, row: EditionStatusRows.Row?, isUnreadable: Bool,
                          columns: Columns, titleWidth: CGFloat, width: CGFloat) -> some View {
        let row = row ?? EditionStatusRows.Row(piece: item, translation: nil, latestRound: nil,
                                               changesToLookAt: 0, trend: [])
        return HStack(spacing: 0) {
            Button {
                onOpen(item.id)
            } label: {
                HStack(spacing: 0) {
                    Text(item.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, Self.horizontalPadding)
                        .frame(width: titleWidth, alignment: .leading)
                    if !isSource {
                        let wide = columns.wide
                        cell(EditionStatusRows.translation(row, unreadable: isUnreadable),
                             wide: wide, width: columns.translation)
                        cell(EditionStatusRows.round(row), wide: wide, width: columns.round)
                        cell(EditionStatusRows.questions(row), wide: wide, width: columns.questions,
                             alignment: wide ? .leading : .center)
                        cell(EditionStatusRows.changes(row), wide: wide, width: columns.changes,
                             alignment: wide ? .leading : .center)
                        cell(EditionStatusRows.trend(row), wide: wide, width: columns.trend)
                    }
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(ReviewBoardRowButtonStyle())
            .help(isSource ? "Open \(item.title)" : "Open \(item.title) in this edition\u{2019}s language")
            // Every cell's whole sentence: they sit inside this one button.
            .accessibilityLabel(EditionStatusRows.accessibilityLabel(
                row, unreadable: isUnreadable, isSource: isSource))
            publishingCell(item, columns: columns)
        }
        .frame(width: width, height: ReviewBoardPane.pieceRowHeight, alignment: .leading)
        .id(item.id)
    }

    private func cell(_ cell: EditionStatusRows.Cell, wide: Bool, width: CGFloat,
                      alignment: Alignment = .leading) -> some View {
        Text(cell.wording(wide: wide))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: width, alignment: alignment)
            .help(cell.help)
    }

    /// **The piece's publishing settings**: a control that opens Publishing…
    /// where the row menu would offer it, plain text elsewhere.
    @ViewBuilder
    private func publishingCell(_ item: StructureItem, columns: Columns) -> some View {
        let cell = EditionStatusRows.publishing(loaded.sections[item.id])
        let text = cell.wording(wide: columns.wide)
        if publishingOffered(item) {
            Button {
                onOpenPublishing(item.id)
            } label: {
                Text(text)
                    .font(.caption)
                    .lineLimit(1)
                    .frame(width: columns.publishing, alignment: .leading)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ReviewBoardRowButtonStyle())
            .help(cell.help + " \u{2014} change in Publishing\u{2026}")
            .accessibilityLabel("Publishing for \(item.title): \(cell.help)")
        } else {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: columns.publishing, alignment: .leading)
                .help(cell.help)
        }
    }
}
