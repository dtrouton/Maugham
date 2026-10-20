import Foundation
import MaughamCore

/// The report's own English, in one place — the round narrative both
/// personas read. Moved out of `DiagnosticsPane` (M4 P2 Task 2) so a
/// consumer that must not depend on that view — Review's cockpit (Task 3)
/// — can read the same copy without a Review→DiagnosticsPane dependency.
/// `DiagnosticsPane` is one caller among others now, not the owner.
enum RoundNarrative {

    /// **The legible wait** (requirement 5). "Checking 14 new paragraphs…",
    /// never a bare participle: a cold first run over a long delta takes about
    /// two minutes, and a writer watching an unqualified "Checking…" for that
    /// long cannot tell a working compiler from a hung one.
    ///
    /// Total over counts a delta cannot have — `beginRun` refuses an empty one
    /// before the running state is ever set — because a function that has to be
    /// reasoned about before it can be called is one a later caller gets wrong.
    ///
    /// **A round says what it is doing instead of counting** (two loops P1
    /// Task 3). A round reads the piece whole, so its counts ARE the whole
    /// manuscript: "Checking 40 new paragraphs…" over one is a true number
    /// saying a false thing, and the writer who has typed four sentences today
    /// would read it as the app having lost track of their work. The counts
    /// are still passed — the caller is one `.running(counts)` case, and a
    /// second running state per kind would be two things that can disagree
    /// about whether a run is in flight — they are simply not what a round has
    /// to say for itself.
    ///
    /// `kind` defaults to `.check` for `runMessageV2`'s reason: the check is
    /// the verb that predates the split, and the one call site that is not a
    /// check — Review's cockpit — names itself.
    static func checkingCopy(
        _ counts: CompilerOrchestrator.DeltaCounts, kind: RunKind = .check,
        elapsed: TimeInterval? = nil, thinkingTokens: Int? = nil
    ) -> String {
        let base: String
        switch kind {
        case .round:
            base = "Reading the whole piece\u{2026}"
        case .check:
            if let phrase = paragraphPhrase(counts) {
                base = "Checking \(phrase)\u{2026}"
            } else {
                base = "Checking\u{2026}"
            }
        }
        // **The wait made legible** (spec 2026-09-09 §5): how long it has
        // been, and what the model has done so far, from the CLI's own
        // estimate. No clock means the sentence every caller had before this
        // milestone — a caller with nothing to say about the wait says
        // nothing rather than "0s".
        guard let elapsed else { return base }
        var line = base + " " + clockPhrase(elapsed)
        if let thinkingTokens, thinkingTokens > 0 {
            line += " \u{00b7} thinking (\(roughThousands(thinkingTokens)) tokens)"
        }
        return line
    }

    /// `4s`, `2m 10s`, `1h 2m` — the strip's clock. Truncated, never
    /// rounded up: a run in its fourth second has not reached five.
    static func clockPhrase(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3_600, minutes = (total % 3_600) / 60, secs = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(secs)s" }
        return "\(secs)s"
    }

    /// `12k`, never `12,400`, while the number is still moving: a digit that
    /// changes every tick is a number the writer reads as noise. The settled
    /// figure gets `thousands` in the tooltip.
    static func roughThousands(_ n: Int) -> String {
        n >= 1_000 ? "\(n / 1_000)k" : "\(n)"
    }

    /// The suffix the "Last checked" line and the cockpit's report line carry
    /// over a run that recorded its timing; empty otherwise, so a run filed
    /// before this milestone reads exactly as it did.
    static func readInSuffix(_ timing: RunTiming?) -> String {
        guard let timing else { return "" }
        return " \u{00b7} read in \(clockPhrase(timing.elapsed))"
    }

    /// **The same fact as a sentence**, for a surface with nothing to hang the
    /// suffix on. Review's cockpit reports a round against the one before it,
    /// so a lane's FIRST round has no line at all — and the cost of the
    /// only round a writer has run is exactly the thing they want to know.
    /// Capital letter and full stop, because here it is the whole line.
    static func readInLine(_ timing: RunTiming) -> String {
        "Read in \(clockPhrase(timing.elapsed))."
    }

