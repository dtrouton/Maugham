import XCTest
@testable import Maugham

final class PublishConfigValidatorTests: XCTestCase {

    func testAccepts_validConfig() {
        let cfg = PublishConfig(metadata: .init(title: "X", author: "Y"))
        let errs = PublishConfigValidator.validate(cfg)
        XCTAssertTrue(errs.isEmpty)
    }

    func testRejects_emptyTitle() {
        var cfg = PublishConfig()
        cfg.metadata.title = ""
        let errs = PublishConfigValidator.validate(cfg)
        XCTAssertTrue(errs.contains(where: { $0.field == "metadata.title" }))
    }

    // ADR 0015: an unknown `start_on` written by a newer Maugham must NOT throw
    // (which would make the whole config.json unloadable). It degrades to
    // `.any` (the no-constraint default) so the rest of the config survives.
    func testUnknownStartOn_degradesToAny() throws {
        let json = """
        {"title_override":null,"start_on":"sideways","include_in_toc":true}
        """
        let section = try JSONDecoder().decode(
            PublishConfig.Section.self, from: Data(json.utf8))
        XCTAssertEqual(section.startOn, .any)
    }

    func testRejects_negativeYear() {
        var cfg = PublishConfig()
        cfg.metadata.year = -100
        let errs = PublishConfigValidator.validate(cfg)
        XCTAssertTrue(errs.contains(where: { $0.field == "metadata.year" }))
    }

    func testRejects_unsupportedSchemaVersion() {
        var cfg = PublishConfig()
        cfg.schemaVersion = 99
        let errs = PublishConfigValidator.validate(cfg)
        XCTAssertTrue(errs.contains(where: { $0.field == "schema_version" }))
    }

    // Sweep finding P3 (docs/superpowers/notes/2026-07-26-sweep.md) claimed the
    // validator "does not validate" that `filename_template` includes
    // `{version}` — false when filed: the rule has existed since this file's
    // sibling `PublishConfigValidator.swift` was created (`28b6fed9`,
    // lines ~54-56). This file existed too, but never pinned that specific
    // clause. These two close the gap; the dynamic replay half (a doctored
    // snapshot's config re-validated at republish time) is pinned in
    // `RepublisherTests.test_republishRefusesASnapshotWhoseTemplateLacksVersion`,
    // which needs the compile/snapshot harness already built there.
    func test_templateMissingVersionTokenIsRefused() {
        let cfg = PublishConfig(outputs: .init(filenameTemplate: "{title}.{ext}"))
        let errs = PublishConfigValidator.validate(cfg)
        XCTAssertTrue(
            errs.contains(where: { $0.field == "outputs.filename_template" }),
            "expected a filename_template error for a template missing {version}, got \(errs)")
    }

    func test_defaultTemplatePasses() {
        let errs = PublishConfigValidator.validate(PublishConfig())
        XCTAssertFalse(
            errs.contains(where: { $0.field == "outputs.filename_template" }),
            "the default config's filename_template must pass validation, got \(errs)")
    }

    func testBumpVersion_minor_succeeds() {
        XCTAssertEqual(PublishConfigValidator.bumpedNextVersion(from: "0.3"), "0.4")
        XCTAssertEqual(PublishConfigValidator.bumpedNextVersion(from: "1.9"), "1.10")
        XCTAssertEqual(PublishConfigValidator.bumpedNextVersion(from: "0.1"), "0.2")
    }

    func testBumpVersion_invalidInput_resetsToBaseline() {
        XCTAssertEqual(PublishConfigValidator.bumpedNextVersion(from: "garbage"), "0.1")
        XCTAssertEqual(PublishConfigValidator.bumpedNextVersion(from: ""), "0.1")
    }
}

// MARK: - Imprint validation (imprints P1, Task 3)

