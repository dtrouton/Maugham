import SwiftUI

public enum SyntaxHelpMode {
    case prose
    case screenplay
}

// MARK: - Block model

enum HelpBlock {
    case heading(level: Int, text: String)
    case paragraph(text: AttributedString)
    case codeBlock(text: String)
    case bullet(text: AttributedString)
}

// MARK: - Main view

struct SyntaxHelpSheet: View {
    let mode: SyntaxHelpMode
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: Tab

    enum Tab: String, Hashable {
        case markdown, fountain, keyboard
    }

    init(mode: SyntaxHelpMode) {
        self.mode = mode
        switch mode {
        case .prose:      self._selectedTab = State(initialValue: .markdown)
        case .screenplay: self._selectedTab = State(initialValue: .fountain)
        }
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $selectedTab) {
                SyntaxHelpBlocksView(mode: .prose)
                    .tabItem { Text("Markdown") }
                    .tag(Tab.markdown)
                SyntaxHelpBlocksView(mode: .screenplay)
                    .tabItem { Text("Fountain") }
                    .tag(Tab.fountain)
                KeyboardCheatsheetView()
                    .tabItem { Text("Keyboard") }
                    .tag(Tab.keyboard)
            }
            .padding(.top, 8)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .navigationTitle("Reference")
        }
        .frame(minWidth: 640, minHeight: 480)
    }

    // MARK: - Content loading

    static func loadContent(mode: SyntaxHelpMode) -> [HelpBlock] {
        let resourceName: String
        switch mode {
        case .prose:        resourceName = "markdown-syntax"
        case .screenplay:   resourceName = "fountain-syntax"
        }
        guard let url = Bundle.main.url(
                forResource: resourceName, withExtension: "md"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else {  // adr-0018-ok: bundled syntax-help doc read, not manuscript
            return [.paragraph(text: AttributedString("Help content unavailable."))]
        }
        return parseMarkdownBlocks(raw)
    }

    // MARK: - Block parser

    static func parseMarkdownBlocks(_ raw: String) -> [HelpBlock] {
        var result: [HelpBlock] = []
        let lines = raw.components(separatedBy: "\n")
        var index = 0

        enum State {
            case normal
            case inCode(buffer: [String])
        }
        var state: State = .normal

        while index < lines.count {
            let line = lines[index]

            switch state {
            case .inCode(var buffer):
                if line.trimmingCharacters(in: .whitespaces) == "```" {
                    result.append(.codeBlock(text: buffer.joined(separator: "\n")))
                    state = .normal
                } else {
                    buffer.append(line)
                    state = .inCode(buffer: buffer)
                }
                index += 1

            case .normal:
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                if trimmed.isEmpty {
                    index += 1
                } else if trimmed.hasPrefix("```") {
                    state = .inCode(buffer: [])
                    index += 1
                } else if trimmed.hasPrefix("###### ") {
                    result.append(.heading(level: 6, text: String(trimmed.dropFirst(7))))
                    index += 1
                } else if trimmed.hasPrefix("##### ") {
                    result.append(.heading(level: 5, text: String(trimmed.dropFirst(6))))
                    index += 1
                } else if trimmed.hasPrefix("#### ") {
                    result.append(.heading(level: 4, text: String(trimmed.dropFirst(5))))
                    index += 1
                } else if trimmed.hasPrefix("### ") {
                    result.append(.heading(level: 3, text: String(trimmed.dropFirst(4))))
                    index += 1
                } else if trimmed.hasPrefix("## ") {
                    result.append(.heading(level: 2, text: String(trimmed.dropFirst(3))))
                    index += 1
                } else if trimmed.hasPrefix("# ") {
                    result.append(.heading(level: 1, text: String(trimmed.dropFirst(2))))
                    index += 1
                } else if trimmed.hasPrefix("- ") {
                    result.append(.bullet(text: parseInline(String(trimmed.dropFirst(2)))))
                    index += 1
                } else {
                    // Paragraph: collect contiguous non-blank, non-special lines
                    var paragraphLines: [String] = []
                    while index < lines.count {
                        let pLine = lines[index]
                        let pTrimmed = pLine.trimmingCharacters(in: .whitespaces)
                        if pTrimmed.isEmpty
                            || pTrimmed.hasPrefix("#")
                            || pTrimmed.hasPrefix("- ")
                            || pTrimmed.hasPrefix("```") {
                            break
                        }
                        paragraphLines.append(pTrimmed)
                        index += 1
                    }
                    let joined = paragraphLines.joined(separator: " ")
                    result.append(.paragraph(text: parseInline(joined)))
                }
            }
        }

        return result
    }

    // MARK: - Inline markdown helper

    static func parseInline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s)) ?? AttributedString(s)
    }
}

// MARK: - Per-mode blocks view

/// Renders a single help mode's blocks. Used inside each tab of SyntaxHelpSheet.
private struct SyntaxHelpBlocksView: View {
    let mode: SyntaxHelpMode
    @State private var blocks: [HelpBlock] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    blockView(for: block)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .task(id: mode) {
            blocks = SyntaxHelpSheet.loadContent(mode: mode)
        }
    }

    @ViewBuilder
    private func blockView(for block: HelpBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            headingView(level: level, text: text)
        case .paragraph(let attributed):
            Text(attributed)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .codeBlock(let text):
            Text(text)
                .font(.system(.body, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(6)
        case .bullet(let attributed):
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                    .font(.body)
                Text(attributed)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func headingView(level: Int, text: String) -> some View {
        switch level {
        case 1:
            Text(text).font(.title2).bold().padding(.top, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
        case 2:
            Text(text).font(.title3).bold().padding(.top, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
        case 3:
            Text(text).font(.headline).padding(.top, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        default:
            Text(text).font(.subheadline).bold()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
