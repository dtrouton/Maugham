// Packages/MaughamCore/Sources/MaughamCore/StreamCensus.swift
import Foundation

/// The census of history this Mac remembers and cannot find: truncated
/// streams, absent streams, and the lost-history drawer's one derivation.
/// Split out of `OpLogStore` (foundations plan 6); `OpLogStore` keeps
/// forwarders so callers are unchanged.
public enum StreamCensus {
    /// **A foreign stream this device has found shorter than it remembered
    /// it**, with the device named the way every other finding names one
    /// (P3a Task 9, spec §4.7).
    public struct TruncatedStream: Equatable, Sendable {
        public let truncation: OpLogDeviceState.StreamTruncation
        /// The writer's word for whose stream it was: the label the root gave
        /// them, else their four-character code, else — with no table to ask —
        /// the slug their files are named for.
        public let label: String

        public var streamKey: String { truncation.streamKey }
        public var deviceSlug: String { truncation.deviceSlug }
        public var noticedAt: Date { truncation.noticedAt }

        /// **What went missing, in the writer's words** — and the two losses
        /// are different enough to say apart (fix round 1, minor 1).
        ///
        /// A LINE loss is the live tail having been cut back; a SEGMENT loss
        /// is a whole sealed span of history that is not in the folder any
        /// more. Neither takes a word out of the draft — what was applied
        /// stays applied — so both sentences end the same way, pointing at the
        /// one place a writer can get the lost history back from.
        public var sentence: String {
            let what = truncation.loss == .segment
                ? "part of \(label)’s sealed history is missing from this book"
                : "\(label)’s history here is shorter than it was"
            return "\(what.prefix(1).uppercased())\(what.dropFirst()). "
                + "Nothing has left the draft — every word Maugham had already "
                + "applied is still in it — but what is gone is gone from the "
                + "folder. A backup is where it can be got back from."
        }

        public init(truncation: OpLogDeviceState.StreamTruncation, label: String) {
            self.truncation = truncation
            self.label = label
        }
    }

    /// **What this device has noticed going missing from other devices'
    /// streams**, oldest first — P3b's History entry and the integrity
    /// report's own finding, read from one place.
    ///
    /// It reads a memory and touches no file of the project: the finding was
    /// recorded at the load that met it, because a load is the only reader
    /// that ever held both the remembered line and the bytes that no longer
    /// carry it.
    ///
    /// `trust` is optional for the reason the keyless readers exist: a caller
    /// that already holds a verified table names the device, and one that
    /// holds none — `ProjectIntegrity.check` — still names the stream, which is
    /// the fact the writer acts on.
    nonisolated public static func truncatedStreams(
        in projectURL: URL, state: OpLogDeviceState, trust: TrustTable? = nil
    ) -> [TruncatedStream] {
        state.truncations(inRoot: projectURL).map { truncation in
            TruncatedStream(
                truncation: truncation,
                label: trust?.label(forDeviceSlug: truncation.deviceSlug)
                    ?? truncation.deviceSlug)
        }
    }

    // MARK: - History this book is missing (P3b Task 6)

    /// **One piece of history this Mac remembers and cannot find**, in the
    /// shape History draws and the writer acknowledges.
    ///
    /// It has two sources and they are not interchangeable:
    ///
    /// - A **truncation**, which a LOAD recorded when it met a stream shorter
    ///   than it remembered it. The stream is still there; part of it is not.
    /// - An **absent** stream: the memory names it and the folder holds no
    ///   file of it at all. A load says nothing about one of these on purpose
    ///   (`ForeignStreamWatch.settle`: a missing stream is not a truncated one
    ///   — iCloud may be halfway through) and it is exactly the case a
    ///   marking verb refuses over, so it must be visible or the refusal's
    ///   *History shows what this book is missing* is a dead end.
    ///
    /// Both are the same fact to the writer — *this history is gone* — and
    /// both take the same way out.
    public struct LostHistory: Equatable, Sendable, Identifiable {
        public enum What: Equatable, Sendable {
            /// The last line this device settled in the live tail is nowhere
            /// in the stream any more.
            case line
            /// A whole sealed segment this device had taken in is gone.
            case segment
            /// No file of this stream is in the folder at all.
            case absent
        }

