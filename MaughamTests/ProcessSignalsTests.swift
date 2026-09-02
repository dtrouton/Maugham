// MaughamTests/ProcessSignalsTests.swift
import XCTest
import MaughamCore
@testable import Maugham

/// `ProcessSignals` is Maugham's own observation of the writer's process —
/// where the frontier is, what is being rewritten and how often, how long
/// since the frontier moved, how long they were away — computed off one
/// document's op log and a live `sequence` and nothing else (spec
/// `2026-08-29-the-editorial-letter-design.md` §5). Every number below is
/// deterministic: the value takes `now` rather than reading a clock, reads no
/// store, and derives its sessions from the ops themselves.
///
/// The fixture is `DeltaBuilderTests`' `makeOp` shape with `at` and `session`
/// made explicit, because those two fields are the whole session derivation.
final class ProcessSignalsTests: XCTestCase {

    // MARK: - Fixture

    /// Epoch-anchored so a day boundary never depends on when the suite runs.
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func minutes(_ value: Double) -> Date {
        base.addingTimeInterval(value * 60)
    }

    private func days(_ value: Double) -> Date {
        base.addingTimeInterval(value * 86_400)
    }

    private func makeOp(
        opId: String,
        kind: OpKind = .typingBurst,
        at: Date,
        session: String = "s1",
        changes: [Op.ParagraphChange] = [],
        device: String = "macA"
    ) -> Op {
        Op(opId: opId, docId: "doc-1", at: at, device: device,
           session: session, kind: kind, changes: changes, sequence: nil)
    }

    private func mint(_ id: String, _ text: String = "New.") -> Op.ParagraphChange {
        .init(paragraphId: id, prior: nil, next: text)
    }

    private func edit(_ id: String, _ text: String = "Revised.") -> Op.ParagraphChange {
        .init(paragraphId: id, prior: "Was.", next: text)
    }

    private func delete(_ id: String) -> Op.ParagraphChange {
        .init(paragraphId: id, prior: "Was.", next: "")
    }

    // MARK: - Nothing to observe

    /// A document with no ops is not an error and not a zero — it is a value
    /// with nothing in it, and `noteworthy` is empty so the briefing writes no
    /// process section at all.
    func test_anEmptyLogObservesNothing() {
        let signals = ProcessSignals(ops: [], sequence: [], now: base)

        XCTAssertTrue(signals.sessions.isEmpty)
        XCTAssertNil(signals.frontier)
        XCTAssertNil(signals.sessionsSinceFrontierMoved)
        XCTAssertTrue(signals.hotspots.isEmpty)
        XCTAssertNil(signals.daysAway)
        XCTAssertEqual(signals.noteworthy, [])
    }

    // MARK: - Sessions

    /// `Op.session` is process-lifetime on the Mac (`EditorHost.sessionId` is a
    /// UUID minted once per launch), so a change of it is unambiguously a new
    /// sitting even with no time between the two ops.
    func test_aChangeOfOpSessionSplitsASessionAtZeroGap() {
        let ops = [
            makeOp(opId: "op01", at: minutes(0), session: "s1", changes: [mint("a1b2")]),
            makeOp(opId: "op02", at: minutes(0), session: "s2", changes: [mint("c3d4")]),
        ]

        let signals = ProcessSignals(ops: ops, sequence: ["a1b2", "c3d4"], now: minutes(1))

        XCTAssertEqual(signals.sessions.count, 2)
        XCTAssertEqual(signals.sessions.map(\.index), [0, 1])
        XCTAssertEqual(signals.sessions.map(\.opIds), [["op01"], ["op02"]])
    }

