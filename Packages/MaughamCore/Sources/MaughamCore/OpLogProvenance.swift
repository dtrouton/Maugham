import Foundation

/// What a load found out about ONE op-log file: how many of its lines this
/// device can vouch for, how many are merely history, and how many it refused.
///
/// The counts are over LINES, not ops — a seal is a line and is counted in the
/// class it settles, because the question this answers is "what is this file
/// made of", and a file is made of lines. Deliberately not a verdict: nothing
/// here says whether the document may be opened. The reader applies what it
/// applies and then says what it saw, in the order the writer's surfaces
/// (Task 6) want to read it.
public struct FileProvenance: Equatable, Sendable {
    /// The file's own name, so a surface can say which one it means.
    public let name: String
    /// Lines written before this milestone: no `prev`, no seal.
    public let legacy: Int
    /// Lines covered by a seal from a key this device trusts — its own.
    public let verified: Int
    /// Chained lines no seal has reached yet. The live tail's ordinary state.
    public let unsealed: Int
    /// Lines under a seal this device does not trust, or in a sealed segment
    /// with no signature of ours beside it. Applied — P1 has no registry — but
    /// never claimed as this device's own word.
    public let unsignedHistory: Int
    /// Lines that were NOT applied: the chain broke at or before them, or the
    /// key that sealed them was revoked or belongs to another claimant.
    public let quarantined: Int
    /// Lines HELD: sealed by a key this device's chain says nothing about, so
    /// neither applied nor refused (spec §3). Admitting the device applies
    /// them on the next read; nothing is rewritten either way.
    public let pending: Int
    /// The same number split by the DEVICE whose seal is holding each span, so
    /// a surface can offer *admit this device* about somebody in particular
    /// rather than about a count.
    ///
    /// Keyed on the device record's fingerprint — never the actor key that made
    /// the seal — because a device holds four of those, and a phone that wrote
    /// as both its author and its assistant is one device waiting for
    /// admission. A key no device record names stands for itself.
    public let pendingByDevice: [String: Int]
    /// **What those held lines ARE** — paragraphs of prose and notes, and a
    /// few of the words — keyed as `pendingByDevice` is (P3b smoke find F2).
    /// `HeldLines.Waiting.byDevice`'s answer, taken from the same classified
    /// lines in the same pass, so a count and its description cannot disagree.
    public let pendingWaitingByDevice: [String: HeldLines.Waiting]
    /// **Of those, the ones this book has no person record for** — the devices
    /// the writer can actually be asked to ADMIT (P3a Task 5's D5).
    ///
    /// P2 held a line for exactly one reason — a stranger's seal — so *held*
    /// and *waiting for admission* were the same fact and a surface could read
    /// `pendingByDevice` raw. P3a holds a line for a second reason: a permit
    /// this build cannot judge, from a device that is already admitted. Those
    /// two share `Line.State.pending` on purpose (same storage state, same
    /// tallies, one walk) and are told apart HERE, by the one predicate
    /// (`TrustTable.isStrangerDevice`), so every admission-worded sentence
    /// narrows in the same place.
    ///
    /// Stamped by the load, which is the only place the table is in hand.
    /// **Unstamped means every held device is a stranger** — P2's meaning
    /// exactly, since a stranger's seal was the only reason to hold a line —
    /// so a `FileProvenance` built by hand answers what it always answered.
    public let pendingStrangerDevices: Set<String>
    /// **The device slug this file's STREAM carries**, or nil where there is
    /// none — the legacy unsuffixed `<docId>.jsonl`, and any file this build
    /// does not recognise as one of the three stream families
    /// (`PermitMark.stream(of:)`).
    ///
    /// Carried beside `name` because a holder's own key does not always say
    /// which of a device's four writers made it: a non-author actor key with no
    /// device record yet stands for itself in `pendingByDevice`, and the only
    /// thing on disk that names it is the slug of the file it was written in
    /// (P3b Task 4, spec §7.1). The admission sheet is what needs it — a key
    /// that is not a person's must never be offered as one — and the file is
    /// the only place the join can be made, so it is recorded here rather than
    /// re-derived from `name` by a reader that would have to know the directory
    /// too.
    ///
    /// **Nil is never a narrowing.** A reader that cannot name the slug asks
    /// nothing of it and leaves the holder exactly as P2b left it.
    public let deviceSlug: String?
    /// Whether this file is a sealed `.mzseg` segment rather than a live tail.
    public let isSealedSegment: Bool
    /// For a sealed segment: whether its signature settled it (either read from
    /// the sidecar beside it, or remembered from a previous load). Nil for a
    /// live tail, which is settled line by line rather than as a whole.
    public let segmentVerified: Bool?

