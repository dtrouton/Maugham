import XCTest
import MaughamCore

/// CHARACTERIZATION for `MaughamCore.PaletteCard` (module M1).
///
/// Every assertion pins behaviour OBSERVED at HEAD `db1bea2c` via
/// `ObservationProbe`. Warrant LOW, intent UNKNOWN. Several of these pin
/// behaviour I believe is WRONG — pinning is not endorsement; the candidates are
/// called out in `experiment/02-characterization-notes.md` and carried to the
/// ruling sheet. Claim ids (M1-C-xxx) match `experiment/01-claims-ledger.json`.
final class PaletteCardCharacterization: XCTestCase {

    private let dir = "research/palette"

    private func parse(_ md: String, dir: String? = nil) -> PaletteCard {
        PaletteCardParser.parse(markdown: md, itemId: "id", fallbackTitle: "FB",
                                cardDirectory: dir ?? self.dir)
    }
    private func render(_ c: PaletteCard, dir: String? = nil) -> String {
        PaletteCardRenderer.render(c, cardDirectory: dir ?? self.dir)
    }
    private func roundTrip(_ c: PaletteCard) -> PaletteCard { parse(render(c)) }

    // MARK: - color(fromHex:) (M1-C-001 … M1-C-007)

    func test_C001_lengthsOtherThanThreeOrSixHexDigitsAreRejected() {
        for s in ["#", "#f", "#ff", "#ffff", "#fffff", "#ffffffff"] {
            XCTAssertNil(PaletteCard.color(fromHex: s), "\(s) should be rejected")
        }
    }

    func test_C002_surroundingOrInteriorWhitespaceIsNotTolerated() {
        XCTAssertNil(PaletteCard.color(fromHex: "#FFFFFF "))
        XCTAssertNil(PaletteCard.color(fromHex: "# fff"))
    }

    func test_C003_aLeadingPlusSignIsACCEPTEDAsPartOfTheHexBody() {
        // `UInt32(_:radix:)` accepts a leading "+", and the six-character length
        // check counts it as a digit. So "#+FFFFF" is six characters, parses as
        // 0x0FFFFF, and is treated as a VALID swatch everywhere downstream.
        let rgb = PaletteCard.color(fromHex: "#+FFFFF")
        XCTAssertNotNil(rgb)
        XCTAssertEqual(rgb?.r ?? -1, Double(0x0F) / 255, accuracy: 1e-12)
        XCTAssertEqual(rgb?.g ?? -1, 1.0, accuracy: 1e-12)
        XCTAssertEqual(rgb?.b ?? -1, 1.0, accuracy: 1e-12)
    }

    func test_C004_aLeadingMinusSignIsRejected() {
        XCTAssertNil(PaletteCard.color(fromHex: "#-FFFFF"))
    }

    func test_C005_nonASCIIDigitFormsAreRejected() {
        XCTAssertNil(PaletteCard.color(fromHex: "#\u{FF23}\u{FF23}\u{FF23}"))  // fullwidth CCC
        XCTAssertNil(PaletteCard.color(fromHex: "#\u{0661}\u{0662}\u{0663}"))  // arabic-indic 123
    }

    func test_C006_theEmptyStringIsRejected() {
        XCTAssertNil(PaletteCard.color(fromHex: ""))
    }

    func test_C007_theThreeDigitFormExpandsByDigitDoublingAndIsCaseInsensitive() {
        let upper = PaletteCard.color(fromHex: "#ABC")
        let lower = PaletteCard.color(fromHex: "#abc")
        let long  = PaletteCard.color(fromHex: "#AABBCC")
        XCTAssertEqual(upper?.r, long?.r); XCTAssertEqual(upper?.g, long?.g); XCTAssertEqual(upper?.b, long?.b)
        XCTAssertEqual(lower?.r, long?.r); XCTAssertEqual(lower?.g, long?.g); XCTAssertEqual(lower?.b, long?.b)
    }

    // MARK: - Degenerate input to parse (M1-C-008 … M1-C-013)

    func test_C008_anEmptyDocumentYieldsAFullyDefaultedCard() {
        let c = parse("")
        XCTAssertEqual(c.title, "FB"); XCTAssertEqual(c.kind, .other)
        XCTAssertEqual(c.body, ""); XCTAssertTrue(c.swatches.isEmpty)
        XCTAssertTrue(c.notes.isEmpty); XCTAssertTrue(c.imagePaths.isEmpty)
    }

