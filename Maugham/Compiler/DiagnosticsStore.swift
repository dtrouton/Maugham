import Foundation
import MaughamCore

/// Per-device, per-document sidecar of compiler diagnostics: the notes the
/// last un-superseded `CompilerRun` raised against one document, on THIS
/// machine.
///
/// Derived state (mirrors `CanvasStore.load`'s contract): a missing or
/// corrupt sidecar reads as empty rather than throwing. Losing it costs
/// nothing — the next compiler run repopulates it — so there is no repair
/// path, only "start from nothing."
///
/// One file per `(docId, device)` under `.maugham/diagnostics/` (tripwire 17
/// spirit: a diagnostics run on one Mac must not collide with a run on
/// another writing the same doc). `replace` is the compiler's write: a new
/// run's diagnostics wholly supersede the previous run's for that doc — there
/// is never more than one run's worth of notes live per document.
@Observable @MainActor
final class DiagnosticsStore {
    /// Monotonic; bumped by every mutation (`load`, `replace`, `dismiss`) so
    /// an observing pane can invalidate a cached read without diffing arrays.
    private(set) var version: Int = 0

    /// Per document: how many notes a run has landed that the writer has not
    /// had in front of them yet — the picker's unread badge, the Inbox
    /// segment's idiom (`DetailPaneToggle.inboxCount`).
    ///
    /// **In memory only, and deliberately.** Unread is a fact about this
    /// session's attention, not about the document: a project reopened puts
    /// the notes back on the pane where they can be read, and a badge restored
    /// with them would be counting something the writer already answered. The
    /// sidecar stays a record of the run.
    private(set) var unread: [String: Int] = [:]

    private let projectRoot: URL
    private let device: DeviceSlug

    private struct FileContent: Codable, Equatable {
        var run: CompilerRun
        var diagnostics: [Diagnostic]
        /// The drift ring: clause-status snapshots from ingests that carried
        /// them, oldest→newest, capped at `clauseHistoryDepth`. Appended only
        /// by `replace` — never reconstructed on `load` — so a sidecar
        /// written before this field existed decodes with an empty ring
        /// rather than a backfill from the standing run.
        var clauseHistory: [[DiagnosticIngest.ClauseStatus]]
        /// The round ring: THAT each of the last `roundHistoryDepth` rounds
        /// finished, which lane it was in and when, oldest→newest. Appended
        /// only by `replace`, and only from the run it is about to supersede —
        /// a round's notes are gone the moment the next round replaces them,
        /// and this is the only thing left that says the round happened.
        ///
        /// **What it does not hold is what the rounds FOUND** (M4 P1 Task 5):
        /// that is counted off the queue by `SinceLastRound`, whose boundary is
        /// this record's `at`.
        var rounds: [RoundRecord]

        init(
            run: CompilerRun, diagnostics: [Diagnostic],
            clauseHistory: [[DiagnosticIngest.ClauseStatus]] = [],
            rounds: [RoundRecord] = []
        ) {
            self.run = run
            self.diagnostics = diagnostics
            self.clauseHistory = clauseHistory
            self.rounds = rounds
        }

