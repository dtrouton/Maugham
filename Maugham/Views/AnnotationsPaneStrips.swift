import SwiftUI
import MaughamCore

// MARK: - The round cockpit (M4 P2 Task 3)

/// **`AnnotationsPane`'s round cockpit** — the mount, the reads it draws from
/// and the letter it discloses. Every value comes in from the pane; the
/// letter's own state is the pane's, reached through bindings.
@MainActor
struct AnnotationsRoundCockpit: View {
    let scope: AnnotationScope
    let document: Document?
    let store: ProjectStore
    let documentStore: DocumentStore
    let orchestrator: CompilerOrchestrator?
    let diagnostics: DiagnosticsStore?
    let world: DeclaredWorldStore?
    let reviewPasses: [ReviewPass]
    /// `AnnotationsPane.cockpitActivePass` — the piece's RECORDED active pass.
    let cockpitActivePass: ReviewPass?
    let onSetActivePass: (String, String) -> Void
    let compilerModel: CompilerModelChoice
    let onCompilerModelChange: (CompilerModelChoice) -> Void
    let undoManager: UndoManager?
    let onJumpToParagraph: (String) -> Void
    @Binding var turnClauseFiledForRun: String?
    @Binding var letterOfferFailure: String?
    @Binding var keptLetter: LetterKeep.Kept?
    @Binding var letterKeepFailure: String?
    @Binding var letterLedgerFailure: String?
    @Binding var letterLedgerRevision: Int

    var body: some View { roundCockpit }

    /// **The strip that says where the reviewer is and offers the next round**
    /// — `ReviewRoundCockpit`, mounted below the toolbar's divider and above
    /// the nudge (spec §7).
    ///
    /// **Not in the toolbar, and that is structural rather than aesthetic.**
    /// `AnnotationsQueueToolbar`'s one job is fitting a column whose floor is
    /// 240pt, and `AnnotationsQueueToolbarWidthTests` measures the row as
    /// declared; a control added there would inflate the pane's layout width
    /// and centre every annotation body against a width the column does not
    /// have — the exact defect that suite was written for.
    ///
    /// **Document scope only.** The strip is a statement about ONE piece's
    /// pass, round and next run; in project scope every section is a different
    /// piece with different answers, and a single strip there could only be
    /// wrong (`passOrderNudge` refuses the same way for the same reason).
    ///
    /// A `nil` orchestrator or store draws nothing: this pane serves hosts
    /// with no compiler behind them.
    @ViewBuilder
    private var roundCockpit: some View {
        if !scope.isProject, let document, let orchestrator, let diagnostics {
            // **The seat is not read here at all** (two loops P1 Task 8).
            // The coach reads CHECKS, in Author (`AuthorReader`); a round is
            // the piece's own stage editor's or it is refused
            // (`RoundEditor`), so every value this strip draws — the lane
            // label, the round it counts, the round the buttons offer —
            // comes from `cockpitActivePass` and nothing else.
            let pass = cockpitActivePass
            ReviewRoundCockpit(
                passes: reviewPasses,
                activePassId: pass?.id,
                // **The piece's own lane, or none.** `latestRound` is asked
                // about a LANE id, and a piece with no stage set is in no
                // lane: nothing has filed a round on it, because a round with
                // no editor is refused before it starts.
                round: cockpitRound(diagnostics, docId: document.docId,
                                    passId: pass?.id),
                // A round on another piece is named by its manifest title
                // (#83) — a pure lookup over the store this pane holds.
                phase: ReviewRoundCockpit.phase(
                    runState: orchestrator.runState, docId: document.docId,
                    titleOf: { RoundNarrative.pieceTitle(
                        of: $0, in: store.manifest.structure) }),
                reportLine: cockpitReportLine(diagnostics, docId: document.docId),
                // **The live round's clock** (spec 2026-09-09 §5): the strip
                // draws the wait, and the orchestrator is the one thing that
                // knows when it started and how far it has got.
                runSince: orchestrator.runStartedAt,
                runProgress: orchestrator.runProgress,
                // The timing of the round the line above was built from, so
                // the tooltip behind it describes that same turn.
                reportTiming: cockpitReportTiming(diagnostics, docId: document.docId),
                // **The round cockpit's own button, and it is a round by
                // construction** (two loops P1) — this surface exists only in
                // Review. Said literally rather than minted from a persona,
                // because the only persona it could read is the one it is
                // already standing in.
                //
                // **Not drawn where this Mac may not run a round on the piece**
                // (P3c Task 6, plan ruling R4) — the piece's own drawing
                // posture; the orchestrator's door asks the settled one.
                onRun: documentStore.posture(forDocId: document.docId)
                    .allows(.runRound)
                    ? { freshEyes in
                        orchestrator.runRequested(
                            docId: document.docId, kind: .round, freshEyes: freshEyes)
                    }
                    : nil,
                onSetActivePass: { passId in
                    onSetActivePass(document.docId, passId)
                },
                onCancel: { orchestrator.cancel() },
                compilerModel: compilerModel,
                onCompilerModelChange: onCompilerModelChange,
                // **The letter, in one line with the whole of it behind a
                // disclosure** (spec §3.5). The line comes from the strip's
                // own static so Author and Review cannot disagree about what
                // it says; the disclosure opens the SAME `LetterSection`
                // Author draws, wired to this pane's document and project.
                letterLine: ReviewRoundCockpit.letterLine(
                    cockpitLetter(diagnostics, docId: document.docId)),
                letterDisclosure: cockpitLetter(diagnostics, docId: document.docId)
                    .map { letter in
                        { AnyView(letterSection(letter, document: document,
                                                diagnostics: diagnostics)) }
                    },
                // **The same field Author's header carries, over the ROUND's
                // own per-document value** (spec §3.7; per tempo as of two
                // loops P1 Task 6). The strip holds no store, so the commit
                // arrives as a closure — `AskField.commit` is the one
                // spelling of it, so neither home can refuse a long ask in
                // different words. `kind: .round` is what keeps this an
                // independent sentence from the one Author's header reads
                // and writes for the same document.
                ask: AskField.Input(
                    docId: document.docId,
                    kind: .round,
                    text: cockpitAsk(diagnostics, docId: document.docId),
                    commit: { text in
                        AskField.commit(text, docId: document.docId,
                                        kind: .round, diagnostics: diagnostics)
                    },
                    note: { text, doc in
                        AskField.note(text, docId: doc, kind: .round, diagnostics: diagnostics)
                    }))
            Divider()
        }
    }

