import Foundation

/// **Whose a held line is, and what to say about it** (P3b Task 2).
///
/// A held line is one the reader neither applied nor refused —
/// `OpLogChain.Line.State.pending(device:)`. P2 had exactly one reason to hold
/// one, a stranger's seal, so *held* and *waiting for admission* were the same
/// fact and every surface could read `pendingByDevice` raw. There are now
/// three, they share one storage state on purpose (same walk, same tallies,
/// one `applied` filter), and they are told apart HERE — once, by the string
/// the walk held them under:
///
/// - **a stranger** — a key this book has no person record for. The writer can
///   be asked to admit it, and admitting applies what it wrote.
/// - **permit-pending** — an ADMITTED person whose line was held rather than
///   applied. She is already in the book; offering an admission sheet about her
///   would offer a control that changes nothing. **Two reasons, one holder
///   string** (P3b Task 7): this build cannot judge the line
///   (`Permit.Allowed.cannotJudge`: a later build's op kind, a role or scope
///   word this one does not know), or she opened a piece nobody has claimed
///   (spec §4.5) — which is a question the writer can answer today. The string
///   cannot tell them apart and neither can anything downstream, so the walk
///   that decided it says so: `AmendmentPermits.recordStartedAPiece`, carried
///   into `holder(of:registry:startedAPiece:)` as an INPUT.
/// - **unsigned** — a line written after the first narrowing by a file this
///   register can name no key for (`UnsignedSnapshot`). There is no device to
///   admit, because there is no key: nothing on that Mac signs what it writes.
///   Its one way back in is the Inbox.
///
/// **The unsigned holder is a string no fingerprint can be**, and that is what
/// makes the classification total rather than a guess. A seal key is 64 hex
/// characters and a device id is `<actor>-<hex…>`; `DeviceSlug.make` maps
/// everything outside `[a-z0-9]` to `-`. A colon appears in none of them, so
/// `unsigned:<stream>` cannot collide with a key, cannot be parsed as a device
/// id (`DeviceIdentity.looksLikeADeviceId` answers false), and cannot be
/// mistaken for a person.
///
/// **One predicate, extended rather than copied.** `Registry.isStrangerDevice`
/// and its twin on `TrustTable` ask this type whether a holder is unsigned, so
/// every admission-worded count in the app narrows in the same place —
/// `strangersAwaitingAdmission`, `OpLogProvenance.pendingStrangersByDevice`,
/// the inbox's own map, `announcePendingHistory`. A filter per surface is how
/// one of them comes to offer an Admit… sheet about a Mac that has no key.
public enum HeldLines {

    // MARK: - The unsigned holder

    /// The one spelling of *this line was held because nothing signs it*.
    ///
    /// Private to this type: a second literal somewhere else is a holder one
    /// surface recognises and another calls a stranger.
    private static let unsignedPrefix = "unsigned:"

    /// **What the unsigned door holds a line under** — the STREAM it was in,
    /// named by the device slug its files carry, or by the stream key where
    /// there is no slug at all (the legacy unsuffixed `<docId>.jsonl`, which
    /// belongs to no device in particular and is exactly the file no key can
    /// name).
    ///
    /// The slug rather than the file, because a stream outlives its filenames:
    /// a rotated `.mzseg` and the tail it came out of are one writer, and two
    /// holder strings for them would ask the writer about one Mac twice.
    public static func unsignedHolder(
        forStreamKey key: String, deviceSlug: String?
    ) -> String {
        "\(unsignedPrefix)\(deviceSlug ?? key)"
    }

    /// `PermitMark.Stream`'s own answer, so no caller picks between the two
    /// halves above by hand.
    public static func unsignedHolder(for stream: PermitMark.Stream) -> String {
        unsignedHolder(forStreamKey: stream.key, deviceSlug: stream.deviceSlug)
    }

    /// Is this held-line holder an unsigned stream rather than a key?
    public static func isUnsignedHolder(_ device: String) -> Bool {
        device.hasPrefix(unsignedPrefix)
    }

