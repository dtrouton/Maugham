import XCTest
@testable import MaughamCore

/// `RecoveredHistory.report` is the honest half of Plan B's merge: a pure
/// computation deciding which paragraphs a recovered (previously-unreadable)
/// history file carries that the *current* merged draft does not. Tripwire 8:
/// paragraph id literals come from the valid 4-char alphabet
/// `[0-9a-hjkmnp-tv-z]`.
final class RecoveredHistoryTests: XCTestCase {

    private func makeOp(
        opId: String, device: String = "m", changes: [Op.ParagraphChange],
        sequence: [String]? = nil
    ) -> Op {
        Op(opId: opId, docId: "doc-1", at: Date(timeIntervalSince1970: 0),
           device: device, session: "s", kind: .typingBurst,
           changes: changes, sequence: sequence)
    }

    private func change(_ paragraphId: String, _ text: String) -> Op.ParagraphChange {
        .init(paragraphId: paragraphId, prior: nil, next: text)
    }

    /// Spec §5 rule 3: a paragraph superseded by the writer's newer keyframes
    /// is an orphan; one that survives the merge is not.
    func test_supersededParagraphIsAnOrphan_survivorIsNot() {
        // Returned file: paragraphs a,b with sequence [a,b].
        let returnedOps = [
            makeOp(
                opId: "01A0000000", device: "p",
                changes: [change("aaaa", "returned-a"), change("bbbb", "returned-b")],
                sequence: ["aaaa", "bbbb"])
        ]
        // Current: a NEWER keyframe (higher opId) that drops b and rewrites a.
        let currentOps = [
            makeOp(
                opId: "01B0000000", device: "m",
                changes: [change("aaaa", "current-a")],
                sequence: ["aaaa"])
        ]

        let report = RecoveredHistory.report(currentOps: currentOps, returnedOps: returnedOps)

        XCTAssertEqual(report.orphans, [
            RecoveredHistoryReport.Orphan(paragraphId: "bbbb", text: "returned-b")
        ])
        XCTAssertFalse(report.redundant)
    }

    func test_fullyRedundantReturn_reportsRedundant_noOrphans() {
        let opA = makeOp(
            opId: "01A0000000", device: "m",
            changes: [change("aaaa", "text-a")], sequence: ["aaaa"])
        let opB = makeOp(
            opId: "01B0000000", device: "m",
            changes: [change("bbbb", "text-b")], sequence: ["aaaa", "bbbb"])
        let currentOps = [opA, opB]
        let returnedOps = [opA] // returnedOps ⊂ currentOps by opId

        let report = RecoveredHistory.report(currentOps: currentOps, returnedOps: returnedOps)

        XCTAssertTrue(report.redundant)
        XCTAssertEqual(report.orphans, [])
    }

    func test_returnedOnlyOps_mergeIn_lastWriterWinsPerParagraph() {
        // Returned file holds an OLDER edit to paragraph a.
        let returnedOps = [
            makeOp(
                opId: "01A0000000", device: "p",
                changes: [change("aaaa", "old-a")], sequence: ["aaaa"])
        ]
        // Current has a NEWER edit to the same paragraph.
        let currentOps = [
            makeOp(
                opId: "01B0000000", device: "m",
                changes: [change("aaaa", "new-a")], sequence: ["aaaa"])
        ]

        let report = RecoveredHistory.report(currentOps: currentOps, returnedOps: returnedOps)

        // a is not an orphan — the merge owns it (last-writer-wins is
        // current's job via Deriver, not this report's).
        XCTAssertFalse(report.orphans.map(\.paragraphId).contains("aaaa"))
        XCTAssertFalse(report.redundant)
    }

    /// THE TOTALITY PROPERTY (global constraint): for randomized op sets,
    /// every paragraph in derive(returnedOps).sequence is EITHER in
    /// derive(merged).sequence OR in the orphan list — never lost, never both.
    func test_property_everyReturnedParagraphIsAccountedFor() {
        var rng = SystemRandomNumberGenerator()
        let paragraphPool = ["aaaa", "bbbb", "cccc", "dddd", "eeee", "ffff"]

        for trial in 0..<200 {
            var allOps: [Op] = []
            let opCount = Int.random(in: 2...30, using: &rng)
            for i in 0..<opCount {
                // Lexically-ordered opId (zero-padded counter) so op order is
                // deterministic and encodes intended time order, mirroring a
                // ULID's monotonic-by-construction property, across two
                // interleaved device streams.
                let opId = String(format: "OP%010d", i)
                let device = Bool.random(using: &rng) ? "device-A" : "device-B"
                let paragraphId = paragraphPool.randomElement(using: &rng)!
                var sequence: [String]?
                // Occasional sequence keyframe: a shuffled subset of the pool.
                if Int.random(in: 0..<4, using: &rng) == 0 {
                    let count = Int.random(in: 1...paragraphPool.count, using: &rng)
                    sequence = Array(paragraphPool.shuffled(using: &rng).prefix(count))
                } else {
                    sequence = nil
                }
                allOps.append(makeOp(
                    opId: opId, device: device,
                    changes: [change(paragraphId, "text-\(i)")],
                    sequence: sequence))
            }

            // Split into current/returned as a true partition (no opId lands
            // on both sides) — sync merges the two logs, it doesn't duplicate
            // an op into both.
            var currentOps: [Op] = []
            var returnedOps: [Op] = []
            for op in allOps {
                if Bool.random(using: &rng) {
                    currentOps.append(op)
                } else {
                    returnedOps.append(op)
                }
            }

            let currentIds = Set(currentOps.map(\.opId))
            let returnedIds = Set(returnedOps.map(\.opId))
            XCTAssertTrue(
                currentIds.isDisjoint(with: returnedIds),
                "trial \(trial): partition must not duplicate an opId across both sides")

            let report = RecoveredHistory.report(currentOps: currentOps, returnedOps: returnedOps)

            // Independent oracle: since current/returned are a strict
            // opId partition (asserted above), plain concatenation has no
            // duplicate opId and is equivalent to a deduped union for
            // Deriver's purposes.
            let mergedState = Deriver.deriveWithSequenceFallback(ops: currentOps + returnedOps)
            let returnedState = Deriver.deriveWithSequenceFallback(ops: returnedOps)
            let mergedIds = Set(mergedState.sequence)
            let orphanIds = Set(report.orphans.map(\.paragraphId))

            for paragraphId in returnedState.sequence {
                let inMerged = mergedIds.contains(paragraphId)
                let inOrphans = orphanIds.contains(paragraphId)
                if inMerged == inOrphans {
                    print("--- FAILURE trial \(trial): paragraph \(paragraphId) inMerged=\(inMerged) inOrphans=\(inOrphans) ---")
                    print("currentOps: \(currentOps)")
                    print("returnedOps: \(returnedOps)")
                    XCTFail(
                        "trial \(trial): paragraph \(paragraphId) must be in exactly one of merged/orphans")
                }
            }
        }
    }
}
