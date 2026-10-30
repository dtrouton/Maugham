import SwiftUI
import MaughamCore

/// **`AnnotationsPane`'s verbs** — every press that writes a note, the ledger
/// or the pane's own state, over bindings to the pane's `@State`.
///
/// Built fresh per call by `AnnotationsPane.verbs` and never stored (the
/// CanvasView split's shape): a binding writes the same storage the pane
/// writes, so nothing is copied and nothing is synchronised. The pane's own
/// lens reads (`projectSnapshot`, `visibleAnnotations`, `effectiveSelection`)
/// arrive as closures, so a read after an `await` is the pane's live answer.
@MainActor
struct AnnotationsPaneVerbs {
    let store: ProjectStore
    let documentStore: DocumentStore
    let world: DeclaredWorldStore?
    let userPreferences: UserPreferences
    let undoManager: UndoManager?
    let onChoiceOfferChanged: (ChoiceOffer?) -> Void
    let projectSnapshot: () -> ProjectAnnotationsSnapshot
    let visibleAnnotations: (Document) -> [Annotation]
    let effectiveSelection: ([Annotation]) -> Set<String>
    @Binding var staleConfirm: AnnotationsPane.AnnotationTarget?
    @Binding var anchorLostNotice: AnnotationsPane.AnnotationTarget?
    @Binding var revertConfirm: AnnotationsPane.AnnotationTarget?
    @Binding var rulingNotice: String?
    @Binding var ledgerNotice: String?
    @Binding var choiceOffer: ChoiceOffer?
    @Binding var stetFlourishIds: Set<String>
    @Binding var bulkInFlight: Bool
    @Binding var selectedIds: Set<String>
    @Binding var bulkNotice: String?
    @Binding var letterLedgerRevision: Int
    @Binding var projectRefreshToken: Int

    /// Run one verb over the planned ids.
    ///
    /// **No undo group wraps this** (ADR 0023's D1 corollary): a group would
    /// have to cover accept, and `Document.acceptAnnotation` calls
    /// `removeAllActions` from inside itself. Each note registers its own undo
    /// action instead; `NSUndoManager`'s event grouping then coalesces the
    /// batch, so one ⌘Z reverses it — which is what one deliberate click should
    /// cost. The accepted consequence is accept's own: each SUGGESTION accept
    /// wipes the previous registrations, so after a bulk accept only the LAST
    /// suggestion is reachable by ⌘Z and the rest need a row's Revert. The
    /// Accept button's tooltip says so; `AnnotationBulkActionsTests` pins it.
    /// It stays true of a mixed batch because `AnnotationBulkActions.plan`
    /// sorts suggestions ahead of textless notes, so the wipes land before any
    /// comment registers — see that function's doc for why the alternative left
    /// an accepted comment reachable by nothing at all.
    func runBulk(
        _ verb: AnnotationBulkActions.BulkVerb, on ids: [String],
        in document: Document
    ) {
        guard !ids.isEmpty, !bulkInFlight else { return }
        bulkInFlight = true
        // The same flourish a single Stet wears, at scale: the rows stay put
        // for ~2.5s wearing the proofreader's mark before they resolve out of
        // the open list, so the writer sees what they just did.
        if verb == .stet { stetFlourishIds.formUnion(ids) }
        Task {
            let outcome = await AnnotationBulkActions.perform(
                verb, on: ids, in: document, undoManager: undoManager,
                mayWrite: mayWriteText(document))
            bulkInFlight = false
            noteChanged()
            // Selection hygiene: the run may have taken its own rows off
            // screen. Prune to what is still visible rather than leaving ticks
            // pointing at nothing.
            selectedIds = effectiveSelection(visibleAnnotations(document))
            if let notice = outcome.notice { bulkNotice = notice }
            if verb == .stet {
                // Drop the mark from anything that did NOT stet immediately:
                // the flourish says "this note has been let stand", and a row
                // wearing it for 2.5s over a note that is still open is the
                // surface lying about what happened.
                stetFlourishIds.subtract(
                    Set(ids).subtracting(outcome.succeeded))
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                stetFlourishIds.subtract(outcome.succeeded)
            }
        }
    }

