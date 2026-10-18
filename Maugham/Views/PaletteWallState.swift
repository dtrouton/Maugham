import SwiftUI

/// **The palette wall's window state, as one value** (foundations plan 4
/// Task 6). Three `@State`s on `ProjectWindow` until then — the wall's open
/// flag, the travel token and the inspector stash — held now in ONE `@State`
/// of this type, and their folds moved here from `ProjectWindow`'s statics as
/// mutating methods, unchanged in what they do. The door's press,
/// `ProjectWindow.pressPaletteWallDoor`, stays on the window: it writes the
/// persona as well, and the window is a persona decision site.
///
/// **A value, never an `@Observable`** (tripwire 2): the window owns it, and
/// `PaletteWallModifier` takes a `Binding` to the whole of it, so every write
/// is an ordinary `@State` write the modifier's `.onChange` observers see in
/// the usual way. A surface that needs only the flag (`CentreColumn`) takes
/// `$paletteWall.showsWall`.
struct PaletteWallState: Equatable {
    /// The palette wall's door (shell-finish stage 2b Task 5) — the Palette
    /// tree section's own "Open Wall" affordance opens it (through
    /// `ProjectWindow.pressPaletteWallDoor`, which either writes this or travels — stage 3b
    /// Task 4), and that door is what carried the wall across Task 7's deletion
    /// of the binder strip it used to be reached through.
    /// `ProjectWindow.showsPaletteWallCentre` is what turns this (plus the
    /// persona) into a routing decision; `PaletteWallModifier` is what turns it
    /// into the inspector stash/restore the old `.palette` segment used to own.
    var showsWall: Bool = false
    /// **The travel token** (shell-finish stage 3b Task 4, Denver's 2026-08-12
    /// ruling: the door in Plan takes the writer to Author with the wall open).
    ///
    /// It exists because the two halves cannot happen in one pass: a persona
    /// change CLOSES the wall (`closePaletteWallOnPersonaChange`), so a door
    /// that opened the wall and then switched persona would have the switch
    /// shut it. So the press arms this, and `PaletteWallModifier`'s own persona
    /// observer consumes it — inside that one handler, immediately after the
    /// close — which is what "opened AFTER the switch lands" means without any
    /// ordering resting on which modifier SwiftUI delivers first (tripwire 2).
    ///
    /// Window state, never persisted: it is a one-shot about a press that has
    /// already happened, and a token surviving a relaunch would open a wall
    /// nobody asked for.
    var travelPending: Bool = false
    /// The inspector's visibility captured on entry to the palette wall, so
    /// leaving restores it exactly (spec: no stuck-hidden inspector). `nil`
    /// when the wall is closed. Owned by `PaletteWallModifier`.
    var inspectorWasVisibleBefore: Bool?

    /// The palette wall's own inspector rule, as a fold rather than a closure
    /// body — behaviour unchanged in shape, extracted so a test can drive it.
    ///
    /// **Re-keyed on `showsPaletteWall` in stage 2b Task 5**, rather than on a
    /// `.palette` binder segment. The old key shared an update pass with
    /// `CanvasCollapseModifier`, which watched the same segment — Plan's binder
    /// offered Palette and Canvas side by side, so a one-click palette → canvas
    /// move in focus mode ran both folds in the same pass, in an order neither
    /// could depend on. The wall's door touches no shared key, and Task 7 took
    /// the strip that was the other half of the race: the wall cannot be open in
    /// Plan at all (`showsPaletteWallCentre` refuses to draw it there, and
    /// `closePaletteWallOnPersonaChange` closes it on any persona change), so
    /// the two folds can no longer meet.
    mutating func applyPaletteWallChange(from old: Bool,
                                         to new: Bool,
                                         showInspector: inout Bool,
                                         selectedPaletteCardId: inout String?) {
        if new && !old {
            inspectorWasVisibleBefore = showInspector
            showInspector = false
        } else if old && !new {
            // A `nil` stash is a real state and means "someone else has already
            // taken this memory over" — see `canvasCollapse`'s takeover. It has
            // always been written as a conditional restore; that is now
            // load-bearing rather than merely defensive.
            if let prior = inspectorWasVisibleBefore { showInspector = prior }
            inspectorWasVisibleBefore = nil
            selectedPaletteCardId = nil
        }
    }

    /// **A persona change closes the wall — ANY persona change** (stage 2b
    /// final review's I3).
    ///
    /// The rule used to live in `PersonaModifier`, keyed on the destination
    /// being Plan, and it was reachable only from the ⌘1–⌘4 handler. Two other
    /// writers move the persona: `CanvasClaudeArrivalModifier.show` writes
    /// `persona = .plan` directly (deliberately — its own doc comment argues
    /// down going through the notification), and `ManuscriptNavigation.go`
    /// writes it for a wiki-link jump. So a wall open over Author's centre
    /// survived a Show, hid itself in Plan (`showsPaletteWallCentre` refuses
    /// there), and was back over the manuscript the moment the writer pressed
    /// ⌘2 — with a visibility stash still armed to close their inspector on the
    /// way out.
    ///
    /// **An observer of the persona rather than a call at each writer.** A
    /// census of three call sites is one refactor away from being a census of
    /// two; the wall is window state and the question is about the state.
    ///
    /// **It drops the stash rather than restoring it**, which is what makes the
    /// order-independence argument hold: a persona switch opens the right column
    /// (`PersonaModifier` writes `showInspector = true`), and
    /// `applyPaletteWallChange`'s exit arm — which runs a pass later — would
    /// restore the pre-wall visibility over it and land a writer who had closed
    /// their inspector in the new persona with it closed, unlike every other
    /// switch. A `nil` stash makes that restore a no-op in either order, which
    /// is tripwire 2's whole lesson.
    mutating func closePaletteWallOnPersonaChange() {
        guard showsWall else { return }
        inspectorWasVisibleBefore = nil
        showsWall = false
    }

    /// **The other half of the same persona change** (shell-finish stage 3b
    /// Task 4): the wall the writer asked for in Plan, opened now that the
    /// switch to Author has landed.
    ///
    /// Called from `PaletteWallModifier`'s `.onChange(of: persona)` and only
    /// there, AFTER `closePaletteWallOnPersonaChange`. The order is the whole
    /// point: the close is unconditional, so a travel consumed first would open
    /// a wall the close then shuts, and the writer would arrive in Author with
    /// the same nothing the disabled door used to give them.
    ///
    /// **A one-shot.** Clearing the token before opening is what keeps the wall
    /// from following the writer around — ⌘1 back to Plan closes it, and ⌘2 must
    /// not bring it back.
    mutating func applyWallTravelOnPersonaChange() {
        guard travelPending else { return }
        travelPending = false
        showsWall = true
    }
}
