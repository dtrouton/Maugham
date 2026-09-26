import XCTest
@testable import MaughamCore

/// Contract tests that pin `ProjectManifest.fileName` and the shared
/// coder config so any future change that breaks Mac↔phone interop
/// fails here rather than silently at runtime.
final class ProjectManifestCodingTests: XCTestCase {

    // MARK: - T1c: filename constant

    func testFileName() {
        XCTAssertEqual(ProjectManifest.fileName, "project.maugham.json",
            "ProjectManifest.fileName must match the literal used in every project folder")
    }

    // MARK: - T1d: coder round-trip

    /// Fixed epoch so the round-trip is deterministic regardless of wall-clock.
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testRoundTrip() throws {
        let original = ProjectManifest(
            schemaVersion: ProjectManifest.currentSchemaVersion,
            id: "01HTEST00000000000000FIXED",
            type: .novel,
            title: "Test Novel",
            author: "Test Author",
            created: fixedDate,
            modified: fixedDate,
            structure: [],
            research: []
        )

        let encoder = ProjectManifest.makeEncoder()
        let data = try encoder.encode(original)

        let decoder = ProjectManifest.makeDecoder()
        let decoded = try decoder.decode(ProjectManifest.self, from: data)

        XCTAssertEqual(decoded, original,
            "makeEncoder/makeDecoder round-trip must produce an identical ProjectManifest")
    }

    /// Verifies that the encoded JSON uses ISO8601 whole-second dates (the
    /// format the Mac has written since milestone-1a). A fractional-seconds
    /// drift would silently produce a different timestamp on re-decode.
    func testEncodedDateIsISO8601() throws {
        let manifest = ProjectManifest(
            type: .shortStory,
            title: "ISO Date Check",
            author: "",
            created: fixedDate,
            modified: fixedDate,
            structure: [],
            research: []
        )
        let data = try ProjectManifest.makeEncoder().encode(manifest)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        // ISO8601 whole-second: "2023-11-14T22:13:20Z"
        let formatter = ISO8601DateFormatter()
        let expected = formatter.string(from: fixedDate)
        XCTAssertTrue(json.contains(expected),
            "Encoded manifest must contain the ISO8601 date '\(expected)'")
    }

    /// Verifies that `makeEncoder()` uses `.prettyPrinted` + `.sortedKeys`
    /// — the byte-identical output format the Mac has produced since milestone-1a.
    func testEncoderOutputFormatting() throws {
        let manifest = ProjectManifest(
            type: .novel,
            title: "Format Check",
            author: "",
            created: fixedDate,
            modified: fixedDate,
            structure: [],
            research: []
        )
        let data = try ProjectManifest.makeEncoder().encode(manifest)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        // prettyPrinted → contains newlines
        XCTAssertTrue(json.contains("\n"),
            "makeEncoder() must produce pretty-printed JSON (contains newlines)")
        // sortedKeys → "author" appears before "created" (alphabetical order)
        let authorRange = json.range(of: "\"author\"")
        let createdRange = json.range(of: "\"created\"")
        XCTAssertNotNil(authorRange, "Encoded JSON must contain 'author' key")
        XCTAssertNotNil(createdRange, "Encoded JSON must contain 'created' key")
        if let a = authorRange, let c = createdRange {
            XCTAssertLessThan(a.lowerBound, c.lowerBound,
                "makeEncoder() must sort keys: 'author' should appear before 'created'")
        }
    }

    // MARK: - Option A: a piece records its starter (P3c plan 2, ruling OA-1)

    private func manifest(structure: [StructureItem]) -> ProjectManifest {
        ProjectManifest(
            type: .collection, title: "Starters", author: "",
            created: fixedDate, modified: fixedDate,
            structure: structure, research: [])
    }

    /// `startedBy` survives the shared coder, wherever in the tree the item
    /// sits, and the lookup finds it by the piece's id.
    func test_aPiecesStarterRoundTrips() throws {
        let original = manifest(structure: [
            StructureItem(id: "grp", title: "Part", type: .group, children: [
                StructureItem(id: "p1", title: "One", type: .document,
                              path: "pieces/one.md", startedBy: "author-00112233aabbccdd"),
            ]),
            StructureItem(id: "p2", title: "Two", type: .document, path: "pieces/two.md"),
        ])
        let data = try ProjectManifest.makeEncoder().encode(original)
        let decoded = try ProjectManifest.makeDecoder().decode(ProjectManifest.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.startedBy(ofPiece: "p1"), "author-00112233aabbccdd")
        XCTAssertNil(decoded.startedBy(ofPiece: "p2"), "a piece with no starter recorded")
        XCTAssertNil(decoded.startedBy(ofPiece: "nope"), "an id that is no item")
    }

    /// **Both directions of ADR 0015's tolerance.** A manifest written before
    /// this build — no `startedBy` key at all — decodes with nil; a nil starter
    /// writes NO key, so such a manifest's bytes do not change; and an item
    /// carrying a field this build has never heard of still decodes.
    func test_anAbsentStarterDecodesAsNilAndWritesNoKey() throws {
        let legacy = """
        {"schemaVersion":\(ProjectManifest.currentSchemaVersion),"type":"collection",\
        "title":"Old","author":"","created":"2023-11-14T22:13:20Z",\
        "modified":"2023-11-14T22:13:20Z","research":[],"structure":[\
        {"id":"p1","title":"One","type":"document","path":"pieces/one.md",\
        "aFieldFromTomorrow":{"x":1}}]}
        """
        let decoded = try ProjectManifest.makeDecoder()
            .decode(ProjectManifest.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.structure.first?.startedBy)
        XCTAssertNil(decoded.startedBy(ofPiece: "p1"))

        let written = try ProjectManifest.makeEncoder().encode(decoded)
        let text = try XCTUnwrap(String(data: written, encoding: .utf8))
        XCTAssertFalse(text.contains("startedBy"),
            "a piece nobody records a starter for writes exactly what it always did")

        var started = decoded
        started.structure[0].startedBy = "author-00112233aabbccdd"
        let data2 = try ProjectManifest.makeEncoder().encode(started)
        XCTAssertTrue(try XCTUnwrap(String(data: data2, encoding: .utf8)).contains("startedBy"))
        XCTAssertEqual(
            try ProjectManifest.makeDecoder().decode(ProjectManifest.self, from: data2)
                .startedBy(ofPiece: "p1"),
            "author-00112233aabbccdd")
    }
}
