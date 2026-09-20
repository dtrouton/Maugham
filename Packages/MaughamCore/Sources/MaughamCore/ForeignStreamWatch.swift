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
/// saw that stream's chain verify. A later load that cannot find that line
/// anywhere in the stream has met a stream somebody shortened.
///
/// **What it never does.** It refuses no load, sets no line aside and holds
/// nothing back. The lines that remain are good and they stay applied — that
/// is the whole of the spec's clause, and it is why this is a REPORT (the
/// integrity channel, and P3b's dated History entry) rather than a verdict.
///
/// **Keyed by stream, and why the segment count is here.** A rotation copies
/// the live tail into a `.mzseg` and deletes the tail, so the remembered line
/// moves from one filename into another while staying in the same stream. The
/// key is therefore `PermitMark.stream(of:)`'s and never a filename. That
/// alone is not enough: a settled segment is never walked (its container
/// signature settles it whole, and the fast path deliberately counts its lines
/// rather than splitting them), so after a rotation the remembered line is in a
/// file this load has no lines for. The stream's SEGMENT COUNT closes it — a
/// tail that no longer holds the remembered line while the stream has grown a
/// segment has rotated. Both halves are per stream, which is what makes
/// keying on the filename fail loudly rather than quietly (the rotation pin in
/// `ForeignHeadTests`).
///
/// **It costs one hash comparison in the steady state.** A file nobody has
/// touched answers its remembered head as `Verification.head`, which the walk
/// has already computed; a file that grew is searched from the END, so the
/// scan is as long as what was appended. Only a stream that has genuinely lost
/// its line pays a pass over the whole file, and it pays it once — the memory
/// moves on to what is there now, so the second load finds what it remembers.
public final class ForeignStreamWatch: @unchecked Sendable {

    /// One stream as this load found it, gathered across however many files it
    /// is spread over.
    private struct Sighting {
        let slug: String
        let root: URL
        var tailHead: String?
        var segments = 0
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
    /// segment settled by its own signature, or a container that failed before
    /// a line could be walked. Such a file still COUNTS as a segment, which is
    /// the rotation tolerance; it simply cannot answer whether the remembered
    /// line is inside it.
    public func observe(url: URL, verification: OpLogChain.Verification?) {
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
            sighting.segments += 1
            if let verification, !sighting.holdsRemembered,
               let remembered = remembered(stream.key, root)?.head {
                sighting.holdsRemembered = Self.holds(remembered, verification)
            }
        } else if let verification {
            // The tail, and only the tail, is where the next line goes — so it
            // is the only file whose last line can be the stream's newest one.
            // Nothing here reads a segment index: a filename is the writer's to
            // choose, which is the whole reason a mark is not one either.
            if let head = verification.head { sighting.tailHead = head }
            if !sighting.holdsRemembered,
               let remembered = remembered(stream.key, root)?.head {
                sighting.holdsRemembered = Self.holds(remembered, verification)
            }
        }
        sightings[stream.key] = sighting
    }

    private func remembered(_ key: String, _ root: URL) -> OpLogDeviceState.ForeignStreamMemory? {
        state.foreignStream(key, inRoot: root)
    }

    /// Is this hash one of these lines? The head first, because a file nobody
    /// has touched since the last load answers there for free; then backwards,
    /// because a file that GREW holds the remembered line just behind whatever
    /// was appended to it.
    private static func holds(_ hash: String, _ verification: OpLogChain.Verification) -> Bool {
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
            var truncation: OpLogDeviceState.StreamTruncation?
            if let lost = remembered?.head, !sighting.holdsRemembered,
               sighting.segments <= (remembered?.segments ?? 0) {
                truncation = .init(
                    streamKey: key, deviceSlug: sighting.slug,
                    lostHead: lost, noticedAt: now())
            }
            updates.append(.init(
                streamKey: key, root: sighting.root,
                memory: .init(
                    deviceSlug: sighting.slug,
                    head: sighting.tailHead,
                    segments: sighting.segments),
                truncation: truncation))
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
