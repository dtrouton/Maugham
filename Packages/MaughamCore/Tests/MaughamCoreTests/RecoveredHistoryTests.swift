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

        let report = RecoveredHistory.report(
            currentOps: currentOps, returnedOps: returnedOps, mergeHappened: true)

        XCTAssertEqual(report.orphans, [
            RecoveredHistoryReport.Orphan(paragraphId: "bbbb", text: "returned-b")
        ])
        XCTAssertFalse(report.redundant)
    }

    // MARK: - The no-merge branch (fix round: whole-branch review C1)

    /// **The reproduction shape.** The archive holds the WINNING keyframe, and
    /// the destination has been refilled by sync with a divergent, older
    /// generation — so `attemptReturn` moves nothing and the writer's draft
    /// derives from the current log ALONE. Computed against the hypothetical
    /// merge (the shipped bug) both archive paragraphs survive and the report
    /// says nothing was missing, while they live in no readable log at all.
    func test_noMerge_orphansAreMeasuredAgainstTheCurrentDerivationAlone() {
        // Archive: paragraphs abcd/efgh, keyframe [abcd, efgh], HIGH opIds.
        let returnedOps = [
            makeOp(
                opId: "aaaa", device: "p",
                changes: [change("abcd", "archive-1"), change("efgh", "archive-2")],
                sequence: ["abcd", "efgh"]),
            makeOp(
                opId: "bbbb", device: "p",
                changes: [change("efgh", "archive-2 revised")],
                sequence: ["abcd", "efgh"]),
        ]
        // The recreated device file: an older generation entirely, whose
        // keyframe LOSES the merge.
        let currentOps = [
            makeOp(
                opId: "0001", device: "p",
                changes: [change("jkmn", "recreated")], sequence: ["jkmn"]),
        ]

        // What the merge WOULD have kept — the old computation's answer.
        let hypothetical = RecoveredHistory.report(
            currentOps: currentOps, returnedOps: returnedOps, mergeHappened: true)
        XCTAssertEqual(hypothetical.orphans, [],
                       "the archive's keyframe wins a merge — which is exactly why "
                       + "measuring the no-move case against it was a lie")

        let report = RecoveredHistory.report(
            currentOps: currentOps, returnedOps: returnedOps, mergeHappened: false)

        XCTAssertEqual(report.orphans.map(\.paragraphId), ["abcd", "efgh"],
                       "nothing moved, so both archive paragraphs are absent from "
                       + "the draft the writer will see")
        XCTAssertEqual(report.orphans.map(\.text), ["archive-1", "archive-2 revised"])
        XCTAssertFalse(report.redundant,
                       "the current log holds neither archive op")
    }

    /// The other direction, and the one that must NOT become noise: when the
    /// archive is a strict subset of the current log, no move happens AND
    /// nothing is missing — the writer is told the truth in both branches.
    func test_noMerge_strictSubsetArchiveStillYieldsZeroOrphans() {
        let opA = makeOp(
            opId: "01A0000000", device: "p",
            changes: [change("aaaa", "text-a")], sequence: ["aaaa"])
        let opB = makeOp(
            opId: "01B0000000", device: "m",
            changes: [change("bbbb", "text-b")], sequence: ["aaaa", "bbbb"])

        let report = RecoveredHistory.report(
            currentOps: [opA, opB], returnedOps: [opA], mergeHappened: false)

        XCTAssertEqual(report.orphans, [],
                       "everything the archive carries is already in the live log")
        XCTAssertTrue(report.redundant)
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

        let report = RecoveredHistory.report(
            currentOps: currentOps, returnedOps: returnedOps, mergeHappened: true)

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

        let report = RecoveredHistory.report(
            currentOps: currentOps, returnedOps: returnedOps, mergeHappened: true)

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
            let allOps = randomOps(pool: paragraphPool, using: &rng)

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

            let report = RecoveredHistory.report(
                currentOps: currentOps, returnedOps: returnedOps, mergeHappened: true)

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

    /// **THE TOTALITY PROPERTY, no-merge branch** — the companion the C1 fix
    /// needs, and deliberately NOT a partition: `current` and `returned`
    /// OVERLAP on opIds here, which is the real shape when sync recreates a
    /// device file from a generation the archive also holds. Nothing moves in
    /// this branch, so the oracle is `derive(current)` alone: every paragraph
    /// in the returned file's own derivation is EITHER in the current
    /// derivation OR in the orphan list, never both, never neither.
    func test_property_noMerge_everyReturnedParagraphIsAccountedForAgainstCurrent() {
        var rng = SystemRandomNumberGenerator()
        let paragraphPool = ["aaaa", "bbbb", "cccc", "dddd", "eeee", "ffff"]

        for trial in 0..<200 {
            let allOps = randomOps(pool: paragraphPool, using: &rng)

            // An OVERLAPPING split: an op can land on both sides (sync
            // delivered a generation the archive also carries), on one, or —
            // for `current` — on neither, so a wholly divergent archive is
            // reachable too.
            var currentOps: [Op] = []
            var returnedOps: [Op] = []
            for op in allOps {
                switch Int.random(in: 0..<4, using: &rng) {
                case 0: currentOps.append(op)
                case 1: returnedOps.append(op)
                case 2:
                    currentOps.append(op)
                    returnedOps.append(op)
                default: break
                }
            }

            let report = RecoveredHistory.report(
                currentOps: currentOps, returnedOps: returnedOps, mergeHappened: false)

            let currentState = Deriver.deriveWithSequenceFallback(ops: currentOps)
            let returnedState = Deriver.deriveWithSequenceFallback(ops: returnedOps)
            let currentIds = Set(currentState.sequence)
            let orphanIds = Set(report.orphans.map(\.paragraphId))

            for paragraphId in returnedState.sequence {
                let inCurrent = currentIds.contains(paragraphId)
                let inOrphans = orphanIds.contains(paragraphId)
                if inCurrent == inOrphans {
                    print("--- FAILURE trial \(trial): paragraph \(paragraphId) inCurrent=\(inCurrent) inOrphans=\(inOrphans) ---")
                    print("currentOps: \(currentOps)")
                    print("returnedOps: \(returnedOps)")
                    XCTFail(
                        "trial \(trial): with no merge, paragraph \(paragraphId) must be "
                        + "in exactly one of the current derivation / the orphan list")
                }
            }
        }
    }

    /// The two property trials' shared op generator: 2–30 ops over two
    /// interleaved device streams, with occasional sequence keyframes.
    /// Lexically-ordered opIds (a zero-padded counter) so op order is
    /// deterministic and encodes intended time order, mirroring a ULID's
    /// monotonic-by-construction property.
    private func randomOps(
        pool paragraphPool: [String], using rng: inout SystemRandomNumberGenerator
    ) -> [Op] {
        var allOps: [Op] = []
        let opCount = Int.random(in: 2...30, using: &rng)
        for i in 0..<opCount {
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
        return allOps
    }

    // MARK: - aggregate (fix round: I1 — `redundant` gets a production reader)

    private func report(orphanIds: [String], redundant: Bool) -> RecoveredHistoryReport {
        RecoveredHistoryReport(
            orphans: orphanIds.map { .init(paragraphId: $0, text: "text-\($0)") },
            redundant: redundant)
    }

    func test_aggregate_concatenatesOrphansInSweepOrder() {
        let combined = RecoveredHistoryReport.aggregate([
            report(orphanIds: ["aaaa"], redundant: false),
            report(orphanIds: ["bbbb", "cccc"], redundant: false),
        ])
        XCTAssertEqual(combined.orphans.map(\.paragraphId), ["aaaa", "bbbb", "cccc"])
    }

    func test_aggregate_isRedundantOnlyWhenEveryReportWas() {
        XCTAssertTrue(RecoveredHistoryReport.aggregate([
            report(orphanIds: [], redundant: true),
            report(orphanIds: [], redundant: true),
        ]).redundant)
        XCTAssertFalse(RecoveredHistoryReport.aggregate([
            report(orphanIds: [], redundant: true),
            report(orphanIds: ["aaaa"], redundant: false),
        ]).redundant,
            "one return carrying history the live log lacks makes the whole sweep "
            + "non-redundant — that is the lossy case the pane must not call clean")
    }

    func test_aggregate_ofNothingIsNotRedundant() {
        let empty = RecoveredHistoryReport.aggregate([])
        XCTAssertEqual(empty.orphans, [])
        XCTAssertFalse(empty.redundant,
                       "nothing was delivered, so there is nothing for sync to have "
                       + "already delivered — vacuous truth would read as 'all clean'")
    }
}
