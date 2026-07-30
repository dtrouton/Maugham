import XCTest
import SwiftUI
import AppKit
import MaughamCore
@testable import Maugham

/// **Whose hand made this**, drawn. Spec §8A.2 constraint 1: the writer must be
/// able to tell at a glance what they wrote from what was read off a photograph.
///
/// Every assertion is a two-render diff over scenes that differ in exactly one
/// model fact — `author` — with a control that must measure zero, which is the
/// 1C-b raster pattern `PromotionRenderTests` established: "some pixels changed"
/// proves nothing without one.
///
/// **Both appearances, every time.** Light and dark are two materials (§7.1) and
/// the two Claude pairs are calibrated separately; a fixture pinned to `.light`
/// is how a dark canvas that was flat black shipped with the suite entirely
/// green. `render` pins the scheme and resolves the page backing under the
/// matching appearance, so this process's own DarkAqua cannot leak into a light
/// render.
@MainActor
final class CanvasAuthorRenderTests: XCTestCase {

    private let a = CanvasNodeID("a")
    private let b = CanvasNodeID("b")
    private let size = CGSize(width: 800, height: 600)
    private let schemes: [(ColorScheme, String)] = [(.light, "light"), (.dark, "dark")]

    /// Two cards, far enough apart that the line between their centres has a
    /// long bare run neither card draws over.
    private func scene(cardFromClaude: Bool = false,
                       line: Bool = false,
                       lineFromClaude: Bool = false) -> CanvasScene {
        var s = CanvasScene()
        s.insert(CanvasNode(id: a, kind: .scrap, origin: CGPoint(x: 100, y: 100),
                            width: 240, cachedHeight: 80,
                            author: cardFromClaude ? .claude : nil))
        s.insert(CanvasNode(id: b, kind: .scrap, origin: CGPoint(x: 100, y: 400),
                            width: 240, cachedHeight: 80))
        if line {
            s.insertLine(CanvasLine(id: CanvasLineID("l1"), from: a, to: b,
                                    author: lineFromClaude ? .claude : nil))
        }
        return s
    }

    /// The card `a` occupies, inset past the border stroke and the shadow so the
    /// count is the paper and not an antialiased edge.
    private let cardBody = CGRect(x: 104, y: 104, width: 232, height: 72)
    /// The bare run of the line between the two cards.
    private let bareRun = CGRect(x: 210, y: 200, width: 20, height: 190)

    func test_theControlMeasuresZeroSoAChangedCountMeansSomething() throws {
        for (scheme, named) in schemes {
            let one = try render(scene: scene(line: true), size: size, scheme: scheme)
            let two = try render(scene: scene(line: true), size: size, scheme: scheme)
            XCTAssertEqual(one.differingPixels(from: two,
                                               in: CGRect(origin: .zero, size: size)), 0,
                           "under \(named) two renders of the same scene must be identical, "
                           + "or every count below is measuring noise")
        }
    }

    /// The paper is the whole of the difference, so nearly the whole card body
    /// changes — a handful of pixels would mean a mark had been added somewhere
    /// instead, which is the thing §6.3 argues against (a fourth mark beside the
    /// promoted stripe, the resize triangle and the connect dot, with no way for
    /// the writer to tell which meant what).
    func test_aClaudeCardDrawsDifferentlyFromTheWritersOwn() throws {
        for (scheme, named) in schemes {
            let writers = try render(scene: scene(), size: size, scheme: scheme)
            let claudes = try render(scene: scene(cardFromClaude: true), size: size,
                                     scheme: scheme)
            let changed = claudes.differingPixels(from: writers, in: cardBody)
            let area = Int(cardBody.width * cardBody.height)
            XCTAssertGreaterThan(
                changed, area / 2,
                "under \(named) only \(changed) of \(area) pixels of the card body differ "
                + "— a card Claude put down is told apart by its PAPER, so the body should "
                + "change almost everywhere. A small count means a mark was drawn instead.")

            // The other card is the writer's in both renders, so nothing about it
            // may move: the tint is a fact about one card, not a mode the canvas
            // enters.
            XCTAssertEqual(
                claudes.differingPixels(from: writers,
                                        in: CGRect(x: 104, y: 404, width: 232, height: 72)), 0,
                "under \(named) the writer's own card changed when a DIFFERENT card "
                + "gained an author")
        }
    }

