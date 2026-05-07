import SwiftUI
import AppKit

struct HelpClaudeDesktopSheet: View {
    let projectURL: URL?
    let projectTitle: String?
    @Environment(\.dismiss) private var dismiss
    @State private var copied: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up Claude Desktop")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Claude Desktop can read your Maugham project folder via its built-in filesystem MCP server. Add the snippet below to Claude Desktop's `claude_desktop_config.json` and restart Claude Desktop.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Config snippet:")
                    .font(.callout)
                    .fontWeight(.medium)
                ScrollView {
                    Text(snippet)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(4)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 220)
                HStack {
                    Button(copied ? "Copied" : "Copy snippet") {
                        copySnippet()
                    }
                    Spacer()
                    Text("Config file: ~/Library/Application Support/Claude/claude_desktop_config.json")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 580, minHeight: 420)
    }

    private var snippet: String {
        let path = projectURL?.path ?? "<your-project-path>"
        let key = projectTitle.flatMap { Slugifier.slug(from: $0) } ?? "your-project"
        return """
        {
          "mcpServers": {
            "maugham-\(key)": {
              "command": "npx",
              "args": [
                "-y",
                "@modelcontextprotocol/server-filesystem",
                "\(path)"
              ]
            }
          }
        }
        """
    }

    private func copySnippet() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(snippet, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
