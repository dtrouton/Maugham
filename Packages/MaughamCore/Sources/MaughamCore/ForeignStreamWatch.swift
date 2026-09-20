import Foundation

/// **This device noticing that another device's stream has got shorter**
/// (signed op log P3a Task 9, spec §4.7).
///
/// P1 gave this device a memory of the head it last WROTE into each of its own
/// files, and that memory is what catches an agent appending a correctly
/// chained line to a file it does not own. It says nothing about anybody
/// else's files: another Mac's history could be cut back to a seal and every
/// rule the chain has would still hold, because the bytes that remain follow
/// from each other perfectly.
///
/// So this device remembers, per FOREIGN stream, the hash of the last line it
/// saw that stream's chain verify and the digest of every sealed segment of it
/// it took in whole. A later load that cannot find one of those has met a
/// stream somebody shortened.
///
/// **What it never does.** It refuses no load, sets no line aside and holds
/// nothing back. The lines that remain are good and they stay applied — that
/// is the whole of the spec's clause, and it is why this is a REPORT (the
/// integrity channel, and P3b's dated History entry) rather than a verdict.
///
/// **A stream is remembered only once it has ANSWERED** (fix round 1's
/// Important). A file can be present, readable and yet yield nothing this
/// device can point at — a zero-byte `.jsonl` that has synced ahead of its
/// contents, or one whose first line is corrupt so every line after it is
/// `chainBroke` and none was ever *seen*. `positions` names no such stream in
/// a mark, so remembering it would make `expectedStreams` demand a name the
/// sweep can never produce, and the root's verbs would refuse for ever over a
/// file that is sitting there perfectly readable, with nothing the writer
/// could do about it short of deleting this memory. So the ENTRY's existence
/// is the fact *this device has applied something of theirs*: nothing answers,
/// nothing is written. Once an entry exists it is kept — a stream that
/// answered and has stopped answering is the truncation case, and it is
/// supposed to refuse.
///
/// **Keyed by stream, and why the digests are here.** A rotation copies the
/// live tail into a `.mzseg` and deletes the tail, so the remembered line moves
/// from one filename into another while staying in the same stream. The key is
/// therefore `PermitMark.stream(of:)`'s and never a filename. That alone is not
/// enough: a segment that settled is never walked (its container signature
/// settles it whole, and the fast path counts its lines rather than splitting
/// them), so after a rotation the remembered line is inside a file this load
/// has no lines for. A **new segment digest** closes it — a tail that no longer
/// holds the remembered line while the stream has taken in a segment it had not
/// seen before has rotated. The digests do a second job the count they replaced
/// could not: a digest this device remembers that is in NO segment of the
/// stream now is a SEGMENT that went missing, which is history lost even though
/// every line still applied stays applied.
///
/// **It costs one hash comparison in the steady state.** A file nobody has
/// touched answers its remembered head as `Verification.head`, which the walk
/// has already computed; a file that grew is searched from the END, so the scan
/// is as long as what was appended. Only a stream that has genuinely lost its
/// line pays a pass over the whole file.
public final class ForeignStreamWatch: @unchecked Sendable {

    /// One stream as this load found it, gathered across however many files it
    /// is spread over.
    private struct Sighting {
        let slug: String
        let root: URL
        var tailHead: String?
        /// The digest of every segment this load took in WHOLE — the same
        /// answer a mark's `segments` list is built from, so the memory and the
        /// sweep cannot disagree about what this stream is made of.
        var digests: Set<String> = []
        /// A `.mzseg` that is present and yielded no digest: evicted, corrupt,
        /// or signed by a key this device cannot settle it by. **It is not a
        /// deletion**, and while one is here no digest is reported missing —
        /// under-counting the segments must never read as somebody removing
        /// one.
        var sawUnsettledSegment = false
        var holdsRemembered = false
    }

    private let projectURL: URL
    private let state: OpLogDeviceState
    /// The slugs of THIS device's own streams. They are `OpLogDeviceState
    /// .heads`' business — a per-file memory with a stricter meaning, which the
    /// chained write depends on — and remembering them twice would be two
    /// answers to where this device's own history stands.
    private let mine: Set<String>
    private let lock = NSLock()
    private var sightings: [String: Sighting] = [:]

    public init(projectURL: URL, state: OpLogDeviceState, mine: Set<String>) {
        self.projectURL = projectURL
        self.state = state
        self.mine = mine
    }

    /// The slugs this device's own files are named for. ENUMERATES — `all`
    /// answers over the actors whose key already exists and mints none, which
    /// is the rule every read path obeys (`LocalIdentities`).
    public static func slugs(of identities: LocalIdentities) -> Set<String> {
        Set(identities.all.map { DeviceSlug.make(from: $0.deviceId).raw })
    }

    // MARK: - Observing

