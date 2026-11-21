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
    /// Claude's unconfirmed readings for the piece (or the Book).
    var facts: [BibleFact] = []
    /// The Book's decisions, grouped by where each was made, in the filter's
    /// order (`BriefBookView.groups`). Empty for every other scope.
    var bookGroups: [BriefBookView.Group] = []
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
/// "Brief"). The scope switch: a piece, a Part, the Book, an edition, a piece
/// that lives in another project, and the subjects outside the manuscript.
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
    /// A solid mark's click: To resolve's request for its finding
    /// (`ClauseMarks.jump`); the window moves the right column to To resolve
    /// and hands the request over (`ProjectWindow.showStrain`).
    let onShowStrain: (ResolveRequest) -> Void
    let onOpenBrief: (BinderSubject) -> Void
    /// The Department desk for an edition — where its cast is changed. Nil
    /// draws no way there.
    let onOpenDesk: ((_ language: String) -> Void)?
    /// The window's tree: Details' sheets and cached publishing answer, and
    /// the fold index the empty-fold hint asks. Nil draws neither.
    let tree: BinderTreeSectionsState?

    @State private var contents: BriefContents
    /// A visual-language proposal waits (`VisualLanguageProposalModifier`,
    /// the source the segment's dot reads).
    @State private var proposalPending = false
    @State private var window: NSWindow?

    init(store: ProjectStore, documentStore: DocumentStore, scope: BriefScope,
         diagnostics: DiagnosticsStore?, bible: BibleStore?, world: DeclaredWorldStore?,
         centreItem: CentreItem?,
         onOpenInCentre: @escaping (CentreItem) -> Void,
         onPullUp: @escaping (PulledUp) -> Void,
         onShowStrain: @escaping (ResolveRequest) -> Void,
         onOpenBrief: @escaping (BinderSubject) -> Void,
         onOpenDesk: ((_ language: String) -> Void)? = nil,
         tree: BinderTreeSectionsState? = nil) {
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
        self.onOpenDesk = onOpenDesk
        self.tree = tree
        _contents = State(initialValue: .empty(scope))
    }

    static let elsewhereLine = "This piece belongs to another project. Its brief is that project's."
    static let outsideLine = "Brief holds what a piece, a Part, the Book or an edition is held to. Choose one in the tree."

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if proposalPending {
                BriefProposalNotice(onPullUp: onPullUp)
            }
            switch scope {
            case .piece(let docId):
                scrolling {
                    BriefPieceView(
                        store: store, documentStore: documentStore, docId: docId,
                        contents: current, bible: bible, world: world,
                        inTheCentre: ProjectWindow.statementIsInTheCentre(
                            kind: .intent, scope: .document(docId), centreItem: centreItem),
                        onOpenInCentre: onOpenInCentre, onShowStrain: onShowStrain,
                        onOpenBrief: onOpenBrief, onPullUp: onPullUp, tree: tree,
                        formatCaption: Self.formatCaption(
                            docId: docId, structure: store.manifest.structure,
                            projectType: store.manifest.type))
                    // One piece's state per piece: a scope change remounts it,
                    // so its line commits under the piece it was typed for.
                    .id(docId)
                }
            case .part(_, let docIds):
                scrolling {
                    BriefPartView(store: store, documentStore: documentStore, docIds: docIds,
                                  contents: current, world: world, onOpenBrief: onOpenBrief)
                }
            case .book:
                scrolling {
                    BriefBookView(
                        store: store, documentStore: documentStore, contents: current,
                        bible: bible, world: world, centreItem: centreItem,
                        onOpenInCentre: onOpenInCentre, onPullUp: onPullUp,
                        onOpenBrief: onOpenBrief)
                }
            case .edition(let language):
                // Not scrolled: the edition brief's own pane holds an editor
                // that takes the height it is given.
                BriefEditionView(store: store, documentStore: documentStore,
                                 language: language, onPullUp: onPullUp,
                                 onOpenDesk: onOpenDesk.map { open in { open(language) } })
                    .id(language)
            case .elsewhere:
                quietPane(Self.elsewhereLine)
            case .outside:
                quietPane(Self.outsideLine)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WindowAccessor(window: $window))
        .modifier(VisualLanguageProposalModifier(
            projectURL: store.url, window: window, proposed: $proposalPending))
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
                                   run: diagnostics?.lastCheck(docId: docId),
                                   findings: diagnostics?.checkFindings(docId: docId) ?? [],
                                   docId: docId)
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
        case .book:
            // Once per key, never per row or per filter (tripwire 4): each
            // origin's file-order rulings are read here, with the grouping.
            contents.bookGroups = BriefBookView.groups(
                snapshot.decisions, structure: store.manifest.structure) { origin in
                    let statement = origin.statement
                    return RulingsStratum.currentRows(kind: statement.kind,
                                                      forScope: statement.scope, store: store)
                }
            if let bible {
                contents.facts = BibleStratum.facts(for: .project, in: bible.allFacts())
            }
        case .edition, .elsewhere, .outside:
            break
        }
        return contents
    }

    /// The marks to draw: none unless the check read exactly this intent
    /// (`ClauseMarks.applies`), else its strains and silent clauses placed on
    /// the WHOLE essay (so ranges are essay offsets). Each solid mark carries
    /// its To resolve finding: the sidecar strain THIS run minted from that
    /// clause (`findings` from another run answer nothing).
    static func marks(essay: String?, intentText: String?, run: CompilerRun?,
                      findings: [Diagnostic] = [], docId: String? = nil) -> [ClauseMark] {
        guard let essay, let run, ClauseMarks.applies(run: run, statementText: intentText) else { return [] }
        return ClauseMarks.placement(in: essay, clauses: run.clauseStatuses ?? [],
                                     findings: findings.filter { $0.runId == run.id },
                                     docId: docId).marks
    }

    // MARK: - What is offered (pure)

    /// What Brief offers under the piece intent's posture. Whether the piece
    /// is open in the centre does not enter: every one of these is a manifest
    /// or a statement write, never the piece's manuscript.
    ///
    /// **The line is a manifest field, not the statement**, so it asks the
    /// tree's door for a piece's manifest fields — `mayWriteTheLine`, from
    /// `TreeStructureVerbs.mayRestructure` on the piece (what Rename asks) —
    /// and the intent, its decisions and Confirm ask the intent's posture.
    static func offers(posture: Posture, mayWriteTheLine: Bool) -> BriefOffers {
        let edits = StatementSurfaceVerbs.offered(under: posture)
        return BriefOffers(editsLine: mayWriteTheLine, editsIntent: edits, confirms: edits)
    }

    /// Whether the piece's line may be written: the tree's own question for
    /// a piece's manifest fields (`TreeStructureVerbs.mayRestructure`).
    @MainActor
    static func mayWriteTheLine(docId: String, store: ProjectStore,
                                documentStore: DocumentStore) -> Bool {
        guard let item = TreeWalk.find(id: docId, in: store.manifest.structure) else { return false }
        return TreeStructureVerbs.mayRestructure(item, postureOf: { documentStore.posture(forDocId: $0) })
    }

    /// Which quiet lines show: From the book when the Book's intent has an
    /// essay or the Book has decisions; What Claude has read, with its count,
    /// when there is any.
    static func quietLines(_ snapshot: BriefSnapshot) -> (fromTheBook: Bool, readings: Int?) {
        let essay = (snapshot.bookIntentEssay ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (!essay.isEmpty || !snapshot.bookDecisions.isEmpty,
                snapshot.unconfirmedReadings > 0 ? snapshot.unconfirmedReadings : nil)
    }

    /// **What a Collection's loose piece is written as** — "Prose" or
    /// "Screenplay" (owner's ruling, shell plan 3 Task 9: the old piece
    /// inspector's format label, at the head of the one place that says what
    /// the piece is held to). Nil outside a project that holds pieces, where
    /// every piece is the project's own kind, and for a reference piece,
    /// which has no Brief here.
    static func formatCaption(docId: String, structure: [StructureItem],
                              projectType: ProjectType) -> String? {
        guard projectType.holdsPieces,
              let piece = TreeWalk.find(id: docId, in: structure) else { return nil }
        switch piece.pieceKind {
        case .reference: return nil
        case .loose, .none: return DocumentFormat.ofManuscript(path: piece.path).kindLabel
        }
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

extension BriefPane {
    /// **Whether `(kind, scope)`'s statement would not read in this
    /// snapshot** (RULING-54; final wave, I2): named in `unreadable`, never
    /// drawn as empty.
    static func statementIsUnreadable(kind: Statement.Kind, scope: Statement.Scope,
                                      snapshot: BriefSnapshot, statements: [Statement]) -> Bool {
        guard !snapshot.unreadable.isEmpty,
              let id = StatementLookup.statement(in: statements, kind: kind, scope: scope)?.id
        else { return false }
        return snapshot.unreadable.contains(id)
    }
}
