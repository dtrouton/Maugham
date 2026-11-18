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
    /// the nudge (spec §7), through `RoundCockpitMount` (moved to
    /// `Resolve/ResolveHead.swift`, shell plan 2 Task 5, so To resolve's head
    /// mounts the one spelling).
    ///
    /// **Not in the toolbar, and that is structural rather than aesthetic.**
    /// `AnnotationsQueueToolbar`'s one job is fitting a column whose floor is
    /// 240pt, and `AnnotationsQueueToolbarWidthTests` measures the row as
    /// declared.
    ///
    /// **Document scope only.** The strip is a statement about ONE piece's
    /// pass, round and next run; in project scope every section is a different
    /// piece with different answers.
    ///
    /// A `nil` orchestrator or store draws nothing: this pane serves hosts
    /// with no compiler behind them.
    @ViewBuilder
    private var roundCockpit: some View {
        if !scope.isProject, let document, let orchestrator, let diagnostics {
            RoundCockpitMount(
                docId: document.docId, store: store, orchestrator: orchestrator,
                diagnostics: diagnostics, reviewPasses: reviewPasses,
                activePass: cockpitActivePass,
                annotations: cockpitAnnotations,
                // **The round cockpit's own button, and it is a round by
                // construction** (two loops P1). Not drawn where this Mac may
                // not run a round on the piece (P3c Task 6, plan ruling R4).
                // This old queue keeps calling the orchestrator until shell
                // plan 2 Task 7 deletes it; To resolve's head posts the command.
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
                compilerModel: compilerModel,
                onCompilerModelChange: onCompilerModelChange,
                // **The letter, in one line with the whole of it behind a
                // disclosure** (spec §3.5): the SAME `RunLetterSection` the
                // check's letter is drawn by, wired to this pane's document.
                letter: cockpitLetter(diagnostics, docId: document.docId),
                letterDisclosure: cockpitLetter(diagnostics, docId: document.docId)
                    .map { letter in
                        { AnyView(letterSection(letter, document: document,
                                                diagnostics: diagnostics)) }
                    })
            Divider()
        }
    }

    /// The standing run's letter for this piece, version-gated. `nil` for no
    /// run, no letter, or a letter with nothing in it.
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

    /// **The disclosure's contents: the one letter host, in Review's
    /// column.** The jump is this pane's event, the task is its document, the
    /// ruling is its project.
    @ViewBuilder
    private func letterSection(
        _ letter: Letter, document: Document, diagnostics: DiagnosticsStore
    ) -> some View {
        let run = diagnostics.lastRound(docId: document.docId)
        RunLetterSection(
            letter: letter, run: run,
            voice: letterVoice(run),
            docId: document.docId, store: store, world: world,
            postureOf: postureOfAnyStatement(_:_:),
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
            turnClauseFiledForRun: $turnClauseFiledForRun,
            offerFailure: $letterOfferFailure,
            keptLetter: $keptLetter,
            keepFailure: $letterKeepFailure,
            ledgerFailure: $letterLedgerFailure,
            ledgerRevision: $letterLedgerRevision)
    }

    /// **The document's queue in EVERY state** — what the since-last-round
    /// line is counted from, and never the pane's visible rows (a `[.open]`
    /// filter would make "resolved" permanently zero). Gated on
    /// `annotationsVersion` (`ResolveHead.everyState`), so a note stetted in
    /// the queue moves the sentence.
    private var cockpitAnnotations: [Annotation]? {
        ResolveHead.everyState(of: document)
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