    /// One file of one stream, as the load classified it.
    ///
    /// `verification` is nil exactly where the load has no lines to offer — a
    /// segment settled by its own signature or by this device's memory of its
    /// digest, or a container that failed before a line could be walked.
    ///
    /// `segmentDigest` is `FileClassification.wholeSegmentDigest`: the digest
    /// of a segment this reader took in WHOLE, and the very value a mark's
    /// `segments` list is built from. Nil for a tail, and nil for a segment
    /// that did not settle and could not be walked to its end — which is the
    /// *present but not readable through* case, and must never read as a
    /// deletion.
    public func observe(
        url: URL, verification: OpLogChain.Verification?,
        segmentDigest: String? = nil
    ) {
        guard let stream = PermitMark.stream(of: url),
              // The legacy unsuffixed `<docId>.jsonl` is nobody's stream — it
              // is the one file with more than one writer, which is why a mark
              // never names it either.
              let slug = stream.deviceSlug,
              !mine.contains(slug)
        else { return }
        let root = OpLogDeviceState.projectRoot(of: url) ?? projectURL
        lock.lock()
        defer { lock.unlock() }
        var sighting = sightings[stream.key] ?? Sighting(slug: slug, root: root)
        if url.pathExtension == OpLogSegment.fileExtension {
            if let segmentDigest {
                sighting.digests.insert(segmentDigest)
            } else {
                sighting.sawUnsettledSegment = true
            }
        } else if let verification, let head = verification.head {
            // The tail, and only the tail, is where the next line goes — so it
            // is the only file whose last line can be the stream's newest one.
            // Nothing here reads a segment index: a filename is the writer's to
            // choose, which is the whole reason a mark is not one either.
            sighting.tailHead = head
        }
        if let verification, !sighting.holdsRemembered,
           let remembered = state.foreignStream(stream.key, inRoot: root)?.head {
            sighting.holdsRemembered = Self.holds(remembered, verification)
        }
        sightings[stream.key] = sighting
    }

    // MARK: - The one predicate

    /// **What one stream lost, given what this device remembers of it and what
    /// a reader just found** — the one answer, shared by the load's watch and
    /// by a registry verb's position sweep (final fix wave, W2).
    ///
    /// It used to live inline in `settle`, which made the sweep's own
    /// short-mark guard a second opinion waiting to be written: the sweep
    /// checked that a stream's NAME came back and nothing else, so a rotation
    /// whose tail deletion reached the root's disk before its new segment did
    /// produced a mark naming the stream with the line gone — and the root's
    /// Revoke (*keep what was applied*) then set aside words this Mac had
    /// already applied. Every device inherits that cut, because the mark is a
    /// signed shared event.
    ///
    /// **The rotation tolerance is the whole subtlety.** A tail that no longer
    /// holds the remembered line while the stream has taken in a segment digest
    /// this device had not seen has ROTATED: the line moved into the segment,
    /// nothing was lost, and a reader that called that a truncation would
    /// refuse every verb after every maintenance pass. A digest this device
    /// remembers that no segment carries now is a segment that went missing,
    /// which is a loss the count this replaced could not see; it is never
    /// computed while a `.mzseg` is present and unsettled, because that file's
    /// digest is unknown rather than gone.
    public enum Loss: Equatable, Sendable {
        /// The remembered last line of the tail is nowhere in the stream.
        case line(String)
        /// A segment this device had taken in whole is no longer there.
        case segment(String)
    }

    /// What a reader found for one stream — the sweep's side of the predicate,
    /// and what `Sighting` reduces to.
    public struct Found: Equatable, Sendable {
        /// Digests of the segments this reader took in whole.
        public var digests: Set<String>
        /// A `.mzseg` that is present and yielded no digest.
        public var sawUnsettledSegment: Bool
        /// Did the tail this reader walked hold the remembered line?
        public var holdsRemembered: Bool
        /// Did this stream say anything at all that a mark can name?
        public var answered: Bool

        public init(
            digests: Set<String> = [], sawUnsettledSegment: Bool = false,
            holdsRemembered: Bool = false, answered: Bool = false
        ) {
            self.digests = digests
            self.sawUnsettledSegment = sawUnsettledSegment
            self.holdsRemembered = holdsRemembered
            self.answered = answered
        }
    }

    /// Nil where nothing was lost. See `Loss` for the two arms and the
    /// tolerance between them.
    public static func loss(
        remembered: OpLogDeviceState.ForeignStreamMemory?, found: Found
    ) -> Loss? {
        guard let remembered else { return nil }
        let rotated = !found.digests.subtracting(remembered.segmentDigests).isEmpty
        let missing = found.sawUnsettledSegment
            ? []
            : remembered.segmentDigests.subtracting(found.digests)
        if let lost = remembered.head, !found.holdsRemembered, !rotated {
            return .line(lost)
        }
        if let gone = missing.sorted().first { return .segment(gone) }
        return nil
    }

