// Static-only by rule (#116): no instance members — instance state stays in the root.
import SwiftUI
import MaughamCore

// MARK: - The pane's pure statics — every one a test without a mount

extension HistoryPane {
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
        sent: [String: Int] = [:]
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
                    // Counted off the LINES by the store (P3c Task 7, M2),
                    // never off a memory keyed by this holder: the same
                    // paragraphs are held under a different holder the day a
                    // signing Mac's first seal syncs.
                    sentCount: unsigned ? (sent[holder] ?? 0) : 0)
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
        case .admitted, .silentlyAdmitted, .recognised: return "person.badge.plus"
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
        // A key let go: the person stays, their Apple ID no longer vouches
        // for a new device.
        case .personKeyForgotten: return "key.slash"
        // Not a person at all: a stream this book can name no key for. The
        // question-mark face rather than a warning triangle, because nothing is
        // wrong — the words are waiting, not refused (P3b Task 10).
        case .unsigned: return "person.fill.questionmark"
        }
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
    /// (`PartialRestorePicker.offeredDocIds`), asked through the picker's own
    /// `mayWrite` over the picker's own list. No `DocumentStore` behind the
    /// pane fails closed (`mayWrite(through: nil)` answers false).
    ///
    /// **Asks as little as it can** (P3c plan 2 Task 9): nothing at all when
    /// no row is a checkpoint — there is no Revert to draw — and otherwise
    /// only until the first document the picker would list, rather than
    /// putting every document of the book into the drawing door's asked set
    /// on every body pass.
    static func offersRevert(
        for entries: [HistoryEntry], docIds: [String], mayWrite: (String) -> Bool
    ) -> Bool {
        guard entries.contains(where: {
            if case .checkpoint = $0 { return true } else { return false }
        }) else { return false }
        return docIds.contains(where: mayWrite)
    }
}