    /// **The tooltip behind that suffix** — what the turn cost, for a
    /// writer who wants it, on a line nobody has to read. Every clause but the
    /// model is optional, because a legacy record or a result event that named
    /// none of them must still produce a sentence rather than a row of blanks.
    static func timingDetail(_ timing: RunTiming) -> String {
        var parts: [String] = []
        if let first = timing.firstLineAfter {
            parts.append("First word after \(clockPhrase(first))")
        }
        if let turns = timing.turns {
            parts.append(turns == 1 ? "1 turn" : "\(turns) turns")
        }
        if let thinking = timing.thinkingTokens {
            parts.append("\(thousands(thinking)) tokens of thinking")
        }
        parts.append("\(timing.model) at \(timing.effort)")
        if let cost = timing.costUSD {
            parts.append(String(format: "$%.2f", cost))
        }
        return parts.joined(separator: " \u{00b7} ")
    }

    /// What a delta is, in the writer's English — the ONE spelling, read by the
    /// header and by the empty state, because two sentences about the same two
    /// numbers are two things that can disagree.
    static func paragraphPhrase(_ counts: CompilerOrchestrator.DeltaCounts) -> String? {
        switch (counts.new, counts.revised) {
        case (0, 0):
            return nil
        case (let new, 0):
            return "\(new) new \(new == 1 ? "paragraph" : "paragraphs")"
        case (0, let revised):
            return "\(revised) revised \(revised == 1 ? "paragraph" : "paragraphs")"
        case (let new, let revised):
            // Always plural: the sum is at least two to reach this arm.
            return "\(new) new and \(revised) revised paragraphs"
        }
    }

    // MARK: - Since last round (spec §6; the arithmetic is `SinceLastRound`)

    /// **"Since round N−1: X resolved · Y persisting · Z new"**, or `nil` when
    /// this run is not a round that can be compared.
    ///
    /// **A fourth clause joins it when the round engaged a finding the writer
    /// is holding in another pass's lane** (#42 F-H) — "· 1 still open in
    /// Structural". The three counts above are lane-local by construction
    /// (`SinceLastRound`'s decision 1) and the mint refuses a cross-lane
    /// re-raise, so that case fell between them and left the round reading
    /// three zeroes. WHICH notes matched is not derived here: the mint records
    /// them on `CompilerRun.openInOtherLanesNoteIds` at the one place
    /// fingerprints are already compared, and `openElsewhere` asks the queue,
    /// on every render, which of them are still open (#53). Nothing still open
    /// appends nothing, so the sentence a writer already knows is unchanged.
    ///
    /// Pure and static on `driftNote`'s mould, and for the same reason: the
    /// sentence is the pane's, the arithmetic is not. `SinceLastRound.compute`
    /// is the ONE spelling of the three counts.
    ///
    /// **What it counts is the writer's QUEUE, not two rounds' reports** (M4
    /// P1 Task 5). Two of the three kinds a round raises are annotations now,
    /// so the sidecar no longer holds a round's findings to diff against — and
    /// diffing them was never right: the model rewords a finding every time it
    /// raises it, and a finding it simply stopped mentioning is not one the
    /// writer resolved. What the line says now is what they can check against
    /// their own screen — one settled since the last round, one still in front
    /// of them, one raised today.
    ///
    /// Silent in three cases:
    ///
    /// - the run carries no round number. A passless ⌘R is an ordinary M2 run;
    ///   there is no round for this to be *since*.
    /// - the newest record in its own lane is not the round immediately
    ///   before it. Round 1 has nothing behind it; a lane whose earlier rounds
    ///   have aged out of the ring has nothing left to compare; and — the case
    ///   this guard is really for — **a run still streaming has not filed the
    ///   round it supersedes yet**, so the newest same-lane record mid-preview
    ///   is round N−2. Without the check the pane would say "Since round 1"
    ///   over round 3's half-arrived report and then correct itself when the
    ///   turn ended. Within a lane the numbers are consecutive by construction
    ///   (`latestRound + 1`), so this costs nothing a finished round has.
    /// - the run was read with fresh eyes (Task 6). It was deliberately
    ///   briefed on no prior findings, so a difference measured against the
    ///   last round would be an artifact of the reading rather than of the
    ///   draft. Its header says what it is instead.
    ///
    /// `annotations` is the open document's queue in EVERY state — the
    /// filtering is `SinceLastRound`'s, and a caller that pre-filtered to open
    /// notes would report zero resolved forever.
    ///
    /// **This line and the run's own briefing can differ, and both are
    /// honest.** A writer who steps out of a lane and back is briefed on
    /// nothing (the previous round's prose was superseded two runs ago) while
    /// this line still counts, because the notes themselves are still in the
    /// queue carrying the round that raised them.
    ///
    /// `passes` is the project's ladder (`effectiveReviewPasses`), which is
    /// what names the lane a matched note is open in.
    static func sinceLastRoundLine(
        history: [RoundRecord], run: CompilerRun?, annotations: [Annotation],
        passes: [ReviewPass] = []
    ) -> String? {
        guard let run, let round = run.round, run.freshEyes != true else { return nil }
        guard let previous = history.last(where: {
            $0.passId == run.passId && $0.round != nil
        }), let previousNumber = previous.round, previousNumber == round - 1 else { return nil }

        // The boundary is the record's own `at` — when the round this line is
        // "since" was filed. Anything the writer settled before then was
        // already reported, in the round they settled it in.
        let outcome = SinceLastRound.compute(
            annotations: annotations, lane: run.passId, currentRound: round,
            previousRoundAt: previous.at)
        let line = "Since round \(previousNumber): \(outcome.resolved) resolved "
            + "\u{00b7} \(outcome.persisting) persisting \u{00b7} \(outcome.new) new"
        guard let elsewhere = openElsewhere(
            run: run, annotations: annotations, passes: passes) else { return line }
        return line + " \u{00b7} " + elsewhere.clause
    }

