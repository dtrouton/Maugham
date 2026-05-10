import SwiftUI

public enum SyntaxHelpMode {
    case prose
    case screenplay
}

struct SyntaxHelpSheet: View {
    let mode: SyntaxHelpMode
    @Environment(\.dismiss) private var dismiss

    @State private var content: AttributedString = AttributedString("")

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(content)
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .navigationTitle(navigationTitle)
        }
        .frame(minWidth: 640, minHeight: 480)
        .task {
            content = Self.loadContent(mode: mode)
        }
    }

    private var navigationTitle: String {
        switch mode {
        case .prose:        return "Markdown Syntax"
        case .screenplay:   return "Fountain Syntax"
        }
    }

    static func loadContent(mode: SyntaxHelpMode) -> AttributedString {
        let resourceName: String
        switch mode {
        case .prose:        resourceName = "markdown-syntax"
        case .screenplay:   resourceName = "fountain-syntax"
        }
        guard let url = Bundle.main.url(
                forResource: resourceName, withExtension: "md"),
              let data = try? Data(contentsOf: url) else {
            return AttributedString("Help content unavailable.")
        }
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full)
        if let attributed = try? AttributedString(markdown: data, options: options) {
            return attributed
        }
        // Fallback to raw text on parse failure.
        if let raw = String(data: data, encoding: .utf8) {
            return AttributedString(raw)
        }
        return AttributedString("Help content unavailable.")
    }
}
