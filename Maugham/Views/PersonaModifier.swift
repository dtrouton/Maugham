import SwiftUI
import MaughamCore
import AppKit

/// Persona switching, as one modifier so `ProjectWindow.body`'s chain (at the
/// Release type-check ceiling) gains exactly one expression.
struct PersonaModifier: ViewModifier {
    @Binding var persona: Persona
    @Binding var detailSegment: DetailSegment
    @Binding var showInspector: Bool
    // No wall bindings here: the one wall rule is the persona observer
    // `PaletteWallState.closePaletteWallOnPersonaChange`, and threading them
    // in would invite a second.
    /// `CanvasCollapseModifier`'s pre-collapse visibility stash. Written here
    /// only to DROP it — see `releasesCanvasCollapse(from:to:stash:)`.
    @Binding var inspectorWasVisibleBeforeCanvasCollapse: Bool?
    /// The split view's column visibility, handed back here in the SAME pass as
    /// the stash is dropped. Dropping the stash alone would leave the sidebar
    /// hidden in a persona that has no canvas to justify it.
    @Binding var columnVisibility: NavigationSplitViewVisibility
    let window: NSWindow?
    let documentStore: DocumentStore?

    struct Change: Equatable {
        let persona: Persona
        let segment: DetailSegment
        /// The memory to persist, with the departing persona's position
        /// already recorded. Returned rather than mutated in place so the
        /// whole rule stays one pure function.
        let memory: PersonaMemory
    }

    /// Pure core, so the whole workspace switch is testable without SwiftUI.
    /// This is the ONE place a persona change moves the right column.
    ///
    /// A persona switch is a WORKSPACE switch: the departing persona's pane
    /// selection is snapshotted, and the destination's is restored (its own
    /// default the first time). Keeping whatever segment the destination also
    /// offers strands the writer (2026-07-25 smoke, defect B). The left column
    /// is the project's own tree in every persona, so a switch never moves it.
    static func applyPersonaChange(to persona: Persona,
                                   from currentPersona: Persona,
                                   currentSegment: DetailSegment,
                                   memory: PersonaMemory) -> Change {
        var memory = memory
        memory.record(persona: currentPersona, detailSegment: currentSegment)
        return Change(persona: persona,
                      segment: memory.restoredDetailSegment(for: persona),
                      memory: memory)
    }

    static func persona(fromPayload raw: String?) -> Persona? {
        guard let raw else { return nil }
        return Persona(rawValue: raw)
    }

    // The palette wall's persona rule is not here: it is observed on the
    // persona itself (`PaletteWallState.closePaletteWallOnPersonaChange` in
    // `PaletteWallModifier`), because two other writers move the persona
    // without passing through this handler (`CanvasClaudeArrivalModifier
    // .show`, `ManuscriptNavigation.go`).

    /// True when a persona change moves the binder OFF the canvas *while a
    /// `⌘\` collapse is in force* — the case where `CanvasCollapseModifier`'s
    /// stash must be dropped and the sidebar handed back, here, synchronously.
    ///
    /// **The same ordering hazard as the palette's, one surface over.**
    /// `CanvasCollapseModifier`'s `.onChange` fires a pass LATER than this
    /// handler, so its release arm would restore the stashed visibility *over*
    /// the `showInspector = true` below. Doing both halves here makes that arm
    /// a no-op instead of a race — tripwire 2.
    ///
    /// **The predicate rather than `== .plan`**: leaving the canvas means
    /// leaving the persona whose centre is the board; a persona name would
    /// claim the collapse belongs to a mode rather than to the column.
    ///
    /// **Guarded on the stash rather than on the personas alone**, so a persona
    /// switch off an *uncollapsed* canvas reopens nothing: the writer may have
    /// dragged the sidebar shut themselves, and this is not the code that gets
    /// to undo that.
    static func releasesCanvasCollapse(fromPersona: Persona,
                                       toPersona: Persona,
                                       stash: Bool?) -> Bool {
        guard stash != nil else { return false }
        return fromPersona.centresTheCanvas && !toPersona.centresTheCanvas
    }

    func body(content: Content) -> some View {
        content
            // **The window's working mode, published to the scene** for the File
            // menu's two compiler items: Author's ⌘R is a check and Review's a
            // round, so `RunMenuTitles` titles them apart. A TITLE and nothing else
            // — the `RunKind` is minted from the persona at the receiver, and a
            // second read on the posting side would be one decision made in two
            // places. Here because the persona is this modifier's whole subject;
            // `RunMenuTitlesTests` censuses the publish site so there stays one.
            .focusedSceneValue(\.persona, persona)
            .onKeyWindowCommand(.maughamSetPersona, window: window) { note in
                guard let next = Self.persona(
                    fromPayload: note.userInfo?[MaughamEvent.personaKey] as? String)
                else { return }
                // The memory is read from (and written back to) `UIState`
                // rather than kept in a parallel `@State` — it is per-project
                // state that sits beside `persona`, and `updateUIState`
                // mutates its in-memory copy synchronously, so the read here
                // always sees the last switch.
                let change = Self.applyPersonaChange(
                    to: next,
                    from: persona,
                    currentSegment: detailSegment,
                    memory: documentStore?.uiState.personaMemory ?? .empty)
                if Self.releasesCanvasCollapse(
                    fromPersona: persona, toPersona: change.persona,
                    stash: inspectorWasVisibleBeforeCanvasCollapse) {
                    inspectorWasVisibleBeforeCanvasCollapse = nil
                    columnVisibility = .all
                }
                persona = change.persona
                detailSegment = change.segment
                showInspector = true
                documentStore?.updateUIState {
                    $0.persona = change.persona
                    $0.personaMemory = change.memory
                }
            }
    }
}
