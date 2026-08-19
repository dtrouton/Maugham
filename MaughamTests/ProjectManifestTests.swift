import XCTest
import MaughamCore
@testable import Maugham

final class ProjectManifestTests: XCTestCase {
    private func makeISODecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private func makeISOEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    func test_shortStoryManifest_roundTrips() throws {
        let manifest = ProjectManifest(
            schemaVersion: 1,
            type: .shortStory,
            title: "The Fall of Edward Barnard",
            author: "W. Somerset Maugham",
            created: Date(timeIntervalSince1970: 1_715_000_000),
            modified: Date(timeIntervalSince1970: 1_715_001_000),
            structure: [
                StructureItem(id: "manuscript", title: "Story",
                              type: .document, path: "story.md")
            ],
            research: [],
            targets: nil
        )

        let data = try makeISOEncoder().encode(manifest)
        let decoded = try makeISODecoder().decode(ProjectManifest.self, from: data)
        XCTAssertEqual(decoded, manifest)
    }

    func test_novelManifest_withNestedStructure_roundTrips() throws {
        let manifest = ProjectManifest(
            schemaVersion: 1,
            type: .novel,
            title: "The Razor's Edge",
            author: "WSM",
            created: Date(timeIntervalSince1970: 1_715_000_000),
            modified: Date(timeIntervalSince1970: 1_715_001_000),
            structure: [
                StructureItem(id: "act-1", title: "Act One", type: .group, children: [
                    StructureItem(id: "ch-1", title: "Opening",
                                  type: .document, path: "manuscript/01.md")
                ])
            ],
            research: [
                ResearchItem(id: "characters", title: "Characters",
                             type: .group, children: [
                    ResearchItem(id: "larry", title: "Larry",
                                 type: .asset, kind: .image,
                                 path: "research/larry.jpg")
                ])
            ],
            targets: ProjectTargets(totalWords: 90_000, deadline: nil)
        )

        let data = try makeISOEncoder().encode(manifest)
        let decoded = try makeISODecoder().decode(ProjectManifest.self, from: data)
        XCTAssertEqual(decoded, manifest)
    }

    func test_decodingUnknownTopLevelField_doesNotThrow() throws {
        // Forward compatibility: a future version may add fields
        // that this version of Maugham doesn't know about. We
        // tolerate (drop on re-encode for now; preservation lands later).
        let json = """
        {
          "schemaVersion": 1,
          "type": "short_story",
          "title": "X",
          "author": "Y",
          "created": "2026-05-07T14:22:00Z",
          "modified": "2026-05-07T14:22:00Z",
          "structure": [],
          "research": [],
          "future_field_we_do_not_know": {"x": 42}
        }
        """.data(using: .utf8)!

        XCTAssertNoThrow(try makeISODecoder().decode(ProjectManifest.self, from: json))
    }

    func test_schemaVersion8_isCurrent() {
        // claudeAcceptRevert (2026-07-08) bumped the schema 1 -> 2; annotationReopen
        // (2026-07-09, ADR 0015 contract) bumped 2 -> 3; the `statements` section
        // (M1A, 2026-07-31) bumped 3 -> 4 — see ProjectManifest.statements for why
        // an additive, absent-tolerant section still needs the bump. RULING-33
        // (2026-08-09) bumped 4 -> 5: `claudeReject` became manuscript-affecting
        // so the convergence repair can carry the inverse of the accept it beat,
        // and an older build folding none of it would show the suggestion's text
        // under a `rejected` status. M3 P1 (2026-08-14) bumped 5 -> 6: the
        // `reviewPasses` section, plus `passStates` on each `StructureItem` — an
        // older build's re-save would silently drop a writer's per-piece pass
        // state across a whole collection; honest refusal beats silent loss.
        // M3 P2 (2026-08-15) bumped 6 -> 7: the `annotationStet` and
        // `annotationTriage` op kinds, under `OpKind`'s "adding a case ⇒ bump
        // this" contract — an older build derives a stetted note as still
        // OPEN, so the writer is shown a queue they already cleared. The
        // publish department (2026-08-19) bumped 7 -> 8 for two causes: the
        // `productionRoles` section (an older build's re-save drops the
        // writer's named translators and designer, orphaning the annotations
        // they signed) and the new `Statement.Kind.editionBrief` case, which an
        // older build retains losslessly but cannot route — an edition's own
        // doctrine would sit on disk unread.
        //
        // Deliberately a literal, unlike the gate tests: this is the ledger's
        // assertion, and its whole job is to make a bump a conscious act that
        // sends the next person to `currentSchemaVersion`'s doc comment.
        XCTAssertEqual(ProjectManifest.currentSchemaVersion, 8)
    }

    func test_codable_roundTrips_withTypographyOverride() throws {
        let typography = TypographySettings(
            fontFamily: "New York",
            fontSize: 19,
            lineHeightMultiplier: 1.6,
            pageWidthCharacters: 80,
            paragraphSpacingMultiplier: 0.8,
            smartQuotes: false,
            emDashAutoReplace: false,
            ellipsisAutoReplace: false
        )
        let manifest = ProjectManifest(
            type: .novel,
            title: "Test",
            author: "",
            created: Date(),
            modified: Date(),
            structure: [],
            research: [],
            typography: typography
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ProjectManifest.self, from: data)

        XCTAssertEqual(decoded.typography?.fontFamily, "New York")
        XCTAssertEqual(decoded.typography?.fontSize, 19)
    }

    func test_codable_omitsTypography_whenNil() throws {
        let manifest = ProjectManifest(
            type: .shortStory,
            title: "Test",
            author: "",
            created: Date(),
            modified: Date(),
            structure: [],
            research: [],
            typography: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ProjectManifest.self, from: data)
        XCTAssertNil(decoded.typography)
    }
}
