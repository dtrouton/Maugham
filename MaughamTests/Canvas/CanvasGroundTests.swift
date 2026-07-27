import XCTest
import SwiftUI
import AppKit
import Metal
@testable import Maugham

final class CanvasGroundTests: XCTestCase {

    // MARK: - The wash

    /// §7.1: "Dosage is the risk — at 15% a grim palette yields a canvas you
    /// cannot work on. The wash is felt, not seen."
    func test_washOpacityStaysInTheFeltNotSeenBand() {
        XCTAssertGreaterThanOrEqual(CanvasGroundPalette.washOpacity, 0.03)
        XCTAssertLessThanOrEqual(CanvasGroundPalette.washOpacity, 0.05)
    }

    func test_washFromNoSwatches_isEmptyNotACrash() {
        XCTAssertTrue(CanvasGroundPalette.wash(fromHex: []).isEmpty)
        XCTAssertTrue(CanvasGroundPalette.validHexes([]).isEmpty)
    }

    func test_washIsCappedSoOnePaletteCannotStripeTheGround() {
        let many = (0..<40).map { _ in "#8A6F4D" }
        XCTAssertEqual(CanvasGroundPalette.validHexes(many).count,
                       CanvasGroundPalette.maximumSwatches)
        XCTAssertEqual(CanvasGroundPalette.wash(fromHex: many).count,
                       CanvasGroundPalette.maximumSwatches)
    }

    /// The test above compares the capped count against the very constant the
    /// implementation caps with, so it says "the cap is applied" and cannot say
    /// "the cap is small". A `maximumSwatches` of 40 would satisfy it exactly.
    /// Ten bands across a `LinearGradient` at 4% is a striped ground, which is
    /// the failure the cap exists to prevent — so the size gets its own pin, the
    /// same way `washOpacity` gets a band rather than a comment.
    func test_theCapIsSmallEnoughToTintRatherThanStripe() {
        XCTAssertGreaterThanOrEqual(CanvasGroundPalette.maximumSwatches, 2,
                                    "a one-colour cap makes the gradient a flat fill")
        XCTAssertLessThanOrEqual(CanvasGroundPalette.maximumSwatches, 8,
                                 "more bands than this and the wash reads as stripes "
                                 + "rather than as the project's colour")
    }

    /// Order is the palette's, not the dictionary's — the wash of a project
    /// must look the same on every launch.
    func test_washPreservesSwatchOrder() {
        let hexes = ["#8A6F4D", "#2F3B4C", "#C0392B"]
        XCTAssertEqual(CanvasGroundPalette.validHexes(hexes), hexes)
    }

    func test_malformedHexesAreDroppedRatherThanPaintedClear() {
        let hexes = ["#8A6F4D", "not-a-colour", "", "#GGGGGG", "#2F3B4C"]
        XCTAssertEqual(CanvasGroundPalette.validHexes(hexes), ["#8A6F4D", "#2F3B4C"])
    }

    func test_shortFormHexIsAccepted() {
        XCTAssertEqual(CanvasGroundPalette.validHexes(["#abc"]), ["#abc"])
    }

    // MARK: - The card sits ON the ground, not IN it

