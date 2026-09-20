import Foundation

/// **One person's permits, in the order they held** (P3 spec §3.4).
///
/// A permit is evaluated *as of the line*, never as of today. That one sentence
/// is the whole of this type, and both ways of getting it wrong are silent:
///
/// - Judge by today's permit and a **demotion reaches backwards**. Everything
///   she ever wrote as an author is set aside the moment she becomes a
///   reviewer — words already in the book, already read, already published.
/// - Judge by the permit at admission and a **promotion is a pardon**. What she
///   wrote while the permit said no is applied the moment it says yes, which
///   makes the refusal worth nothing: write it anyway, ask later.
///
/// So the history is its own value. Each entry is a `(permit, mark)`: the
/// permit an event installed, and — on the entry that installed it — the
/// `PermitMark` saying where the permit BEFORE it stopped. A line is under the
/// last entry whose mark judges it *new*; a line every mark judges *old* is
/// under the entry that opens the timeline.
///
/// **The person record is not consulted, ever.** Not the `role` field, not
/// `scope`, not `pieces` — a record is re-signed in place and so forgets its
/// own past, which is exactly the thing this type exists to remember. A person
/// with **no events has one entry: author of the whole book, no mark**, which
/// is what every P2-era admission meant and is what makes P3a behaviour-neutral
/// for every book already on disk. A record that SAYS reviewer with no event
/// behind it is still read as author here: the record being one step ahead of
/// the history is the crash window the spec's write order leaves (event, then
/// record), and it is detected and re-signed rather than enforced from here
/// (Task 7's `recordBehindEvents`).
///
/// **Pure, and it does no hashing of its own.** Judging a FILE against a mark
/// is `PermitMark.judge`'s, which hashes lines; this type asks for those
/// judgements and indexes them. That split is what lets a caller compute one
/// judgement per (file, entry) and then answer every line of the file from it,
/// rather than re-hashing a novel's tail once per line.
public struct PermitTimeline: Equatable, Hashable, Sendable {

    /// One permit, and where the one before it stopped.
    public struct Entry: Equatable, Hashable, Sendable {
        /// What the subject may write, from this entry's mark onwards.
        public let permit: Permit
        /// Where the PREVIOUS permit stopped, as chain positions (spec §3.3).
        /// Nil on the opening entry alone, which has no previous permit — and
        /// nil is not the same as empty: an empty mark is *nothing had been
        /// applied*, and judges every line new.
        public let mark: PermitMark?
        /// The event that installed this permit — its id, its kind and its
        /// date — so a surface can name what happened without re-reading the
        /// folder. All nil on the opening entry, which no event installed.
        public let event: String?
        public let kind: PermitEvent.Kind?
        public let at: Date?

        public init(
            permit: Permit, mark: PermitMark?,
            event: String? = nil, kind: PermitEvent.Kind? = nil, at: Date? = nil
        ) {
            self.permit = permit
            self.mark = mark
            self.event = event
            self.kind = kind
            self.at = at
        }

        /// The entry every timeline opens with: what this book meant before
        /// anybody wrote a permit down.
        public static let opening = Entry(permit: .bookAuthor, mark: nil)
    }

    /// Oldest first, and **never empty** — the opening entry is always there,
    /// so `entries[0]` and `current` are always answerable.
    public let entries: [Entry]

    /// A person with no events at all: author of the whole book, from the
    /// start. Every P2 admission, and every root.
    public static let bookAuthor = PermitTimeline(events: [])

    // MARK: - Building one

