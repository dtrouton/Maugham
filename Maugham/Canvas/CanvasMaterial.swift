import AppKit
import SwiftUI

/// Every number the canvas's *look* is calibrated with, in one place.
///
/// This exists because the look is calibrated by eye, against a running app, by
/// the writer — not derived. A constant he will want to move must be findable
/// without reading a shader, so the shader takes uniforms and holds no material
/// literals of its own. `CanvasGround` feeds them to the GPU; `CanvasRenderer`
/// reads the card colour and the tilt.
///
/// **Light and dark are two materials, not one texture inverted** (spec §7.1:
/// "Light: a muted canvas weave. Dark: slate under a lamp… Paper is a light-mode
/// idea."). So every knob that differs is a *pair* of constants, and nothing
/// here is a shared number that both appearances have to live with. Light was
/// signed off on 2026-07-26 and is deliberately untouched by the dark
/// calibration; dark was raised out of a 0.06–0.12 band in which no material
/// could be seen at all.
enum CanvasMaterial {

    // MARK: - The ground

    /// The unlit ground, before grain and before the lamp falls across it.
    ///
    /// Authored in **sRGB**, not calibrated RGB. `NSColor(calibratedRed:)` with
    /// the same digits resolves ~30% lighter and the lift is invisible in the
    /// source. `CanvasGroundTests.test_theGroundResolvesToTheValuesItIsAuthoredWith`
    /// pins the resolved components against these literals, so what is written
    /// here is what is rendered.
    ///
    /// **Lighter ground:** raise these. The dark value carries the same
    /// blue-slate cast the 0.049/0.054/0.060 original had (ratios ≈ 0.82 / 0.90
    /// / 1.00), scaled up — a slate that is *visible as slate*. At the original
    /// 0.060 the entire dark scene lived between 0.060 and 0.118: the grain was
    /// ±0.028 of nothing, the lamp's whole travel was ~2 levels of 255, and the
    /// writer's reading was "bland and black, the texture isn't coming in".
    ///
    /// Raising the ground alone would have *shrunk* the card's separation, so
    /// `darkCardPaper` moves with it — see there.
    static let lightBase = NSColor(srgbRed: 0.930, green: 0.915, blue: 0.880, alpha: 1)
    static let darkBase = NSColor(srgbRed: 0.094, green: 0.103, blue: 0.115, alpha: 1)

    /// Peak-to-peak grain swing, as a fraction of full scale. The shader adds
    /// `±amplitude/2` before the lamp multiplies, so the ground's rendered range
    /// is `base ± amplitude/2`, never wider.
    ///
    /// **More texture:** raise these. Dark runs hotter than light on purpose:
    /// grain is a *relative* signal and the dark ground is an eighth of the light
    /// one's brightness, so the same absolute swing that reads as tooth on
    /// 0.930 reads as nothing on 0.115.
    ///
    /// The ceiling is not taste. `CanvasGroundTests` pins that the ground at
    /// peak grain stays below the card — a grain spike that out-lights the paper
    /// on it turns a scrap into a hole (§7.2), and that is the same failure the
    /// base-colour pin exists to prevent, just intermittent and per-pixel.
    static let lightGrainAmplitude: Double = 0.055
    static let darkGrainAmplitude: Double = 0.099

    /// **The colour the grain is made of** — which way a fleck leans, where
    /// `grainAmplitude` is how far it travels.
    ///
    /// The grain used to be a single monochrome offset added equally to R, G and
    /// B, so every fleck was *exactly the ground's hue*, lighter or darker. That
    /// is why raising the amplitude could only ever make a flat colour noisier:
    /// stone varies in hue as well as in value, and the shader had no way to say
    /// so. The writer's reading was "the grain colour is just too close to the
    /// background colour", and he was describing the model, not the dosage.
    ///
    /// The colour is **luminance-normalised** before it reaches the GPU (see
    /// `grainTint`), so it carries a *direction* and not a brightness: making it
    /// lighter or darker changes nothing, making it warmer or cooler changes
    /// everything. That is deliberate — amplitude owns "how much" and this owns
    /// "toward what", and the two stay independent knobs.
    ///
    /// Because the noise is signed, one colour gives variation in **both**
    /// directions: bright flecks lean toward this colour, dark flecks lean away
    /// from it, which on a cool slate ground means warm mineral highlights and
    /// cooler shadows from a single number. A second, opposed colour would let
    /// the two directions be chosen independently, and is the thing to reach for
    /// if that ever proves too coupled; until it does, one colour is one fewer
    /// knob whose interaction with the other has to be held in the head.
    ///
    /// **Dark** is a sandy ochre against the ground's blue-slate — feldspar in
    /// stone. **Light is deliberately neutral**: a grey normalises to (1, 1, 1)
    /// and reproduces the pre-colour monochrome grain exactly, which is what
    /// keeps the signed-off light material byte-for-byte unchanged.
    static let lightGrainColor = NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
    static let darkGrainColor = NSColor(srgbRed: 0.72, green: 0.62, blue: 0.48, alpha: 1)