    /// The other half of constraint 21: one launch that spans a week is not one
    /// session, so a gap of at least `SessionTracker.idleThreshold` splits even
    /// when `Op.session` never changes.
    ///
    /// **Disable experiment.** With the gap clause removed from the boundary
    /// test in `ProcessSignals.sessions(in:)` (leaving
    /// `op.session != previous.session` alone), this test failed at the first
    /// assertion:
    /// `XCTAssertEqual failed: ("1") is not equal to ("2") - a 31-minute gap
    /// must end the session`. The 29-minute control below stayed green, which
    /// is what says the split is the threshold's doing and not an accident of
    /// the fixture.
    func test_aGapPastTheIdleThresholdSplitsWithinOneOpSession() {
        let ops = [
            makeOp(opId: "op01", at: minutes(0), changes: [mint("a1b2")]),
            makeOp(opId: "op02", at: minutes(31), changes: [mint("c3d4")]),
        ]

        let signals = ProcessSignals(ops: ops, sequence: ["a1b2", "c3d4"], now: minutes(32))

        XCTAssertEqual(signals.sessions.count, 2,
                       "a 31-minute gap must end the session")
        XCTAssertEqual(signals.sessions.first?.startedAt, minutes(0))
        XCTAssertEqual(signals.sessions.first?.endedAt, minutes(0))
        XCTAssertEqual(signals.sessions.last?.startedAt, minutes(31))
    }

    /// The control for the split above: a gap UNDER the threshold is one
    /// sitting with a pause in it, which is what a writer thinking for half an
    /// hour actually is.
    func test_aGapUnderTheIdleThresholdIsOneSession() {
        let ops = [
            makeOp(opId: "op01", at: minutes(0), changes: [mint("a1b2")]),
            makeOp(opId: "op02", at: minutes(29), changes: [mint("c3d4")]),
        ]

        let signals = ProcessSignals(ops: ops, sequence: ["a1b2", "c3d4"], now: minutes(30))

        XCTAssertEqual(signals.sessions.count, 1)
        XCTAssertEqual(signals.sessions.first?.opIds, ["op01", "op02"])
        XCTAssertEqual(signals.sessions.first?.startedAt, minutes(0))
        XCTAssertEqual(signals.sessions.first?.endedAt, minutes(29))
    }

    /// Constraint 22's first half: only ops that reach the manuscript count, and
    /// the question is asked of `Deriver.appliesToManuscript` rather than a
    /// local re-switch. A checkpoint two hours later is not a second sitting.
    ///
    /// **Disable experiment.** With the `Deriver.appliesToManuscript` filter
    /// removed from `ProcessSignals.init`, this test failed at its first
    /// assertion: `XCTAssertEqual failed: ("2") is not equal to ("1") - a
    /// checkpoint op is not a writing session`.
    func test_onlyManuscriptOpsFormSessions() {
        let ops = [
            makeOp(opId: "op01", at: minutes(0), changes: [mint("a1b2")]),
            makeOp(opId: "op02", kind: .checkpoint, at: minutes(120), changes: []),
        ]

        let signals = ProcessSignals(ops: ops, sequence: ["a1b2"], now: minutes(121))

        XCTAssertEqual(signals.sessions.count, 1,
                       "a checkpoint op is not a writing session")
        XCTAssertEqual(signals.sessions.first?.opIds, ["op01"])
    }

    /// Ops arrive in whatever order a merge produced them; the value sorts by
    /// `opId` the way `DeltaBuilder.delta` does before reading anything, so the
    /// answer is a function of the set and not of the file.
    func test_opsAreReadInOpIdOrderWhateverOrderTheyArriveIn() {
        let later = makeOp(opId: "op02", at: minutes(31), changes: [mint("c3d4")])
        let earlier = makeOp(opId: "op01", at: minutes(0), changes: [mint("a1b2")])

        let signals = ProcessSignals(ops: [later, earlier],
                                     sequence: ["a1b2", "c3d4"], now: minutes(32))

        XCTAssertEqual(signals.sessions.map(\.opIds), [["op01"], ["op02"]])
        XCTAssertEqual(signals.frontier?.paragraphId, "c3d4")
    }

    // MARK: - The frontier

