import XCTest
@testable import MaughamCore

/// Contract tests for `Statement` and the `ProjectManifest.statements` section.
///
/// The two things worth breaking a build over: an unknown `kind`/`scope` from a
/// newer build must survive an old build's decode→re-save **byte-identically**
/// (ADR 0015, the `ResearchRole` shape), and a schema-3 manifest — which has no
/// `statements` key at all — must still open.
final class StatementTests: XCTestCase {

    // MARK: - Fixtures

    /// A manifest fixture with an arbitrary `statements` value spliced in.
    /// `statementsJSON` is the raw JSON for the key, or nil to omit the key
    /// entirely (a schema-3 manifest).
    private func manifestJSON(schemaVersion: Int, statementsJSON: String? = nil) -> Data {
        let statementsLine = statementsJSON.map { "  \"statements\": \($0),\n" } ?? ""
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
        \(statementsLine)  "showElementGutter": false
        }
        """.utf8)
    }

    private func wire(_ manifest: ProjectManifest) throws -> String {
        String(decoding: try ProjectManifest.makeEncoder().encode(manifest), as: UTF8.self)
    }

    // MARK: - Control

    /// CONTROL: asserts a fact that holds independently of anything this task
    /// implements, so a green run of this file cannot mean "the file never
    /// compiled into the target". Paired with the executed-test count.
    func test_control_aManifestOneVersionAboveThisBuildIsRefused() {
        let json = manifestJSON(schemaVersion: ProjectManifest.currentSchemaVersion + 1)
        XCTAssertThrowsError(try ProjectManifest.decodeGuardingSchema(json))
    }

    // MARK: - The absent section

    /// A schema-3 manifest has no `statements` key. It must still open, with an
    /// empty section — not throw `keyNotFound`, which would make every project
    /// written before this milestone unopenable.
    func test_aSchemaThreeManifestWithNoStatementsKeyStillDecodes() throws {
        let manifest = try ProjectManifest.decodeGuardingSchema(manifestJSON(schemaVersion: 3))
        XCTAssertEqual(manifest.statements, [])
    }

    // MARK: - The schema gate (the paired-release guarantee)

    /// This build writes and supports schema 4. A schema-5 manifest — written by
    /// a build that knows something we don't — must be refused up front rather
    /// than decoded and re-saved with the newer section stripped.
    func test_aSchemaFiveManifestIsRefusedByThisFourSupportingBuild() {
        XCTAssertThrowsError(try ProjectManifest.decodeGuardingSchema(manifestJSON(schemaVersion: 5))) { error in
            guard let e = error as? ProjectManifest.SchemaTooNewError else {
                return XCTFail("Expected SchemaTooNewError, got \(error)")
            }
            XCTAssertEqual(e, ProjectManifest.SchemaTooNewError(found: 5, supported: 4))
        }
    }

    // MARK: - Lossless unknowns

    /// A `kind` this build does not know is the writer's prose under a label a
    /// newer build understands. Decoding it to a default and re-saving would
    /// destroy that label; it must come back out byte-identical.
    func test_anUnknownKindSurvivesARoundTrip() throws {
        let statements = """
        [{"id": "st-1", "kind": "manifesto", "scope": "project", "path": "manifesto.md"}]
        """
        let manifest = try ProjectManifest.decodeGuardingSchema(
            manifestJSON(schemaVersion: 4, statementsJSON: statements))

        XCTAssertEqual(manifest.statements.first?.kind, .unknown("manifesto"))

        let resaved = try wire(manifest)
        XCTAssertTrue(resaved.contains(#""kind" : "manifesto""#),
            "re-saved manifest must carry the original raw kind; got:\n\(resaved)")
        XCTAssertFalse(resaved.contains(#""kind" : "unknown""#),
            "re-saved manifest must not clobber a newer kind to the literal \"unknown\"")
    }

    /// The same for `scope`: a scope a newer build invented (a series? a piece?)
    /// must not be flattened to `.project`, which would silently re-point the
    /// statement at the whole book.
    func test_anUnknownScopeSurvivesARoundTrip() throws {
        let statements = """
        [{"id": "st-1", "kind": "intent", "scope": "series:s-9", "path": "intent.md"}]
        """
        let manifest = try ProjectManifest.decodeGuardingSchema(
            manifestJSON(schemaVersion: 4, statementsJSON: statements))

        XCTAssertEqual(manifest.statements.first?.scope, .unknown("series:s-9"))

        let resaved = try wire(manifest)
        XCTAssertTrue(resaved.contains(#""scope" : "series:s-9""#),
            "re-saved manifest must carry the original raw scope; got:\n\(resaved)")
        XCTAssertFalse(resaved.contains(#""scope" : "project""#),
            "re-saved manifest must not flatten a newer scope to project")
    }

    // MARK: - The on-disk shape

    /// Pins the wire strings. These are what lands in every writer's
    /// `project.maugham.json`; changing one is a data migration, not a rename.
    func test_theKnownKindsAndScopesEncodeAsTheirDocumentedStrings() throws {
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(timeIntervalSince1970: 0), modified: Date(timeIntervalSince1970: 0),
            structure: [], research: [],
            statements: [
                Statement(id: "st-1", kind: .intent, scope: .project, path: "intent.md"),
                Statement(id: "st-2", kind: .visualLanguage, scope: .project, path: "visual-language.md"),
                Statement(id: "st-3", kind: .intent, scope: .document(DocIdShape.example),
                          path: "intent/chapter-one.md"),
            ])

        let resaved = try wire(manifest)
        XCTAssertTrue(resaved.contains(#""kind" : "intent""#), resaved)
        XCTAssertTrue(resaved.contains(#""kind" : "visual_language""#), resaved)
        XCTAssertTrue(resaved.contains(#""scope" : "project""#), resaved)
        XCTAssertTrue(resaved.contains(#""scope" : "document:\#(DocIdShape.example)""#), resaved)

        let back = try ProjectManifest.decodeGuardingSchema(Data(resaved.utf8))
        XCTAssertEqual(back.statements, manifest.statements)
    }

    /// A document id is opaque to `Scope`, so the split is on the FIRST colon.
    /// An id that itself contains one must come back whole.
    func test_aDocumentScopeRoundTripsAnIdContainingAColon() throws {
        let scope = Statement.Scope.document("doc:with:colons")
        let encoded = String(decoding: try JSONEncoder().encode(scope), as: UTF8.self)
        XCTAssertEqual(encoded, #""document:doc:with:colons""#)
        XCTAssertEqual(try JSONDecoder().decode(Statement.Scope.self, from: Data(encoded.utf8)), scope)
    }

    /// `"document:"` carries no id. Minting an empty-id document scope would
    /// make it match nothing while looking valid; preserve it verbatim instead,
    /// so whatever wrote it gets it back unharmed.
    func test_aDocumentScopeWithNoIdIsPreservedAsUnknown() throws {
        let decoded = try JSONDecoder().decode(Statement.Scope.self, from: Data(#""document:""#.utf8))
        XCTAssertEqual(decoded, .unknown("document:"))
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self),
                       #""document:""#)
    }
}
