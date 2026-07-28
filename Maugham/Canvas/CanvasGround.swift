import SwiftUI
import MaughamCore

/// The canvas ground.
///
/// MUST be a sibling layer BENEATH the content, never an overlay across it: a
/// shader applied over a subtree containing an `NSViewRepresentable` logs a
/// warning and renders a placeholder (spec §7A.4, documented on
/// `colorEffect`/`layerEffect`/`distortionEffect`). The canvas has two of them —
/// the event view and the mounted scrap editor — so this view holds no content
/// of its own and `CanvasView` stacks it underneath.
///
/// No `.drawingGroup()`. It would add an offscreen render target on every pan
/// for a subtree that is already a single GPU-filled rectangle, and the
/// isolation it was once credited with actually comes from the ZStack.
struct CanvasGround: View {
    /// Which material this ground is made of. Light and dark differ by more than
    /// a fill colour — grain amplitude, the grain's own colour, and lamp depth
    /// are all per-appearance too
    /// (§7.1: "a different material, not the same texture inverted") — and the
    /// shader cannot ask, so the branch happens here and arrives as uniforms.
    ///
    /// Reading the ENVIRONMENT rather than `NSApp.effectiveAppearance` is what
    /// keeps this agreeing with `Color(nsColor:)` below, which resolves against
    /// the same signal. It is also what lets a test render either appearance with
    /// `.environment(\.colorScheme, _)` and get a coherent ground.
    @Environment(\.colorScheme) private var colorScheme

    let camera: CanvasCamera
    /// 3–5% wash from the project's own sensory palette swatches (§7.1).
    let wash: [Color]

    /// Grain cell size in CONTENT points. Small enough to read as tooth, large
    /// enough that a zoomed-out canvas is not a moiré field.
    static let grainScale: CGFloat = 0.9

    /// The unlit ground, before grain and before the lamp. **The numbers live in
    /// `CanvasMaterial`** — everything the writer calibrates is there, in one
    /// findable place, rather than split between a view and a shader.
    ///
    /// **The card must stay lighter than the ground in BOTH appearances.** A
    /// ground *above* the card turns every scrap into a hole punched in the
    /// surface instead of an object resting on it, which fails §7.2 as surely as
    /// unreadable text does. Task 7 pinned the card against its own INK;
    /// `CanvasGroundTests.test_theCardIsLighterThanTheGroundInBothAppearances`
    /// pins it against the ground — including at peak grain — and the two pins
    /// together are what keep a scrap legible AND present.
    ///
    /// The lamp only ever darkens from here (its ceiling is 1.0), so the base
    /// colours plus the grain amplitude bound the rendered relationship entirely.
    static let base: NSColor = CanvasMaterial.dynamic(light: CanvasMaterial.lightBase,
                                                      dark: CanvasMaterial.darkBase)

    private var isDark: Bool { colorScheme == .dark }

    private var grainAmplitude: Double {
        isDark ? CanvasMaterial.darkGrainAmplitude : CanvasMaterial.lightGrainAmplitude
    }

    /// The grain's own colour, as the per-channel multiplier the shader wants.
    /// `CanvasMaterial` owns both the colour and the normalisation — the branch
    /// here is only which appearance's pair to ask for.
    private var grainTint: SIMD3<Double> {
        CanvasMaterial.grainTint(
            color: isDark ? CanvasMaterial.darkGrainColor : CanvasMaterial.lightGrainColor,
            chroma: isDark ? CanvasMaterial.darkGrainChroma : CanvasMaterial.lightGrainChroma)
    }

    private var lampDepth: Double {
        isDark ? CanvasMaterial.darkLampDepth : CanvasMaterial.lightLampDepth
    }

    private var lampFloor: Double {
        isDark ? CanvasMaterial.darkLampFloor : CanvasMaterial.lightLampFloor
    }

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: Self.base))
            // The shader reads the filled base as `currentColor`, so the
            // appearance resolution stays in Swift and the grain is content-space.
            .colorEffect(
                ShaderLibrary.canvasGround(
                    .float2(camera.pan.x, camera.pan.y),
                    .float(camera.zoom),
                    .float(Self.grainScale),
                    .float(grainAmplitude),
                    .float3(Float(grainTint.x), Float(grainTint.y), Float(grainTint.z)),
                    .float(lampDepth),
                    .float(lampFloor),
                    .float(CanvasMaterial.lampReach)))
            .overlay {
                // The wash is felt, not seen — see CanvasGroundPalette.washOpacity.
                if !wash.isEmpty {
                    LinearGradient(colors: wash,
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .opacity(CanvasGroundPalette.washOpacity)
                        .blendMode(.softLight)
                }
            }
            .allowsHitTesting(false)
    }
}

enum CanvasGroundPalette {
    /// §7.1 names the dosage and names the risk: "Washed 3–5% by the project's
    /// own sensory palette swatches… at 15% a grim palette yields a canvas you
    /// cannot work on. The wash is felt, not seen."
    static let washOpacity: Double = 0.04

    /// A palette with thirty entries would stripe the ground rather than tint it.
    static let maximumSwatches = 5

    /// The seam is HEX, matching `PaletteCard.swatches`. Malformed entries are
    /// dropped rather than painted `.clear` — a silent transparent band in the
    /// gradient is a bug that looks like a design choice. Order is the palette's.
    static func validHexes(_ hexes: [String]) -> [String] {
        hexes.filter { PaletteCard.color(fromHex: $0) != nil }
            .prefix(maximumSwatches)
            .map { $0 }
    }

    static func wash(fromHex hexes: [String]) -> [Color] {
        validHexes(hexes).compactMap { hex in
            guard let c = PaletteCard.color(fromHex: hex) else { return nil }
            return Color(red: c.r, green: c.g, blue: c.b)
        }
    }
}
