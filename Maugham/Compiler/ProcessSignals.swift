import Foundation
import MaughamCore

/// Maugham's own observation of the writer's process, computed off one
/// document's op log and nothing else — spec
/// `2026-08-29-the-editorial-letter-design.md` §5.
///
/// Four observations: where the **frontier** is (the last place new paragraphs
/// were added, and the session that added them), what is being **rewritten**
/// and how often, how many sessions since the frontier last moved, and how
/// many days the writer was away. No model is involved and no judgement is
/// made here — `noteworthy` is the whole of the opinion, and it is a plain
/// threshold.
///
/// **Pure.** The value takes `(ops, sequence, now)` — the same reading
/// `DeltaBuilder` already takes — and reads no store, no `SessionLog` and no
/// clock of its own, so the compiler can compute it at the keystroke from
/// `DocumentReading` and the Statistics window can compute it per closed
/// document off `OpLogStore.loadSyncMerged`, and the two cannot disagree.
///
/// **The frontier moves only on the writer's own hand.** `Deriver.appliesToManuscript`
/// decides what forms a SESSION — every op that reaches the manuscript text is
/// evidence the writer was at the desk. It cannot decide what counts as
/// WRITING, and a `.checkpointRestore` proves it: `Restore.makeRestoreOp`
/// writes `prior: curr`, which is `nil` for a paragraph the restore reinstates,
/// so a rewind would read as a mint and reset the frontier to the moment of the
/// rewind. So two narrower questions are asked here, of two allowlists: a MINT
/// counts only on a `.typingBurst`, and a REWRITE only on a `.typingBurst` or a
/// `.claudeAccept`. Restores, reverts, rejects, bootstraps and external edits
/// move manuscript text without the writer composing a line of it.
///
/// **A session here is derived, not `Op.session`.** `Op.session` is
/// process-lifetime on the Mac (`EditorHost.sessionId` is minted once per
/// launch), so a week left open would count as one sitting. A session is a run
/// of manuscript ops split where `Op.session` changes OR where consecutive ops
/// are at least `SessionTracker.idleThreshold` apart — the same constant the
/// Statistics window's own sessions are cut on, so the two agree on the number.
struct ProcessSignals: Equatable, Sendable {

    /// One sitting: a run of manuscript ops with no session change and no idle
    /// gap inside it. `index` is 0-based in file order, so the latest session
    /// is `sessions.count - 1`.
    struct Session: Equatable, Sendable {
        let index: Int
        let startedAt: Date
        let endedAt: Date
        let opIds: [String]
    }

    /// The most recently MINTED paragraph that is still in `sequence`, and the
    /// session that minted it. A paragraph typed and then cut is not where the
    /// writing stands, and a `.bootstrap` mint is text that already existed.
    struct Frontier: Equatable, Sendable {
        let paragraphId: String
        let position: Int
        let sessionIndex: Int
        let at: Date
    }

    /// A live paragraph and how many ops inside the churn window rewrote it.
    struct Hotspot: Equatable, Sendable {
        let paragraphId: String
        let position: Int
        let rewrites: Int
    }

    let sessions: [Session]
    let frontier: Frontier?
    /// Sessions AFTER the frontier's session — `nil` with no frontier, 0 when
    /// it moved in the latest session.
    let sessionsSinceFrontierMoved: Int?
    /// Top `hotspotCount` live paragraphs by rewrites over the last
    /// `churnWindowSessions` sessions, ties by position; excludes paragraphs
    /// with 0 rewrites.
    let hotspots: [Hotspot]
    /// Days away BEFORE the latest session when the writer is mid-session now
    /// (last op within `SessionTracker.idleThreshold` of `now`), else days
    /// since the last op. `nil` with fewer than one session, or mid-session
    /// with no earlier session.
    let daysAway: Int?

    /// Spec §5's thresholds. Changing one changes what the letter is allowed to
    /// mention, so they are named constants rather than literals at the site.
    static let frontierStallSessions = 3
    static let churnWindowSessions = 5
    static let hotspotRewrites = 5
    static let hotspotCount = 3
    static let coldReadDays = 14

