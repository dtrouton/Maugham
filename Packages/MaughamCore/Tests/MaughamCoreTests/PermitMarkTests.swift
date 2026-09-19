import CryptoKit
import Foundation
import XCTest
@testable import MaughamCore

/// **The mark — chain positions, rotation-safe** (P3a Task 2, spec §3.3).
///
/// A permit change has to carry a cut that means the same thing on every
/// device: *this much was written under the old permit*. P2's mark is one
/// opId per person, and an opId carries a timestamp its own writer chooses —
/// so a demoted author stamps new text with an old id and slips under it.
/// P3's mark is made of the shared bytes instead: segment digests and a line
/// hash.
///
/// The first test here is the one the whole format stands on, and it is a pin
/// on production behaviour rather than on this file's code: a rotation copies
/// the tail into a segment, deletes the tail, and starts the next one from
/// `genesis`. **The marked line MOVES.** Anything keyed on a filename is
/// therefore wrong within one seal, and the three forgery tests below are
/// what is left once you stop trusting filenames: a segment renumbered to look
/// ancient, a segment rewritten in place, and an op backdated past the cut.
@MainActor
final class PermitMarkTests: XCTestCase {

    private let docId = "doc-permit"
    private var projectURL: URL!
    /// The device whose streams are being marked. A software signer, because
    /// CI's runner has no enclave and a mark over unsigned history would be
    /// asserting the runner rather than the code (tripwire 36).
    private var identities: LocalIdentities!
    private var device: DeviceIdentity { identities.author }
    private var deviceState: OpLogDeviceState!
    /// A second device, so "only the subject's streams" is a real assertion.
    private var otherIdentities: LocalIdentities!
    private var other: DeviceIdentity { otherIdentities.author }
    private var otherState: OpLogDeviceState!