    /// Is this hash one of these lines? The head first, because a file nobody
    /// has touched since the last load answers there for free; then backwards,
    /// because a file that GREW holds the remembered line just behind whatever
    /// was appended to it.
    public static func holds(_ hash: String, _ verification: OpLogChain.Verification) -> Bool {
        if verification.head == hash { return true }
        for line in verification.lines.reversed()
        where OpLogChain.lineHash(line.bytes) == hash {
            return true
        }
        return false
    }

    // MARK: - Settling

    /// Write what this load saw, and record what it could not find.
    ///
    /// **A stream with no files at all never reaches here**, and that is the
    /// distinction the spec draws: a stream whose every file is ABSENT is not
    /// truncated, it is missing — iCloud has moved it, or a sync is halfway
    /// through — and the act that must not proceed over that is a registry
    /// verb's position sweep (`expectedStreams`), not a load. A load says
    /// nothing at all about it.
    public func settle(now: () -> Date = { Date() }) {
        lock.lock()
        let found = sightings
        lock.unlock()
        guard !found.isEmpty else { return }

        var updates: [OpLogDeviceState.ForeignStreamUpdate] = []
        for (key, sighting) in found {
            let remembered = state.foreignStream(key, inRoot: sighting.root)
            // **Did this stream say anything this device can point at?** A
            // line hash, or a segment it took in whole. Nothing else counts,
            // because nothing else is a thing `positions` can put in a mark.
            let answered = sighting.tailHead != nil || !sighting.digests.isEmpty
            guard remembered != nil || answered else { continue }

            // **The predicate, asked rather than spelled** (final fix wave,
            // W2). `loss` is the one answer to *what did this stream lose*,
            // and a registry verb's position sweep asks the same function of
            // the same memory — a second spelling of the rotation tolerance
            // would have the load call a rotation maintenance while the sweep
            // called it a truncation, or the reverse.
            let found = Found(
                digests: sighting.digests,
                sawUnsettledSegment: sighting.sawUnsettledSegment,
                holdsRemembered: sighting.holdsRemembered,
                answered: answered)
            let rotated = !sighting.digests
                .subtracting(remembered?.segmentDigests ?? []).isEmpty
            let missing = sighting.sawUnsettledSegment
                ? []
                : (remembered?.segmentDigests ?? []).subtracting(sighting.digests)

            let truncation: OpLogDeviceState.StreamTruncation? =
                switch Self.loss(remembered: remembered, found: found) {
                case let .line(lost):
                    .init(streamKey: key, deviceSlug: sighting.slug, loss: .line,
                          lost: lost, noticedAt: now())
                case let .segment(gone):
                    .init(streamKey: key, deviceSlug: sighting.slug, loss: .segment,
                          lost: gone, noticedAt: now())
                case nil:
                    nil
                }

            // **A stream moves its memory on only when it lost nothing.**
            // Two clauses, and each is load-bearing. It must have ANSWERED, or
            // the emptiness that IS the loss would overwrite the position whose
            // absence is the finding. And nothing must be missing, or the very
            // next load would find what it now remembers, call the loss made
            // good and clear a finding about history that is still gone — a
            // truncation that erased itself one open later. A stream with a
            // standing loss keeps the position it lost, so the finding stands
            // until those bytes come back, and `settleForeign` keeps the day it
            // was first noticed.
            let memory: OpLogDeviceState.ForeignStreamMemory? = (answered && truncation == nil)
                ? .init(
                    deviceSlug: sighting.slug,
                    head: sighting.tailHead ?? (rotated ? nil : remembered?.head),
                    segmentDigests: sighting.digests.union(
                        sighting.sawUnsettledSegment
                            ? (remembered?.segmentDigests ?? [])
                            : []))
                : nil
            updates.append(.init(
                streamKey: key, root: sighting.root,
                memory: memory, truncation: truncation,
                clearsTruncation: truncation == nil
                    && (remembered?.head == nil || sighting.holdsRemembered)
                    && missing.isEmpty))
        }
        state.settleForeign(updates)
    }

    // MARK: - The one-file door

    /// A stream that is ONE file — a translation sidecar, an inbox manifest —
    /// observed and settled in one act.
    ///
    /// It refuses an `ops` stream on purpose. Only the op log rotates, and the
    /// rotation tolerance is a fact about the stream rather than about the file
    /// in hand, so an op-log file judged alone would read its own rotation as a
    /// truncation. The op log goes through a `ForeignStreamWatch` that sees
    /// every file of the document before it settles.
    public static func note(
        url: URL, verification: OpLogChain.Verification?,
        projectURL: URL, state: OpLogDeviceState, mine: Set<String>,
        now: () -> Date = { Date() }
    ) {
        guard let stream = PermitMark.stream(of: url), stream.kind != .ops else { return }
        let watch = ForeignStreamWatch(projectURL: projectURL, state: state, mine: mine)
        watch.observe(url: url, verification: verification)
        watch.settle(now: now)
    }
}
