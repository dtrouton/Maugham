import SwiftUI
import MaughamCore

// MARK: - The decisions (pure)

/// **What the head is, for a scope** (shell plan 2, Task 5).
enum ResolveHeadShape: Equatable {
    /// One piece: where it stands, its latest letter, Run.
    case piece(docId: String)
    /// Book or Part: one line counting the pieces with something open.
    case count
    /// An edition (shell p4 Task 6): where it stands and Run — the
    /// translator's newest letter and a whole-book round, or for the Source
    /// edition the designer's line and a design round (`EditionHeadView`).
    case edition(language: String, isSource: Bool)
    /// A piece read in a language (shell p4 Task 9): that piece's own latest
    /// round in the language — its letter, or why it stopped — then Run on
    /// this piece, what the translation still lacks, what is left over from
    /// deleted paragraphs, and the caret's paragraph's spot-checks
    /// (`PieceInLanguageHeadView`).
    case pieceInLanguage(docId: String, language: String)
    /// A figure, a reference piece, or nothing To resolve reads.
    case nothing
}

/// **What the head offers on a piece** — read anywhere, act only on the open
/// piece (Denver, 2026-11-18), and hide what the posture refuses (tripwires 47,
/// 51). Every field is a presence: a refused control is not drawn, never
/// greyed.
struct ResolveHeadOffers: Equatable {
    /// The round's Run and Fresh Eyes: the open piece, where the posture runs
    /// a round (ruling R4).
    let runRound: Bool
    /// The check's Reread: the open piece. A check is not gated by posture —
    /// it writes the reviewer row (`Posture.Verb.runRound`'s own note).
    let runCheck: Bool
    /// The ladder's menus and the pass-order nudge's verbs. A pass state is a
    /// manifest value (`ProjectStore.setPassState`), not a `Document` method,
    /// so it is offered open or not, wherever `PassLadder.offersRulings` says.
    let rulesOnPasses: Bool
    /// The letter's Accept as task: `Document.createPaneTask`, so the open
    /// piece only, where the posture takes a task.
    let acceptsExercise: Bool
    /// "Open the piece to run a check or a round on it." — in place of Run on
    /// a piece that is not open.
    let opensThePiece: Bool
}

/// **To resolve's head: the pure half.** No store is read here; the view
/// below hands each decision its values.
enum ResolveHead {

    /// The head for `scope`. A one-script screenplay's Book is a `.piece`
    /// scope, so it gets the piece's head.
    static func shape(_ scope: ResolveScope) -> ResolveHeadShape {
        switch scope {
        case .piece(let docId, _): return .piece(docId: docId)
        case .pieces: return .count
        case .edition(let language, let isSource, _): return .edition(language: language, isSource: isSource)
        case .pieceInLanguage(let docId, let language): return .pieceInLanguage(docId: docId, language: language)
        case .figure, .elsewhere, .outside: return .nothing
        }
    }

    /// What the head offers on a piece. `mayAct` is `ResolveVerbGate.mayAct`
    /// for that piece; `posture` is the piece's drawing posture
    /// (`DocumentStore.posture(forDocId:)`).
    static func offers(mayAct: Bool, posture: Posture) -> ResolveHeadOffers {
        ResolveHeadOffers(
            runRound: mayAct && posture.allows(.runRound),
            runCheck: mayAct,
            rulesOnPasses: PassLadder.offersRulings(under: posture),
            acceptsExercise: mayAct && posture.allows(.task),
            opensThePiece: !mayAct)
    }

    /// **The newer of the check's letter and the round's**, by the run's
    /// `at`. A run whose letter is absent or says nothing (`Letter.isEmpty`)
    /// yields to the other; a tie goes to the check. The translator's round
    /// letter is not one of these: it is a `TranslationRound`, kept per
    /// language, and a later plan draws it.
    static func latestLetter(check: CompilerRun?, round: CompilerRun?) -> CompilerRun? {
        func written(_ run: CompilerRun?) -> CompilerRun? {
            guard let run, let letter = run.letter, !letter.isEmpty else { return nil }
            return run
        }
        switch (written(check), written(round)) {
        case let (check?, round?): return round.at > check.at ? round : check
        case let (check?, nil): return check
        case let (nil, round?): return round
        case (nil, nil): return nil
        }
    }

    /// **Who signed a standing letter** — each loop's own answer (tripwire
    /// 34). A check's is the reader the run was read under, else today's
    /// `AuthorReader` (the Diagnostics pane's rule); a round's is its pass's
    /// editor (`ResolveHead.roundLetterVoice`). Neither reads the other's.
    @MainActor
    static func letterVoice(run: CompilerRun, reader: AuthorReader,
                            passes: [ReviewPass]) -> String {
        switch run.effectiveKind {
        case .check: return run.readerName ?? reader.editorName
        case .round: return roundLetterVoice(run: run, passes: passes)
        }
    }

