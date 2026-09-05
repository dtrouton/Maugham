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
/// run's diagnostics wholly supersede the previous run's **of the same
/// verb** — there is never more than one check's worth and one round's worth
/// of notes live per document.
///
/// **Two standing slots, one per `RunKind`** (two loops P1 Task 5). Author's
/// ⌘R and Review's Run round are two verbs against the same document, with
/// separate readers and separate briefings; while this file held one standing
/// run they also shared one shelf, so a check landed on top of the round the
/// cockpit was showing and a round took the marker and the notes Author's
/// pane was drawing. Each slot is replaced only by its own kind
/// (`CompilerRun.effectiveKind`), and the readers are split to match:
/// `lastCheck` for Author's pane, `lastRound` for the Review cockpit, both
/// for the drift ring and for `lastRun`.
@Observable @MainActor
final class DiagnosticsStore {
    /// Monotonic; bumped by every mutation (`load`, `replace`, `dismiss`) so
    /// an observing pane can invalidate a cached read without diffing arrays.
    private(set) var version: Int = 0

    /// Per document AND VERB: how many notes a run has landed that the writer
    /// has not had in front of them yet — the picker's unread badge, the Inbox
    /// segment's idiom (`DetailPaneToggle.inboxCount`).
    ///
    /// **In memory only, and deliberately.** Unread is a fact about this
    /// session's attention, not about the document: a project reopened puts
    /// the notes back on the pane where they can be read, and a badge restored
    /// with them would be counting something the writer already answered. The
    /// sidecar stays a record of the run.
    ///
    /// **Keyed by `SlotKey`, for the reason the slots exist at all** (two
    /// loops P1 Task 5, fix round 1). `replace` clears the badge when its run
    /// left nothing, which was right while a replace superseded the other
    /// verb's notes as well — now it does not, so a document-keyed count let a
    /// clean round erase the badge counting a standing check's strains, which
    /// are still on Author's pane, and a clean check erase a round's queued
    /// notes. A run clears its own contribution and no one else's.
    ///
    /// The door is `unreadCount(docId:)`, which SUMS the two: the badge sits
    /// on the pane picker and says how much this document has waiting,
    /// whichever loop left it. Private because `SlotKey` is, which is also
    /// what keeps that sum the only answer anything outside can get.
    private var unread: [SlotKey: Int] = [:]

    private let projectRoot: URL
    private let device: DeviceSlug

    /// **One verb's standing answer**: the run and the notes it raised, kept
    /// together because they are one report and are superseded as one.
    ///
    /// A struct rather than two dictionaries keyed the same way, for the
    /// reason `SlotKey` exists: a run and its notes that can be written
    /// separately are a run and its notes that can disagree about which check
    /// the writer is looking at.
    private struct Standing: Codable, Equatable {
        var run: CompilerRun
        var diagnostics: [Diagnostic]
    }

    private struct FileContent: Codable, Equatable {
        /// **What Author's ⌘R last said about this document.** `nil` for a
        /// document only ever run against from Review — which is exactly what
        /// the Author pane should say about it: no check has been made.
        var check: Standing?
        /// **What Review's last round said about this document**, whatever
        /// lane it was filed in. `nil` for a document only ever checked.
        var round: Standing?
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
        /// **Rounds only** (two loops P1 Task 5). It was a ring of "whatever
        /// finished last" while the two verbs shared one slot, so a ⌘R between
        /// two rounds filed itself as the round the next one was measured
        /// since. A check finishes in its own slot now and contributes
        /// nothing here.
        ///
        /// **What it does not hold is what the rounds FOUND** (M4 P1 Task 5):
        /// that is counted off the queue by `SinceLastRound`, whose boundary is
        /// this record's `at`.
        var rounds: [RoundRecord]

        init(
            check: Standing? = nil, round: Standing? = nil,
            clauseHistory: [[DiagnosticIngest.ClauseStatus]] = [],
            rounds: [RoundRecord] = []
        ) {
            self.check = check
            self.round = round
            self.clauseHistory = clauseHistory
            self.rounds = rounds
        }

        /// The slot a verb's answer stands in — the one place a `RunKind`
        /// becomes a property, so no caller writing one slot can name the
        /// other's field by hand.
        subscript(kind: RunKind) -> Standing? {
            get {
                switch kind {
                case .check: return check
                case .round: return round
                }
            }
            set {
                switch kind {
                case .check: check = newValue
                case .round: round = newValue
                }
            }
        }

