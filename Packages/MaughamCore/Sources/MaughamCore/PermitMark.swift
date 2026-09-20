import Foundation

/// **Where a permit changed, said in positions every device can check**
/// (P3 spec §3.3).
///
/// A permit is evaluated *as of the line*: a demotion does not reach back, a
/// promotion is not a pardon. So every event has to carry a cut — *this much
/// was written under the old permit, everything after it under the new one* —
/// and the cut has to mean the same thing on the root's Mac, on the subject's
/// own second Mac, and on a Mac that joins the book next year holding none of
/// the memories either of them has.
///
/// **Why it is not an opId.** P2's mark is `highestOpIdSeen`, one opId per
/// person, and it cannot survive being a permission boundary: an opId carries
/// a timestamp *its own writer chooses*, so a demoted author stamps new text
/// with an old id and slips under the mark. Fixing that with each device's own
/// memory of what it applied makes a fresh Mac — which has no memory — apply
/// what the root refused, and the two devices diverge on the same bytes. The
/// mark has to be made of the shared data itself.
///
/// **So it is chain positions, and the format follows from three facts about
/// how these files are stored** (verified against the code 2026-09-19):
///
/// 1. `OpLogStore.classify` yields one `OpLogChain.Verification` per FILE —
///    **each file is its own chain**.
/// 2. `sealTailIfNeeded` copies the whole tail into a `.mzseg` segment and
///    deletes the tail; the next append starts from `OpLogChain.genesis`. So a
///    new tail's first `prev` is `genesis`, and **the marked line MOVES** —
///    the line that was last in the tail is inside a segment after the next
///    rotation. A mark keyed by filename would be wrong within one seal.
/// 3. A segment's index is part of a filename, and a filename is the writer's
///    to choose. Ordering files by it would let a forger mint `seg0000` and
///    have it read as ancient history.
///
/// Hence, per STREAM: the **digest of every whole segment** the root had
/// applied, and the **`OpLogChain.lineHash` of the last line** it applied. A
/// line's hash covers its own `prev`, so it is unique in its chain and it
/// survives the rotation that moves it.
///
/// Judging a file is then three rules and no ordering at all — see `judge`.
/// Every device computes the same answer from the same bytes; backdating an
/// opId, renumbering a segment or rewriting one buys nothing.
///
/// **An empty mark is legal and means *nothing was applied*** — P2's
/// `RevocationScope.nothingAppliedMark` in the new shape. It judges everything
/// new, which is the strict side and the right one: the first admission has no
/// past to divide.
public struct PermitMark: Equatable, Hashable, Sendable {

    // MARK: - The wire form

    /// **One stream's position, as the root that made the event saw it.**
    ///
    /// This is `PermitEvent`'s own field type — moved here, not copied, and
    /// still spelled `PermitEvent.StreamMark` through a typealias. Two shapes
    /// for one thing is how the record a build reads and the rule it applies
    /// become two opinions living in one type.
    ///
    /// Strings, both of them, for tripwire 42's reason: the serializer the
    /// canonical form goes through normalizes numbers. `line` is absent rather
    /// than empty when the root had applied no line of that stream's tail.
    public struct StreamMark: Codable, Equatable, Hashable, Sendable {
        /// The digest of every whole segment of this stream the root had
        /// applied. A segment whose digest is listed is wholly under the old
        /// permit whatever its filename says afterwards.
        public let segments: [String]
        /// The `lineHash` of the last line the root applied.
        public let line: String?

        public init(segments: [String] = [], line: String? = nil) {
            self.segments = segments
            self.line = line
        }
    }

    /// Stream key → position. The key is `stream(of:)`'s answer and nobody
    /// else's, so the mark a root writes and the file a reader judges are
    /// named by one function.
    public let streams: [String: StreamMark]

    public init(_ streams: [String: StreamMark] = [:]) {
        self.streams = streams
    }

    /// *Nothing was applied.* Everything judges new.
    public static let nothingApplied = PermitMark()

    public var isEmpty: Bool { streams.isEmpty }

    public subscript(streamKey: String) -> StreamMark? { streams[streamKey] }

    // MARK: - Naming a stream

    /// What one op-log-family file belongs to.
    ///
    /// `deviceSlug` is nil for exactly one shape: the legacy unsuffixed
    /// `<docId>.jsonl`, which predates ADR 0012's partitioning and so belongs
    /// to no device in particular.
    public struct Stream: Equatable, Hashable, Sendable {
        public enum Kind: String, Equatable, Hashable, Sendable {
            case ops, translation, inbox
        }
        public let key: String
        public let kind: Kind
        public let docId: String
        /// Translation streams only.
        public let language: String?
        /// Nil for the legacy unsuffixed `<docId>.jsonl`.
        public let deviceSlug: String?
    }