    func test_C009_aWhitespaceOnlyDocumentBecomesBODY_notAnEmptyCard() {
        // Blank-but-not-empty lines are body bytes; only a truly EMPTY pre-`kind:`
        // line is treated as structural framing.
        XCTAssertEqual(parse("   \n\t\n").body, "   \n\t")
    }

    func test_C010_aHashLineWithNoTitleTextIsNOTATitleAndFallsIntoBody() {
        // The structure probe is the TRIMMED line, so "# " trims to "#", which
        // fails `hasPrefix("# ")`. Title falls back and the line is kept as body.
        let c = parse("# \n")
        XCTAssertEqual(c.title, "FB")
        XCTAssertEqual(c.body, "# ")
    }

    func test_C011_aSecondTitleHeadingIsKeptAsBODYRatherThanDiscarded() {
        let c = parse("# One\n\n# Two\n")
        XCTAssertEqual(c.title, "One")
        XCTAssertEqual(c.body, "# Two")
    }

    func test_C012_aHashWithNoFollowingSpaceIsNotATitle() {
        XCTAssertEqual(parse("#NoSpace\n").title, "FB")
        XCTAssertEqual(parse("#NoSpace\n").body, "#NoSpace")
    }

    func test_C013_anH3HeadingIsNeitherTitleNorSectionAndBecomesBody() {
        XCTAssertEqual(parse("### Deep\n\nkind: motif\n").body, "### Deep")
        XCTAssertEqual(parse("kind: motif\n\n### Deep\n\nmore\n\n## Swatches\n").body,
                       "### Deep\n\nmore")
    }

    // MARK: - Section-heading recognition (M1-C-014 … M1-C-019)

    func test_C014_sectionHeadingMatchingIsCaseInsensitive() {
        XCTAssertEqual(parse("kind: motif\n\n## SWATCHES\n\n- #fff\n").swatches, ["#fff"])
    }

    func test_C015_extraSpacesInsideASectionHeadingAreTolerated() {
        XCTAssertEqual(parse("kind: motif\n\n##   Swatches   \n\n- #fff\n").swatches, ["#fff"])
    }

    func test_C016_anINDENTEDSectionHeadingStillOpensThatSection() {
        // Structure detection runs on the trimmed probe, so leading whitespace does
        // not protect a heading-shaped line from being claimed as a section.
        let c = parse("kind: motif\n\nprose\n\n  ## Swatches\n\n  - #fff\n")
        XCTAssertEqual(c.swatches, ["#fff"])
        XCTAssertEqual(c.body, "prose")
    }

    func test_C017_aHeadingWithNoSpaceAfterTheHashesIsNotASection() {
        let c = parse("kind: motif\n##Swatches\n- #fff\n")
        XCTAssertTrue(c.swatches.isEmpty)
        XCTAssertEqual(c.body, "##Swatches\n- #fff")
    }

    func test_C018_aRepeATEDSectionHeadingAppendsToTheSameCollection() {
        XCTAssertEqual(parse("kind: motif\n\n## Swatches\n\n- #fff\n\n## Swatches\n\n- #000\n").swatches,
                       ["#fff", "#000"])
    }

    func test_C019_sectionsMayAppearInAnyOrder() {
        let c = parse("kind: motif\n\n## Images\n\n- a.png\n\n## Swatches\n\n- #fff\n")
        XCTAssertEqual(c.swatches, ["#fff"])
        XCTAssertEqual(c.imagePaths, ["research/palette/a.png"])
    }

    // MARK: - `kind:` capture (M1-C-020 … M1-C-023)

    func test_C020_theKindKeyToleratesAMissingSpaceAndAnyKeyCasing() {
        XCTAssertEqual(parse("kind:location\n").kind, .location)
        XCTAssertEqual(parse("KIND: location\n").kind, .location)
    }

    func test_C021_anEmptyKindValueCONSUMEStheOneShotCapture() {
        // `kind: ` (blank) resolves to .other AND marks kind as captured, so a
        // later well-formed `kind:` line is demoted to body prose.
        let c = parse("kind: \n\nkind: location\n")
        XCTAssertEqual(c.kind, .other)
        XCTAssertEqual(c.body, "kind: location")
    }

    func test_C022_aKindLineAfterASectionHeadingIsDiscardedEntirely() {
        // Not captured as kind (a section has been seen) and not kept as body
        // (body accumulation only runs while section == .none).
        let c = parse("## Swatches\n\nkind: location\n")
        XCTAssertEqual(c.kind, .other)
        XCTAssertEqual(c.body, "")
    }

