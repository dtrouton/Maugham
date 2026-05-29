import XCTest
import MaughamCore
@testable import Maugham

final class CheckpointTests: XCTestCase {
    func test_checkpoint_codable_roundTrips() throws {
        let cp = Checkpoint(
            checkpointId: "cp-01HZK",
            label: "end of draft 2",
            labelSource: .user,
            at: Date(timeIntervalSince1970: 1_715_950_400),
            device: "mac-1",
            activeDoc: "doc-a3f9b2",
            docPointers: ["doc-a3f9b2": "op-01HZK", "doc-c81e44": "op-01HZJ"],
            manuscriptWordCount: 42301)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(Checkpoint.self, from: try enc.encode(cp))
        XCTAssertEqual(back, cp)
    }

    func test_checkpoint_decodesUserAndAutoLabelSource() throws {
        for str in ["user", "auto"] {
            let json = """
            {"checkpoint_id":"cp","label":"L","label_source":"\(str)","at":"2026-05-17T00:00:00Z","device":"m","active_doc":"d","doc_pointers":{},"manuscript_word_count":0}
            """
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            let cp = try dec.decode(Checkpoint.self, from: Data(json.utf8))
            XCTAssertEqual(cp.labelSource.rawValue, str)
        }
    }
}
