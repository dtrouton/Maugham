import Foundation

/// A census of what block/inline element kinds a compiled book actually
/// contains, keyed to the first piece each kind appears in. A publish
/// DESIGN (template/stylesheet) has to account for every kind present —
/// this is the source of truth for "does this design handle blockquotes,
/// dual dialogue, wiki-links…".
///
/// `Kind`'s case list mirrors `ProjectAST`'s own node vocabulary one-for-one
/// on purpose: `take(from:)` switches over `ProjectAST.Node`,
/// `.ProseNode`, `.FountainNode` and `.Inline` with NO `default:` arm, so a
/// new AST case fails this file to compile until `Kind` and the switch both
/// grow a matching arm — the `SynthesisSource` discipline (tripwire 12):
/// adding a case is a compile-time event here, never a silent gap.
public struct ElementCensus: Equatable, Sendable {
    public let kinds: Set<Kind>
    public let firstPiece: [Kind: String]

    public init(kinds: Set<Kind>, firstPiece: [Kind: String]) {
        self.kinds = kinds
        self.firstPiece = firstPiece
    }

    /// Fountain kinds are their own cases, never collapsed onto their prose
    /// look-alikes (`.sceneHeading` is not `.heading`; `.dialogue` is not
    /// `.paragraph`) — the AST distinguishes them and a design needs to know
    /// which mode it's accounting for.
    public enum Kind: Hashable, Sendable, CaseIterable {
        // Prose block kinds
        case paragraph
        case heading
        case blockquote
        case sceneBreak
        case list
        case verbatim

        // Fountain block kinds
        case sceneHeading
        case action
        case character
        case dialogue
        case parenthetical
        case transition
        case lyric
        case centered
        case pageBreak
        case titlePage
        case dualDialogue

        // Inline kinds — one shared vocabulary, since `ProjectAST.Inline`
        // doesn't restate itself per mode.
        case emphasis
        case strong
        case strikethrough
        case underline
        case code
        case wikiLink
        case lineBreak
    }

    /// Writer-facing label for one kind — the ONE spelling (`ProductionRole`'s
    /// discipline), shared by `SamplePageSelection`'s `demonstrates` lines and
    /// `DesignerBriefing`'s census section so the two surfaces can never drift
    /// into naming the same kind two different ways.
    public static func label(for kind: Kind) -> String {
        switch kind {
        case .paragraph: return "paragraph"
        case .heading: return "heading"
        case .blockquote: return "blockquote"
        case .sceneBreak: return "scene break"
        case .list: return "list"
        case .verbatim: return "code block"
        case .sceneHeading: return "scene heading"
        case .action: return "action"
        case .character: return "character cue"
        case .dialogue: return "dialogue"
        case .parenthetical: return "parenthetical"
        case .transition: return "transition"
        case .lyric: return "verse"
        case .centered: return "centered text"
        case .pageBreak: return "page break"
        case .titlePage: return "title page"
        case .dualDialogue: return "dual dialogue"
        case .emphasis: return "emphasis"
        case .strong: return "strong emphasis"
        case .strikethrough: return "strikethrough"
        case .underline: return "underline"
        case .code: return "inline code"
        case .wikiLink: return "wiki-link"
        case .lineBreak: return "line break"
        }
    }

    public static func take(from ast: ProjectAST) -> ElementCensus {
        var kinds: Set<Kind> = []
        var firstPiece: [Kind: String] = [:]

        func record(_ kind: Kind, in pieceID: String) {
            kinds.insert(kind)
            if firstPiece[kind] == nil {
                firstPiece[kind] = pieceID
            }
        }

        func walk(_ inline: ProjectAST.Inline, in pieceID: String) {
            switch inline {
            case .text:
                break
            case .emphasis(let inner):
                record(.emphasis, in: pieceID)
                walk(inner, in: pieceID)
            case .strong(let inner):
                record(.strong, in: pieceID)
                walk(inner, in: pieceID)
            case .strikethrough(let inner):
                record(.strikethrough, in: pieceID)
                walk(inner, in: pieceID)
            case .underline(let inner):
                record(.underline, in: pieceID)
                walk(inner, in: pieceID)
            case .code:
                record(.code, in: pieceID)
            case .wikiLink:
                record(.wikiLink, in: pieceID)
            case .lineBreak:
                record(.lineBreak, in: pieceID)
            }
        }

        func walk(_ inlines: [ProjectAST.Inline], in pieceID: String) {
            for inline in inlines { walk(inline, in: pieceID) }
        }

        func walk(_ node: ProjectAST.ProseNode, in pieceID: String) {
            switch node {
            case .paragraph(let inlines):
                record(.paragraph, in: pieceID)
                walk(inlines, in: pieceID)
            case .heading(_, let inlines):
                record(.heading, in: pieceID)
                walk(inlines, in: pieceID)
            case .blockquote(let nested):
                record(.blockquote, in: pieceID)
                for n in nested { walk(n, in: pieceID) }
            case .sceneBreak:
                record(.sceneBreak, in: pieceID)
            case .list(_, let items):
                record(.list, in: pieceID)
                for item in items { walk(item, in: pieceID) }
            case .verbatim:
                record(.verbatim, in: pieceID)
            }
        }

        func walk(_ node: ProjectAST.FountainNode, in pieceID: String) {
            switch node {
            case .sceneHeading:
                record(.sceneHeading, in: pieceID)
            case .action(let inlines):
                record(.action, in: pieceID)
                walk(inlines, in: pieceID)
            case .character:
                record(.character, in: pieceID)
            case .dialogue(let inlines):
                record(.dialogue, in: pieceID)
                walk(inlines, in: pieceID)
            case .parenthetical(let inlines):
                record(.parenthetical, in: pieceID)
                walk(inlines, in: pieceID)
            case .transition:
                record(.transition, in: pieceID)
            case .lyric(let inlines):
                record(.lyric, in: pieceID)
                walk(inlines, in: pieceID)
            case .centered(let inlines):
                record(.centered, in: pieceID)
                walk(inlines, in: pieceID)
            case .pageBreak:
                record(.pageBreak, in: pieceID)
            case .titlePage:
                record(.titlePage, in: pieceID)
            case .dualDialogue(let left, let right):
                record(.dualDialogue, in: pieceID)
                for n in left { walk(n, in: pieceID) }
                for n in right { walk(n, in: pieceID) }
            }
        }

        for section in ast.sections {
            for node in section.nodes {
                switch node {
                case .prose(let p):
                    walk(p, in: section.pieceID)
                case .fountain(let f):
                    walk(f, in: section.pieceID)
                }
            }
        }

        return ElementCensus(kinds: kinds, firstPiece: firstPiece)
    }
}