    /// One person's timeline from their own verified events.
    ///
    /// **Ordered by event id**, which is `<subject>.<ULID>` — monotonic within
    /// a subject, so the ids of one person's events sort into the order they
    /// were made whatever order the folder listed them in.
    ///
    /// **Which kinds install a permit**, and why the others do not:
    ///
    /// - `admitted`, `silentlyAdmitted`, `roleChanged`, `scopeChanged` and
    ///   `readmitted` each say what the subject may write from their mark on.
    /// - `revoked`, `revokedEntirely` and `retired` say a person or a machine
    ///   has STOPPED, which is not a permit at all: `TrustVerdict` already has
    ///   `.revoked` and `.retired` arms and they outrank everything here. An
    ///   entry for one would restate a rule that lives somewhere else, and the
    ///   role these events carry is the state they found rather than a change
    ///   they make.
    /// - An `unknown` kind — a later build's verb — installs `.unjudgeable`,
    ///   so everything after its mark is held PENDING. That is the global rule
    ///   (spec §3.1, §4.2) applied to the one field that decides whether an
    ///   event means anything at all: skipping it would apply lines under a
    ///   permit a newer Mac may have narrowed, and refusing them would
    ///   quarantine what a newer Mac applies.
    public init(events: [PermitEvent]) {
        let ordered = events.sorted(by: { $0.event < $1.event })
        var built: [Entry] = [Self.opening(before: ordered)]
        for event in ordered {
            guard let permit = Self.installedPermit(of: event) else { continue }
            built.append(Entry(
                permit: permit, mark: PermitMark(event.mark),
                event: event.event, kind: event.kind, at: event.at))
        }
        entries = built
    }

    /// **What governs a line written before this person's first event**
    /// (P3a Task 5's fix round 3).
    ///
    /// The opening entry is where every line lands that every mark judges
    /// OLD, and reading it as *author of the whole book* unconditionally is
    /// wrong in one direction and load-bearing in the other:
    ///
    /// - **A stranger's held lines are SEEN.** So the `admitted` event that
    ///   lets them in carries a mark naming them, they judge OLD, and they
    ///   fall to the opening entry — which would apply a REVIEWER's manuscript
    ///   text as a book author's, the moment she was admitted. There is
    ///   nothing before an admission: that event's permit governs everything
    ///   the person ever wrote, on both sides of its mark, and the mark is
    ///   meaningless for judging (the entry the event installs carries the
    ///   same permit, so which side a line falls on does not matter).
    /// - **A role or scope change is not an admission.** A person whose first
    ///   event is one of those was admitted under P2, with no `admitted` event
    ///   to point at, and **P2 admitted everybody as an author of the whole
    ///   book**. Reading the opening as anything else would make every
    ///   demotion reach back through work the writer has read for months.
    ///
    /// An `unknown` first kind is **pending**: this build cannot tell whether
    /// a later one's first event was an admission, and the two answers are not
    /// interchangeable. Pending is recoverable; applying wrongly is not.
    ///
    /// `revoked` / `revokedEntirely` / `retired` are skipped, because they
    /// install no entry at all — they are the VERDICT's business, and the role
    /// they carry is the state they found rather than a change they make.
    private static func opening(before ordered: [PermitEvent]) -> Entry {
        guard let first = ordered.first(where: { installedPermit(of: $0) != nil })
        else { return .opening }
        switch first.kind {
        case .admitted, .silentlyAdmitted:
            return Entry(permit: Permit(event: first), mark: nil)
        case .roleChanged, .scopeChanged, .readmitted:
            return .opening
        case let .unknown(raw):
            return Entry(permit: .unjudgeable(raw: raw), mark: nil)
        case .revoked, .revokedEntirely, .retired:
            // Unreachable — `installedPermit` answered nil for these, so
            // `first(where:)` skipped them. Spelled rather than defaulted, so
            // a ninth kind is a compile error here too.
            return .opening
        }
    }

    /// A timeline built from entries directly — the door a test uses to state
    /// a history as a value, and the one `bookAuthor` is made through.
    public init(entries: [Entry]) {
        self.entries = entries.isEmpty ? [.opening] : entries
    }

    /// The permit an event installs, or nil where the event installs none.
    private static func installedPermit(of event: PermitEvent) -> Permit? {
        switch event.kind {
        case .admitted, .silentlyAdmitted, .roleChanged, .scopeChanged, .readmitted:
            return Permit(event: event)
        case .revoked, .revokedEntirely, .retired:
            return nil
        case let .unknown(raw):
            return .unjudgeable(raw: raw)
        }
    }

