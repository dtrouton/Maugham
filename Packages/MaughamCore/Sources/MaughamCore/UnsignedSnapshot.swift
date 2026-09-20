import Foundation

/// **The photograph the book takes of its unsigned streams the first time
/// anybody is narrowed** (P3b Task 1; Denver's ruling of 2026-09-20, option B).
///
/// ## The hole
///
/// A file this register can name no key for — no seal it can attribute, no
/// device record naming its slug — is applied UNJUDGED. That is P1's design
/// and it is deliberate: being unsigned is a first-class state (a Mac with no
/// Secure Enclave, a VM, CI's runner), and such a device writes chained lines
/// that nothing seals and is told nothing is wrong. In a book where everybody
/// may write everything, nothing turns on it. The moment somebody may NOT, it
/// is the ladder's one open door: a client that simply never seals walks past
/// every role in it.
///
/// ## Why it cannot be closed by refusing
///
/// Refuse unattributable lines in a narrowed book and the day the root first
/// makes somebody a reviewer, every word an enclave-less Mac ever wrote is
/// withdrawn from every signed Mac at once — and every note it withdrew comes
/// back, and every note edit reverts. That is the demotion rule inverted:
/// **narrowing must not reach back**.
///
/// ## What it does instead
///
/// The first NARROWING event (not the first permit event — an admission
/// changes nothing about who may write what) records where every unattributable
/// stream in the book stood, in P3a's own chain-position form. Then:
///
/// - **At or before the snapshot**: exactly P1. Manuscript text stays applied,
///   and an unsigned Mac's note edits and withdrawals stay honoured.
/// - **After it**: an unattributable line is PENDING — held, never set aside
///   (nothing is wrong with it), never pardonable by an admission (there is no
///   key to admit). Its one way in is Send to Inbox.
///
/// An un-narrowed or registerless book is untouched, and narrowing is STICKY
/// (`TrustTable.hasNarrowingPermits` reads every entry of every timeline), so
/// there is no un-narrowing direction to think about.
///
/// ## Which snapshot governs
///
/// **The earliest narrowing event's**, by the event's own id ordering — never
/// the newest. A later narrowing that superseded the first would MOVE the
/// cliff, and moving it forward applies lines that had been held while moving
/// it back withdraws lines that had been applied; the first narrowing is the
/// moment the book started caring, and it is the only position that does not
/// move again.
///
/// Event ids are `<subject>.<ULID>`, so within one subject the ordering is
/// chronological. Across subjects — and across two roots that have adopted
/// each other — it is deterministic rather than chronological, and
/// determinism is the load-bearing half: every device must reach the same
/// answer from the same bytes, and a date is a number its own writer chose.
///
/// ## What it is not
///
/// It is not built from this device's memory, and it holds no opinion of its
/// own about old and new: `side(streamKey:…)` delegates to `PermitMark.judge`,
/// which is the one rule for reading a position, so the file this build reads
/// and the rule a later one applies cannot become two opinions living in one
/// type.
public struct UnsignedSnapshot: Equatable, Hashable, Sendable {

    /// The id of the narrowing event whose photograph this is — kept so a
    /// surface, a diagnostic or a later reader can say WHICH act drew the line
    /// without walking the folder again.
    public let event: String

    /// When that event was made. Display only: nothing here decides by it.
    public let at: Date

    /// Where each unattributable stream stood. **Empty is a real value** — a
    /// book with nothing unattributable in it when it was first narrowed, and
    /// also a narrowed book whose governing event predates this field
    /// entirely, which reads as *everything unattributable is after*.
    public let mark: PermitMark

    public init(event: String, at: Date, mark: PermitMark) {
        self.event = event
        self.at = at
        self.mark = mark
    }

    /// **The governing snapshot for a book, or nil where nothing narrows it.**
    ///
    /// `events` is every verified permit event the register holds, with root
    /// subjects already excluded — which is exactly the collection
    /// `TrustTable.resolve` builds its timelines from, and is why the two
    /// cannot disagree about whether this book is narrowed. (A root is an
    /// author of the whole book unconditionally; `RegistryReader` lists an
    /// event that says otherwise malformed, and `TrustTable` skips it besides.)
    ///
    /// Nil is *there is no narrowing event*, which is the same condition
    /// `TrustTable.hasNarrowingPermits` answers false to — the equivalence is
    /// pinned rather than assumed.
    public static func governing(events: [PermitEvent]) -> UnsignedSnapshot? {
        guard let first = events
            .filter({ PermitTimeline.narrows($0) })
            .min(by: { $0.event < $1.event })
        else { return nil }
        return UnsignedSnapshot(
            event: first.event, at: first.at,
            mark: PermitMark(first.unsigned ?? [:]))
    }

    /// **Which side of the photograph each line of one file falls on.**
    ///
    /// `PermitMark.judge`'s three rules, unchanged and un-restated: a segment
    /// whose digest the snapshot lists is wholly *old*; the file holding the
    /// marked line is *old* through it and *new* after; everything else, and
    /// every stream this snapshot does not name, is wholly *new*.
    ///
    /// *Old* means **applied exactly as P1 applied it**; *new* means held. The
    /// words `old` and `new` say nothing about either — that reading is the
    /// caller's, as it is for every other mark.
    public func side(
        streamKey: String,
        fileIsSegmentWithDigest digest: String?,
        lines: [Data]
    ) -> PermitMark.Judgement {
        mark.judge(
            streamKey: streamKey, fileIsSegmentWithDigest: digest, lines: lines)
    }
}