    /// **The round's report line, honest without a queue.** With the piece's
    /// annotations in every state it is the cockpit's own line. With none
    /// (`nil`: the piece is not open, and To resolve reads only its open
    /// notes), a since-round count would say "0 resolved" over notes it never
    /// saw, so only what the run cost is said.
    @MainActor
    static func roundReportLine(history: [RoundRecord], run: CompilerRun?,
                                annotations: [Annotation]?, passes: [ReviewPass]) -> String? {
        guard let annotations else { return run?.timing.map(RoundNarrative.readInLine) }
        return ReviewRoundCockpit.reportLine(
            history: history, run: run, annotations: annotations, passes: passes)
    }

    /// **The open document's queue in every state**, version-gated —
    /// `nil` when there is no document (the piece is not open). Never a load.
    @MainActor
    static func everyState(of document: Document?) -> [Annotation]? {
        guard let document else { return nil }
        _ = document.annotationsVersion
        return document.annotations(filter: AnnotationFilter(statuses: nil))
    }

    /// **What a Book or Part holds open**, counted from the UNFILTERED
    /// snapshot (controller ruling M3): the pieces with something open, the
    /// Book's own to-dos, and notes on figures no piece owns. A figure owned by
    /// a piece counts on that piece (`ProjectStore.countsOn`, the board's rule).
    static func bookCount(_ items: [ResolveItem], scope: ResolveScope,
                          figureOwners: [String: String?]) -> ResolveBookCount {
        let held = Set(scope.docIds)
        var pieces: Set<String> = []
        var bookTodos = 0
        var bookFigures = 0
        for item in items {
            let docId = item.docId
            if docId == ProjectStore.projectTasksDocId {
                bookTodos += 1
            } else if let piece = ProjectStore.countsOn(docId, owners: figureOwners) {
                if held.contains(piece) { pieces.insert(piece) }
            } else {
                bookFigures += 1
            }
        }
        return ResolveBookCount(pieces: pieces.count, bookTodos: bookTodos,
                                bookFigures: bookFigures)
    }

    /// **The Book's or a Part's lines** — one per kind of thing open, never
    /// "Nothing to resolve" over a list with something in it.
    static func bookLines(_ count: ResolveBookCount) -> [String] {
        var lines: [String] = []
        switch count.pieces {
        case 0: break
        case 1: lines.append("1 piece has something open")
        default: lines.append("\(count.pieces) pieces have something open")
        }
        if count.bookTodos > 0 { lines.append(bookTodosLine) }
        if count.bookFigures > 0 { lines.append(bookFiguresLine) }
        return lines.isEmpty ? [nothingLine] : lines
    }

    // MARK: Earlier letters (shell p4 Task 9; the plan's call 9)

    /// **The editors' earlier letters on a piece** — each pass's latest
    /// FINISHED round (`DiagnosticsStore.latestRounds`, which never holds a
    /// round still arriving), that says something, of a pass the project
    /// still lists (Task 2 review M2: the map is unpruned), less the letter
    /// the head already shows. Mid-round the head shows the round arriving
    /// (`lastRound`) and this lists the finished letters behind it — never
    /// the preview twice. Empty — and the menu hidden — with one letter.
    static func earlierLetters(_ latestRounds: [CompilerRun], shown: CompilerRun?,
                               passes: [ReviewPass]) -> [CompilerRun] {
        let listed = Set(passes.map(\.id))
        return latestRounds.filter { run in
            guard run.id != shown?.id, let passId = run.passId, listed.contains(passId),
                  let letter = run.letter, !letter.isEmpty else { return false }
            return true
        }
    }

    /// One earlier letter's line in the menu: its editor and its round.
    static func earlierLetterTitle(_ run: CompilerRun, passes: [ReviewPass]) -> String {
        let editor = roundLetterVoice(run: run, passes: passes)
        return run.round.map { "\(editor) \u{00B7} round \($0)" } ?? editor
    }

    static let earlierLettersTitle = "Earlier letters"
    static let backToTheLatestLetterTitle = "The latest letter"
    static let earlierLetterShownLabel = "An earlier letter"

    static let nothingLine = "Nothing to resolve"
    static let bookTodosLine = "Book to-dos open"
    static let bookFiguresLine = "Book figures have notes open"

    /// **The identity the letter block takes**: its piece and its run. The
    /// block holds the letter's refusals and confirmations, so a new piece or
    /// a new latest run (the check's letter giving way to the round's) mounts
    /// a fresh block and nothing raised on one letter is drawn under another.
    static func letterIdentity(docId: String, runId: String) -> String {
        "\(docId)/\(runId)"
    }

    /// **In place of Run on a piece that is not open; its click opens it**
    /// (appraisal 1). Where the piece has notes or to-dos, whose verbs act
    /// only on the open piece (`ResolveVerbGate`), it says that is why they
    /// have no buttons here; otherwise it says what opening offers. `noun` is
    /// what the project calls a piece (`FiledUnder.pieceNoun`). Pure.
    static func openThePieceLine(noun: String, hasItemsToAnswer: Bool) -> String {
        hasItemsToAnswer
            ? "Open this \(noun) to answer its notes"
            : "Open this \(noun) to run a check or a round on it"
    }

