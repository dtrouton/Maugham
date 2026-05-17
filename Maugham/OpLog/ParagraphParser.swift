// Maugham/OpLog/ParagraphParser.swift
import Foundation

public struct ParsedParagraph: Equatable, Sendable {
    public let id: String?
    public let text: String
    public init(id: String?, text: String) {
        self.id = id
        self.text = text
    }
}

public enum ParagraphParser {
    /// Split markdown text into paragraphs by blank lines. An optional
    /// `<!-- ¶id -->` comment immediately preceding a paragraph attaches
    /// its id to that paragraph. Stray comments without a following text
    /// block are discarded.
    public static func parse(_ markdown: String) -> [ParsedParagraph] {
        var result: [ParsedParagraph] = []
        var pendingId: String? = nil
        var buffer: [String] = []

        func flushParagraph() {
            guard !buffer.isEmpty else { return }
            let text = buffer.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                result.append(ParsedParagraph(id: pendingId, text: text))
            }
            buffer.removeAll(keepingCapacity: true)
            pendingId = nil
        }

        let lines = markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for line in lines {
            let s = String(line)
            if s.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
                continue
            }
            if let id = ParagraphID.parseComment(s) {
                // Comment lines flush any in-progress buffer and stash the id
                // for the next paragraph. Existing pendingId (from a prior
                // stray comment) is replaced.
                flushParagraph()
                pendingId = id
                continue
            }
            buffer.append(s)
        }
        flushParagraph()
        return result
    }
}