    func test_C023_aBlankLineBetweenPreKindProseAndTheKindLineIsSILENTLYEATEN() {
        // Every EMPTY line before `kind:` is treated as the renderer's structural
        // framing, including one the writer typed between real prose and `kind:`.
        XCTAssertEqual(parse("# T\n\nprose\n\nkind: location\n").body, "prose")
        // …but a blank-LOOKING line with any whitespace in it survives, because the
        // framing test is `raw.isEmpty`, not `line.isEmpty`.
        XCTAssertEqual(parse("# T\n\n   \nkind: location\n").body, "   ")
    }

    // MARK: - CRLF (M1-C-024) — pinned, and a defect candidate

    func test_C024_aCRLFDocumentParsesAsONELine_losingEveryField() {
        // Swift treats "\r\n" as a SINGLE Character, so `split(separator: "\n")`
        // never fires on a CRLF document. The whole file becomes one line, the
        // title swallows it, and kind/swatches/senses/images are all lost.
        let md = "# T\r\n\r\nkind: location\r\n\r\n## Swatches\r\n\r\n- #fff\r\n"
        let c = parse(md)
        XCTAssertEqual(c.kind, .other, "kind is lost")
        XCTAssertTrue(c.swatches.isEmpty, "swatches are lost")
        XCTAssertTrue(c.title.contains("kind: location"), "the title swallowed the document")
        XCTAssertTrue(c.title.contains("## Swatches"))
    }

    // MARK: - Swatch and note item handling (M1-C-025 … M1-C-030)

    func test_C025_swatchesAreNeitherDeduplicatedNorCaseNormalisedByTheParser() {
        XCTAssertEqual(parse("kind: motif\n\n## Swatches\n\n- #fff\n- #fff\n- #FFF\n").swatches,
                       ["#fff", "#fff", "#FFF"])
    }

    func test_C026_theThreeDigitSwatchFormSurvivesParsingUnexpanded() {
        XCTAssertEqual(parse("kind: motif\n\n## Swatches\n\n- #abc\n").swatches, ["#abc"])
    }

    func test_C027_anUnrecognisedSensePrefixKeepsTheWHOLEItemTextIncludingTheColon() {
        let notes = parse("kind: motif\n\n## Senses\n\n- foo: bar\n").notes
        XCTAssertEqual(notes, [.init(sense: nil, text: "foo: bar")])
    }

    func test_C028_anItemBeginningWithAColonIsUntaggedAndKeepsTheColon() {
        XCTAssertEqual(parse("kind: motif\n\n## Senses\n\n- : x\n").notes,
                       [.init(sense: nil, text: ": x")])
    }

    func test_C029_whitespaceAroundTheSenseTokenIsTolerated() {
        XCTAssertEqual(parse("kind: motif\n\n## Senses\n\n-  smell : x\n").notes,
                       [.init(sense: .smell, text: "x")])
    }

    func test_C030_aBareDashItemIsDroppedFromEverySection() {
        XCTAssertTrue(parse("kind: motif\n\n## Senses\n\n-\n- \n").notes.isEmpty)
    }

    // MARK: - Image path resolution (M1-C-031 … M1-C-037)

    func test_C031_dashItemImagesAreNOTDeduplicatedAgainstEachOther() {
        XCTAssertEqual(parse("kind: motif\n\n## Images\n\n- a.png\n- a.png\n").imagePaths,
                       ["research/palette/a.png", "research/palette/a.png"])
    }

    func test_C032_anINLINEImageIsDeduplicatedAgainstAnAlreadyCollectedDashItem() {
        XCTAssertEqual(parse("kind: motif\n\n## Images\n\n- a.png\n\ntext ![x](a.png)\n").imagePaths,
                       ["research/palette/a.png"])
    }

    func test_C033_anAbsolutePathPassesThroughResolutionUnchanged() {
        XCTAssertEqual(parse("kind: motif\n\n## Images\n\n- /abs/x.png\n").imagePaths, ["/abs/x.png"])
    }

    func test_C034_aRemoteURLDashItemIsSkippedEntirely() {
        XCTAssertTrue(parse("kind: motif\n\n## Images\n\n- https://e.com/x.png\n").imagePaths.isEmpty)
    }