        /// **`run`/`diagnostics` are read and never written again.** A sidecar
        /// this build wrote carries `check` and/or `round`; one written before
        /// Task 5 carries a single run at the top level, and which verb it was
        /// is `CompilerRun.effectiveKind`'s answer — the one place that legacy
        /// is stated (tripwire 11: no migration, the old file simply loads).
        private enum CodingKeys: String, CodingKey {
            case check, round, clauseHistory, rounds
            case run, diagnostics
        }

        /// Hand-written so a v1/v2 sidecar (written before these fields
        /// existed) decodes clean instead of failing the whole file — the
        /// same discipline as `CompilerRun.init(from:)`, and with the same
        /// trap: a new field needs its own `decodeIfPresent` line here,
        /// because the property's default is not what a synthesised decode
        /// falls back to.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            check = try c.decodeIfPresent(Standing.self, forKey: .check)
            round = try c.decodeIfPresent(Standing.self, forKey: .round)
            clauseHistory = try c.decodeIfPresent(
                [[DiagnosticIngest.ClauseStatus]].self, forKey: .clauseHistory) ?? []
            rounds = try c.decodeIfPresent([RoundRecord].self, forKey: .rounds) ?? []

            // The legacy shape lands in the slot its own kind names, and never
            // over a slot the new keys already filled: a file carrying both is
            // one this build wrote, and its top-level run would be the stale
            // half of a shape nothing writes any more.
            guard let legacy = try c.decodeIfPresent(CompilerRun.self, forKey: .run)
            else { return }
            let standing = Standing(
                run: legacy,
                diagnostics: try c.decodeIfPresent(
                    [Diagnostic].self, forKey: .diagnostics) ?? [])
            if self[legacy.effectiveKind] == nil { self[legacy.effectiveKind] = standing }
        }