    /// Whether any of `items` on `docId` needs the piece open to be acted on:
    /// a note or a to-do. A finding's Answer files a ruling and needs no
    /// `Document`, so findings alone ask nothing. Pure.
    static func hasItemsToAnswer(_ items: [ResolveItem], docId: String) -> Bool {
        items.contains { item in
            guard item.docId == docId else { return false }
            switch item {
            case .note, .todo: return true
            // A finding's Answer files a ruling; an edition's kinds act
            // through the round's record, the gate or the centre — none
            // needs the piece open.
            case .finding, .translationChange, .glossaryProposal, .designProposal, .compileProblem:
                return false
            }
        }
    }

    /// **The piece a Book or Part group's header offers to open** (appraisal
    /// 1): a piece's group whose notes or to-dos cannot be acted on here
    /// because the piece is not open (`mayAct` is `ResolveVerbGate.mayAct`).
    /// Nil for every other group. Opening it keeps the list (the row click's
    /// `ResolveNavigation.goInsideTheFaces`). Pure.
    static func groupOpensItsPiece(_ group: ResolveGroup, mayAct: (String) -> Bool) -> String? {
        guard case .piece(let docId) = group.key, !mayAct(docId),
              hasItemsToAnswer(group.items, docId: docId) else { return nil }
        return docId
    }
}

/// What a Book or Part holds open (`ResolveHead.bookCount`).
extension ResolveHead {
    /// The "whose piece this is" line for `docId`: `PieceWriters`' sentence,
    /// nil where the book names nobody for it (one writer, or whole-book
    /// co-authors) — the old Inspector's rule, unchanged.
    static func whoseLine(_ writers: PieceWriters, docId: String) -> String? {
        writers.sentence(for: docId)
    }
}

/// **The head's "Written by" line and its one registry read** — a view of its
/// own, so the head holds no state (`ResolveHeadView`'s letter rule). Read
/// once per project in `.task(id: store.url)`, the old Inspector's rule: who
/// may write in this book is a fact about the folder, so moving between
/// chapters costs no registry read, and nothing reads it in `body`
/// (tripwire 4).
struct ResolveWhoseLineHost: View {
    let store: ProjectStore
    let docId: String

    @State private var writers: PieceWriters = .none

    var body: some View {
        // A stack, not a `Group`: an empty `Group` hands its `.task` to no
        // child, and the read would never run.
        VStack(alignment: .leading, spacing: 0) {
            if let by = ResolveHead.whoseLine(writers, docId: docId) {
                ResolveWhoseLine(sentence: by)
            }
        }
        .task(id: store.url) {
            writers = await PieceWriters.read(
                projectURL: store.url,
                pieces: PermitControl.pieces(in: store.manifest.structure))
        }
    }
}

/// The head's "Written by" line: the title over the names, wrapping in a
/// narrow column. Identified by `PieceWriters.rowIdentifier`, as the
/// Inspector's row was.
struct ResolveWhoseLine: View {
    let sentence: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(PieceWriters.rowTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(sentence)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(PieceWriters.rowIdentifier)
    }
}

/// **"Open this chapter to answer its notes"** — the head's line on a piece
/// that is not open, and a Book or Part group's (appraisal 1). A link-styled
/// button, so it reads as something to press, never as a caption.
struct ResolveOpenThePieceButton: View {
    let line: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            Text(line)
                .font(.caption)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.link)
        .help(line)
        .accessibilityIdentifier("resolve.openThePiece")
    }
}

struct ResolveBookCount: Equatable {
    let pieces: Int
    let bookTodos: Int
    /// Notes on figures no piece owns (a whole-book figure).
    let bookFigures: Int
}

// MARK: - The head

