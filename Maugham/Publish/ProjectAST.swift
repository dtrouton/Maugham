import Foundation

/// Target-agnostic representation of a compilable project. Built by
/// `ProjectASTBuilder` from a project's pieces in binder order; consumed
/// by `LaTeXBodyEmitter` and `XHTMLBodyEmitter`.
public struct ProjectAST: Equatable, Sendable {
    public let sections: [Section]

    public init(sections: [Section]) {
        self.sections = sections
    }

    public struct Section: Equatable, Sendable {
        public let pieceID: String
        public let title: String
        public let mode: Mode
        public let nodes: [Node]

        public init(pieceID: String, title: String, mode: Mode, nodes: [Node]) {
            self.pieceID = pieceID
            self.title = title
            self.mode = mode
            self.nodes = nodes
        }
    }

    public enum Mode: String, Equatable, Sendable {
        case prose
        case fountain
    }

    /// Inline or block node. Each section's nodes are exhaustively in one of the
    /// two mode-specific shapes — `prose` mode uses `.prose` cases, `fountain`
    /// uses `.fountain` cases. Mixing isn't valid AST but the type permits it
    /// (callers responsible).
    public enum Node: Equatable, Sendable {
        case prose(ProseNode)
        case fountain(FountainNode)
    }

    public enum ProseNode: Equatable, Sendable {
        case paragraph([Inline])              // a run of inline content
        case heading(level: Int, [Inline])    // ATX `## Day 1/3` — section title
        indirect case blockquote([ProseNode]) // `> …` markdown blockquote
        case sceneBreak
        // Inline emphasis/strong/code/wiki-links live inside
        // `paragraph([Inline])` via the `Inline` enum below — they are not
        // standalone block nodes.
    }

    /// Inline content within a prose paragraph. Nestable so real markdown
    /// like `**bold _italic_**` and `*em with **strong** inside*` round-trips:
    /// a single `String` payload can't represent nesting, an `[Inline]` can.
    public enum Inline: Equatable, Sendable {
        case text(String)
        case emphasis([Inline])               // *italic* / _italic_ (prose)
        case strong([Inline])                 // **bold**
        case underline([Inline])              // _underline_ (fountain)
        case code(String)                     // `inline code` — never nests
        case wikiLink(target: String, display: String)
        case lineBreak                        // explicit "  \n" hard break
    }

    public enum FountainNode: Equatable, Sendable {
        case sceneHeading(String)
        case action([Inline])                 // emphasis-bearing
        case character(String)
        case dialogue([Inline])               // emphasis-bearing
        case parenthetical([Inline])          // emphasis-bearing
        case transition(String)
        case titlePage([TitleField])          // Fountain title-page block
        indirect case dualDialogue(left: [FountainNode], right: [FountainNode])
    }

    /// One key/value pair from a Fountain title-page block. Keys are
    /// canonicalized (Title, Credit, Author, Source, Draft date, Contact,
    /// Copyright, Notes); unknown keys are preserved as-typed. Multi-line
    /// values join with "\n".
    public struct TitleField: Equatable, Sendable {
        public let key: String
        public let value: String
        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }
}

// Convenience constructors so tests/builders can write
//   .paragraph("foo")  instead of  .prose(.paragraph("foo"))
public extension ProjectAST.Node {
    static func paragraph(_ inlines: [ProjectAST.Inline]) -> Self { .prose(.paragraph(inlines)) }
    static func paragraph(_ s: String) -> Self { .prose(.paragraph([.text(s)])) }
    static func heading(level: Int, _ inlines: [ProjectAST.Inline]) -> Self {
        .prose(.heading(level: level, inlines))
    }
    static func blockquote(_ nodes: [ProjectAST.ProseNode]) -> Self { .prose(.blockquote(nodes)) }
    static var sceneBreak: Self { .prose(.sceneBreak) }
}

// String convenience for the emphasis-bearing fountain nodes so callers and
// tests can write `.action("plain")` for unformatted text; the builder uses
// the `[Inline]` cases directly via `FountainInline.parse`.
public extension ProjectAST.FountainNode {
    static func action(_ s: String) -> Self { .action([.text(s)]) }
    static func dialogue(_ s: String) -> Self { .dialogue([.text(s)]) }
    static func parenthetical(_ s: String) -> Self { .parenthetical([.text(s)]) }
}
