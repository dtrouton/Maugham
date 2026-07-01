import SwiftUI

/// Read-only markdown preview for a research-note file. Loads the file
/// from disk and delegates rendering to ResearchNotePreviewPane — the
/// same renderer the editor's ⌘⇧P preview uses, so headings, inline
/// emphasis, and inline images render consistently.
struct TextPreview: View {
    let notePath: String
    let projectURL: URL
    @State private var text: String = ""

    var body: some View {
        ResearchNotePreviewPane(
            notePath: notePath,
            projectURL: projectURL,
            noteText: text)
        .task(id: notePath) {
            let url = projectURL.appendingPathComponent(notePath)
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""  // adr-0018-ok: research text-preview read, not manuscript
        }
    }
}
