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

    func test_schemaVersion2_isCurrent() {
        // claudeAcceptRevert (2026-07-08) bumped the schema 1 -> 2 (ADR 0015 contract).
        XCTAssertEqual(ProjectManifest.currentSchemaVersion, 2)
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
