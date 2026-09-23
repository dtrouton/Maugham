import Foundation
import MaughamCore

/// **The one way a set-aside paragraph comes back** (signed op log P3b Task 8,
/// spec §7.4).
///
/// A `.lines` record is the book refusing to apply somebody's lines, and that
/// refusal never softens: nothing here touches the op log, nothing is
/// re-admitted, and the record stays exactly where it is with the same words on
/// it. What this decides is narrower and is the whole of §7.4 — **a refusal
/// that took WORDS out of the writer's draft can hand those words back as
/// captures**, through the writer's own hand, so that a retired Mac's last
/// chapter or a refused paragraph of the assistant's is not simply gone.
///
/// **Both directions, and the second is the one that matters.**
/// - It is offered exactly where the record's own archive holds manuscript
///   text (`OpLogQuarantine.recoverableWords`, which asks
///   `Deriver.appliesToManuscript` rather than restating it — tripwire 44). A
///   record of dispositions, tasks and notes offers nothing: there are no words
///   in it, and a button promising some would be a lie about the evidence.
/// - It **applies nothing**. The words come back as ordinary captures signed by
///   this Mac's own AUTHOR actor, attributed to whoever wrote them, and the
///   writer puts them where they belong by hand. That is the constitution's *AI
///   is never the author* and spec §5's *a revocation is not undone by reading
///   it* in one rule: the only route from a refused line into the manuscript is
///   a person deciding, one paragraph at a time.
/// - It is offered **once**. A record whose words this Mac has already sent
///   carries no door, because the second press would file every paragraph a
///   second time. The memory is device-local and sits beside the set-aside
///   acknowledgement (`UIState.sentSetAsideRecords`) for its reason: what this
///   Mac has told its writer is this Mac's business, and the archives are not
///   the place to write it.
///
/// Pure over what a refresh already read, like every other model behind these
/// panes: the disk read is `rows(records:in:…)`'s one pass, and the view draws
/// the answer (tripwire 4).
enum SetAsideDoor {

    /// One row of the *Set-aside records* disclosure.
    struct Row: Identifiable, Equatable {
        /// The archive file's own name — what the disclosure shows and what
        /// `SetAsideAcknowledgement` keys on, so the two cannot disagree about
        /// which record a press was about.
        let name: String
        /// How many paragraphs **Send to Inbox** would hand back. Zero is the
        /// ordinary answer: most refusals take no manuscript text away.
        let words: Int
        /// Already sent from this Mac.
        let sent: Bool

        var id: String { name }

        /// The control is drawn exactly here.
        var offersTheDoor: Bool { words > 0 && !sent }

        /// What the button promises, counted, so a writer knows what a press
        /// costs before they make it.
        var doorHelp: String {
            let noun = words == 1 ? "paragraph" : "paragraphs"
            return "Send \(words) set-aside \(noun) to the Inbox as captures. "
                + "Nothing is applied to the draft and the record stays."
        }

        /// What is said once the door has been used. The row stays — the
        /// archive is evidence and the disclosure lists it forever — and it
        /// says what the press did rather than going quiet, for the reason
        /// `HistoryPane.lostHistoryRows` gives about an acknowledged loss.
        var sentNote: String? {
            guard sent else { return nil }
            let noun = words == 1 ? "paragraph" : "paragraphs"
            return "\(words) \(noun) sent to the Inbox"
        }
    }

    /// One capture on its way to the Inbox: a paragraph and the line naming
    /// who wrote it.
    struct Capture: Equatable {
        let text: String
        let attribution: String
    }

    // MARK: - The rows

    /// Every set-aside record, in the order the disclosure lists them, with
    /// what each one can still give back.
    static func rows(
        records: [QuarantineRecord], in projectURL: URL, sent: Set<String>
    ) -> [Row] {
        records.map { record in
            let name = SetAsideAcknowledgement.name(for: record, in: projectURL)
            let words = OpLogQuarantine.recoverableWords(
                ofRecord: record, in: projectURL)
            return Row(name: name, words: words.count, sent: sent.contains(name))
        }
    }

    /// The words for one record, ready to be captured.
    ///
    /// Separate from `rows` because it reads the archive a second time on a
    /// press and never on a refresh: the row needs a COUNT, and holding every
    /// paragraph of every record in the pane's state for a button nobody may
    /// press is the per-row-computation shape tripwire 4 is about.
    static func captures(
        forRecord record: QuarantineRecord,
        in projectURL: URL,
        attribution: (OpLogQuarantine.SetAsideWords) -> String
    ) -> [Capture] {
        OpLogQuarantine.recoverableWords(ofRecord: record, in: projectURL)
            .map { Capture(text: $0.text, attribution: attribution($0)) }
    }