/// The imprint half of `PublishConfigValidator` — the pure rules that refuse a
/// bad imprint at save time, and the project-aware pass that also asks the
/// filesystem and the project's own piece list.
///
/// The control everywhere is the spec's own example (`2026-08-27-imprints-and-
/// bilingual-editions-design.md` §3): every refusal below is a one-field
/// mutation of a config that this class first proves passes untouched.
final class PublishConfigImprintValidationTests: XCTestCase {

    var tmp: URL!
    var publishDir: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PCImprintValidation-\(UUID().uuidString)")
        publishDir = tmp.appendingPathComponent(".maugham/publish", isDirectory: true)
        try FileManager.default.createDirectory(at: publishDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: Fixtures

    /// The spec §3 example, verbatim, over a two-piece project.
    private func specExample(
        name: String = "special-glb",
        imprint: PublishConfig.Imprint? = nil
    ) -> PublishConfig {
        PublishConfig(
            metadata: .init(title: "Playlist", author: "Denver"),
            imprints: [name: imprint ?? specImprint()])
    }

    private func specImprint(
        template: String? = "templates/special-glb.tex",
        sections: [String: PublishConfig.Section]? = ["ab12": PublishConfig.Section()],
        nextVersion: String? = "0.1"
    ) -> PublishConfig.Imprint {
        PublishConfig.Imprint(
            template: template,
            sections: sections,
            metadata: ["title": .string("Good Luck Babe"), "subtitle": .null],
            outputs: ["filename_template":
                .string("{title}-{imprint}-v{version}{language}{label_suffix}.{ext}")],
            cover: ["path": .string("covers/glb-cover.jpg")],
            nextVersion: nextVersion)
    }

    private func fields(_ errs: [PublishConfigValidator.ValidationError]) -> [String] {
        errs.map(\.field)
    }

    /// Writes `relative` under the publish dir, creating parents.
    private func write(_ relative: String, into dir: URL) throws {
        let url = dir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("% template".utf8).write(to: url)
    }

    // MARK: The control

    func test_specExampleImprint_passesThePureRules() {
        let errs = PublishConfigValidator.validate(specExample())
        XCTAssertTrue(errs.isEmpty, "the spec's own example must validate, got \(errs)")
    }

    // MARK: Name

    func test_imprintNameWithUppercase_isRefused() {
        let errs = PublishConfigValidator.validate(specExample(name: "Special"))
        XCTAssertTrue(errs.contains { $0.field == "imprints.Special" },
                      "expected a name error for 'Special', got \(fields(errs))")
    }

    func test_imprintNameWithUnderscore_isRefused() {
        let errs = PublishConfigValidator.validate(specExample(name: "special_glb"))
        XCTAssertTrue(errs.contains { $0.field == "imprints.special_glb" },
                      "expected a name error for 'special_glb', got \(fields(errs))")
    }

    func test_imprintNameEmpty_isRefused() {
        let errs = PublishConfigValidator.validate(specExample(name: ""))
        XCTAssertTrue(errs.contains { $0.field == "imprints." },
                      "expected a name error for the empty name, got \(fields(errs))")
    }

    // MARK: The imprint's template — a relative path inside the tree

    func test_imprintTemplateEscapingTheTree_isRefused() {
        let cfg = specExample(imprint: specImprint(template: "../x.tex"))
        let errs = PublishConfigValidator.validate(cfg)
        XCTAssertTrue(errs.contains { $0.field == "imprints.special-glb.template" },
                      "expected a template error for '../x.tex', got \(fields(errs))")
    }

    func test_imprintTemplateAbsolute_isRefused() {
        let cfg = specExample(imprint: specImprint(template: "/etc/x.tex"))
        let errs = PublishConfigValidator.validate(cfg)
        XCTAssertTrue(errs.contains { $0.field == "imprints.special-glb.template" },
                      "expected a template error for '/etc/x.tex', got \(fields(errs))")
    }

    func test_imprintTemplateEmpty_isRefused() {
        let cfg = specExample(imprint: specImprint(template: ""))
        let errs = PublishConfigValidator.validate(cfg)
        XCTAssertTrue(errs.contains { $0.field == "imprints.special-glb.template" },
                      "expected a template error for the empty path, got \(fields(errs))")
    }

    func test_imprintTemplateWithNullByte_isRefused() {
        let cfg = specExample(imprint: specImprint(template: "templates/x\u{0}.tex"))
        let errs = PublishConfigValidator.validate(cfg)
        XCTAssertTrue(errs.contains { $0.field == "imprints.special-glb.template" },
                      "expected a template error for a null byte, got \(fields(errs))")
    }

    func test_imprintTemplateAbsent_isAccepted() {
        let cfg = specExample(imprint: specImprint(template: nil))
        XCTAssertTrue(PublishConfigValidator.validate(cfg).isEmpty,
                      "an imprint that names no template inherits the book's")
    }

    // MARK: The allowlist

    func test_imprintSectionsPresentButEmpty_isRefused() {
        let cfg = specExample(imprint: specImprint(sections: [:]))
        let errs = PublishConfigValidator.validate(cfg)
        XCTAssertTrue(errs.contains { $0.field == "imprints.special-glb.sections" },
                      "expected a sections error for an empty allowlist, got \(fields(errs))")
    }

    func test_imprintSectionsEntryWithIncludeFalse_isRefused() {
        let cfg = specExample(imprint: specImprint(
            sections: ["ab12": PublishConfig.Section(include: false)]))
        let errs = PublishConfigValidator.validate(cfg)
        XCTAssertTrue(errs.contains { $0.field == "imprints.special-glb.sections.ab12" },
                      "expected an entry error for include:false, got \(fields(errs))")
    }

    func test_imprintSectionsAbsent_isAccepted() {
        let cfg = specExample(imprint: specImprint(sections: nil))
        XCTAssertTrue(PublishConfigValidator.validate(cfg).isEmpty,
                      "an absent allowlist inherits the book's map")
    }

    // MARK: next_version — held to the top level's rule, which is no rule

    /// `validate(_:)` applies NOTHING to the top-level `next_version`
    /// (`PublishConfigValidator.swift`, the body of `validate(_:)`: schema
    /// version, `metadata.title`, `metadata.year`, `outputs.directory`,
    /// `outputs.filename_template`, `outputs.formats_enabled`,
    /// `language_overrides` — and no `next_version` clause). The brief holds an
    /// imprint's counter to "the same rule the top-level already has", so the
    /// imprint's is unconstrained too. This test is what makes that a decision
    /// rather than an omission: if a `next_version` rule is ever added at the
    /// top level, this goes red and the imprint's must move with it.
    func test_nextVersion_isUnconstrained_atBothLevels() {
        var cfg = specExample(imprint: specImprint(nextVersion: "banana"))
        cfg.nextVersion = "banana"
        let errs = PublishConfigValidator.validate(cfg)
        XCTAssertFalse(errs.contains { $0.field == "next_version" },
                       "the top level has no next_version rule; got \(errs)")
        XCTAssertFalse(errs.contains { $0.field == "imprints.special-glb.next_version" },
                       "an imprint's counter is held to the same (absent) rule; got \(errs)")
    }

    // MARK: The selected imprint (constraint 3 — nothing writes the empty string)

    func test_selectedImprintEmptyString_isRefused() {
        var cfg = specExample()
        cfg.imprint = ""
        let errs = PublishConfigValidator.validate(cfg)
        XCTAssertTrue(errs.contains { $0.field == "imprint" },
                      "an imprint of \"\" must be refused, got \(fields(errs))")
    }

    func test_selectedImprintNilOrNamed_isAccepted() {
        var cfg = specExample()
        XCTAssertTrue(PublishConfigValidator.validate(cfg).isEmpty, "nil is the book")
        cfg.imprint = "special-glb"
        XCTAssertTrue(PublishConfigValidator.validate(cfg).isEmpty, "a real name is fine")
    }

    // MARK: The book's own template

    func test_topLevelTemplateEscapingTheTree_isRefused() {
        var cfg = specExample()
        cfg.template = "../evil.tex"
        let errs = PublishConfigValidator.validate(cfg)
        XCTAssertTrue(errs.contains { $0.field == "template" },
                      "expected a top-level template error, got \(fields(errs))")
    }

    func test_topLevelDefaultTemplate_isAccepted() {
        XCTAssertFalse(
            PublishConfigValidator.validate(PublishConfig()).contains { $0.field == "template" },
            "the default template must pass the pure rules")
    }

    // MARK: - Project-aware: existence and piece ids

    func test_projectAware_missingImprintTemplate_isRefused_thenAcceptedOnceWritten() throws {
        try write("template.tex", into: publishDir)
        let cfg = specExample()

        let before = PublishConfigValidator.validate(
            cfg, publishDir: publishDir, pieceIDs: ["ab12"])
        XCTAssertTrue(before.contains { $0.field == "imprints.special-glb.template" },
                      "a template that is not on disk must be refused, got \(fields(before))")

        try write("templates/special-glb.tex", into: publishDir)
        let after = PublishConfigValidator.validate(
            cfg, publishDir: publishDir, pieceIDs: ["ab12"])
        XCTAssertTrue(after.isEmpty, "once written, the same config passes: \(after)")
    }

    func test_projectAware_templateSymlinkedOutOfTheTree_isRefused() throws {
        try write("template.tex", into: publishDir)
        let outside = tmp.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let target = outside.appendingPathComponent("evil.tex")
        try Data("% not ours".utf8).write(to: target)

        let link = publishDir.appendingPathComponent("templates/special-glb.tex")
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let errs = PublishConfigValidator.validate(
            specExample(), publishDir: publishDir, pieceIDs: ["ab12"])
        XCTAssertTrue(errs.contains { $0.field == "imprints.special-glb.template" },
                      "a symlink out of the publish dir must be refused, got \(fields(errs))")
    }

    func test_projectAware_allowlistIdThatIsNotAPiece_isRefused() throws {
        try write("template.tex", into: publishDir)
        try write("templates/special-glb.tex", into: publishDir)
        let errs = PublishConfigValidator.validate(
            specExample(), publishDir: publishDir, pieceIDs: ["cd34"])
        XCTAssertTrue(errs.contains { $0.field == "imprints.special-glb.sections.ab12" },
                      "an allowlist id that names no piece must be refused, got \(fields(errs))")
    }

    func test_projectAware_allowlistIdThatIsAPiece_isAccepted() throws {
        try write("template.tex", into: publishDir)
        try write("templates/special-glb.tex", into: publishDir)
        let errs = PublishConfigValidator.validate(
            specExample(), publishDir: publishDir, pieceIDs: ["cd34", "ab12"])
        XCTAssertTrue(errs.isEmpty, "the same allowlist over a project that has ab12: \(errs)")
    }

    func test_projectAware_missingBookTemplate_isRefused() throws {
        try write("templates/special-glb.tex", into: publishDir)
        let errs = PublishConfigValidator.validate(
            specExample(), publishDir: publishDir, pieceIDs: ["ab12"])
        XCTAssertTrue(errs.contains { $0.field == "template" },
                      "the book's own template must exist too, got \(fields(errs))")
    }

    /// One rule set: the project-aware door runs the pure rules as well, so a
    /// bad name is refused there without a second spelling of the regex.
    func test_projectAware_carriesThePureRules() throws {
        try write("template.tex", into: publishDir)
        try write("templates/special-glb.tex", into: publishDir)
        let errs = PublishConfigValidator.validate(
            specExample(name: "Special"), publishDir: publishDir, pieceIDs: ["ab12"])
        XCTAssertTrue(errs.contains { $0.field == "imprints.Special" },
                      "the pure name rule must fire through the project-aware door, got \(fields(errs))")
    }
}