        public let streamKey: String
        public let deviceSlug: String
        /// The writer's word for whose stream it was: the label the book gives
        /// them, else — with no table to ask — the slug their files carry.
        public let label: String
        public let what: What
        /// The day a LOAD noticed it. Nil for an absent stream, which no load
        /// ever recorded: drawing today's date on it would date a fact nobody
        /// dated.
        public let noticedAt: Date?
        /// Has the writer been shown this and put it down? An acknowledged
        /// loss stops being EXPECTED by the sweeps; it does not stop being
        /// true, which is why the row stays.
        public let acknowledged: Bool

        public var id: String { streamKey }

        public init(
            streamKey: String, deviceSlug: String, label: String, what: What,
            noticedAt: Date?, acknowledged: Bool
        ) {
            self.streamKey = streamKey
            self.deviceSlug = deviceSlug
            self.label = label
            self.what = what
            self.noticedAt = noticedAt
            self.acknowledged = acknowledged
        }

        /// **What is gone, in the writer's words.** Neither kind takes a word
        /// out of the draft — what was applied stays applied — so all three
        /// end at the one place the lost history can be got back from.
        /// **An ABSENT stream says something weaker, because less is known
        /// about it** (fix round 1, Important 1).
        ///
        /// A truncation was WITNESSED: this Mac held the remembered line and
        /// the bytes that no longer carry it, in one reading. Absence is not
        /// witnessed at all — `ForeignStreamWatch.settle`'s own rule is that a
        /// stream with no file is *missing, not truncated: iCloud has moved
        /// it, or a sync is halfway through* — so a row asserting it is gone
        /// from the folder states as a fact the one thing this Mac cannot
        /// know. It matters because the row carries a control: a writer told
        /// their collaborator's history is gone presses Acknowledge, and a
        /// revocation the next day marks a stream that was only ever
        /// mid-sync.
        public var sentence: String {
            switch what {
            case .absent:
                return "Maugham can’t find \(label)’s history in this book. "
                    + "Nothing has left the draft — every word it had already "
                    + "applied is still in it — but the file those words came "
                    + "from isn’t here. It may still be syncing; if it isn’t, "
                    + "a backup is where it can be got back from."
            case .segment, .line:
                let what = self.what == .segment
                    ? "part of \(label)’s sealed history is missing from this book"
                    : "\(label)’s history here is shorter than it was"
                return "\(what.prefix(1).uppercased())\(what.dropFirst()). "
                    + "Nothing has left the draft — every word Maugham had already "
                    + "applied is still in it — but what is gone is gone from the "
                    + "folder. A backup is where it can be got back from."
            }
        }

        /// **What acknowledging one costs**, in one spelling — read BEFORE the
        /// press, on the control itself, and again after it in the row
        /// (fix round 1, Important 1).
        ///
        /// It was only ever said afterwards, which is the wrong half of the
        /// act to say it in: the whole of what the writer takes on is that a
        /// stream which comes back later falls on the far side of whatever
        /// they decide in between.
        public static let costOfAcknowledging =
            "If it comes back, it is judged as written after that change."

        /// What acknowledging it did, once it has been acknowledged — because
        /// the row stays and a row that only repeated itself would look like a
        /// press that did nothing.
        public static let acknowledgedSentence =
            "You’ve said you know this history is gone, so Maugham no longer "
            + "waits for it before changing what somebody may write. "
            + costOfAcknowledging
    }