    /// **The cross-lane clause, live** (#53) — the ONE projection the
    /// since-line, `freshEyesHeader` and the Diagnostics pane's seal arm all
    /// read, so the three cannot disagree about whether a finding is still
    /// held elsewhere.
    ///
    /// A run recorded with `openInOtherLanesNoteIds` is filtered against the
    /// queue on every render: the matched notes still open, minus any finding
    /// that is now ALSO open in the run's own lane (own-lane presence wins,
    /// as at the mint — that one is the since-line's *persisting*), counted
    /// per FINDING (two open notes holding one fingerprint are one thing the
    /// writer holds), and the lanes holding them named. Settle the other
    /// lane's note and the clause is gone on the next render.
    ///
    /// A record written before the ids existed has only the count, which was
    /// a snapshot at the mint; it keeps its past-tense sentence
    /// (`openInOtherLanes(_:)`), the one thing a stored number can keep being
    /// right about.
    ///
    /// `annotations` is the document's queue in any state (the filtering is
    /// here); `passes` is the project's ladder.
    static func openElsewhere(
        run: CompilerRun, annotations: [Annotation], passes: [ReviewPass]
    ) -> (clause: String, sentence: String)? {
        guard let ids = run.openInOtherLanesNoteIds else {
            return openInOtherLanes(run.openInOtherLanes)
        }
        let matched = Set(ids)
        let open = annotations.filter { $0.status == .open }
        let ownLane = Set(open.lazy
            .filter { $0.isCompilerAuthored && $0.reviewPassId == run.passId }
            .compactMap(\.compilerFingerprint))
        var findings = Set<String>()
        var lanes = Set<String?>()
        for note in open where matched.contains(note.id) && note.reviewPassId != run.passId {
            let finding = note.compilerFingerprint ?? note.id
            guard !ownLane.contains(finding) else { continue }
            findings.insert(finding)
            lanes.insert(note.reviewPassId)
        }
        guard !findings.isEmpty else { return nil }
        let count = findings.count
        let heldIn = laneNames(lanes, passes: passes)
        return (clause: "\(count) still open in \(heldIn)",
                sentence: count == 1
                    ? "1 finding this check raised is still open in \(heldIn)."
                    : "\(count) findings this check raised are still open in \(heldIn).")
    }