    // MARK: - Asking it

    /// The permit in force NOW — what a device may write today.
    ///
    /// The load seam asks this (spec §4.6): whether to mint a `bootstrap` is a
    /// question about this moment, not about a line that already exists.
    /// Anything judging LINES asks `permits(forFile:lineCount:)` instead.
    public var current: Permit { entries.last?.permit ?? .bookAuthor }

    /// Has anything ever happened to this permit? False is the P2-era book.
    public var hasEvents: Bool { entries.count > 1 }

    /// **Which permit each line of one file was written under.**
    ///
    /// `judgements` runs parallel to `entries`: index *i* is this file judged
    /// against `entries[i].mark`, and nil where that entry has no mark (the
    /// opening entry, always) or where the caller chose not to judge it. One
    /// judgement per (file, entry) — `PermitMark.judge` walks and hashes every
    /// line up to the cut, so a caller that asked it per LINE would hash a
    /// novel's tail once per line of it.
    ///
    /// The walk is newest-to-oldest and takes the first entry whose mark says
    /// **new**: a line after the latest cut is under the latest permit, a line
    /// between two cuts is under the permit installed by the earlier of them,
    /// and a line before every cut is under the opening entry. That is both
    /// halves of spec §5 in one rule — the demotion does not reach back, and
    /// the promotion does not pardon.
    public func permits(
        forFile judgements: [PermitMark.Judgement?], lineCount: Int
    ) -> [Permit] {
        (0..<max(0, lineCount)).map { permit(ofLineAt: $0, judgements: judgements) }
    }

    /// `permits(forFile:lineCount:)` with the judging left to the caller's
    /// closure, called **once per entry that has a mark** and never per line.
    ///
    /// The shape a reader in front of a file actually wants: it holds the
    /// stream key, the segment digest and the lines, and every entry asks the
    /// same question of them.
    public func permits(
        lineCount: Int, judging: (PermitMark) -> PermitMark.Judgement
    ) -> [Permit] {
        permits(
            forFile: entries.map { entry in entry.mark.map(judging) },
            lineCount: lineCount)
    }

    /// One line's permit, from the same judgements.
    public func permit(
        ofLineAt index: Int, judgements: [PermitMark.Judgement?]
    ) -> Permit {
        governingEntry(ofLineAt: index, judgements: judgements).permit
    }

    /// **The whole entry that governs a line**, not just its permit — which is
    /// what a REFUSAL needs: the sentence a writer reads differs depending on
    /// whether the line was written after something changed (*…after it
    /// stopped being hers*) or under the permit the person has always had, and
    /// the entry's own `mark` is the one thing that tells the two apart. The
    /// opening entry is the only one with no mark.
    ///
    /// The walk is the one `permit(ofLineAt:)` has always been — newest to
    /// oldest, the first entry whose mark judges the line *new* — spelled once
    /// so the permit and the entry it came from cannot drift apart.
    public func governingEntry(
        ofLineAt index: Int, judgements: [PermitMark.Judgement?]
    ) -> Entry {
        for position in entries.indices.reversed() {
            guard position < judgements.count,
                  let judgement = judgements[position],
                  judgement.side(ofLineAt: index) == .new
            else { continue }
            return entries[position]
        }
        return entries.first ?? .opening
    }

    /// `permits(lineCount:judging:)`'s entry-bearing twin, with the same
    /// once-per-entry judging contract.
    public func governingEntries(
        lineCount: Int, judging: (PermitMark) -> PermitMark.Judgement
    ) -> [Entry] {
        let judgements = entries.map { entry in entry.mark.map(judging) }
        return (0..<max(0, lineCount)).map {
            governingEntry(ofLineAt: $0, judgements: judgements)
        }
    }
}
