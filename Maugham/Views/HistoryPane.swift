// Maugham/Views/HistoryPane.swift
import SwiftUI
import AppKit
import MaughamCore
import os

/// Diagnostic channel for a Retry attempt that leaves a record `.held`
/// (`.stillUnreadable`/`.corrupt`) — the writer sees the standing notice
/// persist; this is the WHY for anyone debugging it. Mirrors
/// `PartialRestorePicker.swift`'s `partialRestoreLog`.
private let historyQuarantineLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham",
    category: "HistoryPaneQuarantine")

// MARK: - History entry + filter

public enum HistoryEntry: Identifiable {
    case op(Op)
    case checkpoint(Checkpoint)

    public var id: String {
        switch self {
        case .op(let op): return "op:\(op.opId)"
        case .checkpoint(let cp): return "cp:\(cp.checkpointId)"
        }
    }
    public var timestamp: Date {
        switch self {
        case .op(let op): return op.at
        case .checkpoint(let cp): return cp.at
        }
    }

    public static func merge(
        ops: [Op], checkpoints: [Checkpoint]
    ) -> [HistoryEntry] {
        var all: [HistoryEntry] = []
        all.append(contentsOf: ops.map(HistoryEntry.op))
        all.append(contentsOf: checkpoints.map(HistoryEntry.checkpoint))
        all.sort { $0.timestamp > $1.timestamp }
        return all
    }
}

public enum HistoryFilter: String, CaseIterable, Identifiable, FilterRowItem {
    case all, checkpoints, edits, annotations, external

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .all: return "All"
        case .checkpoints: return "Checkpoints"
        case .edits: return "Edits"
        case .annotations: return "Annotations"
        case .external: return "External"
        }
    }

    public var symbolName: String {
        switch self {
        case .all: return "circle"           // unused (kept-short)
        case .checkpoints: return "flag.fill"
        case .edits: return "pencil"
        case .annotations: return "bubble.left"
        case .external: return "arrow.down.left"
        }
    }

    public func matches(_ entry: HistoryEntry) -> Bool {
        switch self {
        case .all:
            return true
        case .checkpoints:
            switch entry {
            case .checkpoint: return true
            case .op(let op): return op.kind == .checkpointRestore
            }
        case .edits:
            if case .op(let op) = entry {
                return op.kind == .typingBurst || op.kind == .bootstrap
            }
            return false
        case .annotations:
            if case .op(let op) = entry {
                switch op.kind {
                case .claudeComment, .claudeSuggestion, .claudeAccept,
                     .claudeAcceptRevert, .claudeReject, .claudeArchive,
                     .claudeQuery, .claudeCraftNote:
                    return true
                default: return false
                }
            }
            return false
        case .external:
            if case .op(let op) = entry {
                return op.kind == .externalEdit
            }
            return false
        }
    }
}

// MARK: - HistoryPane view

@MainActor
struct HistoryPane: View {
    let projectURL: URL
    let activeDocId: String
    let allDocIds: [String]
    let device: String
    let session: String
    let docPaths: [String: String]
    let documentStore: DocumentStore?

    @State private var filter: HistoryFilter = .all
    @State private var checkpoints: [Checkpoint] = []
    /// Checkpoint device files `reload()` could not read — name AND reason
    /// (RULING-54: an unreadable file used to read as EMPTY — every checkpoint
    /// from that device silently gone from this pane and from Rewind's
    /// targets). The pane shows a notice when non-empty, with the reasons in
    /// its tooltip: "permission denied" and "couldn't be downloaded" want
    /// opposite responses from the writer. The rows are intact on disk. The
    /// inbox pane's M8-IN-012 shape.
    @State private var unreadableCheckpointFiles: [CheckpointLoad.UnreadableFile] = []
    /// Set-aside (Plan B) op-log files for `activeDocId` still `.held` —
    /// `records(forDocId:in:)` already self-heals a stale `.held` row whose
    /// return actually succeeded, so this list is only ever the genuine
    /// article: history the writer cannot currently see.
    @State private var heldQuarantineRecords: [QuarantineRecord] = []
    /// How many CHANGES were set aside, by the REASON each was set aside for
    /// (signed op log P1; the reasons are P2b's), counting only what the writer
    /// has not yet acknowledged (P2a, D2) and only what is not in their draft
    /// already (P2 smoke, find 7). Counts rather than the records, because the
    /// notice is pure over them and reading the archives is `reload()`'s job,
    /// not `body`'s — and by reason rather than one total, because four of the
    /// six causes describe lines Maugham itself wrote on the writer's other
    /// machine (whole-branch review, I3).
    @State private var setAsideChangesByReason: [String: Int] = [:]
    /// Every set-aside record for this doc, acknowledged or not, by the name it
    /// is acknowledged under. The disclosure below the sentence lists these
    /// REGARDLESS: what an Acknowledge press puts down is the sentence, not the
    /// forensics. Resolved on `reload()` and held, because
    /// `SetAsideAcknowledgement.name(for:in:)` reads the quarantine directory
    /// and a per-row read from `body` is tripwire 4.
    @State private var setAsideRecordNames: [String] = []
    /// The same records as rows the disclosure can act on (P3b Task 8, spec
    /// §7.4): how many paragraphs each would hand back to the Inbox, whether
    /// this Mac has already sent them, and the sentence each is shown under.
    /// Resolved on `reload()` for `setAsideRecordNames`' reason — the count
    /// reads each archive.
    @State private var setAsideRows: [SetAsideDoor.Row] = []
    /// What the last **Send to Inbox** did, or why it could not. Shown on the
    /// row until the next reload, because a press that appeared to do nothing
    /// is worse than a refusal (the Retry notice's own rule).
    @State private var sendToInboxError: String?
    /// **How many waiting paragraphs each unsigned holder has**, and nothing
    /// else about the rows (P3b Task 8; narrowed in fix round 2's I1).
    ///
    /// This half re-runs the walk over the document's files, which is disk work
    /// and never `body`'s (tripwire 4). The SENTENCES are not here: they are
    /// composed in `body` from the live provenance and the live names, because
    /// a snapshot of them taken in `reload()` was taken before `reloadChain()`
    /// had resolved a single name and before a document opening in the same
    /// pass had a provenance at all — so Task 7's held sentences were
    /// intermittently not drawn, and a renamed person's was a reload behind.
    @State private var heldWordCounts: [String: Int] = [:]
    /// Device fingerprint → the name that device's registry record gives it,
    /// for the pending sentence (signed op log P2a). Empty when this project
    /// has no registry, and empty when one could not be read: a name is
    /// decoration on a count, so an unreadable registry costs the writer a code
    /// rather than the sentence. Resolved in `reload()` because reading it is
    /// disk work (tripwire 4).
    @State private var chainDeviceNames: [String: String] = [:]
    /// Whose chain this Mac is on, already as the sentence — nil when it has
    /// joined nobody's. The whole line rather than the root's fingerprint,
    /// because both halves it is built from (this device's registry memory and
    /// the people records) are resolved in the same off-actor read.
    @State private var joinedChainLine: String?
    /// **What retirement means, on the machine that did it** (fix round 1,
    /// Important 2). Nil until this Mac has retired itself in this book; a
    /// standing fact afterwards, drawn with no control, because there is
    /// nothing to press — a device cannot be un-retired.
    @State private var retirementLine: String?
    /// The project's dated trust events, already as drawn rows (signed op log
    /// P2b, ruling C). Resolved in `reloadChain` beside the names they are told
    /// in, because both come out of the same off-actor registry read.
    @State private var trustEventLines: [TrustEventLine] = []
    /// **History this Mac remembers and cannot find** (P3b Task 6): a stream
    /// found shorter than it was, or one the folder holds no file of at all.
    /// Resolved off the main actor with the registry read that names each
    /// device, like everything else here that touches disk (tripwire 4).
    @State private var lostHistoryRows: [LostHistoryRow] = []
    @State private var isRetryingQuarantine: Bool = false
    /// The report from the most recently completed Retry, kept only long
    /// enough for the writer to view or dismiss it — cleared when the sheet
    /// closes. Nil whenever nothing has just been recovered.
    @State private var recoveredReport: RecoveredHistoryReport?
    @State private var showingRecoveredHistorySheet: Bool = false
    @State private var ops: [Op] = []
    @State private var expanded: Set<String> = []
    @State private var selectedCheckpoint: Checkpoint?
    @State private var showingRestorePicker: Bool = false
    /// Hosting window for the ADR 0021 project scope + closed-window liveness
    /// guard on `.maughamCheckpointAdded`.
    @State private var window: NSWindow?

    /// What the OPEN document's load found out about its own history (signed
    /// op log P1). Nil when this doc is not open — the counts are a property of
    /// a load, and this pane must not perform one of its own to invent them.
    private var documentProvenance: OpLogProvenance? {
        documentStore?.document(forDocId: activeDocId)?.provenance
    }

    private var entries: [HistoryEntry] {
        HistoryEntry.merge(ops: ops, checkpoints: checkpoints)
            .filter { filter.matches($0) }
    }

    /// Index of ops by op_id for HistoryRow's sourceAnnotationId lookups
    /// (used to surface the body of an annotation whose archive row
    /// otherwise only shows "paragraph deleted").
    private var opsByOpId: [String: Op] {
        var map: [String: Op] = [:]
        for op in ops { map[op.opId] = op }
        return map
    }

    /// Each op's immediate predecessor in the opId-ordered log, keyed by opId.
    /// "Rewind to before this…" opens the rewind at the PREDECESSOR — the
    /// state the row's op destroyed, not the state it produced. Posting the
    /// row's own op landed the writer AFTER it, because `derive(upTo:)` is
    /// inclusive by contract (RULING-22 disposition 2026-08-08, M4-RW-002).
    /// The first op has no entry: there is no "before" to offer.
    static func predecessorIndex(ops: [Op]) -> [String: Op] {
        var map: [String: Op] = [:]
        map.reserveCapacity(max(ops.count - 1, 0))
        for i in 1..<max(ops.count, 1) {
            map[ops[i].opId] = ops[i - 1]
        }
        return map
    }

    private var emptyTitle: String {
        switch filter {
        case .all:         return "No history yet"
        case .checkpoints: return "No checkpoints"
        case .edits:       return "No edits"
        case .annotations: return "No annotations"
        case .external:    return "No external edits"
        }
    }

    private var emptySymbol: String {
        switch filter {
        case .all:         return "clock.arrow.circlepath"
        case .checkpoints: return "flag"
        case .edits:       return "pencil"
        case .annotations: return "bubble.left.and.bubble.right"
        case .external:    return "arrow.down.doc"
        }
    }

    private var emptyHint: String {
        switch filter {
        case .all:
            return "Type, take a checkpoint, or ask Claude for feedback — your activity will show up here."
        case .checkpoints:
            return "Press ⌘⇧S to capture a named checkpoint, or ⌘S to auto-checkpoint."
        case .edits:
            return "Typing bursts appear here every 30 seconds while you work."
        case .annotations:
            return "Ask Claude to comment or suggest a change — annotations land here as a forensic record."
        case .external:
            return "External edits to the .md file (e.g. via another editor or sync) show up here."
        }
    }