    /// The stream (or slug) an unsigned holder names, for a surface that wants
    /// to say WHICH one; nil for anything that is not one.
    public static func streamOfUnsignedHolder(_ device: String) -> String? {
        guard isUnsignedHolder(device) else { return nil }
        let named = device.dropFirst(unsignedPrefix.count)
        return named.isEmpty ? nil : String(named)
    }

    // MARK: - Whose it is

    /// The three reasons a line is held, and nothing else is one.
    public enum Holder: Equatable, Hashable, Sendable {
        /// A key this book has no person record for. Admittable.
        case stranger(fingerprint: String)
        /// A person already in the book whose line was held rather than
        /// applied — for one of two reasons, which the payload tells apart
        /// (P3b Task 7, finding B).
        ///
        /// `startedAPiece` is spec §4.5: an author of some pieces put
        /// manuscript text, with her own hand, into a piece that is in nobody's
        /// scope. That is a **question the writer can answer today** — is the
        /// piece hers? — and it is decided in the partition, where the permit,
        /// the actor, the class and the op kind are all in hand
        /// (`AmendmentPermits.recordStartedAPiece`).
        ///
        /// `false` is P3a's reason and stays P3a's: this BUILD cannot judge
        /// the line (`Permit.Allowed.cannotJudge` — a later build's op kind, a
        /// role or scope word this one does not know), and there is nothing to
        /// do but wait for a build that can.
        case permitPending(person: String, startedAPiece: Bool)
        /// A stream nothing signs, after the first narrowing. The payload is
        /// `unsignedHolder`'s own — a device slug, or a stream key.
        case unsigned(stream: String)
    }

    /// **The one classifier.** Unsigned first, because that answer is decided
    /// by the string itself and no registry can contradict it; then the
    /// registry's own stranger predicate, which this function is the reason
    /// for.
    ///
    /// **`startedAPiece` widens the INPUT and never the classification** (P3b
    /// Task 7). It is the walk's own answer — did this holder's held lines open
    /// a piece nobody has claimed (`AmendmentPermits.whoStartedAPiece`) — and
    /// it reaches only the one arm it is about. A stranger is still a stranger
    /// and an unsigned stream is still unsigned whatever it says, because
    /// neither of those is a person whose SCOPE could be widened: there is one
    /// classifier, and this is a fact it carries rather than a second opinion
    /// about who is waiting. It defaults to the P3a answer, so a caller that
    /// has no walk to ask — `AdmissionDecision.standing`, which only ever
    /// matches `.stranger` — is untouched.
    public static func holder(
        of pendingDevice: String, registry: Registry,
        startedAPiece: Bool = false
    ) -> Holder {
        holder(
            of: pendingDevice,
            isAStranger: registry.isStrangerDevice(pendingDevice),
            startedAPiece: startedAPiece)
    }

    /// **The same classifier, for a caller that has already been told who the
    /// strangers are** (P3b Task 7).
    ///
    /// The load stamps that split once, with the table it had in hand
    /// (`FileProvenance.pendingStrangerDevices` →
    /// `OpLogProvenance.pendingStrangersByDevice`), so a pane drawing a
    /// document's own counts can classify without reading the folder again —
    /// which on a `body` pass would be tripwire 4's shape.
    ///
    /// **One body, so there is still one classifier.** The overload above is
    /// this with the predicate asked of a registry instead of handed in; the
    /// unsigned branch is decided by the string either way, which is why an
    /// unsigned holder cannot be lost by a caller whose stranger set was
    /// computed before this rule existed.
    public static func holder(
        of pendingDevice: String, isAStranger: Bool,
        startedAPiece: Bool = false
    ) -> Holder {
        if let stream = streamOfUnsignedHolder(pendingDevice) {
            return .unsigned(stream: stream)
        }
        return isAStranger
            ? .stranger(fingerprint: pendingDevice)
            : .permitPending(person: pendingDevice, startedAPiece: startedAPiece)
    }

