/// Display style for one title-page field, keyed by its (canonical-cased) key.
/// SINGLE SOURCE of the per-key title-page treatment across surfaces — the Mac
/// editor maps it to NSFont attributes, the iOS reader to SwiftUI font modifiers.
/// `scale` is a multiplier on each surface's base title-page font size.
/// Cross-surface contract (depth B); see docs/superpowers/notes/cross-surface-contracts.md.
public struct TitlePageFieldStyle: Equatable, Sendable {
    public enum Alignment: Equatable, Sendable { case leading, center }

    public let scale: Double
    public let bold: Bool
    public let italic: Bool
    /// True for the "other" keys the Mac renders in its dim syntax-punctuation
    /// color (Draft date, Contact, Notes, Copyright, unknown keys).
    public let dimmed: Bool
    public let alignment: Alignment

    public init(scale: Double, bold: Bool, italic: Bool, dimmed: Bool, alignment: Alignment) {
        self.scale = scale
        self.bold = bold
        self.italic = italic
        self.dimmed = dimmed
        self.alignment = alignment
    }

    /// The treatment for a title-page key. Matches the Mac's existing per-key
    /// logic in `ScreenplayMode.titlePageValueAttributes(key:)` exactly.
    ///
    /// Keys are matched against their canonical casing (the form the Fountain
    /// tokenizer produces: "Title", "Credit", "Author", "Source", …). Any key
    /// outside the special set — including the canonical "Draft date",
    /// "Contact", "Notes", "Copyright" and unrecognized keys — falls through to
    /// the dimmed, smaller, leading-aligned "other" treatment.
    public static func style(forKey key: String) -> TitlePageFieldStyle {
        switch key {
        case "Title":
            return TitlePageFieldStyle(
                scale: 1.5, bold: true, italic: false, dimmed: false, alignment: .center)
        case "Credit":
            return TitlePageFieldStyle(
                scale: 1.0, bold: false, italic: true, dimmed: false, alignment: .center)
        case "Author":
            return TitlePageFieldStyle(
                scale: 1.0, bold: false, italic: false, dimmed: false, alignment: .center)
        case "Source":
            return TitlePageFieldStyle(
                scale: 0.9, bold: false, italic: true, dimmed: false, alignment: .center)
        default:
            // Draft date, Contact, Notes, Copyright, unknown keys.
            return TitlePageFieldStyle(
                scale: 0.85, bold: false, italic: false, dimmed: true, alignment: .leading)
        }
    }
}
