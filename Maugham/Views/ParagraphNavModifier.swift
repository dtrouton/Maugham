import SwiftUI
import MaughamCore
import AppKit
import os

/// Handles .maughamNavigateToParagraph in its own modifier to stay within
/// Swift's type-checker expression limit in SessionAndNavigationModifier.
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
            // **The screenplay's own navigation, and the third to route here.**
            //
            // A slugline click posts this from `SceneNavigatorPane`'s `onSelect`
            // (via `BinderPaneToggle`) and `EditorCoordinator` receives it to
            // scroll. Slice 2 gave Plan's Structure tab that same navigator, and
            // in Plan the coordinator does not exist — so the click set the
            // subject and then nothing happened at all: no movement, no error,
            // no greyed-out affordance (slice 2 review, F2). Denver's ruling
            // covers it exactly as it covers the other two: *"if I'm moving to
            // the manuscript I'm moving to Author."*
            //
            // **Two receivers, one poster, and they do different jobs**: this one
            // moves the window to where the script can be read, the coordinator's
            // scrolls to the slugline. Deliberately NOT a re-post once the editor
            // mounts — see `SceneNavigatorPane.subject(_:whenNavigatingTo:)` for
            // the already-recorded first-click edge and why a delayed re-post
            // would be worse than a first click that under-delivers. From Plan
            // that edge is now reachable one more way: the click that moves the
            // window to Author lands in the script rather than on that slugline,
            // and the next one scrolls.
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
