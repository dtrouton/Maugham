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
    }

    public let range: NSRange
    public let kind: Kind

    public init(range: NSRange, kind: Kind) {
        self.range = range
        self.kind = kind
    }
}