    // MARK: - The verbs
    //
    // Every one of them takes the document EXPLICITLY. In project scope the
    // row's document is not the pane's own, and a verb that reached for
    // `self.document` would answer a note about Chapter Nine by editing
    // whatever happens to be centred. The pane's own document is just the
    // argument document scope passes.
    //
    // Every one of them also calls `noteChanged()` when its work lands — see
    // `projectRefreshToken`. `AnnotationScopeTests` keeps the two together.

    func accept(_ document: Document, _ ann: Annotation) {
        if ann.kind == .suggestedChange && ann.isStale {
            staleConfirm = AnnotationsPane.AnnotationTarget(document: document, annotation: ann)
            return
        }
        Task { await performAccept(document, ann) }
    }

    /// The window's yield-aware answer for a text-writing disposition (#79):
    /// a suggestion's accept, its Revert, and their ⌘Z/⇧⌘Z re-ask it, because
    /// only the posture knows the yield (Ruling U) and Edit Anyway. Weak, as
    /// the undo stack outlives the pane.
    private func mayWriteText(_ document: Document) -> @MainActor () -> Bool {
        let docId = document.docId
        let store = documentStore
        return { [weak store] in
            store?.posture(forDocId: docId).allows(.writeText) ?? false
        }
    }

    /// The one accept executor for suggestion-capable paths: a refusal for a
    /// lost span anchor (RULING-5) is surfaced, never swallowed — `try?` here
    /// would be the M5-AN-050 silence back again.
    func performAccept(_ document: Document, _ ann: Annotation) async {
        do {
            try await document.acceptAnnotation(
                id: ann.id, undoManager: undoManager,
                mayWrite: mayWriteText(document))
        } catch let error as AnnotationAcceptError where error == .suggestionAnchorLost {
            anchorLostNotice = AnnotationsPane.AnnotationTarget(document: document, annotation: ann)
        } catch {
            documentLog.error("acceptAnnotation failed for \(ann.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        noteChanged()
    }

    /// Reply to a query — an accept carrying the writer's words.
    func replyToQuery(
        _ document: Document, _ ann: Annotation, reply: String
    ) {
        Task {
            try? await document.acceptAnnotation(
                id: ann.id, userResponse: reply, undoManager: undoManager,
                mayWrite: mayWriteText(document))
            noteChanged()
        }
    }

    /// Answer a question as doctrine — the ruling and the reply on the thread,
    /// from one sentence.
    ///
    /// **Routed by the same one decision the control was drawn from**
    /// (`RulingDestination.offered`), rather than by a second `if` here: a
    /// button that appeared for one reason and a commit that filed for another
    /// is exactly the drift the shared destination exists to make impossible.
    /// A press that reaches here over a note offered neither refuses in words
    /// rather than guessing a destination — an answer filed under a statement
    /// the note does not belong to is checked against the wrong reader from
    /// then on, silently.
    ///
    /// The refusal is surfaced rather than logged: unlike a reply, this act can
    /// land half-done, and a writer who is not told would answer again and mint
    /// a second ruling for a decision already filed.
    func answerAsRuling(
        _ document: Document, _ ann: Annotation, answer: String
    ) {
        Task {
            switch RulingDestination.offered(for: ann, manifest: store.manifest) {
            case .editionBrief:
                rulingNotice = await QueryRuling.commit(
                    answer, answering: ann, in: document, store: store,
                    undoManager: undoManager)
            case .firstReader:
                rulingNotice = await FirstReaderRuling.commit(
                    answer, answering: ann, in: document, store: store,
                    undoManager: undoManager)
            case nil:
                rulingNotice = RulingDestination.noDestinationRefusal
            }
            noteChanged()
        }
    }

    func reject(_ document: Document, _ ann: Annotation, reason: String) {
        Task {
            try? await document.rejectAnnotation(
                id: ann.id, userResponse: reason, undoManager: undoManager)
            noteChanged()
        }
    }

    /// **Stet, or the offer that a second one raises** (editorial letter P2
    /// Task 8, spec §6).
    ///
    /// Once is a note let stand. Twice on the same habit is a pattern, and the
    /// app *asks* at that point — it never files on its own, because the ledger
    /// moves only by the writer's hand. Everything else, including a first stet
    /// and any stet of a note carrying no heading, is the plain stet below,
    /// unchanged.
    ///
    /// **The twin is looked for across the PROJECT, in both scopes** (P3 Task
    /// 8, Denver's ruling A) — the ledger a press may file into is
    /// project-scope, and a habit shown once in each of two chapters is the
    /// pattern the second stet is about. The cost is one read of the cached
    /// project snapshot at the press, which is where a read the writer is
    /// waiting on can be afforded; the walk itself is `projectSnapshot`'s and
    /// is already paid for whenever project scope is up.
    func stet(_ document: Document, _ ann: Annotation) {
        if let heading = QueueLedgerVerbs.secondStetOffer(
            for: ann, among: projectSnapshot().annotations.map(\.annotation),
            ledgerText: LessonLedgerVerbs.ledgerText(store: store)) {
            setChoiceOffer(ChoiceOffer(
                annotationId: ann.id, heading: heading,
                makeItAChoice: {
                    setChoiceOffer(nil)
                    performChoice(document, ann)
                },
                justStet: {
                    setChoiceOffer(nil)
                    performStet(document, ann)
                },
                cancel: { setChoiceOffer(nil) }))
            return
        }
        performStet(document, ann)
    }

    /// The one place the offer is raised and dropped, so the alert's state and
    /// the witness cannot come apart.
    func setChoiceOffer(_ offer: ChoiceOffer?) {
        choiceOffer = offer
        onChoiceOfferChanged(offer)
    }

    /// Stet — the proofreader's own gesture, and now the only one that wears the
    /// proofreader's mark. The op is recorded immediately (never blocked); the
    /// flag holds the row on-screen ~2.5s so the STET badge and the reinstated
    /// text read clearly before the row resolves out of the open list.
    private func performStet(_ document: Document, _ ann: Annotation) {
        stetFlourishIds.insert(ann.id)
        Task {
            try? await document.stetAnnotation(id: ann.id, undoManager: undoManager)
            noteChanged()
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            stetFlourishIds.remove(ann.id)
        }
    }

    /// **This is a choice** — the ledger row and the stet, in that order
    /// (`QueueLedgerVerbs.makeChoice`, which owns both the ordering and the two
    /// refusal sentences).
    ///
    /// The flourish plays exactly as it does for a plain stet: what the writer
    /// did to the note is the same thing, and a choice that resolved a row with
    /// no STET mark would read as a different verb.
    ///
    /// `letterLedgerRevision` moves because the ledger did — the letter's own
    /// Keep and Retire offers are computed against `ledgerText`, and without
    /// this a habit just filed as a choice still draws a Keep button.
    func performChoice(_ document: Document, _ ann: Annotation) {
        stetFlourishIds.insert(ann.id)
        Task {
            let refusal = await QueueLedgerVerbs.makeChoice(
                ann, in: document, store: store, world: world,
                undoManager: undoManager)
            ledgerNotice = refusal
            letterLedgerRevision += 1
            noteChanged()
            // **A refusal takes the mark off at once** — `runBulk`'s own guard,
            // for its reason: the flourish says "this note has been let
            // stand", and a row wearing it for 2.5s over a note that is still
            // open is the surface lying about what happened. Sleeping first
            // would put the lie on screen for exactly as long as the truth.
            guard refusal == nil else {
                stetFlourishIds.remove(ann.id)
                return
            }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            stetFlourishIds.remove(ann.id)
        }
    }

    /// **Keep as lesson…** — the writer's shortened sentence, filed. No
    /// annotation op: the note is already accepted, and this is a second,
    /// independent act (`QueueLedgerVerbs.keepAsLesson`).
    func keepAsLesson(_ ann: Annotation, heading: String) {
        Task {
            ledgerNotice = await QueueLedgerVerbs.keepAsLesson(
                heading, from: ann, store: store, world: world)
            letterLedgerRevision += 1
        }
    }

    /// Mark (or clear) what the writer plans to do about a note. Not a
    /// resolution — the row stays exactly as open as it was; only its place in
    /// the queue moves.
    func triage(_ document: Document, _ ann: Annotation, mark: TriageMark?) {
        Task {
            try? await document.triageAnnotation(
                id: ann.id, mark: mark, undoManager: undoManager)
            noteChanged()
        }
    }

    func archive(_ document: Document, _ ann: Annotation) {
        Task {
            try? await document.archiveAnnotation(id: ann.id, undoManager: undoManager)
            noteChanged()
        }
    }

    /// RULING-29's verb, and RULING-34's Restore — one spelling, taking an id
    /// because a withdrawn note is not in the projection to be passed whole.
    /// Extracted from the row's closure so the refresh census can see it; the
    /// `reopenAnnotation` caller census is unmoved, since this is the same file
    /// it already names. Restore reaches the undo-manager overload where it
    /// used to call the bare one, which changes nothing: that overload
    /// registers a ⌘Z pair only for a rejected / archived / stetted note and
    /// falls through un-registered for a withdrawn one, which is all Restore
    /// ever passes it.
    func reopen(_ document: Document, id: String) {
        Task {
            do {
                try await document.reopenAnnotation(id: id, undoManager: undoManager)
            } catch {
                AnnotationsPane.sayRefused(error, in: document)
            }
            noteChanged()
        }
    }

    /// Revert an accepted suggestion from the pane (visible under the
    /// resolved/All filter). Reaches accepts ⌘Z can't — ⌘Z only undoes the
    /// most recent one. Gated behind a confirm when the paragraph drifted
    /// since the accept (revert restores the PRE-accept text, clobbering the
    /// intervening edits) — mirror of the accept path's `staleConfirm` gate.
    /// Only THIS pane button gates: the ⌘Z undo closure calls
    /// `revertAcceptedAnnotation` directly (undo of an immediately-prior
    /// action needs no confirm).
    func revert(_ document: Document, _ ann: Annotation) {
        if document.acceptedTextDrifted(annotationId: ann.id) {
            revertConfirm = AnnotationsPane.AnnotationTarget(document: document, annotation: ann)
            return
        }
        performRevert(document, ann)
    }

    /// Passing the window's undo manager makes the revert itself ⌘Z-undoable
    /// (re-accept, original reply preserved).
    func performRevert(_ document: Document, _ ann: Annotation) {
        Task {
            try? await document.revertAcceptedAnnotation(
                id: ann.id, undoManager: undoManager,
                mayWrite: mayWriteText(document))
            noteChanged()
        }
    }

    /// Author self-service edit of one's own annotation. The pane updates via
    /// `annotationsVersion`; the notification refreshes the key-window editor's
    /// crafted marks immediately (mirrors the create-case refresh).
    func editOwn(
        _ document: Document, _ ann: Annotation,
        newBody: String, newSuggested: String?
    ) {
        Task {
            try? await document.editReviewerAnnotation(
                id: ann.id,
                newBody: newBody,
                newSuggestedText: newSuggested,
                authorName: userPreferences.collaboratorDisplayName,
                undoManager: undoManager)
            noteChanged()
            // No explicit editor notify: the edit bumps `annotationsVersion` on
            // the shared Document, which EditorHost mirrors into the control model
            // → `applyControl` → `setReviewAnnotations`, recomputing crafted marks
            // automatically (ADR 0017).
        }
    }

    /// Author self-service withdraw (delete) of one's own annotation.
    func withdrawOwn(_ document: Document, _ ann: Annotation) {
        Task {
            try? await document.withdrawReviewerAnnotation(
                id: ann.id,
                authorName: userPreferences.collaboratorDisplayName,
                undoManager: undoManager)
            noteChanged()
        }
    }

    /// Something changed under a row. Bumps the token `projectSnapshot` is
    /// keyed on, so the cross-document queue re-reads a walk nothing else
    /// observes (see `projectRefreshToken`). Cheap and unconditional: it costs
    /// one integer in document scope, where nothing reads it.
    func noteChanged() {
        projectRefreshToken &+= 1
    }
}