    /// **The lanes holding a finding, in words** — "Structural", "Structural
    /// and Line", "Structural, Line and Copyedit".
    ///
    /// Named through `ReviewPass.pass(id:in:)` and its `laneDisplayName`, the
    /// one spelling the board uses (the coach answers her editor's name), in
    /// ladder order. A lane with no name — a passless check's notes, or a
    /// pass the project no longer lists — is never drawn as its raw id: it
    /// reads "another lane" ("other lanes" for several), last.
    static func laneNames(_ lanes: Set<String?>, passes: [ReviewPass]) -> String {
        var named: [(rank: Int, name: String)] = []
        var unnamed = 0
        for lane in lanes {
            guard let id = lane, let pass = ReviewPass.pass(id: id, in: passes) else {
                unnamed += 1
                continue
            }
            named.append((passes.firstIndex { $0.id == id } ?? passes.count,
                          pass.laneDisplayName))
        }
        var words = named
            .sorted { ($0.rank, $0.name) < ($1.rank, $1.name) }
            .map(\.name)
        if unnamed == 1 { words.append("another lane") }
        if unnamed > 1 { words.append("other lanes") }
        guard let last = words.popLast() else { return "another lane" }
        return words.isEmpty ? last : words.joined(separator: ", ") + " and " + last
    }

    /// **The cross-lane count in words, for a LEGACY record** (#42 F-H) — one
    /// written before `openInOtherLanesNoteIds` existed, which only
    /// `openElsewhere` reads through. `nil` when there is nothing to say:
    /// zero, or a record written before the count existed either.
    ///
    /// **One function returning BOTH wordings, rather than two functions.** The
    /// three surfaces that say this phrase it differently — the since-line
    /// appends a bare clause to a row of counts, while the pane's empty state
    /// opens a sentence of its own — but they must agree about when one becomes
    /// many, and a second `count == 1` written elsewhere is a second place for
    /// that to drift. The singular and plural forms sit adjacent here for the
    /// same reason.
    ///
    /// **Past tense, deliberately** (whole-branch review, M1). The three counts
    /// beside this clause are computed live off the writer's queue every time
    /// the line is drawn; this number is a snapshot taken at the mint and
    /// stored on the run. Present tense ("is already open") would quietly go
    /// false the moment the writer settled the other lane's note, and the
    /// sentence would then claim something about the queue that the queue no
    /// longer says. Past tense describes what the ROUND did, which is the one
    /// thing a stored number can keep being right about.
    static func openInOtherLanes(_ count: Int?)
        -> (clause: String, sentence: String)? {
        guard let count, count > 0 else { return nil }
        return count == 1
            ? (clause: "1 was already open in another lane",
               sentence: "What this check raised was already open in another "
                   + "pass's queue.")
            : (clause: "\(count) were already open in other lanes",
               sentence: "What this check raised was already open in other "
                   + "passes' queues.")
    }

    /// **"Fresh eyes · round N"** — what a cold read (⌘⇧R) says about itself,
    /// in the slot the since-last-round line would have taken.
    ///
    /// The two are mutually exclusive by construction and that is the point:
    /// a fresh-eyes round was briefed on no prior findings (spec §6), so it
    /// has no distance to report, and a comparison drawn over it would name a
    /// difference the run never made. `sinceLastRoundLine` refuses the same
    /// round from the other end; this is what stands in its place, so a report
    /// that leads with nothing is never how the writer learns their expensive
    /// keystroke did something different.
    ///
    /// `nil` round is a passless cold read — an ordinary M2 ⌘⇧R — which is
    /// still worth saying, just with no number to name.
    ///
    /// `== true` rather than `?? false`: the stamp is `Bool?` on the wire and
    /// an ordinary run writes no key at all, so absent and `false` must read
    /// alike.
    /// **It carries the cross-lane clause too** (#42, whole-branch review I2).
    /// A cold read is one of the places the since-line is silent by design, so
    /// without this the count would be recorded on the run and drawn nowhere —
    /// and a Fresh Eyes round whose every finding was already open in another
    /// pass is exactly the round a writer would otherwise read as "found
    /// nothing".
    ///
    /// Read through `openElsewhere`, the since-line's own projection, so it
    /// is live too (#53).
    static func freshEyesHeader(
        run: CompilerRun?, annotations: [Annotation] = [], passes: [ReviewPass] = []
    ) -> String? {
        guard let run, run.freshEyes == true else { return nil }
        var header = "Fresh eyes"
        if let round = run.round { header += " \u{00b7} round \(round)" }
        if let elsewhere = openElsewhere(
            run: run, annotations: annotations, passes: passes) {
            header += " \u{00b7} " + elsewhere.clause
        }
        return header
    }

