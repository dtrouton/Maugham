import SwiftUI

/// Read-only markdown renderer for bundled help topics. Block parser mirrors
/// `ResearchNotePreviewPane` (headings + inline-markdown paragraphs) plus
/// bullets and fenced code; no project-relative image resolution.
struct GuideMarkdownView: View {
    let markdown: String

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(String)
        case code(String)
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var inCode = false
        var codeLines: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw

            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode { blocks.append(.code(codeLines.joined(separator: "\n"))); codeLines = [] }
                inCode.toggle()
                continue
            }
            if inCode { codeLines.append(line); continue }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix { $0 == "#" }.count
                let body = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: min(hashes, 6), text: body))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                blocks.append(.bullet(String(trimmed.dropFirst(2))))
            } else {
                blocks.append(.paragraph(trimmed))
            }
        }
        if inCode, !codeLines.isEmpty { blocks.append(.code(codeLines.joined(separator: "\n"))) }
        return blocks
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(Self.parse(markdown).enumerated()), id: \.offset) { _, block in
                    render(block)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }

    @ViewBuilder private func render(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .font(headingFont(level)).fontWeight(.semibold)
                .padding(.top, level <= 2 ? 10 : 4)
                .textSelection(.enabled)
        case .paragraph(let text):
            Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
                .textSelection(.enabled)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
            }.textSelection(.enabled)
        case .code(let code):
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .textSelection(.enabled)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level { case 1: return .title; case 2: return .title2; case 3: return .title3; default: return .headline }
    }
}