    /// The notice shown when checkpoint device files can't be read — nil when
    /// everything read cleanly. Static so the copy is pinnable without a
    /// window mount (the `predecessorIndex` pattern).
    static func unreadableCheckpointNotice(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        return "Some checkpoints can’t be read (\(names.joined(separator: ", "))). "
             + "They are still in the file — check permissions or iCloud sync."
    }

    /// The notice's tooltip: one "name — reason" line per unreadable file, so
    /// the WHY reaches the writer ("permission denied" is fixed here;
    /// "couldn't be downloaded" is fixed by getting online).
    static func unreadableCheckpointDetail(_ files: [CheckpointLoad.UnreadableFile]) -> String? {
        guard !files.isEmpty else { return nil }
        return files.map { "\($0.name) — \($0.reason)" }.joined(separator: "\n")
    }

    /// The standing notice for set-aside (Plan B quarantine) history — nil
    /// once nothing is held (nothing was ever set aside, or Retry brought
    /// everything back). Pinnable without mounting, like the checkpoint
    /// notice above. The sentence names what happened ("set aside") rather
    /// than the internal term ("quarantine") — CLAUDE.md's writer-facing
    /// copy rule. The row's "Retry" control sits beside this text in body;
    /// read together they form the quoted UX copy the spec names.
    ///
    /// `heldCount` is the count of `.file` records ONLY — a whole per-device
    /// op-log file that could not be read, which is the thing "Retry" can
    /// bring back. A `.lines` record has no file waiting to return and speaks
    /// through `setAsideLinesNotice` instead.
    static func quarantineNotice(heldCount: Int) -> String? {
        guard heldCount > 0 else { return nil }
        return "Part of this document’s history is set aside (couldn’t be read when it was)."
    }

    /// What this document's history is made of that this Mac cannot vouch for
    /// (signed op log P1) — nil when there is nothing to say.
    ///
    /// Two causes, and they are different facts. **Legacy**: lines written
    /// before this milestone existed, which no key can ever sign retroactively;
    /// every manuscript that predates the signed op log answers yes forever, so
    /// the sentence states it rather than warning about it. **Foreign**: lines
    /// under a seal from a key this device does not trust — in P1 that is every
    /// other device, the writer's own phone included. `unsealed` lines are the
    /// ordinary state between seals and are deliberately NEVER mentioned: the
    /// live tail is always partly unsealed, so naming it would be a permanent
    /// notice about nothing.
    ///
    /// When BOTH are true this is ONE sentence carrying both — the coalescing
    /// rule (`Maugham/OpLog/AREA.md`, "The Document's one writer-facing
    /// channel"): the notice slot holds one sentence, and two stacked notices
    /// about the same subject read as two problems.
    static func unsignedHistoryNotice(provenance: OpLogProvenance?) -> String? {
        guard let provenance else { return nil }
        let legacy = provenance.hasLegacyHistory
        let foreignCount = provenance.unsignedHistoryLines
        guard legacy || foreignCount > 0 else { return nil }
        let foreignClause = foreignCount == 1
            ? "1 change from another device is applied as unsigned history"
            : "\(foreignCount) changes from another device are applied as unsigned history"
        if legacy && foreignCount > 0 {
            return "Part of this document’s history was written before this book "
                 + "was signed, and \(foreignClause)."
        }
        if legacy {
            return "Part of this document’s history was written before this book was signed."
        }
        return "\(foreignClause)."
    }

    /// What was NOT applied: lines in one of this document's op-log files that
    /// something other than Maugham wrote. They are kept as forensics and there
    /// is nothing to bring back, so this notice carries no Retry — unlike
    /// `quarantineNotice`, whose subject is a whole file that may yet read.
    ///
    /// **The sentence says WHY, because since revocation there are six whys**
    /// (whole-branch review, I3).
    ///
    /// Until P2b every `.lines` record meant one thing — a line something other
    /// than Maugham had written into a file — and this sentence said so
    /// unconditionally. Revocation, retirement, the late/backdated split and
    /// another claimant's chain are four more causes, and every one of them
    /// describes lines MAUGHAM wrote, on the writer's own other machine. A
    /// writer who revokes their old Mac and is then told *something that is not
    /// Maugham* wrote those changes has been misinformed about their own book
    /// by the one screen that exists to tell them the truth about it.
    ///
    /// So the reasons come in and each gets its own clause. The words are
    /// `JSONLAppendStore.quarantineReason`'s, which the records already carry —
    /// derived from the cause and never spelled twice, so this pane cannot file
    /// an event under a sentence of its own.
    ///
    /// Ordered by count, then alphabetically, so one folder answers one way
    /// however its sidecars happened to be enumerated.
    ///
    /// Pure over the counts, so the copy pins without a window and without
    /// disk. The counts come from `setAsideChangesByReason`, which is the half
    /// that has to read files.
    ///
    /// **The composition is `SetAsideDoor.notice`'s since P3b Task 8** (carry
    /// C1): the Inbox's twin was still reason-blind, so the two panes described
    /// the same event differently. What stays here is only what a DOCUMENT's
    /// refusal costs the writer — the noun, and that the change was not
    /// applied.
    static func setAsideChangesNotice(byReason: [String: Int]) -> String? {
        func changes(_ count: Int) -> String {
            count == 1 ? "1 change" : "\(count) changes"
        }
        return SetAsideDoor.notice(
            byReason: byReason,
            subject: { "\(changes($0)) to this document" },
            clause: changes,
            ending: "kept in backup, not applied")
    }

    /// How many CHANGES were set aside, **under each reason they were set aside
    /// for**, and **not counting one the writer already has**.
    ///
    /// The enumeration is `OpLogQuarantine.setAsideChanges`' — the Inbox pane
    /// asks the same question of the manifest stream, and two copies would be
    /// two answers. It is asked ONCE over every record rather than once per
    /// reason, because dedup is across records: an op set aside twice under two
    /// reasons is one change, and a per-reason call could not see that.
    ///
    /// `applied` is the op ids this document is currently carrying. A `.lines`
    /// record is permanent evidence and the disclosure lists it forever, but
    /// once the writer admits the device those ops are in the draft and *set
    /// aside* has stopped being true of them (P2 smoke, find 7).
    ///
    /// **The derivation moved to `SetAsideDoor` in P3b Task 8** so the Inbox
    /// pane can ask the same question of the manifest stream (carry C1); this
    /// is the ask, kept under its own name because the pane and its suite have
    /// always called it that.
    static func setAsideChangesByReason(
        records: [QuarantineRecord], in projectURL: URL, applied: Set<String> = [],
        nowKeepsNothing: (QuarantineRecord) -> Bool? = { _ in nil }
    ) -> [String: Int] {
        SetAsideDoor.changesByReason(
            records: records, in: projectURL, applied: applied,
            nowKeepsNothing: nowKeepsNothing)
    }

    /// The notice shown after a Retry completes. Zero orphans is
    /// unconditionally honest as "nothing was missing" — that covers both a
    /// genuinely redundant return (sync already delivered the same history)
    /// and a returned file that turned out to hold nothing new (including
    /// the zero-byte-file case), because in both the merged draft already
    /// has everything the recovered file has.
    static func recoveredHistoryNotice(orphanCount: Int) -> String {
        guard orphanCount > 0 else {
            return "Recovered history merged — nothing was missing"
        }
        let plural = orphanCount == 1 ? "" : "s"
        let verb = orphanCount == 1 ? "isn’t" : "aren’t"
        return "\(orphanCount) paragraph\(plural) from the recovered history \(verb) in your draft — View"
    }

    /// The notice for a Retry where NOTHING came back — every held record is
    /// still unreadable or still torn. The pressed button did something and
    /// said nothing before this (the review's I2): a control that looks dead
    /// is worse than a refusal, and the standing notice above it does not
    /// change, so silence reads as "the press didn't register". Names the
    /// first reason, because the reasons want opposite responses from the
    /// writer ("permission denied" is fixed here; a torn file is not fixable
    /// by pressing again). Writer-voiced — "set aside", never the internal
    /// term.
    static func stillHeldNotice(reason: String) -> String {
        "That part of this document’s history still can’t be read, so it stays "
        + "set aside (\(reason))."
    }

    // MARK: - The chain (signed op log P2a)

    /// The pending line's control, as constants `body` reads rather than
    /// literals inside it.
    ///
    /// It is the ONE History line that carries a control (spec §6), because
    /// held history is the one thing on this list the writer can act on: every
    /// other sentence here is a statement of fact. P2a DRAWS it; P2b wires it
    /// to the admission sheet, and flipping `admitIsAvailable` is what that
    /// costs here. Constants because the decision — drawn, live, and what it
    /// says — is then pinnable with no window at all (tripwire 33: no test
    /// presses a mounted control and waits for its effect).
    ///
    /// P2b's wiring is what the press does: it asks this window to put the
    /// admission sheet up (`MaughamEvent.postAdmissionRequested(forced:)`),
    /// which is the writer's own ask and therefore reopens a sheet they
    /// dismissed earlier in this session. The disabled shape's own sentence is
    /// GONE (P2b Task 4's minor (c)): it was kept for a test that never read it
    /// and for a day that has arrived the other way round, and a constant
    /// nothing reads is a sentence nobody maintains.
    ///
    /// **`admitIsAvailable` went the same way** (P2b Task 10). It was the
    /// not-yet flag, and once the wiring landed it was a `true` gating a
    /// `.disabled(!true)` — a control that reads as conditionally live and
    /// cannot be anything but live. A flag whose every reader is its own
    /// constant is worse than none: the next writer of this file has to prove
    /// it is still dead before touching it.
    static let admitTitle = "Admit…"
    static let admitHelp = "Say who this device belongs to, and apply what it wrote"