    /// The frontier is where new prose is being ADDED, which is the latest mint
    /// in op order — not the mint furthest down the document. A writer who goes
    /// back and opens a new paragraph in the middle of chapter two has moved
    /// their frontier there, however much text stands below it.
    func test_theFrontierIsTheLatestMintAndNotTheFurthestDownTheDocument() {
        let ops = [
            makeOp(opId: "op01", at: minutes(0),
                   changes: [mint("a1b2"), mint("c3d4"), mint("e5f6")]),
            makeOp(opId: "op02", at: minutes(60), changes: [mint("g7h8")]),
        ]

        let signals = ProcessSignals(
            ops: ops, sequence: ["a1b2", "g7h8", "c3d4", "e5f6"], now: minutes(61))

        XCTAssertEqual(signals.frontier?.paragraphId, "g7h8")
        XCTAssertEqual(signals.frontier?.position, 1)
        XCTAssertEqual(signals.frontier?.sessionIndex, 1)
        XCTAssertEqual(signals.frontier?.at, minutes(60))
    }

    /// Constraint 22's second half: a bootstrap mints ids for text that already
    /// existed, so importing a finished chapter is not drafting it. A log with
    /// nothing but a bootstrap has a session and no frontier — and `nil` there
    /// is a legitimate answer, not a missing one.
    ///
    /// **Disable experiment.** With the `where op.kind != .bootstrap` clause
    /// dropped from the frontier search, this test failed at the first
    /// assertion: `XCTAssertNil failed: "Frontier(paragraphId: "c3d4",
    /// position: 1, sessionIndex: 0, at: 2023-11-14 22:13:20 +0000)" - a
    /// bootstrap mints ids for text that already existed`.
    func test_aBootstrapOnlyLogHasNoFrontier() {
        let ops = [
            makeOp(opId: "op01", kind: .bootstrap, at: minutes(0),
                   changes: [mint("a1b2"), mint("c3d4")]),
        ]

        let signals = ProcessSignals(ops: ops, sequence: ["a1b2", "c3d4"], now: minutes(1))

        XCTAssertNil(signals.frontier,
                     "a bootstrap mints ids for text that already existed")
        XCTAssertEqual(signals.sessions.count, 1, "it is still a session")
        XCTAssertNil(signals.sessionsSinceFrontierMoved)
    }

    /// A paragraph typed and then cut is not where the writing stands. The
    /// frontier walks back to the latest mint that is still in `sequence`.
    ///
    /// **Disable experiment.** With the frontier's position lookup given a
    /// default (`position[change.paragraphId] ?? 0`) so a cut paragraph still
    /// resolves, this test failed at the first assertion:
    /// `XCTAssertEqual failed: ("Optional("c3d4")") is not equal to
    /// ("Optional("a1b2")") - a paragraph minted and then cut is not the
    /// frontier`.
    func test_aMintedThenDeletedParagraphDoesNotHoldTheFrontier() {
        let ops = [
            makeOp(opId: "op01", at: minutes(0), changes: [mint("a1b2")]),
            makeOp(opId: "op02", at: minutes(60), changes: [mint("c3d4")]),
            makeOp(opId: "op03", at: minutes(61), changes: [delete("c3d4")]),
        ]

        let signals = ProcessSignals(ops: ops, sequence: ["a1b2"], now: minutes(62))

        XCTAssertEqual(signals.frontier?.paragraphId, "a1b2",
                       "a paragraph minted and then cut is not the frontier")
        XCTAssertEqual(signals.frontier?.position, 0)
        XCTAssertEqual(signals.frontier?.sessionIndex, 0)
    }

    // MARK: - Forward motion

