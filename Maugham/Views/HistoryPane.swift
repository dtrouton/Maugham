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
    /// How many CHANGES were set aside because something that is not Maugham
    /// wrote them into one of this doc's op-log files (signed op log P1) **and
    /// the writer has not yet acknowledged** (P2a, D2). A count rather than the
    /// records, because the notice is pure over the count and reading the
    /// archives is `reload()`'s job, not `body`'s.
    @State private var setAsideLineCount: Int = 0
    /// Every set-aside record for this doc, acknowledged or not, by the name it
    /// is acknowledged under. The disclosure below the sentence lists these
    /// REGARDLESS: what an Acknowledge press puts down is the sentence, not the
    /// forensics. Resolved on `reload()` and held, because
    /// `SetAsideAcknowledgement.name(for:in:)` reads the quarantine directory
    /// and a per-row read from `body` is tripwire 4.
    @State private var setAsideRecordNames: [String] = []
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
    /// The project's dated trust events, already as drawn rows (signed op log
    /// P2b, ruling C). Resolved in `reloadChain` beside the names they are told
    /// in, because both come out of the same off-actor registry read.
    @State private var trustEventLines: [TrustEventLine] = []
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
    /// Pure over the count, so the copy pins without a window and without disk.
    /// The count itself comes from `setAsideLineCount`, which is the half that
    /// has to read files.
    static func setAsideLinesNotice(lineCount: Int) -> String? {
        guard lineCount > 0 else { return nil }
        let subject = lineCount == 1
            ? "1 change was written"
            : "\(lineCount) changes were written"
        return "\(subject) to this document by something that is not Maugham; "
             + "kept in backup, not applied."
    }

    /// How many CHANGES were set aside. One line, because the counting is
    /// `OpLogQuarantine.setAsideLineCount`'s — the Inbox pane asks the same
    /// question of the manifest stream, and two copies would be two answers.
    static func setAsideLineCount(
        records: [QuarantineRecord], in projectURL: URL
    ) -> Int {
        OpLogQuarantine.setAsideLineCount(records: records, in: projectURL)
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
    static let admitTitle = "Admit…"
    static let admitIsAvailable = true
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
        guard let provenance, provenance.hasPendingHistory else { return nil }
        let total = provenance.pendingLines
        let noun = total == 1 ? "note" : "notes"
        let verb = total == 1 ? "is" : "are"
        let devices = provenance.pendingByDevice.keys.sorted()
        let who: String
        if devices.count > 1 {
            who = "\(devices.count) devices"
        } else if let device = devices.first {
            who = names[device] ?? DeviceCode.short(device)
        } else {
            // Held lines nothing attributes to a device. Structurally unlikely
            // — the tally is built off the same lines the count is — but the
            // COUNT is what matters here, and going quiet about history that is
            // not in the draft would be the one unacceptable answer.
            who = "another device"
        }
        return "\(total) \(noun) from \(who) \(verb) waiting for admission."
    }

    /// Whose chain this Mac is on — nil when it has joined nobody's.
    ///
    /// A Mac that is its own root joins nothing (B1, `TrustTable.RootSource`'s
    /// arm 2): there is no chain of somebody else's for it to be on, and the
    /// cache records only a FOREIGN root. So the ordinary single-Mac project
    /// never sees this line, and a Mac admitted to another's book always does.
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
    nonisolated static func trustEventLines(
        _ events: [TrustEvent], labels: [String: String]
    ) -> [TrustEventLine] {
        events.map { event in
            TrustEventLine(
                id: event.id,
                sentence: TrustEventSentence.sentence(for: event, labels: labels),
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
        case .revoked: return "person.badge.minus"
        case .retired: return "moon.zzz"
        case .claimed: return "flag"
        case .adopted: return "arrow.triangle.merge"
        case .joined: return "link"
        case .anotherClaimant: return "exclamationmark.triangle"
        case .recordRestored: return "arrow.uturn.backward.circle"
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
            if let notice = Self.setAsideLinesNotice(lineCount: setAsideLineCount) {
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
                        .disabled(!Self.admitIsAvailable)
                        .help(Self.admitHelp)
                        // .help is hover-only; the WHY must reach VoiceOver.
                        .accessibilityHint(Text(Self.admitHelp))
                }
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
            if !setAsideRecordNames.isEmpty {
                // Listed whether acknowledged or not — the archives are the
                // writer's to read at any time, and an acknowledgement is a
                // statement about the sentence above, never about the evidence.
                DisclosureGroup("Set-aside records") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(setAsideRecordNames, id: \.self) { name in
                            Text(name)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.top, 2)
                }
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
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
        setAsideLineCount = Self.setAsideLineCount(
            records: SetAsideAcknowledgement.unacknowledged(
                records: setAside,
                acknowledged: documentStore?.uiState.acknowledgedSetAsideRecords ?? [],
                in: projectURL),
            in: projectURL)
        await reloadChain()
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
            trustEventLines = []
            return
        }
        let resolved = await Task.detached(priority: .userInitiated) {
            () -> (names: [String: String], joined: String?, events: [TrustEventLine]) in
            let registry = try? RegistryReader.load(projectURL: url)
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
                mine: .current, for: url)
            return (names,
                    HistoryPane.joinedChainNotice(
                        cache: .shared, projectURL: url, labels: labels),
                    HistoryPane.trustEventLines(events, labels: labels))
        }.value
        chainDeviceNames = resolved.names
        joinedChainLine = resolved.joined
        trustEventLines = resolved.events
    }

    /// Put the set-aside sentence down: every record it could be about is
    /// recorded as seen in this device's UI state, and the reload recomputes
    /// the count from what is left. Nothing on disk moves — the disclosure
    /// above goes on listing exactly what it listed before.
    private func acknowledgeSetAside() {
        documentStore?.acknowledgeSetAsideRecords(Set(setAsideRecordNames))
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
            if case .checkpoint = entry {
                Button("Revert here…", action: onRevert)
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .simultaneousGesture(TapGesture().onEnded { })
            } else if case .op(let op) = entry, mutatesManuscript(op.kind),
                      let before = rewindTarget {
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

