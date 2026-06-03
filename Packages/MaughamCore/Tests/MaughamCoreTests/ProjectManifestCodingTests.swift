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
}
