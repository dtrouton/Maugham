import Foundation

/// One classified line in a parsed Fountain script.
public struct FountainLine: Equatable, Sendable {
    /// NSRange in the source text covering this line, including the trailing
    /// newline if present (so consecutive lines' ranges are contiguous).
    public let range: NSRange

    /// Element classification.
    public let element: ScreenplayElement

    /// Visible content of the line — the source text minus any forced marker
    /// prefix (`@`, `!`, `.`, `>`, `~`, `#`, `=`) and minus the line's
    /// trailing newline. For `.boneyard` and `.note` the content includes
    /// the bracketing markers (so the styler can render them dim alongside
    /// the body).
    public let content: String

    /// True when the element was determined by a forced marker rather than
    /// by context-sensitive inference. Used by the styler to decide whether
    /// to apply display-uppercase.
    public let isForced: Bool

    /// Casing of `content`. Used by the styler to decide whether display-
    /// uppercase substitution is needed.
    public let sourceCase: SourceCase

    /// Sub-range markers (currently inline notes only). Empty for most lines.
    public let inlineSpans: [FountainInlineSpan]

    public init(
        range: NSRange,
        element: ScreenplayElement,
        content: String,
        isForced: Bool,
        sourceCase: SourceCase,
        inlineSpans: [FountainInlineSpan] = []
    ) {
        self.range = range
        self.element = element
        self.content = content
        self.isForced = isForced
        self.sourceCase = sourceCase
        self.inlineSpans = inlineSpans
    }
}
