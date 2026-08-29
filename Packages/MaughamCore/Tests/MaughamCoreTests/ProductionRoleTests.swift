import XCTest
@testable import MaughamCore

/// Contract tests for `ProductionRole` and the `ProjectManifest.productionRoles`
/// section (publish department P1, schema 8).
///
/// Mirrors `ReviewPassTests`' shape, because the type earns the same machinery:
/// the things worth breaking a build over are that a schema-7 manifest (no
/// `productionRoles` key at all) still opens, that a stored list round-trips
/// byte-stable through `makeEncoder()`, and that the `effective*` fallbacks
/// resolve in one place so no call site ever reads a raw field.
final class ProductionRoleTests: XCTestCase {

    // MARK: - Fixtures

    /// A manifest fixture with an arbitrary `productionRoles` value spliced in.
    /// `productionRolesJSON` is the raw JSON for the key, or nil to omit the key
    /// entirely (a schema-7 manifest).
    private func manifestJSON(schemaVersion: Int, productionRolesJSON: String? = nil) -> Data {
        let line = productionRolesJSON.map { "  \"productionRoles\": \($0),\n" } ?? ""
        return Data("""
        {
          "schemaVersion": \(schemaVersion),
          "type": "novel",
          "title": "The Book",
          "author": "A",
          "created": "2026-01-01T00:00:00Z",
          "modified": "2026-01-01T00:00:00Z",
          "structure": [],
          "research": [],
        \(line)  "showElementGutter": false
        }
        """.utf8)
    }

    private func wire(_ manifest: ProjectManifest) throws -> String {
        String(decoding: try ProjectManifest.makeEncoder().encode(manifest), as: UTF8.self)
    }

    private func roundTrip(_ role: ProductionRole.Role) throws -> ProductionRole.Role {
        let data = try JSONEncoder().encode(role)
        return try JSONDecoder().decode(ProductionRole.Role.self, from: data)
    }

    private func rawOnTheWire(_ role: ProductionRole.Role) throws -> String {
        String(decoding: try JSONEncoder().encode(role), as: UTF8.self)
    }

    // MARK: - Control

    /// CONTROL: asserts a fact that holds independently of anything this task
    /// implements, so a green run of this file cannot mean "the file never
    /// compiled into the target".
    func test_control_aManifestOneVersionAboveThisBuildIsRefused() {
        let json = manifestJSON(schemaVersion: ProjectManifest.currentSchemaVersion + 1)
        XCTAssertThrowsError(try ProjectManifest.decodeGuardingSchema(json))
    }

    // MARK: - Role: the single-string on-disk form

