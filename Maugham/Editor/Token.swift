import Foundation
import MaughamCore

/// A classified range of source text, produced by a `WritingMode`'s tokenizer
/// and consumed by the editor coordinator to apply theme attributes.
public struct Token: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case heading(level: Int)
        case emphasis(EmphasisTraits)
        case code
        case link(href: String)
        case wikiLink(title: String)
        case listMarker
        case blockquote
        case horizontalRule
        case syntaxPunctuation
        case plain
        /// `isDualSecond` is part of token IDENTITY on purpose: dual-dialogue
        /// state is inherited by dialogue/parenthetical lines from the
        /// preceding CHARACTER cue's trailing `^` (see FountainTokenizer), so
        /// it can change without the line's own text changing. Carrying it
        /// here means `TokenRestyleWindow`'s (kind, length) diff sees the
        /// followers (and a same-length `^`-overtype on the cue itself) as
        /// changed and re-styles them — without it, a `BARRY ^` → `BARRY`
        /// edit strands the followers' dual-column indents. Pinned by
        /// `WindowedTypographyEquivalenceTests` dual-caret cases.
        case fountainElement(ScreenplayElement, isForced: Bool, isDualSecond: Bool)
        /// `- [ ]` / `- [x]` markdown checkbox glyph. The `range` on the
        /// containing `Token` covers exactly the 3 chars of `[ ]`/`[x]`.
        /// The line prefix (`(\s*)- `) is emitted as `.syntaxPunctuation`
        /// alongside; the body is left to fill-with-plain.
        case checkbox(checked: Bool)

        /// Body text of an inline task (`- [ ] body` or `[[todo: body]]`).
        /// The range covers only the body content — not the bracket glyph,
        /// list marker, or anchor span. `done` signals checked state so
        /// painters can apply strikethrough.
        case taskBody(done: Bool)

        /// `<!--t-XXXXXX-->` task-anchor span (optionally with a leading
        /// space for markdown line tasks). Painted fully transparent so the
        /// anchor lives in NSTextStorage without being visible to the writer.
        case invisibleAnchor

        // MARK: Report elements (report foundations plan 3a)
        //
        // None carries an associated value: `TokenRestyleWindow`'s oracle
        // compares `(kind, length)`, so a value that could change without the
        // text changing (a resolved "Figure 3") would make it disagree. The
        // resolved labels are plan 3b's drawn overlay, never a token payload.

        /// A table's unescaped `|` pipes, and its whole delimiter row.
        case tableSyntax
        /// One header-row cell's text (trimmed). An OVERLAY: appended after
        /// the gap fill like `taskBody`, so emphasis, citations and footnote
        /// references inside a header cell keep their own tokens; the paint
        /// adds the bold trait on top of whatever font they set.
        case tableHeader
        /// A table's `Table: …` caption line, up to its `{#…}` block.
        case tableCaption
        /// The whole table, header row through caption line. An OVERLAY with
        /// no styling of its own: it is how a caret finds its enclosing table
        /// (`MarkdownTokenizer.tableBlockRange(containing:in:)`).
        case tableBlock
        /// `[^label]` inside a sentence.
        case footnoteReference
        /// `[^label]:` at the head of a footnote definition.
        case footnoteLabel
        /// `[@key]`, `[@key, p. 12]`, `[@a; @b]` (as `ManuscriptInlineScanner`
        /// ranges it).
        case citation
        /// `@fig:name`, or `[@fig:name]` in brackets.
        case crossReference
        /// A figure line's `![` and its `](path)`; the caption between stays
        /// prose.
        case figureSyntax
        /// A trailing `{#kind:name}` label on a heading, a table caption or a
        /// figure line.
        case attributeBlock
    }

    public let range: NSRange
    public let kind: Kind

    public init(range: NSRange, kind: Kind) {
        self.range = range
        self.kind = kind
    }
}
