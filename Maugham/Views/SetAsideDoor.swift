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
/// - It offers **what is left**, and never the same paragraph twice. A press
///   remembers each paragraph it filed, by `<opId>#<paragraphId>`
///   (`UIState.sentRecoveredOpIds`), so a record that goes on being written to
///   keeps offering the NEW words while the ones already in the Inbox are
///   counted as sent rather than filed again. (Fix round 2's C1: it used to be
///   offered *once* per record, which closed the door on a stream that was
///   still growing and reported the live count as *sent*.) The memory is
///   device-local, keyed per door, and shared with the held-line door beside
///   it, for its reason: what this Mac has handed its writer is this Mac's
///   business, and the archives are not the place to write it. (The held door
///   remembers `<docId>|<opId>#<paragraphId>` under one key per document, and
///   never keys by holder — `heldDoorKey` says why.)
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
        /// How many paragraphs **Send to Inbox** would hand back NOW — the
        /// ones this Mac has not already sent. Zero is the ordinary answer:
        /// most refusals take no manuscript text away, and a record whose
        /// words are all in the Inbox has nothing left to offer.
        let unsent: Int
        /// How many captures this Mac has already made from this record.
        let sentCount: Int

        var id: String { name }

        /// The control is drawn exactly here.
        var offersTheDoor: Bool { unsent > 0 }

        /// What the button promises, counted, so a writer knows what a press
        /// costs before they make it.
        var doorHelp: String {
            let noun = unsent == 1 ? "paragraph" : "paragraphs"
            return "Send \(unsent) set-aside \(noun) to the Inbox as captures. "
                + "Nothing is applied to the draft and the record stays."
        }

        /// What is said once the door has been used. The row stays — the
        /// archive is evidence and the disclosure lists it forever — and it
        /// says what the press DID rather than going quiet, for the reason
        /// `HistoryPane.lostHistoryRows` gives about an acknowledged loss.
        ///
        /// **The count is of what was SENT**, never of what is there: the two
        /// are different numbers the moment anything is added or a send lands
        /// only partly, and reporting the second as the first is the screen
        /// telling the writer it did something it did not do.
        var sentNote: String? {
            guard sentCount > 0 else { return nil }
            let noun = sentCount == 1 ? "paragraph" : "paragraphs"
            return "\(sentCount) \(noun) sent to the Inbox"
        }
    }

    /// One capture on its way to the Inbox: a paragraph, the line naming who
    /// wrote it, and the identity this Mac remembers it by.
    struct Capture: Equatable {
        /// `captureId`'s — what makes a re-press file only the rest.
        let id: String
        let text: String
        let attribution: String
    }

    /// **What this Mac remembers a sent capture by** (fix round 2, C1).
    ///
    /// The PARAGRAPH, not the op: a capture is one paragraph, the note counts
    /// captures, and an op carrying three paragraphs of which one failed to
    /// land is a real state (`captureRecoveredWords` records what landed). A
    /// key per op could not tell any of those apart.
    static func captureId(_ words: OpLogQuarantine.SetAsideWords) -> String {
        "\(words.opId)#\(words.paragraphId)"
    }

    // MARK: - The rows

    /// Every set-aside record, in the order the disclosure lists them, with
    /// what each one can still give back.
    ///
    /// `sent` is this Mac's memory of the captures it has already made, by
    /// door key (fix round 2, C1). The door offers what is left rather than
    /// closing after one press — which matters here less than it does for a
    /// held span (an archive does not grow), but the two doors must count the
    /// same way or the writer learns to distrust whichever is wrong.
    static func rows(
        records: [QuarantineRecord], in projectURL: URL,
        sent: [String: Set<String>]
    ) -> [Row] {
        records.map { record in
            let name = SetAsideAcknowledgement.name(for: record, in: projectURL)
            let already = sent[name] ?? []
            let words = OpLogQuarantine.recoverableWords(
                ofRecord: record, in: projectURL)
            return Row(
                name: name,
                unsent: words.filter { !already.contains(captureId($0)) }.count,
                sentCount: already.count)
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
        alreadySent: Set<String> = [],
        attribution: (OpLogQuarantine.SetAsideWords) -> String
    ) -> [Capture] {
        OpLogQuarantine.recoverableWords(ofRecord: record, in: projectURL)
            .filter { !alreadySent.contains(captureId($0)) }
            .map {
                Capture(id: captureId($0), text: $0.text,
                        attribution: attribution($0))
            }
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
    ///
    /// **`keptNothing` is `mark == nil` and nothing else** (fix round 2, I2;
    /// ruled 2026-09-23). `TrustVerdict.refusal` is the one spelling of that
    /// rule (`OpLogChain.swift`, `.afterRevocation(person:keptNothing: mark ==
    /// nil)`) and this asks the same question of the same field.
    ///
    /// `RevocationScope.nothingAppliedMark` is emphatically NOT the harsh
    /// press: it is what the GENTLE one records over a person this book had
    /// applied nothing of (`DocumentStore+Registry`'s `.nothingApplied` arm,
    /// find-5's High). A real mark, written precisely so the two presses stay
    /// tellable apart. Reading it as *set aside everything it wrote* is the
    /// defect that ruling exists to prevent, arriving one layer up: the writer
    /// pressed the gentle button and History would redraw their choice as the
    /// harsh one.
    static func keepsNothingNow(
        _ record: QuarantineRecord, in projectURL: URL, table: TrustTable
    ) -> Bool? {
        var answer: Bool?
        for deviceId in OpLogQuarantine.writers(ofRecord: record, in: projectURL) {
            guard let key = table.deviceKey(forDeviceId: deviceId)?.key,
                  case let .revoked(_, mark) = table.verdict(forSealKey: key)
            else { continue }
            let harsh = mark == nil
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

    // MARK: - The other door: a held span nothing signs (spec §7.4)

    /// **A row of History's held-line notices**, with what it can give back.
    ///
    /// The held door and the set-aside door are the same offer over two
    /// different refusals, and the difference is worth stating: a `.lines`
    /// record is words the book REFUSED and archived, while this is words the
    /// book is HOLDING in the file it found them in, because a stream nothing
    /// signs has written after the book's first narrowing. Nothing is wrong
    /// with them, which is exactly why no record was ever written for them and
    /// why nothing but the walk can say which they are.
    struct HeldRow: Identifiable, Equatable {
        /// The holder string the walk held these lines under.
        let holder: String
        /// The sentence `HeldLines` gives this holder — never worded here.
        let sentence: String
        /// How many waiting paragraphs **Send to Inbox** would hand back NOW —
        /// the ones this Mac has not already sent. Zero for every holder that
        /// is not an unsigned stream, and for one whose re-read found nothing
        /// or would not read.
        ///
        /// **A held span is LIVE** (fix round 2, C1), which is the whole
        /// difference from an archive: the stream it names goes on being
        /// written to. A door that closed after one press would leave every
        /// paragraph that arrived afterwards with no way in at all — the state
        /// this door exists to remove — so what it offers is what is left.
        let unsent: Int
        /// How many captures this Mac has already made from this span, in this
        /// document.
        let sentCount: Int

        var id: String { holder }

        var offersTheDoor: Bool { unsent > 0 }

        var doorHelp: String {
            let noun = unsent == 1 ? "paragraph" : "paragraphs"
            return "Send \(unsent) waiting \(noun) to the Inbox as captures. "
                + "Nothing is applied to the draft and the lines stay where "
                + "they are."
        }

        /// The count is of what was SENT, never of what is waiting — see
        /// `Row.sentNote`. Here the two diverge on the ordinary case rather
        /// than on an edge one, because the stream keeps writing.
        var sentNote: String? {
            guard sentCount > 0 else { return nil }
            let noun = sentCount == 1 ? "paragraph" : "paragraphs"
            return "\(sentCount) \(noun) sent to the Inbox"
        }
    }

    /// **The door key a held-span send is remembered under** — per DOCUMENT,
    /// and deliberately NOT per holder (P3c Task 7, carry M2).
    ///
    /// It used to be `<docId>|<holder>`, and the holder is the one thing about
    /// a held line that is NOT a fact about the line: it is the walk's current
    /// opinion of whose it is. A signing Mac whose first seal has not synced
    /// here yet reads as an unsigned stream (`unsigned:<slug>`), and the moment
    /// the seal arrives the SAME lines are held under its key instead — so a
    /// memory keyed by the holder forgot every paragraph the writer had already
    /// sent, and offered them again. What is remembered is therefore the LINES
    /// (`heldLineId`), and this key only groups them by the chapter they are
    /// in.
    ///
    /// No colon, so it can never equal an older `<docId>|unsigned:<stream>`
    /// key: those stay in `UIState.sentRecoveredOpIds` unread (tripwire 11, no
    /// migration), and a paragraph sent under one before this build is offered
    /// once more — the safe direction, a duplicate capture rather than a lost
    /// one, and only on the dev Macs that ran P3b.
    static func heldDoorKey(docId: String) -> String {
        "\(docId)|held"
    }

    /// **What this Mac remembers one sent held paragraph by**:
    /// `<docId>|<opId>#<paragraphId>` — the record door's `captureId`, with
    /// the chapter in front. The op and the paragraph are what the line IS, so
    /// the same words held under a different holder tomorrow are the same id.
    static func heldLineId(
        docId: String, _ words: OpLogQuarantine.SetAsideWords
    ) -> String {
        "\(docId)|\(captureId(words))"
    }

    /// **What the held door can still give back, and what it already has**,
    /// per holder, for one document — the disk half of History's held rows,
    /// resolved by `DocumentStore.unsignedHeldWordCounts` on a reload.
    ///
    /// `sent` is how many of the paragraphs held under that holder NOW are
    /// ones this Mac has already made a capture of — a count of what was
    /// SENT, taken from the lines themselves, so it is right whichever holder
    /// they were sent under.
    struct HeldWordCounts: Equatable, Sendable {
        var unsent: [String: Int] = [:]
        var sent: [String: Int] = [:]

        static let none = HeldWordCounts()
    }

    /// **The held door's two counts, off the lines** — pure over what the
    /// store's walk read (`wordsByHolder`) and this Mac's memory (`sent`, the
    /// whole of `UIState.sentRecoveredOpIds`). A holder with no words is left
    /// out of both maps, so a re-read that found nothing offers no door.
    ///
    /// **The holder chooses which lines are counted, and never how they are
    /// remembered** (P3c Task 7, M2): a paragraph sent while its stream was
    /// held as unsigned is still *sent* once the same line is held under a
    /// key, and a paragraph never sent is offered whatever it is held under.
    static func heldWordCounts(
        docId: String,
        wordsByHolder: [String: [OpLogQuarantine.SetAsideWords]],
        sent: [String: Set<String>]
    ) -> HeldWordCounts {
        let already = sent[heldDoorKey(docId: docId)] ?? []
        var counts = HeldWordCounts()
        for (holder, words) in wordsByHolder where !words.isEmpty {
            let sentHere = words.filter {
                already.contains(heldLineId(docId: docId, $0))
            }.count
            if sentHere > 0 { counts.sent[holder] = sentHere }
            if words.count > sentHere { counts.unsent[holder] = words.count - sentHere }
        }
        return counts
    }

    /// **The captures a held-door press would file**: the paragraphs this Mac
    /// has not already sent from this document, each carrying the id it will
    /// be remembered by (`heldLineId`) — pure, for `heldWordCounts`' reason.
    static func heldCaptures(
        docId: String, words: [OpLogQuarantine.SetAsideWords],
        sent: [String: Set<String>]
    ) -> [Capture] {
        let already = sent[heldDoorKey(docId: docId)] ?? []
        return words
            .map { (id: heldLineId(docId: docId, $0), words: $0) }
            .filter { !already.contains($0.id) }
            .map {
                Capture(id: $0.id, text: $0.words.text,
                        attribution: unsignedAttribution)
            }
    }

    /// **Who a recovered held paragraph is from**, in `HeldLines`' own words.
    ///
    /// There is no device to name and there never will be: an unsigned Mac
    /// files no record, so the book has never been told what to call it — which
    /// is the same reason `HeldLines.sentence` names nobody in its unsigned
    /// arm. The phrase is that arm's, shared rather than re-worded, and it says
    /// what is true of the machine rather than what is missing from it.
    static let unsignedAttribution =
        "Waiting — \(HeldLines.unsignedWriter)"

    // MARK: - Who wrote it

    /// **What a record whose CHAIN broke can honestly say about its writer**
    /// (fix round 2, M6; ruled 2026-09-23) — nothing.
    ///
    /// Every other cause names a device whose lines these are, and the capture
    /// says so. A chain break says the opposite: those bytes were refused
    /// because nothing in the file vouches for them, and the `device` string
    /// inside them is a word whatever-wrote-them chose. Reading it out would
    /// put a paragraph in a real machine's mouth on the strength of the one
    /// field the refusal exists to disbelieve — and the writer, who is
    /// deciding whether to keep those words, would be deciding on a byline the
    /// book cannot stand behind.
    static let unattributable = "Set aside — this book cannot say who wrote it"

    /// The attribution for one of a RECORD's paragraphs: the writer it names,
    /// unless the record's own reason says the chain broke, in which case
    /// nobody. Asked of `OpLogQuarantine.isAChainBreakReason`, which derives
    /// both spellings from `quarantineReason` exactly as
    /// `reason(_:nowKeepsNothing:)` derives the revocation pair.
    static func attribution(
        forRecord record: QuarantineRecord, deviceId: String,
        registry: Registry, table: TrustTable
    ) -> String {
        guard !OpLogQuarantine.isAChainBreakReason(record.reason) else {
            return unattributable
        }
        return attribution(
            forDeviceId: deviceId, registry: registry, table: table)
    }

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