    /// Sessions AFTER the one that minted the frontier — the number the
    /// briefing turns into "the frontier hasn't moved in three sessions".
    func test_sessionsSinceFrontierMovedCountsTheSessionsAfterIt() {
        let ops = [
            makeOp(opId: "op01", at: days(0), changes: [mint("a1b2")]),
            makeOp(opId: "op02", at: days(1), changes: [edit("a1b2")]),
            makeOp(opId: "op03", at: days(2), changes: [edit("a1b2")]),
            makeOp(opId: "op04", at: days(3), changes: [edit("a1b2")]),
        ]

        let signals = ProcessSignals(ops: ops, sequence: ["a1b2"], now: days(3))

        XCTAssertEqual(signals.sessions.count, 4)
        XCTAssertEqual(signals.frontier?.sessionIndex, 0)
        XCTAssertEqual(signals.sessionsSinceFrontierMoved, 3)
    }

    /// Zero, not `nil`, when the frontier moved in the latest session — the
    /// writer is adding prose right now.
    func test_sessionsSinceFrontierMovedIsZeroWhenItMovedInTheLatestSession() {
        let ops = [
            makeOp(opId: "op01", at: days(0), changes: [mint("a1b2")]),
            makeOp(opId: "op02", at: days(1), changes: [mint("c3d4")]),
        ]

        let signals = ProcessSignals(ops: ops, sequence: ["a1b2", "c3d4"], now: days(1))

        XCTAssertEqual(signals.sessionsSinceFrontierMoved, 0)
    }

    // MARK: - Churn

    /// Churn is REWRITING: an op carrying a change with a prior and a non-empty
    /// next. A mint is not a rewrite (the paragraph is being written for the
    /// first time) and neither is a cut. Top three by count, ties by position,
    /// and a paragraph nobody touched never appears.
    ///
    /// **Disable experiment.** With the edit predicate widened to every change
    /// (dropping `prior != nil && next != ""`), this test failed at the first
    /// assertion, the bootstrap's mints and the cut having been counted:
    /// `XCTAssertEqual failed: ("["a1b2@0×4", "c3d4@1×4", "e5f6@2×3"]") is not
    /// equal to ("["a1b2@0×3", "c3d4@1×3", "e5f6@2×2"]")`.
    func test_hotspotsCountRewritesAndNotMintsOrCuts() {
        var ops = [
            makeOp(opId: "op01", kind: .bootstrap, at: minutes(0), changes: [
                mint("a1b2"), mint("c3d4"), mint("e5f6"), mint("g7h8"), mint("j9k2"),
                mint("m3n4"),
            ]),
        ]
        // Three rewrites of a1b2, three of c3d4, two of e5f6, one of g7h8,
        // none of j9k2 — plus a cut of m3n4, which leaves it out of `sequence`.
        let rewrites: [(String, String)] = [
            ("op02", "a1b2"), ("op03", "a1b2"), ("op04", "a1b2"),
            ("op05", "c3d4"), ("op06", "c3d4"), ("op07", "c3d4"),
            ("op08", "e5f6"), ("op09", "e5f6"),
            ("op10", "g7h8"),
        ]
        for (index, entry) in rewrites.enumerated() {
            ops.append(makeOp(opId: entry.0, at: minutes(Double(index) + 1),
                              changes: [edit(entry.1)]))
        }
        ops.append(makeOp(opId: "op11", at: minutes(11), changes: [delete("m3n4")]))

        let signals = ProcessSignals(
            ops: ops, sequence: ["a1b2", "c3d4", "e5f6", "g7h8", "j9k2"],
            now: minutes(12))

        XCTAssertEqual(Self.describe(signals.hotspots),
                       ["a1b2@0×3", "c3d4@1×3", "e5f6@2×2"])
    }

    /// Two changes to one paragraph inside a single op are one rewrite: the op
    /// is the unit of the writer's act, not the change record.
    func test_aParagraphIsCountedOnceForTheOpThatRewroteIt() {
        let ops = [
            makeOp(opId: "op01", at: minutes(0),
                   changes: [edit("a1b2", "One."), edit("a1b2", "Two.")]),
        ]

        let signals = ProcessSignals(ops: ops, sequence: ["a1b2"], now: minutes(1))

        XCTAssertEqual(Self.describe(signals.hotspots), ["a1b2@0×1"])
    }

