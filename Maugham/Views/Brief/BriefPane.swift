import SwiftUI
import MaughamCore

/// Everything a Brief draws, read once per refresh in `.task`, never in a
/// body (tripwire 4).
struct BriefContents: Equatable {
    var snapshot: BriefSnapshot
    /// The latest check's marks on the piece's essay — EMPTY unless
    /// `ClauseMarks.applies` (the intent is the text the check read).
    var marks: [ClauseMark] = []
    /// docId → its intent's rulings in FILE order (the ruling verbs' index
    /// space; `BriefDecidedSection`).
    var fileOrder: [String: [Ruling]] = [:]
    /// The piece's live paragraph ids, for a directive's orphan verdict; nil
    /// is unknown (no orphan is manufactured).
    var liveParagraphIds: Set<String>? = nil
    /// Claude's unconfirmed readings for the piece.
    var facts: [BibleFact] = []
    /// False for the placeholder drawn before the first read lands: Going
    /// for decides its face only over a real read, or every piece would open
    /// on the editor for a frame and keep it.
    var isRead = false

    static func empty(_ scope: BriefScope) -> BriefContents { BriefContents(snapshot: .empty(scope)) }
}

/// What Brief offers under a posture — hidden, never disabled (tripwires 47,
/// 51). Asked of the piece intent's OWN posture: the line is shown beside the
/// intent and follows the same answer. Lock does not apply to Brief.
struct BriefOffers: Equatable {
    let editsLine: Bool
    let editsIntent: Bool
    let confirms: Bool
}

/// **Brief** — what the faces' subject is held to (shell plan 3, spec
/// "Brief"). The scope switch: a piece, a Part, a piece that lives in another
/// project, and the subjects outside the manuscript. The Book and an edition
/// are Task 5's (`bookOrEdition` is the seam).
///
/// **It never loads a manuscript `Document`** (`BriefReader`; the census
/// `test_noBriefSourceLoadsAManuscriptDocument` reads this folder). The one
/// `Document` it may hold is a statement's, through `StatementEditorHost`,
/// the window's sanctioned second editor — and never one another host
/// already holds (`GoingForView.heldElsewhere`) or the centre's cover is
/// showing (`ProjectWindow.statementIsInTheCentre`).
struct BriefPane: View {
    @Bindable var store: ProjectStore
    let documentStore: DocumentStore
    let scope: BriefScope
    let diagnostics: DiagnosticsStore?
    let bible: BibleStore?
    let world: DeclaredWorldStore?
    let centreItem: CentreItem?
    let onOpenInCentre: (CentreItem) -> Void
    let onPullUp: (PulledUp) -> Void
    let onShowStrain: (_ docId: String, _ clauseQuote: String) -> Void
    let onOpenBrief: (BinderSubject) -> Void

    @State private var contents: BriefContents

    init(store: ProjectStore, documentStore: DocumentStore, scope: BriefScope,
         diagnostics: DiagnosticsStore?, bible: BibleStore?, world: DeclaredWorldStore?,
         centreItem: CentreItem?,
         onOpenInCentre: @escaping (CentreItem) -> Void,
         onPullUp: @escaping (PulledUp) -> Void,
         onShowStrain: @escaping (_ docId: String, _ clauseQuote: String) -> Void,
         onOpenBrief: @escaping (BinderSubject) -> Void) {
        self.store = store
        self.documentStore = documentStore
        self.scope = scope
        self.diagnostics = diagnostics
        self.bible = bible
        self.world = world
        self.centreItem = centreItem
        self.onOpenInCentre = onOpenInCentre
        self.onPullUp = onPullUp
        self.onShowStrain = onShowStrain
        self.onOpenBrief = onOpenBrief
        _contents = State(initialValue: .empty(scope))
    }

