import SwiftUI
import MaughamCore

extension BriefDecision.Origin {
    /// The statement a decision made here lives in — the address its row's
    /// verbs act on.
    var statement: (kind: Statement.Kind, scope: Statement.Scope) {
        switch self {
        case .book: return (.intent, .project)
        case .piece(let docId): return (.intent, .document(docId))
        case .lessons: return (.lessons, .project)
        case .firstReader: return (.firstReader, .project)
        case .edition(let language): return (.editionBrief(language), .project)
        }
    }
}

/// **The Book's Brief** (shell plan 3 Task 5; spec "Brief"): the book's
/// intent (Going for, at `.project` — no check reads the Book, so no mark),
/// then every standing decision in the book under one filter, then the three
/// long statements that pull up, then what Claude has read of the book.
///
/// A screenplay never draws this: its Book IS its one script, and
/// `BriefScope.of` answers `.piece` for it.
///
/// **Read once per key, never per row** (tripwire 4): the decisions arrive
/// grouped by origin in `BriefContents.bookGroups`, built in `BriefPane.read`
/// inside `.task`. The filter only picks groups; each group draws its newest
/// `BriefDecisions.showing` and folds the rest, inside a `LazyVStack`.
struct BriefBookView: View {
    @Bindable var store: ProjectStore
    let documentStore: DocumentStore
    let contents: BriefContents
    let bible: BibleStore?
    let world: DeclaredWorldStore?
    let centreItem: CentreItem?
    let onOpenInCentre: (CentreItem) -> Void
    let onPullUp: (PulledUp) -> Void
    let onOpenBrief: (BinderSubject) -> Void

    /// The filter: nil is All. Remembered for the life of the view.
    @State private var filter: BriefDecision.Origin?
    @State private var showsReadings = false
    /// Where a Confirm filed (shell plan 3 Task 6).
    @State private var filedNotice: FiledNotice.Filing?

    static let allTitle = "All"
    static let bookTitle = "The book"
    static let lessonsTitle = "What I've Learned"
    static let firstReaderTitle = "First Reader"
    static let visualLanguageTitle = "Visual Language"

    // MARK: - Decided, grouped (pure)

    /// One origin's standing decisions: newest first to draw, and the
    /// statement's rulings in FILE order (the ruling verbs' index space).
    struct Group: Equatable, Identifiable {
        let origin: BriefDecision.Origin
        let title: String
        let kind: Statement.Kind
        let scope: Statement.Scope
        let decisions: [Ruling]
        let fileOrder: [Ruling]
        var id: String { origin.key }
    }

    /// One item of the filter menu; a nil origin is All.
    struct FilterItem: Hashable, Identifiable {
        let origin: BriefDecision.Origin?
        let title: String
        var id: String { origin?.key ?? "all" }
    }

    /// Where a decision was made, as the writer names it.
    static func title(of origin: BriefDecision.Origin, structure: [StructureItem]) -> String {
        switch origin {
        case .book: return bookTitle
        case .piece(let docId): return TreeWalk.find(id: docId, in: structure)?.title ?? docId
        case .lessons: return lessonsTitle
        case .firstReader: return firstReaderTitle
        case .edition(let language):
            return TreeEditionRows.title(forLanguage: language) + " edition"
        }
    }

    /// The decisions grouped by origin, in the filter's order
    /// (`BriefDecisions.origins`: the book, pieces in manuscript order, the
    /// lessons ledger, the first reader, editions by tag), each newest first.
    /// An origin with no standing decision has no group. `.task` only — it
    /// asks `fileOrder` once per origin.
    static func groups(_ decisions: [BriefDecision], structure: [StructureItem],
                       fileOrder: (BriefDecision.Origin) -> [Ruling]) -> [Group] {
        let byOrigin = Dictionary(grouping: decisions, by: \.origin)
        return BriefDecisions.origins(of: decisions, structure: structure).map { origin in
            let statement = origin.statement
            return Group(origin: origin, title: title(of: origin, structure: structure),
                         kind: statement.kind, scope: statement.scope,
                         decisions: BriefDecisions.newestFirst((byOrigin[origin] ?? []).map(\.ruling)),
                         fileOrder: fileOrder(origin))
        }
    }

    /// The filter's items: All, then each origin that has a decision. Empty
    /// when nothing is decided — then there is no filter and no heading.
    static func filterItems(_ groups: [Group]) -> [FilterItem] {
        guard !groups.isEmpty else { return [] }
        return [FilterItem(origin: nil, title: allTitle)]
            + groups.map { FilterItem(origin: $0.origin, title: $0.title) }
    }

