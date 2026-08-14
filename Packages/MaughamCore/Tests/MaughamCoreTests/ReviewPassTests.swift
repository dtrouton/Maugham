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
    private func manifestJSON(schemaVersion: Int, reviewPassesJSON: String? = nil) -> Data {
        let line = reviewPassesJSON.map { "  \"reviewPasses\": \($0),\n" } ?? ""
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
}
