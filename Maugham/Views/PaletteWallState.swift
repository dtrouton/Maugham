import SwiftUI

/// **The palette wall's window state, as one value** — the wall's open flag,
/// the travel token and the inspector stash, with their folds as mutating
/// methods. The door's press, `ProjectWindow.pressPaletteWallDoor`, stays on
/// the window: it writes the persona as well, and the window is a persona
/// decision site.
///
/// **A value, never an `@Observable`** (tripwire 2): the window owns it, and
/// `PaletteWallModifier` takes a `Binding` to the whole of it, so every write
/// is an ordinary `@State` write the modifier's `.onChange` observers see. A
/// surface that needs only the flag (`CentreColumn`) takes
/// `$paletteWall.showsWall`.
struct PaletteWallState: Equatable {
    /// Whether the wall is open. The Palette tree section's "Open Wall" door
    /// opens it (through `ProjectWindow.pressPaletteWallDoor`, which either
    /// writes this or travels). `ProjectWindow.showsPaletteWallCentre` turns it
    /// (plus the persona) into a routing decision; `PaletteWallModifier` turns
    /// it into the inspector stash/restore.
    var showsWall: Bool = false
    /// **The travel token** (Denver's 2026-08-12 ruling: the door in Plan takes
    /// the writer to Author with the wall open).
    ///
    /// The two halves cannot happen in one pass: a persona change CLOSES the
    /// wall, so the press arms this and `PaletteWallModifier`'s persona observer
    /// consumes it inside that one handler, immediately after the close — no
    /// ordering rests on which modifier SwiftUI delivers first (tripwire 2).
    ///
    /// Never persisted: a one-shot about a press that has already happened.
    var travelPending: Bool = false
    /// The inspector's visibility captured on entry to the palette wall, so
    /// leaving restores it exactly (spec: no stuck-hidden inspector). `nil`
    /// when the wall is closed. Owned by `PaletteWallModifier`.
    var inspectorWasVisibleBefore: Bool?

    /// The palette wall's own inspector rule, as a fold a test can drive.
    ///
    /// **Keyed on `showsWall`**, a key no other fold shares: the wall cannot be
    /// open in Plan (`showsPaletteWallCentre` refuses to draw it there, and
    /// `closePaletteWallOnPersonaChange` closes it on any persona change), so
    /// this fold and `canvasCollapse`'s can never run in the same pass
    /// (tripwire 2).
    mutating func applyPaletteWallChange(from old: Bool,
                                         to new: Bool,
                                         showInspector: inout Bool,
                                         selectedPaletteCardId: inout String?) {
        if new && !old {
            inspectorWasVisibleBefore = showInspector
            showInspector = false
        } else if old && !new {
            // A `nil` stash is a real state — `closePaletteWallOnPersonaChange`
            // dropped it — so the restore is conditional, and load-bearing.
            if let prior = inspectorWasVisibleBefore { showInspector = prior }
            inspectorWasVisibleBefore = nil
            selectedPaletteCardId = nil
        }
    }

    /// **A persona change closes the wall — ANY persona change**, whichever of
    /// its writers moved it (the ⌘1–⌘4 handler, `CanvasClaudeArrivalModifier
    /// .show`, `ManuscriptNavigation.go`). Otherwise a wall hidden in Plan would
    /// be back over the manuscript on ⌘2, with a stash still armed to close the
    /// inspector.
    ///
    /// **An observer of the persona rather than a call at each writer**: a
    /// census of three call sites is one refactor away from two; the question
    /// is about the state.
    ///
    /// **It drops the stash rather than restoring it**: a persona switch opens
    /// the right column (`PersonaModifier`), and `applyPaletteWallChange`'s exit
    /// arm, a pass later, would restore the pre-wall visibility over it. A `nil`
    /// stash makes that restore a no-op in either order — tripwire 2's lesson.
    mutating func closePaletteWallOnPersonaChange() {
        guard showsWall else { return }
        inspectorWasVisibleBefore = nil
        showsWall = false
    }

    /// **The other half of the same persona change**: the wall the writer asked
    /// for in Plan, opened now that the switch to Author has landed.
    ///
    /// Called from `PaletteWallModifier`'s `.onChange(of: persona)` only, AFTER
    /// `closePaletteWallOnPersonaChange`: the close is unconditional, so a travel
    /// consumed first would open a wall the close then shuts.
    ///
    /// **A one-shot.** Clearing the token before opening keeps the wall from
    /// following the writer around — ⌘1 back to Plan closes it, and ⌘2 must not
    /// bring it back.
    mutating func applyWallTravelOnPersonaChange() {
        guard travelPending else { return }
        travelPending = false
        showsWall = true
    }
}
