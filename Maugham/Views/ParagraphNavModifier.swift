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
    /// The window's subject. **Going to a paragraph opens its piece**
    /// (`ManuscriptNavigation`): an annotation row, a history row, a task row,
    /// a diagnostic or a figure's Used-in link all end with the piece in the
    /// centre and the faces, whatever the centre was.
    @Binding var subject: WindowSubject
    /// The centre item's cover: a navigation closes it before it lands.
    @Binding var centreItem: CentreItem?
    /// The project's structure, read at post time to tell a piece on the faces
    /// from a Part.
    let structure: () -> [StructureItem]
    /// The window's editor control: where a place whose piece the editor does
    /// not have yet is held until that piece loads (`EditorControl.pendingPlace`).
    let editorControl: EditorControl
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .onKeyWindowCommand(.maughamNavigateToParagraph, window: window) { note in
                // The editor's own receiver (`EditorCoordinator`) scrolls to the
                // paragraph when it has the piece; this one puts the piece in
                // the centre, and holds the place for the editor that loads it.
                ManuscriptNavigation.go(to: holdingThePlace(note), subject: $subject,
                                        centreItem: $centreItem)
            }
            // **The screenplay's own navigation.** A slugline click posts this from
            // `SceneNavigatorPane`'s `onSelect` after that pane has put the script
            // on the faces (`SceneNavigatorPane.subject(_:whenNavigatingTo:)`);
            // this receiver opens it, so a slugline clicked over the canvas lands
            // in the script.
            //
            // **Two receivers, one poster, different jobs**: this one opens the
            // script, the coordinator's scrolls to the slugline. When the editor
            // does not have the script loaded the slugline's line is held, never
            // re-posted, and the editor that loads the script lands it
            // (`EditorControl.pendingPlace`): a later click replaces it, so a
            // quick A-then-B lands on B.
            .onKeyWindowCommand(.maughamNavigateToScene, window: window) { note in
                ManuscriptNavigation.go(to: holdingThePlace(note), subject: $subject,
                                        centreItem: $centreItem)
            }
            // **An annotation jump closes the centre item's cover** (controller
            // ruling, shell plan 3 Task 5 fix 2) — even one with no paragraph,
            // which posts no paragraph navigation for `go` to close it from:
            // the editor's own receiver selects the annotation under it.
            .onKeyWindowCommand(.maughamNavigateToAnnotation, window: window) { _ in
                if centreItem != nil { centreItem = nil }
            }
            // `.maughamShowHelp` is `.allWindows` scoped, so every live-or-zombie
            // window receives it; `openWindow(id:)` for a singleton Window is
            // idempotent (it brings the one Help window forward), so no
            // key-window guard.
            .onGlobalEvent(.maughamShowHelp) { _ in
                openWindow(id: "help")
            }
            // A place still waiting for a piece the window has left is
            // dropped: its load was abandoned (`EditorControl.pendingPlace`).
            .onChange(of: subject.open) { _, open in
                ManuscriptNavigation.openChanged(to: open, control: editorControl)
            }
    }

    /// Where the navigation takes the window, the place held for the editor
    /// when it does not have the piece yet (`ManuscriptNavigation.holdingThePlace`).
    private func holdingThePlace(_ note: Notification) -> WindowSubject {
        ManuscriptNavigation.holdingThePlace(payload: note.userInfo, current: subject,
                                             structure: structure(), control: editorControl)
    }
}
