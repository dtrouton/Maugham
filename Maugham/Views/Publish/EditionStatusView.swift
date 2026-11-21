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
    /// Whether this Mac may change `item`'s publishing settings — what the
    /// tree's row menu offers Publishing… on (`PieceRowMenus.items`).
    let publishingOffered: (StructureItem, Bool) -> Bool
    let onOpen: (String) -> Void
    let onOpenPublishing: (String) -> Void

    @State private var loaded = EditionStatusView.Loaded()
    /// Translation writes and annotation changes heard while mounted — the
    /// halves of the key no file date carries.
    @State private var revisions = 0

    /// What the read is a function of: the edition, the manifest, the writes
    /// heard, the rounds ledger's and the config's modified times.
    struct Key: Equatable {
        let language: String
        let manifest: Date
        let revisions: Int
        let rounds: Date?
        let config: Date?
    }

    private var key: Key {
        Key(language: language, manifest: store.manifest.modified, revisions: revisions,
            rounds: Self.modified(TranslationRoundStore.fileURL(language: language, in: store.url)),
            config: DepartmentPaneHost.configModified(in: store.url))
    }

    var body: some View {
        EditionStatusView(structure: store.manifest.structure, isSource: isSource,
                          loaded: loaded, remembered: remembered, faces: faces,
                          keyboardRequest: keyboardRequest,
                          publishingOffered: { publishingOffered($0, loaded.publishingIsSetUp) },
                          onOpen: onOpen, onOpenPublishing: onOpenPublishing)
            .task(id: key) { await load() }
            .onProjectEvent(.maughamTranslationDidUpdate, url: store.url, window: window) { _ in
                revisions &+= 1
            }
            .onProjectEvent(.maughamAnnotationsChanged, url: store.url, window: window) { _ in
                revisions &+= 1
            }
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// **The one read per key.** The Source edition reads the config alone:
    /// it has nothing translated to count.
    private func load() async {
        let config = (try? PublishConfigStore.read(in: store.url)) ?? nil
        var next = EditionStatusView.Loaded()
        next.sections = config?.sections ?? [:]
        next.publishingIsSetUp = PublishStarter.isInitialized(in: store.url)
        let structure = store.manifest.structure
        guard !isSource else {
            next.rows = EditionStatusRows.rows(structure: structure, report: [], rounds: [:], trends: [:])
            next.isLoaded = true
            loaded = next
            return
        }
        let report = await EditionStatus.documentRows(
            documentIds: EditionStatus.manuscriptDocumentIds(in: store.manifest),
            store: store, projectURL: store.url)
        guard !Task.isCancelled else { return }
        let rounds = TranslationRoundStore(projectURL: store.url)
        next.rows = EditionStatusRows.rows(
            structure: structure,
            report: report.rows.filter { $0.language.caseInsensitiveCompare(language) == .orderedSame },
            rounds: rounds.latestFinishedByPiece(language: language),
            trends: rounds.trendsByPiece(language: language))
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
        var isLoaded = false
    }

    let structure: [StructureItem]
    let isSource: Bool
    let loaded: Loaded
    let remembered: Binding<String?>
    let faces: BinderSubject
    let keyboardRequest: Int
    let publishingOffered: (StructureItem) -> Bool
    let onOpen: (String) -> Void
    let onOpenPublishing: (String) -> Void

    @FocusState private var holdsTheKeys: Bool

    // MARK: - Columns

    static let minimumTitleColumnWidth: CGFloat = 110
    static let translationColumnWidth: CGFloat = 76
    static let roundColumnWidth: CGFloat = 84
    static let questionsColumnWidth: CGFloat = 34
    static let changesColumnWidth: CGFloat = 34
    static let trendColumnWidth: CGFloat = 48
    static let publishingColumnWidth: CGFloat = 72
    private static let horizontalPadding: CGFloat = 10
    private static let groupIndent: CGFloat = 14

    /// The columns beside the piece's: the publishing column alone for the
    /// Source edition.
    static func fixedWidth(isSource: Bool) -> CGFloat {
        isSource ? publishingColumnWidth
            : translationColumnWidth + roundColumnWidth + questionsColumnWidth
                + changesColumnWidth + trendColumnWidth + publishingColumnWidth
    }

    /// **The width the grid needs** — at most the centre column's floor
    /// (`ProjectWindow.centreColumnFloor`), so the edition's Status needs no
    /// horizontal scroll at the window's minimum width.
    static func intrinsicWidth(isSource: Bool) -> CGFloat {
        fixedWidth(isSource: isSource) + minimumTitleColumnWidth
    }

    // MARK: - Body

    var body: some View {
        let layout = ReviewBoardRows.derive(structure: structure)
        let ids = layout.filter { $0.kind == .piece }.map(\.id)
        let current = ReviewBoardKeys.current(remembered: remembered.wrappedValue, faces: faces, in: ids)
        let byId = Dictionary(loaded.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let unreadable = Set(loaded.unreadable.map(\.documentId))
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(EditionStatusRows.notices(loaded.unreadable).enumerated()), id: \.offset) { _, notice in
                PublishNoticeLine(headline: notice.headline, detail: notice.detail)
                    .padding(.horizontal, 10)
            }
            if ids.isEmpty {
                ContentUnavailableView {
                    Label("No chapters yet", systemImage: "checklist")
                } description: {
                    Text("Add chapters and Status shows where each one stands in this edition.")
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
            let titleWidth = width - Self.fixedWidth(isSource: isSource)
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    headers(titleWidth: titleWidth)
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
                                                 titleWidth: titleWidth, width: width)
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

    private func headers(titleWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text("Piece")
                .padding(.horizontal, Self.horizontalPadding)
                .frame(width: titleWidth, alignment: .leading)
            if !isSource {
                Text("Translation").frame(width: Self.translationColumnWidth, alignment: .leading)
                Text("Round").frame(width: Self.roundColumnWidth, alignment: .leading)
                headerSymbol("questionmark.bubble", "Open questions", width: Self.questionsColumnWidth)
                headerSymbol("arrow.triangle.swap", "Changes to look at", width: Self.changesColumnWidth)
                Text("Trend").frame(width: Self.trendColumnWidth, alignment: .leading)
            }
            Text("Publishing").frame(width: Self.publishingColumnWidth, alignment: .leading)
        }
        .lineLimit(1)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.vertical, 5)
    }

    private func headerSymbol(_ symbol: String, _ name: String, width: CGFloat) -> some View {
        Image(systemName: symbol)
            .frame(width: width)
            .help(name)
            .accessibilityLabel(name)
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
                          titleWidth: CGFloat, width: CGFloat) -> some View {
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
                        cell(EditionStatusRows.translation(row, unreadable: isUnreadable),
                             width: Self.translationColumnWidth)
                        cell(EditionStatusRows.round(row), width: Self.roundColumnWidth)
                        cell(EditionStatusRows.questions(row), width: Self.questionsColumnWidth,
                             alignment: .center)
                        cell(EditionStatusRows.changes(row), width: Self.changesColumnWidth,
                             alignment: .center)
                        cell(EditionStatusRows.trend(row), width: Self.trendColumnWidth)
                    }
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(ReviewBoardRowButtonStyle())
            .help(isSource ? "Open \(item.title)" : "Open \(item.title) in this edition\u{2019}s language")
            .accessibilityLabel(item.title)
            publishingCell(item)
        }
        .frame(width: width, height: ReviewBoardPane.pieceRowHeight, alignment: .leading)
        .id(item.id)
    }

    private func cell(_ cell: EditionStatusRows.Cell, width: CGFloat,
                      alignment: Alignment = .leading) -> some View {
        Text(cell.text)
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
    private func publishingCell(_ item: StructureItem) -> some View {
        let cell = EditionStatusRows.publishing(loaded.sections[item.id])
        if publishingOffered(item) {
            Button {
                onOpenPublishing(item.id)
            } label: {
                Text(cell.text)
                    .font(.caption)
                    .lineLimit(1)
                    .frame(width: Self.publishingColumnWidth, alignment: .leading)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ReviewBoardRowButtonStyle())
            .help(cell.help + " \u{2014} change in Publishing\u{2026}")
            .accessibilityLabel("Publishing for \(item.title): \(cell.help)")
        } else {
            Text(cell.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: Self.publishingColumnWidth, alignment: .leading)
                .help(cell.help)
        }
    }
}
