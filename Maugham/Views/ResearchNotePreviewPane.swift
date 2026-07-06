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

    enum Block {
        case heading(level: Int, text: String)
        case paragraph(AttributedString)
        case image(NSImage)
        case unknown(String)
    }

    private func parsedBlocks() -> [Block] {
        Self.parse(text: noteText, notePath: notePath, projectURL: projectURL)
    }

    /// Exposed as `static` (rather than an instance method) so tests can drive
    /// the parse step directly, mirroring `GuideMarkdownView.parse`.
    ///
    /// Consecutive non-empty, non-heading, non-solo-image lines accumulate into
    /// a single `.paragraph` block (joined with a space) so hard-wrapped prose
    /// renders as one flowing paragraph instead of stacked line fragments. The
    /// buffer flushes on a blank line, a heading, a solo image, or end of text.
    static func parse(text: String, notePath: String, projectURL: URL) -> [Block] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [Block] = []
        var paragraphBuffer: [String] = []
        let imageRegex = try? NSRegularExpression(
            pattern: #"^!\[.*?\]\((\.[/][^)]+)\)$"#)
        let headingRegex = try? NSRegularExpression(
            pattern: #"^(#{1,6})\s+(.+)$"#)

        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            let joined = paragraphBuffer.joined(separator: " ")
            paragraphBuffer.removeAll()
            if let attr = try? AttributedString(markdown: joined) {
                blocks.append(.paragraph(attr))
            } else {
                blocks.append(.unknown(joined))
            }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            // Heading detection: # through ######
            // AttributedString(markdown:) uses inline-only parsing by default,
            // so block-level constructs like headings must be detected here.
            if let regex = headingRegex {
                let range = NSRange(location: 0, length: (trimmed as NSString).length)
                if let match = regex.firstMatch(in: trimmed, range: range),
                   match.numberOfRanges >= 3 {
                    let hashes = (trimmed as NSString).substring(with: match.range(at: 1))
                    let text   = (trimmed as NSString).substring(with: match.range(at: 2))
                    flushParagraph()
                    blocks.append(.heading(level: hashes.count, text: text))
                    continue
                }
            }

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
                        flushParagraph()
                        blocks.append(.image(img))
                        continue
                    }
                }
            }

            paragraphBuffer.append(trimmed)
        }
        flushParagraph()
        return blocks
    }

    @ViewBuilder
    private func render(block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .font(headingFont(forLevel: level))
                .fontWeight(.bold)
                .padding(.top, level == 1 ? 8 : 4)
                .frame(maxWidth: .infinity, alignment: .leading)
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

    private func headingFont(forLevel level: Int) -> Font {
        switch level {
        case 1:  return .title
        case 2:  return .title2
        case 3:  return .title3
        case 4:  return .headline
        default: return .subheadline
        }
    }
}
