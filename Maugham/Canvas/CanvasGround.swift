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
    let camera: CanvasCamera
    /// 3–5% wash from the project's own sensory palette swatches (§7.1).
    let wash: [Color]

    /// Grain cell size in CONTENT points. Small enough to read as tooth, large
    /// enough that a zoomed-out canvas is not a moiré field.
    static let grainScale: CGFloat = 0.9

    /// The unlit ground, before grain and before the corner falloff.
    ///
    /// Light: a muted canvas weave. Dark: slate under a lamp — a different
    /// material, not the same texture inverted. Paper is a light-mode idea.
    ///
    /// **The card must stay lighter than the ground in BOTH appearances.**
    /// `CanvasRenderer.cardPaper` is `textBackgroundColor`, which measures 1.000
    /// in light and 0.118 in dark; a ground *above* the card in dark mode turns
    /// every scrap into a hole punched in the surface instead of an object
    /// resting on it, which fails §7.2 as surely as unreadable text does. The
    /// dark value here is 0.060, so the card sits 0.058 above it — the same
    /// direction as light mode's 0.930 against 1.000. Task 7 pinned the card
    /// against its own INK; `CanvasGroundTests.test_theCardIsLighterThanTheGroundInBothAppearances`
    /// pins it against the ground, and the two pins together are what keep a
    /// scrap legible AND present.
    ///
    /// The shader only ever darkens from here (falloff ×0.86…1.0, grain ±0.028),
    /// so pinning these two constants pins the rendered relationship.
    ///
    /// Authored in **sRGB**, not calibrated RGB. `NSColor(calibratedRed:)` with
    /// these same digits resolves ~30% lighter — 0.049/0.054/0.060 arrives as
    /// 0.055/0.063/0.073 — and that lift is invisible in the source. What is
    /// written here is what is rendered.
    static let base: NSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.049, green: 0.054, blue: 0.060, alpha: 1)
            : NSColor(srgbRed: 0.930, green: 0.915, blue: 0.880, alpha: 1)
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
                    .float(Self.grainScale)))
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
