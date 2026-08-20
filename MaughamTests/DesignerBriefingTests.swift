// MaughamTests/DesignerBriefingTests.swift
import XCTest
@testable import Maugham

/// `DesignerBriefing.compose` assembles what one designer run sends to the
/// spawned Claude — `TranslatorBriefing`'s sibling, same purity discipline: a
/// plain `Inputs` value in, one message out, no store, no clock, no I/O.
final class DesignerBriefingTests: XCTestCase {

    // MARK: - Role frame

    func test_roleFrame_namesTheDesigner() {
        let inputs = makeInputs(designerName: "Tschichold")
        let briefing = DesignerBriefing.compose(inputs: inputs)
        XCTAssertTrue(briefing.contains("Tschichold"))
    }

    func test_roleFrame_isTheFirstSection() {
        let inputs = makeInputs(designerName: "Tschichold")
        let briefing = DesignerBriefing.compose(inputs: inputs)
        XCTAssertTrue(briefing.hasPrefix("You are Tschichold"))
    }

    func test_roleFrame_includesTheEffectiveBriefWhenPresent() {
        let inputs = makeInputs(roleBrief: "Design the page, not the decoration.")
        let briefing = DesignerBriefing.compose(inputs: inputs)
        XCTAssertTrue(briefing.contains("Design the page, not the decoration."))
    }

    func test_roleFrame_noBriefSentenceWhenRoleBriefIsNil() {
        let inputs = makeInputs(roleBrief: nil)
        let briefing = DesignerBriefing.compose(inputs: inputs)
        // No stray blank section: composing with a nil brief must not leave
        // an empty line where the sentence would have been.
        XCTAssertFalse(briefing.contains("\n\n\n"))
    }

    // MARK: - Visual language

    func test_visualLanguage_appearsVerbatimWhenPresent() {
        let inputs = makeInputs(
            visualLanguageText: "A quiet serif, generous margins, no ornament.")
        let briefing = DesignerBriefing.compose(inputs: inputs)
        XCTAssertTrue(briefing.contains("A quiet serif, generous margins, no ornament."))
    }

    func test_visualLanguage_honestAbsenceWhenNil() {
        let inputs = makeInputs(visualLanguageText: nil)
        let briefing = DesignerBriefing.compose(inputs: inputs)
        XCTAssertTrue(briefing.contains("no visual language declared; ask before assuming"))
    }

    func test_visualLanguage_honestAbsenceWhenEmpty() {
        let inputs = makeInputs(visualLanguageText: "")
        let briefing = DesignerBriefing.compose(inputs: inputs)
        XCTAssertTrue(briefing.contains("no visual language declared; ask before assuming"))
    }

    func test_visualLanguage_anchorsAreStripped() {
        let inputs = makeInputs(
            visualLanguageText: "<!-- ¶y3z4 -->\n\nA quiet serif, generous margins.")
        let briefing = DesignerBriefing.compose(inputs: inputs)
        XCTAssertFalse(briefing.contains("<!--"))
        XCTAssertTrue(briefing.contains("A quiet serif, generous margins."))
    }

    // MARK: - Edition brief (rides when a language is in play)

    func test_editionBrief_omittedWhenNoLanguageInPlay() {
        let inputs = makeInputs(language: nil, editionBriefText: "Formal register.")
        let briefing = DesignerBriefing.compose(inputs: inputs)
        XCTAssertFalse(briefing.contains("Formal register."))
    }

    func test_editionBrief_namesTheLanguageWhenInPlay() {
        let inputs = makeInputs(language: "es", editionBriefText: nil)
        let briefing = DesignerBriefing.compose(inputs: inputs)
        XCTAssertTrue(briefing.contains("es"))
    }

    func test_editionBrief_carriesTheBriefTextWhenLanguageInPlay() {
        let inputs = makeInputs(language: "es", editionBriefText: "Formal register throughout.")
        let briefing = DesignerBriefing.compose(inputs: inputs)
        XCTAssertTrue(briefing.contains("Formal register throughout."))
    }

    // MARK: - Census + sample demonstration

    func test_census_listsEveryKindPresent() {
        let census = ElementCensus(
            kinds: [.paragraph, .blockquote, .wikiLink],
            firstPiece: [.paragraph: "p1", .blockquote: "p1", .wikiLink: "p2"])
        let inputs = makeInputs(census: census)
        let briefing = DesignerBriefing.compose(inputs: inputs)
        XCTAssertTrue(briefing.contains(ElementCensus.label(for: .paragraph)))
        XCTAssertTrue(briefing.contains(ElementCensus.label(for: .blockquote)))
        XCTAssertTrue(briefing.contains(ElementCensus.label(for: .wikiLink)))
    }

    func test_census_carriesTheDemonstratesLinesFromSelection() {
        let selection = SamplePageSelection.Selection(
            pieceIds: ["p1", "p2"], maxPages: SamplePageSelection.maxPages,
            demonstrates: [
                "chapter opener — \u{2018}The Fog\u{2019}",
                "verse — \u{2018}Interlude\u{2019}",
            ])
        let inputs = makeInputs(selection: selection)
        let briefing = DesignerBriefing.compose(inputs: inputs)
        XCTAssertTrue(briefing.contains("chapter opener — \u{2018}The Fog\u{2019}"))
        XCTAssertTrue(briefing.contains("verse — \u{2018}Interlude\u{2019}"))
    }

    // MARK: - Current templates