    // MARK: - What to say

    /// **What an unsigned stream IS**, in one phrase, said once.
    ///
    /// The sentence below puts it in a count; §7.4's door puts it on the
    /// capture a held paragraph comes back as. Two spellings would be two
    /// answers to *whose words are these*, and the wrong one is easy to reach
    /// for: a Mac with no enclave has no key, but telling a writer their other
    /// machine *has no key* describes a missing part rather than what is
    /// actually true of it, which is that nothing it writes is signed.
    public static let unsignedWriter = "a Mac that signs nothing it writes"

    /// **Where an unsigned stream's words come back**, said in the one place
    /// that knows whether the reader is standing in it (P3b Task 10).
    ///
    /// The unsigned arm is the only sentence here with a way back to name, and
    /// it named the Inbox everywhere — which in the Inbox PANE is a circle: it
    /// tells the writer to go where they already are, about captures that can
    /// never carry the door anyway (an inbox row decodes to `OpKind.unknown`,
    /// so `Deriver.appliesToManuscript` answers no and §7.4's verb offers it
    /// nothing). A parameter rather than a second sentence, so the two
    /// spellings cannot drift apart about what the words ARE.
    public enum WayBackIn: Equatable, Hashable, Sendable {
        /// History's held rows, where the **Send to Inbox** control lives.
        /// The answer everywhere except the Inbox itself.
        case theInboxDoor
        /// The Inbox pane's own answer: the door is on the other pane, and
        /// there is nothing to press here.
        case historysHeldRows
    }

    /// **One sentence per holder, and none of them is the others'.**
    ///
    /// `name` is the writer's word for whoever is waiting — the label the root
    /// gave them, else their four-character code — and is nil where there is
    /// nobody to name, which is every unsigned stream: a Mac with no key has
    /// no record, so the book has never been told what to call it.
    ///
    /// `notes` is the count of held OP lines, never the line tally: a held
    /// span's own seal line is one of those lines, and two held ops under one
    /// signature would read as three notes (`OpLogProvenance.pendingOpLines`
    /// is the sum that already makes that distinction).
    ///
    /// Nil for a count of nothing, so a surface drawing this never has to
    /// decide whether zero is worth a sentence.
    ///
    /// **`what` says what the lines ARE** (P3b smoke find F2). A held line of
    /// prose is not a note, and *1 note is waiting* over a paragraph Kit wrote
    /// told the writer the opposite of what was waiting. Where the caller has
    /// the kinds — `Waiting`, counted by the load — the sentence says them in
    /// the writer's terms (*2 paragraphs and 1 note*); where it has only a
    /// count (the capture stream, which holds no ops), it says *notes* as it
    /// always did.
    ///
    /// `pieceWasTakenFromThem` is the walk's own answer
    /// (`AmendmentPermits.whoKeptWritingInATakenPiece`): §4.5's line after a
    /// deliberate removal, where *nobody has claimed* would be false (Q1,
    /// ruled 2026-09-24). It reaches only the piece-start arm.
    public static func sentence(
        _ holder: Holder, notes count: Int, what: Waiting? = nil,
        named name: String? = nil,
        wayBackIn: WayBackIn = .theInboxDoor, pieceWasTakenFromThem: Bool = false
    ) -> String? {
        guard count > 0 else { return nil }
        let phrase = what?.phrase
        let noun = phrase.map(\.text) ?? "\(count) \(count == 1 ? "note" : "notes")"
        let verb = (phrase.map(\.isPlural) ?? (count != 1)) ? "are" : "is"
        switch holder {
        case .stranger:
            let who = name ?? "another device"
            return "\(noun) from \(who) \(verb) waiting for admission."
        case .permitPending(_, let startedAPiece):
            let who = name ?? "a device in this book"
            // **§4.5, and the only held line the writer can do something
            // about** (P3b Task 7). She wrote in a piece that is in nobody's
            // scope, which is a question rather than a violation — so the
            // sentence states the fact and names the one surface that can
            // settle it. It must not borrow the other arm's words: this build
            // reads her line perfectly well, and telling the writer to wait
            // for a newer Maugham would be telling them to wait for nothing.
            guard !startedAPiece else {
                if pieceWasTakenFromThem {
                    return "\(noun) from \(who) \(verb) waiting in a "
                        + "piece that was taken from them — they kept writing "
                        + "in it. Say whether to give it back in People & Devices."
                }
                return "\(noun) from \(who) \(verb) waiting in a piece "
                    + "nobody has claimed yet. Say whether the piece is theirs "
                    + "in People & Devices."
            }
            return "\(noun) from \(who) \(verb) waiting. This version "
                + "of Maugham can’t tell what they are allowed to write here; "
                + "a newer one will."
        case .unsigned:
            let where_ = wayBackIn == .theInboxDoor
                ? "can be brought back through the Inbox."
                : "is brought back from History."
            return "\(noun) \(verb) waiting from \(unsignedWriter). "
                + "There is no device to admit — what it wrote \(where_)"
        }
    }

