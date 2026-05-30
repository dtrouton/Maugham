import Foundation

/// The cross-surface **emphasis contract** for Fountain screenplay elements.
///
/// Two renderers style screenplays independently and *must stay independent*:
/// the Mac editor's AppKit `ScreenplayMode` (editable Courier-column text view,
/// char-width indents, layout-manager display-uppercase, theme palette) and the
/// iOS reader's SwiftUI `FountainStyler` (read-only `Text`, point indents,
/// string uppercase). Their **layout** legitimately differs by surface and is
/// deliberately *out* of this contract.
///
/// What *should* read the same on both is an element's **semantic emphasis** —
/// is it bold? is it italic? This type is the single, documented declaration of
/// that agreement, and it is the thing both surfaces' tests assert against
/// (`ScreenplayEmphasisContractTests` exists in *both* `MaughamTests` and
/// `MaughamPhoneTests`).
///
/// It is **not** consulted by either renderer at runtime — they keep their own
/// cohesive per-element styling. It exists purely as the contract + its tests,
/// so:
///   - change an element's bold/italic on ONE surface and the other surface's
///     contract test fails until they agree (or the contract is deliberately
///     updated, which then fails the *other* surface's test — forcing both);
///   - **add a new `ScreenplayElement` case and `contract(for:)` below stops
///     compiling until you classify it** — at which point its doc forces you to
///     realise the element must be styled on BOTH the Mac editor and the iOS
///     reader, not just the one you were working on.
///
/// Scope is intentionally `bold` + `italic` only. Uppercase and dimming are
/// expected to *feel* the same but are produced by surface-specific mechanisms
/// (the Mac uppercases via its layout manager and dims via palette alpha), so
/// they are not mechanically contracted here.
public struct ScreenplayEmphasis: Equatable, Sendable {
    public var bold: Bool
    public var italic: Bool

    public init(bold: Bool = false, italic: Bool = false) {
        self.bold = bold
        self.italic = italic
    }

    /// The agreed bold/italic emphasis for `element`, or `nil` when the emphasis
    /// is **intentionally surface-specific** (each renderer decides for itself,
    /// and no cross-surface assertion is made).
    ///
    /// The non-nil values track the Mac editor's long-standing behaviour (the
    /// canonical screenplay styling); the iOS reader conforms to them.
    public static func contract(for element: ScreenplayElement) -> ScreenplayEmphasis? {
        switch element {
        case .action:        return ScreenplayEmphasis()
        case .sceneHeading:  return ScreenplayEmphasis(bold: true)
        case .dialogue:      return ScreenplayEmphasis()
        case .parenthetical: return ScreenplayEmphasis(italic: true)
        case .transition:    return ScreenplayEmphasis(bold: true)
        case .centered:      return ScreenplayEmphasis(bold: true)
        case .lyric:         return ScreenplayEmphasis(italic: true)
        case .section:       return ScreenplayEmphasis(bold: true)
        case .synopsis:      return ScreenplayEmphasis(italic: true)
        case .note:          return ScreenplayEmphasis(italic: true)
        case .boneyard:      return ScreenplayEmphasis(italic: true)

        // Intentionally surface-specific — NOT cross-surface contracted:
        case .character:
            // Mac: indented cue + caps (industry convention, not bold).
            // iOS: bold + centred for legibility on a narrow screen.
            return nil
        case .pageBreak:
            // Mac: shown, dimmed. iOS: hidden (no pagination on a phone).
            return nil
        case .titlePage:
            // Mac: a dedicated title-page styling pass. iOS: a separate header
            // block rendered from `FountainScript.titlePage`.
            return nil
        }
    }
}