    /// Task 7, Minor 1. Nothing pinned the card against the GROUND, only against
    /// its own ink, and dark mode is where that bites: the ground is dark too,
    /// and a ground *lighter* than the card turns every scrap into a hole punched
    /// in the paper rather than an object resting on it. §7.2 wants honest
    /// objects; a hole fails it as surely as unreadable text does.
    ///
    /// The direction is the load-bearing claim, and it fails against the exact
    /// value Task 8 was handed: an sRGB-resolved (0.16, 0.17, 0.19) is 0.249
    /// brightness against a card of 0.118, i.e. the ground more than twice as
    /// light as the card it carries.
    ///
    /// **The second assertion is what the dark calibration added.** The lamp only
    /// ever *darkens* the ground (its ceiling is 1.0), so the base colours alone
    /// would bound the relationship — except the grain swings both ways. Its
    /// amplitude is now a per-appearance tunable, so "raise the texture until it
    /// reads" has a point past which a grain spike out-lights the paper on it and
    /// scraps flicker into holes, per pixel, only at high zoom. That is a real
    /// failure mode of this exact knob, so it gets its own pin rather than a note.
    func test_theCardIsLighterThanTheGroundInBothAppearances() throws {
        let cases: [(NSAppearance.Name, amplitude: Double)] = [
            (.aqua, amplitude: CanvasMaterial.lightGrainAmplitude),
            (.darkAqua, amplitude: CanvasMaterial.darkGrainAmplitude),
        ]
        for (name, amplitude) in cases {
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                guard let ground = CanvasGround.base.usingColorSpace(.sRGB),
                      let paper = CanvasRenderer.cardPaper.usingColorSpace(.sRGB) else {
                    return XCTFail("could not resolve the colours under \(name.rawValue)")
                }
                XCTAssertGreaterThan(
                    paper.brightnessComponent - ground.brightnessComponent, 0.04,
                    "under \(name.rawValue) the ground is \(ground.brightnessComponent) "
                    + "and the card paper is \(paper.brightnessComponent) — a card that "
                    + "is not lighter than the ground under it reads as a hole, not as "
                    + "an object (spec 7.2). CanvasGround.base must stay below "
                    + "CanvasRenderer.cardPaper in BOTH appearances.")

                // The shader adds +/- amplitude/2 before the lamp multiplies down.
                let peak = ground.brightnessComponent + amplitude / 2
                XCTAssertGreaterThan(
                    paper.brightnessComponent - peak, 0.02,
                    "under \(name.rawValue) the ground peaks at \(peak) once the grain "
                    + "(amplitude \(amplitude)) is added, against a card of "
                    + "\(paper.brightnessComponent). Raise CanvasMaterial's card paper or "
                    + "lower its base/grain amplitude: a grain spike that reaches the "
                    + "card's own brightness makes the scrap read as a hole wherever it "
                    + "lands.")
            }
        }
    }

    /// `CanvasMaterial`'s colours are authored in sRGB on purpose: what is
    /// written is what is rendered.
    ///
    /// `NSColor(calibratedRed:...)` is a *different* colour space, and the lift
    /// is large and completely invisible in the source — the values handed to
    /// Task 8 went in as 0.16/0.17/0.19 and come out of `usingColorSpace(.sRGB)`
    /// as 0.212/0.225/0.249. That ~30% lift is most of why the ground out-lit the
    /// card it carries.
    ///
    /// So this pins the RESOLVED components against the authored literals, which
    /// is a claim that can fail: swapping `srgbRed:` for `calibratedRed:` without
    /// touching a digit moves the dark ground from 0.115 to ~0.135 and this test
    /// says so. (The contrast pin above would not: 0.135 still clears its floor.)
    /// This matters more now than it did, not less — the writer is calibrating
    /// these numbers by eye, and a constant that renders 30% off the digit he
    /// typed makes the next round of calibration meaningless.
    func test_theGroundResolvesToTheValuesItIsAuthoredWith() {
        let authored: [(NSAppearance.Name, r: CGFloat, g: CGFloat, b: CGFloat)] = [
            (.aqua, r: 0.930, g: 0.915, b: 0.880),
            (.darkAqua, r: 0.094, g: 0.103, b: 0.115),
        ]
        for (name, wantR, wantG, wantB) in authored {
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                guard let c = CanvasGround.base.usingColorSpace(.sRGB) else {
                    return XCTFail("could not resolve the ground under \(name.rawValue)")
                }
                let message = "under \(name.rawValue) the ground resolves to "
                    + "\(c.redComponent)/\(c.greenComponent)/\(c.blueComponent) but is "
                    + "authored \(wantR)/\(wantG)/\(wantB) — the literals are being read "
                    + "in a colour space other than the one they are measured in"
                XCTAssertEqual(c.redComponent, wantR, accuracy: 0.002, message)
                XCTAssertEqual(c.greenComponent, wantG, accuracy: 0.002, message)
                XCTAssertEqual(c.blueComponent, wantB, accuracy: 0.002, message)
            }
        }
    }

    /// The same colour-space pin on the card, which now has a hand-authored dark
    /// value of its own and so can go wrong the same way the ground did.
    ///
    /// It also pins the SPLIT: light must still resolve to `textBackgroundColor`
    /// (the semantically right colour for a card, per Task 7 — the departure is
    /// dark-only and deliberate), and dark must NOT, because
    /// `textBackgroundColor`'s 0.118 is now below the ground.
    func test_theCardPaperIsTextBackgroundInLightAndItsOwnValueInDark() {
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            guard let paper = CanvasRenderer.cardPaper.usingColorSpace(.sRGB),
                  let system = NSColor.textBackgroundColor.usingColorSpace(.sRGB) else {
                return XCTFail("could not resolve the light card paper")
            }
            XCTAssertEqual(paper.brightnessComponent, system.brightnessComponent,
                           accuracy: 0.002,
                           "light mode was signed off on textBackgroundColor and the dark "
                           + "calibration must not have moved it")
        }
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            guard let paper = CanvasRenderer.cardPaper.usingColorSpace(.sRGB) else {
                return XCTFail("could not resolve the dark card paper")
            }
            let message = "the dark card resolves to \(paper.redComponent)/"
                + "\(paper.greenComponent)/\(paper.blueComponent) but is authored "
                + "0.235/0.232/0.226"
            XCTAssertEqual(paper.redComponent, 0.235, accuracy: 0.002, message)
            XCTAssertEqual(paper.greenComponent, 0.232, accuracy: 0.002, message)
            XCTAssertEqual(paper.blueComponent, 0.226, accuracy: 0.002, message)
        }
    }

    /// Light and dark are two materials, not one texture inverted (§7.1), and
    /// the writer's calibration is dark-only. A "tidy-up" that collapses the
    /// per-appearance pairs back to one shared number would put dark's amplitude
    /// and lamp on light, which was signed off and is not up for change.
    func test_theTwoAppearancesAreCalibratedSeparately() {
        XCTAssertNotEqual(CanvasMaterial.lightGrainAmplitude,
                          CanvasMaterial.darkGrainAmplitude,
                          "the dark ground is an eighth of the light one's brightness, so "
                          + "the same absolute grain swing cannot read the same on both")
        XCTAssertGreaterThan(CanvasMaterial.darkLampDepth, CanvasMaterial.lightLampDepth,
                             "a lamp on near-black needs a deeper falloff to be felt at all")
        XCTAssertLessThan(CanvasMaterial.darkLampFloor, CanvasMaterial.lightLampFloor,
                          "the floor is how far the light may drop; dark needs more room")

        // Light, untouched by the dark pass.
        XCTAssertEqual(CanvasMaterial.lightGrainAmplitude, 0.055, accuracy: 1e-9)
        XCTAssertEqual(CanvasMaterial.lightLampDepth, 0.10, accuracy: 1e-9)
        XCTAssertEqual(CanvasMaterial.lightLampFloor, 0.86, accuracy: 1e-9)
    }

    // MARK: - The shader

    /// C5: the shader must actually be compiled into the app. A `.metal` file
    /// that never reaches the target leaves `.colorEffect` a silent no-op and
    /// the ground renders flat — which looks like a design choice, not a bug.
    func test_groundShaderIsCompiledIntoTheDefaultMetalLibrary() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device on this machine")
        }
        let library = try device.makeDefaultLibrary(bundle: .main)
        XCTAssertTrue(library.functionNames.contains { $0.contains("canvasGround") },
                      "CanvasGround.metal did not compile into the app's default.metallib. "
                      + "Functions found: \(library.functionNames)")
    }

    /// C5 again, from the other side: writing the shader and never applying it
    /// is the failure this pins. Source-level because there is no runtime hook
    /// that reports "this view has a colorEffect".
    func test_canvasGroundActuallyAppliesTheShader() throws {
        let code = try Self.groundCode()
        XCTAssertTrue(code.contains(".colorEffect("),
                      "CanvasGround declares a shader it never applies")
        XCTAssertTrue(code.contains("ShaderLibrary.canvasGround"),
                      "the applied shader must be the one CanvasGround.metal defines")
        XCTAssertFalse(code.contains(".drawingGroup()"),
                       "drawingGroup adds an offscreen render target per pan and buys "
                       + "nothing here — the ground is one GPU-filled rectangle, and "
                       + "isolation comes from being a ZStack sibling")
    }

    /// The hand-smoke for this slice is one sentence: "Pan the canvas. The grain
    /// must not crawl." This is that sentence, rendered.
    ///
    /// Every assertion here fails under a specific, plausible wrong shader, and
    /// they are three different wrong shaders:
    ///
    /// 1. **Flat** — the `.colorEffect` never ran (unbuilt metallib, misspelled
    ///    function). Neighbouring pixels would then be identical everywhere and
    ///    the grain energy would be 0.00 against a measured 2.72.
    /// 2. **Screen-space** — the shader samples bare `position` and ignores the
    ///    pan uniform, which is the crawl itself. Panning would then change
    ///    nothing at all: the two renders would be byte-identical.
    /// 3. **Content-space, wrongly signed** — pan added where it should be
    ///    subtracted. The same CONTENT point would then land at a different
    ///    colour after a pan.
    ///
    /// Assertion 3 is the one that would quietly agree with a screen-space
    /// shader if it were written carelessly: sampling the same VIEW point in
    /// both images passes trivially under screen-space. It samples `p` in one
    /// and `p + panDelta` in the other, which is the whole point.
    ///
    /// Verified by mutation on 2026-07-26: replacing `(position - pan)` with
    /// bare `position` fails assertions 2 and 3 and leaves every other test in
    /// this file green, so this test is the only thing holding that claim.
    @MainActor
    func test_grainIsAnchoredToTheContentSoItDoesNotCrawlUnderAPan() throws {
        let size = CGSize(width: 160, height: 120)
        let delta = CGSize(width: 40, height: 24)
        let still = try Self.renderGround(pan: .zero, size: size)
        let panned = try Self.renderGround(pan: CGPoint(x: delta.width, y: delta.height),
                                           size: size)

        // 1. The ground carries grain at all.
        XCTAssertGreaterThan(Self.grainEnergy(still), Self.grainFloor,
                             "the ground rendered flat (grain energy "
                             + "\(Self.grainEnergy(still))). The colorEffect did not run, "
                             + "so nothing below this measures a shader at all")

        // 2. Panning moved the ground. A screen-space shader is invariant under
        //    pan, so these two renders would be identical byte for byte.
        //
        //    Counted rather than compared with XCTAssertNotEqual, which prints
        //    both operands: two 160x120 grounds is 150k bytes of failure message,
        //    and the useful number is just "how many".
        let changed = zip(still.bytes, panned.bytes).count { $0 != $1 }
        XCTAssertGreaterThan(changed, 0,
                             "panning the camera changed no pixel of \(still.bytes.count) "
                             + "— the shader is sampling screen space, so the grain is "
                             + "painted onto the window rather than onto the paper")

        // 3. The same CONTENT point kept its colour. Zoom is 1, so content point
        //    p appears at view p in `still` and at view p + delta in `panned`.
        var moved: [String] = []
        for p in Self.samplePoints {
            let before = still.rgb(x: p.x, y: p.y)
            let after = panned.rgb(x: p.x + Int(delta.width), y: p.y + Int(delta.height))
            // Bit-identical in practice — the same uniforms produce the same
            // arithmetic — and measured as 0 differing samples on 2026-07-26.
            // The tolerance is slack against GPU nondeterminism between two
            // renders, not against a sign error, which moves whole levels.
            if Self.differs(before, after, byMoreThan: 2) {
                moved.append("(\(p.x), \(p.y)): \(before) -> \(after)")
            }
        }
        XCTAssertTrue(moved.isEmpty,
                      "the grain crawled: these content points changed colour when the "
                      + "camera panned, which is what a writer sees as the paper "
                      + "sliding under its own texture: \(moved)")
    }

    /// The uniforms the shader is fed are the camera's, not a snapshot taken
    /// once. Assertion 3 above proves the *pan* uniform is live; zoom needs its
    /// own pin because the two are passed at the same call site and a zoom that
    /// never reaches the GPU looks exactly like a correct render until someone
    /// zooms out and meets a moire field.
    @MainActor
    func test_zoomReachesTheShaderAndFadesTheGrainOnZoomOut() throws {
        let size = CGSize(width: 160, height: 120)
        let near = try Self.renderGround(pan: .zero, zoom: 1, size: size)
        let far = try Self.renderGround(pan: .zero, zoom: 0.2, size: size)

        // Below the shader's fade floor the grain amplitude is zero, so the far
        // render is smooth where the near one is not.
        //
        // The measure is HIGH-FREQUENCY on purpose. A whole-image lightest-minus-
        // darkest spread would have conflated the grain with the corner falloff:
        // at zoom 0.2 the viewport covers five times as much content, so the
        // falloff alone sweeps a comparable number of levels and the two figures
        // come out nearly equal. Adjacent-pixel difference sees the grain and is
        // blind to a gradient that takes the whole image to move.
        // Measured 2026-07-26: 2.72 at zoom 1, 0.034 at zoom 0.2 — a factor of 80.
        XCTAssertLessThan(Self.grainEnergy(far), Self.grainFloor,
                          "grain energy was \(Self.grainEnergy(near)) at zoom 1 and "
                          + "\(Self.grainEnergy(far)) at zoom 0.2. Below the shader's "
                          + "0.25 fade floor the amplitude is zero, so a zoomed-out "
                          + "ground must read as flat by the same measure that calls a "
                          + "shaderless ground flat — and if it does not, the zoom "
                          + "uniform is not reaching the GPU")
        XCTAssertGreaterThan(Self.grainEnergy(near), Self.grainEnergy(far) * 4,
                             "the fade must be a fade, not a rounding difference")
    }

    // MARK: - The dark material, rendered

    /// "The canvas looks a little bland and black, the texture isn't coming in.
    /// I think this also leads to the cards not feeling differentiated enough."
    /// — the writer, looking at a real dark-mode canvas, 2026-07-26.
    ///
    /// **Nothing in this file could have said so**, and that is why it is here:
    /// every render fixture was pinned to `.light`, so the dark ground was never
    /// rasterised by any test. It could be, and was, unusable while the suite was
    /// entirely green — the shader ran, the grain was anchored, the zoom faded,
    /// and the result was still black.
    ///
    /// All three assertions are measurements in 8-bit levels, taken 2026-07-27 at
    /// 160×120 scale 1, with the numbers the material shipped *before* this pass
    /// alongside — because "bland" is a comparison, and a floor with nothing to
    /// compare against is a number someone will later lower to make a test pass.
    @MainActor
    func test_theDarkGroundIsAMaterialRatherThanABlackFill() throws {
        let size = CGSize(width: 160, height: 120)
        let near = try Self.renderGround(pan: .zero, zoom: 1, size: size, scheme: .dark)

        // 1. NOT BLACK. The ground has to sit high enough that grain and lamp
        //    have levels to move through at all. Measured 23.1; the old
        //    0.049/0.054/0.060 base measured ~14, and the whole dark scene —
        //    ground, grain, lamp, card — lived between 15 and 30 of 255.
        let mean = Self.meanGreen(near)
        XCTAssertGreaterThan(mean, 20.0,
                             "the dark ground renders at \(mean) of 255. Below about 20 "
                             + "there is no room for a material: the grain and the lamp "
                             + "are quantised into a handful of levels and the canvas "
                             + "reads as flat black. Raise CanvasMaterial.darkBase.")

        // 2. TEXTURED. Pinned in light since Task 8; dark was never measured, and
        //    dark is where it was reported missing. Measured 3.39 against light's
        //    2.72 — deliberately hotter, because grain is a relative signal and
        //    this ground is an eighth of light's brightness.
        let grain = Self.grainEnergy(near)
        XCTAssertGreaterThan(grain, Self.grainFloor,
                             "the dark ground scores \(grain) — at or below the flat "
                             + "floor of \(Self.grainFloor), i.e. indistinguishable from "
                             + "a ground with no shader at all")
        XCTAssertGreaterThan(grain, 2.0,
                             "the dark ground scores \(grain), which clears 'a shader "
                             + "ran' but not 'a writer can see tooth'. Raise "
                             + "CanvasMaterial.darkGrainAmplitude.")

        // 3. LIT FROM A CORNER. Sampled at zoom 0.1 so the viewport spans ~1600
        //    content points and the lamp's whole travel is inside one image;
        //    below the 0.25 fade floor the grain is off, so this measures the
        //    lamp alone. Measured 22.6 at the lit corner against 17.1 at the far
        //    one — a 5.5-level sweep. The old 0.10/0.86 lamp swept 1.3 levels,
        //    which is a rounding difference wearing a light source's name.
        let wide = try Self.renderGround(pan: .zero, zoom: 0.1, size: size, scheme: .dark)
        let lit = Self.meanGreen(wide, rows: 0..<8, columns: 0..<8)
        let unlit = Self.meanGreen(wide, rows: 112..<120, columns: 152..<160)
        XCTAssertGreaterThan(lit - unlit, 3.5,
                             "the lamp sweeps \(lit - unlit) levels across the whole of "
                             + "its falloff (\(lit) at the lit corner, \(unlit) at the "
                             + "far one). §7.1 asks for light falling from one corner; "
                             + "under about 3 levels a writer sees an even fill. Raise "
                             + "CanvasMaterial.darkLampDepth or lower darkLampFloor.")
    }

    // MARK: - The layering constraint

    /// Spec §7A.4, and the reason this view holds no content of its own: a
    /// shader applied OVER a subtree containing an `NSViewRepresentable` logs a
    /// warning and renders a placeholder. The canvas subtree has two of them
    /// (the event view, and Task 9's mounted editor), so Task 10 must stack the
    /// ground as a ZStack SIBLING underneath — never as a `.background` or
    /// `.overlay` wrapped around the content.
    ///
    /// A grep, because the failure is silent at runtime: the placeholder is
    /// grey, the warning goes to the console, and nothing throws.
    func test_theGroundHoldsNoContentOfItsOwn() throws {
        let code = try Self.groundCode()
        for forbidden in ["ViewBuilder", "NSViewRepresentable"] where code.contains(forbidden) {
            XCTFail("CanvasGround names \(forbidden), so it has started taking or hosting "
                    + "content. A colorEffect over a subtree containing an "
                    + "NSViewRepresentable renders a grey placeholder and only warns to "
                    + "the console (spec 7A.4). The ground is a leaf that Task 10 stacks "
                    + "BENEATH the canvas, never wrapped around it.")
        }
    }

    // MARK: - Fixtures

    private static let samplePoints: [(x: Int, y: Int)] = [
        (3, 3), (11, 7), (19, 31), (27, 13), (35, 47),
        (43, 19), (51, 53), (59, 29), (67, 61), (75, 37),
        (83, 67), (91, 41), (99, 71), (107, 23), (115, 59), (7, 83),
    ]

    /// `CanvasGround.swift` with its comments removed.
    ///
    /// The two greps above read THIS, not the raw file, for the reason
    /// `CanvasRendererTests` reads a stripped line: a doc comment must be free to
    /// NAME the hazard it is warning about. This is not hypothetical — the plan
    /// text handed to this task paired a `XCTAssertFalse(source.contains(
    /// ".drawingGroup()"))` with an implementation whose doc comment opens "No
    /// `.drawingGroup()`.", so the two could never both be right. Both greps
    /// failed on their first run for exactly that reason and nothing was wrong
    /// with the code.
    private static func groundCode() throws -> String {
        let raw = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()    // MaughamTests/Canvas
                .deletingLastPathComponent()    // MaughamTests
                .deletingLastPathComponent()    // repo root
                .appendingPathComponent("Maugham/Canvas/CanvasGround.swift"),
            encoding: .utf8)

        var code = ""
        var inBlockComment = false
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            var rest = Substring(line)
            while !rest.isEmpty {
                if inBlockComment {
                    guard let end = rest.range(of: "*/") else { rest = ""; break }
                    rest = rest[end.upperBound...]
                    inBlockComment = false
                } else if let open = rest.range(of: "/*"),
                          rest.range(of: "//").map({ open.lowerBound < $0.lowerBound }) ?? true {
                    code += rest[..<open.lowerBound]
                    rest = rest[open.upperBound...]
                    inBlockComment = true
                } else if let slashes = rest.range(of: "//") {
                    code += rest[..<slashes.lowerBound]
                    rest = ""
                } else {
                    code += rest
                    rest = ""
                }
            }
            code += "\n"
        }
        return code
    }

    /// If `groundCode` ever returned nothing — a moved file, a stripper that ate
    /// the whole source — both greps above would find no offender and pass for
    /// the wrong reason. The same guard `CanvasRendererTests` puts on its own
    /// directory walk.
    func test_theStrippedSourceIsStillTheSource() throws {
        let code = try Self.groundCode()
        XCTAssertTrue(code.contains("struct CanvasGround: View"),
                      "the source grep is not reading CanvasGround.swift any more, so "
                      + "every grep in this file is passing on an empty string")
        XCTAssertFalse(code.contains("Paper is a light-mode idea"),
                       "the comment stripper is not stripping, so a doc comment that "
                       + "names a hazard would be reported as code that uses it")
    }

    private static func differs(_ a: [UInt8], _ b: [UInt8], byMoreThan tolerance: Int) -> Bool {
        zip(a, b).contains { abs(Int($0) - Int($1)) > tolerance }
    }

    /// Below this a ground reads as flat.
    ///
    /// Measured on 2026-07-26 at 160x120, scale 1: a zoom-1 ground scores 2.72
    /// and a zoom-0.2 ground — below the shader's amplitude fade floor, so grain
    /// free — scores 0.034. A ground with no shader at all scores 0.00. The
    /// threshold sits two orders of magnitude clear of both sides, so it is a
    /// floor rather than a tuning.
    private static let grainFloor: Double = 1.0

    /// Mean absolute difference between horizontally adjacent pixels, in 8-bit
    /// levels of the green channel.
    ///
    /// This is a HIGH-FREQUENCY measure, which is the point: the shader's grain
    /// cell is ~1.1 content points across, so it moves between neighbours, while
    /// the corner falloff takes the whole image to travel a few levels and
    /// contributes essentially nothing here. That separation is what lets the
    /// zoom test attribute a drop to the amplitude fade rather than to the
    /// viewport covering more content.
    /// Mean green channel over a region, in 8-bit levels. A LOW-frequency
    /// measure, and the complement of `grainEnergy`: it sees the base colour and
    /// the lamp, and averages the grain away.
    private static func meanGreen(_ g: Ground,
                                  rows: Range<Int>? = nil,
                                  columns: Range<Int>? = nil) -> Double {
        let ys = rows ?? 0..<g.height
        let xs = columns ?? 0..<g.width
        var total = 0
        for y in ys { for x in xs { total += Int(g.rgb(x: x, y: y)[1]) } }
        let count = ys.count * xs.count
        return count == 0 ? 0 : Double(total) / Double(count)
    }

    private static func grainEnergy(_ g: Ground) -> Double {
        var total = 0, count = 0
        for y in stride(from: 0, to: g.height, by: 1) {
            for x in stride(from: 0, to: g.width - 1, by: 1) {
                total += abs(Int(g.rgb(x: x, y: y)[1]) - Int(g.rgb(x: x + 1, y: y)[1]))
                count += 1
            }
        }
        return count == 0 ? 0 : Double(total) / Double(count)
    }

    /// One rendered ground, addressed in POINTS from the top-left.
    private struct Ground {
        let bytes: [UInt8]
        let bytesPerRow: Int
        let width: Int
        let height: Int

        /// The R, G, B bytes at `(x, y)`. The context is `premultipliedFirst`
        /// with the default byte order, so the bytes run A, R, G, B — the same
        /// layout `CanvasRendererTests` measured on 2026-07-26.
        func rgb(x: Int, y: Int) -> [UInt8] {
            precondition((0..<width).contains(x) && (0..<height).contains(y),
                         "sample (\(x), \(y)) is off a \(width)x\(height) ground — an "
                         + "off-page read would compare padding, not paper")
            let o = y * bytesPerRow + x * 4
            return [bytes[o + 1], bytes[o + 2], bytes[o + 3]]
        }
    }

    /// Render `CanvasGround` at scale 1 and read its pixels.
    ///
    /// The colour scheme is pinned to `.light` for the same reason the renderer
    /// fixtures pin theirs: this test process runs under DarkAqua, and an
    /// unpinned dynamic colour would resolve dark inside a light render. The
    /// grain assertions are all relative, but the pin keeps them reproducible.
    @MainActor
    private static func renderGround(pan: CGPoint,
                                     zoom: CGFloat = 1,
                                     size: CGSize,
                                     scheme: ColorScheme = .light) throws -> Ground {
        var camera = CanvasCamera()
        camera.pan = pan
        camera.zoom = zoom
        let renderer = ImageRenderer(
            content: CanvasGround(camera: camera, wash: [])
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, scheme))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage, "ImageRenderer produced no image")

        let w = image.width, h = image.height
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let count = ctx.bytesPerRow * h
        let bytes = Array(UnsafeBufferPointer(start: ctx.data!.bindMemory(to: UInt8.self,
                                                                         capacity: count),
                                              count: count))
        return Ground(bytes: bytes, bytesPerRow: ctx.bytesPerRow, width: w, height: h)
    }
}
