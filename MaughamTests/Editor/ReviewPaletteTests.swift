import XCTest
import AppKit
import MaughamCore
@testable import Maugham

/// Tests for the pure colour-assignment policy behind the crafted review render
/// (Component F). Deterministic, AppKit-light — no drawing, no text view.
final class ReviewPaletteTests: XCTestCase {

    private func human(_ id: String?, name: String = "Someone") -> AnnotationAuthor {
        AnnotationAuthor(sourceKind: .human, displayName: name, collaboratorId: id)
    }

    private func claude() -> AnnotationAuthor {
        AnnotationAuthor(sourceKind: .claude, displayName: "Claude", collaboratorId: nil)
    }

    // Same id → same colour across repeated calls (stable assignment).
    func test_sameId_sameColourAcrossCalls() {
        let palette = ReviewPalette()
        let a = palette.color(for: human("collab-123"))
        let b = palette.color(for: human("collab-123"))
        XCTAssertEqual(a, b)
    }

    // A human with nil id falls back to displayName for stability.
    func test_nilId_stableByDisplayName() {
        let palette = ReviewPalette()
        let a = palette.color(for: human(nil, name: "Edith"))
        let b = palette.color(for: human(nil, name: "Edith"))
        XCTAssertEqual(a, b)
    }

    // Claude → the fixed terracotta, and that terracotta is reserved: no human
    // assignment ever returns it.
    func test_claude_fixedTerracotta_neverGivenToHumans() {
        let palette = ReviewPalette()
        let terracotta = palette.color(for: claude())
        XCTAssertEqual(terracotta, ReviewPalette.claudeTerracotta)

        // Probe a large spread of human ids; none may collide with the reserved
        // Claude colour.
        for i in 0..<500 {
            let c = palette.color(for: human("human-\(i)"))
            XCTAssertNotEqual(c, terracotta, "human \(i) was assigned the reserved Claude colour")
        }
    }

    // Claude is stable too.
    func test_claude_stable() {
        let palette = ReviewPalette()
        XCTAssertEqual(palette.color(for: claude()), palette.color(for: claude()))
    }

    // Two different ids both draw from the capped human set (determinism, not
    // uniqueness — once the set is exhausted collisions are allowed).
    func test_differentIds_drawFromCappedSet_deterministic() {
        let palette = ReviewPalette()
        let set = Set(ReviewPalette.humanTones)
        XCTAssertFalse(set.isEmpty)
        XCTAssertLessThanOrEqual(ReviewPalette.humanTones.count, 6)

        let c1 = palette.color(for: human("id-A"))
        let c2 = palette.color(for: human("id-B"))
        XCTAssertTrue(set.contains(c1))
        XCTAssertTrue(set.contains(c2))

        // Determinism across instances: a fresh palette yields the same mapping.
        let palette2 = ReviewPalette()
        XCTAssertEqual(palette2.color(for: human("id-A")), c1)
        XCTAssertEqual(palette2.color(for: human("id-B")), c2)
    }

    // A nil author (defensive) still returns a colour from the human set
    // (treated as an anonymous human), never the reserved Claude tone.
    func test_nilAuthor_returnsHumanTone() {
        let palette = ReviewPalette()
        let c = palette.color(for: nil)
        XCTAssertTrue(Set(ReviewPalette.humanTones).contains(c))
        XCTAssertNotEqual(c, ReviewPalette.claudeTerracotta)
    }

    // MARK: - Contrast (shell p5a closing round B2, M2)

    /// WCAG relative luminance of a colour, resolved in `appearance`.
    private static func luminance(_ colour: NSColor, in appearance: NSAppearance.Name) -> Double {
        var resolved = NSColor.black
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            resolved = colour.usingColorSpace(.sRGB) ?? colour
        }
        func lin(_ c: CGFloat) -> Double {
            let c = Double(c)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(resolved.redComponent) + 0.7152 * lin(resolved.greenComponent)
            + 0.0722 * lin(resolved.blueComponent)
    }

    private static func contrast(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// **Every person's tone stands at least 3:1 against the editor's page
    /// in both appearances** — a dot is a 6 pt graphical object. The same
    /// palette colours the cards and To resolve's author dots, so all three
    /// agree. Control: the old blue pencil on the dark page fell short.
    func test_everyPersonsToneIsLegibleOnTheEditorsPageInBothAppearances() {
        let pages: [(NSAppearance.Name, NSColor, String)] = [
            (.aqua, ThemePalette.light.background, "light"),
            (.aqua, ThemePalette.sepia.background, "sepia"),
            (.darkAqua, ThemePalette.dark.background, "dark"),
        ]
        for (index, tone) in ReviewPalette.humanTones.enumerated() {
            for (appearance, page, name) in pages {
                let ratio = Self.contrast(Self.luminance(tone, in: appearance),
                                          Self.luminance(page, in: appearance))
                XCTAssertGreaterThanOrEqual(ratio, 3, "tone \(index) on the \(name) page: \(ratio)")
            }
        }
        let oldBlue = NSColor(srgbRed: 0.30, green: 0.40, blue: 0.62, alpha: 1)
        XCTAssertLessThan(Self.contrast(Self.luminance(oldBlue, in: .darkAqua),
                                        Self.luminance(ThemePalette.dark.background, in: .darkAqua)), 3,
                          "control: the measure catches the old blue pencil")
    }
}