        /// Hand-written for the decoder's other half: the legacy keys are
        /// declared so they can be READ, and Swift will not synthesise an
        /// encoder over a `CodingKeys` carrying a case no property answers to.
        /// Written out, this is also the assertion that the two of them are
        /// never emitted again — a sidecar this build writes has slots and
        /// rings and nothing else.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(check, forKey: .check)
            try c.encodeIfPresent(round, forKey: .round)
            try c.encode(clauseHistory, forKey: .clauseHistory)
            try c.encode(rounds, forKey: .rounds)
        }
    }

    /// **One document's one verb** — the key every piece of per-slot state is
    /// held under.
    ///
    /// A struct rather than a `checkPreviewing`/`roundPreviewing` pair beside
    /// every existing dictionary: parallel dictionaries are two places to
    /// forget one verb, and the bug that would leave is a preview of a check
    /// hiding the round the cockpit is drawing.
    private struct SlotKey: Hashable {
        let docId: String
        let kind: RunKind
    }

    /// **Keyed by document, because the FILE is per document.** The two
    /// standing slots live inside one `FileContent` rather than under two
    /// `SlotKey`s here: the drift ring and the round ring belong to the
    /// document rather than to either verb, and splitting the file across two
    /// dictionary entries would give each verb its own copy of both.
    /// Everything that is genuinely per-verb — which slot is previewing, and
    /// what that preview is standing in front of — is keyed by `SlotKey`.
    private var byDoc: [String: FileContent] = [:]

    /// Slots whose in-memory content is a `preview` — a run still arriving —
    /// rather than a run that finished. Read by `load`, which must not read
    /// the sidecar back over one.
    private var previewing: Set<SlotKey> = []

    /// For a slot whose in-memory content is a preview: the last answer in
    /// that slot that belonged to a run which FINISHED — `replace`'s snapshot
    /// source for the round ring.
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
    private var finishedBeforePreview: [SlotKey: Standing] = [:]

    /// The answer in `docId`'s `kind` slot from the last run that actually
    /// FINISHED — the standing answer, unless a preview has been standing in
    /// for it, in which case the shadow is the only place a finished run can
    /// be.
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
    private func finishedStanding(docId: String, kind: RunKind) -> Standing? {
        let key = SlotKey(docId: docId, kind: kind)
        return previewing.contains(key) ? finishedBeforePreview[key] : byDoc[docId]?[kind]
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

    /// What the writer has asked of the next run, per document PER TEMPO, on
    /// THIS device — "I'm worried the middle sags" (editorial letter P2
    /// §3.7; keyed per `RunKind` as of two loops P1 Task 6).
    ///
    /// **Beside `FileContent` rather than inside it, for `refusedColdStart`'s
    /// reason and one sharper.** An ask is written BEFORE a run, and the
    /// sidecar is written by one: a writer can type an ask into a document the
    /// compiler has never read, and there is no `CompilerRun` to hang it off.
    /// Putting it in the per-doc file would mean fabricating a run that never
    /// happened, and every ask would be lost the moment the writer typed it.
    ///
    /// One small file for the whole project, keyed by ``askKey(docId:kind:)``,
    /// on the same derived-state contract as everything else here — except
    /// that this one is the writer's own words rather than a run's output,
    /// which is why it is persisted the instant it is set rather than at the
    /// next run.
    ///
    /// **Keyed by `(docId, kind)`, not just `docId`.** The check and the round
    /// are different readers of the same document — the ask typed in Author's
    /// header is a worry aimed at the reader who checks, and the one typed in
    /// Review's cockpit is aimed at the editor who runs the round — and a
    /// single shared sentence would mean asking the coach the same question
    /// meant for Gould. `askKey` is the one place the two are joined into a
    /// dictionary key, so nothing else here can drift into keying one kind's
    /// read against the other's write.
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
    /// **A standing preview is never read over, slot by slot.** A run still
    /// arriving is by
    /// construction newer than the sidecar, which holds the last run that
    /// finished — so re-reading the file mid-stream would put an OLDER answer
    /// on a pane whose header says "Checking…". The real caller is
    /// `DiagnosticsPane.onAppear`: a writer who presses ⌘R from the editor and
    /// then opens the pane mounts it mid-check, and without this the report
    /// they came to watch blinks back to the previous run until the next
    /// section lands. `discardPreview` is how a preview is deliberately
    /// dropped, and it clears this first.
    func load(docId: String) {
        let held = RunKind.allCases.filter {
            previewing.contains(SlotKey(docId: docId, kind: $0))
        }
        guard held.count < RunKind.allCases.count else { return }
        let url = Self.sidecarURL(projectRoot: projectRoot, docId: docId, device: device)
        guard let data = try? Data(contentsOf: url), // adr-0018-ok: diagnostics sidecar, derived, not manuscript
              var content = try? Self.makeDecoder().decode(FileContent.self, from: data)
        else {
            // Nothing readable on disk. A slot standing in front of a preview
            // is still newer than the file, so the whole entry is left alone
            // when one is; otherwise this document has no record at all.
            if held.isEmpty { byDoc[docId] = nil }
            version += 1
            return
        }
        for kind in RunKind.allCases {
            if held.contains(kind) {
                // A run still arriving is by construction newer than the file.
                content[kind] = byDoc[docId]?[kind]
            } else if var standing = content[kind] {
                standing.diagnostics = standing.diagnostics.filter { $0.kind != nil }
                content[kind] = standing
            }
        }
        byDoc[docId] = content
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
    /// compared against once the round after it exists. So the first round
    /// against a document contributes nothing, and each one after it files the
    /// round it replaced.
    ///
    /// **Only the run's own slot moves** (two loops P1 Task 5). A check
    /// replaces the standing check and leaves the round the cockpit is showing
    /// byte-identical, and a round replaces the standing round and leaves
    /// Author's notes and delta marker where they were. Both kinds feed the
    /// drift ring — a clause strains across the writer's runs, not across one
    /// verb's — and only a round feeds the round ring.
    func replace(run: CompilerRun, diagnostics: [Diagnostic], docId: String) {
        let kind = run.effectiveKind
        var content = byDoc[docId] ?? FileContent()

        if let statuses = run.clauseStatuses {
            content.clauseHistory.append(statuses)
            if content.clauseHistory.count > Self.clauseHistoryDepth {
                content.clauseHistory.removeFirst(
                    content.clauseHistory.count - Self.clauseHistoryDepth)
            }
        }

        // The outgoing run is whatever finished last IN THIS SLOT, and only a
        // round is filed — a check has no lane and no number, and one filed
        // here would become the round the next round says it is measured
        // since. `previewing.remove` runs further down, so the flag
        // `finishedStanding` reads is still set here.
        let outgoing = finishedStanding(docId: docId, kind: kind)
        if kind == .round, let outgoing {
            content.rounds.append(RoundRecord(run: outgoing.run))
            if content.rounds.count > Self.roundHistoryDepth {
                content.rounds.removeFirst(content.rounds.count - Self.roundHistoryDepth)
            }
        }
        let key = SlotKey(docId: docId, kind: kind)
        finishedBeforePreview[key] = nil

        // The run finished: what is in memory is an answer again, and the
        // sidecar below is about to say the same thing.
        previewing.remove(key)
        content[kind] = Standing(run: run, diagnostics: diagnostics)
        byDoc[docId] = content
        persist(docId: docId, content: content)
        // A run that raised nothing clears ITS OWN badge rather than leaving
        // the previous run's count standing over an empty pane — its own, and
        // not the other verb's, which is what `unread`'s `SlotKey` is for.
        //
        // **"Nothing" means nothing ANYWHERE** (M4 P1). The badge says a
        // finished run left the writer something they have not seen, and since
        // this milestone a run can leave notes in two places — strains here,
        // continuity questions and reader reports in the queue. A badge that
        // counted only this store's rows would clear itself on the very run
        // that queued three questions, which is the one case it exists for.
        let left = diagnostics.count + (run.mintedNotes ?? 0)
        unread[key] = left == 0 ? nil : left
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
    /// **And it stands in one slot only** (two loops P1 Task 5): a check
    /// streaming onto Author's pane leaves the standing round exactly where
    /// the cockpit is drawing it, and the other way round.
    ///
    /// Undone by `discardPreview`; superseded by `replace` when the turn ends.
    func preview(run: CompilerRun, diagnostics: [Diagnostic], docId: String) {
        let key = SlotKey(docId: docId, kind: run.effectiveKind)
        // The FIRST section of a turn is where the finished run is set aside
        // (see `finishedBeforePreview`); every section after it is already
        // standing over a preview and has nothing to keep.
        if !previewing.contains(key) {
            finishedBeforePreview[key] = byDoc[docId]?[key.kind]
        }
        previewing.insert(key)
        var content = byDoc[docId] ?? FileContent()
        content[key.kind] = Standing(run: run, diagnostics: diagnostics)
        byDoc[docId] = content
        version += 1
    }

    /// Take back everything `preview` put on screen for `docId`.
    ///
    /// It re-reads the sidecar, and that is the whole implementation *because*
    /// a preview never wrote one: what is on disk is still the last run that
    /// actually finished, so reading it back is exactly "put the standing
    /// answer back". A document with no finished run reads as nothing, which
    /// is the correct answer for a first check the writer cancelled.
    ///
    /// **`kind` is the run's own, never inferred here.** The caller is holding
    /// the run it is abandoning (`CompilerOrchestrator.discardStreamPreview`),
    /// and a cancel that cleared both slots' previews would take down a report
    /// the writer is watching in the other loop.
    func discardPreview(docId: String, kind: RunKind) {
        let key = SlotKey(docId: docId, kind: kind)
        previewing.remove(key)
        // The run that was set aside is about to be read back off disk as the
        // standing answer, so the shadow has nothing left to protect.
        finishedBeforePreview[key] = nil
        load(docId: docId)
    }

    /// The writer has the pane in front of them — drop `docId`'s badge.
    ///
    /// Does **not** bump `version`: the notes did not change, and a mounted
    /// pane calls this from its own reaction to a version change (see
    /// `DiagnosticsPane.body`), which a bump here would re-enter.
    func markRead(docId: String) {
        for kind in RunKind.allCases { unread[SlotKey(docId: docId, kind: kind)] = nil }
    }

    /// **The badge's one answer, and it is the document's**: what this
    /// document has waiting for the writer, whichever loop left it. The
    /// per-verb keying underneath exists so a run cannot clear the other
    /// verb's count (see ``unread``), not so a surface can ask about one verb
    /// — nothing draws a per-loop badge, and a picker showing two would be
    /// two numbers for one door.
    func unreadCount(docId: String) -> Int {
        RunKind.allCases.reduce(0) { $0 + (unread[SlotKey(docId: docId, kind: $1)] ?? 0) }
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
    ///
    /// **The CHECK slot's notes** (two loops P1 Task 5). These are Author's
    /// rows, and Author's ⌘R is the check. A round's conformance strains are
    /// stored in the round slot and drawn nowhere in P1 — a deliberate carry:
    /// the round's findings reach the writer as annotations in the queue, and
    /// giving its strains a surface is a later task, not something to smuggle
    /// in by pointing Author's pane at whichever run happened to be newer.
    func live(docId: String, currentText: (String) -> String?) -> [Diagnostic] {
        guard let standing = byDoc[docId]?[.check] else { return [] }
        return standing.diagnostics.filter { diagnostic in
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
    /// **A doc with no CHECK record is left alone.** The marker is a property
    /// of a run that happened, and a document nobody has ever checked has
    /// nothing to move; the empty delta on a first run means an empty
    /// document, and the next run's answer is the same either way. A document
    /// that has only ever had rounds run against it is that same case — the
    /// marker is the check loop's position, and a round moves no marker (Task
    /// 4).
    func advanceMarker(to opId: String, docId: String) {
        guard var content = byDoc[docId], var standing = content[.check] else { return }
        standing.run.lastOpId = opId
        content[.check] = standing
        byDoc[docId] = content
        persist(docId: docId, content: content)
        version += 1
    }

    /// Remove one diagnostic (the writer answered or ignored it). Persists
    /// immediately. No-op if `docId`/`id` is unknown.
    ///
    /// **Precondition: `docId`'s CHECK slot is not previewing** — these are
    /// the check's notes, `live`'s rule one verb over. This is the store's third
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
        guard !previewing.contains(SlotKey(docId: docId, kind: .check)) else { return }
        guard var content = byDoc[docId], var standing = content[.check] else { return }
        standing.diagnostics.removeAll { $0.id == id }
        content[.check] = standing
        byDoc[docId] = content
        persist(docId: docId, content: content)
        version += 1
    }

    /// **What Author's ⌘R last said about `docId`** — the standing check
    /// (two loops P1 Task 5). What the Diagnostics pane reports on.
    func lastCheck(docId: String) -> CompilerRun? {
        byDoc[docId]?[.check]?.run
    }

    /// **What Review's last round said about `docId`**, whatever lane it was
    /// filed in — the standing round (two loops P1 Task 5). What the round
    /// cockpit reports on, and where the letter it draws comes from.
    func lastRound(docId: String) -> CompilerRun? {
        byDoc[docId]?[.round]?.run
    }

    /// **The newer of the two standing runs**, and the only reader that mixes
    /// them.
    ///
    /// It exists for the two questions that are about the DOCUMENT rather
    /// than about either loop: `IntentDrift.mayTrailDraft`, whose mark says
    /// the draft may have wandered from the intent and is answered by whoever
    /// judged that last, and the unread badge, which counts what any finished
    /// run left the writer unread. Every other reader wants one verb's answer
    /// and asks `lastCheck` or `lastRound` by name — a surface reading
    /// "whichever ran last" is a surface that changes what it is reporting on
    /// when the writer switches persona.
    ///
    /// A tie goes to the check, which is the loop the intent strip is drawn
    /// in; two runs sharing a whole second is a fixture, not a session.
    func lastRun(docId: String) -> CompilerRun? {
        guard let content = byDoc[docId] else { return nil }
        switch (content[.check]?.run, content[.round]?.run) {
        case (let check?, let round?): return check.at >= round.at ? check : round
        case (let check?, nil): return check
        case (nil, let round?): return round
        case (nil, nil): return nil
        }
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
    /// raised — the last ROUND that FINISHED against `docId`, whatever lane it
    /// belonged to (the caller matches the lane; this reader has no opinion).
    ///
    /// It reads the round slot alone as of two loops P1 Task 5: a check that
    /// landed between two rounds is a different verb's answer, and briefing a
    /// round on it said the previous round had raised what Author's own ⌘R
    /// did.
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
    /// `finishedStanding` is what makes an answer mid-preview still honest.
    func standingRound(docId: String) -> (record: RoundRecord, notes: [Diagnostic])? {
        guard let standing = finishedStanding(docId: docId, kind: .round) else { return nil }
        return (RoundRecord(run: standing.run), standing.diagnostics)
    }

    /// The most recent round number in `passId`'s lane for this document, or
    /// `nil` when the lane has no prior round — which is what makes the next
    /// one round 1.
    ///
    /// The standing ROUND is asked first, because it is the newest round of
    /// all and is not in the ring yet (the ring holds rounds that have been
    /// superseded). A standing check is not consulted at all — it has no lane
    /// and no number. Then the ring, newest first. A lane is matched exactly:
    /// the passless lane (`nil`) resolves against passless records only, and
    /// since a passless run mints no round number this reader answers `nil`
    /// for it — an ordinary M2 run, not round 1 of nothing.
    ///
    /// **Reads `byDoc` directly, deliberately never the preview shadow
    /// (`finishedStanding`, which `standingRound` reads instead) — R1, #42.**
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
        if let run = content[.round]?.run, run.passId == passId, let round = run.round {
            return round
        }
        for record in content.rounds.reversed() where record.passId == passId {
            if let round = record.round { return round }
        }
        return nil
    }

    /// The delta marker: the op-log position the last run checked as of.
    func lastOpId(docId: String) -> String? {
        byDoc[docId]?[.check]?.run.lastOpId
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

    // MARK: - The writer's ask (editorial letter P2 §3.7; per tempo, two loops P1 Task 6)

    /// **Join a document and a tempo into the one key `asks`/`pendingAsks`
    /// are stored under.** The one place `docId` and `kind` combine, so
    /// nothing else here can key a read against one kind and a write against
    /// the other.
    private static func askKey(docId: String, kind: RunKind) -> String {
        "\(docId)#\(kind.rawValue)"
    }

    /// What the writer has asked of the next run of THIS KIND against
    /// `docId`, or `nil` when they have asked nothing of it. Read by
    /// `CompilerOrchestrator.beginRun` at the keystroke, and by the field
    /// that holds it.
    ///
    /// **A check's ask and a round's ask are independent for the same
    /// document.** The reader who checks and the editor who runs the round
    /// are different readers of the same prose, and a worry typed for one is
    /// not automatically a worry typed for the other.
    func ask(docId: String, kind: RunKind) -> String? {
        asks[Self.askKey(docId: docId, kind: kind)]
    }

    /// **What the writer has typed into the ask field but not yet committed**,
    /// per document PER TEMPO, in memory only (editorial letter P2 Task 7, fix
    /// round 1; keyed per `RunKind` as of two loops P1 Task 6).
    ///
    /// **This is not a second source of truth for the ask.** `ask(docId:kind:)`
    /// is the ask; this is a keystroke buffer that exists so a round asked for
    /// while the field still holds uncommitted words is briefed with them —
    /// `commitPendingAsk(docId:kind:)` promotes it through `setAsk` at the top
    /// of every run and it is gone. Keyed through the same ``askKey(docId:kind:)``
    /// as `asks`, so a check's draft can never be promoted into a round's ask.
    ///
    /// Deliberately not persisted and deliberately not `version`-bumping: it is
    /// written on every keystroke, and the whole reason the field commits on
    /// submit rather than on typing is that a real commit rewrites this
    /// project's asks file and re-renders both panes.
    private var pendingAsks: [String: String] = [:]

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

    /// Set — or, with `nil` or blank, clear — the ask for `docId` OF THIS
    /// KIND. Answers whether it was taken.
    ///
    /// **Trimmed, and an empty ask is a removal rather than an empty string.**
    /// A writer who selects the field's text and deletes it has cleared their
    /// ask, and an empty string kept on disk would brief every later run with
    /// a question mark of nothing. `ask(docId:kind:)` answering `nil` is the
    /// one spelling of "nothing was asked", so there is no second empty state
    /// for the prompt to guard against.
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
    /// touched `ask(docId:kind:)` would observe nothing, because a plain
    /// Dictionary read through a method is not a tracked access. Neither
    /// happens on a refusal: nothing changed, so nothing needs re-reading.
    @discardableResult
    func setAsk(_ text: String?, docId: String, kind: RunKind) -> Bool {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.count <= Self.askLimit else { return false }
        let key = Self.askKey(docId: docId, kind: kind)
        // Whatever was pending has now been decided, one way or the other.
        pendingAsks[key] = nil
        if trimmed.isEmpty {
            asks[key] = nil
        } else {
            asks[key] = trimmed
        }
        persistAsks()
        version += 1
        return true
    }

    /// **Note what the writer is typing, without writing anything.** Called on
    /// every keystroke; see ``pendingAsks`` for why that is cheap and why it is
    /// not a commit.
    ///
    /// `nil`/blank is meaningful and is kept as `""` rather than dropped: a
    /// writer who selects their ask and deletes it has withdrawn it, and the
    /// round they then ask for must not be briefed with the sentence they just
    /// removed.
    func notePendingAsk(_ text: String, docId: String, kind: RunKind) {
        pendingAsks[Self.askKey(docId: docId, kind: kind)] = text
    }

    /// **Forget an uncommitted draft entirely** — not the same as noting an
    /// empty one.
    ///
    /// Noting `""` says the writer emptied the field, which a later round
    /// promotes into a withdrawal of the stored ask. This says the draft is
    /// no longer the writer's business at all: the field discards what was
    /// typed about a piece when the writer moves to another one, and the ask
    /// that piece already had must survive that untouched.
    func discardPendingAsk(docId: String, kind: RunKind) {
        pendingAsks[Self.askKey(docId: docId, kind: kind)] = nil
    }

    /// **Promote whatever is in the field into the ask, at the top of a run.**
    ///
    /// The gap this closes: ⌘R is a menu command that never touches the first
    /// responder, so a writer who types a worry and asks for a round without
    /// pressing Return would otherwise have the round briefed on the ask they
    /// had *before*, with the new sentence still on screen in front of them.
    /// Every run trigger goes through `CompilerOrchestrator.beginRun`, which is
    /// the one place that calls this — so the cockpit's buttons and the
    /// cold-start offer are covered by the same line as the two keystrokes.
    ///
    /// **Promotes only the pending draft OF THIS KIND.** A check and a round
    /// against the same document have independent drafts, so beginning a
    /// round must not promote whatever the writer left half-typed in Author's
    /// field, and vice versa.
    ///
    /// **A pending draft that matches the stored ask writes nothing**, so an
    /// ordinary round costs no file write; and one over `askLimit` is refused
    /// by `setAsk` exactly as a submitted one is, leaving the round briefed
    /// with the ask that stands. Answers whether anything changed.
    @discardableResult
    func commitPendingAsk(docId: String, kind: RunKind) -> Bool {
        let key = Self.askKey(docId: docId, kind: kind)
        guard let pending = pendingAsks[key] else { return false }
        let trimmed = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (asks[key] ?? "") else {
            pendingAsks[key] = nil
            return false
        }
        return setAsk(pending, docId: docId, kind: kind)
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
    /// whole project, keyed by ``askKey(docId:kind:)``, for the reason `asks`
    /// gives. `.raw` is interpolated only here (tripwire 24), a third site in
    /// this file building a third genuinely different filename.
    static func asksURL(projectRoot: URL, device: DeviceSlug) -> URL {
        projectRoot
            .appendingPathComponent(".maugham/diagnostics")
            .appendingPathComponent("asks.\(device.raw).json")
    }

    /// **A legacy file written before the ask was per-tempo reads as the
    /// check's** (two loops P1 Task 6). Before this task the whole file was
    /// keyed by bare `docId`, and every ask on disk was Author's — the round
    /// cockpit did not exist to write one — so a bare key with no `#` is
    /// migrated to `askKey(docId:kind:.check)` on load. A key that already
    /// carries a `#` is a new-format key and is kept as written.
    ///
    /// The migration happens here, in memory, rather than as an immediate
    /// rewrite of the file: `asks` is always keyed in the new shape from the
    /// moment this returns, so any later `persistAsks()` — the very next
    /// `setAsk` — writes the whole dictionary back under new keys only, and a
    /// bare key never survives a load-and-save.
    private static func loadAsks(
        projectRoot: URL, device: DeviceSlug
    ) -> [String: String] {
        let url = asksURL(projectRoot: projectRoot, device: device)
        guard let data = try? Data(contentsOf: url), // adr-0018-ok: diagnostics sidecar, derived, not manuscript
              let raw = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        var migrated: [String: String] = [:]
        for (key, value) in raw {
            if key.contains("#") {
                migrated[key] = value
            } else {
                migrated[askKey(docId: key, kind: .check)] = value
            }
        }
        return migrated
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
