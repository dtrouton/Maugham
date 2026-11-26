import SwiftUI

/// **The lines the window stands over the centre column** (shell read-through
/// Task 3 fix round, M7), applied once by `ProjectWindow.contentColumn` so a
/// test can stack them over a real editor as production does
/// (`CentreTopLinesFixture`).
///
/// Each `safeAreaInset` sits outside what it wraps, so the first applied is
/// nearest the prose: the intent strip (a running head belonging to the
/// page) directly over the writing, then the posture's standing line, then
/// the view-only share's notice outermost. Inside them, `EditorHost` stands
/// its own line — a translation's or read-through's — directly over the text.
struct CentreTopLines: ViewModifier {
    /// The intent strip's line, or nil for no strip.
    let intentLine: String?
    let intentMayTrailDraft: Bool
    /// Why the words are not hers, or nil.
    let standingLine: PostureStandingLine.Line?
    let documentStore: DocumentStore
    let shareIsReadOnly: Bool

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if let intentLine {
                    IntentStrip(line: intentLine, mayTrailDraft: intentMayTrailDraft)
                }
            }
            .safeAreaInset(edge: .top) {
                // **Why the words are not hers** — the posture's own reason, one
                // sentence, over the editor. A role is the permit's, said in the
                // standing line; read-through says itself over the text (`EditorHost`).
                if let standingLine {
                    PostureStandingLineView(line: standingLine, documentStore: documentStore)
                }
            }
            .safeAreaInset(edge: .top) {
                // Read-only trap: a user on a VIEW-ONLY iCloud share cannot
                // append annotation ops at all. Surface that loudly rather than
                // letting a comment attempt fail silently.
                if shareIsReadOnly {
                    ViewOnlyShareNotice()
                }
            }
    }
}