    /// A paragraph wrestled with and then cut is not a hotspot: it is not in
    /// the document any more, so there is nothing to jump to and nothing for
    /// the letter to say about it.
    ///
    /// **Disable experiment.** With the `compactMap`'s position lookup given a
    /// default (`position[paragraphId] ?? 0`) so a cut paragraph keeps its
    /// count, this test failed at its assertion:
    /// `XCTAssertEqual failed: ("["c3d4@0×2", "a1b2@0×1"]") is not equal to
    /// ("["a1b2@0×1"]") - a paragraph rewritten and then cut is gone`.
    func test_aParagraphRewrittenThenCutIsNotAHotspot() {
        let ops = [
            makeOp(opId: "op01", at: minutes(0),
                   changes: [mint("a1b2"), mint("c3d4")]),
            makeOp(opId: "op02", at: minutes(1), changes: [edit("c3d4")]),
            makeOp(opId: "op03", at: minutes(2), changes: [edit("c3d4")]),
            makeOp(opId: "op04", at: minutes(3), changes: [edit("a1b2")]),
            makeOp(opId: "op05", at: minutes(4), changes: [delete("c3d4")]),
        ]

        let signals = ProcessSignals(ops: ops, sequence: ["a1b2"], now: minutes(5))

        XCTAssertEqual(Self.describe(signals.hotspots), ["a1b2@0×1"],
                       "a paragraph rewritten and then cut is gone")
    }

    /// The window is the last five sessions, so what a writer wrestled with a
    /// fortnight and six sittings ago is not still being reported at them.
    ///
    /// **Disable experiment.** With `churnWindowSessions` read as `6` inside
    /// the window computation, this test failed at its assertion, the
    /// sixth-session-ago rewrites of a1b2 having been counted:
    /// `XCTAssertEqual failed: ("["c3d4@1×5", "a1b2@0×2"]") is not equal to
    /// ("["c3d4@1×5"]") - a rewrite six sessions ago is outside the window`.
    func test_theChurnWindowIsTheLastFiveSessions() {
        var ops = [
            makeOp(opId: "op01", at: days(0), changes: [edit("a1b2")]),
            makeOp(opId: "op02", at: days(0).addingTimeInterval(60),
                   changes: [edit("a1b2")]),
        ]
        for index in 1...5 {
            ops.append(makeOp(opId: String(format: "op%02d", index + 2),
                              at: days(Double(index)), changes: [edit("c3d4")]))
        }

        let signals = ProcessSignals(ops: ops, sequence: ["a1b2", "c3d4"], now: days(5))

        XCTAssertEqual(signals.sessions.count, 6)
        XCTAssertEqual(Self.describe(signals.hotspots), ["c3d4@1×5"],
                       "a rewrite six sessions ago is outside the window")
    }

    // MARK: - Time away

    /// Mid-session — the writer is typing right now — the interesting number is
    /// not zero, it is how long the drawer was shut before they came back
    /// (spec §5's "time away"; Denver's R5).
    func test_daysAwayMidSessionReadsTheGapBeforeTheLatestSession() {
        let ops = [
            makeOp(opId: "op01", at: days(0), changes: [mint("a1b2")]),
            makeOp(opId: "op02", at: days(5), changes: [edit("a1b2")]),
            makeOp(opId: "op03", at: days(5).addingTimeInterval(600),
                   changes: [edit("a1b2")]),
        ]

        // Ten minutes after the last op: inside the idle threshold, so the
        // writer is still in the session.
        let signals = ProcessSignals(ops: ops, sequence: ["a1b2"],
                                     now: days(5).addingTimeInterval(1_200))

        XCTAssertEqual(signals.sessions.count, 2)
        XCTAssertEqual(signals.daysAway, 5)
    }

