import SwiftUI

/// **The palette wall's window state, as one value** — the inspector stash and
/// the subject the wall was opened over, with their folds as mutating methods.
/// Whether the wall is open is not here: it is the subject's `open == .palette`
/// (`ProjectWindow.showsPaletteWallCentre`), one truth with nothing to drift.
///
/// **A value, never an `@Observable`** (tripwire 2): the window owns it, and
/// `PaletteWallModifier` takes a `Binding` to the whole of it, so every write
/// is an ordinary `@State` write.
struct PaletteWallState: Equatable {
    /// The inspector's visibility captured on entry to the palette wall, so
    /// leaving restores it exactly (spec: no stuck-hidden inspector). `nil`
    /// when the wall is closed. Owned by `PaletteWallModifier`.
    var inspectorWasVisibleBefore: Bool?
    /// The subject the wall was opened over, so the wall's own Close puts the
    /// writer back where they were. `nil` when the wall is closed.
    var subjectBeforeWall: WindowSubject?

    /// The palette wall's own inspector rule, as a fold a test can drive —
    /// keyed on the wall opening or closing, which is the subject's `open`
    /// becoming or leaving `.palette`.
    ///
    /// The stash and the canvas collapse's can never meet: the wall and the
    /// canvas are each the centre, and the subject has one `open` (tripwire 2).
    mutating func applyPaletteWallChange(from old: WindowSubject,
                                         to new: WindowSubject,
                                         showInspector: inout Bool,
                                         selectedPaletteCardId: inout String?) {
        let was = ProjectWindow.showsPaletteWallCentre(subject: old)
        let isOpen = ProjectWindow.showsPaletteWallCentre(subject: new)
        if isOpen && !was {
            inspectorWasVisibleBefore = showInspector
            subjectBeforeWall = old
            showInspector = false
        } else if was && !isOpen {
            if let prior = inspectorWasVisibleBefore { showInspector = prior }
            inspectorWasVisibleBefore = nil
            subjectBeforeWall = nil
            selectedPaletteCardId = nil
        }
    }

    /// **The wall's Close** (Esc, the close button): the subject the wall was
    /// opened over, else the Book — keeping whatever was opened beside while the
    /// wall was up. A wall left by any other subject change has already closed
    /// by that change. The window repairs the answer against the project
    /// (`ProjectWindow.validatedSubject`).
    func closingWall(_ subject: WindowSubject) -> WindowSubject {
        guard ProjectWindow.showsPaletteWallCentre(subject: subject) else { return subject }
        var back = subjectBeforeWall ?? .book
        back.beside = subject.beside
        return back
    }
}
