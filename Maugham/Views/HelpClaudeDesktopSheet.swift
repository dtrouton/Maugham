import SwiftUI
import MaughamCore
import AppKit

struct HelpClaudeDesktopSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var state: ClaudeDesktopConfig.State = .missing
    @State private var showingManualSnippet: Bool = false
    @State private var errorMessage: String?
    @State private var copied: Bool = false

    private var binaryPath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/maugham-mcp").path
    }

    private var configURL: URL { ClaudeDesktopConfig.defaultConfigURL }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch state {
            case .missing:    missingView
            case .corrupt:    corruptView
            case .unconfigured: unconfiguredView
            case .stalePath(let oldPath): stalePathView(oldPath: oldPath)
            case .configured(let path):   configuredView(path: path)
            }
            if let err = errorMessage {
                Text(err).font(.callout).foregroundStyle(.red)
            }
            if showingManualSnippet { manualSnippet }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 580, minHeight: 360)
        .onAppear { detect() }
    }

    private func detect() {
        state = ClaudeDesktopConfig.detect(
            configURL: configURL, expectedBinary: binaryPath)
    }

    // MARK: State views

    private var missingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude Desktop isn't set up yet.").font(.title2).fontWeight(.semibold)
            Text("Install Claude Desktop, then come back to connect Maugham. Once connected, Claude can read your open projects and create research notes.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Get Claude Desktop") {
                    if let url = URL(string: "https://claude.ai/download") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Show manual setup") { showingManualSnippet.toggle() }
                    .buttonStyle(.borderless)
            }
        }
    }

    private var corruptView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Claude Desktop config can't be parsed.").font(.title2).fontWeight(.semibold)
            Text("We won't overwrite a config we don't understand. Add the snippet manually:")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            manualSnippet
            Button("Reveal Config in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([configURL])
            }
        }
    }

    private var unconfiguredView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Maugham isn't connected to Claude Desktop yet.").font(.title2).fontWeight(.semibold)
            Text("Claude will be able to:")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Label("Read your open projects, outlines, and chapters", systemImage: "book.closed")
                Label("Search across your manuscript and research", systemImage: "magnifyingglass")
                Label("Create new research notes for you", systemImage: "doc.badge.plus")
            }
            .font(.callout)
            HStack {
                Button("Configure") { runConfigure() }
                    .buttonStyle(.borderedProminent)
                Button("Show manual setup") { showingManualSnippet.toggle() }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func stalePathView(oldPath: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Maugham is connected, but the path is out of date.", systemImage: "exclamationmark.triangle")
                .font(.title3).fontWeight(.semibold)
            Text("Claude Desktop is pointing at:\n\(oldPath)\n\nUpdate it to this Maugham:\n\(binaryPath)")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Update Path") { runConfigure() }
                    .buttonStyle(.borderedProminent)
                Button("Reveal Config in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([configURL])
                }
            }
        }
    }

    private func configuredView(path: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Maugham is connected to Claude Desktop.", systemImage: "checkmark.circle.fill")
                .font(.title3).fontWeight(.semibold)
                .foregroundStyle(.green)
            Text("Try asking Claude: \"What chapters are in my novel?\"")
                .foregroundStyle(.secondary)
            Text(path).font(.caption).foregroundStyle(.tertiary)
            HStack {
                Button("Reveal Config in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([configURL])
                }
                Button("Remove", role: .destructive) { runRemove() }
            }
        }
    }

    private var manualSnippet: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Manual setup:").font(.callout).fontWeight(.medium)
            ScrollView {
                Text(snippetText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(4)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 140)
            HStack {
                Button(copied ? "Copied" : "Copy snippet") { copy() }
                Spacer()
                Text("Config: \(configURL.path)")
                    .font(.caption).foregroundStyle(.secondary)
                    .truncationMode(.middle).lineLimit(1)
            }
        }
    }

    private var snippetText: String {
        let key = BuildVariant.current.mcpServerKey
        let socket = BuildVariant.current.mcpSocketPath
        return """
        {
          "mcpServers": {
            "\(key)": {
              "command": "\(binaryPath)",
              "env": { "MAUGHAM_MCP_SOCKET": "\(socket)" }
            }
          }
        }
        """
    }

    // MARK: Actions

    private func runConfigure() {
        errorMessage = nil
        do {
            try ClaudeDesktopConfig.merge(
                configURL: configURL,
                maughamBinary: binaryPath,
                socketPath: BuildVariant.current.mcpSocketPath)
            detect()
        } catch ClaudeDesktopConfig.MergeError.existingConfigCorrupt {
            state = .corrupt
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func runRemove() {
        errorMessage = nil
        do {
            try ClaudeDesktopConfig.removeMaughamEntry(configURL: configURL)
            detect()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippetText, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
