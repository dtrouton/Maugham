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

    // MARK: - `active_doc` is optional in memory and always present on the wire

    private func decoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }

    private func encoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return enc
    }

    private func checkpoint(activeDoc: String?) -> Checkpoint {
        Checkpoint(
            checkpointId: "cp", label: "L", labelSource: .auto,
            at: Date(timeIntervalSince1970: 0), device: "m",
            activeDoc: activeDoc, docPointers: [:], manuscriptWordCount: 0)
    }

    func test_checkpoint_withNoActiveDoc_roundTrips() throws {
        let cp = checkpoint(activeDoc: nil)
        let back = try decoder().decode(Checkpoint.self, from: try encoder().encode(cp))
        XCTAssertEqual(back, cp)
        XCTAssertNil(back.activeDoc)
    }

    /// **The backward-tolerance contract, and the reason `nil` is written as
    /// `""` rather than by omitting the key.** A project folder is routinely
    /// touched by two app versions at once (ADR 0015's premise), and an older
    /// build decodes `active_doc` non-optionally: a missing key throws, and
    /// `JSONLAppendStore.parse` quarantines the line, so the whole checkpoint
    /// disappears from that build's History. An empty string decodes there as
    /// an id matching no document — which is exactly what the sentinel already
    /// did, so the older build is no worse off than before.
    func test_checkpoint_withNoActiveDoc_stillWritesTheKeyForOlderBuilds() throws {
        let json = String(
            data: try encoder().encode(checkpoint(activeDoc: nil)), encoding: .utf8)
        XCTAssertNotNil(json)
        XCTAssertTrue(
            json?.contains("\"active_doc\":\"\"") == true,
            "an older build's synthesized decoder throws on a missing "
            + "`active_doc` and the row is dropped — got \(json ?? "nil")")
    }

    func test_checkpoint_decodesAnEmptyActiveDocAsNoDocument() throws {
        let json = """
        {"checkpoint_id":"cp","label":"L","label_source":"auto","at":"2026-05-17T00:00:00Z","device":"m","active_doc":"","doc_pointers":{},"manuscript_word_count":0}
        """
        let cp = try decoder().decode(Checkpoint.self, from: Data(json.utf8))
        XCTAssertNil(cp.activeDoc, "the empty string is the wire spelling of no document")
    }

    /// Forward tolerance, the other direction: a row written without the key at
    /// all (by hand, or by some future build that stops writing it) must decode
    /// rather than be quarantined.
    func test_checkpoint_decodesAMissingActiveDocWithoutThrowing() throws {
        let json = """
        {"checkpoint_id":"cp","label":"L","label_source":"auto","at":"2026-05-17T00:00:00Z","device":"m","doc_pointers":{},"manuscript_word_count":0}
        """
        let cp = try decoder().decode(Checkpoint.self, from: Data(json.utf8))
        XCTAssertNil(cp.activeDoc)
        XCTAssertEqual(cp.checkpointId, "cp", "and the rest of the row survives")
    }

    /// The legacy sentinel decodes as itself, not as `nil`. Deciding it names
    /// no document is a *census membership* test that this type cannot make —
    /// it has never seen the project's structure. `PartialRestorePicker` makes
    /// it (`PartialRestoreScopeTests`), where a deleted document is caught by
    /// the same rule.
    func test_checkpoint_decodesALegacySentinelVerbatim() throws {
        let json = """
        {"checkpoint_id":"cp","label":"L","label_source":"auto","at":"2026-05-17T00:00:00Z","device":"m","active_doc":"__no-selection__","doc_pointers":{},"manuscript_word_count":0}
        """
        let cp = try decoder().decode(Checkpoint.self, from: Data(json.utf8))
        XCTAssertEqual(cp.activeDoc, "__no-selection__")
    }
}
