import CoreGraphics
import MaughamCore

/// A pure, platform-agnostic display-style descriptor for one parsed Fountain
/// line. Deliberately uses plain enums + `CGFloat` (NOT SwiftUI Font/Alignment)
/// so the mapping is unit-testable without rendering; the E.2 SwiftUI renderer
/// translates each field into the corresponding view modifier.
struct FountainLineStyle: Equatable {
    enum Weight: Equatable { case regular, bold }
    enum Align: Equatable { case leading, center, trailing }
    /// Maps to `.body` / `.callout` / `.headline` system fonts in the renderer.
    enum Role: Equatable { case body, callout, headline }

    var weight: Weight = .regular
    var italic: Bool = false
    var monospaced: Bool = false
    var align: Align = .leading
    var role: Role = .body
    var leadingIndent: CGFloat = 0
    var trailingIndent: CGFloat = 0
    var topPadding: CGFloat = 0
    /// Renderer applies `content.uppercased()`.
    var uppercased: Bool = false
    /// Notes / synopsis / boneyard render dimmed.
    var dimmed: Bool = false
    /// Page breaks (and any other non-rendered element) are suppressed.
    var hidden: Bool = false
}

/// Maps a parsed `FountainLine` to its semantic display style (spec §3.8). This
/// is the single place screenplay element → visual style is decided on phone;
/// the renderer stays a thin translator.
enum FountainStyler {
    /// Extra indent (points) added to the leading edge of dual-dialogue second
    /// blocks, so a `^`-paired column reads distinctly from the primary one.
    private static let dualSecondExtraIndent: CGFloat = 24

    /// Map a parsed line to its semantic display style (spec §3.8 table).
    static func style(for line: FountainLine) -> FountainLineStyle {
        var s = FountainLineStyle()

        switch line.element {
        case .sceneHeading:
            // Bold, monospaced, uppercased, with breathing room above.
            s.weight = .bold
            s.monospaced = true
            s.uppercased = true
            s.topPadding = 12

        case .action:
            // Plain body, leading, no indent — the default descriptor already.
            break

        case .character:
            s.weight = .bold
            s.align = .center

        case .parenthetical:
            s.italic = true
            s.leadingIndent = 64

        case .dialogue:
            s.leadingIndent = 48
            s.trailingIndent = 48

        case .transition:
            s.weight = .bold
            s.align = .trailing
            s.uppercased = true

        case .centered:
            // Bold per the ScreenplayEmphasis contract (matches the Mac).
            s.weight = .bold
            s.align = .center

        case .lyric:
            // Dialogue-ish block, italicized.
            s.italic = true
            s.leadingIndent = 48

        case .section:
            // Bold headline; we keep it simple and don't vary by level.
            s.role = .headline
            s.weight = .bold

        case .synopsis:
            s.role = .callout
            s.italic = true
            s.dimmed = true

        case .note:
            // v1: show dimmed (a hide toggle may come later). Not hidden so the
            // writer can see inline notes exist while reading on the phone.
            // Italic per the ScreenplayEmphasis contract (matches the Mac).
            s.italic = true
            s.dimmed = true

        case .pageBreak:
            // No pagination on phone — suppress entirely.
            s.hidden = true

        case .boneyard:
            // Commented-out `/* ... */` text. CHOICE: render dimmed (not hidden)
            // so the reader can see the text still exists in the manuscript,
            // consistent with how `.note` is surfaced.
            // Italic per the ScreenplayEmphasis contract (matches the Mac).
            s.italic = true
            s.dimmed = true

        case .titlePage:
            // The renderer draws the title page block separately from
            // `FountainScript.titlePage`; a stray titlePage-classified line
            // falls back to a dim callout.
            s.role = .callout
            s.dimmed = true
        }

        // Dual-dialogue second column reads distinctly via a deeper indent on
        // top of whatever the element's base leading indent is.
        if line.isDualSecond {
            s.leadingIndent += dualSecondExtraIndent
        }

        return s
    }
}
