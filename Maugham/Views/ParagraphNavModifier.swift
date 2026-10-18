import SwiftUI
import MaughamCore
import AppKit

/// Handles .maughamNavigateToParagraph and .maughamNavigateToScene, in its
/// own modifier for the type-check ceiling.
struct ParagraphNavModifier: ViewModifier {
    /// The owning project window. `.maughamNavigateToParagraph` and
    /// `.maughamNavigateToScene` are both key-window scoped (ADR 0021), so only
    /// the key window acts.
    let window: NSWindow?
    /// Moved to Author by a navigation from a persona that would not show the
    /// document — **and left alone in Review, which is the case this rule is
    /// written around.** An annotation row and a history row both post this
    /// notification; a reviewer taken to Author would lose the notes they were
    /// adjudicating against. See `Persona.showsManuscriptDocuments(for:)`.
    @Binding var persona: Persona
    @Binding var detailSegment: DetailSegment
    let documentStore: DocumentStore?
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .onKeyWindowCommand(.maughamNavigateToParagraph, window: window) { note in
                // v1: just ensure the manuscript pane is focused.
                // Anchored scroll-to-paragraph is a follow-up.
                _ = note.userInfo?["paragraph_id"] as? String
                ManuscriptNavigation.go(
                    to: ManuscriptNavigation.destination(
                        from: persona,
                        currentDetailSegment: detailSegment,
                        memory: documentStore?.uiState.personaMemory ?? .empty),
                    persona: $persona,
                    detailSegment: $detailSegment,
                    documentStore: documentStore)
            }
            // **The screenplay's own navigation.** A slugline click posts this from
            // `SceneNavigatorPane`'s `onSelect`, and `EditorCoordinator` receives it
            // to scroll — but Plan mounts no coordinator, so without this the click
            // would set the subject and nothing else. Denver's ruling: *"if I'm
            // moving to the manuscript I'm moving to Author."*
            //
            // **Two receivers, one poster, different jobs**: this one moves the
            // window to where the script can be read, the coordinator's scrolls to
            // the slugline. Deliberately NOT a re-post once the editor mounts — see
            // `SceneNavigatorPane.subject(_:whenNavigatingTo:)` for the first-click
            // edge (from Plan, the first click lands in the script and the next one
            // scrolls) and why a delayed re-post would be worse.
            .onKeyWindowCommand(.maughamNavigateToScene, window: window) { _ in
                ManuscriptNavigation.go(
                    to: ManuscriptNavigation.destination(
                        from: persona,
                        currentDetailSegment: detailSegment,
                        memory: documentStore?.uiState.personaMemory ?? .empty),
                    persona: $persona,
                    detailSegment: $detailSegment,
                    documentStore: documentStore)
            }
            // `.maughamShowHelp` is `.allWindows` scoped, so every live-or-zombie
            // window receives it; `openWindow(id:)` for a singleton Window is
            // idempotent (it brings the one Help window forward), so no
            // key-window guard.
            .onGlobalEvent(.maughamShowHelp) { _ in
                openWindow(id: "help")
            }
    }
}
