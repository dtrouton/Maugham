import XCTest
@testable import Maugham

final class OpTests: XCTestCase {
    func test_op_codable_roundTripsTypingBurst() throws {
        let op = Op(
            opId: "01HZK7ABCDABCDABCDABCDABCD",
            docId: "doc-a3f9b2",
            at: Date(timeIntervalSince1970: 1_715_950_392),
            device: "macbook-pro-1",
            session: "session-1",
            kind: .typingBurst,
            changes: [
                Op.ParagraphChange(
                    paragraphId: "a3f9",
                    prior: "Old line.",
                    next: "New line."),
            ],
            sequence: ["a3f9", "b21c"],
            provenance: nil)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(op)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(Op.self, from: data)
        XCTAssertEqual(back, op)
    }

    func test_op_codable_omitsOptionalSequenceAndProvenance() throws {
        let op = Op(
            opId: "01HZK7ABCDABCDABCDABCDABCD",
            docId: "doc-a3f9b2",
            at: Date(),
            device: "mac-1",
            session: "s1",
            kind: .typingBurst,
            changes: [],
            sequence: nil,
            provenance: nil)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let json = String(data: try enc.encode(op), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("\"sequence\""),
            "expected sequence to be omitted when nil")
        XCTAssertFalse(json.contains("\"provenance\""),
            "expected provenance to be omitted when nil")
    }

    func test_op_decodesAllKinds() throws {
        let kinds: [(String, OpKind)] = [
            ("typing_burst", .typingBurst),
            ("claude_suggestion", .claudeSuggestion),
            ("claude_accept", .claudeAccept),
            ("claude_reject", .claudeReject),
            ("external_edit", .externalEdit),
            ("checkpoint", .checkpoint),
            ("checkpoint_restore", .checkpointRestore),
            ("bootstrap", .bootstrap),
            ("claude_comment", .claudeComment),
            ("claude_query", .claudeQuery),
            ("claude_craft_note", .claudeCraftNote),
            ("claude_archive", .claudeArchive),
        ]
        for (str, expected) in kinds {
            let json = """
            {"op_id":"01HZK7","doc_id":"d","at":"2026-05-17T00:00:00Z","device":"m","session":"s","kind":"\(str)","changes":[]}
            """
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            let op = try dec.decode(Op.self, from: Data(json.utf8))
            XCTAssertEqual(op.kind, expected, "kind \(str) didn't decode to \(expected)")
        }
    }
}
