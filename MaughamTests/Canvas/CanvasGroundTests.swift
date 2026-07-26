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

    /// Task 7, Minor 1. `CanvasRenderer.cardPaper` is `textBackgroundColor` —
    /// 1.00 brightness in light, 0.12 in dark. Nothing pinned the card against
    /// the GROUND, only against its own ink, and dark mode is where that bites:
    /// the ground is dark too, and a ground *lighter* than the card turns every
    /// scrap into a hole punched in the paper rather than an object resting on
    /// it. §7.2 wants honest objects; a hole fails it as surely as unreadable
    /// text does.
    ///
    /// The direction is the load-bearing claim, and it fails against the exact
    /// value this task was handed: an sRGB-resolved (0.16, 0.17, 0.19) is 0.249
    /// brightness against a card of 0.118, i.e. the ground is more than twice as
    /// light as the card it carries.
    ///
    /// The shader only ever *darkens* the ground from here — its corner falloff
    /// multiplies by 0.86...1.0 and the grain swings +/-0.028 — so pinning the
    /// base colours pins the rendered relationship too.
    func test_theCardIsLighterThanTheGroundInBothAppearances() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
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
            }
        }
    }

    /// `CanvasGround.base` is authored in sRGB on purpose: what is written is
    /// what is rendered.
    ///
    /// `NSColor(calibratedRed:...)` is a *different* colour space, and the lift
    /// is large and completely invisible in the source — the values handed to
    /// this task went in as 0.16/0.17/0.19 and come out of
    /// `usingColorSpace(.sRGB)` as 0.212/0.225/0.249. That ~30% lift is most of
    /// why the ground out-lit the card it carries.
    ///
    /// So this pins the RESOLVED components against the authored literals, which
    /// is a claim that can fail: swapping `srgbRed:` for `calibratedRed:` without
    /// touching a digit moves the dark ground from 0.060 to 0.073 and this test
    /// says so. (The contrast pin above would not: 0.073 still clears its floor.)
    func test_theGroundResolvesToTheValuesItIsAuthoredWith() {
        let authored: [(NSAppearance.Name, r: CGFloat, g: CGFloat, b: CGFloat)] = [
            (.aqua, r: 0.930, g: 0.915, b: 0.880),
            (.darkAqua, r: 0.049, g: 0.054, b: 0.060),
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
                                     size: CGSize) throws -> Ground {
        var camera = CanvasCamera()
        camera.pan = pan
        camera.zoom = zoom
        let renderer = ImageRenderer(
            content: CanvasGround(camera: camera, wash: [])
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .light))
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