    /// The lane's newest round number. `latestRound` consults the standing run
    /// before the ring — the ONE spelling of "which round is this lane on",
    /// shared with the round mint, so the strip and the run cannot disagree.
    private func cockpitRound(
        _ diagnostics: DiagnosticsStore, docId: String, passId: String?
    ) -> Int? {
        _ = diagnostics.version
        return diagnostics.latestRound(forPass: passId, docId: docId)
    }

    /// The writer's standing ask for this piece, version-gated exactly as
    /// every other read of the sidecar here is — so a commit made in Author's
    /// header is what this field shows.
    private func cockpitAsk(
        _ diagnostics: DiagnosticsStore, docId: String
    ) -> String? {
        _ = diagnostics.version
        return diagnostics.ask(docId: docId, kind: .round)
    }

    /// The standing run's letter for this piece, version-gated exactly as
    /// every other read of the sidecar here is. `nil` for no run, no letter,
    /// or a letter with nothing in it — `ReviewRoundCockpit.letterLine` makes
    /// the same judgement about emptiness, and this feeds both the line and
    /// the disclosure so they can never disagree about whether there is one.
    private func cockpitLetter(
        _ diagnostics: DiagnosticsStore, docId: String
    ) -> Letter? {
        _ = diagnostics.version
        guard let letter = diagnostics.lastRound(docId: docId)?.letter,
              !letter.isEmpty else { return nil }
        return letter
    }

    private func letterVoice(_ run: CompilerRun?) -> String {
        AnnotationsPane.letterVoice(run: run, passes: reviewPasses)
    }

    /// **The disclosure's contents: Author's own section, in Review's
    /// column.** Every verb is this pane's — the jump is its event, the task
    /// is its document, the ruling is its project — so the reviewer can act on
    /// the letter without leaving the queue.
    @ViewBuilder
    private func letterSection(
        _ letter: Letter, document: Document, diagnostics: DiagnosticsStore
    ) -> some View {
        let run = diagnostics.lastRound(docId: document.docId)
        let ledger = ledgerHandlers(letter, run: run)
        LetterSection(
            letter: letter,
            // **The run, so an accepted exercise is forgotten with it** \u{2014}
            // an index means nothing outside one letter (final review).
            runId: run?.id,
            signature: LetterSection.signature(
                voice: letterVoice(run),
                // The stage off the SAME letter `shortLetterPart` reads (fix
                // round 1, minor 2), never a second path through the run.
                round: run?.round, stage: letter.draftStage),
            currentText: { document.paragraphs[$0] },
            onJump: { onJumpToParagraph($0) },
            // Ruling U (P3c Task 8): filed only where THIS document's posture
            // takes a task — hidden otherwise.
            onAcceptExercise: !documentStore.posture(forDocId: document.docId)
                .allows(.task) ? nil : { habit in
                document.createPaneTask(
                    body: habit.exercise ?? habit.name,
                    parentTaskId: nil,
                    paragraphId: habit.refs.first?.paragraphId,
                    undoManager: undoManager)
            },
            onAddTurnClause: turnClauseOffer(letter, run: run, docId: document.docId),
            // The tense follows the scope the ruling will be filed at, and
            // both come from the same builder.
            addToIntentTitle: TurnClauseOffer.buttonTitle(
                store: store, docId: document.docId),
            // **The same verb Author's pane presses** (`LetterKeep`, spec
            // §3.6): one render, one scope, one router — so a letter kept from
            // the queue and a letter kept from the report are the same note.
            onKeep: LetterKeep.handler(
                letter: letter, run: run, docId: document.docId, store: store,
                editorName: letterVoice(run),
                onKept: { keptLetter = $0 },
                onFailure: { letterKeepFailure = $0 }),
            offerFailure: letterOfferFailure,
            keepConfirmation: LetterKeep.confirmation(for: keptLetter, run: run),
            keepFailure: letterKeepFailure,
            // **The same builder Author's pane calls** (`LessonOffer.handlers`,
            // P2 Task 7): one provenance, one date, one refusal channel — so a
            // lesson kept from the queue and a lesson kept from the report are
            // the same row, filed the same way.
            ledgerText: ledger.ledgerText,
            freshEyes: run?.freshEyes == true,
            onKeepAsLesson: ledger.onKeepAsLesson,
            onAllChoices: ledger.onAllChoices,
            onRetire: ledger.onRetire,
            ledgerFailure: letterLedgerFailure)
    }