    /// **Every piece of this book's history this Mac remembers and cannot
    /// find** — the drawer's list, and the one derivation of it.
    ///
    /// The truncations come from the memory the loads wrote; the absent
    /// streams come from that same memory against the folder's own filenames.
    /// **The memory is read UNFILTERED here** (`foreignStreams`, never
    /// `expectedStreams`): a loss the writer has put down is still a loss, and
    /// a drawer that dropped it would take the row away the moment it was
    /// acknowledged — leaving nothing on screen saying why the book no longer
    /// waits for that stream.
    nonisolated public static func lostHistory(
        in projectURL: URL, state: OpLogDeviceState, trust: TrustTable? = nil
    ) -> [LostHistory] {
        let put = state.acknowledgedLosses(inRoot: projectURL)
        func name(_ slug: String) -> String {
            trust?.label(forDeviceSlug: slug) ?? slug
        }
        var out = state.truncations(inRoot: projectURL).map { truncation in
            LostHistory(
                streamKey: truncation.streamKey,
                deviceSlug: truncation.deviceSlug,
                label: name(truncation.deviceSlug),
                what: truncation.loss == .segment ? .segment : .line,
                noticedAt: truncation.noticedAt,
                acknowledged: put[truncation.streamKey] != nil)
        }
        let known = Set(out.map(\.streamKey))
        let remembered = state.foreignStreams(inRoot: projectURL, writtenBy: nil)
        for key in absentStreams(in: projectURL, remembering: remembered).sorted()
        where !known.contains(key) {
            guard let memory = remembered[key] else { continue }
            out.append(LostHistory(
                streamKey: key, deviceSlug: memory.deviceSlug,
                label: name(memory.deviceSlug), what: .absent,
                noticedAt: nil, acknowledged: put[key] != nil))
        }
        return out
    }

    /// **Which remembered streams the folder holds no file of at all.**
    ///
    /// Filenames only: `PermitMark.stream(of:)` is the one parse and it takes
    /// a URL, so a stream key is never taken apart to build a filename back.
    /// Nothing is opened and nothing is verified — this answers *is there a
    /// file of this stream here*, which is the question the position sweeps
    /// answer the hard way while they are reading everything anyway.
    ///
    /// **It refuses nothing.** A directory that will not list answers as if it
    /// were empty, which would call every stream in it absent — so a listing
    /// that fails is treated as *no opinion* and contributes nothing. The acts
    /// that must not proceed over a short reading refuse on their own account
    /// (`OpLogStore.ReadError.unlistableStreamDirectory`); this is a read for a sentence.
    nonisolated public static func absentStreams(
        in projectURL: URL,
        remembering expecting: [String: OpLogDeviceState.ForeignStreamMemory]
    ) -> [String] {
        guard !expecting.isEmpty else { return [] }
        let opsDir = projectURL.appendingPathComponent(".maugham/ops")
        // EITHER listing failing is *no opinion about any of it*: a folder
        // half read would call every stream in the half it could not see
        // absent, which is the one wrong answer this can give.
        guard let filenames = try? OpLogStore.listing(of: opsDir, naming: ".maugham/ops"),
              let others = try? StreamPositions.otherStreamFileURLs(in: projectURL, forSlugs: nil)
        else { return [] }
        var present: Set<String> = []
        for filename in filenames {
            if let stream = PermitMark.stream(
                of: opsDir.appendingPathComponent(filename)) {
                present.insert(stream.key)
            }
        }
        for url in others {
            if let stream = PermitMark.stream(of: url) {
                present.insert(stream.key)
            }
        }
        return expecting.keys.filter { !present.contains($0) }
    }

    /// The file a `ReadError` names, for a caller that reports unreadable
    /// files by name and has caught something that might not be one.
    nonisolated public static func unreadableName(_ error: Error) -> String {
        if case let OpLogStore.ReadError.unreadableFile(name, _, _) = error { return name }
        // A DIRECTORY that would not list, and a stream that was there before
        // and is not now, are both things a verb refuses over (P3a Task 7's
        // fix round 1) — and the writer's next move turns on which file it
        // was, so each names itself rather than falling through to the
        // registry.
        if case let OpLogStore.ReadError.unlistableStreamDirectory(name, _) = error { return name }
        if case OpLogStore.ReadError.unlistableOpsDirectory = error { return ".maugham/ops" }
        if case let OpLogStore.ReadError.streamMissingFromSweep(streamKey) = error { return streamKey }
        return "the project's registry"
    }
}
