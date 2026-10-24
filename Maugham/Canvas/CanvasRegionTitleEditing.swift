import SwiftUI

/// `CanvasView`'s region names on the canvas (spec §3): the title opens for
/// typing after a sweep makes a region, after a drop is wrapped in one, on a
/// double click on the title and on Return with the region selected — over
/// bindings to the view's own `@State`. Return commits ("Rename Region"),
/// Escape leaves the name as it was, and a click anywhere else commits what
/// was typed.
///
/// **One editor slot.** The title field is the second branch of
/// `CanvasView.mountedEditor`, so it and a scrap editor never both exist:
/// `begin` finishes any open scrap visit first, and `CanvasScrapFlow.enter`
/// and the click handler's head finish an open title (`commitIfOpen`).
///
/// **What the writer typed reaches state on every keystroke**
/// (`noteTyping`), so `commitIfOpen` — which runs at the click handler's head,
/// windowless in the tests — commits the words even if the field has not yet
/// told anyone it lost focus. The draft names its region, so a draft left by
/// another region's field is never written into this one.
///
/// Built fresh per call by `CanvasView.regionTitleEditing` and never stored;
/// a sibling helper may hold the one it was handed (tripwire 32's surface
/// census). It holds `editFocus`, so this file schedules no work.
@MainActor
struct CanvasRegionTitleEditing {
    let model: CanvasModel
    let editFocus: CanvasEditFocus
    @Binding var regionTitleEditingID: CanvasRegionID?
    @Binding var regionTitleDraft: CanvasRegionTitleDraft?
    @Binding var editingNodeID: CanvasNodeID?
    @Binding var keyboardTicket: Int
    @Binding var revision: Int

    /// Whether a title is open on a region still in the scene. An undo can
    /// take the region away under an open field; that is no open title.
    var isOpen: Bool {
        guard let id = regionTitleEditingID else { return false }
        return model.scene.region(id) != nil
    }

    /// Open `id`'s title for typing.
    ///
    /// Asked in the surface's order (`CanvasEditGateTests`): a gesture of the
    /// writer's hand refuses it — the open scrap visit's own "Edit Scrap" is
    /// not one, and is closed below — then the gate (a read-only canvas names
    /// nothing), then the open scrap is finished (folded, closed and left) and
    /// any other open title committed, then the title opens. It opens no undo
    /// step: the sweep's "New Region" has already closed, and naming is a step
    /// of its own only when the commit changes the name.
    func begin(_ id: CanvasRegionID) {
        guard editingNodeID != nil || !model.isInGesture else { return }
        guard CanvasEditGate.editsValues(isReadOnly: model.isReadOnly),
              model.scene.region(id) != nil else { return }
        editFocus.commitActiveEdit()
        editFocus.leaveTheOpenScrap()
        // Already open here: what has been typed stays.
        guard regionTitleEditingID != id else { return }
        commitIfOpen()
        regionTitleDraft = nil
        regionTitleEditingID = id
        // The drawn label steps aside on the next frame.
        revision += 1
    }

    /// Return: write the name and close, then hand the keyboard back to the
    /// canvas so the next key means something there.
    /// Returns false when the write was refused (mid-gesture, or the canvas
    /// went read-only): the title stays open with the words in it, and the
    /// field takes Return again.
    @discardableResult
    func commit(_ text: String) -> Bool {
        guard let id = regionTitleEditingID else { return true }
        guard writeTitle(text, to: id) else { return false }
        close()
        keyboardTicket += 1
        return true
    }

    /// Escape: close with nothing written and no undo step. A region just
    /// swept stays, untitled (spec §3) — Escape is not ⌘Z.
    @discardableResult
    func cancel() -> Bool {
        guard regionTitleEditingID != nil else { return true }
        close()
        keyboardTicket += 1
        return true
    }

    /// Commit whatever was typed into the open title and close it, without
    /// asking for the keyboard — the click or scrap that called this is where
    /// the writer is going next. A no-op with no title open.
    func commitIfOpen() {
        guard let id = regionTitleEditingID else { return }
        if let draft = regionTitleDraft, draft.region == id {
            guard writeTitle(draft.text, to: id) else { return }
        }
        close()
    }

    /// A keystroke in `id`'s field: what it now holds.
    func noteTyping(_ text: String, in id: CanvasRegionID) {
        guard regionTitleEditingID == id else { return }
        regionTitleDraft = CanvasRegionTitleDraft(region: id, text: text)
    }

    /// `id`'s field lost the keyboard to something other than Return or
    /// Escape — a click elsewhere, Tab, the inspector. Commits what was typed
    /// and closes, without taking the keyboard from wherever it went.
    @discardableResult
    func fieldLostFocus(_ text: String, in id: CanvasRegionID) -> Bool {
        guard regionTitleEditingID == id else { return true }
        guard writeTitle(text, to: id) else { return false }
        close()
        return true
    }

    /// The open title names a region no longer in the scene (an undo took it):
    /// close it, so a redo bringing the region back does not remount the field
    /// and take the keyboard. Called on every structural change.
    func forgetIfTheRegionIsGone() {
        guard let id = regionTitleEditingID, model.scene.region(id) == nil else { return }
        close()
    }

    /// Write `text` as `id`'s name, exactly as `RegionInspector.commitLabel`
    /// writes it — no trim, and nothing at all when it is unchanged — but from
    /// the surface, so through `mutate` (tripwire 32). Returns false only when
    /// refused: mid-gesture (it would nest) or read-only. A refusal leaves the
    /// title open with the words still in it.
    private func writeTitle(_ text: String, to id: CanvasRegionID) -> Bool {
        guard !model.isInGesture else { return false }
        guard CanvasEditGate.editsValues(isReadOnly: model.isReadOnly) else { return false }
        guard let region = model.scene.region(id) else { return true }
        guard region.label != text else { return true }
        model.mutate("Rename Region") { $0.updateRegion(id) { $0.label = text } }
        // The spoken name and the inspector's both read the structural counter.
        model.bumpSceneRevision()
        return true
    }

    private func close() {
        regionTitleEditingID = nil
        regionTitleDraft = nil
        revision += 1
    }
}