    /// **The one function that turns a file into a stream key.**
    ///
    /// Tasks that record a mark, cut a span against one, or report what a mark
    /// covers all ask this rather than rebuilding `"\(docId).\(slug)"` — a
    /// second spelling is a mark filed under a name no reader looks up, which
    /// fails by silently judging everything new.
    ///
    /// The key spellings, and why they cannot collide:
    ///
    /// | file | key |
    /// |---|---|
    /// | `.maugham/ops/<docId>.<slug>.jsonl` (and its `.segNNNN.mzseg`) | `<docId>.<slug>` |
    /// | `.maugham/ops/<docId>.jsonl` (legacy, unsuffixed) | `<docId>` |
    /// | `.maugham/translations/<docId>.<lang>.<slug>.jsonl` | `translation:<docId>.<lang>.<slug>` |
    /// | `.maugham/inbox/inbox.<slug>.jsonl` | `inbox:<slug>` |
    ///
    /// An ops docId carries no dot (`OpLogStore.docId(fromOpLogFilename:)` is
    /// the rule and takes the component before the first one) and a
    /// `DeviceSlug` carries none either (`make` maps everything outside
    /// `[a-z0-9]` to `-`), so the legacy key — a bare docId with no second
    /// component — can never be a per-device key. The other two families carry
    /// a prefix of their own, which is what keeps a translation of
    /// `d-one` in `es` from colliding with an ops stream of a doc called
    /// `d-one` on a device slugged `es`. A segment and the tail it was rotated
    /// out of answer the SAME key: that is the whole point — a stream outlives
    /// its filenames.
    ///
    /// Nil for anything this build does not recognise as one of the three.
    public static func stream(of url: URL) -> Stream? {
        let directory = url.deletingLastPathComponent().lastPathComponent
        let name = url.lastPathComponent
        switch directory {
        case "ops":
            guard let (docId, slug) = headAndSlug(ofFileNamed: name) else { return nil }
            return Stream(
                key: slug.map { "\(docId).\($0)" } ?? docId,
                kind: .ops, docId: docId, language: nil, deviceSlug: slug)
        case "inbox":
            guard let (head, slug) = headAndSlug(ofFileNamed: name),
                  head == InboxManifest.chainDocId, let slug else { return nil }
            return Stream(
                key: "inbox:\(slug)", kind: .inbox,
                docId: InboxManifest.chainDocId, language: nil, deviceSlug: slug)
        case "translations":
            guard let parsed = TranslationStore.parseFileName(name) else { return nil }
            return Stream(
                key: "translation:\(parsed.docId).\(parsed.language).\(parsed.deviceSlug)",
                kind: .translation, docId: parsed.docId,
                language: parsed.language, deviceSlug: parsed.deviceSlug)
        default:
            return nil
        }
    }

    /// `stream(of:)`'s key alone, for a caller that wants nothing else.
    public static func streamKey(of url: URL) -> String? { stream(of: url)?.key }

    /// **The seal key a FILE's own name can be matched to** (Task 11) — arm 2
    /// of *the file's key*, and the one place the two hops are spelled: this
    /// type's filename parse, then `TrustTable.key(forDeviceSlug:)`.
    ///
    /// It lives beside `stream(of:)` because that is already the one parse of
    /// an op-log, translation or inbox filename, and a second caller doing the
    /// slug hop by hand would be a second way to map a filename to a key —
    /// which is exactly how two readers come to disagree about whose file they
    /// are holding.
    ///
    /// Nil is *this device cannot name one*, and its callers must then do what
    /// P1 did: a legacy unsuffixed file (no slug at all), a device that has
    /// written no record here, a book with no register. That is arm 3, the
    /// unsigned door, and nothing here closes it.
    public static func keyNaming(_ url: URL, in trust: TrustTable?) -> String? {
        guard let trust, let slug = stream(of: url)?.deviceSlug else { return nil }
        return trust.key(forDeviceSlug: slug)
    }

