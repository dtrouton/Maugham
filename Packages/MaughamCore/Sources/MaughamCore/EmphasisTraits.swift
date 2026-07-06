import Foundation

/// Combinable font-emphasis traits for inline text. Bold and italic are
/// orthogonal — model them as a bitfield so "both" falls out of the set
/// instead of being a special case (this mirrors Apple's
/// `InlinePresentationIntent`). Underline is NOT here: it is a separate
/// rendering axis (`underlineStyle`, not font) and is Fountain-only.
public struct EmphasisTraits: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let bold          = EmphasisTraits(rawValue: 1 << 0)
    public static let italic        = EmphasisTraits(rawValue: 1 << 1)
    /// GFM `~~struck~~`. A separate rendering axis (`strikethroughStyle`), but
    /// modeled here so one scan carries every inline mark a run accumulates.
    public static let strikethrough = EmphasisTraits(rawValue: 1 << 2)
}
