import SwiftUI
import MaughamCore

// MARK: - The decisions (pure)

/// **What the head is, for a scope** (shell plan 2, Task 5).
enum ResolveHeadShape: Equatable {
    /// One piece: where it stands, its latest letter, Run.
    case piece(docId: String)
    /// Book or Part: one line counting the pieces with something open.
    case count
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
    /// `AuthorReader` (`DiagnosticsPane`'s rule); a round's is its pass's
    /// editor (`AnnotationsPane.letterVoice`). Neither reads the other's.
    @MainActor
    static func letterVoice(run: CompilerRun, reader: AuthorReader,
                            passes: [ReviewPass]) -> String {
        switch run.effectiveKind {
        case .check: return run.readerName ?? reader.editorName
        case .round: return AnnotationsPane.letterVoice(run: run, passes: passes)
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

    /// **How many pieces have something to resolve**: distinct piece ids
    /// among `items`, within the scope. The Book's own to-dos and figures'
    /// notes are not pieces.
    static func openPieceCount(_ items: [ResolveItem], scope: ResolveScope) -> Int {
        let held = Set(scope.docIds)
        return Set(items.map(\.docId).filter {
            held.contains($0) && $0 != ProjectStore.projectTasksDocId
                && !DocumentClass.isFigureDocId($0)
        }).count
    }

    /// The Book's or a Part's one line.
    static func bookLine(openPieces: Int) -> String {
        switch openPieces {
        case 0: return "Nothing to resolve"
        case 1: return "1 piece has something to resolve"
        default: return "\(openPieces) pieces have something to resolve"
        }
    }

    /// In place of Run on a piece that is not open; its click opens it.
    static let openThePieceLine = "Open the piece to run a check or a round on it."

    /// Open `docId` in the centre — the window's own paragraph navigation,
    /// which opens a piece it does not have (`ManuscriptNavigation`). With a
    /// paragraph, the caret lands there.
    static func go(toDocId docId: String, paragraphId: String? = nil) {
        var payload: [String: String] = [ManuscriptNavigation.docIdKey: docId]
        if let paragraphId { payload["paragraph_id"] = paragraphId }
        MaughamEvent.post(.maughamNavigateToParagraph, to: .keyWindow, payload: payload)
    }
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

    @Environment(\.undoManager) private var undoManager

    @State private var turnClauseFiledForRun: String?
    @State private var offerFailure: String?
    @State private var keptLetter: LetterKeep.Kept?
    @State private var keepFailure: String?
    @State private var ledgerFailure: String?
    @State private var ledgerRevision = 0

    var body: some View {
        switch ResolveHead.shape(scope) {
        case .piece(let docId):
            pieceHead(docId)
        case .count:
            Text(ResolveHead.bookLine(
                openPieces: ResolveHead.openPieceCount(snapshot.items, scope: scope)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 6)
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
                Button {
                    ResolveHead.go(toDocId: docId)
                } label: {
                    Text(ResolveHead.openThePieceLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
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
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            if let nudge = AnnotationsPane.passOrderNudgeDecision(
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
        if let run = ResolveHead.latestLetter(
            check: diagnostics.lastCheck(docId: docId),
            round: diagnostics.lastRound(docId: docId)),
           let letter = run.letter {
            RunLetterSection(
                letter: letter, run: run,
                voice: ResolveHead.letterVoice(run: run, reader: reader, passes: passes),
                docId: docId, store: store, world: world,
                postureOf: { kind, scope in
                    documentStore.posture(
                        ofStatement: kind, scope: scope,
                        statements: store.manifest.statements)
                },
                currentText: { snapshot.paragraphText[$0] },
                onJump: { ResolveHead.go(toDocId: docId, paragraphId: $0) },
                onAcceptExercise: offers.acceptsExercise ? { habit in
                    documentStore.document(forDocId: docId)?.createPaneTask(
                        body: habit.exercise ?? habit.name,
                        parentTaskId: nil,
                        paragraphId: habit.refs.first?.paragraphId,
                        undoManager: undoManager)
                } : nil,
                turnClauseFiledForRun: $turnClauseFiledForRun,
                offerFailure: $offerFailure,
                keptLetter: $keptLetter,
                keepFailure: $keepFailure,
                ledgerFailure: $ledgerFailure,
                ledgerRevision: $ledgerRevision)
            Divider()
        }
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
    /// Ask. The values `DiagnosticsPane` derives, derived the same way from
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
            state: DiagnosticsPane.headerState(
                runState: orchestrator.runState, lastRun: check, noteCount: strains,
                docId: docId, runStartedAt: orchestrator.runStartedAt,
                runProgress: orchestrator.runProgress),
            // The snapshot is the piece's whole open queue, read without a
            // load, so the queue is always visible here.
            wetInk: DiagnosticsPane.wetInkStanding(
                mintedNotes: check?.mintedNotes, queueVisible: true, openNow: openNow),
            visibleQueue: open,
            reviewPasses: passes,
            otherLoopLine: DiagnosticsPane.otherLoopLine(
                runState: orchestrator.runState, docId: docId,
                titleOf: { RoundNarrative.pieceTitle(of: $0, in: store.manifest.structure) }),
            orchestrator: orchestrator, diagnostics: diagnostics, docId: docId,
            reader: reader, store: store,
            compilerModel: compilerModel,
            onCompilerModelChange: onCompilerModelChange,
            onChooseReader: onChooseReader,
            onOpenProjectSettings: onOpenProjectSettings,
            offersReread: offers.runCheck)
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
/// Moved out of `DiagnosticsPane` (the check's letter) and
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
            onFailure: { ledgerFailure = $0 })
    }

    /// The offer, decided and written by `TurnClauseOffer`.
    private func turnClauseOffer() -> (() -> Void)? {
        TurnClauseOffer.handler(
            letter: letter, run: run, docId: docId, store: store, world: world,
            voice: voice,
            filedRunId: turnClauseFiledForRun,
            postureOf: postureOf,
            onFiled: { turnClauseFiledForRun = $0 },
            onFailure: { offerFailure = $0 })
    }
}

// MARK: - The pass-order nudge's row (moved from `AnnotationsPaneStrips`)

/// **The advisory nudge's row** (pass-order nudge gains its verbs) — its own
/// view so its width is measurable (`AnnotationsQueueToolbarWidthTests`). The
/// host supplies the pass and the two closures
/// (`AnnotationsPane.passOrderNudgeDecision`); this struct owns no store and
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
