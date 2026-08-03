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

    // MARK: - Regions

    /// The region wash, per appearance.
    ///
    /// §4 makes a region *where the cards are*, not a panel they sit on: at a
    /// dosage anyone would call "a filled box" the cards stop reading as the
    /// objects and the region becomes the object instead. **More legible
    /// regions:** raise the alpha. The ceiling is not taste —
    /// `CanvasRegionRenderTests.test_theRegionWashIsFeltRatherThanSeen` pins it
    /// against `regionWashCeiling` in both appearances.
    ///
    /// A pair, like everything else here. Dark runs a warmer, slightly stronger
    /// wash for the same reason the grain does: it is a *relative* signal, and
    /// the dark ground is an eighth of the light one's brightness, so the same
    /// alpha over a near-black ground moves fewer levels than it does over
    /// paper. Measured 2026-07-28 over each appearance's OWN ground: light moves
    /// a bare pixel 0.031 in its strongest channel, dark 0.059 — both between
    /// their floors and the shared ceiling.
    static let lightRegionWash = NSColor(srgbRed: 0.55, green: 0.52, blue: 0.44, alpha: 0.07)
    static let darkRegionWash = NSColor(srgbRed: 0.72, green: 0.62, blue: 0.48, alpha: 0.09)

    /// How far, in 0–1 channel distance, the wash may move a pixel off the bare
    /// ground. The felt-not-seen bound of §4, made falsifiable — and shared by
    /// both appearances on purpose, because "reads as a filled panel" is a
    /// perceptual threshold rather than a per-material calibration.
    static let regionWashCeiling: Double = 0.10

    /// …and how far it must move it AT LEAST. The other end of the same bound: a
    /// wash that clears the ceiling and moves nothing is a region the writer
    /// cannot see, and `XCTAssertNotEqual` alone will accept one 8-bit level of
    /// quantisation as "visible".
    ///
    /// **These are a pair and the dark one is the load-bearing half.** Dark's
    /// 0.045 sits above the 0.032 the LIGHT wash would move over the dark ground
    /// — so a tidy-up that gives dark the light constant is measured, in the
    /// rendered pixels, rather than only in a comparison of two literals. That
    /// is 1C-a's failure mode in miniature (a green suite over a dark surface
    /// drawn with light-mode values) and the thing this whole seam exists to
    /// stop. Light's 0.020 cannot do the same trick in reverse — the dark wash
    /// over the light ground moves 0.036, *more* than light's own 0.031, so a
    /// floor cannot separate them and a ceiling tight enough to would freeze a
    /// constant the writer tunes by eye. The light side is covered by
    /// `test_theTwoAppearancesRenderDifferentWashes` instead.
    ///
    /// **Raising either wash means raising its floor**, or the floor stops
    /// discriminating; the test messages say so.
    static let lightRegionWashFloor: Double = 0.020
    static let darkRegionWashFloor: Double = 0.045

    /// The region's outline. Quieter than a card's border: a region is an area,
    /// and an area whose edge out-shouts the cards inside it has become a box.
    static let lightRegionStroke = NSColor(srgbRed: 0.45, green: 0.42, blue: 0.35, alpha: 0.35)
    static let darkRegionStroke = NSColor(srgbRed: 0.78, green: 0.72, blue: 0.62, alpha: 0.30)

    /// Selection is the one place on this surface that may shout a little.
    /// Shared across appearances, because it is the system's accent and follows
    /// the writer's own choice rather than this material's calibration — and
    /// shared across PRIMITIVES, because `CanvasSelection` is one selection
    /// covering both regions and cards, so two accents would be two answers to
    /// "what is selected".
    static let regionSelectedStroke: NSColor = .controlAccentColor

    /// A tether explains a relationship the writer already knows about — that
    /// this card lives in that region — so it must not compete with the cards.
    ///
    /// Applied by REPLACING the stroke colour's own alpha, not by multiplying
    /// it: `lightRegionStroke` is already 0.35, and 0.35 × 0.30 is 0.105, which
    /// is a line nobody can see. **Fainter tethers:** lower this.
    static let tetherOpacity: CGFloat = 0.30

    /// A chip is a reference (§4.3). It reads as lighter than the thing it
    /// stands for — same paper, less of it — so that "which of these live here
    /// and which are visiting" is answerable at a glance without reading a word.
    static let chipOpacity: CGFloat = 0.75

    /// Softer than a card's 3. A region is an *area*, and a tight corner on an
    /// area reads as a panel — which is a look decision, not a layout one, so it
    /// lives here with the rest of the look. Shared: the corner is the same
    /// shape under both appearances; only its colour differs.
    static let regionCornerRadius: CGFloat = 6

    // MARK: - Lines

    /// A line's ink, per appearance — a pair, like everything else here (§7.1).
    ///
    /// Authored at full alpha so `lineOpacity` below is the whole story about how
    /// loud a line is: two alphas multiplying each other is how the tether ended
    /// up at 0.105 and invisible, and the comment on `tetherOpacity` is that
    /// lesson. **Fainter / bolder lines:** move `lineOpacity`, not these.
    ///
    /// Quieter than a card's ink and louder than a region's outline: a line is a
    /// real object the writer made, unlike a tether, which only explains a
    /// relationship they already know about.
    static let lightLineStroke = NSColor(srgbRed: 0.32, green: 0.30, blue: 0.26, alpha: 1)
    static let darkLineStroke = NSColor(srgbRed: 0.82, green: 0.78, blue: 0.70, alpha: 1)

    /// How present an unselected line is. Shared across appearances: this is a
    /// dosage on top of a pair that already differs, not a second calibration.
    static let lineOpacity: CGFloat = 0.6

    /// **A selected line draws heavier and FULLY OPAQUE rather than in an accent
    /// colour.** The canvas already spends its colour budget on the region ring
    /// and the palette wash (§7.1), and a line is thin enough that weight reads
    /// faster than hue — a hairline in the accent is a hairline you still have to
    /// hunt for.
    static let lineWidth: CGFloat = 1.5
    static let selectedLineWidth: CGFloat = 3

    /// The label pill. `lineLabelHeight` is the pill; the text sits at
    /// `lineLabelFontSize` inside `lineLabelPadding` on each side.
    ///
    /// Drawn on the card's own paper so a label crossing a busy patch of canvas
    /// is readable, at less than full opacity so the pill never reads as a card.
    static let lineLabelFontSize: CGFloat = 10
    static let lineLabelHeight: CGFloat = 16
    static let lineLabelPadding: CGFloat = 6
    static let lineLabelOpacity: CGFloat = 0.9

    /// The line under the pointer while one is being drawn.
    ///
    /// **Dashed, for the reason `sweepDash` is dashed:** nothing has been made
    /// yet, and a solid line would show the writer a connection that does not
    /// exist and then, if the drag was a twitch, take it away again. It borrows
    /// `sweepStroke`'s colour deliberately — a live gesture is a live gesture,
    /// and one knob for "the thing under my pointer right now" is one fewer place
    /// for two answers to drift apart.
    static let pendingLineWidth: CGFloat = 1.5
    static let pendingLineDash: [CGFloat] = [6, 4]

    /// The dot on the selected card's right edge that a line is dragged from.
    ///
    /// **The MARK; the TARGET is `CanvasRenderer.connectHandleRect`**, and the
    /// target is deliberately the larger of the two — the same way round as the
    /// resize corner, where a target slightly larger than its ink forgives a near
    /// miss and the reverse swallows drags aimed at the card.
    ///
    /// It takes the selection accent rather than a colour of its own, because it
    /// *is* selection chrome: it appears with the selection stroke and goes with
    /// it, and a second hue there would be a second answer to "what is selected".
    static let connectMarkDiameter: CGFloat = 8

    // MARK: - Claude's hand

    /// The paper of a card Claude put on the canvas, per appearance.
    ///
    /// Spec §8A.2 constraint 1: **the writer must be able to tell at a glance
    /// what they wrote from what was read off a photograph.** This pair and the
    /// line pair below are the whole of how that is said, and they are one
    /// gesture on purpose — a cooler, slightly darker paper, and a
    /// correspondingly cooler stroke, with the same ink, the same shape and the
    /// same hairline weight. "Claude's" is then one thing to learn rather than
    /// three. **Not a fourth mark**: `CanvasRenderer.drawCard`'s adjacency
    /// warning already covers three (the promoted stripe, the resize triangle,
    /// the connect dot), and a fourth of the same family is exactly what §6.3
    /// spends its length arguing against — the writer would have no way to tell
    /// which mark meant what.
    ///
    /// **The two appearances are not equally free, and that is arithmetic rather
    /// than taste.** The mark is *darker than the writer's paper*, and the ceiling
    /// on darkening is the ground at peak grain — below it a card reads as a hole
    /// cut out of the surface (§7.2), which
    /// `CanvasGroundTests.test_theCardIsLighterThanTheGroundInBothAppearances`
    /// pins for BOTH papers.
    ///
    /// - **Light is bounded in RED and only in red.** The writer's paper is
    ///   `textBackgroundColor`, i.e. white, over a 0.930 ground whose grain peaks
    ///   at 0.9575 in red — so red may fall at most 0.0225 below white, and the
    ///   shipped 0.980 spends all but 0.0025 of that. **Green and blue are not
    ///   bound by red's ceiling**, and the first draft of this pair wrongly
    ///   assumed they were: it dropped all three by similar amounts, which is a
    ///   *dim*, and a 1.5% dim on white is near-invisible. The cool cast is bought
    ///   by lowering red, so **blue is free to sit at 1.000** — holding it there
    ///   and taking green down to meet red turns the dim into a *tint*, and hue at
    ///   near-neutral is the discriminable axis. Measured against white: the
    ///   uniform draft was ΔE2000 **1.36**, this is **2.79**, and red's headroom
    ///   is byte-identical. That is the dark side's own insight (the hue flip
    ///   below), applied to light.
    /// - **Dark has room in every channel and uses it.** The writer's dark paper
    ///   is a deliberately *warm* 0.235 grey against the ground's cool slate, so
    ///   Claude's can be both meaningfully darker and cool — the hue flips as well
    ///   as the value, which is the stronger of the two signals at this size.
    ///
    /// Light still reaches only ~70% of dark's ΔE, and it cannot do better without
    /// moving red — i.e. without `lightGrainAmplitude` or `lightBase` coming down,
    /// which is a recalibration of a material signed off on 2026-07-26 and is
    /// Denver's call rather than a tidy-up. **The tilt is the other half of the
    /// answer** (`minimumTiltDegrees`): Claude's things are drawn exactly
    /// straight, which costs no colour budget at all.
    ///
    /// Authored in **sRGB**, like everything here: `NSColor(calibratedRed:)` with
    /// the same digits resolves ~30% lighter and the lift is invisible in the
    /// source.
    static let lightClaudeCardPaper = NSColor(srgbRed: 0.980, green: 0.980, blue: 1.000,
                                              alpha: 1)
    static let darkClaudeCardPaper = NSColor(srgbRed: 0.198, green: 0.204, blue: 0.216,
                                             alpha: 1)

    /// The ink of a line Claude drew, per appearance — the counterpart of the
    /// paper above, cooler by the same gesture against the writer's warm stroke.
    ///
    /// Authored at full alpha so `lineOpacity` stays the whole story about how
    /// loud a line is, exactly as `lightLineStroke`/`darkLineStroke` are: two
    /// alphas multiplying each other is how the tether reached 0.105 and
    /// invisible.
    ///
    /// **Held at roughly the writer's own lightness rather than darkened.** The
    /// card says "Claude's" with value *and* hue because it has a broad surface
    /// to say it on; a 1.5 pt hairline has no such surface, and darkening it as
    /// well would make Claude's lines quieter than the writer's rather than
    /// merely different. Rec.709 luminance: light 0.279 against the writer's
    /// 0.301, dark 0.755 against 0.783.
    ///
    /// **This pair is the one to watch.** At `lineWidth` 1.5 and `lineOpacity`
    /// 0.6 no pixel on a hairline is even fully covered, and a hue shift may
    /// simply be too quiet to read. Measured through `CanvasRenderer.draw`, the
    /// strongest pixel on a bare run moves ~0.05 in light and ~0.08 in dark —
    /// 14 and 21 levels of 255. **If that proves too quiet, the answer is these
    /// four numbers and not a second mark**, and a line's provenance is carried
    /// by `CanvasAccessibility.connectionPhrase` regardless of what the hairline
    /// manages to say.
    static let lightClaudeLineStroke = NSColor(srgbRed: 0.24, green: 0.28, blue: 0.38, alpha: 1)
    static let darkClaudeLineStroke = NSColor(srgbRed: 0.68, green: 0.75, blue: 0.88, alpha: 1)

    // MARK: - Promotion

    /// The stripe down the left edge of a card that has produced a durable
    /// artifact (spec §6).
    ///
    /// **A stripe rather than a corner dot**, because the other three positions
    /// are spoken for and the fourth is not free: the resize triangle owns the
    /// bottom-right, the connect dot owns the right edge vertically centred, and
    /// the text box starts `CanvasCardMetrics.inset` in from the top-left — so a
    /// corner mark would either land on the writer's first line or where an
    /// existing mark already means something. The left edge is outside the text
    /// inset at every card width, and it survives being zoomed out, which a few
    /// points of dot does not.
    static let promotedMarkWidth: CGFloat = 3

    /// Drawn in `cardInk`, which is already appearance-dynamic — so this is one
    /// constant rather than a light/dark pair. It is deliberately quieter than
    /// the selection stroke: a promoted card is a *fact* about the card, and a
    /// canvas where half the cards have been promoted must not read as a canvas
    /// where half the cards are selected.
    static let promotedMarkOpacity: CGFloat = 0.45

    // MARK: - The dim (§4)

    /// **The alpha a dimmed thing draws at — the alpha, not a factor on it.**
    ///
    /// One number for the whole surface, because a dim is one statement: *this
    /// is not what the tree named.* A card, a region's outline, a line, a tether
    /// and a chip all land on this value rather than each keeping a scaled
    /// version of its own dosage, so "how loud is the dim" is one knob the
    /// writer can move by eye. **Quieter dim:** lower it.
    ///
    /// **It is applied by `dimmedAlpha(lit:)` and never by multiplication**, and
    /// that is this file's oldest lesson rather than a preference — see
    /// `tetherOpacity`, where `0.35 × 0.30` shipped a line nobody could see. A
    /// dim meets four different starting alphas on this canvas (card paper at 1,
    /// the region wash at 0.07–0.09, a chip at 0.75, a tether at 0.30) and a
    /// multiplier makes the two quietest of them disappear entirely — which is
    /// the one thing a de-emphasis may not do, because a dimmed card is still
    /// clickable, still selectable, and still where the writer left it.
    ///
    /// It sits below every text dosage on this surface — `secondaryLabelColor`
    /// at ~0.5 and `tertiaryLabelColor` at ~0.26 — and above nothing except the
    /// region wash, which `dimmedAlpha(lit:)` therefore leaves alone.
    /// `CanvasHighlightRenderTests` pins both ends of that.
    static let dimmedOpacity: CGFloat = 0.22

    /// The alpha a dimmed thing draws at, given the alpha it draws at when lit.
    ///
    /// **`min`, and the `min` is load-bearing in one place.** A bare replacement
    /// would *raise* the region wash — it is authored at 0.07–0.09, well under
    /// the dim — so a dimmed region would carry a stronger wash than a lit one,
    /// which is the signal running backwards. A product would take it to 0.015
    /// and the region's area would vanish. `min` says the honest thing: a dim
    /// can make something quieter and can never make it louder, and a thing
    /// already quieter than the dim is left where it is.
    static func dimmedAlpha(lit: CGFloat) -> CGFloat { min(lit, dimmedOpacity) }

    // MARK: - The sweep

    /// The outline under the pointer while a region is being drawn.
    ///
    /// **The same hues as `lightRegionStroke`/`darkRegionStroke`, at roughly
    /// twice the alpha.** The hue says what is coming — this will be a region —
    /// and the alpha is the difference between a settled object and a live one:
    /// `regionStroke` is deliberately quiet because a region that out-shouts the
    /// cards inside it has become a box, but a sweep exists for about a second,
    /// under the writer's own cursor, and its whole job is to be seen. A sweep
    /// dosed at the settled region's alpha is the failure this shape exists to
    /// close, one notch quieter.
    ///
    /// **Fainter / bolder sweep:** move these alphas. They are a pair for the
    /// reason every knob here is a pair (§7.1: light and dark are two materials,
    /// not one texture inverted).
    static let lightSweepStroke = NSColor(srgbRed: 0.45, green: 0.42, blue: 0.35, alpha: 0.75)
    static let darkSweepStroke = NSColor(srgbRed: 0.78, green: 0.72, blue: 0.62, alpha: 0.70)

    /// Dashed, and that carries meaning rather than decoration: nothing has been
    /// made yet. A solid outline is what a region has once it exists, so a solid
    /// sweep would show the writer a region that is not there and then, if the
    /// sweep was a twitch, take it away again.
    ///
    /// In CONTENT points, like every other length the renderer draws with, so
    /// the dash scales with the camera exactly as the region outline it becomes
    /// does.
    static let sweepDash: [CGFloat] = [6, 4]

    /// Half a point over the settled region's 1, for the same reason the alpha
    /// is doubled: a live gesture reads as live.
    static let sweepLineWidth: CGFloat = 1.5

    // MARK: - The tilt

    /// The half-width of the seeded rotation: everything the writer put down
    /// leans somewhere in `±minimumTiltDegrees ... ±maximumTiltDegrees`,
    /// deterministically from its id (§7.2 — nothing is rough, but everything was
    /// *put down* rather than snapped to a grid).
    ///
    /// **More tilt:** raise this. It is the only definition; `seededRotation`
    /// scales into it and everything downstream — the drawn angle, the caret's
    /// inverse transform, the culling bleed's overhang budget — derives from
    /// there.
    ///
    /// 0.6° was the first calibration and read as almost square; 1.2° was the
    /// writer's doubling, asked for to see the range; **1.0° is where he settled
    /// it on 2026-07-27 (`dfde12e`) and it is his number, not a derived one.**
    /// 1C-c3 added a floor under it rather than moving it — see
    /// `minimumTiltDegrees`. `CanvasRenderer.cullingBleed` carries
    /// the overhang this produces and
    /// `CanvasRendererTests.test_theCullingBleedCoversTheRotationOverhangAtTheCalibratedTilt`
    /// re-does that arithmetic against whatever this is set to, so raising it
    /// further fails loudly rather than clipping a card corner at the window edge.
    static let maximumTiltDegrees: Double = 1.0

    /// The DEAD BAND around zero, and the reason it exists is provenance rather
    /// than looks (spec §8A.2 constraint 1).
    ///
    /// **Straight means Claude.** The surface already says "a hand put this here"
    /// with the seeded lean, so the cheapest possible way to say "a machine put
    /// this here" is to withhold it — Claude's cards and Claude's regions are
    /// drawn at exactly 0°, and it costs no colour budget at all, which matters
    /// because light mode has almost none (see `lightClaudeCardPaper`).
    ///
    /// That reading is only reliable if **true zero is reserved.** Before this,
    /// `seededRotation` mapped a uniform sample straight onto
    /// `±maximumTiltDegrees`, so a card whose seed landed near the middle drew
    /// essentially straight and a writer's own card could pass for Claude's. A
    /// signal that is usually right is worse than no signal: the failure it
    /// invites is the writer trusting that a card is theirs when it is not. So
    /// every human thing leans by at least this much, and the drawn angles are
    /// two disjoint bands with a gap between them.
    ///
    /// **More separation:** raise this. It is bounded above by
    /// `maximumTiltDegrees` — the band is `min…max` and a minimum that met the
    /// maximum would give every card the same lean, which is the grid §7.2
    /// rejects. `CanvasRendererTests.test_theTiltBandLeavesTrueZeroToClaude`
    /// pins both ends.
    static let minimumTiltDegrees: Double = 0.4

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