    // MARK: - When a run does not answer

    /// **One honest sentence per failure** — no apology, no chirp. `cliNotFound`
    /// and `disabledByToggle` each name the surface that fixes them;
    /// `sessionDied` only ever reaches here for a death that was NOT the
    /// writer's own doing (`CompilerOrchestrator.finish` already routes the
    /// other three details to `.idle` through
    /// `CompilerRunFailure.isTheWritersOwnDoing`), so its detail is worth
    /// showing rather than translating away.
    ///
    /// **Hoisted out of `DiagnosticsPane` (2026-08-18, Denver's smoke) for the
    /// reason the rest of this file was hoisted: a second surface now says it.**
    /// Review's cockpit collapsed `.failed` into `.idle` and drew a timed-out
    /// round exactly like a clean one, so two Structural and Line rounds that
    /// died at the 120s budget read as "returned nothing" — the failure was
    /// legible only in Author's Diagnostics pane, which is not where the run was
    /// launched. A failure must surface where the button was pressed, and both
    /// surfaces must say it in the same words: a writer who checks the other
    /// pane to understand the first must not find a differently-worded account
    /// of the same death. `ReviewRoundCockpitTests`' one-spelling census reads
    /// every surface's file and goes red on a restatement.
    ///
    /// **`session` is what the third surface needed** (publish-department P4 Task
    /// 3). The compiler's check, the translator's round — and, when the desk's
    /// Design row runs, the designer's — all die through this one
    /// `CompilerRunFailure`, because they are one `ClaudeCLISession` machinery
    /// with three owners. So there must go on being ONE switch over it. What
    /// differs is only the noun: "The check took too long" is not what a writer
    /// asked for when they pressed Run on the Spanish row, and "couldn't be read
    /// as notes" describes nothing a translator produces. Defaulted to `.check`,
    /// so the two surfaces that came first are unchanged to the byte.
    static func failureCopy(_ failure: CompilerRunFailure,
                            session: SessionWork = .check) -> String {
        switch failure {
        case .cliNotFound:
            return "Claude Code isn't installed. Set it up, then check "
                + "Settings \u{2192} General \u{2192} Claude integration."
        case .disabledByToggle:
            return "Claude access is off in Settings \u{2014} turn on "
                + "\u{201C}Allow Claude to connect (MCP)\u{201D} to \(session.purpose)."
        case .timedOut(let stall):
            return stallCopy(stall, session: session)
        case .sessionDied(let detail):
            return "\(session.owner) ended before it could answer: \(detail)."
        case .unusableOutput:
            return "Claude's answer couldn't be read as \(session.product)."
        }
    }

    /// **Which budget stopped the turn, and how far it had got** (spec
    /// 2026-09-09 §2). A stall with no account of itself (`Stall.unknown`,
    /// `after == 0`) keeps the sentence every caller had before this
    /// milestone, so a legacy `.timedOut()` reads exactly as it did.
    static func stallCopy(_ stall: CompilerRunFailure.Stall, session: SessionWork) -> String {
        guard stall.after > 0 else {
            return "\(session.subject) took too long and was stopped."
        }
        let base: String
        switch stall.cause {
        case .silence:
            base = "Claude went quiet for \(minutesPhrase(stall.after)) and was stopped"
        case .ceiling:
            base = "The read passed \(minutesPhrase(stall.after)) and was stopped"
        }
        guard let tokens = stall.thinkingTokens, tokens > 0 else { return base + "." }
        return base + " \u{2014} \(thousands(tokens)) tokens of thinking so far."
    }