    init(ops: [Op], sequence: [String], now: Date) {
        // Op order is `DeltaBuilder.ordered`'s, the one spelling, because the
        // compiler reads the same op stream through both. Only ops that reach
        // the manuscript form a sitting, and that question is asked of
        // `Deriver.appliesToManuscript` rather than a local re-switch.
        let ordered = DeltaBuilder.ordered(ops)
            .filter { Deriver.appliesToManuscript($0.kind) }

        let sessions = Self.sessions(in: ordered)
        self.sessions = sessions

        let sessionIndexByOpId = Self.sessionIndexByOpId(sessions)
        // `position` is also the liveness oracle: a paragraph the manuscript no
        // longer orders has no entry, and both readings below test it once.
        let position = Self.positions(in: sequence)

        self.frontier = Self.frontier(
            in: ordered, position: position,
            sessionIndexByOpId: sessionIndexByOpId)
        self.sessionsSinceFrontierMoved = self.frontier.map {
            sessions.count - 1 - $0.sessionIndex
        }
        self.hotspots = Self.hotspots(
            in: ordered, sessions: sessions, position: position,
            sessionIndexByOpId: sessionIndexByOpId)
        self.daysAway = Self.daysAway(sessions: sessions, now: now)
    }

    // MARK: - Sessions

    private static func sessions(in ordered: [Op]) -> [Session] {
        var sessions: [Session] = []
        var current: [Op] = []

        func close() {
            guard let first = current.first, let last = current.last else { return }
            sessions.append(Session(
                index: sessions.count,
                startedAt: first.at,
                endedAt: last.at,
                opIds: current.map(\.opId)))
            current = []
        }

        for op in ordered {
            if let previous = current.last {
                let sittingChanged = op.session != previous.session
                let wentIdle = op.at.timeIntervalSince(previous.at)
                    >= SessionTracker.idleThreshold
                if sittingChanged || wentIdle { close() }
            }
            current.append(op)
        }
        close()
        return sessions
    }

    private static func sessionIndexByOpId(_ sessions: [Session]) -> [String: Int] {
        var map: [String: Int] = [:]
        for session in sessions {
            for opId in session.opIds { map[opId] = session.index }
        }
        return map
    }

    /// Paragraph id → its index in `sequence`, and so also the liveness
    /// oracle: an id with no entry is not in the manuscript. First position
    /// wins, which matters only for a sequence corrupt enough to repeat an id.
    private static func positions(in sequence: [String]) -> [String: Int] {
        var map: [String: Int] = [:]
        for (index, paragraphId) in sequence.enumerated() where map[paragraphId] == nil {
            map[paragraphId] = index
        }
        return map
    }

    // MARK: - The writer's own hand

    /// An op on which a change with no prior is the writer opening a new
    /// paragraph. Only typing is: a bootstrap mints ids for text that already
    /// existed, and a `.checkpointRestore` reinstating a paragraph carries a
    /// nil prior too (`Restore.makeRestoreOp`), so importing a finished chapter
    /// and rewinding to Tuesday would both read as drafting.
    private static func mintsTheFrontier(_ kind: OpKind) -> Bool {
        switch kind {
        case .typingBurst: return true
        default: return false
        }
    }

    /// An op on which a change over existing text is the writer revising.
    /// Typing is, and taking Claude's suggested change is — the writer chose
    /// it. A restore, a revert and a reject each move text back to something it
    /// already said, which is not the same act.
    private static func countsAsARewrite(_ kind: OpKind) -> Bool {
        switch kind {
        case .typingBurst, .claudeAccept: return true
        default: return false
        }
    }

    // MARK: - The frontier