    /// `<head>(.<slug>)?(.segNNNN)?.(jsonl|mzseg)` taken apart.
    ///
    /// The segment index is DROPPED rather than returned: a rotated segment
    /// and the tail it came from are one stream, and the index is a filename.
    private static func headAndSlug(
        ofFileNamed name: String
    ) -> (head: String, slug: String?)? {
        let stem: String
        let isSegment: Bool
        if name.hasSuffix(".jsonl") {
            stem = String(name.dropLast(".jsonl".count))
            isSegment = false
        } else if name.hasSuffix(".\(OpLogSegment.fileExtension)") {
            stem = String(name.dropLast(OpLogSegment.fileExtension.count + 1))
            isSegment = true
        } else {
            return nil
        }
        var parts = stem
            .split(separator: ".", omittingEmptySubsequences: false)
            .map(String.init)
        guard let head = parts.first, !head.isEmpty else { return nil }
        parts.removeFirst()
        if isSegment {
            guard let last = parts.last, last.hasPrefix("seg") else { return nil }
            let digits = last.dropFirst(3)
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
            parts.removeLast()
        }
        let slug = parts.isEmpty ? nil : parts.joined(separator: ".")
        guard slug.map({ !$0.isEmpty }) ?? true else { return nil }
        return (head, slug)
    }

    // MARK: - Judging a file

    /// Which permit each line of one file was written under.
    public struct Judgement: Equatable, Sendable {
        /// **Old** is *written under the permit this mark replaced*; **new**
        /// is *written under the one it installed*. Neither says applied or
        /// refused — that is the caller's rule, and it differs by event kind.
        public enum Side: String, Equatable, Hashable, Sendable {
            case old, new
        }

        /// One side per line, in the order the lines were given.
        public let sides: [Side]

        public init(sides: [Side]) { self.sides = sides }

        public static func allOld(count: Int) -> Judgement {
            Judgement(sides: Array(repeating: .old, count: count))
        }

        public static func allNew(count: Int) -> Judgement {
            Judgement(sides: Array(repeating: .new, count: count))
        }

        public func side(ofLineAt index: Int) -> Side? {
            sides.indices.contains(index) ? sides[index] : nil
        }

        public var isAllOld: Bool { !sides.isEmpty && sides.allSatisfy { $0 == .old } }
        public var isAllNew: Bool { sides.allSatisfy { $0 == .new } }

        /// The last line under the old permit, where the cut falls inside this
        /// file. Nil when nothing here is old.
        public var lastOldIndex: Int? { sides.lastIndex(of: .old) }
    }

    /// **Which permit each line of this file was written under** — three rules
    /// and no ordering.
    ///
    /// 1. A file that IS a segment whose digest this stream's mark lists is
    ///    wholly **old**. The digest is the container's own commitment to its
    ///    uncompressed bytes, so renaming it, renumbering it or moving it
    ///    changes nothing, and rewriting it changes the digest.
    /// 2. Otherwise, the file that CONTAINS the marked line hash is **old**
    ///    through that line inclusive and **new** after it. A line's hash
    ///    covers its `prev`, so it is unique in its chain — which is why this
    ///    works whether the line is still in the tail or has since been
    ///    rotated into a segment.
    /// 3. Every other file, and every stream this mark does not name, is
    ///    wholly **new**.
    ///
    /// What it deliberately does NOT read: a segment index, a filename, or an
    /// opId. All three are the writer's to choose, and a rule that consulted
    /// any of them would let the demoted device pick its own side of the cut.
    ///
    /// - Parameters:
    ///   - streamKey: `stream(of:)`'s answer for the file in hand.
    ///   - fileIsSegmentWithDigest: the digest a sealed segment CARRIES and
    ///     that VERIFIED (`OpLogSegment.DecodeResult.digest` where
    ///     `isVerified`), or nil for a live `.jsonl` tail and for a container
    ///     that did not hold together. A digest that did not verify is a
    ///     digest a tamperer would have left alone, so it is never passed.
    ///   - lines: the file's non-blank lines, in file order — the walk's own
    ///     (`verification.lines.map(\.bytes)`), or a settled segment's
    ///     decompressed JSONL split on newlines. The trailing newline is
    ///     optional; `OpLogChain.lineHash` ignores exactly one.
    public func judge(
        streamKey: String,
        fileIsSegmentWithDigest digest: String?,
        lines: [Data]
    ) -> Judgement {
        guard let mark = streams[streamKey] else { return .allNew(count: lines.count) }
        if let digest, mark.segments.contains(digest) {
            return .allOld(count: lines.count)
        }
        guard let markedLine = mark.line,
              let cut = lines.firstIndex(where: {
                  OpLogChain.lineHash($0) == markedLine
              })
        else { return .allNew(count: lines.count) }
        return Judgement(sides: lines.indices.map { $0 <= cut ? .old : .new })
    }
}
