import XCTest
@testable import MaughamCore

/// ADR 0014 — persisted-schema evolution. These pin the cross-version
/// Codable tolerance: a value written by a NEWER build must not crash an
/// older build's decode (graceful degradation), while a genuinely
/// newer-SCHEMA manifest is REFUSED outright (no degrade-and-resave
/// corruption).
final class SchemaEvolutionToleranceTests: XCTestCase {

    // MARK: - Op-log enums: unknown → `.unknown`, inert, not a throw

    func testUnknownOpKindDecodesToUnknownNotThrow() throws {
        let json = Data(#""op_kind_from_the_future""#.utf8)
        let kind = try JSONDecoder().decode(OpKind.self, from: json)
        XCTAssertEqual(kind, .unknown,
            "An OpKind raw value from a newer build must decode to .unknown, not throw")
    }

    func testKnownOpKindStillDecodes() throws {
        let json = Data(#""typing_burst""#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(OpKind.self, from: json), .typingBurst)
    }

    func testUnknownOpKindIsInertForManuscript() {
        // The whole point of the `.unknown` case + the compile-forcing switch:
        // an unknown op never mutates derived manuscript text.
        XCTAssertFalse(Deriver.appliesToManuscript(.unknown),
            ".unknown ops must be treated as non-manuscript (inert)")
        // And a real op line carrying an unknown kind must still PARSE at the
        // Op level (so it isn't quarantined / silently dropped) ...
        let opJSON = Data("""
        {"op_id":"op_x","doc_id":"d_x","device":"dev","session":"s","kind":"brand_new_kind","at":"2026-01-01T00:00:00Z","changes":[]}
        """.utf8)
        let op = try? ProjectManifest.makeDecoder().decode(Op.self, from: opJSON)
        XCTAssertNotNil(op, "An op with an unknown kind must still decode (kept, inert)")
        XCTAssertEqual(op?.kind, .unknown)
    }

    func testUnknownSynthesisSourceDecodesToUnknown() throws {
        let json = Data(#""some_future_cause""#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(SynthesisSource.self, from: json), .unknown)
        XCTAssertEqual(try JSONDecoder().decode(SynthesisSource.self, from: Data(#""rewind""#.utf8)), .rewind)
    }

    // MARK: - Manifest enums: unknown → safe default, manifest still decodes

    func testUnknownProjectTypeDegradesToUnknownCase() throws {
        let json = Data(#""graphic_novel""#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ProjectType.self, from: json), .unknown)
        // `.unknown` is excluded from the picker's allCases.
        XCTAssertFalse(ProjectType.allCases.contains(.unknown))
        XCTAssertEqual(ProjectType.allCases.count, 4)
    }

    func testUnknownProjectTypeKeepsWholeManifestDecodable() throws {
        // The high-severity case: one unknown enum value must NOT make the
        // whole project unopenable.
        let manifestJSON = Data("""
        {
          "schemaVersion": 1,
          "type": "graphic_novel",
          "title": "Future Project",
          "author": "A",
          "created": "2026-01-01T00:00:00Z",
          "modified": "2026-01-01T00:00:00Z",
          "structure": [
            {"id":"doc-1","title":"Ch1","type":"chapter_v2"}
          ],
          "research": []
        }
        """.utf8)
        let manifest = try ProjectManifest.decodeGuardingSchema(manifestJSON)
        XCTAssertEqual(manifest.type, .unknown)
        XCTAssertEqual(manifest.title, "Future Project")
        // Unknown structural item type degrades to a benign leaf document.
        XCTAssertEqual(manifest.structure.first?.type, .document)
    }

    func testUnknownStructureItemTypeDegradesToDocument() throws {
        let json = Data(#"{"id":"x","title":"T","type":"freeform_canvas"}"#.utf8)
        let item = try JSONDecoder().decode(StructureItem.self, from: json)
        XCTAssertEqual(item.type, .document)
    }

    func testUnknownResearchItemTypeDegradesToAsset() throws {
        let json = Data(#"{"id":"x","title":"T","type":"smart_folder"}"#.utf8)
        let item = try JSONDecoder().decode(ResearchItem.self, from: json)
        XCTAssertEqual(item.type, .asset)
    }

    func testUnknownAssetKindDegradesToDocument() throws {
        let json = Data(#"{"id":"x","title":"T","type":"asset","kind":"hologram"}"#.utf8)
        let item = try JSONDecoder().decode(ResearchItem.self, from: json)
        XCTAssertEqual(item.kind, .document)
    }

    func testUnknownPieceKindDegradesToLoose() throws {
        let json = Data(#""embedded_app""#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(PieceKind.self, from: json), .loose)
    }

    // MARK: - schemaVersion gate (PRIMARY defence)

    func testSchemaVersionGreaterThanCurrentIsRefused() throws {
        let future = ProjectManifest.currentSchemaVersion + 1
        let json = Data("""
        {
          "schemaVersion": \(future),
          "type": "novel",
          "title": "Newer",
          "author": "A",
          "created": "2026-01-01T00:00:00Z",
          "modified": "2026-01-01T00:00:00Z",
          "structure": [],
          "research": []
        }
        """.utf8)
        XCTAssertThrowsError(try ProjectManifest.decodeGuardingSchema(json)) { error in
            guard let e = error as? ProjectManifest.SchemaTooNewError else {
                return XCTFail("Expected SchemaTooNewError, got \(error)")
            }
            XCTAssertEqual(e.found, future)
            XCTAssertEqual(e.supported, ProjectManifest.currentSchemaVersion)
        }
    }

    func testCurrentSchemaVersionIsAccepted() throws {
        let json = Data("""
        {
          "schemaVersion": \(ProjectManifest.currentSchemaVersion),
          "type": "novel",
          "title": "Now",
          "author": "A",
          "created": "2026-01-01T00:00:00Z",
          "modified": "2026-01-01T00:00:00Z",
          "structure": [],
          "research": []
        }
        """.utf8)
        let m = try ProjectManifest.decodeGuardingSchema(json)
        XCTAssertEqual(m.title, "Now")
    }

    // MARK: - TypographySettings: missing field → default, not a throw

    func testTypographySettingsMissingFieldDecodesWithDefaults() throws {
        // A pre-`ellipsisAutoReplace`-style payload: omit two fields entirely.
        let json = Data("""
        {
          "fontFamily": "Charter",
          "fontSize": 19,
          "lineHeightMultiplier": 1.5,
          "pageWidthCharacters": 80,
          "paragraphSpacingMultiplier": 0.5
        }
        """.utf8)
        let t = try JSONDecoder().decode(TypographySettings.self, from: json)
        XCTAssertEqual(t.fontFamily, "Charter")
        XCTAssertEqual(t.fontSize, 19)
        // Missing fields fall back to defaults instead of throwing keyNotFound.
        XCTAssertEqual(t.smartQuotes, TypographySettings.defaults.smartQuotes)
        XCTAssertEqual(t.emDashAutoReplace, TypographySettings.defaults.emDashAutoReplace)
        XCTAssertEqual(t.ellipsisAutoReplace, TypographySettings.defaults.ellipsisAutoReplace)
    }

    func testTypographySettingsRoundTrips() throws {
        let original = TypographySettings.defaults
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TypographySettings.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Inbox enums: unknown → safe default, row not quarantined

    func testUnknownInboxKindDegradesToText() throws {
        XCTAssertEqual(try JSONDecoder().decode(InboxEntry.Kind.self, from: Data(#""sketch""#.utf8)), .text)
    }

    func testUnknownTranscriptionStateDegradesToFailedNotWorkerEligible() throws {
        // Defaulting to .failed (not .none) avoids a cross-version
        // re-transcription loop against a newer build's state.
        XCTAssertEqual(
            try JSONDecoder().decode(InboxEntry.TranscriptionState.self, from: Data(#""cloud_streaming""#.utf8)),
            .failed)
    }

    func testUnknownInboxStatusDegradesToNewStaysVisible() throws {
        XCTAssertEqual(try JSONDecoder().decode(InboxEntry.Status.self, from: Data(#""snoozed""#.utf8)), .new)
    }

    func testUnknownCheckpointLabelSourceDegradesToAuto() throws {
        XCTAssertEqual(try JSONDecoder().decode(Checkpoint.LabelSource.self, from: Data(#""ai_suggested""#.utf8)), .auto)
    }
}
