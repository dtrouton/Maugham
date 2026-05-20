import XCTest
@testable import Maugham

final class SynthesisSourceMigrationTests: XCTestCase {
    /// Existing op logs on disk encode synthesisSource as a snake_case string
    /// (e.g. "paragraph_deleted"). Verify the new enum decodes that shape.
    func test_existingOpLog_withStringSynthesisSource_decodesToEnum() throws {
        let json = #"""
        {
          "op_id": "01ABCDEFGHJKMNPQRSTVWXYZ12",
          "doc_id": "doc-x",
          "at": "2026-05-19T12:00:00.000Z",
          "device": "d1",
          "session": "s1",
          "kind": "claude_archive",
          "changes": [],
          "provenance": {
            "synthesis_source": "paragraph_deleted",
            "source_annotation_id": "01ANN"
          }
        }
        """#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let op = try decoder.decode(Op.self, from: json)
        XCTAssertEqual(op.provenance?.synthesisSource, .paragraphDeleted)
    }

    func test_newOp_withEnumSynthesisSource_roundTripsViaCodable() throws {
        let original = Op(
            opId: "01TESTOPID0000000000000000",
            docId: "doc-x",
            at: Date(timeIntervalSince1970: 1_715_000_000),
            device: "d1", session: "s1",
            kind: .checkpointRestore,
            changes: [.init(paragraphId: "aabb", prior: "old", next: "")],
            sequence: ["aabb"],
            provenance: .init(sourceCheckpoint: "01PASTOP00000000000000000A", synthesisSource: .rewind))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let round = try decoder.decode(Op.self, from: data)
        XCTAssertEqual(round.provenance?.synthesisSource, .rewind)
    }
}