    /// The groups the filter shows. A remembered origin that no longer has a
    /// decision shows everything rather than nothing.
    static func shown(_ groups: [Group], filter: BriefDecision.Origin?) -> [Group] {
        guard let filter, groups.contains(where: { $0.origin == filter }) else { return groups }
        return groups.filter { $0.origin == filter }
    }

    /// Where a decision row's caption goes on a click: a piece's to that
    /// piece's Brief (the faces move to it); every other origin is named only.
    static func opensBrief(_ origin: BriefDecision.Origin) -> BinderSubject? {
        if case .piece(let docId) = origin { return .item(docId) }
        return nil
    }

    // MARK: - The lines that pull up (pure)

    struct PullUpLine: Equatable, Identifiable {
        let title: String
        let request: PullUpRequest
        var id: String { request.rawValue }
    }

    /// The Book's three long statements, in the order Brief lists them.
    static let pullUpLines = [
        PullUpLine(title: lessonsTitle, request: .lessons),
        PullUpLine(title: firstReaderTitle, request: .firstReader),
        PullUpLine(title: visualLanguageTitle, request: .visualLanguage),
    ]

    /// What a line pulls up: Task 3's one answer, asked as the Book's Brief
    /// asks it (the faces are the Book).
    static func pulledUp(_ request: PullUpRequest, structure: [StructureItem]) -> PulledUp? {
        RightColumnContent.pulledUp(for: request, subject: .book, structure: structure)
    }

    // MARK: - What would not read (final wave, I2)

    /// **The statements this read could not read, as the writer names their
    /// origin** (RULING-54): the Book, or the piece. Pure.
    static func unreadableTitles(snapshot: BriefSnapshot, statements: [Statement],
                                 structure: [StructureItem]) -> [String] {
        snapshot.unreadable.compactMap { id in
            guard let statement = statements.first(where: { $0.id == id }) else { return nil }
            switch statement.scope {
            case .project: return bookTitle
            case .document(let docId): return TreeWalk.find(id: docId, in: structure)?.title ?? docId
            case .unknown: return ArtifactIndex.statementTitle(statement, documentTitle: { _ in nil })
            }
        }
    }

    /// Decided's one line naming what would not read; nil when everything read.
    static func unreadableLine(titles: [String]) -> String? {
        guard !titles.isEmpty else { return nil }
        return "Decisions that can\u{2019}t be read: \(titles.joined(separator: ", "))."
    }

    // MARK: - The view

    private var posture: Posture {
        documentStore.posture(forDocId: StatementEditorHost.postureDocId(
            kind: .intent, scope: .project, statements: store.manifest.statements))
    }

    var body: some View {
        let posture = self.posture
        VStack(alignment: .leading, spacing: 14) {
            GoingForView(
                store: store, documentStore: documentStore, scope: .project,
                isRead: contents.isRead, essay: contents.snapshot.intentEssay,
                // A check reads a piece, never the Book: nothing to mark.
                marks: [],
                mayEdit: StatementSurfaceVerbs.offered(under: posture),
                inTheCentre: ProjectWindow.statementIsInTheCentre(
                    kind: .intent, scope: .project, centreItem: centreItem),
                isUnreadable: BriefPane.statementIsUnreadable(
                    kind: .intent, scope: .project, snapshot: contents.snapshot,
                    statements: store.manifest.statements),
                posture: posture,
                onOpenInCentre: { onOpenInCentre(.statement(kind: .intent, scope: .project)) },
                onShowStrain: { _ in })
            decided
            BriefPullUpLines(store: store, lines: Self.pullUpLines, onPullUp: onPullUp)
            readings(posture)
            // The Book's foot: History alone — the Book has no row-menu
            // details (parity with what its Brief showed before the foot).
            BriefFootView(parts: [.history(.projectHistory)], openSheet: nil, onPullUp: onPullUp)
        }
    }

