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
    /// An item node is the page the words were read OFF — it already exists as
    /// itself. Task 3 gives it no author and the renderer must not infer one, but
    /// a hand-edited sidecar can put one there, and tinting it would say Claude
    /// took the photograph. The promoted stripe is refused on the same node for
    /// the same reason (`test_anItemNodeGetsNoMarkBecauseItCannotBePromoted`).
    ///
    /// **The control is the scrap beside it**: the same author on a card IS
    /// drawn, so this is about the kind and not about a scene that renders the
    /// same either way.
    func test_anItemNodeIsNeverTinted() throws {
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
            let plain = try page(itemAuthor: nil, scrapAuthor: nil, scheme: scheme)
            XCTAssertEqual(
                try page(itemAuthor: .claude, scrapAuthor: nil, scheme: scheme)
                    .differingPixels(from: plain, in: CGRect(origin: .zero, size: size)), 0,
                "under \(named) a reference gained a tint from a hand-edited author — it "
                + "already exists as itself, and tinting it would say Claude took the "
                + "photograph")
            XCTAssertGreaterThan(
                try page(itemAuthor: nil, scrapAuthor: .claude, scheme: scheme)
                    .differingPixels(from: plain,
                                     in: CGRect(x: 104, y: 404, width: 232, height: 72)), 0,
                "the control: under \(named) the same author on a SCRAP is drawn, so the "
                + "exemption above is about the kind rather than about a scene that "
                + "renders identically either way")
        }
    }
}