/// **To resolve's head** (shell plan 2, Task 5).
///
/// For a piece: where it stands (`PassLadder` with its derived status, the
/// pass-order nudge, the drift line), then the latest letter, then Run (the
/// round cockpit with no letter of its own, and below it the check's header:
/// its reader, Ask and status — their only home). At Book or Part scope: one
/// line. A figure, a reference piece or nothing: nothing.
///
/// **Read anywhere, act only on the open piece.** The standing and the letter
/// show whether or not the piece is open: pass states are manifest values and
/// the letter's text is the snapshot's. Run and Accept as task are offered on
/// the open piece only (`ResolveVerbGate`); elsewhere one quiet line says how,
/// and opens the piece. The ladder's menus are offered wherever the posture
/// allows.
///
/// **Never loads.** It reads the diagnostics store as its host loaded it (the
/// list's `ResolveReader.loadFindings`), the manifest, the snapshot, and the
/// open document only through `DocumentStore.document(forDocId:)`.
///
/// **Tripwire 34.** The check's reader is `reader` (an `AuthorReader` the host
/// resolves from the roster choice); the round's lane is the piece's recorded
/// active pass. The head shows both and neither feeds the other.
@MainActor
struct ResolveHeadView: View {
    let scope: ResolveScope
    /// The list's one read of the scope (`ResolveReader.read`).
    let snapshot: ResolveSnapshot
    /// The piece open in the window's centre — `WindowSubject.open.itemID`.
    let openDocId: String?
    let store: ProjectStore
    let documentStore: DocumentStore
    /// `nil` where no compiler stands behind the window: no letter, no Run.
    let orchestrator: CompilerOrchestrator?
    let diagnostics: DiagnosticsStore?
    let world: DeclaredWorldStore?
    /// Who reads this piece's checks (`ProjectManifest.authorReader(choice:…)`).
    let reader: AuthorReader
    let compilerModel: CompilerModelChoice
    let onCompilerModelChange: (CompilerModelChoice) -> Void
    let onChooseReader: (AuthorReaderChoice) -> Void
    let onOpenProjectSettings: () -> Void
    /// `(piece, passId)` — the window's one `ActivePassMemory` writer.
    let onSetActivePass: (String, String) -> Void
    /// `(piece, passId, state)` — threaded from `RightColumn`, whose closure
    /// is `ProjectStore.setPassState` (`PassStateWriterCensusTests`).
    let onSetPassState: (String, String, PassState?) -> Void
    /// Where the letter's Add to intent or Keep as lesson filed, once it
    /// landed — the list says so under the head (shell plan 3 Task 6).
    var onFiledUnder: (FiledDestination) -> Void = { _ in }
    /// An edition's own read (`ResolveEditionItems.Read`) — its rounds and
    /// proposals, which the edition head draws from.
    var editionRead: ResolveEditionItems.Read = .empty
    /// The round cover and the design gate (`PublishCentreModel.show`).
    var onShowRound: (TranslationRound) -> Void = { _ in }
    var onShowProposal: (DesignProposalStore.Proposal) -> Void = { _ in }
    /// Whether this Mac may decide the book's design (`ResolvePane
    /// .mayDecideDesign`).
    var mayDecideDesign = false
    /// The window's editor control — a piece read in a language's head reads
    /// the translated surface's badges and the caret off it.
    var editorControl: EditorControl? = nil
    /// `.maughamTranslationDidUpdate`s heard: a piece read in a language
    /// re-reads its translation.
    var translationHeard = 0

    @Environment(\.undoManager) private var undoManager