    /// How much of `grainColor`'s lean actually lands: 0 is the old monochrome
    /// grain, 1 is the full hue of the grain colour.
    ///
    /// **This exists because hue and value are not equally safe at grain scale.**
    /// Per-pixel *hue* variation reads as colour fringing or JPEG-ish speckle
    /// long before per-pixel *value* variation reads as anything but texture, so
    /// the hue skew needs its own ceiling rather than being smuggled into the
    /// saturation of the colour — otherwise "warmer flecks" and "more colour
    /// noise" are the same gesture and neither can be tuned without the other.
    ///
    /// At dark's 0.6 the rendered ground carries about 1.0 levels of adjacent-
    /// pixel *chroma* energy against 4.5 levels of luminance energy — hue skews
    /// by roughly a quarter of what value does, which is the ratio §7.1's
    /// "material, not texture" wants: luminance still carries the grain and hue
    /// only tells you what it is made of. `CanvasGroundTests`
    /// `test_theGrainVariesInHueAndNotOnlyInValue` pins both the floor (there IS
    /// hue variation) and that ceiling (it stays under the luminance).
    ///
    /// **Light is 0**, so light's grain stays monochrome no matter what colour
    /// sits above — the second of two independent reasons light renders exactly
    /// as it did before this pass.
    static let lightGrainChroma: Double = 0.0
    static let darkGrainChroma: Double = 0.6

    /// The per-channel multiplier the shader scales the signed grain by.
    ///
    /// `1 + chroma * (color / luminance(color) - 1)`. Dividing by the colour's
    /// own Rec.709 luminance is what makes this a direction rather than a
    /// brightness: the result's luminance is exactly 1 for *any* colour and
    /// *any* chroma, so moving the grain colour cannot move the strength of the
    /// grain — that stays `grainAmplitude`'s job alone.
    ///
    /// Computed here rather than in the shader on purpose: `CanvasGround.metal`
    /// holds no material literals, and a number a test can read is a number the
    /// writer can be shown.
    ///
    /// A neutral grey, or a chroma of 0, returns exactly (1, 1, 1) — exactly,
    /// not nearly: `x / x` is 1 and `1 + 0 * y` is 1 in IEEE arithmetic, and the
    /// shader's multiply by 1 is likewise exact. That is what lets light mode be
    /// byte-for-byte identical to the monochrome grain rather than merely close.
    /// A black or unresolvable colour has no direction to point in, so it falls
    /// back to neutral rather than dividing by zero.
    static func grainTint(color: NSColor, chroma: Double) -> SIMD3<Double> {
        let neutral = SIMD3<Double>(1, 1, 1)
        guard let c = color.usingColorSpace(.sRGB) else { return neutral }
        let rgb = SIMD3<Double>(Double(c.redComponent),
                                Double(c.greenComponent),
                                Double(c.blueComponent))
        let luminance = 0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z
        guard luminance > 0.001 else { return neutral }
        return neutral + chroma * (rgb / luminance - neutral)
    }