    /// **The one to watch at smoke.** A line is a 1.5 pt hairline at
    /// `CanvasMaterial.lineOpacity`, and a cooler value may simply be too quiet
    /// to read at that weight. So this measures the strongest per-channel
    /// distance on the bare run as well as counting pixels: a count says the
    /// stroke changed, and only the distance says by how much.
    ///
    /// If the floor here ever has to come down, the answer is a recalibration of
    /// the Claude line pair in `CanvasMaterial` — **not a second mark**, and the
    /// line's provenance is carried by `CanvasAccessibility.connectionPhrase`
    /// regardless of what the hairline manages to say.
    func test_aClaudeLineDrawsDifferentlyFromTheWritersOwn() throws {
        for (scheme, named) in schemes {
            let writers = try render(scene: scene(line: true), size: size, scheme: scheme)
            let claudes = try render(scene: scene(line: true, lineFromClaude: true),
                                     size: size, scheme: scheme)
            let changed = claudes.differingPixels(from: writers, in: bareRun)
            XCTAssertGreaterThan(
                changed, 200,
                "under \(named) only \(changed) pixels of the bare run between the two "
                + "cards differ — a line Claude drew must stroke in a cooler value along "
                + "its whole length, not at one end of it")

            var strongest = 0.0
            for y in Int(bareRun.minY)..<Int(bareRun.maxY) {
                for x in Int(bareRun.minX)..<Int(bareRun.maxX) {
                    let p = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                    strongest = max(strongest, claudes.distance(to: writers, at: p))
                }
            }
            XCTAssertGreaterThan(
                strongest, 0.04,
                "under \(named) the strongest pixel on the run differs by only \(strongest) "
                + "(≈\(Int(strongest * 255)) of 255) — at 1.5 pt and "
                + "\(CanvasMaterial.lineOpacity) opacity that is a difference nobody can "
                + "see. Recalibrate the Claude line pair in CanvasMaterial; do not add a "
                + "second mark.")
        }
    }

    /// The ruling as an assertion, and the one a tidy-up would break.
    ///
    /// An item node is the page the words were read OFF, and **the two signals
    /// genuinely diverge on it** — which is why this can no longer be a
    /// two-render diff. Claude placed the node, so it is drawn STRAIGHT; the
    /// words on the page are the writer's, so it is drawn UNTINTED. A scene
    /// diff would see the tilt difference and call it a tint.
    ///
    /// So the instrument is a **census of the tint itself**: how many pixels on
    /// the page are exactly `claudeCardPaper`. Immune to geometry, and it says
    /// the thing the ruling says. The control on the same instrument is the
    /// Claude scrap beside it, whose body must be nearly all of that colour —
    /// without it, a census that resolved the wrong colour would return zero
    /// twice and pass.
    ///
    /// The promoted stripe is refused on the same node for the same
    /// already-exists-as-itself reason
    /// (`PromotionRenderTests.test_anItemNodeGetsNoMarkBecauseItCannotBePromoted`).
    func test_anItemNodeIsNeverTinted() throws {
        let itemBody = CGRect(x: 104, y: 104, width: 172, height: 112)
        let scrapBody = CGRect(x: 104, y: 404, width: 232, height: 72)

        func page(itemAuthor: AnnotationAuthor.SourceKind?,
                  scrapAuthor: AnnotationAuthor.SourceKind?,
                  scheme: ColorScheme) throws -> CanvasPage {
            var s = CanvasScene()
            s.insert(CanvasNode(id: .item("r-9"), kind: .item(referenceId: "r-9"),
                                origin: CGPoint(x: 100, y: 100), width: 180,
                                cachedHeight: 120, author: itemAuthor))
            s.insert(CanvasNode(id: a, kind: .scrap, origin: CGPoint(x: 100, y: 400),
                                width: 240, cachedHeight: 80, author: scrapAuthor))
            return try render(scene: s, size: size, scheme: scheme)
        }

        for (scheme, named) in schemes {
            let tinted = try page(itemAuthor: .claude, scrapAuthor: .claude, scheme: scheme)
            XCTAssertEqual(
                tinted.pixels(matching: CanvasRenderer.claudeCardPaper,
                              under: scheme, in: itemBody), 0,
                "under \(named) a reference was painted in Claude's paper — and "
                + "`author: .claude` is the ORDINARY state of one, not a hand-edited "
                + "sidecar: `CanvasClaudePlacement` writes it on every source page it "
                + "creates. The page already exists as itself and its words are the "
                + "writer's, so tinting it would say Claude took the photograph. The "
                + "tilt is what carries the placement, and `CanvasAccessibility` "
                + "speaks it.")
            XCTAssertGreaterThan(
                tinted.pixels(matching: CanvasRenderer.claudeCardPaper,
                              under: scheme, in: scrapBody),
                Int(scrapBody.width * scrapBody.height) / 2,
                "the control, on the same instrument: under \(named) the same author on a "
                + "SCRAP paints its whole body in Claude's paper. Without this a census "
                + "resolving the wrong colour would report zero for both and pass.")
        }

        // …and the other half of the divergence: Claude PLACED the page, so the
        // page is drawn square. This is the assertion that stops the exemption
        // above being "read" as `author` never reaching an item node at all.
        let placed = CanvasNode(id: .item("r-9"), kind: .item(referenceId: "r-9"),
                                origin: .zero, width: 180, cachedHeight: 120,
                                author: .claude)
        XCTAssertEqual(CanvasRenderer.seededRotation(for: placed).degrees, 0, accuracy: 0,
                       "the page Claude put on the canvas must be drawn straight — the "
                       + "tilt asks who placed this, and the tint asks whose words these "
                       + "are, and only the second answer is the writer's")
    }

