import XCTest
@testable import MaughamCore

/// Contract tests for `ReviewPass` and the `ProjectManifest.reviewPasses`
/// section (M3 P1, schema 6).
///
/// Mirrors `StatementTests`' shape: the two things worth breaking a build
/// over are that a schema-5 manifest (no `reviewPasses` key at all) still
/// opens, and that a customized list round-trips byte-stable through
/// `makeEncoder()`.
final class ReviewPassTests: XCTestCase {

    // MARK: - Fixtures

    /// A manifest fixture with an arbitrary `reviewPasses` value spliced in.
    /// `reviewPassesJSON` is the raw JSON for the key, or nil to omit the key
    /// entirely (a schema-5 manifest).
    private func manifestJSON(
        schemaVersion: Int,
        reviewPassesJSON: String? = nil,
        coachVacatedJSON: String? = nil
    ) -> Data {
        let line = reviewPassesJSON.map { "  \"reviewPasses\": \($0),\n" } ?? ""
        let coachLine = coachVacatedJSON.map { "  \"coachVacated\": \($0),\n" } ?? ""
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
        \(coachLine)\(line)  "showElementGutter": false
        }
        """.utf8)
    }

    private func wire(_ manifest: ProjectManifest) throws -> String {
        String(decoding: try ProjectManifest.makeEncoder().encode(manifest), as: UTF8.self)
    }

    // MARK: - Control

    /// CONTROL: asserts a fact that holds independently of anything this task
    /// implements, so a green run of this file cannot mean "the file never
    /// compiled into the target".
    func test_control_aManifestOneVersionAboveThisBuildIsRefused() {
        let json = manifestJSON(schemaVersion: ProjectManifest.currentSchemaVersion + 1)
        XCTAssertThrowsError(try ProjectManifest.decodeGuardingSchema(json))
    }

    // MARK: - The presets

    func test_presetsHaveTheStableContractIdsAndNames() {
        XCTAssertEqual(ReviewPass.presets.map(\.id), ["structural", "line", "copyedit", "proof"])
        XCTAssertEqual(ReviewPass.presets.map(\.name), ["Structural", "Line", "Copyedit", "Proof"])
    }

    // MARK: - The absent section

    /// A schema-5 manifest has no `reviewPasses` key. It must still open,
    /// with an empty stored section — not throw `keyNotFound`, which would
    /// make every project written before this milestone unopenable.
    func test_aSchemaFiveManifestWithNoReviewPassesKeyStillDecodes() throws {
        let manifest = try ProjectManifest.decodeGuardingSchema(manifestJSON(schemaVersion: 5))
        XCTAssertEqual(manifest.reviewPasses, [])
    }

    // MARK: - The presets projection (tripwire 11: never written back)

    /// An absent stored list means the presets, computed via
    /// `effectiveReviewPasses` — never migrated onto disk.
    func test_absentReviewPassesMeansPresetsViaEffective() throws {
        let manifest = try ProjectManifest.decodeGuardingSchema(manifestJSON(schemaVersion: 5))
        XCTAssertEqual(manifest.effectiveReviewPasses, ReviewPass.presets)
        // And it stays absent-on-disk: re-encoding an unmodified decode must
        // not have quietly minted the presets into `reviewPasses`.
        XCTAssertEqual(manifest.reviewPasses, [])
    }

    /// An explicitly emptied list reads the same as an absent one.
    func test_emptyReviewPassesMeansPresetsViaEffective() throws {
        let manifest = try ProjectManifest.decodeGuardingSchema(
            manifestJSON(schemaVersion: 6, reviewPassesJSON: "[]"))
        XCTAssertEqual(manifest.effectiveReviewPasses, ReviewPass.presets)
    }

    /// A customized list is what `effectiveReviewPasses` returns — not the
    /// presets — once the writer has actually written one.
    func test_customReviewPassesOverridePresetsViaEffective() throws {
        let json = """
        [{"id": "beta", "name": "Beta Read"}]
        """
        let manifest = try ProjectManifest.decodeGuardingSchema(
            manifestJSON(schemaVersion: 6, reviewPassesJSON: json))
        XCTAssertEqual(manifest.effectiveReviewPasses, [ReviewPass(id: "beta", name: "Beta Read")])
    }

    // MARK: - The schema gate (the paired-release guarantee)

    /// Version-relative on purpose — the 2026-08-09 lesson: a gate test
    /// hardcoded to literal 5/6 has to be edited at every bump, which is a
    /// test that will one day be edited wrongly.
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

    func test_theCurrentSchemaVersionIsAccepted() throws {
        let manifest = try ProjectManifest.decodeGuardingSchema(
            manifestJSON(schemaVersion: ProjectManifest.currentSchemaVersion))
        XCTAssertEqual(manifest.reviewPasses, [])
    }

    // MARK: - Round-trip

    /// A manifest with a custom list round-trips it byte-stable through
    /// `makeEncoder()`.
    func test_customReviewPassesRoundTripByteStable() throws {
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(timeIntervalSince1970: 0), modified: Date(timeIntervalSince1970: 0),
            structure: [], research: [],
            reviewPasses: [
                ReviewPass(id: "structural", name: "Structural"),
                ReviewPass(id: "custom-pass", name: "My Custom Pass"),
            ])

        let resaved = try wire(manifest)
        let back = try ProjectManifest.decodeGuardingSchema(Data(resaved.utf8))
        XCTAssertEqual(back.reviewPasses, manifest.reviewPasses)

        // Byte-stable: encoding the round-tripped value again produces the
        // identical wire string.
        let resavedAgain = try wire(back)
        XCTAssertEqual(resavedAgain, resaved)
    }

    /// Pins the wire shape: id/name keys, array order preserved.
    func test_theOnDiskShapeIsIdAndNameInArrayOrder() throws {
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(timeIntervalSince1970: 0), modified: Date(timeIntervalSince1970: 0),
            structure: [], research: [],
            reviewPasses: [ReviewPass(id: "line", name: "Line")])

        let resaved = try wire(manifest)
        XCTAssertTrue(resaved.contains(#""id" : "line""#), resaved)
        XCTAssertTrue(resaved.contains(#""name" : "Line""#), resaved)
    }

    // MARK: - Briefs and named editors (M4 P1 Task 1)

    /// Legacy on-disk shape (pre-M4) has neither key. Synthesized decoding
    /// with `decodeIfPresent` must leave both new fields nil rather than
    /// throwing `keyNotFound`.
    func test_legacyJSONWithNoBriefOrEditorNameDecodesToNilFields() throws {
        let json = Data(#"{"id":"line","name":"Line"}"#.utf8)
        let pass = try JSONDecoder().decode(ReviewPass.self, from: json)
        XCTAssertNil(pass.brief)
        XCTAssertNil(pass.editorName)
    }

    /// A customized manifest can store a preset-id pass (e.g. renamed but
    /// never given its own brief/editor) — `effective*` must fall back to
    /// the preset with the matching id, not to nil/name.
    func test_customizedPresetIdPassResolvesToThatPresetsBriefAndEditor() {
        let renamedButNotRebriefed = ReviewPass(id: "line", name: "Line Notes")
        let preset = ReviewPass.presets.first { $0.id == "line" }!

        XCTAssertEqual(renamedButNotRebriefed.effectiveBrief, preset.brief)
        XCTAssertEqual(renamedButNotRebriefed.effectiveEditorName, "Lish")
    }

    /// A pass's own brief/editorName win over the preset-by-id fallback,
    /// even when the id matches a preset.
    func test_ownBriefAndEditorNameWinOverThePresetWithTheSameId() {
        let pass = ReviewPass(id: "line", name: "Line", brief: "Custom brief.", editorName: "Custom Editor")
        XCTAssertEqual(pass.effectiveBrief, "Custom brief.")
        XCTAssertEqual(pass.effectiveEditorName, "Custom Editor")
    }

    /// A fully custom pass (no preset shares its id, no own brief/editor)
    /// falls all the way through: brief nil, editorName the pass's own name.
    func test_fullyCustomPassWithNoPresetMatchYieldsNilBriefAndNameAsEditor() {
        let pass = ReviewPass(id: "beta", name: "Beta Read")
        XCTAssertNil(pass.effectiveBrief)
        XCTAssertEqual(pass.effectiveEditorName, "Beta Read")
    }

    /// All four presets carry a brief and the four named editors.
    func test_presetsCarryAllFourBriefsAndEditorNames() {
        XCTAssertEqual(ReviewPass.presets.map(\.editorName), ["Perkins", "Lish", "Gould", "Argus"])
        for preset in ReviewPass.presets {
            XCTAssertNotNil(preset.brief)
            XCTAssertFalse((preset.brief ?? "").isEmpty)
        }
    }

    /// Pins the doctrine, not a count: Proof's brief must advise Fresh Eyes.
    func test_proofsBriefAdvisesFreshEyes() {
        let proof = ReviewPass.presets.first { $0.id == "proof" }!
        XCTAssertTrue(proof.brief?.contains("Fresh Eyes") == true, proof.brief ?? "nil")
        XCTAssertTrue(proof.brief?.contains("⌘⇧R") == true, proof.brief ?? "nil")
    }

    /// A custom pass with the new fields present round-trips byte-stable,
    /// mirroring `test_customReviewPassesRoundTripByteStable` above.
    func test_customReviewPassesWithBriefAndEditorNameRoundTripByteStable() throws {
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(timeIntervalSince1970: 0), modified: Date(timeIntervalSince1970: 0),
            structure: [], research: [],
            reviewPasses: [
                ReviewPass(id: "custom", name: "Custom", brief: "A custom brief.", editorName: "Custom Editor"),
            ])

        let resaved = try wire(manifest)
        let back = try ProjectManifest.decodeGuardingSchema(Data(resaved.utf8))
        XCTAssertEqual(back.reviewPasses, manifest.reviewPasses)

        let resavedAgain = try wire(back)
        XCTAssertEqual(resavedAgain, resaved)
    }

    // MARK: - The coach's seat (editorial letter P1 Task 4)

    /// **The coach is a preset that never enters the ladder's array**
    /// (spec §4.1). `presets` stays exactly the four stages, so every reader
    /// of `effectiveReviewPasses` — `ReviewStatus.derived`, the board's
    /// chips, `validatedActivePass`, `get_outline`'s `review_passes` — is
    /// unchanged by construction rather than by inspection.
    func test_theCoachIsAPresetOutsideTheLadder() {
        XCTAssertEqual(ReviewPass.coachPreset.id, "workshop")
        XCTAssertEqual(ReviewPass.coachPreset.name, "Workshop")
        XCTAssertEqual(ReviewPass.coachPreset.editorName, "Le Guin")
        XCTAssertNotNil(ReviewPass.coachPreset.brief)
        XCTAssertEqual(ReviewPass.presets.count, 4)
        XCTAssertFalse(ReviewPass.presets.contains { $0.id == ReviewPass.coachPreset.id },
                       "the coach must not be a fifth entry in the ladder's presets")
    }

    /// The coach resolves her brief and her editor name from her OWN fields.
    ///
    /// CONTROL, and the point of the test: a pass carrying the same id with
    /// nil fields resolves to its own name and no brief — proving the
    /// `presets.first { $0.id == id }` fallback is NOT what makes the coach
    /// work, i.e. she really is outside the ladder rather than silently a
    /// fifth preset.
    func test_theCoachResolvesFromHerOwnFieldsNotThePresetFallback() {
        XCTAssertEqual(ReviewPass.coachPreset.effectiveEditorName, "Le Guin")
        XCTAssertEqual(ReviewPass.coachPreset.effectiveBrief, ReviewPass.coachPreset.brief)

        let impostor = ReviewPass(id: "workshop", name: "x")
        XCTAssertNil(impostor.effectiveBrief,
                     "a bare workshop-id pass must find no preset to fall back on")
        XCTAssertEqual(impostor.effectiveEditorName, "x")
    }

    /// Pins the doctrine, not a count (spec §4.4): she teaches, her
    /// line-level output is questions only, and she names whose work she
    /// will not do rather than doing it.
    func test_theCoachsBriefCarriesLeGuinsDoctrine() {
        guard let brief = ReviewPass.coachPreset.brief else {
            return XCTFail("the coach lost her brief")
        }
        XCTAssertTrue(brief.contains("teacher"), brief)
        XCTAssertTrue(brief.contains("question"), brief)
        XCTAssertTrue(brief.contains("Gould"), brief)
        XCTAssertTrue(brief.contains("Perkins"), brief)
    }

    // MARK: - Who writes a letter (spec §3.3)

    /// Each preset brief says which parts of the letter its voice writes.
    /// Perkins and Lish take a letter and say what they leave out of it;
    /// Gould and Argus leave the letter empty, in those words, because the
    /// general instruction otherwise tells them to write all of it.
    func test_eachPresetBriefSaysWhatItWritesInTheLetter() {
        func brief(_ id: String) -> String {
            ReviewPass.presets.first { $0.id == id }?.brief ?? ""
        }
        XCTAssertTrue(brief("structural").contains("scenes"), brief("structural"))
        XCTAssertTrue(brief("structural").contains("no exercises"), brief("structural"))
        XCTAssertTrue(brief("line").contains("no scenes"), brief("line"))
        XCTAssertTrue(brief("line").contains("no exercises"), brief("line"))
        XCTAssertTrue(brief("copyedit").contains("leaves the letter empty"), brief("copyedit"))
        XCTAssertTrue(brief("proof").contains("leaves the letter empty"), brief("proof"))
    }

    // MARK: - The seat on the manifest

    /// A manifest with no `coachVacated` key at all — every manifest written
    /// before this milestone — decodes with the seat HELD, not thrown.
    /// Tolerated-missing, no schema bump (constraint 2).
    func test_aManifestWithNoCoachVacatedKeyDecodesWithTheSeatHeld() throws {
        let manifest = try ProjectManifest.decodeGuardingSchema(
            manifestJSON(schemaVersion: ProjectManifest.currentSchemaVersion))
        XCTAssertFalse(manifest.coachVacated)
        XCTAssertEqual(manifest.effectiveCoach, ReviewPass.coachPreset)
    }

    /// A stored `true` reads as a vacated seat, and `effectiveCoach` is nil.
    func test_aVacatedSeatDecodesAndReadsAsNoCoach() throws {
        let manifest = try ProjectManifest.decodeGuardingSchema(
            manifestJSON(
                schemaVersion: ProjectManifest.currentSchemaVersion,
                coachVacatedJSON: "true"))
        XCTAssertTrue(manifest.coachVacated)
        XCTAssertNil(manifest.effectiveCoach)
    }

    /// The seat is always encoded, and a vacated one round-trips byte-stable
    /// — the `reviewPasses` round-trip's shape.
    func test_aVacatedSeatRoundTripsByteStable() throws {
        var manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(timeIntervalSince1970: 0), modified: Date(timeIntervalSince1970: 0),
            structure: [], research: [])
        XCTAssertFalse(manifest.coachVacated, "the memberwise default holds the seat")
        manifest.coachVacated = true

        let resaved = try wire(manifest)
        XCTAssertTrue(resaved.contains(#""coachVacated" : true"#), resaved)
        let back = try ProjectManifest.decodeGuardingSchema(Data(resaved.utf8))
        XCTAssertTrue(back.coachVacated)
        XCTAssertNil(back.effectiveCoach)
        XCTAssertEqual(try wire(back), resaved)
    }

    /// `false` is written too, not omitted: the field is not optional and an
    /// absent key means "held" only for manifests older than the feature.
    func test_theHeldSeatIsWrittenRatherThanOmitted() throws {
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(timeIntervalSince1970: 0), modified: Date(timeIntervalSince1970: 0),
            structure: [], research: [])
        let resaved = try wire(manifest)
        XCTAssertTrue(resaved.contains(#""coachVacated" : false"#), resaved)
    }
}
