import Foundation
import XCTest
@testable import MaughamCore

/// **The load path's own bursts say what they are** (signed op log P3b Task 3,
/// handoff ruling 3).
///
/// Three emissions the LOAD makes are `typingBurst`s — the two pending-recovery
/// folds and the task-anchor splice — and until this task none of them wrote a
/// `synthesisSource`, so on disk they were indistinguishable from a person
/// typing. That is what stopped P3a's grandfather (`Permit.isALoadEmission`)
/// from reaching them, and it is what the release census has to look for by
/// hand.
///
/// The label is **provenance and nothing else**: it is written prospectively so
/// a later reader can tell the load's own work from the writer's, and it moves
/// no judgment in either direction. The refuse half of that promise lives in
/// `PermitTableTests`; this file pins the wire form and the schema bump that
/// adding two cases obliges (ADR 0015).
final class SynthesisSourceTests: XCTestCase {

    // MARK: - The two new causes

    func test_theLoadsOwnBurstsHaveRawValuesOfTheirOwn() {
        XCTAssertEqual(SynthesisSource.pendingRecovery.rawValue, "pending_recovery")
        XCTAssertEqual(SynthesisSource.anchorSplice.rawValue, "anchor_splice")
        XCTAssertEqual(
            SynthesisSource(rawValue: "pending_recovery"), .pendingRecovery)
        XCTAssertEqual(SynthesisSource(rawValue: "anchor_splice"), .anchorSplice)
    }

    /// Round-trip through the wire, on an op rather than on the enum alone —
    /// the field a census reads is `provenance.synthesis_source`.
    func test_bothCausesRoundTripThroughAnOpsProvenance() throws {
        for cause in [SynthesisSource.pendingRecovery, .anchorSplice] {
            let op = Op(
                opId: "01", docId: "d", at: Date(timeIntervalSince1970: 0),
                device: "author-aaaaaaaaaaaaaaaa-bbbbbbbb", session: "s",
                kind: .typingBurst, changes: [],
                provenance: Op.Provenance(synthesisSource: cause))
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let bytes = try encoder.encode(op)
            let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
            XCTAssertTrue(
                text.contains("\"synthesis_source\":\"\(cause.rawValue)\""),
                "the snake_case raw value is what lands on disk: \(text)")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let back = try decoder.decode(Op.self, from: bytes)
            XCTAssertEqual(back.provenance?.synthesisSource, cause)
        }
    }

    /// The forward-tolerance arm is untouched: a cause this build does not know
    /// still degrades to `.unknown` rather than throwing and quarantining the
    /// whole op (ADR 0015).
    func test_anUnknownCauseStillDegradesRatherThanThrowing() {
        XCTAssertEqual(SynthesisSource(rawValue: "from_the_future"), nil)
        let decoder = JSONDecoder()
        let decoded = try? decoder.decode(
            SynthesisSource.self, from: Data("\"from_the_future\"".utf8))
        XCTAssertEqual(decoded, .unknown)
    }

    // MARK: - The bump the two cases oblige

    /// **Adding a case to a tolerant enum bumps the manifest schema**
    /// (`SynthesisSource`'s own SCHEMA CONTRACT note, ADR 0015 / audit N4).
    ///
    /// It is also this milestone's gate: a v0.40 Mac in a narrowed book applies
    /// a reviewer's refused text and re-asserts it under its own book-author
    /// key, so the first narrowing has to make that Mac refuse the project
    /// outright. `decodeGuardingSchema` is what does the refusing, and 9 is the
    /// number it refuses on.
    func test_schemaVersionIsNine() {
        XCTAssertEqual(ProjectManifest.currentSchemaVersion, 9)
    }

    func test_aSchemaNineManifestIsRefusedByABuildThatStopsAtEight() throws {
        // The shape the gate produces, read by a build whose ceiling is 8.
        let manifest = ProjectManifest(
            schemaVersion: 9, type: .novel, title: "T", author: "A",
            created: Date(timeIntervalSince1970: 0),
            modified: Date(timeIntervalSince1970: 0),
            structure: [], research: [])
        let bytes = try ProjectManifest.makeEncoder().encode(manifest)
        let decoded = try ProjectManifest.makeDecoder()
            .decode(ProjectManifest.self, from: bytes)
        XCTAssertEqual(decoded.schemaVersion, 9)
        XCTAssertGreaterThan(decoded.schemaVersion, 8,
            "an older build's decodeGuardingSchema ceiling")
        // And this build accepts it.
        XCTAssertNoThrow(try ProjectManifest.decodeGuardingSchema(bytes))
    }

    /// The other direction: a manifest at 8 still opens here. Every book that
    /// has never narrowed anybody keeps the number it has (the manifest's
    /// `schemaVersion` is DECODED, not re-stamped on save), so nothing about a
    /// one-writer book moves.
    func test_anOlderManifestStillOpens() throws {
        let manifest = ProjectManifest(
            schemaVersion: 8, type: .novel, title: "T", author: "A",
            created: Date(timeIntervalSince1970: 0),
            modified: Date(timeIntervalSince1970: 0),
            structure: [], research: [])
        let bytes = try ProjectManifest.makeEncoder().encode(manifest)
        let back = try ProjectManifest.decodeGuardingSchema(bytes)
        XCTAssertEqual(back.schemaVersion, 8)
        let again = try ProjectManifest.makeEncoder().encode(back)
        XCTAssertEqual(
            try ProjectManifest.decodeGuardingSchema(again).schemaVersion, 8,
            "an ordinary save does not raise the number \u{2014} only the gate does")
    }
}