    /// What is HELD — history written by a device this book's chain says
    /// nothing about, kept out of the draft until the writer admits it (spec
    /// §3). Nil when nothing is waiting.
    ///
    /// **Nothing is ever waiting on a device with no chain** (decision B3): a
    /// device no root names judges nobody, so every foreign key falls back to
    /// P1 and its lines are APPLIED as unsigned history — which the sentence
    /// above says. That case reaches here as a zero count and this notice is
    /// absent.
    ///
    /// **One device is named; several are counted.** With one, the writer can
    /// act on a name — the device record's own where the registry holds one,
    /// else its code, which is what that device shows for itself. With several,
    /// naming them all would be a list inside a caption, so People & Devices
    /// holds the roll and this says how many.
    ///
    /// `names` maps a DEVICE fingerprint to its record's name. It is an
    /// argument rather than a lookup because the trust table carries no names
    /// (it answers verdicts and names nobody, deliberately) and because a
    /// notice that read the registry would do disk I/O on every `body` pass
    /// (tripwire 4). `reload()` resolves it.
    ///
    /// This is a separate sentence from `unsignedHistoryNotice` rather than a
    /// coalesced one: the pane's coalescing rule is per SUBJECT — one sentence
    /// about one thing — and applied-anyway and held-back are two things with
    /// two different offers, only one of which the writer can answer.
    nonisolated static func pendingNotice(
        provenance: OpLogProvenance?, names: [String: String]
    ) -> String? {
        // **Strangers only** (P3a Task 5's D5). `hasPendingHistory` is every
        // held line; this sentence ends in *waiting for admission*, and a line
        // held because its signer's permit is one this build cannot judge
        // belongs to a device the writer has already admitted. Under P3a such
        // a line is held silently; P3b gives it a surface of its own.
        guard let provenance, provenance.hasPendingAdmission else { return nil }
        // **The OP lines, not the line tally** (whole-branch review, I1). This
        // sentence puts the word "notes" after its number and the admission
        // sheet puts "notes waiting" after its own, and the two were counting
        // different things: `pendingLines` includes the seal line that holds a
        // span, so two held ops read as *3 notes* here and as *2 notes* on the
        // sheet about the same device. `pendingOpLines` is the sum of the very
        // map `AdmissionDecision.requests` is built from, so the agreement is
        // by construction rather than by two files staying in step.
        let total = provenance.pendingStrangerOpLines
        // A pending span that is nothing but a seal (two adjacent seal lines)
        // is held history with no note in it. There is no number to say and no
        // device to name, and Admit… would find nothing — so this goes quiet
        // rather than reporting *1 note from another device*.
        guard total > 0 else { return nil }
        let devices = provenance.pendingStrangersByDevice.keys.sorted()
        // **What they ARE** (P3b smoke find F2), from the load's own
        // description of the same held lines — *1 paragraph*, not *1 note*,
        // where a stranger's line is prose. The plain count stands where the
        // load had nothing to describe.
        let described = devices
            .compactMap { provenance.pendingWaitingByDevice[$0] }
            .reduce(HeldLines.Waiting()) { $0.merged(with: $1) }
            .phrase
        let noun = described?.text ?? (total == 1 ? "1 note" : "\(total) notes")
        let verb = (described?.isPlural ?? (total != 1)) ? "are" : "is"
        let who: String
        if devices.count > 1 {
            who = "\(devices.count) devices"
        } else if let device = devices.first {
            who = names[device] ?? DeviceCode.short(device)
        } else {
            // Unreachable while `total` comes from the same map — a positive
            // sum has at least one key. Kept because going quiet about history
            // that is not in the draft would be the one unacceptable answer if
            // that ever stopped being true.
            who = "another device"
        }
        return "\(noun) from \(who) \(verb) waiting for admission."
    }

    /// **The held lines that are NOT waiting for admission** (P3b Task 7,
    /// closing Task 2's review I1).
    ///
    /// P3a and P3b each added a reason to hold a line that has nothing to do
    /// with letting a device in — an admitted person's line this build cannot
    /// judge, one that opened a piece nobody has claimed, and a stream nothing
    /// signs after the first narrowing — and all three were held SILENTLY: the
    /// sentence above narrows to strangers on purpose, and nothing else said
    /// anything at all. Words outside the draft with no sentence anywhere is
    /// the one shape a refusal may not take.
    ///
    /// **`HeldLines` decides all of it**, both who each holder is and what to
    /// say about them. This function chooses only the ORDER, which is the
    /// holder's own string, so two reloads over one document say the same
    /// things in the same sequence.
    ///
    /// The stranger split is the one the LOAD stamped, so no registry is read
    /// on a draw (tripwire 4); `startedAPiece` is the walk's own answer, off
    /// the open document.
    nonisolated static func heldLineNotices(
        provenance: OpLogProvenance?, startedAPiece: Set<String>,
        names: [String: String]
    ) -> [String] {
        heldLineRows(
            provenance: provenance, startedAPiece: startedAPiece, names: names
        ).map(\.sentence)
    }

    /// **The same notices, as rows that can carry a control** (P3b Task 8 fix
    /// round 1, spec §7.4).
    ///
    /// One of the three reasons a line is held has no way in but this: a
    /// stream nothing signs cannot be admitted, because there is no key to
    /// admit, and no `.lines` record is ever written for it because nothing is
    /// wrong with its bytes. So the unsigned row offers **Send to Inbox** — the
    /// same offer the set-aside disclosure makes, over words the book is
    /// HOLDING rather than words it refused.
    ///
    /// `words` is the walk's own count, resolved on a reload by
    /// `DocumentStore.unsignedHeldWordCounts` — never here, and never from
    /// `body`: reading it re-runs the walk over that document's files. A holder
    /// missing from the map offers nothing, which is the right answer for a
    /// re-read that would not read as well as for one that found no prose.
    ///
    /// `heldLineNotices` is this function's sentences, kept under its own name
    /// because the pane and its suite have always called it that.
    nonisolated static func heldLineRows(
        provenance: OpLogProvenance?, startedAPiece: Set<String>,
        takenFrom: Set<String> = [],
        names: [String: String], words: [String: Int] = [:],
        sent: [String: Set<String>] = [:], docId: String = ""
    ) -> [SetAsideDoor.HeldRow] {
        guard let provenance else { return [] }
        let strangers = Set(provenance.pendingStrangersByDevice.keys)
        return provenance.pendingByDevice.keys.sorted().compactMap { holder in
            let who = HeldLines.holder(
                of: holder, isAStranger: strangers.contains(holder),
                startedAPiece: startedAPiece.contains(holder))
            // A stranger's is the sentence above, with its own control.
            guard case .stranger = who else {
                // **What the lines ARE** (P3b smoke find F2): Kit's paragraph
                // read *1 note is waiting in a piece no one has claimed yet*.
                guard let sentence = HeldLines.sentence(
                    who, notes: provenance.pendingByDevice[holder] ?? 0,
                    what: provenance.pendingWaitingByDevice[holder],
                    named: names[holder],
                    pieceWasTakenFromThem: takenFrom.contains(holder))
                else { return nil }
                // **The door is the unsigned arm's alone.** An admitted
                // person's held line is let in by a later build or by the
                // writer's own answer about a piece, and both of those APPLY
                // it — offering to copy it out as a capture beside them would
                // be a second, worse way in for words that have a real one.
                let unsigned: Bool
                if case .unsigned = who { unsigned = true } else { unsigned = false }
                return SetAsideDoor.HeldRow(
                    holder: holder,
                    sentence: sentence,
                    unsent: unsigned ? (words[holder] ?? 0) : 0,
                    sentCount: unsigned
                        ? (sent[SetAsideDoor.heldKey(
                            docId: docId, holder: holder)]?.count ?? 0)
                        : 0)
            }
            return nil
        }
    }

    // MARK: - History this book is missing (signed op log P3b Task 6)

    /// One drawn row of lost history: the sentence, and whether the writer has
    /// put it down.
    ///
    /// A value built once per reload rather than in `body` (tripwire 4), and
    /// decided in `OpLogStore.lostHistory` rather than here — the pane draws a
    /// row and presses a verb; what is missing from this book is the op log's
    /// own question.
    struct LostHistoryRow: Identifiable, Equatable {
        let streamKey: String
        /// What is gone, in the writer's words, with what acknowledging it did
        /// appended once it has been.
        let sentence: String
        let acknowledged: Bool
        let noticedAt: Date?

        var id: String { streamKey }
    }

    /// Findings → rows. Pure, so the whole drawer is pinnable with no window.
    ///
    /// **An acknowledged row STAYS**, in the register the rest of this pane
    /// uses for a statement of fact: the history is still gone, so the sentence
    /// is still true. What changes is the colour, the button and the second
    /// sentence — because a press that made the row disappear would look like
    /// the loss had been undone.
    nonisolated static func lostHistoryRows(
        _ lost: [OpLogStore.LostHistory]
    ) -> [LostHistoryRow] {
        lost.map { one in
            LostHistoryRow(
                streamKey: one.streamKey,
                sentence: one.acknowledged
                    ? one.sentence + " " + OpLogStore.LostHistory.acknowledgedSentence
                    : one.sentence,
                acknowledged: one.acknowledged,
                noticedAt: one.noticedAt)
        }
    }

    /// What Acknowledge says it is for. It is not *dismiss*: it is the writer
    /// telling this Mac that the history is gone, which is the only thing that
    /// stops the book waiting for it before it will change what somebody may
    /// write.
    ///
    /// **And what it costs, before the press** (fix round 1, Important 1). The
    /// cost was stated only in the row AFTER the act, which is the wrong half
    /// of it: a writer pressing this on a stream that is merely mid-sync has
    /// taken on that everything it eventually delivers is judged as written
    /// after whatever they decide in the meantime. The clause is
    /// `LostHistory.costOfAcknowledging`'s — one spelling, read here and
    /// repeated in the row, never written twice.
    static let acknowledgeLostHelp =
        "I know this history is gone — stop waiting for it before changing "
        + "what somebody may write in this book. "
        + OpLogStore.LostHistory.costOfAcknowledging

    /// Whose chain this Mac is on — nil when it has joined nobody's.
    ///
    /// A Mac that is its own root joins nothing (B1, asked as
    /// `TrustTable.ownRootRecord` — the record, never which arm of the root
    /// order won): there is no chain of somebody else's for it to be on, and
    /// the cache records only a FOREIGN root. So the ordinary single-Mac
    /// project never sees this line, and a Mac admitted to another's book
    /// always does. `DeviceStanding` is the same fact said in full, and is what
    /// People & Devices and the phone's Settings row both draw.
    ///
    /// A second root that names this device is a CLAIMANT, not a new chain
    /// (`RegistryCache.join` is write-once), so this goes on naming the chain
    /// this Mac is actually on however many roots claim it. The claimants are
    /// P2b's People & Devices to show.
    ///
    /// **A fact, not an event** (Denver's ruling C, 2026-09-10). P2a wrote this
    /// as *This Mac JOINED …*, which is something that happened on a day; the
    /// banner is for what holds NOW, so it says *is on*, and the joining — with
    /// its date — is a `TrustEvent` in the section below. The two are the same
    /// fact told in the two shapes ruling C separates, which is why this line
    /// stays here rather than being replaced by the entry.
    ///
    /// `labels` maps a person fingerprint to the label its record gives them,
    /// for the same reason `pendingNotice` takes `names`.
    /// **What retirement means, told to the machine that did it** (fix round 1,
    /// Important 2).
    ///
    /// A pure function of this device's own standing, so the pane's decision —
    /// draw it, and in whose words — is assertable with no window and no disk.
    /// The noun is `"Mac"` because this app IS one; the phone asks the same
    /// value for the same sentence with its own noun (tripwire 19), which is
    /// why the words live in `DeviceStanding` and not here.
    ///
    /// Nil while this Mac is still at work — the ordinary case. The banner is a
    /// standing FACT and carries no control: there is nothing to press, because
    /// a device cannot be un-retired.
    nonisolated static func retirementNotice(standing: DeviceStanding) -> String? {
        standing.retirementNotice(device: "Mac")
    }

    nonisolated static func joinedChainNotice(
        cache: RegistryCache, projectURL: URL, labels: [String: String]
    ) -> String? {
        guard let root = cache.joinedRoot(for: projectURL) else { return nil }
        return "This Mac is on \(labels[root] ?? DeviceCode.short(root))’s chain."
    }

