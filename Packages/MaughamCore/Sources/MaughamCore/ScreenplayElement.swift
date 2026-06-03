import Foundation

/// A Fountain screenplay element classification. Each FountainLine carries one.
public enum ScreenplayElement: Equatable, Hashable, Sendable {
    case action
    case sceneHeading
    case character
    case dialogue
    case parenthetical
    case transition
    case centered
    case lyric
    case section(level: Int)   // 1...6
    case synopsis
    case pageBreak
    case boneyard              // line is part of a /* ... */ block
    case note                  // line is part of a multi-line [[ ... ]] block
    case titlePage             // line is part of the title page block at document head
}

/// Casing of the *content* portion of a FountainLine (after stripping any
/// forced marker like `@` or `.`).
public enum SourceCase: Equatable, Hashable, Sendable {
    case upper      // all letters uppercase
    case mixed      // both cases present
    case lower      // all letters lowercase
    case neutral    // no letters (punctuation/digits only)
}

/// Sub-range classification within a FountainLine — used to mark
/// inline `[[ ... ]]` notes and emphasis spans (*italic*, **bold**, _underline_).
public struct FountainInlineSpan: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case note
        /// Content (markers already excluded) carrying combined font traits.
        case emphasis(EmphasisTraits)
        /// An asterisk-marker range to fade. Carries no font change.
        case emphasisMarker
        case underline
    }
    public let range: NSRange
    public let kind: Kind

    public init(range: NSRange, kind: Kind) {
        self.range = range
        self.kind = kind
    }
}

/// One key/value field in a Fountain title page block. Multi-line values
/// (continuation indent) join with newlines.
public struct TitlePageField: Equatable, Sendable {
    /// Canonical-cased key, e.g., "Title", "Author", "Credit". Recognized
    /// keys are normalized; unknown keys are preserved as-typed.
    public let key: String
    /// Value text (may span multiple source lines, joined with `\n`).
    public let value: String
    /// NSRange covering the entire field in source (key + colon + value
    /// + any continuation lines).
    public let range: NSRange

    public init(key: String, value: String, range: NSRange) {
        self.key = key
        self.value = value
        self.range = range
    }
}