    func test_templates_carryPathAndContent() {
        let file = DesignerBriefing.Inputs.TemplateFile(
            path: "template.tex", content: "\\documentclass{book}")
        let inputs = makeInputs(templateFiles: [file])
        let briefing = DesignerBriefing.compose(inputs: inputs)
        XCTAssertTrue(briefing.contains("template.tex"))
        XCTAssertTrue(briefing.contains("\\documentclass{book}"))
    }

    func test_templates_shortContentIsNotElided() {
        let file = DesignerBriefing.Inputs.TemplateFile(path: "styles.css", content: "body {}")
        let inputs = makeInputs(templateFiles: [file])
        let briefing = DesignerBriefing.compose(inputs: inputs)
        XCTAssertFalse(briefing.contains("truncated"))
    }

    func test_templates_longContentIsCappedWithAnElisionNote() {
        let longContent = String(repeating: "x", count: DesignerBriefing.templateFileCharacterCap + 500)
        let file = DesignerBriefing.Inputs.TemplateFile(path: "template.tex", content: longContent)
        let inputs = makeInputs(templateFiles: [file])
        let briefing = DesignerBriefing.compose(inputs: inputs)

        XCTAssertTrue(briefing.contains("truncated"))
        // The full 500-character overrun never lands in the briefing verbatim.
        XCTAssertFalse(briefing.contains(longContent))
        // But the capped prefix does.
        let prefix = String(longContent.prefix(DesignerBriefing.templateFileCharacterCap))
        XCTAssertTrue(briefing.contains(prefix))
    }

    func test_templates_omittedSectionWhenEmpty() {
        let inputs = makeInputs(templateFiles: [])
        let briefing = DesignerBriefing.compose(inputs: inputs)
        XCTAssertFalse(briefing.contains("Current templates"))
    }

    // MARK: - Config summary

    func test_configSummary_statesTheFormatsEnabled() {
        var config = PublishConfig()
        config.outputs.formatsEnabled = [.pdf]
        let inputs = makeInputs(config: config)
        let briefing = DesignerBriefing.compose(inputs: inputs)
        XCTAssertTrue(briefing.contains("pdf"))
    }

    func test_configSummary_statesTheConfigJsonRefusal() {
        let inputs = makeInputs(config: PublishConfig())
        let briefing = DesignerBriefing.compose(inputs: inputs)
        XCTAssertTrue(briefing.contains("config.json"))
        XCTAssertTrue(briefing.contains("template/style/partial files only"))
    }

    func test_configSummary_neverEmbedsTheWholeConfigAsJSON() {
        var config = PublishConfig()
        config.metadata.title = "Distinctive Unlikely Title Marker"
        let inputs = makeInputs(config: config)
        let briefing = DesignerBriefing.compose(inputs: inputs)
        // The book's title is not a design-relevant field this briefing
        // states — proof the whole struct isn't being JSON-dumped in.
        XCTAssertFalse(briefing.contains("Distinctive Unlikely Title Marker"))
    }

    // MARK: - Direction in words

    func test_direction_appearsWhenGiven() {
        let inputs = makeInputs(direction: "Try something with more air on the chapter openers.")
        let briefing = DesignerBriefing.compose(inputs: inputs)
        XCTAssertTrue(briefing.contains("Try something with more air on the chapter openers."))
    }

    func test_direction_omittedWhenNilOrEmpty() {
        let nilBriefing = DesignerBriefing.compose(inputs: makeInputs(direction: nil))
        XCTAssertFalse(nilBriefing.contains("Direction"))

        let emptyBriefing = DesignerBriefing.compose(inputs: makeInputs(direction: ""))
        XCTAssertFalse(emptyBriefing.contains("Direction"))
    }

    func test_direction_anchorsAreStripped() {
        let inputs = makeInputs(direction: "<!-- ¶a1b2 -->\n\nMore air on the openers.")
        let briefing = DesignerBriefing.compose(inputs: inputs)
        XCTAssertFalse(briefing.contains("<!--"))
        XCTAssertTrue(briefing.contains("More air on the openers."))
    }

    // MARK: - Report contract

    func test_reportContract_referencedVerbatimAsTheLastSection() {
        let briefing = DesignerBriefing.compose(inputs: makeInputs())
        XCTAssertTrue(briefing.contains(DesignerReport.schemaDescription))
        XCTAssertTrue(briefing.hasSuffix(DesignerReport.schemaDescription))
    }

    // MARK: - Fixture

    private func makeInputs(
        designerName: String = "Tschichold",
        roleBrief: String? = nil,
        visualLanguageText: String? = nil,
        census: ElementCensus = ElementCensus(kinds: [], firstPiece: [:]),
        selection: SamplePageSelection.Selection = SamplePageSelection.Selection(
            pieceIds: [], maxPages: SamplePageSelection.maxPages, demonstrates: []),
        templateFiles: [DesignerBriefing.Inputs.TemplateFile] = [],
        config: PublishConfig = PublishConfig(),
        language: String? = nil,
        editionBriefText: String? = nil,
        direction: String? = nil
    ) -> DesignerBriefing.Inputs {
        DesignerBriefing.Inputs(
            designerName: designerName, roleBrief: roleBrief,
            visualLanguageText: visualLanguageText, census: census, selection: selection,
            templateFiles: templateFiles, config: config, language: language,
            editionBriefText: editionBriefText, direction: direction)
    }
}