    public init(
        name: String,
        legacy: Int = 0,
        verified: Int = 0,
        unsealed: Int = 0,
        unsignedHistory: Int = 0,
        quarantined: Int = 0,
        pending: Int = 0,
        pendingByDevice: [String: Int] = [:],
        pendingWaitingByDevice: [String: HeldLines.Waiting] = [:],
        pendingStrangerDevices: Set<String>? = nil,
        deviceSlug: String? = nil,
        isSealedSegment: Bool = false,
        segmentVerified: Bool? = nil
    ) {
        self.name = name
        self.legacy = legacy
        self.verified = verified
        self.unsealed = unsealed
        self.unsignedHistory = unsignedHistory
        self.quarantined = quarantined
        self.pending = pending
        self.pendingByDevice = pendingByDevice
        self.pendingWaitingByDevice = pendingWaitingByDevice
        self.pendingStrangerDevices =
            pendingStrangerDevices ?? Set(pendingByDevice.keys)
        self.deviceSlug = deviceSlug
        self.isSealedSegment = isSealedSegment
        self.segmentVerified = segmentVerified
    }

    /// **Lines of this file kept in History rather than in the text** — set
    /// aside (`quarantined`) or held (`pending`) (P3c Task 3, controller ruling
    /// K). Both are already counted by the load; this names their sum, so the
    /// one question a surface asks of a file has one spelling.
    public var keptInHistory: Int { quarantined + pending }
}

/// The same account over every file a document's history is spread across.
///
/// One document, one answer: the surfaces that report on integrity (Task 6) ask
/// this, never the individual files, so a project with eight devices' files
/// still says one thing about itself.
public struct OpLogProvenance: Equatable, Sendable {
    public let files: [FileProvenance]

    /// **The stream slugs this device's own actors write under**, as the load
    /// that built this value enumerated them (`ForeignStreamWatch.slugs(of:)` —
    /// every actor whose key exists, minting none). Carried so a reader can ask
    /// *which of these files are mine* without enumerating identities of its
    /// own (P3c Task 3, controller ruling K). Empty for a value built by hand:
    /// then no file is this device's, and nothing is counted as hers.
    public let ownStreams: Set<String>

    public init(files: [FileProvenance] = [], ownStreams: Set<String> = []) {
        self.files = files
        self.ownStreams = ownStreams
    }

    /// **Set-aside and held lines in THIS device's own files** (P3c Task 3,
    /// controller ruling K) — what the editor's standing line means by *some
    /// of what you wrote here is kept in History*. Summed over the files whose
    /// stream slug is one of `ownStreams`; a file with no slug (the legacy
    /// unsuffixed log) is nobody's in particular and is not counted.
    public var ownLinesKeptInHistory: Int {
        files.reduce(0) { total, file in
            guard let slug = file.deviceSlug, ownStreams.contains(slug) else { return total }
            return total + file.keptInHistory
        }
    }

    public var legacyLines: Int { files.reduce(0) { $0 + $1.legacy } }
    public var verifiedLines: Int { files.reduce(0) { $0 + $1.verified } }
    public var unsealedLines: Int { files.reduce(0) { $0 + $1.unsealed } }
    public var unsignedHistoryLines: Int { files.reduce(0) { $0 + $1.unsignedHistory } }
    public var quarantinedLines: Int { files.reduce(0) { $0 + $1.quarantined } }
    /// Lines held for a stranger's key across every file of this document.
    public var pendingLines: Int { files.reduce(0) { $0 + $1.pending } }

    /// Held lines by the device whose seal is holding them, summed across the
    /// files. The question a surface asks is *who is waiting*, and one device's
    /// history is spread over one file per actor it has written as.
    public var pendingByDevice: [String: Int] {
        files.reduce(into: [:]) { total, file in
            for (key, count) in file.pendingByDevice { total[key, default: 0] += count }
        }
    }

