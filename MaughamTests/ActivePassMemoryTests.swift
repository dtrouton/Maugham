import XCTest
import MaughamCore
@testable import Maugham

/// `ActivePassMemory` (M3-P1 Task 5) copies `PersonaMemory`'s tolerant
/// keyed-map shape exactly: a `[String: String]` on the wire, an unreadable
/// map decodes empty, and nothing here throws. The one difference from
/// `PersonaMemory` is that both the key (piece id) and value (pass id) are
/// already bare `String`s — there is no closed-enum value type to fail
/// per-entry at decode, so the "unknown entries drop individually" half of
/// the copied contract has nothing to exercise here beyond the whole-map
/// tolerant fallback.
final class ActivePassMemoryTests: XCTestCase {

    // MARK: - Defaults

    func test_empty_hasNoActivePassForAnyPiece() {
        XCTAssertNil(ActivePassMemory.empty.activePass(forPiece: "piece-1"))
    }

    // MARK: - Recording and reading

    func test_record_thenRead_returnsTheSamePassId() {
        var memory = ActivePassMemory.empty
        memory.record(piece: "piece-1", passId: "line")
        XCTAssertEqual(memory.activePass(forPiece: "piece-1"), "line")
    }

    func test_record_isPerPiece() {
        var memory = ActivePassMemory.empty
        memory.record(piece: "piece-1", passId: "structural")
        memory.record(piece: "piece-2", passId: "proof")
        // piece-1's entry surviving a later write to piece-2's key is the
        // whole distinguishing power here — a single shared slot would have
        // overwritten it.
        XCTAssertEqual(memory.activePass(forPiece: "piece-1"), "structural")
        XCTAssertEqual(memory.activePass(forPiece: "piece-2"), "proof")
        XCTAssertNil(memory.activePass(forPiece: "piece-3"))
    }

    func test_record_overwritesThePreviousValueForThatPiece() {
        var memory = ActivePassMemory.empty
        memory.record(piece: "piece-1", passId: "structural")
        memory.record(piece: "piece-1", passId: "copyedit")
        XCTAssertEqual(memory.activePass(forPiece: "piece-1"), "copyedit")
    }

    // MARK: - Stale ids sit harmlessly (never swept)

    /// `activePass(forPiece:)` returns the raw stored id even when it no
    /// longer names a pass in the project's current
    /// `ProjectManifest.effectiveReviewPasses` — the type has no access to
    /// that list and does not validate against it. Filtering a stale id down
    /// to "no active pass" is a READ-TIME decision for whoever consults
    /// `effectiveReviewPasses` (the board, a later task), mirroring
    /// `PersonaMemory.restoredDetailSegment`'s own validity check happening
    /// at the reader rather than inside the stored map. This test pins the
    /// "never swept" half: the raw entry is exactly what was recorded,
    /// regardless of whether a caller-side filter would currently honour it.
    func test_aPassIdRetiredFromTheProjectsListStillReadsBackRaw() {
        var memory = ActivePassMemory.empty
        memory.record(piece: "piece-1", passId: "structural")

        // A customized pass list that no longer includes "structural".
        let customized = [ReviewPass(id: "line", name: "Line")]
        XCTAssertFalse(customized.contains { $0.id == memory.activePass(forPiece: "piece-1") })

        // The memory itself never swept the entry.
        XCTAssertEqual(memory.activePass(forPiece: "piece-1"), "structural")

        // The intended caller-side pattern (Task 6/8's board): a stale id is
        // treated as "no active pass" without touching the stored memory.
        let filtered = customized.contains(where: { $0.id == memory.activePass(forPiece: "piece-1") })
            ? memory.activePass(forPiece: "piece-1")
            : nil
        XCTAssertNil(filtered)
    }

    // MARK: - Codable

    func test_codable_roundTrip() throws {
        var memory = ActivePassMemory.empty
        memory.record(piece: "piece-1", passId: "line")
        memory.record(piece: "piece-2", passId: "proof")
        let data = try JSONEncoder().encode(memory)
        XCTAssertEqual(try JSONDecoder().decode(ActivePassMemory.self, from: data), memory)
    }

    func test_encodedShape_isHumanReadable() throws {
        // `ui-state.json` is a file a writer may open. Keyed by piece id,
        // values are bare pass id strings.
        var memory = ActivePassMemory.empty
        memory.record(piece: "piece-1", passId: "line")
        let json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(memory)) as? [String: Any]
        XCTAssertEqual(json?["active"] as? [String: String], ["piece-1": "line"])
    }

    func test_decode_ofAMalformedMap_isEmptyNotAThrow() throws {
        let json = Data(#"{"active":"nonsense"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ActivePassMemory.self, from: json), .empty)
    }

    func test_decode_ofMissingKey_isEmptyNotAThrow() throws {
        let json = Data("{}".utf8)
        XCTAssertEqual(try JSONDecoder().decode(ActivePassMemory.self, from: json), .empty)
    }

    func test_decode_toleratesGarbageValuesInsideTheMap() throws {
        // Values are already bare strings, so anything JSON can spell as a
        // string decodes — there is no enum validity to fail. This pins that
        // an arbitrary, non-`ReviewPass.presets` string is accepted (it is
        // the "stale/unknown pass id" case, handled at read time elsewhere).
        let json = Data(#"{"active":{"piece-1":"not-a-real-pass-id"}}"#.utf8)
        let memory = try JSONDecoder().decode(ActivePassMemory.self, from: json)
        XCTAssertEqual(memory.activePass(forPiece: "piece-1"), "not-a-real-pass-id")
    }
}
