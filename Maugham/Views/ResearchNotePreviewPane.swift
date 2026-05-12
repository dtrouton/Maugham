import SwiftUI
import AppKit

/// Renders a research note's Markdown text as a read-only preview pane,
/// displaying inline images referenced via Markdown ![alt](path) syntax.
/// Editor stays plain text; the writer sees the rendered version here.
struct ResearchNotePreviewPane: View {
    let notePath: String       // e.g., "research/sarah.md"
    let projectURL: URL
    let noteText: String        // bound from the editor's text state (read-only here)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(parsedBlocks().indices, id: \.self) { i in
                    render(block: parsedBlocks()[i])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }

    private enum Block {
        case paragraph(AttributedString)
        case image(NSImage)
        case unknown(String)
    }

    private func parsedBlocks() -> [Block] {
        let lines = noteText.components(separatedBy: "\n")
        var blocks: [Block] = []
        let imageRegex = try? NSRegularExpression(
            pattern: #"^!\[.*?\]\((\.[/][^)]+)\)$"#)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // Detect solo image reference
            if let regex = imageRegex {
                let range = NSRange(location: 0, length: (trimmed as NSString).length)
                if let match = regex.firstMatch(in: trimmed, range: range),
                   match.numberOfRanges >= 2 {
                    let pathRange = match.range(at: 1)
                    let relPath = (trimmed as NSString).substring(with: pathRange)
                    let trimmedRel = relPath.hasPrefix("./")
                        ? String(relPath.dropFirst(2))
                        : relPath
                    let noteDir = projectURL
                        .appendingPathComponent(notePath)
                        .deletingLastPathComponent()
                    let imageURL = noteDir.appendingPathComponent(trimmedRel)
                    if let img = NSImage(contentsOf: imageURL) {
                        blocks.append(.image(img))
                        continue
                    }
                }
            }

            // Try Markdown inline parsing for regular paragraphs
            if let attr = try? AttributedString(markdown: trimmed) {
                blocks.append(.paragraph(attr))
            } else {
                blocks.append(.unknown(trimmed))
            }
        }
        return blocks
    }

    @ViewBuilder
    private func render(block: Block) -> some View {
        switch block {
        case .paragraph(let attr):
            Text(attr)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .image(let img):
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 320)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        case .unknown(let raw):
            Text(raw)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}