    /// The frontier is the LATEST mint in op order whose paragraph is still in
    /// `sequence`; `nil` is a legitimate answer.
    private static func frontier(
        in ordered: [Op],
        position: [String: Int],
        sessionIndexByOpId: [String: Int]
    ) -> Frontier? {
        for op in ordered.reversed() where mintsTheFrontier(op.kind) {
            for change in op.changes.reversed() where change.prior == nil {
                // No position is no longer in `sequence` — a paragraph typed
                // and then cut is not where the writing stands.
                guard let position = position[change.paragraphId],
                      let sessionIndex = sessionIndexByOpId[op.opId] else { continue }
                return Frontier(
                    paragraphId: change.paragraphId,
                    position: position,
                    sessionIndex: sessionIndex,
                    at: op.at)
            }
        }
        return nil
    }

    // MARK: - Churn

    /// A rewrite is a change carrying a prior and a non-empty next, on an op
    /// `countsAsARewrite` admits — a mint has no prior and a cut has an empty
    /// next (`Document.deleteParagraph`), and a restore is not revision. The
    /// op is the unit, so two changes to one paragraph inside one op is one
    /// rewrite; only paragraphs still in `sequence` are counted, and only ops
    /// inside the last `churnWindowSessions` sessions.
    private static func hotspots(
        in ordered: [Op],
        sessions: [Session],
        position: [String: Int],
        sessionIndexByOpId: [String: Int]
    ) -> [Hotspot] {
        let firstCountedSession = max(0, sessions.count - churnWindowSessions)

        var rewrites: [String: Int] = [:]
        for op in ordered where countsAsARewrite(op.kind) {
            guard let sessionIndex = sessionIndexByOpId[op.opId],
                  sessionIndex >= firstCountedSession else { continue }
            var countedInThisOp: Set<String> = []
            for change in op.changes {
                guard change.prior != nil, !change.next.isEmpty,
                      !countedInThisOp.contains(change.paragraphId) else { continue }
                countedInThisOp.insert(change.paragraphId)
                rewrites[change.paragraphId, default: 0] += 1
            }
        }

        // The `compactMap` is the liveness test: a paragraph rewritten and
        // then cut has no position, and drops out here.
        let ranked = rewrites
            .compactMap { paragraphId, count -> Hotspot? in
                position[paragraphId].map {
                    Hotspot(paragraphId: paragraphId, position: $0, rewrites: count)
                }
            }
            .sorted { a, b in
                a.rewrites == b.rewrites ? a.position < b.position : a.rewrites > b.rewrites
            }
        return Array(ranked.prefix(hotspotCount))
    }

    // MARK: - Time away

    /// Mid-session the interesting number is not zero — it is how long the
    /// drawer was shut before the writer came back — so a live session reads
    /// the gap BEFORE it. Idle, it is simply how long the document has been
    /// shut. Whole days on the writer's own calendar.
    private static func daysAway(sessions: [Session], now: Date) -> Int? {
        guard let latest = sessions.last else { return nil }
        let midSession = now.timeIntervalSince(latest.endedAt)
            < SessionTracker.idleThreshold
        guard midSession else { return wholeDays(from: latest.endedAt, to: now) }
        guard sessions.count >= 2 else { return nil }
        return wholeDays(from: sessions[sessions.count - 2].endedAt, to: latest.startedAt)
    }

    private static func wholeDays(from: Date, to: Date) -> Int? {
        Calendar.current.dateComponents([.day], from: from, to: to).day
    }

    // MARK: - The threshold rule

    /// What makes a `processSection` worth writing (spec §5). Empty is a quiet
    /// session, and a quiet session produces no line at all.
    var noteworthy: [Signal] {
        var signals: [Signal] = []
        if let stalled = sessionsSinceFrontierMoved,
           stalled >= Self.frontierStallSessions {
            signals.append(.frontierUnmoved(sessions: stalled))
        }
        for hotspot in hotspots where hotspot.rewrites >= Self.hotspotRewrites {
            signals.append(.hotspot(hotspot))
        }
        if let days = daysAway, days >= Self.coldReadDays {
            signals.append(.coldRead(days: days))
        }
        return signals
    }

    enum Signal: Equatable, Sendable {
        case frontierUnmoved(sessions: Int)
        case hotspot(Hotspot)
        case coldRead(days: Int)
    }
}