    var body: some View {
        switch ResolveHead.shape(scope) {
        case .piece(let docId):
            pieceHead(docId)
        case .count:
            VStack(alignment: .leading, spacing: 2) {
                ForEach(ResolveHead.bookLines(ResolveHead.bookCount(
                    snapshot.items, scope: scope,
                    figureOwners: ProjectStore.figureNoteOwners(store.manifest.figures ?? []))),
                        id: \.self) { line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 6)
        case .edition(let language, let isSource):
            EditionHeadView(language: language, isSource: isSource,
                            store: store, documentStore: documentStore,
                            editionRead: editionRead, mayDecideDesign: mayDecideDesign,
                            onShowRound: onShowRound, onShowProposal: onShowProposal)
        case .pieceInLanguage(let docId, let language):
            PieceInLanguageHeadView(
                docId: docId, language: language, store: store, documentStore: documentStore,
                read: editionRead,
                isOpen: ResolveVerbGate.mayAct(
                    onDocId: docId, openDocId: openDocId,
                    isRegistered: { documentStore.document(forDocId: $0) != nil }),
                editorControl: editorControl,
                firstParagraph: snapshot.sequences[docId]?.first,
                paragraphText: snapshot.paragraphText,
                model: compilerModel.claudeModel, world: world,
                onShowRound: onShowRound, translationHeard: translationHeard)
        case .nothing:
            EmptyView()
        }
    }

    // MARK: - A piece

    private var passes: [ReviewPass] { store.manifest.effectiveReviewPasses }

    @ViewBuilder
    private func pieceHead(_ docId: String) -> some View {
        let offers = ResolveHead.offers(
            mayAct: ResolveVerbGate.mayAct(
                onDocId: docId, openDocId: openDocId,
                isRegistered: { documentStore.document(forDocId: $0) != nil }),
            posture: documentStore.posture(forDocId: docId))
        VStack(alignment: .leading, spacing: 0) {
            standing(docId, offers: offers)
            if let diagnostics {
                latestLetter(docId, offers: offers, diagnostics: diagnostics)
            }
            if offers.opensThePiece {
                ResolveOpenThePieceButton(
                    line: ResolveHead.openThePieceLine(
                        noun: FiledUnder.pieceNoun(TreeWalk.find(id: docId, in: store.manifest.structure),
                                                   projectType: store.manifest.type),
                        hasItemsToAnswer: ResolveHead.hasItemsToAnswer(snapshot.items, docId: docId)),
                    open: { ResolveNavigation.go(toDocId: docId) })
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
            if let orchestrator, let diagnostics {
                run(docId, offers: offers, orchestrator: orchestrator, diagnostics: diagnostics)
            }
        }
    }

    // MARK: Where it stands

    @ViewBuilder
    private func standing(_ docId: String, offers: ResolveHeadOffers) -> some View {
        if let item = TreeWalk.find(id: docId, in: store.manifest.structure) {
            VStack(alignment: .leading, spacing: 4) {
                PassLadder(
                    item: item, passes: passes,
                    onSet: offers.rulesOnPasses
                        ? { passId, state in onSetPassState(docId, passId, state) }
                        : nil)
                // **Whose piece this is**, under the ladder (shell p3 Task 8,
                // from the old Inspector) — only where `PieceWriters` draws a
                // sentence: a book whose permits name pieces.
                ResolveWhoseLineHost(store: store, docId: docId)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            if let nudge = ResolveHead.passOrderNudgeDecision(
                isProjectScope: false, docId: docId,
                memory: documentStore.uiState.activePassMemory, passes: passes,
                passStates: item.passStates,
                posture: { documentStore.posture(forDocId: $0) },
                onSetPassState: onSetPassState) {
                PassOrderNudgeRow(
                    pass: nudge.pass, onMarkDone: nudge.onMarkDone, onSkip: nudge.onSkip)
            }
        }
        if let diagnostics {
            DiagnosticsDriftLine(driftFindings: driftFindings(docId, diagnostics: diagnostics))
        }
        Divider()
    }

    private func driftFindings(_ docId: String, diagnostics: DiagnosticsStore) -> [DriftFinding] {
        _ = diagnostics.version
        return DriftDetector.drift(history: diagnostics.clauseStatusHistory(docId: docId))
    }

    // MARK: The latest letter

    @ViewBuilder
    private func latestLetter(_ docId: String, offers: ResolveHeadOffers,
                              diagnostics: DiagnosticsStore) -> some View {
        let _ = diagnostics.version
        let latest = ResolveHead.latestLetter(
            check: diagnostics.lastCheck(docId: docId),
            round: diagnostics.lastRound(docId: docId))
        HeadLetterArea(
            latest: latest,
            earlier: ResolveHead.earlierLetters(diagnostics.latestRounds(docId: docId),
                                                shown: latest, passes: passes),
            passes: passes,
            block: { run, letter in
                AnyView(HeadLetterBlock(
                    letter: letter, run: run,
                    voice: ResolveHead.letterVoice(run: run, reader: reader, passes: passes),
                    docId: docId, store: store, world: world,
                    postureOf: { kind, scope in
                        documentStore.posture(
                            ofStatement: kind, scope: scope,
                            statements: store.manifest.statements)
                    },
                    currentText: { snapshot.paragraphText[$0] },
                    onJump: { ResolveNavigation.go(toDocId: docId, paragraphId: $0) },
                    onAcceptExercise: offers.acceptsExercise ? { habit in
                        documentStore.document(forDocId: docId)?.createPaneTask(
                            body: habit.exercise ?? habit.name,
                            parentTaskId: nil,
                            paragraphId: habit.refs.first?.paragraphId,
                            undoManager: undoManager)
                    } : nil,
                    onFiledUnder: onFiledUnder)
                    // **Keyed by piece and run** (fix round 1, I1): a piece
                    // switch, the check's letter giving way to the round's,
                    // or an earlier letter chosen mounts a fresh block, so no
                    // refusal outlives its letter.
                    .id(ResolveHead.letterIdentity(docId: docId, runId: run.id)))
            })
            // "Until the faces change": a new piece starts on its latest.
            .id(docId)
    }

    // MARK: Run

    @ViewBuilder
    private func run(_ docId: String, offers: ResolveHeadOffers,
                     orchestrator: CompilerOrchestrator,
                     diagnostics: DiagnosticsStore) -> some View {
        let open = ResolveHead.everyState(of: documentStore.document(forDocId: docId))
        RoundCockpitMount(
            docId: docId, store: store, orchestrator: orchestrator,
            diagnostics: diagnostics, reviewPasses: passes,
            activePass: activePass(docId),
            annotations: open,
            // **The command, posted** (one delivery path): the window runs
            // its own open piece, and answers a piece it cannot open.
            onRun: offers.runRound
                ? { freshEyes in MaughamEvent.postRun(freshEyes ? .freshEyes : .runRound) }
                : nil,
            onSetActivePass: { onSetActivePass(docId, $0) },
            compilerModel: compilerModel,
            onCompilerModelChange: onCompilerModelChange)
        Divider()
        checkHeader(docId, offers: offers, open: open,
                    orchestrator: orchestrator, diagnostics: diagnostics)
    }

    /// The piece's RECORDED active pass — the round's lane, and nothing the
    /// check reads.
    private func activePass(_ docId: String) -> ReviewPass? {
        guard let id = documentStore.uiState.activePassMemory
            .validatedActivePass(forPiece: docId, in: passes) else { return nil }
        return passes.first { $0.id == id }
    }

    /// **The check's own header** — its line, Reread, the reader picker and
    /// Ask. The values the Diagnostics pane derives, derived the same way from
    /// the same statics, over the snapshot rather than a document.
    private func checkHeader(_ docId: String, offers: ResolveHeadOffers,
                             open: [Annotation]?, orchestrator: CompilerOrchestrator,
                             diagnostics: DiagnosticsStore) -> some View {
        _ = diagnostics.version
        let check = diagnostics.lastCheck(docId: docId)
        let strains = snapshot.items.filter {
            if case .finding(let id, let finding) = $0 {
                return id == docId && finding.kind == .conformanceStrain
            }
            return false
        }.count
        let openNow = snapshot.items.filter {
            if case .note(let note) = $0, let runId = check?.id {
                return note.docId == docId && note.annotation.compilerRunId == runId
            }
            return false
        }.count
        return DiagnosticsPaneHeader(
            state: CheckNarrative.headerState(
                runState: orchestrator.runState, lastRun: check, noteCount: strains,
                docId: docId, runStartedAt: orchestrator.runStartedAt,
                runProgress: orchestrator.runProgress),
            // The snapshot is the piece's whole open queue, read without a
            // load, so the queue is always visible here.
            wetInk: CheckNarrative.wetInkStanding(
                mintedNotes: check?.mintedNotes, queueVisible: true, openNow: openNow),
            visibleQueue: open,
            reviewPasses: passes,
            otherLoopLine: CheckNarrative.otherLoopLine(
                runState: orchestrator.runState, docId: docId,
                titleOf: { RoundNarrative.pieceTitle(of: $0, in: store.manifest.structure) }),
            orchestrator: orchestrator, diagnostics: diagnostics, docId: docId,
            reader: reader, store: store,
            compilerModel: compilerModel,
            onCompilerModelChange: onCompilerModelChange,
            onChooseReader: onChooseReader,
            onOpenProjectSettings: onOpenProjectSettings,
            offersReread: offers.runCheck,
            // The cockpit above draws the same `compilerModel` menu: one
            // setting, drawn once.
            offersModelMenu: false)
    }
}

// MARK: - The head's letter block

/// **The head's latest letter with its own state** — the six values
/// `RunLetterSection` binds, held here so they live and die with ONE letter.
/// Mounted with `.id(ResolveHead.letterIdentity(docId:runId:))`.
@MainActor
struct HeadLetterBlock: View {
    let letter: Letter
    let run: CompilerRun
    let voice: String
    let docId: String
    let store: ProjectStore
    let world: DeclaredWorldStore?
    let postureOf: (Statement.Kind, Statement.Scope) -> Posture
    let currentText: (String) -> String?
    let onJump: (String) -> Void
    let onAcceptExercise: ((Letter.Habit) -> Void)?
    var onFiledUnder: (FiledDestination) -> Void = { _ in }

    @State private var turnClauseFiledForRun: String?
    @State private var offerFailure: String?
    @State private var keptLetter: LetterKeep.Kept?
    @State private var keepFailure: String?
    @State private var ledgerFailure: String?
    @State private var ledgerRevision = 0

    var body: some View {
        RunLetterSection(
            letter: letter, run: run, voice: voice, docId: docId,
            store: store, world: world, postureOf: postureOf,
            currentText: currentText, onJump: onJump,
            onAcceptExercise: onAcceptExercise,
            turnClauseFiledForRun: $turnClauseFiledForRun,
            offerFailure: $offerFailure,
            keptLetter: $keptLetter,
            keepFailure: $keepFailure,
            ledgerFailure: $ledgerFailure,
            ledgerRevision: $ledgerRevision,
            onFiledUnder: onFiledUnder)
    }
}

// MARK: - The head's letter, and the earlier ones

/// **The piece's letter, with "Earlier letters"** (shell p4 Task 9): the
/// latest letter (the check's or the round's, `ResolveHead.latestLetter`),
/// or — chosen from the one menu, hidden with one letter — an earlier
/// editor's latest finished letter, drawn in its place until the faces
/// change (the host mounts this `.id(docId)`).
@MainActor
struct HeadLetterArea: View {
    let latest: CompilerRun?
    let earlier: [CompilerRun]
    let passes: [ReviewPass]
    let block: (CompilerRun, Letter) -> AnyView

    @State private var chosenRunId: String?

    /// The run drawn: the chosen earlier one while it is still listed, else
    /// the latest. Pure.
    static func shown(latest: CompilerRun?, earlier: [CompilerRun], chosen: String?) -> CompilerRun? {
        earlier.first { $0.id == chosen } ?? latest
    }

    var body: some View {
        let run = Self.shown(latest: latest, earlier: earlier, chosen: chosenRunId)
        let isEarlier = run.map { $0.id != latest?.id } ?? false
        if !earlier.isEmpty {
            HStack(spacing: 6) {
                if isEarlier {
                    Text(ResolveHead.earlierLetterShownLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                Menu(ResolveHead.earlierLettersTitle) {
                    if isEarlier, latest != nil {
                        Button(ResolveHead.backToTheLatestLetterTitle) { chosenRunId = nil }
                        Divider()
                    }
                    ForEach(earlier, id: \.id) { run in
                        Button(ResolveHead.earlierLetterTitle(run, passes: passes)) { chosenRunId = run.id }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.caption)
                .accessibilityIdentifier("resolve.earlierLetters")
            }
            .padding(.horizontal, 12).padding(.top, 4)
        }
        if let run, let letter = run.letter {
            block(run, letter)
            Divider()
        }
    }
}

// MARK: - The round cockpit's mount (moved from `AnnotationsRoundCockpit`)

/// **The round cockpit, mounted over one piece** — `ReviewRoundCockpit` with
/// the reads it draws from. Moved out of `AnnotationsRoundCockpit` so To
/// resolve's head and the old queue mount the one spelling; the old queue
/// supplies its letter, the head none (its letter is drawn above Run).
///
/// `onRun` is the host's: the head posts the command; `nil` draws no Run.
@MainActor
struct RoundCockpitMount: View {
    let docId: String
    let store: ProjectStore
    let orchestrator: CompilerOrchestrator
    let diagnostics: DiagnosticsStore
    let reviewPasses: [ReviewPass]
    /// The piece's RECORDED active pass (`validatedActivePass`), never the
    /// queue's filter and never the seat.
    let activePass: ReviewPass?
    /// The piece's queue in EVERY state (`ResolveHead.everyState`), or `nil`
    /// when no queue is visible — then the line is only the run's cost.
    let annotations: [Annotation]?
    let onRun: ((_ freshEyes: Bool) -> Void)?
    let onSetActivePass: (String) -> Void
    let compilerModel: CompilerModelChoice
    let onCompilerModelChange: (CompilerModelChoice) -> Void
    /// The round's own letter, for its one line; `nil` draws none.
    var letter: Letter? = nil
    var letterDisclosure: (() -> AnyView)? = nil

    var body: some View { roundCockpit }

    @ViewBuilder
    private var roundCockpit: some View {
        // **The seat is not read here at all** (two loops P1 Task 8). The
        // coach reads CHECKS, in Author (`AuthorReader`); a round is the
        // piece's own stage editor's or it is refused (`RoundEditor`), so
        // every value this strip draws comes from `activePass`.
        let pass = activePass
        ReviewRoundCockpit(
            passes: reviewPasses,
            activePassId: pass?.id,
            // **The piece's own lane, or none.**
            round: cockpitRound(passId: pass?.id),
            phase: ReviewRoundCockpit.phase(
                runState: orchestrator.runState, docId: docId,
                titleOf: { RoundNarrative.pieceTitle(
                    of: $0, in: store.manifest.structure) }),
            reportLine: cockpitReportLine,
            runSince: orchestrator.runStartedAt,
            runProgress: orchestrator.runProgress,
            reportTiming: cockpitReportTiming,
            onRun: onRun,
            onSetActivePass: onSetActivePass,
            onCancel: { orchestrator.cancel() },
            compilerModel: compilerModel,
            onCompilerModelChange: onCompilerModelChange,
            letterLine: ReviewRoundCockpit.letterLine(letter),
            letterDisclosure: letterDisclosure,
            // **The round's own ask** (`kind: .round`), independent of the
            // check's for the same document (two loops P1 Task 6).
            ask: AskField.Input(
                docId: docId,
                kind: .round,
                text: cockpitAsk,
                commit: { text in
                    AskField.commit(text, docId: docId, kind: .round, diagnostics: diagnostics)
                },
                note: { text, doc in
                    AskField.note(text, docId: doc, kind: .round, diagnostics: diagnostics)
                }))
    }

    /// The lane's newest round number — `latestRound`, the one spelling of
    /// "which round is this lane on", shared with the round mint.
    private func cockpitRound(passId: String?) -> Int? {
        _ = diagnostics.version
        return diagnostics.latestRound(forPass: passId, docId: docId)
    }

    private var cockpitAsk: String? {
        _ = diagnostics.version
        return diagnostics.ask(docId: docId, kind: .round)
    }

    private var cockpitReportLine: String? {
        _ = diagnostics.version
        return ResolveHead.roundReportLine(
            history: diagnostics.roundHistory(docId: docId),
            run: diagnostics.lastRound(docId: docId),
            annotations: annotations, passes: reviewPasses)
    }

    /// The run the report line was resolved from, so the tooltip and the line
    /// describe the same turn.
    private var cockpitReportTiming: RunTiming? {
        _ = diagnostics.version
        return diagnostics.lastRound(docId: docId)?.timing
    }
}

// MARK: - A standing letter (moved from both letter hosts)

/// **A run's letter with its verbs** — the one host `LetterSection` has.
/// Moved out of the Diagnostics pane (the check's letter) and
/// `AnnotationsRoundCockpit` (the round's), which built the same verbs from
/// the same builders with their own values; each now hands those values here.
///
/// **`voice` is the run's own byline** and every writing site reads it — the
/// signature, Keep's heading, a filed lesson's provenance and Add-to-intent's
/// — so a standing letter is never re-signed by whoever reads today. The host
/// decides it (`ResolveHead.letterVoice`).
@MainActor
struct RunLetterSection: View {
    let letter: Letter
    let run: CompilerRun?
    let voice: String
    let docId: String
    let store: ProjectStore?
    let world: DeclaredWorldStore?
    /// The posture of any `(kind, scope)` statement the letter's offers file
    /// into (P3c Task 7) — the drawing door.
    let postureOf: (Statement.Kind, Statement.Scope) -> Posture
    let currentText: (String) -> String?
    let onJump: (String) -> Void
    /// `nil` where the host offers no task (posture, or not the open piece).
    let onAcceptExercise: ((Letter.Habit) -> Void)?
    @Binding var turnClauseFiledForRun: String?
    @Binding var offerFailure: String?
    @Binding var keptLetter: LetterKeep.Kept?
    @Binding var keepFailure: String?
    @Binding var ledgerFailure: String?
    /// Bumped by a ledger write so the ledger text re-reads; nothing else
    /// observes it.
    @Binding var ledgerRevision: Int
    /// Where Add to intent, Keep as lesson or *These are all choices* filed
    /// (shell plan 3 Task 6).
    var onFiledUnder: (FiledDestination) -> Void = { _ in }

    var body: some View {
        let ledger = ledgerHandlers()
        LetterSection(
            letter: letter,
            // **The run, so an accepted exercise is forgotten with it.**
            runId: run?.id,
            signature: LetterSection.signature(
                voice: voice, round: run?.round,
                // The stage off the SAME letter `shortLetterPart` reads.
                stage: letter.draftStage),
            currentText: currentText,
            onJump: onJump,
            onAcceptExercise: onAcceptExercise,
            onAddTurnClause: turnClauseOffer(),
            // The tense follows the scope the ruling will be filed at, and
            // both come from the same builder.
            addToIntentTitle: TurnClauseOffer.buttonTitle(store: store, docId: docId),
            // **Keep files a research note, and the router decides where**
            // (`LetterKeep`, spec §3.6).
            onKeep: LetterKeep.handler(
                letter: letter, run: run, docId: docId, store: store,
                editorName: voice,
                onKept: { keptLetter = $0 },
                onFailure: { keepFailure = $0 }),
            offerFailure: offerFailure,
            keepConfirmation: LetterKeep.confirmation(for: keptLetter, run: run),
            keepFailure: keepFailure,
            // **The ledger, from one builder** (`LessonOffer.handlers`).
            ledgerText: ledger.ledgerText,
            // **A stated fact, not one inferred from the wiring.**
            freshEyes: run?.freshEyes == true,
            onKeepAsLesson: ledger.onKeepAsLesson,
            onAllChoices: ledger.onAllChoices,
            onRetire: ledger.onRetire,
            ledgerFailure: ledgerFailure)
    }

    /// The ledger's four inputs, from the one builder.
    private func ledgerHandlers() -> LessonLedgerHandlers {
        _ = ledgerRevision
        return LessonOffer.handlers(
            letter: letter, run: run, store: store, world: world,
            voice: voice,
            postureOf: postureOf,
            onFiled: { ledgerRevision += 1 },
            onFailure: { ledgerFailure = $0 },
            filedUnder: onFiledUnder)
    }

    /// The offer, decided and written by `TurnClauseOffer`.
    private func turnClauseOffer() -> (() -> Void)? {
        TurnClauseOffer.handler(
            letter: letter, run: run, docId: docId, store: store, world: world,
            voice: voice,
            filedRunId: turnClauseFiledForRun,
            postureOf: postureOf,
            onFiled: { turnClauseFiledForRun = $0 },
            onFailure: { offerFailure = $0 },
            filedUnder: onFiledUnder)
    }
}

// MARK: - The pass-order nudge's row (moved from `AnnotationsPaneStrips`)

/// **The advisory nudge's row** (pass-order nudge gains its verbs) — its own
/// view so its width is measurable (`ResolveColumnWidthTests`). The
/// host supplies the pass and the two closures
/// (`ResolveHead.passOrderNudgeDecision`); this struct owns no store and
/// calls neither closure itself.
///
/// The buttons say only "Mark done" / "Skip": the caption already names the
/// pass (`PassOrderAdvice.caption(for:)`).
@MainActor
struct PassOrderNudgeRow: View {
    let pass: ReviewPass
    /// `nil` where this Mac may not rule on the piece's passes
    /// (`PassLadder.offersRulings(under:)`): the caption draws alone.
    let onMarkDone: (() -> Void)?
    let onSkip: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle").font(.caption2)
            Text(PassOrderAdvice.caption(for: pass))
                .font(.caption2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let onMarkDone {
                Button("Mark done", action: onMarkDone)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
            if let onSkip {
                Button("Skip", action: onSkip)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}