    // MARK: - What is waiting (P3b smoke find F2)

    /// **What a holder's held lines ARE, in the writer's terms** — paragraphs
    /// of prose, notes, and other changes — with a few of the words.
    ///
    /// Every surface that counted held lines put *notes* after the number,
    /// whatever the lines were: the admission sheet said *1 note waiting* and
    /// History said *1 note is waiting in a piece no one has claimed yet* about
    /// a paragraph of prose (smoke find F2). The kinds are ASKED of
    /// `Permit.group(of:)` — the one exhaustive switch over `OpKind`, which
    /// itself asks `Deriver.appliesToManuscript` for prose (tripwire 44) —
    /// never restated here:
    ///
    /// - **prose** — the group that becomes words;
    /// - **notes** — the annotation layer: making a note, amending one, or
    ///   settling one;
    /// - **changes** — everything else: a task's life, a bookmark, a kind from
    ///   a later build.
    ///
    /// **Prose is counted by PARAGRAPH**, not by op: a writer typing one
    /// paragraph in three bursts wrote one paragraph, and *3 paragraphs* would
    /// be a number they cannot find. `prose` keeps the op count, and a prose op
    /// that names no paragraph at all is said as a change — counted in
    /// `anonymousProse`, so it is said even beside prose that does name one.
    public struct Waiting: Equatable, Sendable {
        /// Every paragraph a held prose op touched.
        public var paragraphIds: Set<String>
        /// Held op lines that would move the manuscript's words.
        public var prose: Int
        /// The held prose op lines among `prose` that named NO paragraph — a
        /// line from a later build, or one with no changes. No paragraph can
        /// count them, so the phrase says each as a change.
        public var anonymousProse: Int
        /// Held annotation-layer op lines — comments, suggestions, queries,
        /// craft notes, and edits and dispositions of them.
        public var notes: Int
        /// Every other held op line: tasks, bookmarks, unknown kinds.
        public var other: Int
        /// The words of the first held paragraph, as it last read in the held
        /// span, with task anchors taken out — for a peek, never for applying.
        /// At most `peekLimit` characters; a surface shortens it further.
        public var peek: String?

        public init(
            paragraphIds: Set<String> = [], prose: Int = 0, anonymousProse: Int = 0,
            notes: Int = 0, other: Int = 0, peek: String? = nil
        ) {
            self.paragraphIds = paragraphIds
            self.prose = prose
            self.anonymousProse = anonymousProse
            self.notes = notes
            self.other = other
            self.peek = peek
        }

        /// How much of a paragraph a peek keeps. Enough for any line a surface
        /// draws, small enough that a provenance carrying one per holder per
        /// file costs nothing to hold.
        public static let peekLimit = 280