    /// **The ledger's four inputs, from the one builder both hosts call.** The
    /// provenance and the date live there; this supplies the queue's own
    /// voice, its own store and its own re-read.
    private func ledgerHandlers(
        _ letter: Letter, run: CompilerRun?
    ) -> LessonLedgerHandlers {
        // Read so the ledger text below is re-derived once a write lands —
        // see `letterLedgerRevision`, which nothing else observes.
        _ = letterLedgerRevision
        return LessonOffer.handlers(
            letter: letter, run: run, store: store, world: world,
            voice: letterVoice(run),
            postureOf: postureOfAnyStatement(_:_:),
            onFiled: { letterLedgerRevision += 1 },
            onFailure: { letterLedgerFailure = $0 })
    }

    /// **The offer, decided and written by `TurnClauseOffer`** — the one
    /// builder Author's Diagnostics pane calls too (fix round 1, Minor 4).
    /// The predicate and the ruling live there; this supplies the queue's own
    /// values and its own refusal channel.
    private func turnClauseOffer(
        _ letter: Letter, run: CompilerRun?, docId: String
    ) -> (() -> Void)? {
        TurnClauseOffer.handler(
            letter: letter, run: run, docId: docId, store: store, world: world,
            voice: letterVoice(run),
            filedRunId: turnClauseFiledForRun,
            postureOf: postureOfAnyStatement(_:_:),
            onFiled: { turnClauseFiledForRun = $0 },
            onFailure: { letterOfferFailure = $0 })
    }

    private func cockpitReportLine(
        _ diagnostics: DiagnosticsStore, docId: String
    ) -> String? {
        _ = diagnostics.version
        return ReviewRoundCockpit.reportLine(
            history: diagnostics.roundHistory(docId: docId),
            run: diagnostics.lastRound(docId: docId),
            annotations: cockpitAnnotations, passes: reviewPasses)
    }

    /// **The run `cockpitReportLine` was resolved from**, so the tooltip and
    /// the line cannot describe different turns. Same read, same gate on
    /// `version`.
    private func cockpitReportTiming(
        _ diagnostics: DiagnosticsStore, docId: String
    ) -> RunTiming? {
        _ = diagnostics.version
        return diagnostics.lastRound(docId: docId)?.timing
    }

    /// **The document's queue in EVERY state** — what the since-last-round
    /// line is counted from, and never the pane's visible rows.
    ///
    /// The rows on screen are filtered by kind, status, author, triage and
    /// pass. Counting those would make "resolved" permanently zero under the
    /// default `[.open]` filter and would skew all three numbers under any
    /// other — a number the writer is trusting, quietly wrong. The status
    /// filtering the line needs is `SinceLastRound`'s own.
    ///
    /// Gated on `annotationsVersion` on this pane's own idiom, so a note the
    /// writer stets in the queue moves the sentence rather than leaving it
    /// stale until the next round.
    private var cockpitAnnotations: [Annotation] {
        guard let document else { return [] }
        _ = document.annotationsVersion
        return document.annotations(filter: AnnotationFilter(statuses: nil))
    }

    /// The posture of any `(kind, scope)` statement the letter's offers file
    /// into (P3c Task 7) — the drawing door, at the ruling door's own id.
    private func postureOfAnyStatement(
        _ kind: Statement.Kind, _ scope: Statement.Scope
    ) -> Posture {
        documentStore.posture(
            ofStatement: kind, scope: scope, statements: store.manifest.statements)
    }
}

// MARK: - The pass-order nudge's row

@MainActor
/// **The advisory nudge's row** (pass-order nudge gains its verbs) — extracted
/// as its own view, the way `AnnotationRow` and `AnnotationsQueueToolbar` are,
/// so its width is measurable the same way theirs is
/// (`AnnotationsQueueToolbarWidthTests`). `AnnotationsPane.passOrderNudge` is a
/// thin wrapper supplying the pass and the two closures; this struct owns no
/// store and calls neither closure itself — pressing a button is the
/// writer's, not the row's.
///
/// The two buttons say only "Mark done" / "Skip" rather than repeating the
/// pass's name: the caption beside them already names it (`PassOrderAdvice.
/// caption(for:)`), and there is only ever one earlier open pass to act on,
/// so a second naming of it would be the row arguing with itself about which
/// word is load-bearing.
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