    /// Idle — nobody is typing — and the number is simply how long the document
    /// has been shut.
    func test_daysAwayIdleReadsTheDaysSinceTheLastOp() {
        let ops = [
            makeOp(opId: "op01", at: days(0), changes: [mint("a1b2")]),
        ]

        let signals = ProcessSignals(ops: ops, sequence: ["a1b2"], now: days(3))

        XCTAssertEqual(signals.daysAway, 3)
    }

    /// A first sitting has no gap before it, so there is no time away to report.
    func test_daysAwayIsNilMidSessionWithNoEarlierSession() {
        let ops = [
            makeOp(opId: "op01", at: days(0), changes: [mint("a1b2")]),
        ]

        let signals = ProcessSignals(ops: ops, sequence: ["a1b2"],
                                     now: days(0).addingTimeInterval(600))

        XCTAssertNil(signals.daysAway)
    }

    // MARK: - The threshold rule

    /// Spec §5's plain threshold, all three signals at once: the frontier
    /// unmoved for three sessions, one paragraph rewritten five times inside
    /// the window, and a fortnight away.
    func test_noteworthyReportsEachSignalAtItsThreshold() {
        let signals = ProcessSignals(
            ops: Self.thresholdOps(rewritesInLastSession: 1),
            sequence: ["a1b2", "c3d4"],
            now: days(17))

        XCTAssertEqual(signals.sessionsSinceFrontierMoved, 3)
        XCTAssertEqual(signals.daysAway, 14)
        XCTAssertEqual(signals.noteworthy, [
            .frontierUnmoved(sessions: 3),
            .hotspot(.init(paragraphId: "a1b2", position: 0, rewrites: 5)),
            .coldRead(days: 14),
        ])
    }

    /// One under each threshold — two stalled sessions, four rewrites, thirteen
    /// days — is a quiet session, and a quiet session produces no line at all.
    func test_noteworthyIsEmptyOneUnderEveryThreshold() {
        let ops = [
            makeOp(opId: "op01", at: days(0), changes: [mint("a1b2"), mint("c3d4")]),
            makeOp(opId: "op02", at: days(1), changes: [edit("a1b2")]),
            makeOp(opId: "op03", at: days(1).addingTimeInterval(60),
                   changes: [edit("a1b2")]),
            makeOp(opId: "op04", at: days(2), changes: [edit("a1b2")]),
            makeOp(opId: "op05", at: days(2).addingTimeInterval(60),
                   changes: [edit("a1b2")]),
        ]

        // Thirteen days to the minute after the last op: whole days, so an hour
        // short of fourteen is thirteen.
        let signals = ProcessSignals(ops: ops, sequence: ["a1b2", "c3d4"],
                                     now: days(15).addingTimeInterval(60))

        XCTAssertEqual(signals.sessions.count, 3)
        XCTAssertEqual(signals.sessionsSinceFrontierMoved, 2)
        XCTAssertEqual(Self.describe(signals.hotspots), ["a1b2@0×4"])
        XCTAssertEqual(signals.daysAway, 13)
        XCTAssertEqual(signals.noteworthy, [])
    }

    /// The frontier's own signal carries the count so the briefing can say the
    /// number; four stalled sessions says four, not "≥ 3".
    func test_theStallSignalCarriesItsOwnCount() {
        var ops = [makeOp(opId: "op01", at: days(0), changes: [mint("a1b2")])]
        for index in 1...4 {
            ops.append(makeOp(opId: String(format: "op%02d", index + 1),
                              at: days(Double(index)), changes: [edit("a1b2")]))
        }

        let signals = ProcessSignals(ops: ops, sequence: ["a1b2"], now: days(4))

        XCTAssertEqual(signals.noteworthy.first, .frontierUnmoved(sessions: 4))
    }

    /// A hotspot under the rewrite threshold is still a hotspot — the Statistics
    /// window shows it — but it is not worth a sentence in the letter.
    func test_aHotspotUnderTheRewriteThresholdIsNotNoteworthy() {
        let signals = ProcessSignals(
            ops: Self.thresholdOps(rewritesInLastSession: 0),
            sequence: ["a1b2", "c3d4"],
            now: days(3).addingTimeInterval(600))

        XCTAssertEqual(Self.describe(signals.hotspots), ["a1b2@0×4"])
        XCTAssertFalse(signals.noteworthy.contains { signal in
            if case .hotspot = signal { return true }
            return false
        })
    }