    // MARK: - The project's trust log (signed op log P2b, ruling C)

    /// The heading over History's project-scope section.
    ///
    /// One word, because the timeline below it is this DOCUMENT's and these
    /// entries are the BOOK's: who was let in, who was shown out, which Macs
    /// claim it. They do not change when the writer opens another chapter, and
    /// the heading is what says so.
    static let projectSectionTitle = "Project"

    /// One drawn row: the sentence, the day it happened on where anything
    /// stamps one, and an icon.
    ///
    /// Built once per reload rather than per row (tripwire 4) — and, more to
    /// the point, built OFF the main actor with the registry read that supplies
    /// its names, so `body` does no work at all beyond drawing it.
    struct TrustEventLine: Identifiable, Equatable {
        let id: String
        let sentence: String
        /// Nil for the two honestly undated events — a claimant, and a join
        /// from a memory written before P2b stamped one. The row draws no date
        /// rather than inventing one.
        let date: Date?
        let symbol: String
    }

    /// Events → rows. Pure, so the whole section is pinnable with no window.
    ///
    /// **A row about somebody this book has no record for says why it names
    /// four characters** (P3b Task 7 fix round 1, I2). The clause is
    /// `TrustEventSentence.unknownSubject`'s — beside the sentence rather than
    /// inside it, because the sentence is shared with the phone and pinned to
    /// the byte on both sides — and this is the one place the two are joined.
    /// The commonest case is not a mystery machine but an ordinary lag: the
    /// event synced and the person record has not.
    nonisolated static func trustEventLines(
        _ events: [TrustEvent], labels: [String: String]
    ) -> [TrustEventLine] {
        events.map { event in
            let sentence = TrustEventSentence.sentence(for: event, labels: labels)
            let clause = TrustEventSentence.unknownSubject(
                for: event, labels: labels)
            return TrustEventLine(
                id: event.id,
                sentence: clause.map { "\(sentence) \($0)" } ?? sentence,
                date: event.date,
                symbol: symbol(for: event.kind))
        }
    }

