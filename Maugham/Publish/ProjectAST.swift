import Foundation
import MaughamCore

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

        /// Node index → the op-log `¶id` of the paragraph that node came from.
        /// SPARSE: a paragraph anchors only the FIRST node it produced, so a
        /// cue-and-speech block (one paragraph, three nodes) contributes one
        /// entry, and a paragraph that produced no node of its own — the tail
        /// of a fence split by an internal blank line — contributes none.
        ///
        /// `[:]` when the source handed no paragraphs (`PieceRef.paragraphs ==
        /// nil`) or when they could not be reconciled with `displayText`. The
        /// emitters read it to mint `\hypertarget{p-<tag>-<id>}` / `id="p-<tag>-<id>"`
        /// so a cross-link can point at a paragraph; the NODES are unaffected
        /// by its presence or absence.
        public let anchors: [Int: String]

        /// Footnote label → its definition, per piece; the FIRST definition of
        /// a label wins. A `[^label]: …` definition is not a node: it lives
        /// here, and `.footnoteRef(label:)` inlines point at it.
        public let footnotes: [String: [Inline]]

        /// EVERY top-level node index → the `¶id` of the paragraph its first
        /// line falls in. Dense where `anchors` is sparse: a paragraph that
        /// produced three nodes maps all three. The same span math as
        /// `anchors`, so `[:]` exactly when `anchors` is — no paragraphs, or
        /// paragraphs that don't reconcile with `displayText`. A publish
        /// problem reads it to name the paragraph an element came from.
        public let nodeParagraphs: [Int: String]

        /// Footnote label → the `¶id` of the paragraph holding the definition
        /// `footnotes` kept (the first). `[:]` when `nodeParagraphs` is.
        public let footnoteParagraphs: [String: String]

        /// Footnote label → one entry per DROPPED duplicate definition (a
        /// second, third… `[^label]:` in the piece; the first wins), in source
        /// order: the `¶id` of that duplicate's paragraph, or nil when the
        /// paragraphs don't reconcile. Empty when no label is defined twice.
        public let duplicateFootnotes: [String: [String?]]

        public init(pieceID: String, title: String, mode: Mode, nodes: [Node],
                    anchors: [Int: String] = [:],
                    footnotes: [String: [Inline]] = [:],
                    nodeParagraphs: [Int: String] = [:],
                    footnoteParagraphs: [String: String] = [:],
                    duplicateFootnotes: [String: [String?]] = [:]) {
            self.pieceID = pieceID
            self.title = title
            self.mode = mode
            self.nodes = nodes
            self.anchors = anchors
            self.footnotes = footnotes
            self.nodeParagraphs = nodeParagraphs
            self.footnoteParagraphs = footnoteParagraphs
            self.duplicateFootnotes = duplicateFootnotes
        }
    }

    public enum Mode: String, Equatable, Sendable {
        case prose
        case fountain

        /// The AST shape a manuscript of `format` is built into.
        public init(_ format: DocumentFormat) {
            switch format {
            case .markdown: self = .prose
            case .fountain: self = .fountain
            }
        }
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
        /// ATX `## Day 1/3` — a section title. `label` comes from a trailing
        /// `{#kind:name}`, already stripped from the inlines; nil for a plain
        /// heading. A label of the wrong kind is kept for the resolver to judge.
        case heading(level: Int, [Inline], label: ManuscriptLabel? = nil)
        indirect case blockquote([ProseNode]) // `> …` markdown blockquote
        case sceneBreak
        case list(ordered: Bool, items: [[Inline]])   // flat, tight `- x` / `1. x`
        case verbatim([String])               // ``` fenced block — a mangle guard, not code support
        /// A pipe table: one `[Inline]` per cell, one alignment per header
        /// column, and the `Table: …` caption and label under it.
        case table(header: [[Inline]], alignments: [TableAlignment], rows: [[[Inline]]],
                   caption: [Inline]?, label: ManuscriptLabel?)
        /// `![caption](path)` alone on its line. The path is as written; the
        /// resolver judges it.
        case figure(caption: [Inline], path: String, label: ManuscriptLabel?)
        // Inline emphasis/strong/code/wiki-links live inside
        // `paragraph([Inline])` via the `Inline` enum below — they are not
        // standalone block nodes.
    }

    /// Inline content within a prose paragraph. Nestable so real markdown
    /// like `**bold _italic_**` and `*em with **strong** inside*` round-trips:
    /// a single `String` payload can't represent nesting, an `[Inline]` can.
    public enum Inline: Equatable, Sendable {
        case text(String)
        case emphasis([Inline])               // *italic* (prose + fountain)
        case strong([Inline])                 // **bold**
        case strikethrough([Inline])          // ~~strike~~ (prose GFM only)
        case underline([Inline])              // _underline_ (fountain)
        case code(String)                     // `inline code` — never nests
        case wikiLink(target: String, display: String)
        case lineBreak                        // explicit "  \n" hard break
        // Report markers (prose only; Fountain never produces them).
        case footnoteRef(label: String)       // `[^label]` → `Section.footnotes[label]`
        case citation([CitationItem])         // `[@key, locator; @key]`
        case crossRef(ManuscriptLabel)        // `@fig:x`, `[@tbl:y]`
    }

    public enum FountainNode: Equatable, Sendable {
        case sceneHeading(String, sceneNumber: String?)
        case action([Inline])                 // emphasis-bearing
        case character(String)
        case dialogue([Inline])               // emphasis-bearing
        case parenthetical([Inline])          // emphasis-bearing
        case transition(String)
        case lyric([Inline])                  // emphasis-bearing; `~lyric line~`
        case centered([Inline])               // emphasis-bearing; `>centered<`
        case pageBreak                         // `===`
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
    static func heading(level: Int, _ inlines: [ProjectAST.Inline],
                        label: ManuscriptLabel? = nil) -> Self {
        .prose(.heading(level: level, inlines, label: label))
    }
    static func blockquote(_ nodes: [ProjectAST.ProseNode]) -> Self { .prose(.blockquote(nodes)) }
    static var sceneBreak: Self { .prose(.sceneBreak) }
}

