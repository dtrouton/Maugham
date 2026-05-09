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
}

/// Casing of the *content* portion of a FountainLine (after stripping any
/// forced marker like `@` or `.`).
public enum SourceCase: Equatable, Hashable, Sendable {
    case upper      // all letters uppercase
    case mixed      // both cases present
    case lower      // all letters lowercase
    case neutral    // no letters (punctuation/digits only)
}

/// Sub-range classification within a FountainLine — currently used to mark
/// inline `[[ ... ]]` notes that don't span a full line.
public struct FountainInlineSpan: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case note }
    public let range: NSRange
    public let kind: Kind

    public init(range: NSRange, kind: Kind) {
        self.range = range
        self.kind = kind
    }
}
