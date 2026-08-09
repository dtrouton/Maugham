import AppKit

/// Absorbs the parallel-worker `fontd` cold-start window before a styling
/// suite touches AppKit font APIs that cannot fail politely.
///
/// Mechanism, captured in an xcresult 2026-08-08
/// (`ScreenplayModeStylingTests.test_dialogue_isIndentedAt10_with35WidthBlock`,
/// 0.000s): `NSFont.monospacedSystemFont` and friends are annotated nonnull
/// but CAN return nil while the machine-global `fontd` daemon is being
/// hammered — seven fresh worker processes all resolve their first font at
/// gate start. Swift trusts the annotation, bridges the nil into an
/// attributes dictionary, and the test dies with
/// `attempt to insert nil object from objects[0]` before a single assertion.
/// Two sightings in ~16 gates on 2026-08-08 (its sibling:
/// `WindowedTypographyEquivalenceTests.test_screenplay_editInsideAction`,
/// same 0.000s shape, pre-dating any test change that day).
///
/// The warm-up polls through the OPTIONAL lookup (`NSFont(name:)`), which
/// fails soft, until the font machinery answers — after which the nonnull
/// APIs are safe. Call it from `override class func setUp()` in any suite
/// that styles text through production typography paths.
enum FontWarmup {
    private static var warmed = false

    static func ensure() {
        guard !warmed else { return }
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if NSFont(name: "Helvetica", size: 12) != nil { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        // One straight-through touch of the nonnull path while nothing
        // depends on it, so its lazy setup also happens here and not
        // mid-test. If fontd is genuinely down this line still crashes —
        // but at a named place with this comment above it.
        _ = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        warmed = true
    }
}
