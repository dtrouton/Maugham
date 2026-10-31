import AppKit
import MaughamCore

// **The suggestion strip's side of the grid controller** (report plan 9c-2
// Tasks 5–6): what the strip shows for the active cell, and its answers —
// Accept (a suggestion, which writes the cell), Got it and Reject — through
// the controller's write chain on `gridUndo`. Tripwire 52 counts this
// file's `acceptSuggestion(` in `manuscriptWriterCallSites`.

extension FigureGridController {

    /// Said when an answer arrives after the grid folded or closed: nothing
    /// was written, and the queue still answers the note.
    static func foldedBeforeTheAnswer(reason: String?) -> String {
        let kept = reason.map { " (your reason: \u{201C}\($0)\u{201D})" } ?? ""
        return "The table was folded, so the note was left as it was\(kept) \u{2014} answer it in the Annotations queue."
    }

    /// Said when the note moved (its cell deleted, the note withdrawn)
    /// between the changed-since refusal and the question.
    static let noLongerAnswerable = "This note can no longer be answered here."

    /// **The strip follows the active cell**: its notes looked up in the
    /// cached `cellNotes` (a filter over the figure's few open live notes —
    /// never the host's projection), its buttons from the gate's mode and
    /// the kept posture. The page goes back to the first on another cell;
    /// an unchanged plan and page leave the view alone.
    func refreshStrip() {
        let active = model.selection?.anchor
        if active != stripCell {
            stripCell = active
            stripPage = 0
        }
        stripPlan = FigureGridStrip.Plan.make(
            notes: cellNotes, active: active, table: values.table, names: names, locale: values.locale,
            mayAccept: notesMayBeAnswered && mode.readOnlyReason == nil, mayReject: notesMayBeAnswered,
            readOnly: mode.readOnlyReason)
        stripPage = min(stripPage, max(0, stripPlan.entries.count - 1))
        showStrip()
    }

    /// The strip's ‹ or ›: the active cell's previous or next note.
    func turnStripPage(by delta: Int) {
        guard !stripPlan.entries.isEmpty else { return }
        stripPage = min(max(stripPage + delta, 0), stripPlan.entries.count - 1)
        showStrip()
    }

    private func showStrip() {
        if let shown = stripShown, shown.plan == stripPlan, shown.page == stripPage { return }
        stripShown = (stripPlan, stripPage)
        strip.show(stripPlan, page: stripPage)
    }

    func stripView(_ view: FigureGridStripView, turnPage delta: Int) {
        turnStripPage(by: delta)
    }

    func stripView(_ view: FigureGridStripView, perform verb: FigureGridStrip.Verb, noteId: String) {
        switch verb {
        case .accept: stripAccept(noteId)
        case .gotIt: stripGotIt(noteId)
        case .reject: askToReject(noteId)
        }
    }

    // MARK: The answers

    /// **Accept a suggestion from the strip**: the open cell edit committed
    /// first, then — in turn behind every write asked before — the host's
    /// `acceptSuggestion` on `gridUndo` (one ⌘Z here; in place it joins the
    /// visit, so the fold's one window step takes it back too). A cell
    /// changed since the suggestion is asked about OUTSIDE the write chain
    /// (`askChangedSince`), so a sheet never holds later writes, a fold or a
    /// close; yes asks for the accept again, no writes nothing.
    func stripAccept(_ noteId: String) {
        guard beginStripAnswer(writesTheCell: true) else { return }
        enqueueAccept(noteId, confirmed: false)
    }

    private func enqueueAccept(_ noteId: String, confirmed: Bool) {
        enqueue { [weak self, host, gridUndo] in
            do {
                try await host.acceptSuggestion(id: noteId, confirmChanged: confirmed, undoManager: gridUndo)
            } catch FigureNoteError.cellChangedSinceSuggestion where !confirmed {
                self?.askAcceptAnyway(noteId)
            }
        }
    }