    /// The lamp (§7.1: "Light falls from one corner. Light ages better than
    /// texture."). The ground is multiplied by a falloff that starts near 1 at
    /// the lit corner and bottoms out at `lampFloor`.
    ///
    /// **Stronger lamp:** raise `lampDepth` and/or lower `lampFloor` — depth
    /// sets how fast the light drops, the floor sets how far it can drop at all.
    /// **Longer throw** (the gradient spread over more canvas): lower `lampReach`.
    ///
    /// Dark's original 0.10 / 0.86 was mathematically a 14% darkening and
    /// perceptually nothing: 14% of a 0.060 ground is 2 levels of 255, so the
    /// "lamp" was invisible and the ground read as flat black. 0.26 / 0.66 sweeps
    /// the dark ground from ~0.100 at the lit corner to ~0.076 at the floor —
    /// about 6 levels, over roughly one viewport at zoom 1, which is a light
    /// source you can feel without a vignette you can point at.
    ///
    /// Light keeps 0.10 / 0.86: it was signed off, and on a 0.930 ground the same
    /// 14% is 33 levels — already a generous gradient.
    static let lightLampDepth: Double = 0.10
    static let darkLampDepth: Double = 0.26
    static let lightLampFloor: Double = 0.86
    static let darkLampFloor: Double = 0.66

    /// How much content the lamp's gradient is spread over — content points are
    /// multiplied by this before the distance is taken, so a *smaller* number is
    /// a *longer* throw. Shared: the light's geometry is the same in both
    /// appearances, only its depth differs.
    static let lampReach: Double = 0.0004

    // MARK: - The card

    /// The card's paper, per appearance.
    ///
    /// **Light is `textBackgroundColor` and dark is not, and that split is the
    /// decision.** Task 7 chose `textBackgroundColor` because it is semantically
    /// what a card is, and it remains right in light: 1.000 against a 0.930
    /// ground. In dark it resolves to 0.118, which was only 0.058 above the old
    /// 0.060 ground — and once the ground is raised to 0.115 to give the material
    /// somewhere to live, 0.118 is a card indistinguishable from the surface it
    /// sits on. The writer's "the cards not feeling differentiated enough" is
    /// that number.
    ///
    /// So dark takes a dedicated value: 0.235, a faintly *warm* grey against the
    /// ground's cool slate, which separates it by hue as well as by brightness.
    /// The unlit gap is 0.120, and the lamp only ever darkens the ground, so the
    /// rendered gap is never smaller than that anywhere on the canvas.
    ///
    /// **More card separation:** raise `darkCardPaper` or lower `darkBase`.
    /// Two things bound it from above. `CanvasRenderer.cardInk` is `labelColor`,
    /// which is *white* in dark — so paper that keeps climbing eventually
    /// swallows its own text, and
    /// `CanvasRendererTests.test_theCardsInkContrastsWithItsPaperInBothAppearances`
    /// is what says when. (At 0.235 the ink clears it by a wide margin: white on
    /// 0.235 sRGB is ~11:1.) And a card much lighter than this stops being an
    /// object under the same lamp as the ground and becomes a light-mode
    /// skeuomorph pasted into the dark, which §7.2 rejects.
    static let lightCardPaper: NSColor = .textBackgroundColor
    static let darkCardPaper = NSColor(srgbRed: 0.235, green: 0.232, blue: 0.226, alpha: 1)

    // MARK: - The tilt

    /// The half-width of the seeded per-card rotation: every card sits somewhere
    /// in `-maximumTiltDegrees ... +maximumTiltDegrees`, deterministically from
    /// its id (§7.2 — nothing is rough, but everything was *put down* rather than
    /// snapped to a grid).
    ///
    /// **More tilt:** raise this. It is the only definition; `seededRotation`
    /// scales into it and everything downstream — the drawn angle, the caret's
    /// inverse transform, the culling bleed's overhang budget — derives from
    /// there.
    ///
    /// 0.6° was the first calibration and read as almost square; 1.2° is the
    /// writer's doubling, to see the range. `CanvasRenderer.cullingBleed` carries
    /// the overhang this produces and
    /// `CanvasRendererTests.test_theCullingBleedCoversTheRotationOverhangAtTheCalibratedTilt`
    /// re-does that arithmetic against whatever this is set to, so raising it
    /// further fails loudly rather than clipping a card corner at the window edge.
    static let maximumTiltDegrees: Double = 1.0

    // MARK: -

    /// One appearance-dynamic colour from a light/dark pair.
    ///
    /// `bestMatch(from:)` rather than a name comparison: an appearance may be
    /// `.accessibilityHighContrastDarkAqua` and a `== .darkAqua` test would call
    /// that light.
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}