    /// Whole minutes, in the writer's English. Under sixty seconds is "under
    /// a minute" rather than "0 minutes".
    static func minutesPhrase(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.down))
        guard minutes >= 1 else { return "under a minute" }
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    /// `31,000`, never `31000`: the pane's numbers are read, not parsed. POSIX
    /// locale carries no grouping separator, so use en_US instead.
    static func thousands(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// **Which of the three long-lived sessions died**, for the arms of
    /// `failureCopy` whose sentence names the work rather than a surface to go
    /// and fix.
    ///
    /// Four properties rather than four separate sentences per case: the SHAPE of
    /// each sentence is shared — that is the whole reason there is one switch —
    /// and what a case supplies is the nouns that shape takes.
    enum SessionWork {
        /// The compiler's check (M2). The default, so every existing caller
        /// reads exactly as it did.
        case check
        /// A translation round (publish department).
        case translation
        /// A design round (publish department, P4's desk). The third owner of
        /// the one `ClaudeCLISession` machinery, and the third set of nouns.
        case design

        /// What the writer asked for, as the subject of a sentence.
        var subject: String {
            switch self {
            case .check: return "The check"
            case .translation: return "The translation round"
            case .design: return "The design round"
            }
        }

        /// Whose session it was.
        var owner: String {
            switch self {
            case .check: return "The compiler\u{2019}s session"
            case .translation: return "The translator\u{2019}s session"
            case .design: return "The designer\u{2019}s session"
            }
        }

        /// What a readable answer would have been.
        var product: String {
            switch self {
            case .check: return "notes"
            case .translation: return "translations"
            case .design: return "a design proposal"
            }
        }

        /// What turning the toggle back on would let Claude do.
        var purpose: String {
            switch self {
            case .check: return "check your writing"
            case .translation: return "translate your writing"
            case .design: return "design your book"
            }
        }
    }

    // MARK: - Asking for one

    /// **"Run Gould's round"** — the offer, by the name of the editor who
    /// reads it (M4 P2 Task 4).
    ///
    /// One spelling because it is now said in two places a reviewer sees in
    /// the same minute: the empty queue's teaching in Review's cockpit, and
    /// the verb on every chip of the board. The personification is the whole
    /// point — a writer asks Gould for a copyedit, not "the compiler" for a
    /// "pass" — so the two must not drift into naming the same act two ways.
    ///
    /// The caller resolves the name through `ReviewPass.effectiveEditorName`,
    /// never the raw field: a customized manifest can store a preset-id pass
    /// that predates the editor field, and a pass a writer named themselves
    /// falls back to its own name ("Run Beta Read's round"), which reads as
    /// intended rather than naming a person who does not exist.
    static func runRoundTitle(editorName: String) -> String {
        "Run \(editorName)\u{2019}s round"
    }

    /// **A run of this loop on ANOTHER piece** (#83) — the line both loops'
    /// surfaces draw while the window's one session reads a different
    /// document. Review's says Run waits; Author's says \u{2318}R waits (F7's
    /// keys). The piece is named by its title in curly quotes, or "another
    /// piece" when the manifest cannot name it: never the raw document id,
    /// which is not prose.
    static func runElsewhereLine(kind: RunKind, title: String?) -> String {
        let piece: String
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            piece = "\u{201C}\(title)\u{201D}"
        } else {
            piece = "another piece"
        }
        switch kind {
        case .round:
            return "A round is running on \(piece) \u{2014} Run waits until it finishes."
        case .check:
            return "A check is running on \(piece) \u{2014} \u{2318}R waits until it finishes."
        }
    }

    /// **The one title lookup for `runElsewhereLine`** (#83): pure, over the
    /// manifest structure the host already holds, so naming the other piece
    /// adds no observable state. `nil` when nothing names the id — the caller
    /// falls back to "another piece", never to the id.
    static func pieceTitle(of docId: String, in structure: [StructureItem]?) -> String? {
        structure.flatMap { TreeWalk.find(id: docId, in: $0)?.title }
    }
}