        /// Hand-written so a v1/v2 sidecar (written before these fields
        /// existed) decodes clean instead of failing the whole file — the
        /// same discipline as `CompilerRun.init(from:)`, and with the same
        /// trap: a new field needs its own `decodeIfPresent` line here,
        /// because the property's default is not what a synthesised decode
        /// falls back to.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            run = try c.decode(CompilerRun.self, forKey: .run)
            diagnostics = try c.decode([Diagnostic].self, forKey: .diagnostics)
            clauseHistory = try c.decodeIfPresent(
                [[DiagnosticIngest.ClauseStatus]].self, forKey: .clauseHistory) ?? []
            rounds = try c.decodeIfPresent([RoundRecord].self, forKey: .rounds) ?? []
        }
    }

    private var byDoc: [String: FileContent] = [:]

    /// Documents whose in-memory content is a `preview` — a run still
    /// arriving — rather than a run that finished. Read by `load`, which must
    /// not read the sidecar back over one.
    private var previewing: Set<String> = []

    /// For a document whose in-memory content is a preview: the last content
    /// that belonged to a run which FINISHED — `replace`'s snapshot source for
    /// the round ring.
    ///
    /// **A preview overwrites the very record the ring is owed.** `replace`
    /// remembers the run it supersedes, and in production every run streams,
    /// so by the time the turn ends the standing content is that same run's
    /// own half-report: snapshotting it would file a round against itself and
    /// "since last round" would report everything as persisting, forever. So
    /// the finished content is set aside when the preview begins and consumed
    /// when the run that superseded it lands.
    ///
    /// This is not a preview writing the ring (the global rule): nothing is
    /// appended anywhere until `replace` runs, and a preview that never
    /// finishes (`discardPreview`) drops it untouched.
    private var finishedBeforePreview: [String: FileContent] = [:]

    /// The content of the last run against `docId` that actually FINISHED —
    /// the standing content, unless a preview has been standing in for it, in
    /// which case the shadow is the only place a finished run can be.
    ///
    /// **Keyed on the previewing FLAG, never on the shadow's nil-ness.** A
    /// cold document's first preview captures nothing, and assigning nil to a
    /// Dictionary subscript REMOVES the key, so "captured, and there was
    /// nothing" reads exactly like "never captured" — a `??` fallthrough would
    /// then reach for `byDoc`, which is that same run's own preview, and the
    /// first ⌘R against a new document would file round 1 against itself.
    ///
    /// Both readers of "the previous round" come through here — `replace`
    /// filing it into the ring, and `standingRound` handing it to the briefing
    /// of the round about to begin — so the two can never disagree about which
    /// run that is.
    private func finishedContent(docId: String) -> FileContent? {
        previewing.contains(docId) ? finishedBeforePreview[docId] : byDoc[docId]
    }

    /// docIds the writer has told the cold-start offer "Not now" to, on THIS
    /// device — spec §4's "never re-asked as a nag" (`DiagnosticsPane`'s
    /// `showsColdStartOffer`). Loaded once here rather than per-doc-lazily
    /// like `FileContent`: a refusal is a single bit with no run, no notes and
    /// no drift ring beside it, and a document can be refused before it has
    /// ever been run at all — before `FileContent` for it exists — so this
    /// cannot live inside that struct without fabricating a run that never
    /// happened. One small file for the whole project, on the same
    /// derived-state contract as everything else here: losing it costs
    /// nothing worse than the offer asking once more.
    private var refusedColdStart: Set<String>

    /// What the writer has asked of the next run, per document, on THIS
    /// device — "I'm worried the middle sags" (editorial letter P2 §3.7).
    ///
    /// **Beside `FileContent` rather than inside it, for `refusedColdStart`'s
    /// reason and one sharper.** An ask is written BEFORE a run, and the
    /// sidecar is written by one: a writer can type an ask into a document the
    /// compiler has never read, and there is no `CompilerRun` to hang it off.
    /// Putting it in the per-doc file would mean fabricating a run that never
    /// happened, and every ask would be lost the moment the writer typed it.
    ///
    /// One small file for the whole project, keyed by docId, on the same
    /// derived-state contract as everything else here — except that this one
    /// is the writer's own words rather than a run's output, which is why it
    /// is persisted the instant it is set rather than at the next run.
    private var asks: [String: String]

    init(projectRoot: URL, device: DeviceSlug) {
        self.projectRoot = projectRoot
        self.device = device
        self.refusedColdStart = Self.loadRefusedColdStart(projectRoot: projectRoot, device: device)
        self.asks = Self.loadAsks(projectRoot: projectRoot, device: device)
    }

    /// Read this device's sidecar for `docId` into memory. A missing or
    /// corrupt file clears any in-memory entry for `docId` rather than
    /// throwing — the derived-state contract.
    ///
    /// **A v1 run's notes are dropped as superseded** (`kind == nil`; see
    /// `DiagnosticKind`). They were written against a contract this build no
    /// longer speaks — a free-form category, no refs, no clause — and
    /// replace-on-run puts them one run from gone regardless, so migrating
    /// them would be work to preserve something the next ⌘R deletes. The RUN
    /// RECORD is kept, so the pane can still say when the document was last
    /// checked and what that run discarded.
    ///
    /// **A standing preview is never read over.** A run still arriving is by
    /// construction newer than the sidecar, which holds the last run that
    /// finished — so re-reading the file mid-stream would put an OLDER answer
    /// on a pane whose header says "Checking…". The real caller is
    /// `DiagnosticsPane.onAppear`: a writer who presses ⌘R from the editor and
    /// then opens the pane mounts it mid-check, and without this the report
    /// they came to watch blinks back to the previous run until the next
    /// section lands. `discardPreview` is how a preview is deliberately
    /// dropped, and it clears this first.
    func load(docId: String) {
        guard !previewing.contains(docId) else { return }
        let url = Self.sidecarURL(projectRoot: projectRoot, docId: docId, device: device)
        guard let data = try? Data(contentsOf: url), // adr-0018-ok: diagnostics sidecar, derived, not manuscript
              let content = try? Self.makeDecoder().decode(FileContent.self, from: data)
        else {
            byDoc[docId] = nil
            version += 1
            return
        }
        byDoc[docId] = FileContent(
            run: content.run, diagnostics: content.diagnostics.filter { $0.kind != nil },
            clauseHistory: content.clauseHistory, rounds: content.rounds)
        version += 1
    }

    /// A new run's diagnostics wholly replace the previous run's for
    /// `docId` — un-promoted notes from the prior run are dropped, not
    /// merged. Persists immediately.
    ///
    /// **The drift ring is not swept along with them.** When `run` carries
    /// clause statuses (an ingest that actually checked something — `nil`
    /// means nothing was declared to check, distinct from an empty list
    /// meaning it checked and found nothing straining), that snapshot is
    /// appended to the ring, oldest dropped past `clauseHistoryDepth`. The
    /// ring outlives any single run's supersession by design: `DriftDetector`
    /// needs the pattern across runs that `replace` otherwise forgets.
    ///
    /// **Neither is the round ring**, and it remembers the opposite end: the
    /// clause ring takes the INCOMING run's snapshot, while a `RoundRecord` is
    /// built from the run being superseded, because a round can only be
    /// compared against once the round after it exists. So the first replace
    /// against a document contributes nothing, and each one after it files the
    /// run it replaced.
    func replace(run: CompilerRun, diagnostics: [Diagnostic], docId: String) {
        var history = byDoc[docId]?.clauseHistory ?? []
        if let statuses = run.clauseStatuses {
            history.append(statuses)
            if history.count > Self.clauseHistoryDepth {
                history.removeFirst(history.count - Self.clauseHistoryDepth)
            }
        }

        var rounds = byDoc[docId]?.rounds ?? []
        // The outgoing run is whatever finished last. `previewing.remove` runs
        // further down, so the flag `finishedContent` reads is still set here.
        let outgoing = finishedContent(docId: docId)
        if let outgoing {
            rounds.append(RoundRecord(run: outgoing.run))
            if rounds.count > Self.roundHistoryDepth {
                rounds.removeFirst(rounds.count - Self.roundHistoryDepth)
            }
        }
        finishedBeforePreview[docId] = nil

        // The run finished: what is in memory is an answer again, and the
        // sidecar below is about to say the same thing.
        previewing.remove(docId)
        let content = FileContent(run: run, diagnostics: diagnostics,
                                  clauseHistory: history, rounds: rounds)
        byDoc[docId] = content
        persist(docId: docId, content: content)
        // A run that raised nothing clears the badge rather than leaving the
        // previous run's count standing over an empty pane.
        //
        // **"Nothing" means nothing ANYWHERE** (M4 P1). The badge says a
        // finished run left the writer something they have not seen, and since
        // this milestone a run can leave notes in two places — strains here,
        // continuity questions and reader reports in the queue. A badge that
        // counted only this store's rows would clear itself on the very run
        // that queued three questions, which is the one case it exists for.
        let left = diagnostics.count + (run.mintedNotes ?? 0)
        unread[docId] = left == 0 ? nil : left
        version += 1
    }

    /// **Show a run that is still arriving.** The compiler streams its report
    /// section by section, and this is what puts a section on the pane before
    /// the turn it belongs to has ended.
    ///
    /// Three things `replace` does that this deliberately does not, each of
    /// them a defect if a preview did it:
    ///
    /// - **It does not persist.** A preview is not a run that happened. A
    ///   half-report on disk would be read back as the standing answer by the
    ///   next launch, and the writer would have no way to tell it from a check
    ///   that finished.
    /// - **It does not touch either ring.** `DriftDetector` reads a clause
    ///   straining across *consecutive runs*; a preview appending a snapshot
    ///   per section would let one run contribute four, and the pane would
    ///   announce a drift the writer's prose never had. The round ring is the
    ///   same rule from the other end: a round is a run that FINISHED, and a
    ///   half-report filed as one would be compared against the very run still
    ///   producing it. All this does is set the superseded run aside for
    ///   `replace` to file (`finishedBeforePreview`).
    /// - **It does not set the unread badge.** Unread counts notes a finished
    ///   run left somewhere the writer wasn't looking. A preview's notes may
    ///   not survive the turn, and a badge for notes that no longer exist is a
    ///   badge nothing can clear.
    ///
    /// Undone by `discardPreview`; superseded by `replace` when the turn ends.
    func preview(run: CompilerRun, diagnostics: [Diagnostic], docId: String) {
        // The FIRST section of a turn is where the finished run is set aside
        // (see `finishedBeforePreview`); every section after it is already
        // standing over a preview and has nothing to keep.
        if !previewing.contains(docId) { finishedBeforePreview[docId] = byDoc[docId] }
        previewing.insert(docId)
        byDoc[docId] = FileContent(
            run: run, diagnostics: diagnostics,
            clauseHistory: byDoc[docId]?.clauseHistory ?? [],
            rounds: byDoc[docId]?.rounds ?? [])
        version += 1
    }

    /// Take back everything `preview` put on screen for `docId`.
    ///
    /// It re-reads the sidecar, and that is the whole implementation *because*
    /// a preview never wrote one: what is on disk is still the last run that
    /// actually finished, so reading it back is exactly "put the standing
    /// answer back". A document with no finished run reads as nothing, which
    /// is the correct answer for a first check the writer cancelled.
    func discardPreview(docId: String) {
        previewing.remove(docId)
        // The run that was set aside is about to be read back off disk as the
        // standing content, so the shadow has nothing left to protect.
        finishedBeforePreview[docId] = nil
        load(docId: docId)
    }

    /// The writer has the pane in front of them — drop `docId`'s badge.
    ///
    /// Does **not** bump `version`: the notes did not change, and a mounted
    /// pane calls this from its own reaction to a version change (see
    /// `DiagnosticsPane.body`), which a bump here would re-enter.
    func markRead(docId: String) {
        unread[docId] = nil
    }

    func unreadCount(docId: String) -> Int {
        unread[docId] ?? 0
    }

    /// The diagnostics for `docId` that are still trustworthy to show:
    /// drift notes (`anchor == nil`) always qualify; an anchored note only
    /// qualifies while its paragraph's current text still matches the text
    /// the compiler anchored it to. `currentText(paragraphId) == nil` means
    /// the paragraph is gone, which is also not live.
    ///
    /// **Refs are display-only, not liveness.** A note's anchor is its first
    /// resolving ref; the other `refs` are the excerpt chips the pane shows
    /// beside the note. Liveness depends only on the anchor, so changing a
    /// non-anchor ref's paragraph does not dismiss the note.
    func live(docId: String, currentText: (String) -> String?) -> [Diagnostic] {
        guard let content = byDoc[docId] else { return [] }
        return content.diagnostics.filter { diagnostic in
            guard let anchor = diagnostic.anchor else { return true }
            guard let text = currentText(anchor.paragraphId) else { return false }
            return text == anchor.anchorText
        }
    }

    /// Move the delta marker forward without touching this doc's notes.
    ///
    /// The empty-delta run: ops landed that changed no prose — a checkpoint, an
    /// annotation, a paragraph typed and typed back — so there is nothing to
    /// ask the compiler about, but the next run must not read them again.
    /// `replace` cannot do this: it would drop the standing notes for a run
    /// that produced none.
    ///
    /// **A doc with no run record is left alone.** The marker is a property of
    /// a run that happened, and a document nobody has ever checked has nothing
    /// to move; the empty delta on a first run means an empty document, and the
    /// next run's answer is the same either way.
    func advanceMarker(to opId: String, docId: String) {
        guard var content = byDoc[docId] else { return }
        content.run.lastOpId = opId
        byDoc[docId] = content
        persist(docId: docId, content: content)
        version += 1
    }

    /// Remove one diagnostic (the writer answered or ignored it). Persists
    /// immediately. No-op if `docId`/`id` is unknown.
    ///
    /// **Precondition: `docId` is not previewing.** This is the store's third
    /// writer, and the only one that predates streaming — it was written when
    /// every note it could reach belonged to a run that had finished. Against a
    /// preview it would persist the half-report as the standing sidecar, and
    /// two things follow, both silent:
    ///
    /// - a cancelled run's `discardPreview` re-reads that file as "the standing
    ///   answer", and it carries `run.lastOpId` — the marker minted at the
    ///   START of the run — so the next check builds its delta from a position
    ///   this one never reached and the prose it stopped reading is never read;
    /// - a completed run's `replace` supersedes wholesale from the turn's own
    ///   text, which still contains the answered note, so the note comes back
    ///   indistinguishable from an unanswered one and a second answer mints a
    ///   duplicate ruling.
    ///
    /// So it refuses, in memory as well as on disk: a preview's notes are not
    /// the writer's to dismiss, because the run that raised them has not
    /// finished raising them. `DiagnosticsPane.offersDurableActions` is why no
    /// writer can reach this — the refusal here is what makes that a locked
    /// door rather than a hidden handle, and it is the rule any future per-note
    /// mutator inherits.
    func dismiss(_ id: String, docId: String) {
        guard !previewing.contains(docId) else { return }
        guard var content = byDoc[docId] else { return }
        content.diagnostics.removeAll { $0.id == id }
        byDoc[docId] = content
        persist(docId: docId, content: content)
        version += 1
    }

    func lastRun(docId: String) -> CompilerRun? {
        byDoc[docId]?.run
    }

    /// How many clause-status snapshots the drift ring keeps — enough for
    /// `DriftDetector.consecutiveRunsThreshold`'s k=3 pattern with headroom,
    /// small enough that this stays a sidecar rather than a second op log.
    static let clauseHistoryDepth = 5

    /// The drift ring for `docId`, oldest→newest, capped at
    /// `clauseHistoryDepth`. Feeds `DriftDetector.drift` directly.
    func clauseStatusHistory(docId: String) -> [[DiagnosticIngest.ClauseStatus]] {
        byDoc[docId]?.clauseHistory ?? []
    }

    /// How many finished rounds the ring keeps — `clauseHistoryDepth`'s
    /// reasoning, one ring over: enough that a writer can look back over a
    /// pass's recent rounds, small enough that this stays a sidecar.
    static let roundHistoryDepth = 5

    /// The rounds this document has finished, oldest→newest, capped at
    /// `roundHistoryDepth`. Every lane's rounds are in one ring; a caller
    /// comparing rounds filters to its own `passId` (`SinceLastRound`).
    func roundHistory(docId: String) -> [RoundRecord] {
        byDoc[docId]?.rounds ?? []
    }

    /// **The round a run beginning now is briefed against**, and the notes it
    /// raised — the last run that FINISHED against `docId`, whatever lane it
    /// belonged to (the caller matches the lane; this reader has no opinion).
    ///
    /// It is deliberately not the ring: a round's notes are gone the moment
    /// the next round replaces them, so the standing content is the only
    /// place a previous round's PROSE still exists. The ring records that a
    /// round happened and when — enough to date the boundary the pane's count
    /// is measured from, and nothing about what was said.
    ///
    /// **Read at the keystroke, before the run's first section lands.** From
    /// the first closed line onward the standing content is this run's own
    /// preview — asked later, it would brief a round against itself.
    /// `finishedContent` is what makes an answer mid-preview still honest.
    func standingRound(docId: String) -> (record: RoundRecord, notes: [Diagnostic])? {
        guard let content = finishedContent(docId: docId) else { return nil }
        return (RoundRecord(run: content.run), content.diagnostics)
    }

    /// The most recent round number in `passId`'s lane for this document, or
    /// `nil` when the lane has no prior round — which is what makes the next
    /// one round 1.
    ///
    /// The standing run is asked first, because it is the newest round of all
    /// and is not in the ring yet (the ring holds runs that have been
    /// superseded). Then the ring, newest first. A lane is matched exactly:
    /// the passless lane (`nil`) resolves against passless records only, and
    /// since a passless run mints no round number this reader answers `nil`
    /// for it — an ordinary M2 run, not round 1 of nothing.
    ///
    /// **Reads `byDoc` directly, deliberately never the preview shadow
    /// (`finishedContent`, which `standingRound` reads instead) — R1, #42.**
    /// The two answer different questions and must, on purpose, disagree
    /// while a preview stands: this reader answers "which round is this lane
    /// on, the one in flight included", `standingRound` answers "what did the
    /// round BEFORE this one say". Both callers need the in-flight answer —
    /// `CompilerOrchestrator.beginRun`'s round mint, reached only when
    /// `runRequested` finds `!isRunning` (so a run never numbers itself
    /// against itself; `test_theMintNeverAsksLatestRoundWhileARunIsStanding`
    /// pins the guard), and the Review cockpit strip
    /// (`AnnotationsPane.cockpitRound`), which must say "round N" WHILE round
    /// N is still streaming and whose "next round" tooltip
    /// (`ReviewRoundCockpit`'s `runHelp`) names N+1. Routing either through
    /// the shadow would leave both one round behind for the run's whole
    /// duration. Pinned mid-preview by
    /// `test_latestRound_answersTheRoundInFlightWhileAPreviewStands`.
    func latestRound(forPass passId: String?, docId: String) -> Int? {
        guard let content = byDoc[docId] else { return nil }
        if content.run.passId == passId, let round = content.run.round { return round }
        for record in content.rounds.reversed() where record.passId == passId {
            if let round = record.round { return round }
        }
        return nil
    }

    /// The delta marker: the op-log position the last run checked as of.
    func lastOpId(docId: String) -> String? {
        byDoc[docId]?.run.lastOpId
    }

    // MARK: - The cold-start offer's refusal memory

    /// Whether the writer has already told the cold-start offer "Not now" for
    /// `docId`, on this device.
    func hasRefusedColdStart(docId: String) -> Bool {
        refusedColdStart.contains(docId)
    }

    /// Remember the refusal so the offer never renders again for `docId`
    /// (`DiagnosticsPane.showsColdStartOffer`) — persisted immediately, the
    /// same "a decision the writer made must survive a relaunch" discipline
    /// every other write in this store follows. A second refusal of an
    /// already-refused doc is a no-op: nothing changed, nothing to persist
    /// twice, and no `version` bump the pane would re-render for.
    func refuseColdStart(docId: String) {
        guard refusedColdStart.insert(docId).inserted else { return }
        persistRefusedColdStart()
        version += 1
    }

    // MARK: - The writer's ask (editorial letter P2 §3.7)

    /// What the writer has asked of the next run against `docId`, or `nil`
    /// when they have asked nothing. Read by `CompilerOrchestrator.beginRun`
    /// at the keystroke, and by the field that holds it.
    func ask(docId: String) -> String? {
        asks[docId]
    }

    /// **How long an ask may be** (editorial letter P2 Task 7). A worry is a
    /// sentence, not a page: the ask rides every run's briefing as its own
    /// section, and an essay pasted in here would out-argue the writer's own
    /// intent statement about what this round is for. 400 characters is about
    /// three sentences — long enough for "I'm worried the middle sags and I
    /// can't tell whether her voice is distinct from his", short enough that
    /// nothing arriving here can be a second intent.
    ///
    /// Measured on the TRIMMED text, because that is the string that is stored
    /// and briefed; trailing whitespace the writer cannot see must not be what
    /// refuses their sentence.
    static let askLimit = 400

    /// Set — or, with `nil` or blank, clear — the ask for `docId`. Answers
    /// whether it was taken.
    ///
    /// **Trimmed, and an empty ask is a removal rather than an empty string.**
    /// A writer who selects the field's text and deletes it has cleared their
    /// ask, and an empty string kept on disk would brief every later run with
    /// a question mark of nothing. `ask(docId:)` answering `nil` is the one
    /// spelling of "nothing was asked", so there is no second empty state for
    /// the prompt to guard against.
    ///
    /// **Over `askLimit` it REFUSES and writes nothing — `false`, not a throw.**
    /// Nothing here failed: the file system is fine and the store is fine, and
    /// a writer who typed four sentences has done nothing wrong. What they get
    /// is a notice and their own words still in the field to shorten
    /// (`AskField`), which is why the refusal is a value the caller reads
    /// rather than an error it has to catch — and why the stored ask is left
    /// exactly as it was, so a too-long edit never silently clears the ask a
    /// previous round was briefed on.
    ///
    /// Persisted immediately, on `refuseColdStart`'s discipline: a decision
    /// the writer made must survive a relaunch. `version` moves so an
    /// observing field or pane re-reads it — a SwiftUI reader that only
    /// touched `ask(docId:)` would observe nothing, because a plain
    /// Dictionary read through a method is not a tracked access. Neither
    /// happens on a refusal: nothing changed, so nothing needs re-reading.
    @discardableResult
    func setAsk(_ text: String?, docId: String) -> Bool {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.count <= Self.askLimit else { return false }
        if trimmed.isEmpty {
            asks[docId] = nil
        } else {
            asks[docId] = trimmed
        }
        persistAsks()
        version += 1
        return true
    }

    /// `.maugham/diagnostics/<docId>.<slug>.json` — per-device so two
    /// machines running the compiler against the same doc never race each
    /// other's sidecar. `.raw` is interpolated only here (tripwire 24).
    static func sidecarURL(projectRoot: URL, docId: String, device: DeviceSlug) -> URL {
        projectRoot
            .appendingPathComponent(".maugham/diagnostics")
            .appendingPathComponent("\(docId).\(device.raw).json")
    }

    /// `.maugham/diagnostics/cold-start-refused.<slug>.json` — one small
    /// per-device file for the whole project, unlike every other sidecar
    /// here: see `refusedColdStart`'s doc for why a per-doc file would not
    /// work. `.raw` is interpolated only here (tripwire 24) — a second site
    /// in this file rather than the one `sidecarURL` names, because the two
    /// build genuinely different filenames for genuinely different content.
    private static func refusedColdStartURL(projectRoot: URL, device: DeviceSlug) -> URL {
        projectRoot
            .appendingPathComponent(".maugham/diagnostics")
            .appendingPathComponent("cold-start-refused.\(device.raw).json")
    }

    private static func loadRefusedColdStart(
        projectRoot: URL, device: DeviceSlug
    ) -> Set<String> {
        let url = refusedColdStartURL(projectRoot: projectRoot, device: device)
        guard let data = try? Data(contentsOf: url), // adr-0018-ok: diagnostics sidecar, derived, not manuscript
              let docIds = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(docIds)
    }

    private func persistRefusedColdStart() {
        let url = Self.refusedColdStartURL(projectRoot: projectRoot, device: device)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(refusedColdStart.sorted()) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// `.maugham/diagnostics/asks.<slug>.json` — one per-device file for the
    /// whole project, keyed by docId, for the reason `asks` gives. `.raw` is
    /// interpolated only here (tripwire 24), a third site in this file
    /// building a third genuinely different filename.
    static func asksURL(projectRoot: URL, device: DeviceSlug) -> URL {
        projectRoot
            .appendingPathComponent(".maugham/diagnostics")
            .appendingPathComponent("asks.\(device.raw).json")
    }

    private static func loadAsks(
        projectRoot: URL, device: DeviceSlug
    ) -> [String: String] {
        let url = asksURL(projectRoot: projectRoot, device: device)
        guard let data = try? Data(contentsOf: url), // adr-0018-ok: diagnostics sidecar, derived, not manuscript
              let asks = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return asks
    }

    private func persistAsks() {
        let url = Self.asksURL(projectRoot: projectRoot, device: device)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(asks) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func persist(docId: String, content: FileContent) {
        let url = Self.sidecarURL(projectRoot: projectRoot, docId: docId, device: device)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(content) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
