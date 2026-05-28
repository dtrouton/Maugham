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

        // Deprecated top-level cases — retained only while the emitters and
        // tests migrate to the `Inline`-carrying paragraph shape. Inline
        // emphasis/strong now live inside `paragraph([Inline])` via `Inline`
        // below. Deleted in the body-emitter overhaul's Phase 5.
        case emphasis(String)
        case strong(String)
        case wikiLink(target: String, display: String)
    }

    /// Inline content within a prose paragraph. Nestable so real markdown
    /// like `**bold _italic_**` and `*em with **strong** inside*` round-trips:
    /// a single `String` payload can't represent nesting, an `[Inline]` can.
    public enum Inline: Equatable, Sendable {
        case text(String)
        case emphasis([Inline])               // *italic* / _italic_
        case strong([Inline])                 // **bold**
        case code(String)                     // `inline code` — never nests
        case wikiLink(target: String, display: String)
        case lineBreak                        // explicit "  \n" hard break
    }

    public enum FountainNode: Equatable, Sendable {
        case sceneHeading(String)
        case action(String)
        case character(String)
        case dialogue(String)
        case parenthetical(String)
        case transition(String)
        case dualDialogue(left: [FountainNode], right: [FountainNode])
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
    static func emphasis(_ s: String)  -> Self { .prose(.emphasis(s)) }
    static func strong(_ s: String)    -> Self { .prose(.strong(s)) }
    static func wikiLink(target: String, display: String) -> Self {
        .prose(.wikiLink(target: target, display: display))
    }
    static var sceneBreak: Self { .prose(.sceneBreak) }
}
