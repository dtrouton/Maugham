import Foundation
import AppKit

/// Editor-side surface for markdown checkbox tokens.
///
/// The shared scanner that decides whether a line is a checkbox lives in
/// `Maugham/OpLog/InlineTaskScanners.swift` (it's also consumed by
/// `TaskDeriver`). This file adds the editor-only concerns: the
/// `MaughamCheckboxAttr` custom attribute that's painted onto the bracket
/// range for click hit-testing, and the pure `flipBracket` helper used by
/// the toggle handler to produce a new paragraph string.
public extension MarkdownCheckboxScanner {

    /// Returns a copy of `paragraph` with the 3-char `[ ]` or `[x]` glyph at
    /// `utf16Offset` flipped to the opposite state. If the offset doesn't
    /// land on a recognizable checkbox glyph the string is returned
    /// unchanged. The offset is the location of the opening `[`.
    static func flipBracket(in paragraph: String, atUTF16Offset utf16Offset: Int) -> String {
        let ns = paragraph as NSString
        guard utf16Offset >= 0, utf16Offset + 3 <= ns.length else {
            return paragraph
        }
        let glyph = ns.substring(with: NSRange(location: utf16Offset, length: 3))
        let replacement: String
        switch glyph {
        case "[ ]": replacement = "[x]"
        case "[x]": replacement = "[ ]"
        default:    return paragraph
        }
        return ns.replacingCharacters(
            in: NSRange(location: utf16Offset, length: 3),
            with: replacement)
    }
}

/// Custom attribute key stamped on the bracket range so
/// `EditorCoordinator.checkboxHitTest(atCharacterIndex:)` can detect a click
/// without re-scanning the line. The value carried is a
/// `MaughamCheckboxMarker`.
public let MaughamCheckboxAttr = NSAttributedString.Key("maugham.checkbox")

/// Discriminator for the two syntaxes that paint `MaughamCheckboxAttr`.
/// `.markdown` covers the 3-char `[ ]` / `[x]` glyph emitted by prose-mode
/// `- [ ]` list items. `.fountain` covers the 5-char `todo:` / `done:`
/// prefix inside a Fountain `[[ ... ]]` note. The toggle handler in
/// `EditorHost` reads this to dispatch to the correct flipper.
public enum MaughamCheckboxKind: String, Sendable {
    case markdown
    case fountain
}

/// Payload for `MaughamCheckboxAttr`. Identifies the bracket's location in
/// the doc and its current state. Wrapped in a class (NSObject) because
/// `NSAttributedString` attribute values must be reference-comparable for
/// NSLayoutManager's effective-range bookkeeping.
public final class MaughamCheckboxMarker: NSObject {
    /// UTF-16 offset within the doc-wide string the tokenizer ran against
    /// of the first character of the bracket glyph. For `.markdown` this is
    /// the opening `[`; for `.fountain` this is the `t` of `todo:` (or `d`
    /// of `done:`). The hit-test reads this back rather than the effective-
    /// range start so a click anywhere within the glyph still resolves to
    /// the bracket start.
    public let bracketLocation: Int
    public let checked: Bool
    public let kind: MaughamCheckboxKind

    public init(
        bracketLocation: Int,
        checked: Bool,
        kind: MaughamCheckboxKind = .markdown
    ) {
        self.bracketLocation = bracketLocation
        self.checked = checked
        self.kind = kind
        super.init()
    }
}