    func test_C035_climbingAboveTheProjectRootIsCLAMPEDRatherThanRejected() {
        XCTAssertEqual(parse("kind: motif\n\n## Images\n\n- ../../../../x.png\n").imagePaths, ["x.png"])
    }

    func test_C036_dotAndDotDotSegmentsAreCollapsedInPlace() {
        XCTAssertEqual(parse("kind: motif\n\n## Images\n\n- ./a/./b/../c.png\n").imagePaths,
                       ["research/palette/a/c.png"])
    }

    func test_C037_anEmptyCardDirectoryLeavesRelativePathsBare() {
        XCTAssertEqual(parse("kind: motif\n\n## Images\n\n- a.png\n", dir: "").imagePaths, ["a.png"])
    }

    // MARK: - Unknown sections (M1-C-038 … M1-C-039)

    func test_C038_anUnknownHeadingBEFOREAnyRealSectionIsKeptAsBodyIncludingItsProse() {
        XCTAssertEqual(parse("kind: motif\n\n## Weird\n\nprose here\n").body,
                       "## Weird\n\nprose here")
    }

    func test_C039_anUnknownHeadingAFTERRealStructureDiscardsItselfAndItsContent() {
        let c = parse("kind: motif\n\n## Swatches\n\n- #fff\n\n## Weird\n\n- dropped\n")
        XCTAssertEqual(c.swatches, ["#fff"])
        XCTAssertEqual(c.body, "")
        XCTAssertTrue(c.notes.isEmpty)
    }

    // MARK: - render shape (M1-C-040 … M1-C-042)

    func test_C040_theCanonicalRenderOfAnEmptyCardHasAFixedByteShape() {
        let bare = PaletteCard(researchItemId: "i", title: "T", kind: .other,
                               swatches: [], notes: [], imagePaths: [], body: "")
        XCTAssertEqual(render(bare),
                       "# T\n\nkind: other\n\n## Swatches\n\n\n## Senses\n\n\n## Images\n\n")
    }

    func test_C041_templateAndRenderDisagreeOnBlankLinesBetweenEmptySections() {
        // `template` emits one blank line between empty sections; `render` emits
        // two. Both re-parse identically, so nothing catches the divergence — but a
        // freshly created card's file changes bytes the first time it is saved.
        XCTAssertEqual(PaletteCardParser.template(title: "T", kind: .other),
                       "# T\n\nkind: other\n\n## Swatches\n\n## Senses\n\n## Images\n")
        XCTAssertNotEqual(PaletteCardParser.template(title: "T", kind: .other),
                          render(PaletteCard(researchItemId: "i", title: "T", kind: .other,
                                             swatches: [], notes: [], imagePaths: [], body: "")))
        XCTAssertEqual(parse(PaletteCardParser.template(title: "T", kind: .other)),
                       parse(render(PaletteCard(researchItemId: "i", title: "T", kind: .other,
                                                swatches: [], notes: [], imagePaths: [], body: ""))))
    }

    func test_C042_declarationOrderOfKindAndSenseIsPinned() {
        XCTAssertEqual(PaletteCard.Sense.allCases.map(\.rawValue),
                       ["sight", "sound", "smell", "touch", "taste"])
        XCTAssertEqual(PaletteCard.Kind.allCases.map(\.rawValue),
                       ["location", "character", "motif", "other"])
    }

    // MARK: - Round trips that DO NOT hold (M1-C-043 … M1-C-047)
    //
    // The public initialiser accepts models the parser could never produce. These
    // pin what happens to them. Each is a candidate for the ruling sheet.

    func test_C043_aSwatchThatIsNotValidHexIsSILENTLYLOSTOnRoundTrip() {
        let c = PaletteCard(researchItemId: "i", title: "T", kind: .other,
                            swatches: ["not-a-hex"], notes: [], imagePaths: [], body: "")
        XCTAssertTrue(render(c).contains("- NOT-A-HEX"), "it IS written to disk")
        XCTAssertEqual(roundTrip(c).swatches, [], "and it is gone on the way back in")
    }

    func test_C044_aNewlineInTheTitleMIGRATESTheRemainderIntoBody() {
        let c = PaletteCard(researchItemId: "i", title: "A\nB", kind: .other,
                            swatches: [], notes: [], imagePaths: [], body: "")
        let out = roundTrip(c)
        XCTAssertEqual(out.title, "A")
        XCTAssertEqual(out.body, "B")
    }

