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
        case paragraph(String)        // plain text, no inline markers
        case emphasis(String)         // italics
        case strong(String)
        case wikiLink(target: String, display: String)
        case sceneBreak
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
    static func paragraph(_ s: String) -> Self { .prose(.paragraph(s)) }
    static func emphasis(_ s: String)  -> Self { .prose(.emphasis(s)) }
    static func strong(_ s: String)    -> Self { .prose(.strong(s)) }
    static func wikiLink(target: String, display: String) -> Self {
        .prose(.wikiLink(target: target, display: display))
    }
    static var sceneBreak: Self { .prose(.sceneBreak) }
}