    // MARK: - C16: the sentence a record is shown under

    /// **A revocation's sentence is the one the writer's LAST choice made
    /// true** (carry C16).
    ///
    /// Set-aside archives are content-addressed, so revoking the same device a
    /// second time — harshly, this time — files no new record: the bytes are
    /// already there. The sidecar's frozen `reason` then goes on saying
    /// *written after this device's access was withdrawn* about a paragraph the
    /// writer has since set aside along with everything else that device ever
    /// wrote, which is the register's one screen telling them something that
    /// is no longer true.
    ///
    /// **Only the revocation pair is re-derived, and only between its own two
    /// spellings.** A record filed for a broken chain is not re-read as a
    /// revocation because a person has since been revoked — the cause is a fact
    /// about what the walk met and this has no business revising it. The two
    /// sentences are `JSONLAppendStore.quarantineReason`'s own
    /// (`.afterRevocation`), asked of it rather than spelled here, so there is
    /// still exactly one place that says what a set-aside line is called.
    /// The rule is `OpLogQuarantine.reason`'s, because the two sentences are
    /// the op log's own words and a pane may not spell them; this is the ask.
    static func sentence(frozen: String, nowKeepsNothing: Bool?) -> String {
        OpLogQuarantine.reason(frozen, nowKeepsNothing: nowKeepsNothing)
    }

    // MARK: - C1: one sentence, two panes

    /// How many CHANGES were set aside, **under each reason they were set
    /// aside for**, and not counting one the writer already has.
    ///
    /// The enumeration is `OpLogQuarantine.setAsideChanges`', asked once over
    /// every record rather than once per reason, because the dedup is ACROSS
    /// records: an op set aside twice under two reasons is one change, and a
    /// per-reason call could not see that.
    ///
    /// `applied` is what the stream is currently carrying. A `.lines` record is
    /// permanent evidence and the disclosure lists it forever, but once the
    /// writer admits the device those changes are in the draft and *set aside*
    /// has stopped being true of them (P2 smoke, find 7).
    /// `nowKeepsNothing` is **C16**: the current register's answer about the
    /// person whose lines a record holds — true where their revocation keeps
    /// nothing of theirs, false where it keeps what was applied, nil where the
    /// bytes name nobody this book has revoked. It is asked per record by the
    /// caller that has the table, and it is what stops a second, harsher
    /// revocation leaving History reading out the older, gentler sentence about
    /// bytes the writer has since set aside wholesale.
    ///
    /// **Applied as a rename over the reasons, never per change**, because the
    /// dedup is across records and a change knows only the reason of the FIRST
    /// record that held it. Two records sharing a frozen reason whose current
    /// answers DISAGREE keep the frozen one: this may correct a sentence, and
    /// it may never invent one.
    static func changesByReason(
        records: [QuarantineRecord], in projectURL: URL, applied: Set<String> = [],
        nowKeepsNothing: (QuarantineRecord) -> Bool? = { _ in nil }
    ) -> [String: Int] {
        var rename: [String: String] = [:]
        for record in records {
            let derived = sentence(
                frozen: record.reason, nowKeepsNothing: nowKeepsNothing(record))
            if let standing = rename[record.reason], standing != derived {
                rename[record.reason] = record.reason
            } else {
                rename[record.reason] = derived
            }
        }
        var counts: [String: Int] = [:]
        let changes = OpLogQuarantine.setAsideChanges(
            records: records, in: projectURL)
        for change in changes where !applied.contains(change.id) {
            counts[rename[change.reason] ?? change.reason, default: 0] += 1
        }
        return counts
    }

    /// **One record's own key**, for a caller holding a per-record answer it
    /// resolved elsewhere.
    ///
    /// The triple `OpLogQuarantine.quarantinedFileURL` matches a record on
    /// (`docId`, `originalName`, `quarantinedAt`), asked here without touching
    /// the disk — unlike `SetAsideAcknowledgement.name`, which is the writer's
    /// key for the same record and reads the quarantine directory to resolve
    /// it.
    static func identity(of record: QuarantineRecord) -> String {
        // The stamp is lifted out of the interpolation on purpose: the
        // writer-copy census bans the internal verb inside a string literal
        // anywhere under `Views/`, and an interpolated property name is one
        // (`TripwireGrepTests.test_noWriterVisibleCopyNamesTheQuarantineVerb`).
        let filedAt = record.quarantinedAt.timeIntervalSince1970
        return "\(record.docId)|\(record.originalName)|\(filedAt)"
    }