    func test_C045_aNewlineInANoteTRUNCATESItAtTheNewline() {
        let c = PaletteCard(researchItemId: "i", title: "T", kind: .other, swatches: [],
                            notes: [.init(sense: nil, text: "A\nB")], imagePaths: [], body: "")
        XCTAssertEqual(roundTrip(c).notes.map(\.text), ["A"], "the second line is dropped")
    }

    func test_C046_aRemoteURLInImagePathsIsMANGLEDByRelativizeThenReadBackWrong() {
        // relativize splits on "/", which collapses the "//" in a scheme. The card
        // file gains "- ../../https:/e.com/x.png" and the model comes back with a
        // single-slash URL that is now a relative path.
        let c = PaletteCard(researchItemId: "i", title: "T", kind: .other, swatches: [],
                            notes: [], imagePaths: ["https://e.com/x.png"], body: "")
        XCTAssertTrue(render(c).contains("- ../../https:/e.com/x.png"))
        XCTAssertEqual(roundTrip(c).imagePaths, ["https:/e.com/x.png"])
    }

    func test_C047_aBodySpellingAKnownSectionHeadingLosesItsBodyOnTheFIRSTPassThenConverges() {
        // The documented residual. Pinned so a change in either half is visible.
        let c = PaletteCard(researchItemId: "i", title: "T", kind: .other, swatches: [],
                            notes: [], imagePaths: [], body: "## Images\n\n- ./sneaky.png")
        let first = roundTrip(c)
        XCTAssertEqual(first.body, "", "the body is claimed by section detection")
        XCTAssertEqual(first.imagePaths, ["research/palette/sneaky.png"], "and harvested")
        XCTAssertEqual(roundTrip(first), first, "but the SECOND pass is stable")
    }

    // MARK: - Found by the Phase 15 extension (M1-C-053)

    func test_C053_anUntaggedNoteBeginningWithASenseNameReadsBackAsTAGGED() {
        // A LATENT DEFECT in shipped code, found by the Phase 15 extension
        // implementer while reasoning about a NEW section: it noticed that the
        // ambiguity it had to close for Textures (arbitrary tags) already exists
        // for Senses, narrowed to the five words in `Sense`.
        //
        // Nobody had claimed it. M1-T-006 covers an UNRECOGNISED prefix keeping
        // the whole text; nothing covered an untagged note whose text happens to
        // begin with a RECOGNISED one. Under RULING-1 this is a DEFECT: it is
        // reachable from inside Maugham and the writer's sentence is silently
        // reclassified — the words are not lost but misfiled.
        let card = PaletteCard(
            researchItemId: "i", title: "T", kind: .other, swatches: [],
            notes: [.init(sense: nil, text: "sound: cold underfoot")],
            imagePaths: [], body: "")
        let back = roundTrip(card)
        XCTAssertEqual(back.notes.first?.sense, .sound,
                       "the untagged note came back TAGGED")
        XCTAssertEqual(back.notes.first?.text, "cold underfoot",
                       "and its text was truncated at the colon")
        XCTAssertNotEqual(back, card,
                          "so parse(render(card)) != card for this editor-reachable model")
    }

    // MARK: - relativize edges (M1-C-048 … M1-C-052)

    func test_C048_aPathEQUALToTheDirectoryClimbsOutAndComesBackIn() {
        XCTAssertEqual(PaletteCardRenderer.relativize("research/palette", from: "research/palette"),
                       "../palette")
    }

    func test_C049_anEmptyPathProducesABareClimb() {
        XCTAssertEqual(PaletteCardRenderer.relativize("", from: "research/palette"), "../../")
    }

    func test_C050_anEmptyDirectoryYieldsADotSlashForm() {
        XCTAssertEqual(PaletteCardRenderer.relativize("a.png", from: ""), "./a.png")
    }

    func test_C051_oneClimbIsEmittedPerUNCOMMONDirectoryComponent() {
        XCTAssertEqual(PaletteCardRenderer.relativize("x.png", from: "a/b/c"), "../../../x.png")
        XCTAssertEqual(PaletteCardRenderer.relativize("x/y/z.png", from: "x"), "./y/z.png")
    }

    func test_C052_aSiblingDirectoryWithACOMMONPREFIXIsNotConfusedForTheDirectory() {
        XCTAssertEqual(PaletteCardRenderer.relativize("research/paletteX/a.png",
                                                      from: "research/palette"),
                       "../paletteX/a.png")
    }
}