// String convenience for the emphasis-bearing fountain nodes so callers and
// tests can write `.action("plain")` for unformatted text; the builder uses
// the `[Inline]` cases directly via `FountainInline.parse`.
public extension ProjectAST.FountainNode {
    static func sceneHeading(_ s: String) -> Self { .sceneHeading(s, sceneNumber: nil) }
    static func action(_ s: String) -> Self { .action([.text(s)]) }
    static func dialogue(_ s: String) -> Self { .dialogue([.text(s)]) }
    static func parenthetical(_ s: String) -> Self { .parenthetical([.text(s)]) }
    static func lyric(_ s: String) -> Self { .lyric([.text(s)]) }
    static func centered(_ s: String) -> Self { .centered([.text(s)]) }
}


/// The literal source of a report element, rebuilt from the AST. Tasks 5
/// and 6 KEEP it: it is what an element prints as when it has no rendering
/// (a nil resolution) or cannot be resolved — output never prints "??" (spec
/// §5.2). Until those tasks land, the emitters also use it for every report
/// element, so the build and the novel golden stay green between tasks.
///
/// It keeps the element's meaning but not its exact spelling:
/// - table cells come back as `| a | b |` rows on ONE paragraph line, the
///   delimiter row spelt `---`/`:--`/`:-:`/`--:`, and the caption as
///   `Table: …` on the same line;
/// - a citation comes back as `[@key, locator; @key]` with canonical
///   spacing. A bracket mixing keys and labels reads `[@a; @b]; @fig:x`
///   (ruling R-S4: the citation of every key, then each label);
/// - a footnote definition is not printed (it lives in `Section.footnotes`).
enum InterimReportLiteral {

    /// ` {#kind:name}` for a labelled heading, or nothing.
    static func labelSuffix(_ label: ManuscriptLabel?) -> [ProjectAST.Inline] {
        label.map { [.text(" {#\($0.reference)}")] } ?? []
    }

    static func table(header: [[ProjectAST.Inline]], alignments: [TableAlignment],
                      rows: [[[ProjectAST.Inline]]], caption: [ProjectAST.Inline]?,
                      label: ManuscriptLabel?) -> [ProjectAST.Inline] {
        func row(_ cells: [[ProjectAST.Inline]]) -> [ProjectAST.Inline] {
            var out: [ProjectAST.Inline] = [.text("|")]
            for cell in cells { out += [.text(" ")] + cell + [.text(" |")] }
            return out
        }
        let delimiter = alignments.map { alignment -> [ProjectAST.Inline] in
            switch alignment {
            case .none:     return [.text("---")]
            case .leading:  return [.text(":--")]
            case .center:   return [.text(":-:")]
            case .trailing: return [.text("--:")]
            }
        }
        var out = row(header) + [.text(" ")] + row(delimiter)
        for r in rows { out += [.text(" ")] + row(r) }
        if caption != nil || label != nil {
            out += [.text(" Table: ")] + (caption ?? []) + labelSuffix(label)
        }
        return out
    }

    static func figure(caption: [ProjectAST.Inline], path: String,
                       label: ManuscriptLabel?) -> [ProjectAST.Inline] {
        [.text("![")] + caption + [.text("](\(path))")] + labelSuffix(label)
    }

    static func footnoteRef(_ label: String) -> String { "[^\(label)]" }

    static func citation(_ items: [CitationItem]) -> String {
        "[" + items.map { item in
            "@" + item.key + (item.locator.map { ", " + $0 } ?? "")
        }.joined(separator: "; ") + "]"
    }

    static func crossRef(_ label: ManuscriptLabel) -> String { "@" + label.reference }
}