    @ViewBuilder
    private var decided: some View {
        let groups = contents.bookGroups
        let items = Self.filterItems(groups)
        let unreadableLine = Self.unreadableLine(titles: Self.unreadableTitles(
            snapshot: contents.snapshot, statements: store.manifest.statements,
            structure: store.manifest.structure))
        if !items.isEmpty || unreadableLine != nil {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    BriefPane.sectionHeading(BriefDecidedSection.heading)
                    Spacer(minLength: 0)
                    if !items.isEmpty { filterMenu(items) }
                }
                if let unreadableLine {
                    Text(unreadableLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Self.shown(groups, filter: filter)) { group in
                        BriefDecidedSection(
                            fileOrder: group.fileOrder, decisions: group.decisions,
                            kind: group.kind, scope: group.scope, store: store, world: world,
                            posture: posture(of: group), liveParagraphIds: nil,
                            showsHeading: false,
                            origin: RulingOrigin(title: group.title,
                                                 open: Self.opensBrief(group.origin).map { subject in
                                                     { onOpenBrief(subject) }
                                                 }))
                    }
                }
            }
        }
    }

    private func filterMenu(_ items: [FilterItem]) -> some View {
        let current = items.first { $0.origin == filter && filter != nil } ?? items[0]
        return Menu {
            ForEach(items) { item in
                Button(item.title) { filter = item.origin }
            }
        } label: {
            Text(current.title)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
        .font(.caption)
        .frame(maxWidth: 150, alignment: .trailing)
        .fixedSize(horizontal: false, vertical: true)
        .help("Show the decisions made in one place")
        .accessibilityIdentifier("brief.decidedFilter")
    }

    /// Each group's own statement's posture — per group, never per row.
    private func posture(of group: Group) -> Posture {
        documentStore.posture(forDocId: StatementEditorHost.postureDocId(
            kind: group.kind, scope: group.scope, statements: store.manifest.statements))
    }

    @ViewBuilder
    private func readings(_ posture: Posture) -> some View {
        if let count = BriefPane.quietLines(contents.snapshot).readings, let bible {
            VStack(alignment: .leading, spacing: 6) {
                BriefPane.disclosure("\(BriefPieceView.readingsTitle) (\(count))", isOpen: $showsReadings)
                if showsReadings {
                    BibleStratumView(
                        facts: contents.facts, scope: .project, store: store,
                        bible: bible, world: world, posture: posture,
                        onFiled: { destination in
                            filedNotice = FiledNotice.after(
                                .filed(FiledUnder.filing(destination, faces: .project, store: store)),
                                current: filedNotice)
                        })
                }
            }
        }
        if filedNotice != nil {
            FiledNotice(filing: $filedNotice, onOpenBrief: onOpenBrief)
        }
    }
}

/// **Lines that pull a long statement up beside the centre** — the Book's
/// three, an edition's Visual Language. Each asks `BriefBookView.pulledUp`
/// (Task 3's `RightColumnContent.pulledUp`) and hands the answer to
/// `onPullUp`; the pulled-up view itself is Task 7's.
///
/// Visual Language carries the dot the old picker's segment carried while a
/// visual-language proposal waits (`StatementProposalStore`), read in `.task`
/// and again on `.maughamStatementProposalsChanged` — once for the lines,
/// never per line.
struct BriefPullUpLines: View {
    let store: ProjectStore
    let lines: [BriefBookView.PullUpLine]
    let onPullUp: (PulledUp) -> Void

    @State private var proposed = false
    @State private var reloads = 0
    @State private var window: NSWindow?

    static let proposedHelp = "Claude proposed a visual language — pull it up to adopt or discard"

    /// Whether a line shows the proposal dot. Pure.
    static func showsDot(_ request: PullUpRequest, visualLanguageProposed: Bool) -> Bool {
        request == .visualLanguage && visualLanguageProposed
    }

    /// The slot read: a visual-language proposal waits. `.task` only.
    static func visualLanguageProposed(projectURL: URL) -> Bool {
        StatementProposalStore(projectURL: projectURL).pending(for: .visualLanguage) != nil
    }

    private struct TaskKey: Equatable {
        let reloads: Int
        /// A post that lands before the window resolves is dropped by the
        /// receive helper; re-read once it does (`VisualLanguageProposalModifier`).
        let windowResolved: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(lines) { line in
                Button {
                    if let item = BriefBookView.pulledUp(line.request, structure: store.manifest.structure) {
                        onPullUp(item)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "pin")
                            .font(.caption2)
                        Text(line.title)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if Self.showsDot(line.request, visualLanguageProposed: proposed) {
                            UnreadDot()
                                .accessibilityLabel("Proposed")
                                .help(Self.proposedHelp)
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Pull up \(line.title) beside the centre")
            }
        }
        .task(id: TaskKey(reloads: reloads, windowResolved: window != nil)) {
            if lines.contains(where: { $0.request == .visualLanguage }) {
                proposed = Self.visualLanguageProposed(projectURL: store.url)
            }
        }
        .onProjectEvent(.maughamStatementProposalsChanged, url: store.url, window: window) { _ in
            reloads += 1
        }
        .background(WindowAccessor(window: $window))
    }
}