    static let elsewhereLine = "This piece belongs to another project. Its brief is that project's."
    static let outsideLine = "Brief holds what a piece, a Part, the Book or an edition is held to. Choose one in the tree."

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch scope {
            case .piece(let docId):
                scrolling {
                    BriefPieceView(
                        store: store, documentStore: documentStore, docId: docId,
                        contents: current, bible: bible, world: world,
                        inTheCentre: ProjectWindow.statementIsInTheCentre(
                            kind: .intent, scope: .document(docId), centreItem: centreItem),
                        onOpenInCentre: onOpenInCentre, onShowStrain: onShowStrain)
                    // One piece's state per piece: a scope change remounts it,
                    // so its line commits under the piece it was typed for.
                    .id(docId)
                }
            case .part(_, let docIds):
                scrolling {
                    BriefPartView(store: store, documentStore: documentStore, docIds: docIds,
                                  contents: current, world: world, onOpenBrief: onOpenBrief)
                }
            case .book, .edition:
                bookOrEdition
            case .elsewhere:
                quietPane(Self.elsewhereLine)
            case .outside:
                quietPane(Self.outsideLine)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: scope) { Self.loadFindings(scope, diagnostics: diagnostics) }
        .task(id: readKey) { contents = Self.read(scope: scope, store: store,
                                                 documentStore: documentStore,
                                                 diagnostics: diagnostics, bible: bible) }
    }

    /// The contents for the scope on screen: a value read for another scope
    /// is never drawn under this one (the `.task` lands a beat after a scope
    /// change).
    private var current: BriefContents {
        contents.snapshot.scope == scope ? contents : .empty(scope)
    }

    /// **The Book and an edition: Task 5 draws them here.** Nothing until
    /// then — this view is not mounted in the window before Task 9.
    @ViewBuilder
    private var bookOrEdition: some View {
        EmptyView()
    }

    private func scrolling<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            content()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func quietPane(_ line: String) -> some View {
        Text(line)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - The refresh

    /// **When Brief re-reads.** The scope; `BriefLine.refreshKey` (the
    /// manifest, `statementTextRevision` — every out-of-sight statement change
    /// — and the live openings); the piece's own intent as typed in an open
    /// host (a keystroke past the opening must still re-judge the marks); the
    /// check and the bible; and the open piece's paragraph order (a directive's
    /// orphan verdict). Built in `body` from in-memory observed values only.
    struct ReadKey: Equatable {
        let scope: BriefScope
        let refresh: BriefLine.RefreshKey
        let liveIntent: String?
        let diagnosticsVersion: Int
        let bibleVersion: Int
        let openSequence: [String]?
    }

    private var readKey: ReadKey {
        var liveIntent: String?
        var openSequence: [String]?
        if case .piece(let docId) = scope {
            if let intent = store.statement(kind: .intent, scope: .document(docId)) {
                liveIntent = store.openStatementDocument(id: intent.id)?.displayText
            }
            openSequence = documentStore.document(forDocId: docId)?.sequence
        }
        return ReadKey(scope: scope, refresh: BriefLine.refreshKey(store: store),
                       liveIntent: liveIntent, diagnosticsVersion: diagnostics?.version ?? 0,
                       bibleVersion: bible?.version ?? 0, openSequence: openSequence)
    }

    /// Read the scope's check sidecars, so `lastCheck` has something to
    /// answer. `.task` only.
    @MainActor
    static func loadFindings(_ scope: BriefScope, diagnostics: DiagnosticsStore?) {
        guard let diagnostics, case .piece(let docId) = scope else { return }
        diagnostics.load(docId: docId)
    }

    /// One read of everything the scope draws. `.task` only; no manuscript
    /// `Document` is loaded (the open piece's state is read off its live
    /// `Document`, a closed one's is derived — `currentParagraphState`).
    @MainActor
    static func read(scope: BriefScope, store: ProjectStore, documentStore: DocumentStore,
                     diagnostics: DiagnosticsStore?, bible: BibleStore?) -> BriefContents {
        let snapshot = BriefReader.read(scope: scope, store: store, bible: bible)
        var contents = BriefContents(snapshot: snapshot, isRead: true)
        switch scope {
        case .piece(let docId):
            let rulings = RulingsStratum.currentRows(kind: .intent, forScope: .document(docId), store: store)
            contents.fileOrder = [docId: rulings]
            contents.marks = marks(essay: snapshot.intentEssay, intentText: snapshot.intentText,
                                   run: diagnostics?.lastCheck(docId: docId))
            if rulings.contains(where: { $0.paragraphId != nil }),
               let state = try? currentParagraphState(documentId: docId, store: store,
                                                      documentStore: documentStore, projectURL: store.url) {
                contents.liveParagraphIds = Set(state.sequence)
            }
            if let bible {
                contents.facts = BibleStratum.facts(for: .document(docId), in: bible.allFacts())
            }
        case .part(_, let docIds):
            for docId in docIds {
                contents.fileOrder[docId] = RulingsStratum.currentRows(
                    kind: .intent, forScope: .document(docId), store: store)
            }
        case .book, .edition, .elsewhere, .outside:
            break
        }
        return contents
    }

    /// The marks to draw: none unless the check read exactly this intent
    /// (`ClauseMarks.applies`), else its strains and silent clauses placed on
    /// the WHOLE essay (so ranges are essay offsets).
    static func marks(essay: String?, intentText: String?, run: CompilerRun?) -> [ClauseMark] {
        guard let essay, let run, ClauseMarks.applies(run: run, statementText: intentText) else { return [] }
        return ClauseMarks.placement(in: essay, clauses: run.clauseStatuses ?? []).marks
    }

    // MARK: - What is offered (pure)

    /// What Brief offers under the piece intent's posture. Whether the piece
    /// is open in the centre does not enter: every one of these is a manifest
    /// or a statement write, never the piece's manuscript.
    static func offers(posture: Posture) -> BriefOffers {
        let edits = StatementSurfaceVerbs.offered(under: posture)
        return BriefOffers(editsLine: edits, editsIntent: edits, confirms: edits)
    }

    /// Which quiet lines show: From the book when the Book's intent has an
    /// essay or the Book has decisions; What Claude has read, with its count,
    /// when there is any.
    static func quietLines(_ snapshot: BriefSnapshot) -> (fromTheBook: Bool, readings: Int?) {
        let essay = (snapshot.bookIntentEssay ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (!essay.isEmpty || !snapshot.bookDecisions.isEmpty,
                snapshot.unconfirmedReadings > 0 ? snapshot.unconfirmedReadings : nil)
    }

    // MARK: - Shared pieces

    static func sectionHeading(_ title: String) -> some View {
        Text(title)
            .font(.caption).bold()
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    /// A quiet line that opens in place. `Button(.plain)` (tripwire 9's
    /// shape), so it reads as one control.
    static func disclosure(_ title: String, isOpen: Binding<Bool>) -> some View {
        Button { isOpen.wrappedValue.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: isOpen.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    /// What applies from the Book: its intent's essay and its decisions,
    /// read-only here (they are edited in the Book's Brief).
    struct FromTheBook: View {
        let essay: String?
        let decisions: [Ruling]

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                if let essay, !essay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(essay.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(decisions) { ruling in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ruling.text)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        if let caption = RulingsStratum.caption(for: ruling) {
                            Text(caption).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(.leading, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