    /// **Does the book NOW keep nothing of what this record's writers wrote?**
    /// — C16's input, read off the one trust table this window already has
    /// (tripwire 39: no second table, and no second opinion about a verdict).
    ///
    /// Nil is the ordinary answer and means *nothing to correct*: the bytes
    /// name nobody this register can place, or nobody it has revoked, or two
    /// writers whose revocations disagree. The frozen reason then stands.
    static func keepsNothingNow(
        _ record: QuarantineRecord, in projectURL: URL, table: TrustTable
    ) -> Bool? {
        var answer: Bool?
        for deviceId in OpLogQuarantine.writers(ofRecord: record, in: projectURL) {
            guard let key = table.deviceKey(forDeviceId: deviceId)?.key,
                  case let .revoked(_, mark) = table.verdict(forSealKey: key)
            else { continue }
            let harsh = mark == nil || mark == RevocationScope.nothingAppliedMark
            if let answer, answer != harsh { return nil }
            answer = harsh
        }
        return answer
    }

    /// **The set-aside sentence, once, for both panes** (carry C1).
    ///
    /// History's twin has been reason-aware since P2b and the Inbox's has not:
    /// a capture refused because the writer revoked their own old laptop read
    /// *written to the inbox by something that is not Maugham*, which is a
    /// sentence about a stranger tampering with the file. P3 adds a third kind
    /// of reason — the permit's — so that stopped being cosmetic, and two
    /// spellings of one sentence is how one pane comes to describe an event the
    /// other describes correctly.
    ///
    /// The REASONS are the records' own, in `JSONLAppendStore.quarantineReason`'s
    /// words, derived from the cause and never spelled by a pane. What each
    /// caller supplies is only what its own refusal costs the writer: the noun
    /// (a change to a document, a capture) and what happened to it (not
    /// applied, not shown).
    ///
    /// Ordered by count, then alphabetically, so one folder answers one way
    /// however its sidecars happened to be enumerated. Pure over the counts, so
    /// the copy pins without a window and without disk.
    static func notice(
        byReason: [String: Int],
        subject: (Int) -> String,
        clause: (Int) -> String,
        ending: String
    ) -> String? {
        let groups = byReason
            .filter { $0.value > 0 }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        guard !groups.isEmpty else { return nil }
        if groups.count == 1, let only = groups.first {
            let verb = only.value == 1 ? "was" : "were"
            return "\(subject(only.value)) \(verb) set aside (\(only.key)); "
                + "\(ending)."
        }
        let total = groups.reduce(0) { $0 + $1.value }
        let clauses = groups.map { "\(clause($0.value)) \($0.key)" }
        let tail = ending.prefix(1).uppercased() + ending.dropFirst()
        return "\(subject(total)) were set aside: "
            + clauses.joined(separator: "; ") + ". \(tail)."
    }

    // MARK: - Who wrote it

    /// **The line a recovered capture carries** — who the paragraph is from.
    ///
    /// Two halves, and neither is spelled twice. WHO is `InboxByline`'s answer
    /// about the same `<actor>-<prefix>` string an inbox row carries, so a
    /// recovered capture names a machine in exactly the words the pane's own
    /// bylines name it. WHICH OF THAT MACHINE'S FOUR WRITERS is this
    /// function's, because the byline deliberately does not say — an ordinary
    /// capture is always the writer's own hand, and a refused line very often
    /// is not.
    ///
    /// **The AI actor never gets a product name**: *the assistant*.
    ///
    /// `nil` from the byline is not a gap. It means this Mac's own key, or a
    /// book on no chain, and the honest word for both is *this Mac* — which is
    /// exactly the case an actor refusal produces, since the assistant may not
    /// change the manuscript on any device, the root's included.
    static func attribution(
        forDeviceId deviceId: String, registry: Registry, table: TrustTable
    ) -> String {
        let named = InboxByline.text(
            forDeviceId: deviceId, registry: registry, table: table)
        let whose = named.map {
            $0.hasPrefix("from ") ? String($0.dropFirst("from ".count)) : $0
        } ?? "this Mac"
        switch DeviceIdentity.claimedActor(ofDeviceId: deviceId) {
        case .assistant:
            return "Set aside — the assistant on \(whose)"
        case .translator:
            return "Set aside — the translation pipeline on \(whose)"
        case .maugham:
            return "Set aside — Maugham’s own housekeeping on \(whose)"
        case .author, .none:
            return "Set aside — \(whose)"
        }
    }
}
