import XCTest
@testable import MaughamCore

/// Contract tests for `PassState` and `StructureItem.passStates` (M3 P1, Task 2).
///
/// The two things worth breaking a build over: a manifest written before this
/// milestone (no `passStates` key on any item) still decodes, and a state
/// string written by a NEWER build survives an older build's decode → re-encode
/// with its original spelling intact — the `ResearchRole` lossless shape.
final class PassStateTests: XCTestCase {

    // MARK: - Control

    /// CONTROL: asserts a fact that holds independently of anything this task
    /// implements, so a green run of this file cannot mean "the file never
    /// compiled into the target".
    func test_control_aStructureItemStillDecodesFromItsRequiredFieldsAlone() throws {
        let json = #"{"id":"x","title":"X","type":"document","path":"x.md"}"#
        let item = try JSONDecoder().decode(StructureItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.id, "x")
        XCTAssertNil(item.status)
    }

    // MARK: - The known cases

    func test_knownCasesHaveTheirStableOnDiskSpellings() {
        XCTAssertEqual(PassState.inProgress.rawValue, "in_progress")
        XCTAssertEqual(PassState.done.rawValue, "done")
        XCTAssertEqual(PassState.skipped.rawValue, "skipped")
    }

    func test_knownCasesRoundTripThroughJSON() throws {
        for state in [PassState.inProgress, .done, .skipped] {
            let data = try JSONEncoder().encode(state)
            XCTAssertEqual(try JSONDecoder().decode(PassState.self, from: data), state)
        }
    }

    func test_aKnownCaseEncodesAsItsBareString() throws {
        let wire = String(decoding: try JSONEncoder().encode(PassState.inProgress), as: UTF8.self)
        XCTAssertEqual(wire, #""in_progress""#)
    }

    // MARK: - The lossless unknown

    func test_anUnrecognizedStateDecodesToUnknownPreservingItsRaw() throws {
        let state = try JSONDecoder().decode(PassState.self, from: Data(#""blocked""#.utf8))
        XCTAssertEqual(state, .unknown("blocked"))
    }

    func test_unknownEncodesAsItsPreservedRawNotTheLiteralUnknown() throws {
        let wire = String(decoding: try JSONEncoder().encode(PassState.unknown("blocked")),
                          as: UTF8.self)
        XCTAssertEqual(wire, #""blocked""#)
    }

    /// THE PIN. The manifest is rewritten whole on every structural edit, so an
    /// older build that opens a project whose pieces carry a newer build's pass
    /// state and then merely renames a chapter re-encodes every item. A lossy
    /// sentinel would silently rewrite the writer's recorded state to the
    /// literal "unknown" — losing work nobody asked it to touch.
    func test_anUnknownStateSurvivesAnOlderBuildsDecodeThenReEncode() throws {
        let json = #"""
        {"id":"p1","title":"Chapter One","type":"document","path":"one.md",
         "passStates":{"structural":"done","sensitivity":"awaiting_reader"}}
        """#
        let item = try JSONDecoder().decode(StructureItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.passStates?["sensitivity"], .unknown("awaiting_reader"))

        let reEncoded = try JSONEncoder().encode(item)
        let back = try JSONDecoder().decode(StructureItem.self, from: reEncoded)
        XCTAssertEqual(back.passStates?["sensitivity"], .unknown("awaiting_reader"),
            "a newer build's state must round-trip losslessly, not collapse")
        XCTAssertEqual(back.passStates?["structural"], .done)

        let wire = String(decoding: reEncoded, as: UTF8.self)
        XCTAssertTrue(wire.contains(#""awaiting_reader""#),
            "the re-encoded item must carry the original raw state string")
        XCTAssertFalse(wire.contains(#""unknown""#),
            "the re-encoded item must NOT clobber a newer state to literal \"unknown\"")
    }

    // MARK: - The optional field

    /// A manifest written before this milestone has no `passStates` key on any
    /// item. The field is OPTIONAL precisely so the synthesized decoder does not
    /// throw `keyNotFound` — which, the whole manifest being one JSON object,
    /// would make every existing project unopenable.
    func test_anItemWithNoPassStatesKeyDecodesCleanWithNil() throws {
        let json = #"{"id":"x","title":"X","type":"document","path":"x.md"}"#
        let item = try JSONDecoder().decode(StructureItem.self, from: Data(json.utf8))
        XCTAssertNil(item.passStates)
    }

    func test_theMemberwiseInitDefaultsPassStatesToNil() {
        let item = StructureItem(id: "x", title: "X", type: .document, path: "x.md")
        XCTAssertNil(item.passStates)
    }

    func test_passStatesRoundTripsKeyedByPassId() throws {
        let item = StructureItem(
            id: "p1", title: "Chapter One", type: .document, path: "one.md",
            passStates: ["structural": .done, "line": .inProgress, "proof": .skipped])
        let back = try JSONDecoder().decode(
            StructureItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(back.passStates?["structural"], .done)
        XCTAssertEqual(back.passStates?["line"], .inProgress)
        XCTAssertEqual(back.passStates?["proof"], .skipped)
        XCTAssertEqual(back.passStates?.count, 3)
    }

    /// A pass with no entry is untouched — the absent key and the absent
    /// dictionary say the same thing, so no reader needs a fourth case for
    /// "not started".
    func test_aPassWithNoEntryReadsAsUntouched() {
        let item = StructureItem(id: "p1", title: "One", type: .document, path: "one.md",
                                 passStates: ["structural": .done])
        XCTAssertNil(item.passStates?["line"])
    }

    /// The states hang off the pass ID, not its name — so Task 9's rename of a
    /// pass leaves every piece's recorded state exactly where it was.
    func test_stateSurvivesAPassRenameBecauseItIsKeyedOnTheId() {
        var pass = ReviewPass(id: "structural", name: "Structural")
        let item = StructureItem(id: "p1", title: "One", type: .document, path: "one.md",
                                 passStates: [pass.id: .done])
        pass.name = "Shape"
        XCTAssertEqual(item.passStates?[pass.id], .done)
    }

    /// Children carry their own states through the same synthesized decoder.
    func test_aNestedChildCarriesItsOwnStates() throws {
        let json = #"""
        {"id":"g","title":"Part One","type":"group","children":[
          {"id":"c","title":"One","type":"document","path":"one.md",
           "passStates":{"line":"in_progress"}}]}
        """#
        let item = try JSONDecoder().decode(StructureItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.children?.first?.passStates?["line"], .inProgress)
        XCTAssertNil(item.passStates)
    }
}