    func test_theDesignerRoleIsASingleStringOnTheWire() throws {
        XCTAssertEqual(try rawOnTheWire(.designer), #""designer""#)
        XCTAssertEqual(try roundTrip(.designer), .designer)
    }

    func test_aTranslatorRoleCarriesItsLanguageAfterTheColon() throws {
        XCTAssertEqual(try rawOnTheWire(.translator(language: "es")), #""translator:es""#)
        XCTAssertEqual(try roundTrip(.translator(language: "es")), .translator(language: "es"))
    }

    /// The `Statement.Scope` rule: split on the FIRST colon, so a language tag
    /// containing one survives whole.
    func test_aLanguageTagContainingAColonSurvivesWhole() throws {
        let role = ProductionRole.Role.translator(language: "zh:Hant")
        XCTAssertEqual(try rawOnTheWire(role), #""translator:zh:Hant""#)
        XCTAssertEqual(try roundTrip(role), role)
    }

    /// A role written by a newer build is preserved verbatim, never degraded to
    /// a default — the identity-bearing tolerance `Statement.Kind` documents.
    func test_anUnrecognisedRoleIsLosslessAcrossARoundTrip() throws {
        let data = Data(#""compositor""#.utf8)
        let role = try JSONDecoder().decode(ProductionRole.Role.self, from: data)
        XCTAssertEqual(role, .unknown("compositor"))
        XCTAssertEqual(try rawOnTheWire(role), #""compositor""#)
    }

    /// `"translator:"` with no language would otherwise mint a translator that
    /// matches no edition while looking valid — it decodes as unknown, and
    /// re-encodes as the same raw string.
    func test_aTranslatorWithAnEmptyLanguageDecodesAsUnknownAndStaysLossless() throws {
        let role = try JSONDecoder().decode(
            ProductionRole.Role.self, from: Data(#""translator:""#.utf8))
        XCTAssertEqual(role, .unknown("translator:"))
        XCTAssertEqual(try rawOnTheWire(role), #""translator:""#)
    }

    // MARK: - The preset table

    func test_thePresetTranslatorNamesAreTheFourTheSpecFixes() {
        XCTAssertEqual(ProductionRole.defaultTranslatorName(language: "es"), "Cortázar")
        XCTAssertEqual(ProductionRole.defaultTranslatorName(language: "fr"), "Baudelaire")
        XCTAssertEqual(ProductionRole.defaultTranslatorName(language: "de"), "Tieck")
        XCTAssertEqual(ProductionRole.defaultTranslatorName(language: "ja"), "Motoyuki")
    }

    /// nil, not a manufactured name: an unlisted language is the case where the
    /// caller asks the writer who this translator is.
    func test_anUnlistedLanguageHasNoPresetName() {
        XCTAssertNil(ProductionRole.defaultTranslatorName(language: "is"))
        XCTAssertNil(ProductionRole.defaultTranslatorName(language: ""))
    }

    /// **The lookup is case-insensitive on the tag** — `defaultTranslatorName`
    /// lowercases before consulting `presetTranslatorNames`, but nothing pinned
    /// that until now. Matters because `translatorRole(for:)`'s mint matches
    /// case-insensitively too (`storedTranslator(for:)`), so a caller spelling
    /// the tag either way must land the same preset name.
    func test_thePresetLookupIsCaseInsensitiveOnTheTag() {
        XCTAssertEqual(ProductionRole.defaultTranslatorName(language: "ES"), "Cortázar")
        XCTAssertEqual(ProductionRole.defaultTranslatorName(language: "Es"), "Cortázar")
    }

    func test_thePresetDesignerIsTschichold() {
        XCTAssertEqual(ProductionRole.presetDesigner.role, .designer)
        XCTAssertEqual(ProductionRole.presetDesigner.name, "Tschichold")
        XCTAssertNotNil(ProductionRole.presetDesigner.brief)
        XCTAssertFalse((ProductionRole.presetDesigner.brief ?? "").isEmpty)
    }

    /// Pins the doctrine, not a word count: the designer reads the visual
    /// language statement first, and every proposal is demonstrated in sample
    /// pages.
    func test_theDesignerBriefCarriesItsThreeStandingInstructions() throws {
        let brief = try XCTUnwrap(ProductionRole.presetDesigner.brief)
        XCTAssertTrue(brief.contains("visual language"), brief)
        XCTAssertTrue(brief.contains("sample pages"), brief)
        XCTAssertTrue(brief.lowercased().contains("every element"), brief)
    }

    // MARK: - effectiveName (never read the raw field)

    func test_anOwnNameWinsOverEveryPreset() {
        let role = ProductionRole(id: "r1", role: .designer, name: "Hochuli")
        XCTAssertEqual(role.effectiveName, "Hochuli")
    }

    func test_aDesignerWithNoNameOfItsOwnIsTschichold() {
        let role = ProductionRole(id: "r1", role: .designer)
        XCTAssertEqual(role.effectiveName, "Tschichold")
    }

    func test_aTranslatorWithNoNameOfItsOwnTakesThePresetForItsLanguage() {
        let role = ProductionRole(id: "r1", role: .translator(language: "fr"))
        XCTAssertEqual(role.effectiveName, "Baudelaire")
    }

    /// The last resort: an unlisted language with no name yet still yields
    /// something a surface can print — the tag itself, uppercased, never "".
    func test_anUnlistedUnnamedTranslatorFallsBackToTheUppercasedTag() {
        let role = ProductionRole(id: "r1", role: .translator(language: "is"))
        XCTAssertEqual(role.effectiveName, "IS")
    }

    func test_effectiveNameIsNeverEmptyForAnyRole() {
        let roles: [ProductionRole] = [
            ProductionRole(id: "a", role: .designer),
            ProductionRole(id: "b", role: .translator(language: "es")),
            ProductionRole(id: "c", role: .translator(language: "is")),
            ProductionRole(id: "d", role: .translator(language: "")),
            ProductionRole(id: "e", role: .unknown("compositor")),
            ProductionRole(id: "f", role: .unknown("")),
            ProductionRole(id: "g", role: .designer, name: ""),
            ProductionRole(id: "h", role: .reader(language: "")),
            ProductionRole(id: "i", role: .collator(language: "")),
            ProductionRole(id: "j", role: .reader(language: "sr")),
            ProductionRole(id: "k", role: .collator(language: "sr")),
        ]
        for role in roles {
            XCTAssertFalse(role.effectiveName.isEmpty, "empty effectiveName for \(role.role)")
        }
    }

    // MARK: - effectiveBrief

    func test_anOwnBriefWinsOverThePreset() {
        let role = ProductionRole(id: "r1", role: .designer, brief: "Set it in Bembo.")
        XCTAssertEqual(role.effectiveBrief, "Set it in Bembo.")
    }

    func test_aDesignerWithNoBriefOfItsOwnGetsThePresetDoctrine() {
        let role = ProductionRole(id: "r1", role: .designer)
        XCTAssertEqual(role.effectiveBrief, ProductionRole.presetDesigner.brief)
    }

    /// Translator preset briefs arrive with Plan 2's briefing work — until then
    /// a translator with no brief of its own has none, and a caller must not
    /// find a designer's doctrine handed to a translator.
    func test_aTranslatorWithNoBriefOfItsOwnHasNoneYet() {
        let role = ProductionRole(id: "r1", role: .translator(language: "es"))
        XCTAssertNil(role.effectiveBrief)
    }

    // MARK: - The absent section

    /// A schema-7 manifest has no `productionRoles` key. It must still open,
    /// with an empty stored section — not throw `keyNotFound`, which would make
    /// every project written before this milestone unopenable.
    func test_aSchemaSevenManifestWithNoProductionRolesKeyStillDecodes() throws {
        let manifest = try ProjectManifest.decodeGuardingSchema(manifestJSON(schemaVersion: 7))
        XCTAssertEqual(manifest.productionRoles, [])
    }

    // MARK: - effectiveProductionRoles (the preset MERGES, it does not replace)

    /// The designer exists from the start: with nothing stored, the preset is
    /// what a reader gets — and it is not migrated onto disk (tripwire 11).
    func test_anAbsentSectionYieldsThePresetDesignerAlone() throws {
        let manifest = try ProjectManifest.decodeGuardingSchema(manifestJSON(schemaVersion: 7))
        XCTAssertEqual(manifest.effectiveProductionRoles, [ProductionRole.presetDesigner])
        XCTAssertEqual(manifest.productionRoles, [], "the preset is computed, never written back")
    }

    /// The difference from `effectiveReviewPasses`: a stored list of minted
    /// translators must SURVIVE alongside the preset designer, not be replaced
    /// by it.
    func test_thePresetDesignerIsPrependedToStoredTranslators() {
        let translator = ProductionRole(id: "t-es", role: .translator(language: "es"))
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(timeIntervalSince1970: 0), modified: Date(timeIntervalSince1970: 0),
            structure: [], research: [],
            productionRoles: [translator])

        XCTAssertEqual(manifest.effectiveProductionRoles, [ProductionRole.presetDesigner, translator])
    }

    /// A stored designer — renamed, re-briefed, or just re-saved — is the
    /// project's designer; the preset must not be prepended beside it, or the
    /// desk would show two.
    func test_aStoredDesignerSuppressesThePreset() {
        let ownDesigner = ProductionRole(id: "d-1", role: .designer, name: "Hochuli")
        let translator = ProductionRole(id: "t-es", role: .translator(language: "es"))
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(timeIntervalSince1970: 0), modified: Date(timeIntervalSince1970: 0),
            structure: [], research: [],
            productionRoles: [translator, ownDesigner])

        XCTAssertEqual(manifest.effectiveProductionRoles, [translator, ownDesigner])
    }

    // MARK: - Round-trip

    /// Two roles — a translator and a renamed designer — round-trip byte-stable
    /// through `makeEncoder()`.
    func test_twoProductionRolesRoundTripByteStable() throws {
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(timeIntervalSince1970: 0), modified: Date(timeIntervalSince1970: 0),
            structure: [], research: [],
            productionRoles: [
                ProductionRole(id: "t-es", role: .translator(language: "es"), name: "Aurora"),
                ProductionRole(id: "d-1", role: .designer, brief: "Warmer paper, looser leading."),
            ])

        let resaved = try wire(manifest)
        let back = try ProjectManifest.decodeGuardingSchema(Data(resaved.utf8))
        XCTAssertEqual(back.productionRoles, manifest.productionRoles)

        let resavedAgain = try wire(back)
        XCTAssertEqual(resavedAgain, resaved)
    }

    /// Pins the wire shape: `role` is the single string, and a role with no
    /// name/brief of its own omits those keys rather than writing null.
    func test_theOnDiskShapeIsTheSingleRoleString() throws {
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(timeIntervalSince1970: 0), modified: Date(timeIntervalSince1970: 0),
            structure: [], research: [],
            productionRoles: [ProductionRole(id: "t-ja", role: .translator(language: "ja"))])

        let resaved = try wire(manifest)
        XCTAssertTrue(resaved.contains(#""role" : "translator:ja""#), resaved)
        XCTAssertTrue(resaved.contains(#""id" : "t-ja""#), resaved)
        XCTAssertFalse(resaved.contains(#""name""#), resaved)
    }

    /// A role a newer build wrote survives an old build's open-and-re-save
    /// unchanged — the lossless `.unknown` carried through the manifest, not
    /// just through the enum in isolation.
    func test_anUnknownRoleSurvivesAManifestReSaveVerbatim() throws {
        let manifest = try ProjectManifest.decodeGuardingSchema(manifestJSON(
            schemaVersion: 8,
            productionRolesJSON: #"[{"id":"x","role":"compositor"}]"#))
        XCTAssertEqual(manifest.productionRoles.first?.role, .unknown("compositor"))
        XCTAssertTrue(try wire(manifest).contains(#""role" : "compositor""#))
    }

    // MARK: - The schema gate (the paired-release guarantee)

    /// Version-relative on purpose — the 2026-08-09 lesson: a gate test
    /// hardcoded to a literal has to be edited at every bump, which is a test
    /// that will one day be edited wrongly.
    func test_aManifestFromANewerBuildIsRefused_namingBothVersions() {
        let newer = ProjectManifest.currentSchemaVersion + 1
        XCTAssertThrowsError(
            try ProjectManifest.decodeGuardingSchema(manifestJSON(schemaVersion: newer))
        ) { error in
            guard let e = error as? ProjectManifest.SchemaTooNewError else {
                return XCTFail("Expected SchemaTooNewError, got \(error)")
            }
            XCTAssertEqual(e, ProjectManifest.SchemaTooNewError(
                found: newer, supported: ProjectManifest.currentSchemaVersion))
        }
    }

    /// The section this task adds is what makes the milestone a paired release:
    /// the schema this build writes must be at least 8, or a shipped phone
    /// build would open a manifest carrying roles and re-save it without them.
    func test_theSchemaIsAtLeastEightForTheProductionRolesSection() {
        XCTAssertGreaterThanOrEqual(ProjectManifest.currentSchemaVersion, 8)
    }

    // MARK: - Reader and collator (translation pipeline P1)

    func test_aReaderRoleCarriesItsLanguageAfterTheColon() throws {
        let role = try JSONDecoder().decode(ProductionRole.Role.self, from: Data("\"reader:es\"".utf8))
        XCTAssertEqual(role, .reader(language: "es"))
        XCTAssertEqual(role.rawValue, "reader:es")
    }

    func test_aCollatorRoleCarriesItsLanguageAfterTheColon() throws {
        let role = try JSONDecoder().decode(ProductionRole.Role.self, from: Data("\"collator:pt-br\"".utf8))
        XCTAssertEqual(role, .collator(language: "pt-br"))
        XCTAssertEqual(role.rawValue, "collator:pt-br")
    }

    func test_aReaderOrCollatorWithAnEmptyLanguageDecodesAsUnknownAndStaysLossless() throws {
        for raw in ["reader:", "collator:"] {
            let role = try JSONDecoder().decode(ProductionRole.Role.self, from: Data("\"\(raw)\"".utf8))
            XCTAssertEqual(role, .unknown(raw), raw)
            let re = try JSONEncoder().encode(role)
            XCTAssertEqual(String(decoding: re, as: UTF8.self), "\"\(raw)\"")
        }
    }

    func test_thePresetReadersAndCollatorsAreTheEightTheSpecFixes() {
        XCTAssertEqual(ProductionRole.defaultReaderName(language: "es"), "Ocampo")
        XCTAssertEqual(ProductionRole.defaultReaderName(language: "fr"), "Colette")
        XCTAssertEqual(ProductionRole.defaultReaderName(language: "de"), "Bachmann")
        XCTAssertEqual(ProductionRole.defaultReaderName(language: "ja"), "Enchi")
        XCTAssertEqual(ProductionRole.defaultCollatorName(language: "es"), "Borges")
        XCTAssertEqual(ProductionRole.defaultCollatorName(language: "fr"), "Yourcenar")
        XCTAssertEqual(ProductionRole.defaultCollatorName(language: "de"), "Schlegel")
        XCTAssertEqual(ProductionRole.defaultCollatorName(language: "ja"), "Futabatei")
        XCTAssertNil(ProductionRole.defaultReaderName(language: "sr"))
        XCTAssertNil(ProductionRole.defaultCollatorName(language: "sr"))
        XCTAssertEqual(ProductionRole.defaultReaderName(language: "ES"), "Ocampo", "case-insensitive on the tag")
    }

    func test_aReaderWithNoNameOfItsOwnTakesThePresetForItsLanguage() {
        XCTAssertEqual(ProductionRole(id: "r", role: .reader(language: "fr")).effectiveName, "Colette")
        XCTAssertEqual(ProductionRole(id: "c", role: .collator(language: "de")).effectiveName, "Schlegel")
    }

    func test_anUnlistedUnnamedReaderFallsBackToTheUppercasedTag() {
        XCTAssertEqual(ProductionRole(id: "r", role: .reader(language: "sr")).effectiveName, "SR")
        XCTAssertEqual(ProductionRole(id: "c", role: .collator(language: "sr")).effectiveName, "SR")
    }

    func test_anOwnNameWinsForAReaderAndACollator() {
        XCTAssertEqual(ProductionRole(id: "r", role: .reader(language: "es"), name: "Pizarnik").effectiveName, "Pizarnik")
        XCTAssertEqual(ProductionRole(id: "c", role: .collator(language: "es"), name: "Bioy").effectiveName, "Bioy")
    }

    func test_aReaderAndACollatorAlwaysHaveADoctrine() throws {
        let reader = try XCTUnwrap(ProductionRole(id: "r", role: .reader(language: "es")).effectiveBrief)
        XCTAssertTrue(reader.contains("will not see"), "the reader's brief states its blindness")
        XCTAssertTrue(reader.contains("Do not rewrite"))
        XCTAssertTrue(reader.contains("author's language"), "notes are written to the author")
        let collator = try XCTUnwrap(ProductionRole(id: "c", role: .collator(language: "es")).effectiveBrief)
        XCTAssertTrue(collator.contains("side by side"))
        XCTAssertTrue(collator.contains("drifted"))
        XCTAssertTrue(collator.contains("glossary"))
        XCTAssertNotEqual(reader, collator)
    }

    func test_anOwnBriefWinsForAReader() {
        let role = ProductionRole(id: "r", role: .reader(language: "es"), brief: "Only flag register.")
        XCTAssertEqual(role.effectiveBrief, "Only flag register.")
    }

    func test_theManifestFindsAStoredReaderAndCollatorCaseInsensitively() throws {
        let json = manifestJSON(schemaVersion: 8, productionRolesJSON: """
            [{"id":"r1","role":"reader:es","name":"Pizarnik"},
             {"id":"c1","role":"collator:es"},
             {"id":"t1","role":"translator:es"}]
            """)
        let manifest = try ProjectManifest.decodeGuardingSchema(json)
        XCTAssertEqual(manifest.storedReader(for: "ES")?.id, "r1")
        XCTAssertEqual(manifest.storedCollator(for: "es")?.id, "c1")
        XCTAssertEqual(manifest.storedTranslator(for: "es")?.id, "t1", "unchanged")
        XCTAssertNil(manifest.storedReader(for: "fr"))
    }
}