    /// The icon for one kind. Exhaustive over `TrustEvent.Kind` on purpose: a
    /// kind added later has to be given a face here rather than defaulting into
    /// somebody else's.
    nonisolated static func symbol(for kind: TrustEvent.Kind) -> String {
        switch kind {
        case .admitted, .silentlyAdmitted: return "person.badge.plus"
        // The same face as an admission: somebody let back in came IN, and the
        // sentence beside it is where the writer reads that there was something
        // before.
        case .readmitted: return "person.badge.plus"
        // A permit change is neither an arrival nor a departure — it is a
        // change to what one person may write — so it takes the face the app
        // uses for a person's own settings rather than either of the two.
        case .roleChanged, .scopeChanged: return "person.crop.circle.badge.checkmark"
        case .revoked: return "person.badge.minus"
        // The same face: it is the same act, and the sentence beside it is
        // where the writer reads which of the two they chose.
        case .revokedEntirely: return "person.badge.minus"
        case .retired: return "moon.zzz"
        case .claimed: return "flag"
        case .adopted: return "arrow.triangle.merge"
        case .joined: return "link"
        case .anotherClaimant: return "exclamationmark.triangle"
        case .recordRestored: return "arrow.uturn.backward.circle"
        // Not a person at all: a stream this book can name no key for. The
        // question-mark face rather than a warning triangle, because nothing is
        // wrong — the words are waiting, not refused (P3b Task 10).
        case .unsigned: return "person.fill.questionmark"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            filterToolbar
            Divider()
            if let notice = Self.unreadableCheckpointNotice(unreadableCheckpointFiles.map(\.name)) {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(Self.unreadableCheckpointDetail(unreadableCheckpointFiles) ?? "")
                    // .help is hover-only; the WHY must reach VoiceOver too.
                    .accessibilityHint(Text(
                        Self.unreadableCheckpointDetail(unreadableCheckpointFiles) ?? ""))
                Divider()
            }
            if let notice = Self.quarantineNotice(heldCount: heldQuarantineRecords.count) {
                HStack(spacing: 8) {
                    Label(notice, systemImage: "arrow.uturn.backward.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer(minLength: 4)
                    Button("Retry", action: retryQuarantine)
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                        .disabled(isRetryingQuarantine)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            // Signed op log P1's two statements of fact. Orange and caption
            // like the notices above, but with NO control beside them: neither
            // is something the writer can act on. Unsigned history is history —
            // it stays unsigned. Set-aside lines are kept in the backup and are
            // never applied. Saying so is the whole job.
            if let notice = Self.unsignedHistoryNotice(provenance: documentProvenance) {
                Label(notice, systemImage: "signature")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            if let notice = Self.setAsideChangesNotice(byReason: setAsideChangesByReason) {
                // The one control this statement of fact carries (P2a, D2):
                // there is still nothing to bring back, but a sentence that
                // could never be put down was an accusation the writer could
                // only silence by deleting forensics. Acknowledge records the
                // record names in THIS device's UI state and touches nothing
                // under `.maugham/conflicts/`.
                HStack(spacing: 8) {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer(minLength: 4)
                    Button("Acknowledge", action: acknowledgeSetAside)
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            // **History this book is missing** (P3b Task 6). A fact about the
            // FOLDER rather than about the draft — every word Maugham had
            // applied is still in it — and the one fact here that a registry
            // verb refuses over, which is why it is the one that can be put
            // down. Orange while it is waiting to be read, secondary once the
            // writer has said they know, because an acknowledged row is a
            // standing explanation rather than a thing to do.
            ForEach(lostHistoryRows) { row in
                HStack(spacing: 8) {
                    Label(row.sentence, systemImage: "clock.badge.xmark")
                        .font(.caption)
                        .foregroundStyle(row.acknowledged
                                         ? AnyShapeStyle(.secondary)
                                         : AnyShapeStyle(Color.orange))
                    Spacer(minLength: 4)
                    if !row.acknowledged {
                        Button("Acknowledge") {
                            acknowledgeLostHistory(row.streamKey)
                        }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                            .help(Self.acknowledgeLostHelp)
                            // .help is hover-only; the WHY must reach VoiceOver.
                            .accessibilityHint(Text(Self.acknowledgeLostHelp))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            // Signed op log P2a's two chain sentences, drawn together and in
            // this order because the second is the first's context: what this
            // Mac is holding, and whose chain it is holding it against.
            if let notice = Self.pendingNotice(
                provenance: documentProvenance, names: chainDeviceNames) {
                HStack(spacing: 8) {
                    Label(notice, systemImage: "person.badge.clock")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer(minLength: 4)
                    // The one History line with a control. It asks the WINDOW
                    // to put the sheet up rather than presenting one itself: a
                    // pane is a column, the sheet belongs to the project
                    // window, and the same request arrives from two other
                    // places (a load that held lines, a stranger's file
                    // syncing in) that this pane knows nothing about.
                    //
                    // `forced`, because this is the writer asking — a *Not
                    // now* earlier in this session must not silence their own
                    // press.
                    Button(Self.admitTitle) {
                        MaughamEvent.postAdmissionRequested(
                            projectURL: projectURL, forced: true)
                    }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                        .help(Self.admitHelp)
                        // .help is hover-only; the WHY must reach VoiceOver.
                        .accessibilityHint(Text(Self.admitHelp))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            // **And the held lines nobody can be admitted for** (P3b Task 7).
            // No control: there is nothing the writer could press here that
            // would change either one. A permit this build cannot read wants a
            // newer build; a piece nobody has claimed is settled in People &
            // Devices, where the sentence sends them; an unsigned stream's
            // words come back through the Inbox, which is Task 8's door and
            // which the sentence already names.
            ForEach(heldRows) { row in
                HeldLineNoticeRow(row: row) { sendHeldWordsToInbox($0) }
                Divider()
            }
            if let notice = retirementLine {
                // Orange, unlike the joined-chain fact beneath it: this one is
                // a DIVERGENCE the writer can see from nowhere else. This Mac
                // goes on applying what it writes (`.mine` outranks `.retired`)
                // and every peer sets those lines aside, so the machine holding
                // the words is the only one that can be told.
                Label(notice, systemImage: "moon.zzz")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            if let notice = joinedChainLine {
                // Secondary, not orange: nothing is wrong, and nothing is
                // being asked of the writer. It is the standing fact the
                // sentence above is measured against.
                Label(notice, systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            if !setAsideRows.isEmpty {
                // Listed whether acknowledged or not — the archives are the
                // writer's to read at any time, and an acknowledgement is a
                // statement about the sentence above, never about the evidence.
                VStack(alignment: .leading, spacing: 4) {
                    SetAsideRecordsDisclosure(
                        rows: setAsideRows, onSend: sendSetAsideToInbox)
                    if let sendToInboxError {
                        Text("Couldn’t send to the Inbox: \(sendToInboxError)")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("set-aside-send-error")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider()
            }
            if let report = recoveredReport, !report.orphans.isEmpty {
                HStack(spacing: 8) {
                    Label(Self.recoveredHistoryNotice(orphanCount: report.orphans.count),
                          systemImage: "tray.and.arrow.down")
                        .font(.caption)
                        .foregroundStyle(.blue)
                    Spacer(minLength: 4)
                    Button("View") { showingRecoveredHistorySheet = true }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            if entries.isEmpty && trustEventLines.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: emptySymbol,
                    description: Text(emptyHint))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    // Built ONCE per body pass and captured by every row —
                    // never per row (tripwire 4: no per-row computation in
                    // list rows without caching).
                    let predecessors = Self.predecessorIndex(ops: ops)
                    // What this Mac may do FROM history, asked once per body
                    // pass (P3c whole-branch fix wave, C1): a reviewer reads
                    // every row and is offered no rewind and no revert.
                    let offersRewind = Self.offersRewind(
                        documentStore?.posture(forDocId: activeDocId))
                    let offersRevert = Self.offersRevert(
                        allDocIds.map { documentStore?.posture(forDocId: $0) })
                    // The book's own entries lead the document's (ruling C).
                    // They are FEW — an admission, a revocation, a claim — and
                    // they are the context every entry below them is written
                    // in, so they sit above rather than interleaved by date
                    // into a timeline whose other rows are one document's.
                    //
                    // The outer `VStack` is load-bearing: a `ScrollView` does
                    // not stack its children, so two views handed to it
                    // directly would be drawn ON TOP of one another. The inner
                    // stack stays lazy, which is where the rows are.
                    VStack(spacing: 0) {
                        projectSection
                        LazyVStack(spacing: 0) {
                            ForEach(entries) { entry in
                                HistoryRow(
                                    entry: entry,
                                    expanded: expanded.contains(entry.id),
                                    lookupOp: { id in opsByOpId[id] },
                                    rewindTarget: {
                                        if case .op(let op) = entry {
                                            return predecessors[op.opId]
                                        }
                                        return nil
                                    }(),
                                    onToggle: {
                                        if expanded.contains(entry.id) {
                                            expanded.remove(entry.id)
                                        } else {
                                            expanded.insert(entry.id)
                                        }
                                    },
                                    onJump: { jump(entry) },
                                    onRevert: {
                                        if case .checkpoint(let cp) = entry {
                                            selectedCheckpoint = cp
                                            showingRestorePicker = true
                                        }
                                    },
                                    offersRewind: offersRewind,
                                    offersRevert: offersRevert,
                                    projectURL: projectURL)
                                Divider()
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WindowAccessor(window: $window))
        .task { await reload() }
        // **The counts follow the provenance** (fix round 2, I1): a document
        // whose load lands after this pane's first reload brings its held
        // holders with it, and the door must appear on that pass rather than
        // on whatever reload happens next.
        .task(id: heldHolderKey) { await reloadHeldWordCounts() }
        .onChange(of: activeDocId) { _, _ in Task { await reload() } }
        // Project-scoped (ADR 0021): only this project's checkpoint reloads
        // this pane. Fixes the cross-window leak where every open window's
        // HistoryPane reloaded on ANY project's checkpoint.
        .onProjectEvent(.maughamCheckpointAdded, url: projectURL, window: window) { _ in
            Task { await reload() }
        }
        // The set-aside rows are the one thing in this pane another surface
        // changes behind its back: `EditorHost`'s auto-return sweep runs on
        // every normal document open and can leave nothing held at all. Without
        // this the standing notice went stale and its Retry re-attempted a
        // record that had already come back (the review's I2).
        .onProjectEvent(.maughamQuarantineRecordsChanged, url: projectURL, window: window) { _ in
            Task { await reload() }
        }
        // A device was let in (signed op log P2b) — by this window's sheet, by
        // a second window on the same book, or silently at open. Both halves of
        // what this pane says about the chain have changed: the pending count
        // is smaller or gone, and there is a new dated entry saying who joined.
        // Without this the banner went on offering Admit… for a device that was
        // already in.
        .onProjectEvent(.maughamAdmissionSettled, url: projectURL, window: window) { _ in
            Task { await reload() }
        }
        .sheet(isPresented: $showingRestorePicker) {
            if let cp = selectedCheckpoint {
                PartialRestorePicker(
                    checkpoint: cp,
                    projectURL: projectURL,
                    activeDocId: activeDocId,
                    allDocIds: allDocIds,
                    device: device,
                    session: session,
                    docPaths: docPaths,
                    documentStore: documentStore,
                    onComplete: {
                        showingRestorePicker = false
                        Task { await reload() }
                    },
                    onCancel: { showingRestorePicker = false }
                )
            }
        }
        // `onDismiss` clears `recoveredReport` — the row's "View" is a
        // pointer to a just-completed Retry, not durable state; the next
        // Retry (or reload finding new held records) replaces it.
        .sheet(isPresented: $showingRecoveredHistorySheet, onDismiss: { recoveredReport = nil }) {
            if let report = recoveredReport {
                RecoveredHistorySheet(
                    report: report,
                    document: documentStore?.document(forDocId: activeDocId),
                    // Drawn only where this Mac may write the text (re-review
                    // item 1); no door behind the pane fails closed.
                    mayAppend: Self.offersRewind(
                        documentStore?.posture(forDocId: activeDocId)),
                    onDismiss: { showingRecoveredHistorySheet = false })
            }
        }
    }

    /// History's project-scope section: what happened to this book's people,
    /// dated, above the document's own timeline (ruling C).
    ///
    /// Absent entirely when nothing has happened — which is every project that
    /// has never joined a chain, admitted anybody or been claimed, and so is
    /// most of them. A heading over an empty list would be a permanent reminder
    /// of a feature the writer is not using.
    @ViewBuilder
    private var projectSection: some View {
        if !trustEventLines.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(Self.projectSectionTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(trustEventLines) { line in
                    HStack(spacing: 6) {
                        Label(line.sentence, systemImage: line.symbol)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        if let date = line.date {
                            Text(date.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                }
            }
        }
    }

    @ViewBuilder
    private var filterToolbar: some View {
        HStack(spacing: 6) {
            AdaptiveFilterRow(
                items: HistoryFilter.allCases,
                selection: $filter)
                .layoutPriority(1)
            Spacer(minLength: 4)
            Button {
                MaughamEvent.post(.maughamOpenRewind, to: .project(for: projectURL))
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Rewind…")
            .disabled(ops.isEmpty || (ops.count == 1 && ops[0].kind == .bootstrap))
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    private func reload() async {
        let loaded = await CheckpointStore(projectURL: projectURL).load()
        // Show all project-scope checkpoints regardless of active doc.
        // Checkpoints are project-wide artefacts; filtering by active doc
        // would hide checkpoints captured while a different doc was open,
        // which is exactly what the user would expect to see for a
        // multi-doc novel/screenplay project.
        checkpoints = loaded.checkpoints
        unreadableCheckpointFiles = loaded.unreadableFiles
        // Prefer the live Document if it's loaded (its mirror reflects any
        // unflushed in-memory state). Otherwise read the op log directly
        // from disk — the History pane should always show typing bursts /
        // annotations / external edits for the active doc, even when the
        // user hasn't yet opened it in the editor this session.
        if let ds = documentStore,
           let doc = ds.document(forDocId: activeDocId) {
            ops = (try? await doc.opLog()) ?? []
        } else if activeDocId != BinderSubject.noDocumentSubject {
            let opStore = OpLogStore(projectURL: projectURL)
            ops = (try? await opStore.load(docId: activeDocId)) ?? []
        } else {
            ops = []
        }
        // Split by KIND, because the two kinds are two different offers. A
        // `.file` record is a whole per-device log that could not be read —
        // Retry may bring it back. A `.lines` record is a run of lines
        // something other than Maugham wrote, kept as forensics with nothing
        // to return, so it stays out of the Retry list and out of
        // `quarantineNotice`'s count (signed op log P1).
        let held = activeDocId == BinderSubject.noDocumentSubject
            ? []
            : OpLogQuarantine.records(forDocId: activeDocId, in: projectURL)
                .filter { $0.status == .held }
        heldQuarantineRecords = held.filter { $0.kind == .file }
        // The sentence counts only what this device has NOT yet told the
        // writer about (P2a, D2) — the disclosure below it keeps the whole
        // list. Both resolutions happen here rather than in `body`, because
        // each reads the quarantine directory.
        let setAside = held.filter { $0.kind == .lines }
        setAsideRecordNames = setAside.map {
            SetAsideAcknowledgement.name(for: $0, in: projectURL)
        }
        // **C16's input, resolved once for both readers** (P3b Task 8): the
        // rows below and the sentence beneath them ask the same question of the
        // same table, so a record cannot be listed under one reason and counted
        // under another. Nil for every book that has revoked nobody, which
        // costs nothing to establish.
        let keepsNothing = await Self.keepsNothingNow(setAside, in: projectURL)
        setAsideRows = SetAsideDoor.rows(
            records: setAside, in: projectURL,
            sent: documentStore?.uiState.sentRecoveredOpIds ?? [:])
        // `applied` is the ops this document is carrying RIGHT NOW — the list
        // read a few lines above, so nothing new is read from disk for it. An
        // op that was set aside and is now in the draft (the writer admitted the
        // device that wrote it) is evidence the disclosure keeps listing and a
        // change the sentence has stopped being about (P2 smoke, find 7).
        setAsideChangesByReason = Self.setAsideChangesByReason(
            records: SetAsideAcknowledgement.unacknowledged(
                records: setAside,
                acknowledged: documentStore?.uiState.acknowledgedSetAsideRecords ?? [],
                in: projectURL),
            in: projectURL,
            applied: Set(ops.map(\.opId)),
            nowKeepsNothing: { keepsNothing[SetAsideDoor.identity(of: $0)] ?? nil })
        // Read outside `reloadChain`'s registry guard: a book that has never
        // joined a chain can still hold another device's stream, and what this
        // Mac cannot find is true whether or not a register says whose it was.
        lostHistoryRows = await Self.lostHistoryRows(
            documentStore?.lostHistory() ?? [])
        await reloadChain()
        await reloadHeldWordCounts()
    }

    /// **What each unsigned holder is waiting with** — the disk half of the
    /// held-line rows (fix round 2, I1).
    ///
    /// Keyed off the LIVE provenance rather than a value captured earlier in
    /// `reload()`, and re-run by `body`'s `.task(id:)` whenever that set of
    /// holders changes — which is what a document whose provenance lands after
    /// the first reload looks like from here. A book with no unsigned holder
    /// asks nothing and costs nothing.
    private func reloadHeldWordCounts() async {
        let holders = Array(documentProvenance?.pendingByDevice.keys ?? [:].keys)
        heldWordCounts = await documentStore?.unsignedHeldWordCounts(
            forDocId: activeDocId, holders: holders) ?? [:]
    }

    /// The holders this document is currently holding lines under, as one
    /// stable string — the id `body`'s `.task` watches, so the counts follow a
    /// provenance that arrives late without polling for it.
    private var heldHolderKey: String {
        (documentProvenance?.pendingByDevice.keys.sorted() ?? []).joined(separator: ",")
    }

    /// The rows, composed live. Pure and cheap — a classification and a
    /// sentence per holder, no disk — so it costs a `body` pass what a stored
    /// array would have cost, minus the staleness.
    private var heldRows: [SetAsideDoor.HeldRow] {
        Self.heldLineRows(
            provenance: documentProvenance,
            startedAPiece: documentStore?
                .document(forDocId: activeDocId)?.startedAPiece ?? [],
            takenFrom: documentStore?
                .document(forDocId: activeDocId)?.keptWritingInATakenPiece ?? [],
            names: chainDeviceNames, words: heldWordCounts,
            sent: documentStore?.uiState.sentRecoveredOpIds ?? [:],
            docId: activeDocId)
    }

    /// The names the two chain sentences are told in, resolved off the main
    /// actor (signed op log P2a).
    ///
    /// **Why the registry and not `OpLogStore.trust()`.** A `TrustTable`
    /// answers verdicts and names nobody — that is deliberate, so that a table
    /// need only be rebuilt when the registry changes. The names live in the
    /// records, so this reads them.
    ///
    /// **Off the actor**, for `TrustResolution.resolve`'s own reason: it is a
    /// directory read plus a signature verification per record.
    ///
    /// **A project with no registry directory short-circuits without a read.**
    /// That is every project that has never joined a chain — the ordinary case,
    /// which must cost nothing beyond three `fileExists`. A registry deleted
    /// WHOLESALE therefore leaves both sentences quiet until something restores
    /// it, which the next document load does on its way to any verdict.
    ///
    /// Never fatal: `RegistryReader.load` throws on a record it cannot read
    /// (RULING-54) and refusing the whole pane over a name would be the wrong
    /// trade. The counts and the join do not come from it.
    private func reloadChain() async {
        let url = projectURL
        guard TrustResolution.hasRegistry(in: url) else {
            chainDeviceNames = [:]
            joinedChainLine = nil
            retirementLine = nil
            trustEventLines = []
            return
        }
        // **The unsigned entries' two facts, read with everything else that
        // touches disk** (P3b Task 10). `onlyIfNarrowed` because an unsigned
        // entry exists only in a narrowed book: an un-narrowed one would pay
        // for a walk of every op file to draw nothing.
        let identities = Document.loadIdentities
        let registryCache = Document.loadRegistryCache
        let resolved = await Task.detached(priority: .userInitiated) {
            () -> (names: [String: String], joined: String?, retired: String?,
                   events: [TrustEventLine]) in
            let registry = try? RegistryReader.load(projectURL: url)
            let unsigned = DocumentStore.readUnsigned(
                in: url, identities: identities, cache: registryCache,
                onlyIfNarrowed: true)
            var names: [String: String] = [:]
            var labels: [String: String] = [:]
            for device in registry?.devices ?? [] { names[device.device] = device.name }
            for person in registry?.people ?? [] { labels[person.person] = person.label }
            // The events are derived from whatever the read could vouch for —
            // an unreadable registry costs the writer names, never the pane
            // (RULING-54's trade, as P2a made it for the two banners). What a
            // device REMEMBERS is still read: the join and the claimants are
            // this Mac's own facts and survive a folder nobody can read.
            let events = TrustEvents.derive(
                registry: registry ?? Registry(), cache: .shared,
                mine: .current, for: url,
                unsigned: TrustEvents.UnsignedStreams(
                    narrowedAt: unsigned.narrowedAt, streams: unsigned.streams))
            // This Mac's own standing, for the one fact on it that the machine
            // itself has to be told: `DeviceStanding` owns the sentence so the
            // pane and People & Devices cannot word it differently (tripwire
            // 19), and the noun is this app's — a Mac.
            let standing = DeviceStanding.resolve(
                registry: registry ?? Registry(), cache: .shared,
                mine: .current, for: url)
            return (names,
                    HistoryPane.joinedChainNotice(
                        cache: .shared, projectURL: url, labels: labels),
                    HistoryPane.retirementNotice(standing: standing),
                    HistoryPane.trustEventLines(events, labels: labels))
        }.value
        chainDeviceNames = resolved.names
        joinedChainLine = resolved.joined
        retirementLine = resolved.retired
        trustEventLines = resolved.events
    }

    /// **C16's input for every set-aside record**, resolved off the main actor
    /// against the one trust table this project has (P3b Task 8).
    ///
    /// **A book that has revoked nobody pays nothing at all**: no register
    /// means no revocation, so the frozen reasons are the only ones there are
    /// and the folder is never opened. Keyed on `SetAsideDoor.identity`, which
    /// is the triple the quarantine directory matches a record on — resolved
    /// without touching disk, unlike the archive name.
    static func keepsNothingNow(
        _ records: [QuarantineRecord], in projectURL: URL
    ) async -> [String: Bool?] {
        guard !records.isEmpty, TrustResolution.hasRegistry(in: projectURL)
        else { return [:] }
        let identities = Document.loadIdentities
        let cache = Document.loadRegistryCache
        return await Task.detached(priority: .userInitiated) {
            // Never fatal, for `reloadChain`'s reason: an unreadable registry
            // costs the writer a CORRECTION to a sentence, never the sentence.
            guard let table = try? TrustResolution.resolveVerified(
                projectURL: projectURL, identities: identities, cache: cache).table
            else { return [:] }
            var answers: [String: Bool?] = [:]
            for record in records where record.kind == .lines {
                answers[SetAsideDoor.identity(of: record)] =
                    SetAsideDoor.keepsNothingNow(
                        record, in: projectURL, table: table)
            }
            return answers
        }.value
    }

    /// **Send one record's set-aside words to the Inbox** (spec §7.4).
    ///
    /// Nothing is applied and nothing on disk moves: the words are copied out
    /// as captures signed by this Mac's own author actor, and the record stays
    /// held with the same sentence on it. The press is remembered device-locally
    /// so the door is not offered a second time and the same paragraphs are not
    /// filed twice.
    private func sendSetAsideToInbox(_ row: SetAsideDoor.Row) {
        guard let documentStore else { return }
        let projectURL = self.projectURL
        let records = OpLogQuarantine.records(forDocId: activeDocId, in: projectURL)
        guard let record = records.first(where: {
            SetAsideAcknowledgement.name(for: $0, in: projectURL) == row.name
        }) else { return }
        let already = documentStore.uiState.sentRecoveredOpIds[row.name] ?? []
        Task {
            let named = await Self.attributions(for: record, in: projectURL)
            let captures = SetAsideDoor.captures(
                forRecord: record, in: projectURL, alreadySent: already,
                // A record whose chain broke names nobody (fix round 2, M6):
                // the `device` field in those bytes is the one thing the
                // refusal exists to disbelieve.
                attribution: {
                    named[$0.device] ?? SetAsideDoor.attribution(
                        forRecord: record, deviceId: $0.device,
                        registry: Registry(),
                        table: TrustResolution.keyless(mine: .current))
                })
            do {
                // Recorded as each one lands, so a send that fails halfway
                // leaves a re-press with only the rest to do (fix round 2, M2).
                _ = try await documentStore.inboxStore.captureRecoveredWords(
                    captures,
                    onLanded: { landed in
                        documentStore.recordRecoveredCapturesSent(
                            door: row.name, ids: [landed.id])
                    })
                sendToInboxError = nil
            } catch {
                sendToInboxError = error.localizedDescription
            }
            await reload()
        }
    }

    /// **Send an unsigned holder's WAITING words to the Inbox** (spec §7.4).
    ///
    /// The set-aside door's twin over the other refusal: nothing is applied,
    /// no byte of the stream moves, the lines stay held under the same holder,
    /// and the words arrive as captures signed by this Mac's own author actor.
    /// A re-read that will not read, or that finds no prose, says so and sends
    /// nothing rather than filing a capture it is not sure of.
    private func sendHeldWordsToInbox(_ row: SetAsideDoor.HeldRow) {
        guard let documentStore else { return }
        let docId = activeDocId
        Task {
            do {
                let landed = try await documentStore.sendHeldWordsToInbox(
                    forDocId: docId, heldBy: row.holder)
                sendToInboxError = landed > 0
                    ? nil
                    : "Nothing is waiting to send any more."
            } catch {
                sendToInboxError = error.localizedDescription
            }
            await reload()
        }
    }

    /// Who each of a record's writers is, in the Inbox's own words for the same
    /// machine (`SetAsideDoor.attribution`), resolved once per press and off
    /// the main actor.
    static func attributions(
        for record: QuarantineRecord, in projectURL: URL
    ) async -> [String: String] {
        let identities = Document.loadIdentities
        let cache = Document.loadRegistryCache
        return await Task.detached(priority: .userInitiated) {
            let writers = OpLogQuarantine.writers(ofRecord: record, in: projectURL)
            guard !writers.isEmpty else { return [:] }
            let resolved = try? TrustResolution.resolveVerified(
                projectURL: projectURL, identities: identities, cache: cache)
            let registry = resolved?.registry ?? Registry()
            let table = resolved?.table
                ?? TrustResolution.keyless(mine: identities)
            var answers: [String: String] = [:]
            for deviceId in writers {
                answers[deviceId] = SetAsideDoor.attribution(
                    forRecord: record, deviceId: deviceId,
                    registry: registry, table: table)
            }
            return answers
        }.value
    }

    /// Put the set-aside sentence down: every record it could be about is
    /// recorded as seen in this device's UI state, and the reload recomputes
    /// the count from what is left. Nothing on disk moves — the disclosure
    /// above goes on listing exactly what it listed before.
    private func acknowledgeSetAside() {
        documentStore?.acknowledgeSetAsideRecords(Set(setAsideRecordNames))
        Task { await reload() }
    }

    /// **The writer says they know this history is gone** (P3b Task 6).
    ///
    /// It writes nothing to the book — this Mac's own memory of having been
    /// told, and nothing another device will ever read — and what it changes is
    /// that the marking verbs stop waiting for that stream. The row stays,
    /// saying so.
    private func acknowledgeLostHistory(_ streamKey: String) {
        documentStore?.acknowledgeLostHistory(streamKey: streamKey)
        Task { await reload() }
    }

    /// Runs `attemptReturn` for every held record, reloads, and surfaces
    /// what happened: a toast in EVERY case, plus the report sheet when the
    /// return turned up paragraphs the draft doesn't have.
    ///
    /// Each record's own `RecoveredHistoryReport` is carried through and the
    /// sweep's verdict is `RecoveredHistoryReport.aggregate` — never a report
    /// assembled here from loose orphans with `redundant` written in by hand,
    /// which is what shipped (the review's I1): the flag then said "sync had
    /// already delivered all of this" about sweeps where it had delivered none
    /// of it.
    ///
    /// A record that stays `.stillUnreadable`/`.corrupt` keeps its place in the
    /// standing notice via the next `reload()`, and — when NOTHING in the sweep
    /// came back — says so (`stillHeldNotice`) rather than leaving a pressed
    /// button looking dead.
    private func retryQuarantine() {
        guard !isRetryingQuarantine else { return }
        isRetryingQuarantine = true
        Task {
            var reports: [RecoveredHistoryReport] = []
            var failureReasons: [String] = []
            for record in heldQuarantineRecords {
                let outcome = await OpLogQuarantine.attemptReturn(
                    record: record, in: projectURL, presenter: nil)
                switch outcome {
                case .returned(let report):
                    reports.append(report)
                case .supersededBySync(let report):
                    reports.append(report)
                    // The lossy shape, and the reason `redundant` is a field
                    // rather than an inference from the orphan count: nothing
                    // moved, and the archive carries history the live log has
                    // not got. The writer hears about it through the orphan
                    // notice; this is the WHY for whoever reads the log.
                    if !report.redundant {
                        historyQuarantineLog.notice("retryQuarantine: \(record.originalName, privacy: .public) stays an archive — its place was refilled by sync, and it holds \(report.orphans.count, privacy: .public) paragraph(s) the live history does not")
                    }
                case .stillUnreadable(let reason), .corrupt(let reason):
                    failureReasons.append(reason)
                    historyQuarantineLog.error("retryQuarantine: \(record.originalName, privacy: .public) still held — \(reason, privacy: .public)")
                case .setAsideByProvenance:
                    // Lines this device did not write, kept as forensics. There
                    // is no file to bring back, so this is neither a report nor
                    // a failure — nothing is offered to the writer about it.
                    // Unreachable from here since `reload()` keeps `.lines`
                    // records out of `heldQuarantineRecords` entirely; the arm
                    // is the belt, and the switch has to be exhaustive anyway.
                    historyQuarantineLog.notice("retryQuarantine: \(record.originalName, privacy: .public) holds lines set aside by provenance — nothing to return")
                }
            }
            await reload()
            isRetryingQuarantine = false
            guard !reports.isEmpty else {
                if let reason = failureReasons.first {
                    MaughamEvent.postNotice(
                        Self.stillHeldNotice(reason: reason), projectURL: projectURL)
                }
                return
            }
            let sweep = RecoveredHistoryReport.aggregate(reports)
            MaughamEvent.postNotice(
                Self.recoveredHistoryNotice(orphanCount: sweep.orphans.count),
                projectURL: projectURL)
            if !sweep.orphans.isEmpty {
                recoveredReport = sweep
                showingRecoveredHistorySheet = true
            }
        }
    }

    private func jump(_ entry: HistoryEntry) {
        guard case .op(let op) = entry,
              let pid = op.changes.first?.paragraphId else { return }
        MaughamEvent.post(
            .maughamNavigateToParagraph, to: .keyWindow,
            payload: ["paragraph_id": pid])
    }
}

// MARK: - HistoryRow

@MainActor
private struct HistoryRow: View {
    let entry: HistoryEntry
    let expanded: Bool
    let lookupOp: (String) -> Op?
    /// The op "Rewind to before this…" opens at — the row op's immediate
    /// predecessor in the opId-ordered log, resolved by the parent pane.
    /// `nil` for the first op (no "before" exists) and for checkpoint rows;
    /// the deep-link button is not offered then, because offering a rewind
    /// that cannot land before the op would be the M4-RW-002 lie again.
    let rewindTarget: Op?
    let onToggle: () -> Void
    let onJump: () -> Void
    let onRevert: () -> Void
    /// Whether *Rewind to before this…* is drawn — only where this Mac may
    /// write the document's text (P3c whole-branch fix wave, C1).
    let offersRewind: Bool
    /// Whether a checkpoint row's *Revert here…* is drawn — only where the
    /// picker would offer at least one document this Mac may write.
    let offersRevert: Bool
    /// Names the project scope the per-row Rewind button posts
    /// `.maughamOpenRewind` to (ADR 0021), so multi-window setups dispatch the
    /// modal only on the window on that project.
    let projectURL: URL

    /// For lifecycle ops (claudeAccept/claudeReject/claudeArchive) the body
    /// of interest is on the CREATION op (claudeComment/claudeSuggestion/
    /// claudeQuery/claudeCraftNote) pointed to by provenance.sourceAnnotationId.
    /// Resolves it from the parent HistoryPane's op index when present.
    private func resolvedBody(for op: Op) -> String? {
        if let body = op.provenance?.annotationBody, !body.isEmpty {
            return body
        }
        if let sourceId = op.provenance?.sourceAnnotationId,
           let source = lookupOp(sourceId) {
            return source.provenance?.annotationBody
        }
        return nil
    }

    /// Short paragraph-id chip for the header. Returns nil for ops without
    /// a paragraph anchor (e.g. craft_note creation, checkpoint).
    private func paragraphAnchor(for op: Op) -> String? {
        if let pid = op.changes.first?.paragraphId, !pid.isEmpty {
            return pid
        }
        if let sourceId = op.provenance?.sourceAnnotationId,
           let source = lookupOp(sourceId),
           let pid = source.changes.first?.paragraphId, !pid.isEmpty {
            return pid
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if expanded {
                expandedDetail
            } else {
                collapsedPreview
            }
            if case .checkpoint = entry, offersRevert {
                Button("Revert here…", action: onRevert)
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .simultaneousGesture(TapGesture().onEnded { })
            } else if case .op(let op) = entry, mutatesManuscript(op.kind),
                      offersRewind, let before = rewindTarget {
                Button {
                    MaughamEvent.post(
                        .maughamOpenRewind, to: .project(for: projectURL),
                        payload: ["scrub_op_id": before.opId,
                                  "scrub_op_at": before.at])
                } label: {
                    Label("Rewind to before this…", systemImage: "arrow.uturn.backward")
                        .labelStyle(.iconOnly)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .help("Rewind to before this point…")
                .simultaneousGesture(TapGesture().onEnded { })
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .simultaneousGesture(
            TapGesture().modifiers(.command).onEnded { _ in onJump() })
    }

    private func mutatesManuscript(_ kind: OpKind) -> Bool {
        switch kind {
        case .typingBurst, .externalEdit, .claudeAccept, .claudeAcceptRevert,
             .checkpointRestore:
            return true
        case .bootstrap, .checkpoint, .claudeComment, .claudeSuggestion,
             .claudeQuery, .claudeCraftNote, .claudeReject, .claudeArchive,
             .annotationEdit, .annotationWithdraw, .annotationReopen,
             .annotationStet, .annotationTriage,
             .taskCreate, .taskStatusChange, .taskPriorityChange,
             .taskParentChange, .taskBodyEdit, .taskArchive:
            return false
        case .unknown:
            // Newer-build op (ADR 0015): treated as inert by the Deriver, so
            // it doesn't mutate the manuscript on this build.
            return false
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 6) {
            Label(kindLabel, systemImage: kindIcon)
                .font(.caption)
                .foregroundStyle(kindColor)
            if case .op(let op) = entry,
               let pid = paragraphAnchor(for: op) {
                Text("¶\(pid.prefix(6))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            Spacer()
            Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var collapsedPreview: some View {
        switch entry {
        case .op(let op):
            switch op.kind {
            case .typingBurst:
                Text("\(op.changes.count) paragraph\(op.changes.count == 1 ? "" : "s") edited")
                    .font(.caption).foregroundStyle(.secondary)
            case .claudeComment, .claudeQuery, .claudeCraftNote, .claudeSuggestion:
                Text(op.provenance?.annotationBody ?? "")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            case .claudeAccept:
                if let body = resolvedBody(for: op) {
                    Text(body).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Accepted").font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .claudeAcceptRevert:
                // Inverse of claudeAccept: reverts a previously accepted
                // suggestion, restoring the prior paragraph text.
                // `provenance.sourceAnnotationId` points at the creation op.
                if let body = resolvedBody(for: op) {
                    Text(body).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Accepted suggestion reverted").font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .claudeReject:
                if let r = op.provenance?.userResponse {
                    Text("\"\(r)\"").italic()
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let body = resolvedBody(for: op) {
                    Text(body).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            case .claudeArchive:
                // Show the original annotation body when we have it so the
                // forensic record is legible (the synthesisSource alone
                // — "paragraph deleted" — gives the cause but not the
                // content). Auto-archives from paragraph deletion get
                // both: body + cause.
                if let body = resolvedBody(for: op) {
                    let cause: String = {
                        switch op.provenance?.synthesisSource {
                        case .paragraphDeleted: return " · paragraph deleted"
                        case .rewind:           return " · removed by rewind"
                        default:                return ""
                        }
                    }()
                    Text("\(body)\(cause)")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text({
                        switch op.provenance?.synthesisSource {
                        case .paragraphDeleted: return "paragraph deleted"
                        case .rewind:           return "removed by rewind"
                        default:                return "archived"
                        }
                    }() as String)
                    .font(.caption).foregroundStyle(.secondary)
                }
            case .annotationEdit:
                Text(op.provenance?.annotationBody ?? "Annotation edited")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            case .annotationWithdraw:
                Text("Annotation withdrawn")
                    .font(.caption).foregroundStyle(.secondary)
            case .annotationReopen:
                Text("Annotation reopened")
                    .font(.caption).foregroundStyle(.secondary)
            case .annotationStet:
                // Same shape as the reject arm: the writer's own words about
                // why it stands, else the note they were answering.
                if let r = op.provenance?.userResponse {
                    Text("\"\(r)\"").italic()
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let body = resolvedBody(for: op) {
                    Text(body).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Stetted").font(.caption).foregroundStyle(.secondary)
                }
            case .annotationTriage:
                Text(op.provenance?.triageMark.map { "Triaged · \($0)" } ?? "Triage cleared")
                    .font(.caption).foregroundStyle(.secondary)
            case .externalEdit:
                Text("\(op.changes.count) paragraph\(op.changes.count == 1 ? "" : "s") changed externally")
                    .font(.caption).foregroundStyle(.secondary)
            case .checkpoint, .checkpointRestore, .bootstrap:
                EmptyView()
            case .taskCreate, .taskStatusChange, .taskPriorityChange,
                 .taskParentChange, .taskBodyEdit, .taskArchive:
                if let body = op.provenance?.taskBody {
                    Text(body).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    EmptyView()
                }
            case .unknown:
                // An op written by a newer Maugham build (ADR 0015). Show a
                // neutral placeholder rather than crash; a future named kind
                // makes this switch a compile error, forcing a real label.
                Text("Newer-version entry").font(.caption).foregroundStyle(.secondary)
            }
        case .checkpoint(let cp):
            Text("\(cp.manuscriptWordCount) words · \(cp.label)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var expandedDetail: some View {
        switch entry {
        case .op(let op):
            if op.kind == .claudeAccept || op.kind == .claudeSuggestion {
                ForEach(Array(op.changes.enumerated()), id: \.offset) { _, change in
                    VStack(alignment: .leading, spacing: 1) {
                        if let prior = change.prior {
                            Text("− \(prior)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.red.opacity(0.08))
                        }
                        Text("+ \(change.next)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.green.opacity(0.08))
                    }
                }
            } else if let body = resolvedBody(for: op) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(body).font(.callout)
                    if let resp = op.provenance?.userResponse {
                        Text("Your reply: \"\(resp)\"")
                            .font(.caption).italic()
                            .foregroundStyle(.secondary)
                    }
                    if op.provenance?.synthesisSource == .paragraphDeleted {
                        Text("Auto-archived: paragraph deleted from manuscript.")
                            .font(.caption2).foregroundStyle(.orange)
                    } else if op.provenance?.synthesisSource == .rewind {
                        Text("Auto-archived: paragraph removed by rewind.")
                            .font(.caption2).foregroundStyle(.orange)
                    } else if op.provenance?.synthesisSource == .rejectConvergence {
                        // RULING-33. The paragraph moved and no gesture of the
                        // writer's moved it, so the history has to say who did
                        // and why — otherwise this reads as a second rejection
                        // they do not remember making.
                        Text("Removed a change accepted on another device, so the "
                             + "rejection and the manuscript agree.")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
            } else if let resp = op.provenance?.userResponse {
                Text("\"\(resp)\"").italic().font(.callout)
            } else {
                collapsedPreview
            }
        case .checkpoint(let cp):
            Text(cp.label).font(.callout)
        }
    }

    private var kindLabel: String {
        switch entry {
        case .op(let op):
            switch op.kind {
            case .typingBurst: return "Typed"
            case .claudeComment: return "Comment"
            case .claudeSuggestion: return "Suggestion"
            case .claudeAccept: return "Accepted"
            case .claudeAcceptRevert: return "Accept reverted"
            case .claudeReject:
                // The convergence repair is a reject the WRITER did not issue
                // (RULING-33) — same op kind, different actor. Labelling both
                // "Rejected" would put an act of Maugham's in the writer's
                // column, which is the same misattribution the `.rewind` /
                // `.paragraphDeleted` arms above exist to avoid.
                return op.provenance?.synthesisSource == .rejectConvergence
                    ? "Rejection applied" : "Rejected"
            case .claudeArchive: return "Archived"
            case .claudeQuery: return "Query"
            case .claudeCraftNote: return "Craft"
            case .externalEdit: return "External edit"
            case .checkpoint: return "Checkpoint"
            case .checkpointRestore:
                switch op.provenance?.synthesisSource {
                case .rewind: return "Rewound"
                case .undoRewind: return "Rewind undone"
                default: return "Reverted"
                }
            case .bootstrap: return "Initial"
            case .taskCreate: return "Task created"
            case .taskStatusChange: return "Task status"
            case .taskPriorityChange: return "Task reorder"
            case .taskParentChange: return "Task nested"
            case .taskBodyEdit: return "Task edited"
            case .taskArchive: return "Task archived"
            case .annotationEdit: return "Annotation edited"
            case .annotationWithdraw: return "Annotation withdrawn"
            case .annotationReopen: return "Annotation reopened"
            // "Stet" is the one user-facing word for the verb (M3 P2) — the
            // pane's button, the margin card's tooltip, the Edit menu's undo
            // and this row all say it.
            case .annotationStet: return "Annotation stetted"
            case .annotationTriage: return "Annotation triaged"
            case .unknown: return "Newer version"
            }
        case .checkpoint:
            return "Checkpoint"
        }
    }
    private var kindIcon: String {
        switch entry {
        case .op(let op):
            switch op.kind {
            case .typingBurst: return "pencil"
            case .claudeComment: return "bubble.left"
            case .claudeSuggestion: return "wand.and.stars"
            case .claudeAccept: return "checkmark.circle"
            case .claudeAcceptRevert: return "arrow.uturn.backward.circle"
            case .claudeReject: return "xmark.circle"
            case .claudeArchive: return "archivebox"
            case .claudeQuery: return "questionmark.circle"
            case .claudeCraftNote: return "ruler"
            case .externalEdit: return "arrow.down.doc"
            case .checkpoint, .checkpointRestore: return "flag"
            case .bootstrap: return "circle.dashed"
            case .taskCreate, .taskStatusChange, .taskPriorityChange,
                 .taskParentChange, .taskBodyEdit, .taskArchive:
                return "checklist"
            case .annotationEdit: return "pencil"
            case .annotationWithdraw: return "trash"
            case .annotationReopen: return "arrow.uturn.up"
            case .annotationStet: return "checkmark.seal"
            case .annotationTriage: return "line.3.horizontal.decrease.circle"
            case .unknown: return "questionmark.square.dashed"
            }
        case .checkpoint: return "flag"
        }
    }
    private var kindColor: Color {
        switch entry {
        case .op(let op):
            switch op.kind {
            case .typingBurst, .bootstrap: return .blue
            case .claudeComment: return .blue
            case .claudeSuggestion: return .orange
            case .claudeAccept: return .green
            case .claudeAcceptRevert: return .teal
            case .claudeReject: return .red
            case .claudeArchive: return .gray
            case .claudeQuery: return .purple
            case .claudeCraftNote: return .yellow
            case .externalEdit: return .purple
            case .checkpoint, .checkpointRestore: return .green
            case .taskCreate, .taskStatusChange, .taskPriorityChange,
                 .taskParentChange, .taskBodyEdit, .taskArchive:
                return Color(red: 0.38, green: 0.76, blue: 0.45)
            case .annotationEdit, .annotationWithdraw, .annotationReopen,
                 .annotationStet, .annotationTriage: return .orange
            case .unknown: return .gray
            }
        case .checkpoint: return .green
        }
    }
}


// MARK: - The set-aside records disclosure

/// **The list of set-aside archives, which must not decide how wide this window
/// is** (signed op log P2 smoke, find 8).
///
/// An archive's name is its op-log file's name plus a content hash plus an
/// ISO8601 stamp — 99 characters, with no space in it to break at. Drawn as a
/// plain `Text` with no line limit, three of them ask for **559 pt** while the
/// column they are in is pinned to the writer's own width (320 by default), and
/// opening the chevron blanked all three of Denver's columns with the main
/// thread idle.
///
/// **Why that demand is now dangerous.** `ProjectWindow.detailColumn` pins a
/// single width and has always relied on AppKit breaking its
/// `NSSplitViewItem.MaxSize` rather than the content's demand — undocumented
/// tie-breaking, which that method's own doc comment refuses to call a proof
/// and which `DetailColumnWidthTests.test_theFixedColumnWinsAgainstAnUnbreakablePane`
/// is the canary on. **On the macOS 27 SDK that canary is red, and the tie-break
/// has flipped**: the column pinned to 300 resolves to 528, the pane's own
/// demand, in all five of that file's fixed-width cases. So a pane's width is
/// no longer a hint here — it is what the column becomes, and 559 pt of right
/// column in a 1200 pt window leaves the prose below its own floor.
///
/// So two things, and the second is the one that matters. Each row is a single
/// truncated line (middle truncation, because the distinguishing part of these
/// names is the hash and the stamp at the END, and the tooltip carries the
/// whole thing). And the disclosure declares an ideal width OF ITS OWN — 220 pt,
/// measured, against the shipped shape's 559 — which is what actually bounds
/// the pane: `.lineLimit(1)` lowers a row's MINIMUM width, not the ideal it
/// reports upward, so a truncating row alone would have left the demand where
/// it was (falsified by reverting only the frame:
/// `SetAsideRecordsDisclosureTests`' two width cases go red, the truncation
/// still in place).
///
/// **What is NOT established**: that these rows are what collapsed Denver's
/// window. The collapse would not reproduce — a real `HistoryPane` over real
/// `.lines` records, expanded, in a real three-column split at 1200 pt and
/// 900 pt, holds `[240, 879, 320]` / `[200, 680, 240]` with the shipped shape
/// as well as with this one. The demand and the flipped tie-break are both
/// measured; the step from them to three blank columns is inference. The fix is
/// right either way — a forensic list must not bid for the window — and if the
/// blanking recurs with this shipped, the split view itself is the suspect, not
/// these rows.
///
/// `isExpanded` is state with an injectable seed so the expanded case — the one
/// that broke — is measurable windowlessly (`SetAsideRecordsDisclosureTests`);
/// production never passes it, and the disclosure opens closed.
///
/// **C13 was re-run before this list grew a control** (P3b Task 8, 2026-09-23)
/// and did not reproduce: the expanded disclosure inside a real three-column
/// split holds `[240, 639, 320]` at 1200 pt and `[200, 480, 320]` at 900 pt,
/// with the shipped framed detail column and with the pre-27 unframed one
/// alike. The layout is therefore untouched; what is new is a per-row button,
/// and its width is bounded by the same suite that bounds the names.
///
/// **The row carries at most one control, and only where there is something
/// to give back** (spec §7.4): a record whose refused lines held manuscript
/// text offers **Send to Inbox**, once. Everything else is a name and a
/// tooltip, which is what a forensic list is.
/// **One held-line sentence, and the one control any of them can carry** (P3b
/// Task 8, extracted in Task 10 for the reason the disclosure beside it was).
///
/// A view of its own rather than an `HStack` in `body` so its width is
/// BOUNDABLE: Task 8's review left this row outside the suite that bounds the
/// set-aside row's button (M5), and a row drawn inline in a pane's body can
/// only be measured by mounting the pane. Its sibling
/// `SetAsideRecordsDisclosure` is the precedent, and `C13`'s whole lesson is
/// that a control added to a column that was already near its width is where
/// this pane goes wrong.
///
/// The sentence is bounded rather than hard-wrapped: these are long and
/// composed live (fix round 2's I1), so the row asks for a modest width and
/// takes whatever the column actually gives it.
@MainActor
struct HeldLineNoticeRow: View {
    let row: SetAsideDoor.HeldRow
    /// What a press does. The view decides nothing: whether a control is drawn
    /// at all is `SetAsideDoor.HeldRow.offersTheDoor`, and what a press writes
    /// is `HistoryPane.sendHeldWordsToInbox`.
    var onSend: (SetAsideDoor.HeldRow) -> Void = { _ in }

    /// What the SENTENCE asks for. Narrower than the disclosure's rows, not
    /// wider, although its text is far longer: this row puts a control (or a
    /// *sent* note) on the same LINE, and the two demands add. Measured — at
    /// the disclosure's 220 the already-sent shape asked 415 pt against the
    /// suite's 400 pt bound.
    static let idealWidth: CGFloat = 180

    var body: some View {
        HStack(spacing: 8) {
            Label(row.sentence, systemImage: "clock.badge.questionmark")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .frame(idealWidth: Self.idealWidth, alignment: .leading)
                .accessibilityIdentifier("held-line-notice")
            Spacer(minLength: 4)
            // **The one held line with no other way in** (spec §7.4): a stream
            // nothing signs cannot be admitted, so the words come back as
            // captures or not at all.
            if row.offersTheDoor {
                Button("Send to Inbox") { onSend(row) }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .help(row.doorHelp)
                    .accessibilityIdentifier("held-line-send-to-inbox")
            } else if let sent = row.sentNote {
                Text(sent)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("held-line-sent-note")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
struct SetAsideRecordsDisclosure: View {
    let rows: [SetAsideDoor.Row]
    /// What a press does. The view decides nothing: which rows carry a control
    /// is `SetAsideDoor.Row.offersTheDoor`, and what a press writes is
    /// `HistoryPane.sendSetAsideToInbox`.
    var onSend: (SetAsideDoor.Row) -> Void = { _ in }
    @State private var isExpanded: Bool

    /// What this list asks for, whatever its rows are called. Narrow enough to
    /// sit inside the History pane's own column at any window size; the rows
    /// stretch to fill whatever they are actually given.
    static let idealWidth: CGFloat = 220

    init(
        rows: [SetAsideDoor.Row],
        onSend: @escaping (SetAsideDoor.Row) -> Void = { _ in },
        initiallyExpanded: Bool = false
    ) {
        self.rows = rows
        self.onSend = onSend
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup("Set-aside records", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(row.name)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if row.offersTheDoor {
                            Button("Send to Inbox") { onSend(row) }
                                .controlSize(.small)
                                .buttonStyle(.link)
                                .font(.caption2)
                                .help(row.doorHelp)
                                .accessibilityIdentifier("set-aside-send-to-inbox")
                        } else if let sent = row.sentNote {
                            Text(sent)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .accessibilityIdentifier("set-aside-sent-note")
                        }
                    }
                }
            }
            .padding(.top, 2)
        }
        .font(.caption)
        .frame(idealWidth: Self.idealWidth, maxWidth: .infinity, alignment: .leading)
    }
}


// MARK: - What history offers (P3c whole-branch fix wave, C1)

extension HistoryPane {
    /// **Whether a row offers *Rewind to before this…*** — the door onto a
    /// restore that rewrites every paragraph that differs, so only where this
    /// Mac may write the document's text. `nil` (no door behind the host)
    /// fails CLOSED. The rows themselves always draw: a reviewer reads history.
    static func offersRewind(_ posture: Posture?) -> Bool {
        posture?.allows(.writeText) ?? false
    }

    /// **Whether a checkpoint row offers *Revert here…*** — only where the
    /// picker it opens would list at least one document this Mac may write
    /// (`PartialRestorePicker.offeredDocIds`). Every `nil` fails closed.
    static func offersRevert(_ postures: [Posture?]) -> Bool {
        postures.contains { $0?.allows(.writeText) ?? false }
    }
}
