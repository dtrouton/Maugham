import Foundation

/// A classified range of source text, produced by a `WritingMode`'s tokenizer
/// and consumed by the editor coordinator to apply theme attributes.
public struct Token: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case heading(level: Int)
        case emphasis(strong: Bool)
        case code
        case link(href: String)
        case wikiLink(title: String)
        case listMarker
        case blockquote
        case horizontalRule
        case syntaxPunctuation
        case plain
        case fountainElement(ScreenplayElement, isForced: Bool)
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
    }

    public let range: NSRange
    public let kind: Kind

    public init(range: NSRange, kind: Kind) {
        self.range = range
        self.kind = kind
    }
}