    /// The changed-since question, asked after the refused write has left
    /// the chain; an accept confirmed after the grid folded or closed is said
    /// and not written.
    private func askAcceptAnyway(_ noteId: String) {
        guard let question = changedQuestion(for: noteId) else {
            MaughamEvent.postNotice(Self.noLongerAnswerable, projectURL: host.projectURL)
            return
        }
        stripQuestion = Task { @MainActor [weak self] in
            guard let self, await self.askChangedSince(question),
                  self.beginStripAnswer(writesTheCell: true) else { return }
            self.enqueueAccept(noteId, confirmed: true)
        }
    }

    /// **Got it from the strip**: a comment's or query's status-only accept,
    /// on `gridUndo`, after the open edit.
    func stripGotIt(_ noteId: String) {
        guard beginStripAnswer(writesTheCell: false) else { return }
        enqueue { [host, gridUndo] in
            try await host.acceptNote(id: noteId, userResponse: nil, undoManager: gridUndo)
        }
    }

    /// **Reject from the strip**, keeping `reason`, on `gridUndo` — undone
    /// by ⌘Z while the grid is open; after an in-place fold by Reopen in the
    /// queue (the visit records cell changes only, plan ruling).
    func stripReject(_ noteId: String, reason: String?) {
        guard beginStripAnswer(writesTheCell: false, keeping: reason) else { return }
        enqueue { [host, gridUndo] in
            try await host.rejectAnnotation(id: noteId, reason: reason, undoManager: gridUndo)
        }
    }

    /// **The strip's Reject button**: the reason asked (`askRejectReason`),
    /// then `stripReject`; a cancelled sheet rejects nothing. A grid that may
    /// not answer says so before asking.
    @discardableResult
    func askToReject(_ noteId: String) -> Task<Void, Never> {
        guard mayAnswer(writesTheCell: false) else { return Task {} }
        let entry = stripPlan.entries.first { $0.noteId == noteId }
        let question = FigureGridStrip.RejectQuestion(heading: entry?.heading ?? "", body: entry?.body ?? "")
        return Task { @MainActor [weak self] in
            guard let self else { return }
            guard case .reject(let reason) = await self.askRejectReason(question) else { return }
            self.stripReject(noteId, reason: reason)
        }
    }

    /// Before a strip answer: caught up, the grid still open (else a
    /// sentence, carrying a typed reason), allowed (`mayAnswer`), the open
    /// cell edit committed (one that will not read stays open with its error,
    /// and nothing is answered).
    private func beginStripAnswer(writesTheCell: Bool, keeping reason: String? = nil) -> Bool {
        syncFromHost()
        guard !isClosed, !isFolded else {
            MaughamEvent.postNotice(Self.foldedBeforeTheAnswer(reason: reason), projectURL: host.projectURL)
            return false
        }
        guard mayAnswer(writesTheCell: writesTheCell) else { return false }
        return commitOpenEdit()
    }

    /// **Whether the gate lets the strip answer** (fix round ruling I1): a
    /// read-only grid answers nothing, with its reason — except the window's
    /// review mode, where Got it and Reject (no cell moves) are the posture's
    /// to decide and only Accept (it writes the cell) is refused, saying so.
    private func mayAnswer(writesTheCell: Bool) -> Bool {
        guard let reason = mode.readOnlyReason else { return true }
        if reason == .reviewMode {
            guard writesTheCell else { return true }
            bars.showReason(FigureGridStrip.Plan.reviewModeAccept)
            return false
        }
        answer(reason)
        return false
    }

    /// The changed-since question over the cell as it stands now.
    private func changedQuestion(for noteId: String) -> FigureGridStrip.ChangedQuestion? {
        syncFromHost()
        guard let note = cellNotes.byAnchor.values.joined().first(where: { $0.id == noteId }),
              let cells = SuggestionDisplay.figureCells(
                for: note, table: values.table, names: names, locale: values.locale),
              case .live(let address)? = note.figureAnchor?.resolve(in: values.table)
        else { return nil }
        return .init(address: address, now: cells.before ?? "", after: cells.after)
    }
}
