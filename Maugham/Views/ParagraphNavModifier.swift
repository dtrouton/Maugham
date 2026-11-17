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
    /// The project's structure, read at post time to tell a piece on the faces
    /// from a Part.
    let structure: () -> [StructureItem]
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .onKeyWindowCommand(.maughamNavigateToParagraph, window: window) { note in
                // The editor's own receiver (`EditorCoordinator`) scrolls to the
                // paragraph; this one puts its piece in the centre.
                ManuscriptNavigation.go(
                    to: ManuscriptNavigation.destination(
                        toDocument: ManuscriptNavigation.paragraphDocId(
                            payload: note.userInfo, current: subject,
                            structure: structure()),
                        current: subject),
                    subject: $subject)
            }
            // **The screenplay's own navigation.** A slugline click posts this from
            // `SceneNavigatorPane`'s `onSelect` after that pane has put the script
            // on the faces (`SceneNavigatorPane.subject(_:whenNavigatingTo:)`);
            // this receiver opens it, so a slugline clicked over the canvas lands
            // in the script.
            //
            // **Two receivers, one poster, different jobs**: this one opens the
            // script, the coordinator's scrolls to the slugline. Deliberately NOT a
            // re-post once the editor mounts — see
            // `SceneNavigatorPane.subject(_:whenNavigatingTo:)` for the first-click
            // edge and why a delayed re-post would be worse.
            .onKeyWindowCommand(.maughamNavigateToScene, window: window) { note in
                ManuscriptNavigation.go(
                    to: ManuscriptNavigation.destination(
                        toDocument: ManuscriptNavigation.paragraphDocId(
                            payload: note.userInfo, current: subject,
                            structure: structure()),
                        current: subject),
                    subject: $subject)
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
