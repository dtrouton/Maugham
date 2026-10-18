import SwiftUI
import MaughamCore
import AppKit

/// Persona switching. Extracted so ProjectWindow.body's modifier chain gains
/// exactly one expression — the chain is at the SwiftUI type-checker ceiling
/// and three sibling modifiers exist because inlining broke the Release build.
struct PersonaModifier: ViewModifier {
    @Binding var persona: Persona
    @Binding var detailSegment: DetailSegment
    @Binding var showInspector: Bool
    // **No wall bindings here since the final review's I3 fix.** They were
    // written by one arm of the ⌘1–⌘4 handler and nothing else; leaving them
    // threaded in would invite a second wall rule beside the one observer that
    // now owns the question (`ProjectWindow.closePaletteWallOnPersonaChange`).
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
    /// default the first time). The earlier rule — keep whatever segment the
    /// destination also offers — is what stranded the binder on Research after
    /// ⌘1 then ⌘2 (2026-07-25 smoke, defect B): Author offered Research, so
    /// nothing ever moved it back.
    ///
    /// **It carried the LEFT column too, until shell-finish stage 2b Task 7.**
    /// There is nothing left to carry: every persona's left column is the
    /// project's own tree, so a switch cannot move it and cannot strand anyone
    /// on it. The transient exception went with it — `.find` and `.trash` were
    /// segments a writer had to be allowed to ride through a switch, and both
    /// are window state now (the find overlay, the trash foot disclosure) which
    /// no persona change touches at all.
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

    // **The wall's own arm left this handler in the final review's I3 fix.**
    // `clearsPaletteWallStash` asked whether a persona change was entering Plan
    // with the wall open, and it could only ever be asked HERE — of the ⌘1–⌘4
    // handler — while two other writers move the persona without passing
    // through it (`CanvasClaudeArrivalModifier.show`,
    // `ManuscriptNavigation.go`). Its successor is
    // `ProjectWindow.closePaletteWallOnPersonaChange`, observed on the persona
    // itself in `PaletteWallModifier`, which covers all three by construction
    // and every destination rather than Plan alone. It drops the stash for the
    // same ordering reason this one did — see its doc comment.

    /// True when a persona change moves the binder OFF the canvas *while a
    /// `⌘\` collapse is in force* — the case where `CanvasCollapseModifier`'s
    /// stash must be dropped and the sidebar handed back, here, synchronously.
    ///
    /// **The same ordering hazard as the palette's, one surface over.** That
    /// modifier's own `.onChange` fires in a LATER update pass than this
    /// handler, so its release arm would restore the stashed visibility *over*
    /// the `showInspector = true` below — a writer who had closed the inspector
    /// before collapsing would land in the new persona with it closed, unlike
    /// every other persona-switch path. Doing both halves here rather than
    /// deferring the force-open by a pass is what makes that arm a no-op instead
    /// of a race, which is the fragility tripwire 2 is about.
    ///
    /// **The predicate rather than `== .plan`, since slice 2, and asked of the
    /// PERSONA since stage 2b Task 6.** The board is Plan's centre column, so
    /// what "leaving the canvas" means is leaving Plan — and a rule that named
    /// the persona would be claiming the collapse belongs to a mode rather than
    /// to the column that draws the board. Task 7 dropped the two segment
    /// arguments that stood beside these: while the strip existed, Plan's
    /// Palette tab was Plan with no board in front of the writer, and there is
    /// no such state now.
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
            // **The window's working mode, published to the scene** for the
            // File menu's two compiler items (`FocusedRunButtons`, two loops
            // P3): Author's ⌘R is a check and Review's a round, so the menu
            // titles them apart (`RunMenuTitles`). It is a TITLE and nothing
            // else — what those items post never moved, because the `RunKind`
            // is minted from the persona at the receiver, and a second read of
            // the persona on the posting side would be one decision made in two
            // places that can disagree.
            //
            // It lives on THIS modifier because the persona is this modifier's
            // whole subject — it already owns the binding and is the one place
            // the window's mode is written. Task 1 first hung it off
            // `CanvasPromotionModifier`, which publishes to the same scene and
            // takes the same value: that works, and it couples the File menu's
            // wording to canvas plumbing for no reason that survives being
            // written down. `RunMenuTitlesTests` censuses the publish site so
            // there stays exactly one.
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