        public var paragraphs: Int { paragraphIds.count }
        public var isEmpty: Bool { prose == 0 && notes == 0 && other == 0 }

        /// Two files' (or two documents') worth, as one. The first peek stands:
        /// it is the first words the writer will be shown either way.
        public func merged(with more: Waiting) -> Waiting {
            Waiting(
                paragraphIds: paragraphIds.union(more.paragraphIds),
                prose: prose + more.prose,
                anonymousProse: anonymousProse + more.anonymousProse,
                notes: notes + more.notes,
                other: other + more.other, peek: peek ?? more.peek)
        }

        /// **The noun phrase** — *1 paragraph*, *2 paragraphs and 1 note*,
        /// *1 paragraph, 2 notes and 1 change* — and whether a verb after it is
        /// plural. Nil when nothing is waiting.
        public var phrase: (text: String, isPlural: Bool)? {
            var parts: [(Int, String, String)] = []
            if paragraphs > 0 { parts.append((paragraphs, "paragraph", "paragraphs")) }
            if notes > 0 { parts.append((notes, "note", "notes")) }
            // A prose op that named no paragraph is still something held, and
            // a sentence that counted nothing would say less than is true —
            // whether or not other prose ops named one (whole-branch review
            // M5). With no paragraph named at all, every prose op is one of
            // them, which also covers a description built by hand from `prose`.
            let changes = other + (paragraphs == 0 ? prose : anonymousProse)
            if changes > 0 { parts.append((changes, "change", "changes")) }
            guard !parts.isEmpty else { return nil }
            let words = parts.map { "\($0.0) \($0.0 == 1 ? $0.1 : $0.2)" }
            let text = words.count == 1
                ? words[0]
                : words.dropLast().joined(separator: ", ") + " and " + words.last!
            return (text, parts.count > 1 || parts[0].0 != 1)
        }

        /// **Counted from the lines a walk classified**, keyed the way
        /// `OpLogChain.pendingByDevice` keys them — by the device the line is
        /// held under — and over OP lines only, for that function's reason:
        /// a seal is neither a paragraph nor a note.
        ///
        /// Each held op line is decoded ONCE, as an `Op`; only a line that will
        /// not decode is read again for its bare `kind` (`Op.kind(ofLine:)`),
        /// so a later build's shape is still counted rather than dropped. A
        /// load pays nothing here for a file that holds nothing.
        public static func byDevice(
            of lines: [OpLogChain.Line]
        ) -> [String: Waiting] {
            var answer: [String: Waiting] = [:]
            var peekParagraph: [String: String] = [:]
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = JSONLAppendStore<Op>.dateDecoding
            for line in lines where line.kind == .op {
                guard let device = line.state.pendingDevice else { continue }
                var waiting = answer[device] ?? Waiting()
                defer { answer[device] = waiting }
                let op = try? decoder.decode(Op.self, from: line.bytes)
                guard let kind = op?.kind ?? Op.kind(ofLine: line.bytes) else {
                    waiting.other += 1
                    continue
                }
                switch Permit.group(of: kind) {
                case .manuscriptText:
                    waiting.prose += 1
                    if (op?.changes ?? []).isEmpty { waiting.anonymousProse += 1 }
                case .annotationCreation, .ownAnnotation, .disposition:
                    waiting.notes += 1
                    continue
                case .checkpoint, .task, .translationRecord, .inboxRow, .unreadable:
                    waiting.other += 1
                    continue
                }
                for change in op?.changes ?? [] {
                    waiting.paragraphIds.insert(change.paragraphId)
                    let text = MarkdownDisplayFilter.stripTaskAnchorsInline(change.next)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    // The FIRST paragraph held, as it LAST reads: a paragraph
                    // typed in three bursts peeks at its third.
                    let first = peekParagraph[device] ?? change.paragraphId
                    peekParagraph[device] = first
                    if change.paragraphId == first {
                        waiting.peek = String(text.prefix(peekLimit))
                    }
                }
            }
            return answer
        }
    }
}
