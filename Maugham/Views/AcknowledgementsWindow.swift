import SwiftUI

/// Shows the bundled THIRD-PARTY-LICENSES.md (MIT notices for WhisperKit,
/// Tectonic) so the required attributions ship with the app, not just the repo.
struct AcknowledgementsWindow: View {
    @State private var markdown: String?

    var body: some View {
        Group {
            if let markdown {
                GuideMarkdownView(markdown: markdown)
            } else {
                ContentUnavailableView("Acknowledgements",
                    systemImage: "doc.text",
                    description: Text("Third-party license information is unavailable."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .task {
            if let url = Bundle.main.url(forResource: "THIRD-PARTY-LICENSES", withExtension: "md"),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                markdown = text
            }
        }
    }
}