/// **The manifest's write rule: raise-only on `schemaVersion`** (signed op log
/// P3b fix round 1, Critical 1).
///
/// The manifest is one JSON object rewritten whole from a copy each store read
/// at open, so the moment one Mac narrows a book every OTHER Mac with it open
/// is holding the old number — and the next chapter rename any of them makes
/// would write the gate away, from a machine that narrowed nobody. The fix is
/// at the door rather than at the caller, and this is the door's rule as a pure
/// value.
final class ManifestRaisingTests: XCTestCase {

    private func manifest(_ version: Int) -> ProjectManifest {
        ProjectManifest(
            schemaVersion: version, type: .novel, title: "T", author: "A",
            created: Date(timeIntervalSince1970: 0),
            modified: Date(timeIntervalSince1970: 0),
            structure: [], research: [])
    }

    private func bytes(_ version: Int) throws -> Data {
        try ProjectManifest.makeEncoder().encode(manifest(version))
    }

    // MARK: - It raises

    func test_aHigherNumberOnDiskIsCarriedIntoTheOutgoingManifest() throws {
        let raised = ProjectManifest.raising(try bytes(8), toAtLeast: 9)
        XCTAssertEqual(ProjectManifest.schemaVersion(of: raised), 9)
    }

    /// And only the number moves: the outgoing manifest's own content — the
    /// other Mac's structural edit, which is the writer's act — is carried
    /// verbatim. The door raises a version; it is not a merge.
    func test_everythingButTheNumberIsTheOutgoingManifests() throws {
        var mine = manifest(8)
        mine.title = "The other Mac's rename"
        let raised = ProjectManifest.raising(
            try ProjectManifest.makeEncoder().encode(mine), toAtLeast: 9)
        let back = try ProjectManifest.makeDecoder()
            .decode(ProjectManifest.self, from: raised)
        XCTAssertEqual(back.title, "The other Mac's rename")
        XCTAssertEqual(back.schemaVersion, 9)
    }

    // MARK: - It never lowers, and never rewrites

    func test_aLowerNumberOnDiskChangesNothing() throws {
        let outgoing = try bytes(9)
        XCTAssertEqual(ProjectManifest.raising(outgoing, toAtLeast: 8), outgoing)
        XCTAssertEqual(ProjectManifest.raising(outgoing, toAtLeast: 9), outgoing)
    }

    func test_noFileOnDiskChangesNothing() throws {
        let outgoing = try bytes(8)
        XCTAssertEqual(ProjectManifest.raising(outgoing, toAtLeast: nil), outgoing)
    }

    /// **Byte-identity on the no-op path, pinned with bytes the encoder would
    /// NOT have produced.** Every un-narrowed book's save must be exactly what
    /// it has always been, and a rule that quietly re-encoded would be
    /// invisible to a comparison against a canonical input.
    func test_theNoOpPathHandsBackTheCallersOwnBytesUntouched() throws {
        let odd = Data("""
        {"title":"T","schemaVersion":8,"author":"A","type":"novel",\
        "created":"1970-01-01T00:00:00Z","modified":"1970-01-01T00:00:00Z",\
        "structure":[],"research":[],"aFieldThisBuildDoesNotKnow":42}
        """.utf8)
        XCTAssertEqual(ProjectManifest.raising(odd, toAtLeast: 8), odd)
        XCTAssertEqual(ProjectManifest.raising(odd, toAtLeast: 7), odd)
        XCTAssertEqual(ProjectManifest.raising(odd, toAtLeast: nil), odd)
    }

    /// **It never refuses a save.** Bytes this build cannot decode go through
    /// as they are: the words are safe outranks the gate, and a save that threw
    /// because a version number would not parse would cost the writer an edit
    /// to protect a number.
    func test_bytesItCannotDecodeAreWrittenAsTheyAre() {
        let rubbish = Data("not a manifest at all".utf8)
        XCTAssertEqual(ProjectManifest.raising(rubbish, toAtLeast: 9), rubbish)
        XCTAssertNil(ProjectManifest.schemaVersion(of: rubbish))
    }

    // MARK: - Reading the one field

    func test_theNumberIsReadFromAFileThisBuildCannotFullyDecode() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("raising-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        // A later build's manifest: the number is legible, the rest is not
        // this build's to understand.
        try Data(#"{"schemaVersion":99,"somethingNew":{"a":1}}"#.utf8).write(to: tmp)
        XCTAssertEqual(ProjectManifest.schemaVersion(ofFileAt: tmp), 99)
        XCTAssertNil(try? ProjectManifest.makeDecoder()
            .decode(ProjectManifest.self, from: Data(contentsOf: tmp)),
            "the whole manifest genuinely does not decode here")
    }

    func test_aFileThatIsNotThereHasNoNumber() {
        XCTAssertNil(ProjectManifest.schemaVersion(
            ofFileAt: FileManager.default.temporaryDirectory
                .appendingPathComponent("no-such-\(UUID().uuidString).json")))
    }
}
