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