    /// **This file's own light/dark discriminator.**
    ///
    /// Every assertion above passes under either appearance, because both papers
    /// differ from the writer's under both — so nothing here would have failed if
    /// the light pass had silently resolved dark. That is the exact shape of the
    /// bug `renderCanvasPage`'s own comment describes (a white-bitmap ink test
    /// that measured zero ink and passed everywhere except a dark-mode Mac), and
    /// the corpus closes it for the region wash with
    /// `test_theTwoAppearancesRenderDifferentWashes`. This is that assertion for
    /// this file.
    func test_theTwoAppearancesActuallyRenderDifferently() throws {
        let light = try render(scene: scene(cardFromClaude: true, line: true,
                                            lineFromClaude: true),
                               size: size, scheme: .light)
        let dark = try render(scene: scene(cardFromClaude: true, line: true,
                                           lineFromClaude: true),
                              size: size, scheme: .dark)
        XCTAssertGreaterThan(
            light.differingPixels(from: dark, in: cardBody),
            Int(cardBody.width * cardBody.height) / 2,
            "the same Claude card rendered identically in light and dark — the scheme is "
            + "not reaching the dynamic colours, and every appearance-specific assertion "
            + "in this file is measuring one material twice")
    }

    /// **Straight means Claude** (spec §8A.2 constraint 1), and a region is the
    /// primitive Claude creates on every call. The writer's region leans by its
    /// seed; Claude's is drawn exactly square.
    ///
    /// A whole-page diff, because a rotation moves ink along every edge rather
    /// than in one place — and the control below is what says the diff is the
    /// angle and not the fixture.
    func test_aClaudeRegionIsDrawnSquareAndTheWritersIsNot() throws {
        func page(author: AnnotationAuthor.SourceKind?, scheme: ColorScheme) throws -> CanvasPage {
            var s = CanvasScene()
            s.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                        frame: CGRect(x: 60, y: 60, width: 600, height: 400),
                                        author: author))
            return try render(scene: s, size: size, scheme: scheme)
        }
        let whole = CGRect(origin: .zero, size: size)
        for (scheme, named) in schemes {
            XCTAssertGreaterThan(
                try page(author: nil, scheme: scheme)
                    .differingPixels(from: try page(author: .claude, scheme: scheme),
                                     in: whole), 500,
                "under \(named) a region Claude swept and one the writer swept drew the "
                + "same — either regions are not leaning, or the author is not reaching "
                + "the angle")
            XCTAssertEqual(
                try page(author: .claude, scheme: scheme)
                    .differingPixels(from: try page(author: .claude, scheme: scheme),
                                     in: whole), 0,
                "the control: two renders of Claude's region must be identical")
        }
    }
}

/// A census of one exact colour, for the fixtures whose subject is a fill rather
/// than a difference between two renders.
///
/// It lives here rather than in the shared `CanvasPage` file because it is this
/// suite's vocabulary: the colour and the difference readers next door answer
/// "how much did this change", and after 1C-c3 gave an item node an author and a
/// straight draw, "did this thing change" stopped being able to isolate the tint
/// from the tilt.
extension CanvasPage {

    /// Pixels inside `rect` within one 8-bit level of `color`, resolved under the
    /// matching appearance.
    ///
    /// **`performAsCurrentDrawingAppearance`, not a bare resolve.** This process
    /// runs under DarkAqua, so a dynamic `NSColor` read plainly gives the dark
    /// value while the page was rendered light — the census would then count zero
    /// under light and the assertion would pass for the wrong reason, which is
    /// the failure `renderCanvasPage`'s own comment records.
    ///
    /// One level of slack absorbs the float→byte rounding on the way through
    /// `Color(nsColor:)`. The two papers are 5 levels apart in their nearest
    /// channel in light and 10 in dark, so the slack cannot make one read as the
    /// other.
    func pixels(matching paper: NSColor, under scheme: ColorScheme, in rect: CGRect) -> Int {
        var target: SIMD3<Double>?
        NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
            .performAsCurrentDrawingAppearance {
                guard let c = paper.usingColorSpace(.sRGB) else { return }
                target = SIMD3<Double>(Double(c.redComponent),
                                       Double(c.greenComponent),
                                       Double(c.blueComponent))
            }
        guard let target else { return 0 }
        let slack = 1.0 / 255 + 1e-9
        var count = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let d = color(at: CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) - target
                if abs(d.x) <= slack && abs(d.y) <= slack && abs(d.z) <= slack { count += 1 }
            }
        }
        return count
    }
}
