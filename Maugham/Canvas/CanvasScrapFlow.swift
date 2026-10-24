import SwiftUI

/// The one way to make a scrap and the one way to enter one — a double click
/// today, and every keyboard route that makes or enters a scrap — over
/// bindings to `CanvasView`'s own `@State`.
///
/// A scrap made while a chapter is selected belongs to it
/// (`CanvasInteraction.creationBinding`); one made inside a region joins it by
/// centre. Callers ask `CanvasEditGate` first: a read-only canvas makes and
/// enters nothing, and this helper does not ask again.
///
/// Built fresh per call by `CanvasView.scrapFlow` and never stored; a sibling
/// helper may hold the one it was handed (tripwire 32's surface census).
/// `subject` is a `let` the view hands in, and must never reach
/// `CanvasEditFocus` or `CanvasLayoutPass`, whose callers include `load()`'s
/// closures (tripwire 57).
@MainActor
struct CanvasScrapFlow {
    let model: CanvasModel
    let subject: CanvasSubject
    let layoutPass: CanvasLayoutPass
    @Binding var editingNodeID: CanvasNodeID?
    @Binding var caretIndex: Int?
    @Binding var lastKeystrokeAt: Date?
    @Binding var straighten: CanvasFocusStraighten

    /// One "New Scrap" step: create at `origin`, measure, join by centre, bind
    /// per `creationBinding`, and (when `joinedTo` is non-nil) insert the line.
    /// Then enter it, which opens "Edit Scrap" — one ⌘Z takes back the words,
    /// a second the card, its membership, its binding and its line together.
    @discardableResult
    func makeScrapAndEnter(at origin: CGPoint, joinedTo: CanvasNodeID? = nil) -> CanvasNodeID {
        // Creating the card is its own step, closed before the visit opens:
        // one ⌘Z takes back what the writer typed, a second takes back the
        // card. Explicit begin/end rather than `mutate` — the new id has to
        // escape the gesture, and `mutate`'s closure returns nothing.
        model.beginGesture("New Scrap")
        // The sentinel is never read: `withScene`'s closure is non-escaping
        // and runs unconditionally, so `createScrap` has always assigned by
        // the line below. (In 1C-a the equivalent `var` was genuinely
        // reachable at its sentinel, because the recorder was optional and
        // nil until `load()` had run; the model never is.)
        var id = CanvasNodeID("")
        model.withScene(persist: false) {
            id = CanvasInteraction.createScrap(at: origin, in: &$0)
        }
        model.setScrapText("", for: id)
        // A new scrap has no cachedHeight, so it has no frame, so it is
        // invisible to hit testing and culling until it is measured.
        // `rebuildLayouts()` also bumps `sceneRevision`.
        layoutPass.rebuildLayouts()
        // A card made inside a region belongs to it (Denver, 2026-07-28:
        // creation absorbs, transitions do not). AFTER the measure and not
        // before it, because `joinTarget` reads the card's CENTRE and an
        // unmeasured card has no frame to take one from — asked a line
        // earlier this silently joins nothing, on every scrap the writer
        // ever makes. Inside the "New Scrap" gesture, so one ⌘Z takes back
        // the card and the membership together.
        //
        // The chapter binding and the joining line go in the same closure, so
        // the same ⌘Z takes them too. The binding reads the home the join
        // just chose, which is why it is asked here and not before the measure.
        model.withScene(persist: false) {
            let home = CanvasInteraction.joinTarget(for: id, in: $0)
            if let home {
                CanvasMembership.join(id, home: home, in: &$0)
            }
            let piece = CanvasInteraction.creationBinding(subject: subject, home: home, in: $0)
            if let piece {
                $0.setBoundPiece(piece, for: id)
            }
            if let joinedTo {
                $0.insertLine(CanvasLine(id: CanvasInteraction.newLineID(in: $0),
                                         from: joinedTo, to: id))
            }
            if home != nil || piece != nil || joinedTo != nil {
                // The membership, binding or line changed AFTER
                // `rebuildLayouts()` bumped the structural counter, and that
                // bump is the only one on this path — so without this the
                // region inspector in the other column is reading a scene from
                // before the join, the new card is missing from "Lives here",
                // and the dim does not light it, until some unrelated
                // structural change happens along. It works today only because
                // SwiftUI reads the post-join scene in a later body pass, which
                // is an accident of ordering rather than a guarantee: this is
                // the exact shape of the stale-inspector defect the first
                // whole-branch review caught.
                model.bumpSceneRevision()
            }
        }
        // Closed AFTER the measure, so the next gesture's baseline holds a
        // card with a height. Close it before and "Edit Scrap" opens on a
        // scene whose new node has no `cachedHeight`, so undoing the typing
        // would restore a card with no frame — invisible to hit testing, to
        // culling and to the renderer.
        model.endGesture()
        // The measure, join, bind and line all ran with `persist: false`;
        // this queues them, whichever route made the card.
        model.scheduleSave()
        enter(id, caretIndex: 0)
        return id
    }

    /// Enter an existing measured scrap at `caretIndex` (UTF-16); opens
    /// "Edit Scrap". The caller has already closed the previous visit
    /// (`CanvasEditFocus.commitActiveEdit`), so one visit never nests in another.
    func enter(_ id: CanvasNodeID, caretIndex: Int) {
        self.caretIndex = caretIndex
        editingNodeID = id
        lastKeystrokeAt = nil
        // The editor mounts on this line's body pass and takes keystrokes at
        // once; what it does not do yet is SHOW. `visibleEditorNodeID`
        // withholds that until `straighten.isLevel(_:)`, about a tenth of a
        // second from here, and until then the drawn text stays visible,
        // keeps rotating, and grows as the writer types into the editor
        // nobody can see. Spec §7A.5 calls that beat responsiveness rather
        // than lag.
        straighten.focus(id)
        // The OUTER undo bracket for this visit. Whatever the writer now types
        // is a step separate from anything that came before it.
        model.beginGesture("Edit Scrap")
    }
}
