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
    /// Lines that were NOT applied: the chain broke at or before them.
    public let quarantined: Int
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
        isSealedSegment: Bool = false,
        segmentVerified: Bool? = nil
    ) {
        self.name = name
        self.legacy = legacy
        self.verified = verified
        self.unsealed = unsealed
        self.unsignedHistory = unsignedHistory
        self.quarantined = quarantined
        self.isSealedSegment = isSealedSegment
        self.segmentVerified = segmentVerified
    }
}

/// The same account over every file a document's history is spread across.
///
/// One document, one answer: the surfaces that report on integrity (Task 6) ask
/// this, never the individual files, so a project with eight devices' files
/// still says one thing about itself.
public struct OpLogProvenance: Equatable, Sendable {
    public let files: [FileProvenance]

    public init(files: [FileProvenance] = []) {
        self.files = files
    }

    public var legacyLines: Int { files.reduce(0) { $0 + $1.legacy } }
    public var verifiedLines: Int { files.reduce(0) { $0 + $1.verified } }
    public var unsealedLines: Int { files.reduce(0) { $0 + $1.unsealed } }
    public var unsignedHistoryLines: Int { files.reduce(0) { $0 + $1.unsignedHistory } }
    public var quarantinedLines: Int { files.reduce(0) { $0 + $1.quarantined } }

    /// Does this document carry history from before the chain existed? Not a
    /// fault — every manuscript written before this milestone answers yes, and
    /// it stays yes forever, because the past cannot be signed retroactively.
    public var hasLegacyHistory: Bool { legacyLines > 0 }

    /// Does it carry history signed by a key this device does not trust? In P1
    /// that is every other device, including the writer's own phone; P2's
    /// registry is what turns most of this into `verified`.
    public var hasUnsignedForeignHistory: Bool { unsignedHistoryLines > 0 }
}
