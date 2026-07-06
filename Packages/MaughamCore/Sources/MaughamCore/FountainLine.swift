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

    /// True when this line is the `^`-marked second half of a dual-dialogue
    /// pair, OR a dialogue / parenthetical line that follows such a cue in
    /// the same block. The renderer uses this to apply deeper paragraph
    /// indents; the page-count helper uses it to pair adjacent blocks.
    public let isDualSecond: Bool

    /// Casing of `content`. Used by the styler to decide whether display-
    /// uppercase substitution is needed.
    public let sourceCase: SourceCase

    /// Inline sub-range markers within this line: emphasis (`*italic*`,
    /// `**bold**`, `_underline_`) and inline `[[notes]]`. Document-relative
    /// ranges (same coordinate space as `range`). Empty for lines with no
    /// inline markup. Both surfaces consume these — the Mac editor
    /// (`ScreenplayMode.applyInlineSpan`) and the iOS reader
    /// (`FountainSemanticRenderer`) — so neither re-parses emphasis.
    public let inlineSpans: [FountainInlineSpan]

    /// Scene number lifted from a `.sceneHeading` line's trailing `#…#`
    /// bracket (e.g. `INT. HOUSE - DAY #12#` → "12"). Nil for every other
    /// element and for scene headings without an explicit number. Populated
    /// by the tokenizer (Task 11); stays nil until then.
    public let sceneNumber: String?

    public init(
        range: NSRange,
        element: ScreenplayElement,
        content: String,
        isForced: Bool,
        sourceCase: SourceCase,
        isDualSecond: Bool = false,
        inlineSpans: [FountainInlineSpan] = [],
        sceneNumber: String? = nil
    ) {
        self.range = range
        self.element = element
        self.content = content
        self.isForced = isForced
        self.sourceCase = sourceCase
        self.isDualSecond = isDualSecond
        self.inlineSpans = inlineSpans
        self.sceneNumber = sceneNumber
    }
}
