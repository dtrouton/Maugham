import Foundation

/// The cross-surface **display-uppercase contract** for Fountain screenplay
/// elements.
///
/// Some elements are force-uppercased **for display** regardless of how the
/// writer typed them (e.g. "ext. house - day" renders as "EXT. HOUSE - DAY").
/// This is the single, documented source for *which* elements get that
/// treatment.
///
/// **Current consumer:** the iOS reader (`FountainStyler`) applies `.uppercased()`
/// via this function. The Mac editor currently renders text **as-typed** — the
/// "option-A fallback" documented in CLAUDE.md — so it does NOT execute this
/// function at runtime. If the Mac ever implements display-uppercase, it MUST
/// consume this rather than inventing its own set, so both surfaces uppercase
/// the same elements.
///
/// **How to extend:** add a new `ScreenplayElement` case → the `switch` below
/// stops compiling until you classify it. Pick `true` or `false` deliberately
/// and update the doc comment.
///
/// Cross-surface contract; see docs/superpowers/notes/cross-surface-contracts.md.
public enum ScreenplayUppercase {
    /// Returns `true` when `element`'s text should be force-uppercased for
    /// display.
    ///
    /// Uppercased: `.sceneHeading`, `.transition`.
    /// Everything else: rendered as-typed.
    public static func shouldDisplayUppercase(_ element: ScreenplayElement) -> Bool {
        switch element {
        case .sceneHeading:  return true
        case .transition:    return true

        // Rendered as-typed on both surfaces:
        case .action:        return false
        case .character:     return false
        case .dialogue:      return false
        case .parenthetical: return false
        case .centered:      return false
        case .lyric:         return false
        case .section:       return false
        case .synopsis:      return false
        case .note:          return false
        case .pageBreak:     return false
        case .boneyard:      return false
        case .titlePage:     return false
        }
    }
}