    /// **What each holder's held lines are, across every file** (F2) — the
    /// same union `pendingByDevice` is, of the descriptions rather than the
    /// counts.
    public var pendingWaitingByDevice: [String: HeldLines.Waiting] {
        files.reduce(into: [:]) { total, file in
            for (key, waiting) in file.pendingWaitingByDevice {
                total[key] = total[key].map { $0.merged(with: waiting) } ?? waiting
            }
        }
    }

    /// **Which STREAMS each held holder was held in**, by device slug (P3b
    /// Task 4).
    ///
    /// The admission sheet's question is *is this key a person's*, and a key
    /// nothing has a device record for cannot answer it alone: a non-author
    /// actor key stands for itself here, and the slug of the file it was
    /// written in is the only thing on disk that says which of the four writers
    /// it is (`DeviceIdentity.actor(ofDeviceId:signingWith:)`, which CHECKS the
    /// claim against the key rather than believing the word).
    ///
    /// A file with no slug contributes nothing, so a holder can legitimately
    /// have an empty set and that reads as *nothing here says* — the same
    /// answer P2b gave, which is what keeps the narrowing from ever refusing an
    /// honest stranger.
    public var pendingStreamsByDevice: [String: Set<String>] {
        files.reduce(into: [:]) { streams, file in
            guard let slug = file.deviceSlug else { return }
            for device in file.pendingByDevice.keys {
                streams[device, default: []].insert(slug)
            }
        }
    }

    /// **Held lines by device, narrowed to the devices the writer can be asked
    /// to ADMIT** — every *waiting for admission* sentence counts this map and
    /// never `pendingByDevice` (P3a Task 5's D5).
    ///
    /// A line held because its signer's permit is one this build cannot judge
    /// belongs to a device that is already in the book: offering the writer an
    /// admission sheet about it would offer a control that changes nothing.
    /// Under P3a such a line is held SILENTLY; P3b gives it a surface.
    public var pendingStrangersByDevice: [String: Int] {
        let strangers = files.reduce(into: Set<String>()) {
            $0.formUnion($1.pendingStrangerDevices)
        }
        return pendingByDevice.filter { strangers.contains($0.key) }
    }

    /// The admission-worded total: `pendingOpLines` over strangers alone.
    public var pendingStrangerOpLines: Int {
        pendingStrangersByDevice.values.reduce(0, +)
    }

    /// Is anything waiting on the writer to ADMIT a device? The narrowed twin
    /// of `hasPendingHistory`, and the one every Admit… control gates on.
    public var hasPendingAdmission: Bool { pendingStrangerOpLines > 0 }

    /// **The held OP lines** — what every surface that puts a NOUN after the
    /// number must count (signed op log P2b Task 6's ruling (a)).
    ///
    /// `pendingLines` is the line tally, and a held span's own seal line is one
    /// of those lines: two held ops under one signature are three held lines.
    /// That is the right answer to *how much of this file was not applied* and
    /// the wrong answer to *how many notes are waiting*, because a seal is
    /// neither a note nor a capture. Derived from `pendingByDevice`, which
    /// `OpLogChain` already filters to `kind == .op`, so there is ONE rule
    /// about what counts and History cannot disagree with the admission sheet
    /// about the same device.
    public var pendingOpLines: Int { pendingByDevice.values.reduce(0, +) }

    /// Is anything waiting on the writer to admit a device? The one question
    /// the pending state exists to let a surface ask.
    public var hasPendingHistory: Bool { pendingLines > 0 }

    /// Does this document carry history from before the chain existed? Not a
    /// fault — every manuscript written before this milestone answers yes, and
    /// it stays yes forever, because the past cannot be signed retroactively.
    public var hasLegacyHistory: Bool { legacyLines > 0 }

    /// Does it carry history signed by a key this device does not trust? In P1
    /// that is every other device, including the writer's own phone; P2's
    /// registry is what turns most of this into `verified`.
    public var hasUnsignedForeignHistory: Bool { unsignedHistoryLines > 0 }
}