    override func setUp() async throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("permit-mark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".maugham/ops"),
            withIntermediateDirectories: true)
        identities = .softwareForTesting()
        otherIdentities = .softwareForTesting()
        deviceState = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("state-mine.json"))
        otherState = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("state-other.json"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - Fixtures

    /// Every key this device holds is `.mine`; nobody else is anything. P1's
    /// shape exactly, and enough to settle this device's own segments.
    private var table: TrustTable { TrustResolution.keyless(mine: identities) }

    private func makeStore() -> OpLogStore {
        OpLogStore(projectURL: projectURL, identities: identities, state: deviceState)
    }

    private func op(_ opId: String, by writer: DeviceIdentity? = nil) -> Op {
        Op(opId: opId, docId: docId, at: Date(timeIntervalSince1970: 0),
           device: (writer ?? device).deviceId, session: "s", kind: .typingBurst,
           changes: [.init(paragraphId: "aaaa", prior: nil, next: opId)],
           sequence: ["aaaa"])
    }

    private var slug: DeviceSlug { device.slug }

    private var tailURL: URL {
        OpLogStore.opLogFileURL(forDocId: docId, deviceSlug: slug, in: projectURL)
    }

    private func streamKey(of url: URL) throws -> String {
        try XCTUnwrap(PermitMark.stream(of: url)?.key)
    }

    private func mark() throws -> PermitMark {
        try OpLogStore.appliedPositions(
            ofDeviceIds: [device.deviceId], in: projectURL, trust: table)
    }

    /// The non-blank lines of a live `.jsonl` tail, in file order.
    private func lines(of url: URL) throws -> [Data] {
        try split(Data(contentsOf: url))
    }

    /// The non-blank lines inside a sealed segment.
    private func segmentLines(of url: URL) throws -> [Data] {
        let decoded = OpLogSegment.decodeVerifying(try Data(contentsOf: url))
        XCTAssertTrue(decoded.isVerified, "the fixture segment holds together")
        return try split(XCTUnwrap(decoded.jsonl))
    }

    private func split(_ bytes: Data) throws -> [Data] {
        bytes.split(separator: 0x0A, omittingEmptySubsequences: true).map(Data.init)
    }

    /// The digest a segment container CARRIES, and only where it verified.
    private func digest(of url: URL) throws -> String {
        let decoded = OpLogSegment.decodeVerifying(try Data(contentsOf: url))
        XCTAssertTrue(decoded.isVerified)
        return try XCTUnwrap(decoded.digest)
    }

    private func field(_ key: String, of line: Data) throws -> String? {
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: line) as? [String: Any])
        return object[key] as? String
    }

    // MARK: - The rotation pin

    /// **The fact the whole format stands on.**
    ///
    /// `sealTailIfNeeded` copies the tail into a segment and DELETES the tail;
    /// the next append starts from `OpLogChain.genesis`. So the line a mark
    /// names is in the tail when the mark is made and inside a segment
    /// afterwards, and the new tail's first line links to nothing that came
    /// before it. A mark keyed by filename, or a rule that ordered files by
    /// segment index, would be wrong the moment a stream rotated — which it
    /// does every 512 KB, unprompted, as maintenance.
    ///
    /// A line's hash covers its own `prev`, so it is unique in its chain and
    /// survives the move. That is the whole trick, and this is the test of it.
    func test_theMarkedLineSurvivesTheRotationThatMovesItIntoASegment() async throws {
        let store = makeStore()
        try await store.append(op("01"))
        try await store.append(op("02"))
        try await seal(store)

        let key = try streamKey(of: tailURL)
        let mark = try mark()
        let marked = try XCTUnwrap(mark[key]?.line, "the tail has an applied line")
        let beforeRotation = try lines(of: tailURL)
        XCTAssertEqual(
            OpLogChain.lineHash(try XCTUnwrap(beforeRotation.last)), marked,
            "the mark names the last line the reader applied — here, the seal")

        // One more line under the OLD permit's successor: written after the
        // mark, so it must judge new wherever it ends up.
        try await store.append(op("03"))

        let segURL = try await rotate(store)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tailURL.path),
                       "rotation DELETES the tail it sealed")

        try await store.append(op("04"))
        try await seal(store)

        // Verified fact 1: the new tail's first `prev` is genesis, not the
        // segment's last line. Each file is its own chain.
        let newTail = try lines(of: tailURL)
        XCTAssertEqual(try field("prev", of: try XCTUnwrap(newTail.first)),
                       OpLogChain.genesis,
                       "a new tail's first line links to genesis")

        // Verified fact 2: the marked line is now inside the segment.
        let segmentLines = try segmentLines(of: segURL)
        XCTAssertEqual(segmentLines.count, 4, "01, 02, the seal, then 03")
        let cut = try XCTUnwrap(
            segmentLines.firstIndex { OpLogChain.lineHash($0) == marked },
            "the line the mark names moved into the segment")
        XCTAssertEqual(cut, 2)

        // And the judgement did not move with it.
        XCTAssertEqual(PermitMark.stream(of: segURL)?.key, key,
                       "a segment and the tail it came from are ONE stream")
        let judged = mark.judge(
            streamKey: key,
            fileIsSegmentWithDigest: try digest(of: segURL),
            lines: segmentLines)
        XCTAssertEqual(judged.sides, [.old, .old, .old, .new],
                       "old through the marked line inclusive, new after it")
        XCTAssertEqual(judged.lastOldIndex, cut)

        // The tail written entirely after the mark is entirely new.
        let tailJudged = mark.judge(
            streamKey: key, fileIsSegmentWithDigest: nil, lines: newTail)
        XCTAssertTrue(tailJudged.isAllNew)
        XCTAssertEqual(tailJudged.sides.count, newTail.count)
    }

    /// The converse, so the rule above is a rule and not an accident: a
    /// segment the mark LISTS is wholly old, with no line search at all.
    func test_aSegmentTheMarkListsIsWhollyOld() async throws {
        let store = makeStore()
        try await store.append(op("01"))
        try await store.append(op("02"))
        try await seal(store)
        let segURL = try await rotate(store)

        let key = try streamKey(of: segURL)
        let mark = try mark()
        let segmentDigest = try digest(of: segURL)
        XCTAssertEqual(mark[key]?.segments, [segmentDigest],
                       "a settled segment is remembered by its digest")
        XCTAssertNil(mark[key]?.line,
                     "with the tail gone there is no last applied LINE to name")

        let judged = mark.judge(
            streamKey: key, fileIsSegmentWithDigest: segmentDigest,
            lines: try segmentLines(of: segURL))
        XCTAssertTrue(judged.isAllOld)
    }

    // MARK: - The three forgeries

    /// **A segment numbered to look ancient.** `seg0000` sorts before every
    /// real segment of the stream, and a rule that ordered files by index
    /// would read a demoted device's newest writing as its oldest. The index
    /// is part of a filename and a filename is the writer's to choose, so the
    /// mark never looks at one.
    func test_aForgedLowIndexSegmentNotInTheMarkIsAllNew() async throws {
        let store = makeStore()
        try await store.append(op("05"))
        try await seal(store)
        let real = try await rotate(store)
        let key = try streamKey(of: real)
        let mark = try mark()
        XCTAssertEqual(mark[key]?.segments.count, 1,
                       "the mark has a genuine segment in it")

        // The forgery: the same stream, index 0000, full of writing the root
        // never saw.
        let forged = OpLogStore.segmentFileURL(
            forDocId: docId, deviceSlug: slug, index: 0, in: projectURL)
        try OpLogSegment.encode(jsonl: try encodedLines([op("06"), op("07")]))
            .write(to: forged)
        XCTAssertEqual(
            OpLogStore.segmentIndex(fromFilename: forged.lastPathComponent,
                                    docId: docId, deviceSlug: slug), 0,
            "it really does read as index 0")
        XCTAssertEqual(try streamKey(of: forged), key, "and as the same stream")

        let judged = mark.judge(
            streamKey: key, fileIsSegmentWithDigest: try digest(of: forged),
            lines: try segmentLines(of: forged))
        XCTAssertTrue(judged.isAllNew,
                      "a segment the mark does not name is new, whatever it is called")
    }

    /// **A segment rewritten in place.** The filename is the one the root
    /// applied; the bytes are not. The digest the container carries is a
    /// commitment to its own uncompressed content, so changing a word changes
    /// the answer — which is exactly why the mark holds digests and not names.
    func test_aRewrittenListedSegmentIsAllNew() async throws {
        let store = makeStore()
        try await store.append(op("05"))
        try await seal(store)
        let segURL = try await rotate(store)
        let key = try streamKey(of: segURL)
        let mark = try mark()
        let applied = try digest(of: segURL)
        XCTAssertEqual(mark[key]?.segments, [applied])

        // Rewritten: same path, same index, different content.
        try OpLogSegment.encode(jsonl: try encodedLines([op("06"), op("07")]))
            .write(to: segURL)
        let rewritten = try digest(of: segURL)
        XCTAssertNotEqual(rewritten, applied)
        XCTAssertFalse(try XCTUnwrap(mark[key]?.segments).contains(rewritten))

        let judged = mark.judge(
            streamKey: key, fileIsSegmentWithDigest: rewritten,
            lines: try segmentLines(of: segURL))
        XCTAssertTrue(judged.isAllNew,
                      "the mark named a digest, and this file no longer has it")
    }

    /// **An opId backdated past the cut.** The one attack P2's mark cannot
    /// survive: an opId's high bits are a wall clock its own writer sets, so a
    /// demoted device stamps new text with an old id. The cut is positional —
    /// this line, in this chain — and reads no opId at all.
    func test_aBackdatedOpIdAfterTheMarkedLineIsStillNew() async throws {
        let store = makeStore()
        try await store.append(op("05-written-first"))
        let key = try streamKey(of: tailURL)
        let mark = try mark()
        let marked = try XCTUnwrap(mark[key]?.line)

        // Written after the mark, stamped to sort before it.
        try await store.append(op("01-backdated"))

        let tail = try lines(of: tailURL)
        XCTAssertEqual(tail.count, 2)
        XCTAssertEqual(OpLogChain.lineHash(tail[0]), marked)
        let earlier = try XCTUnwrap(try field("op_id", of: tail[1]))
        let later = try XCTUnwrap(try field("op_id", of: tail[0]))
        XCTAssertLessThan(earlier, later,
                          "the forgery really does carry the lower opId")

        let judged = mark.judge(
            streamKey: key, fileIsSegmentWithDigest: nil, lines: tail)
        XCTAssertEqual(judged.sides, [.old, .new],
                       "position decides, and the backdated line is after the cut")
    }

    // MARK: - Nothing applied, and two devices agreeing

    func test_anEmptyMarkJudgesEverythingNew() async throws {
        let store = makeStore()
        try await store.append(op("01"))
        try await store.append(op("02"))
        let tail = try lines(of: tailURL)
        let key = try streamKey(of: tailURL)

        XCTAssertTrue(PermitMark.nothingApplied.isEmpty)
        XCTAssertTrue(PermitMark.nothingApplied
            .judge(streamKey: key, fileIsSegmentWithDigest: nil, lines: tail).isAllNew)

        // A stream the mark NAMES but with nothing in it means the same thing,
        // and a stream it does not name at all means it too.
        let named = PermitMark([key: .init()])
        XCTAssertTrue(named
            .judge(streamKey: key, fileIsSegmentWithDigest: nil, lines: tail).isAllNew)
        XCTAssertTrue(named
            .judge(streamKey: "somebody-else.mac-z", fileIsSegmentWithDigest: nil,
                   lines: tail).isAllNew)
    }

    /// **Two devices judging the same bytes agree**, which is the property the
    /// whole design exists for: a fresh Mac with none of the root's memories
    /// reaches the root's answer, because the mark travels in the event and
    /// everything else it needs is in the file.
    func test_twoDevicesJudgingTheSameBytesAgree() async throws {
        let store = makeStore()
        try await store.append(op("01"))
        try await seal(store)
        let key = try streamKey(of: tailURL)
        let root = try mark()
        try await store.append(op("02"))
        let tail = try lines(of: tailURL)

        // The mark as it reaches the other device: through the event's wire
        // form and back.
        let wire = try JSONEncoder().encode(root.streams)
        let asRead = PermitMark(
            try JSONDecoder().decode([String: PermitMark.StreamMark].self, from: wire))
        XCTAssertEqual(asRead, root)

        XCTAssertEqual(
            root.judge(streamKey: key, fileIsSegmentWithDigest: nil, lines: tail),
            asRead.judge(streamKey: key, fileIsSegmentWithDigest: nil, lines: tail))
    }

    /// **One shape, two spellings.** `PermitEvent.StreamMark` IS
    /// `PermitMark.StreamMark`; a second struct would be a record this build
    /// reads and a rule it applies disagreeing about what a mark is, and it
    /// would fail silently by judging everything new.
    func test_aMarkIsTheEventsWireFormExactly() throws {
        XCTAssertTrue(PermitEvent.StreamMark.self == PermitMark.StreamMark.self)

        let streams: [String: PermitEvent.StreamMark] = [
            "d-chapter-4.mac-a": .init(segments: ["s1", "s2"], line: "l1"),
            "__project__.mac-a": .init(segments: [], line: nil),
        ]
        let fromRecord = PermitEvent(
            event: "aaaa.01", kind: .scopeChanged, subject: "aaaa",
            mark: streams, at: Date(timeIntervalSince1970: 30), by: "aaaa")
        let fromMark = PermitEvent(
            event: "aaaa.01", kind: .scopeChanged, subject: "aaaa",
            mark: PermitMark(streams).streams,
            at: Date(timeIntervalSince1970: 30), by: "aaaa")
        XCTAssertEqual(try RegistryCanonical.bytes(of: fromRecord),
                       try RegistryCanonical.bytes(of: fromMark),
                       "byte-identical under the form the signature covers")
    }

    // MARK: - Naming a stream

    /// The four shapes, and why the keys cannot collide. Every task that
    /// records a mark or cuts a span against one asks this function; a second
    /// spelling files a mark under a name no reader looks up.
    func test_everyStreamShapeHasOneKey() throws {
        let mac = DeviceSlug.unsafeForTesting("mac-a")
        let ops = projectURL.appendingPathComponent(".maugham/ops")

        XCTAssertEqual(
            PermitMark.streamKey(of: OpLogStore.opLogFileURL(
                forDocId: "d-one", deviceSlug: mac, in: projectURL)),
            "d-one.mac-a")
        XCTAssertEqual(
            PermitMark.streamKey(of: OpLogStore.segmentFileURL(
                forDocId: "d-one", deviceSlug: mac, index: 7, in: projectURL)),
            "d-one.mac-a",
            "a segment answers the same key as the tail it was rotated out of")
        XCTAssertEqual(
            PermitMark.streamKey(of: ops.appendingPathComponent("d-one.jsonl")),
            "d-one",
            "the legacy unsuffixed file belongs to no device, and has a key of its own")
        XCTAssertEqual(
            PermitMark.streamKey(of: OpLogStore.opLogFileURL(
                forDocId: "__project__", deviceSlug: mac, in: projectURL)),
            "__project__.mac-a")
        XCTAssertEqual(
            PermitMark.streamKey(of: TranslationStore.fileURL(
                forDocId: "d-one", language: "es", deviceSlug: mac, in: projectURL)),
            "translation:d-one.es.mac-a")
        XCTAssertEqual(
            PermitMark.streamKey(of: InboxManifest.inboxManifestURL(
                forDeviceSlug: mac, in: projectURL)),
            "inbox:mac-a")

        // The prefixes are what keep the three families apart: a doc called
        // `d-one` on a device slugged `es` is not a translation of `d-one`.
        XCTAssertNotEqual(
            PermitMark.streamKey(of: TranslationStore.fileURL(
                forDocId: "d-one", language: "es", deviceSlug: mac, in: projectURL)),
            PermitMark.streamKey(of: OpLogStore.opLogFileURL(
                forDocId: "d-one", deviceSlug: DeviceSlug.unsafeForTesting("es.mac-a"),
                in: projectURL)))

        XCTAssertNil(PermitMark.streamKey(
            of: projectURL.appendingPathComponent(".maugham/ops/notes.md")))
        XCTAssertNil(PermitMark.streamKey(
            of: projectURL.appendingPathComponent("manuscript.md")))
    }

    // MARK: - What `appliedPositions` records

    /// One device's streams and no other's. A mark is about a person's
    /// writing, and the file a stranger wrote in the same document is not it.
    func test_appliedPositionsRecordsOnlyTheNamedDevicesStreams() async throws {
        let mine = makeStore()
        try await mine.append(op("01"))
        let theirs = OpLogStore(
            projectURL: projectURL, identities: otherIdentities, state: otherState)
        try await theirs.append(op("02", by: other))

        let mark = try mark()
        XCTAssertEqual(Set(mark.streams.keys), [try streamKey(of: tailURL)])

        let otherTail = OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: other.slug, in: projectURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherTail.path),
                      "their file really is there — it is simply not marked")
        XCTAssertNil(mark[try streamKey(of: otherTail)])
    }

    /// The project stream is named by hand, exactly as its sibling and the
    /// open sweep name it: the manuscript-id reader excludes it by contract,
    /// so without naming it the task stream would have no position at all.
    func test_theProjectStreamIsMarkedToo() async throws {
        let store = makeStore()
        try await store.append(op("01"))
        let projectStore = OpLogStore(
            projectURL: projectURL, identities: identities, state: deviceState)
        try await projectStore.append(
            Op(opId: "02", docId: "__project__",
               at: Date(timeIntervalSince1970: 0), device: device.deviceId,
               session: "s", kind: .typingBurst,
               changes: [.init(paragraphId: "bbbb", prior: nil, next: "task")],
               sequence: ["bbbb"]))

        let projectTail = OpLogStore.opLogFileURL(
            forDocId: "__project__", deviceSlug: slug, in: projectURL)
        let mark = try mark()
        XCTAssertNotNil(mark[try streamKey(of: projectTail)]?.line)
        XCTAssertEqual(Set(mark.streams.keys),
                       [try streamKey(of: tailURL), try streamKey(of: projectTail)])
    }

    /// Neither of the two things a reader held back can be the position it got
    /// to. A quarantined line was refused and a pending one is not judged yet;
    /// the mark names the last line the reader actually APPLIED.
    func test_aLineTheReaderNeverAppliedIsNotThePosition() async throws {
        let store = makeStore()
        try await store.append(op("01"))
        try await store.append(op("02"))
        try await seal(store)
        let applied = try lines(of: tailURL)
        let key = try streamKey(of: tailURL)

        // A line spliced onto the end of a sealed file: correctly shaped, and
        // chained to nothing the walk will accept.
        var bytes = try Data(contentsOf: tailURL)
        bytes.append(OpLogChain.chainedLine(
            elementJSON: try encodedLines([op("03")]).dropLast(),
            prev: OpLogChain.lineHash(Data("not this file".utf8))))
        bytes.append(0x0A)
        try bytes.write(to: tailURL)

        let classified = OpLogStore.classify(
            url: tailURL, bytes: bytes, state: nil, trust: table)
        XCTAssertEqual(classified.verification?.lines.last?.state, .quarantined,
                       "the splice really is refused")

        let mark = try mark()
        XCTAssertEqual(mark[key]?.line,
                       OpLogChain.lineHash(try XCTUnwrap(applied.last)),
                       "the position is the last APPLIED line, not the last line")
    }

    // MARK: - What the segment digest is

    /// **Stated once, because two tasks downstream need to know**: the digest
    /// the mark holds is SHA-256 over the segment's UNCOMPRESSED JSONL, hex,
    /// read out of the container's own header — never over the compressed file
    /// bytes. So it is stable across a re-compression and it is the same number
    /// `SegmentSignature` signs and `classifySegment` settles on.
    func test_theSegmentDigestIsOverTheDecompressedJSONL() throws {
        let jsonl = try encodedLines([op("01"), op("02")])
        let container = try OpLogSegment.encode(jsonl: jsonl)
        let decoded = OpLogSegment.decodeVerifying(container)

        XCTAssertEqual(decoded.digest, Hex.encode(Data(SHA256.hash(data: jsonl))))
        XCTAssertNotEqual(decoded.digest, Hex.encode(Data(SHA256.hash(data: container))),
                          "not the file's bytes — the content's")
        XCTAssertEqual(
            OpLogSegment.decodeVerifying(
                try OpLogSegment.encode(jsonl: jsonl, algorithm: .lzma)).digest,
            decoded.digest,
            "and it survives a different compression of the same content")
    }

    // MARK: - Helpers

    /// `sealChain`, asserted. A helper because `XCTAssertTrue`'s argument is
    /// an autoclosure and an autoclosure cannot be async.
    private func seal(_ store: OpLogStore) async throws {
        let sealed = try await store.sealChain(docId: docId)
        XCTAssertTrue(sealed, "this device's own file seals under its own key")
    }

    /// The rotation: the tail is copied into a segment and deleted.
    private func rotate(_ store: OpLogStore) async throws -> URL {
        let url = try await store.sealTailIfNeeded(
            docId: docId, deviceSlug: slug, threshold: 1)
        return try XCTUnwrap(url, "a tail over the threshold rotates")
    }

    private func encodedLines(_ ops: [Op]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        encoder.outputFormatting = [.sortedKeys]
        var out = Data()
        for one in ops {
            out.append(try encoder.encode(one))
            out.append(0x0A)
        }
        return out
    }
}