    // MARK: - The one idle threshold

    /// Constraint 21: the op-derived session and the Statistics window's session
    /// must agree on the number, so there is one constant and it lives on
    /// `SessionTracker`.
    func test_theIdleThresholdIsThirtyMinutes() {
        XCTAssertEqual(SessionTracker.idleThreshold, 30 * 60)
    }

    /// The census: `DocumentStore` must not keep an idle threshold of its own
    /// beside `SessionTracker`'s. Two constants is how the two answers drift.
    func test_documentStoreDeclaresNoIdleThresholdOfItsOwn() throws {
        let source = try Self.documentStoreSource()

        XCTAssertFalse(Self.declaresAnIdleThreshold(in: source),
                       "DocumentStore must read SessionTracker.idleThreshold, "
                       + "not declare a second constant beside it")
        XCTAssertTrue(source.contains("SessionTracker.idleThreshold"),
                      "DocumentStore's idle timer must be scheduled off the one "
                      + "shared constant")
    }

    /// The planted offender, without which the census could be reading a file
    /// that says nothing either way.
    func test_plantedOffender_theCensusSeesASecondIdleThresholdDeclared() throws {
        let planted = try Self.documentStoreSource()
            + "\n    private static let sessionIdleThreshold: TimeInterval = 30 * 60\n"

        XCTAssertTrue(Self.declaresAnIdleThreshold(in: planted),
                      "the census cannot see a declared threshold — it is not "
                      + "reading what it claims to read")
    }

    private static func declaresAnIdleThreshold(in source: String) -> Bool {
        source.split(separator: "\n").contains { line in
            line.contains("static let") && line.lowercased().contains("idlethreshold")
        }
    }

    private static func documentStoreSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Maugham/Stores/DocumentStore.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Helpers

    /// `paragraphId@position×rewrites`, so a failure names what moved rather
    /// than printing four struct descriptions.
    private static func describe(_ hotspots: [ProcessSignals.Hotspot]) -> [String] {
        hotspots.map { "\($0.paragraphId)@\($0.position)×\($0.rewrites)" }
    }

    /// Four sessions: a mint in the first, then two rewrites in each of the next
    /// two and `rewritesInLastSession` in the fourth — so the frontier has been
    /// still for three sessions and a1b2 has been rewritten four or five times.
    private static func thresholdOps(rewritesInLastSession: Int) -> [Op] {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        func day(_ value: Double) -> Date { base.addingTimeInterval(value * 86_400) }
        func edit(_ id: String) -> Op.ParagraphChange {
            .init(paragraphId: id, prior: "Was.", next: "Revised.")
        }
        func op(_ opId: String, _ at: Date, _ changes: [Op.ParagraphChange]) -> Op {
            Op(opId: opId, docId: "doc-1", at: at, device: "macA",
               session: "s1", kind: .typingBurst, changes: changes, sequence: nil)
        }

        var ops = [op("op01", day(0), [.init(paragraphId: "a1b2", prior: nil, next: "New."),
                                       .init(paragraphId: "c3d4", prior: nil, next: "New.")])]
        ops.append(op("op02", day(1), [edit("a1b2")]))
        ops.append(op("op03", day(1).addingTimeInterval(60), [edit("a1b2")]))
        ops.append(op("op04", day(2), [edit("a1b2")]))
        ops.append(op("op05", day(2).addingTimeInterval(60), [edit("a1b2")]))
        for index in 0..<rewritesInLastSession {
            ops.append(op(String(format: "op%02d", index + 6),
                          day(3).addingTimeInterval(Double(index) * 60),
                          [edit("a1b2")]))
        }
        return ops
    }
}
