import Foundation
import XCTest
@testable import MaughamCore

/// **This device's memory of where OTHER devices' streams stood** (signed op
/// log P3a Task 9, spec §4.7), through real loads of a real project.
///
/// Two jobs, and they are not the same job:
///
/// 1. A foreign stream found SHORTER than this Mac remembered it is a finding.
///    Nothing is refused over it, the surviving lines stay applied, and it is
///    reported once rather than once per load.
/// 2. A position sweep must not silently omit a stream this Mac HAS applied.
///    A mark that does not name a stream judges it wholly new, so a stream
///    that is merely missing at sweep time would make a demotion reach back
///    through every line of it — and, on a *keep what was applied* revocation,
///    set aside words this Mac had already put in front of the writer.
///
/// The fixtures are `PermitLoadTests`' shape: a project temp root removed in
/// `tearDown`, software keys from `DeviceIdentity+Testing` alone (tripwire 36),
/// and a per-suite `OpLogDeviceState` so nothing touches `.shared` beside this
/// machine's real keys.
@MainActor
final class ForeignHeadTests: XCTestCase {

    private let docId = "doc-foreign"
    private var projectURL: URL!
    private var root: LocalIdentities!
    private var rootState: OpLogDeviceState!
    private var sam: LocalIdentities!
    private var samState: OpLogDeviceState!
    private var cache: RegistryCache!

    override func setUp() async throws {
        projectURL = TestTemp.root
            .appendingPathComponent("foreign-head-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".maugham/ops"),
            withIntermediateDirectories: true)
        root = .softwareForTesting()
        sam = .softwareForTesting()
        rootState = state("root")
        samState = state("sam")
        cache = RegistryCache(
            fileURL: projectURL.appendingPathComponent("registry-cache.json"),
            identity: root.author.fingerprint)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: projectURL)
    }

    private func state(_ name: String) -> OpLogDeviceState {
        OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("state-\(name).json"))
    }

    // MARK: - Fixtures

    private var rootPerson: String { root.author.fingerprint }
    private var samPerson: String { sam.author.fingerprint }
    private var samSlug: String { sam.author.slug.raw }
    private var samStreamKey: String { "\(docId).\(samSlug)" }

    private func op(_ opId: String, by identity: DeviceIdentity) -> Op {
        Op(opId: opId, docId: docId, at: Date(timeIntervalSince1970: 0),
           device: identity.deviceId, session: "s", kind: .typingBurst,
           changes: [.init(paragraphId: "aaaa", prior: nil, next: opId)],
           sequence: ["aaaa"])
    }

    private func reader() -> OpLogStore {
        OpLogStore(projectURL: projectURL, identities: root,
                   state: rootState, cache: cache)
    }

    private func samsStore() -> OpLogStore {
        OpLogStore(projectURL: projectURL, identities: sam,
                   state: samState, cache: cache)
    }

    private func writeRootRecord() throws {
        try RegistryWriter.write(
            PersonRecord(
                person: rootPerson, label: "Denver", ownName: "Denver’s MacBook",
                admittedAt: Date(timeIntervalSince1970: 10), admittedBy: rootPerson),
            signedBy: root.author, in: projectURL)
        try RegistryWriter.write(
            DeviceRecord(
                device: rootPerson, name: "Denver’s MacBook", kind: .mac,
                actors: [DeviceActor.author.rawValue: rootPerson],
                madeAt: Date(timeIntervalSince1970: 1)),
            signedBy: root.author, in: projectURL)
    }

    private func admitSam() throws {
        try RegistryWriter.write(
            PersonRecord(
                person: samPerson, label: "Sam", ownName: "Sam’s Mac",
                admittedAt: Date(timeIntervalSince1970: 20), admittedBy: rootPerson),
            signedBy: root.author, in: projectURL)
        try RegistryWriter.write(
            DeviceRecord(
                device: samPerson, name: "Sam’s Mac", kind: .mac,
                actors: [DeviceActor.author.rawValue: samPerson],
                madeAt: Date(timeIntervalSince1970: 5)),
            signedBy: sam.author, in: projectURL)
    }

    /// One device's own op-log file: chained and sealed under the key that
    /// wrote it, exactly as `PermitLoadTests` builds one.
    @discardableResult
    private func writeFile(by identity: DeviceIdentity, ops: [Op]) throws -> URL {
        let url = OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: identity.slug, in: projectURL)
        try chained(ops, by: identity).write(to: url, options: .atomic)
        return url
    }

    private func chained(_ ops: [Op], by identity: DeviceIdentity) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        var bytes = Data()
        var head: String?
        for element in try ops.map({ try encoder.encode($0) }) {
            let line = OpLogChain.chainedLine(
                elementJSON: element, prev: head ?? OpLogChain.genesis)
            bytes.append(line)
            bytes.append(0x0A)
            head = OpLogChain.lineHash(line)
        }
        let seal = try OpLogChain.Seal.line(
            head: try XCTUnwrap(head), identity: identity,
            at: Date(timeIntervalSince1970: 50))
        bytes.append(seal)
        bytes.append(0x0A)
        return bytes
    }

    /// Keep the first `count` LINES of a file and throw the rest away — a
    /// stream somebody shortened. Every line that remains still chains
    /// perfectly, which is the whole difficulty: the chain rules cannot fault
    /// a truncation, only a memory can.
    private func truncate(_ url: URL, toFirst count: Int) throws {
        let bytes = try Data(contentsOf: url)
        let lines = bytes.split(separator: 0x0A, omittingEmptySubsequences: true)
        var kept = Data()
        for line in lines.prefix(count) {
            kept.append(contentsOf: line)
            kept.append(0x0A)
        }
        try kept.write(to: url, options: .atomic)
    }

    @discardableResult
    private func load() async throws -> [String] {
        try await reader().loadDiagnosed(docId: docId).ops.map(\.opId)
    }

    private func truncations() -> [OpLogDeviceState.StreamTruncation] {
        rootState.truncations(inRoot: projectURL)
    }

    // MARK: - Job 1: a shortened stream is noticed

    /// **The pin.** Read a foreign device's file, watch it get shorter, and
    /// the loss is reported — once, with the surviving lines still in the
    /// document.
    func test_aForeignStreamThatGetsShorterIsNoticedOnceAndRefusesNothing() async throws {
        try writeRootRecord()
        try admitSam()
        let url = try writeFile(
            by: sam.author,
            ops: ["01", "02", "03", "04"].map { op($0, by: sam.author) })

        var applied = try await load()
        XCTAssertEqual(applied, ["01", "02", "03", "04"])
        XCTAssertTrue(truncations().isEmpty, "nothing is wrong yet")

        // Two ops and the seal go; the two that remain chain as they always did.
        try truncate(url, toFirst: 2)
        applied = try await load()

        XCTAssertEqual(
            applied, ["01", "02"],
            "the words that remain are good and stay in the document")
        let found = truncations()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.streamKey, samStreamKey)
        XCTAssertEqual(found.first?.deviceSlug, samSlug)
        XCTAssertTrue(
            OpLogQuarantine.records(forDocId: docId, in: projectURL).isEmpty,
            "nothing is set aside over a truncation")

        // And a third load says nothing new: the memory moved on to what is
        // there now, so *once* is once and not once per open.
        let noticedAt = try XCTUnwrap(found.first?.noticedAt)
        let third = try await load()
        XCTAssertEqual(third, ["01", "02"])
        XCTAssertEqual(truncations().count, 1)
        XCTAssertEqual(truncations().first?.noticedAt, noticedAt)
    }

    /// **Rotation is not truncation.** `sealTailIfNeeded` copies the whole tail
    /// into a `.mzseg`, deletes the tail, and the next append starts from
    /// genesis — so the remembered line is in a file that this load never even
    /// walks, because a segment its own signature settled is taken in whole.
    /// Keying the memory on the FILENAME turns that ordinary maintenance into
    /// an accusation.
    func test_rememberRotateReadRaisesNoFinding() async throws {
        try writeRootRecord()
        try admitSam()
        try writeFile(
            by: sam.author,
            ops: ["01", "02", "03", "04"].map { op($0, by: sam.author) })

        let first = try await load()
        XCTAssertEqual(first, ["01", "02", "03", "04"])

        // Sam's own Mac rotates her tail, signing the segment with her key.
        let segment = try await samsStore().sealTailIfNeeded(
            docId: docId, deviceSlug: sam.author.slug, threshold: 1)
        XCTAssertNotNil(segment, "a tail over the threshold rotates")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: OpLogStore.opLogFileURL(
                forDocId: docId, deviceSlug: sam.author.slug,
                in: projectURL).path),
            "rotation DELETES the tail — that is why this is hard")

        let afterRotation = try await load()
        XCTAssertEqual(afterRotation, ["01", "02", "03", "04"])
        XCTAssertTrue(
            truncations().isEmpty,
            "a stream that rotated lost nothing")

        // And the stream is still watched afterwards: Sam writes again into a
        // fresh tail, and the memory follows her there.
        try writeFile(by: sam.author, ops: [op("05", by: sam.author)])
        let afterMore = try await load()
        XCTAssertEqual(afterMore, ["01", "02", "03", "04", "05"])
        XCTAssertTrue(truncations().isEmpty)
        XCTAssertNotNil(
            rootState.foreignStream(samStreamKey, inRoot: projectURL)?.head,
            "the new tail's last line is what the stream stands at now")

        // Rotate-and-append, in one window: the tail is rotated away AND a
        // fresh line lands before this Mac next looks. The digests are what
        // make that readable — the remembered line is inside a segment whose
        // digest is new — where a count could be fooled by a deletion in the
        // same window.
        _ = try await samsStore().sealTailIfNeeded(
            docId: docId, deviceSlug: sam.author.slug, threshold: 1)
        try writeFile(by: sam.author, ops: [op("06", by: sam.author)])
        let afterBoth = try await load()
        XCTAssertEqual(afterBoth, ["01", "02", "03", "04", "05", "06"])
        XCTAssertTrue(truncations().isEmpty, "rotate-and-append lost nothing")
    }

    // MARK: - A stream is remembered only once it has ANSWERED

    /// **A present, readable file that yields NOTHING is not remembered** (fix
    /// round 1's Important). `positions` names no such stream in a mark — there
    /// is no line it ever saw and no segment it took in whole — so remembering
    /// it would make `expectedStreams` demand a name the sweep can never
    /// produce, and every verb of the root's would refuse for ever over a file
    /// that is sitting there perfectly readable.
    func test_aForeignFileThatAnswersNothingIsNotRemembered() async throws {
        try writeRootRecord()
        try admitSam()
        // A zero-byte tail: synced ahead of its own contents.
        let url = OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: sam.author.slug, in: projectURL)
        try Data().write(to: url, options: .atomic)

        let applied = try await load()
        XCTAssertTrue(applied.isEmpty)
        XCTAssertTrue(
            rootState.foreignStreams(
            inRoot: projectURL, writtenBy: [samSlug]).isEmpty,
            "nothing answered, so there is nothing to expect")

        // And the sweep the root's verbs run agrees: it names no such stream,
        // which is exactly why the memory must not ask for one.
        let table = try await reader().trust()
        let mark = try OpLogStore.seenPositions(
            ofDeviceIds: Set(sam.all.map(\.deviceId)), in: projectURL, trust: table)
        XCTAssertNil(mark[samStreamKey])
        XCTAssertNoThrow(
            try OpLogStore.seenPositions(
                ofDeviceIds: Set(sam.all.map(\.deviceId)), in: projectURL,
                trust: table,
                expecting: rootState.foreignStreams(
            inRoot: projectURL, writtenBy: [samSlug])))
    }

    /// The same, for the other way a present file answers nothing: a first line
    /// somebody corrupted, so every line after it is `chainBroke` and none of
    /// them was ever *seen*.
    func test_aForeignFileWhoseChainBrokeAtItsFirstLineIsNotRemembered() async throws {
        try writeRootRecord()
        try admitSam()
        let url = try writeFile(
            by: sam.author, ops: ["01", "02"].map { op($0, by: sam.author) })
        var bytes = try Data(contentsOf: url)
        // Break the FIRST line's `prev`, so the walk breaks before anything.
        guard let range = bytes.range(of: Data("{\"prev\":\"".utf8)) else {
            return XCTFail("a chained line starts with its prev")
        }
        bytes.replaceSubrange(
            range.upperBound..<(range.upperBound + 4), with: Data("ffff".utf8))
        try bytes.write(to: url, options: .atomic)

        _ = try await load()
        XCTAssertTrue(
            rootState.foreignStreams(
            inRoot: projectURL, writtenBy: [samSlug]).isEmpty,
            "a file whose every line is refused has told this Mac nothing")
    }

    /// **A stream whose only content is settled SEGMENTS is remembered**, and
    /// the sweep names it through the same digests — the two notions of
    /// *answered* are one, because a disagreement is the Important's bug in
    /// another coat.
    func test_aSegmentOnlyStreamIsRememberedAndNamedByTheSweep() async throws {
        try writeRootRecord()
        try admitSam()
        try writeFile(
            by: sam.author, ops: ["01", "02"].map { op($0, by: sam.author) })
        _ = try await samsStore().sealTailIfNeeded(
            docId: docId, deviceSlug: sam.author.slug, threshold: 1)

        // A fresh memory, so this load is the FIRST sight of the stream and
        // there is no tail left for it to answer with.
        rootState = state("root-segment-only")
        let applied = try await load()
        XCTAssertEqual(applied, ["01", "02"])

        let expected = rootState.foreignStreams(
            inRoot: projectURL, writtenBy: [samSlug])
        XCTAssertEqual(Set(expected.keys), [samStreamKey], "the segment is an answer")
        XCTAssertFalse(
            rootState.foreignStream(samStreamKey, inRoot: projectURL)?
                .segmentDigests.isEmpty ?? true)

        let mark = try OpLogStore.seenPositions(
            ofDeviceIds: Set(sam.all.map(\.deviceId)), in: projectURL,
            trust: try await reader().trust(), expecting: expected)
        XCTAssertEqual(
            Set(mark[samStreamKey]?.segments ?? []),
            rootState.foreignStream(samStreamKey, inRoot: projectURL)?.segmentDigests,
            "the memory and the mark are built from one answer")
    }

    /// **A whole sealed segment that went missing is a finding of its own
    /// kind** — the history's copy is gone even though every line already
    /// applied stays applied.
    func test_adeletedSegmentIsItsOwnFinding() async throws {
        try writeRootRecord()
        try admitSam()
        try writeFile(
            by: sam.author, ops: ["01", "02"].map { op($0, by: sam.author) })
        let rotated = try await samsStore().sealTailIfNeeded(
            docId: docId, deviceSlug: sam.author.slug, threshold: 1)
        let segment = try XCTUnwrap(rotated)
        try writeFile(by: sam.author, ops: [op("03", by: sam.author)])
        _ = try await load()
        XCTAssertTrue(truncations().isEmpty)

        try FileManager.default.removeItem(at: segment)
        try? FileManager.default.removeItem(
            at: OpLogStore.segmentSignatureURL(for: segment))
        let applied = try await load()

        XCTAssertEqual(applied, ["03"], "what remains is still applied")
        let found = truncations()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.loss, .segment)
        let named = OpLogStore.truncatedStreams(
            in: projectURL, state: rootState, trust: try await reader().trust())
        XCTAssertTrue(
            named.first?.sentence.contains("sealed history is missing") ?? false,
            "the finding says which loss it is: \(named.first?.sentence ?? "—")")
    }

    /// A `.mzseg` that is present and cannot be settled — evicted, corrupt, or
    /// signed by a key this device cannot stand behind — is **not** a deletion.
    /// Under-counting the segments must never read as somebody removing one.
    func test_anUnsettledSegmentIsNotADeletedOne() async throws {
        try writeRootRecord()
        try admitSam()
        try writeFile(
            by: sam.author, ops: ["01", "02"].map { op($0, by: sam.author) })
        let rotated = try await samsStore().sealTailIfNeeded(
            docId: docId, deviceSlug: sam.author.slug, threshold: 1)
        let segment = try XCTUnwrap(rotated)
        try writeFile(by: sam.author, ops: [op("03", by: sam.author)])
        _ = try await load()

        // The container is still there and no longer decodes.
        try Data("not a segment".utf8).write(to: segment, options: .atomic)
        _ = try await load()

        XCTAssertTrue(
            truncations().isEmpty,
            "a segment that will not open is present, not deleted")
    }

    /// **A finding is a fact that holds now.** When the bytes come back — iCloud
    /// finishes, a file is restored — the stream stops being a finding rather
    /// than staying unhealthy for ever.
    func test_afindingIsClearedWhenWhatWentMissingComesBack() async throws {
        try writeRootRecord()
        try admitSam()
        let url = try writeFile(
            by: sam.author,
            ops: ["01", "02", "03"].map { op($0, by: sam.author) })
        _ = try await load()
        let whole = try Data(contentsOf: url)

        try truncate(url, toFirst: 1)
        _ = try await load()
        XCTAssertEqual(truncations().count, 1)

        try whole.write(to: url, options: .atomic)
        _ = try await load()
        XCTAssertTrue(truncations().isEmpty, "what came back is not missing")

        let report = try await ProjectIntegrity.check(
            projectURL: projectURL, state: rootState)
        XCTAssertTrue(report.isHealthy)
    }

    /// A stream this Mac has never read is not truncated — it is new, which is
    /// what honest late sync looks like.
    func test_aStreamSeenForTheFirstTimeIsNotAFinding() async throws {
        try writeRootRecord()
        try admitSam()
        try writeFile(by: sam.author, ops: [op("01", by: sam.author)])

        let seen = try await load()
        XCTAssertEqual(seen, ["01"])
        XCTAssertTrue(truncations().isEmpty)
        XCTAssertEqual(
            Set(rootState.foreignStreams(
                inRoot: projectURL, writtenBy: [samSlug]).keys),
            [samStreamKey])
    }

    /// **This device's own files stay in `heads`.** The foreign memory is
    /// about somebody else, and remembering this Mac's own streams twice would
    /// be two answers to where its own history stands — the one question the
    /// chained write depends on.
    func test_thisDevicesOwnStreamIsNotRememberedAsAForeignOne() async throws {
        try writeRootRecord()
        try writeFile(by: root.author, ops: [op("01", by: root.author)])

        let mine = try await load()
        XCTAssertEqual(mine, ["01"])
        XCTAssertTrue(
            rootState.foreignStreams(
                inRoot: projectURL, writtenBy: [root.author.slug.raw]).isEmpty)
    }

    /// The legacy unsuffixed `<docId>.jsonl` is nobody's stream — it is the one
    /// file with more than one writer, which is why a mark never names it
    /// either — so nothing is remembered about it.
    func test_theLegacySharedFileIsNobodysStream() async throws {
        try writeRootRecord()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        var bytes = try encoder.encode(op("01", by: sam.author))
        bytes.append(0x0A)
        try bytes.write(
            to: projectURL.appendingPathComponent(".maugham/ops/\(docId).jsonl"),
            options: .atomic)

        let legacy = try await load()
        XCTAssertEqual(legacy, ["01"])
        XCTAssertTrue(
            rootState.foreignStreams(
            inRoot: projectURL, writtenBy: [samSlug]).isEmpty)
        XCTAssertTrue(truncations().isEmpty)
    }

    /// **`loadSyncMerged` writes nothing**, by design and still. It takes no
    /// watch, so the synchronous reader cannot record a memory the coordinated
    /// one would have to agree with.
    func test_theSynchronousReaderRemembersNothing() async throws {
        try writeRootRecord()
        try admitSam()
        try writeFile(by: sam.author, ops: [op("01", by: sam.author)])

        let before = rootState.persistCountForTesting
        _ = try OpLogStore.loadSyncMerged(
            forDocId: docId, in: projectURL, identities: root,
            state: rootState, trust: try await reader().trust())

        XCTAssertEqual(rootState.persistCountForTesting, before)
        XCTAssertTrue(
            rootState.foreignStreams(
            inRoot: projectURL, writtenBy: [samSlug]).isEmpty)
    }

    /// A load that changed nothing rewrites nothing. The memory is read on
    /// every open of every chapter, so a write per file per load would be a
    /// file rewrite per foreign device per document, forever.
    func test_asecondLoadOfAnUnchangedStreamWritesNothing() async throws {
        try writeRootRecord()
        try admitSam()
        try writeFile(by: sam.author, ops: [op("01", by: sam.author)])
        _ = try await load()

        let before = rootState.persistCountForTesting
        _ = try await load()
        XCTAssertEqual(rootState.persistCountForTesting, before)
    }

    /// And a document spread over several foreign files is ONE write, not one
    /// per file.
    func test_awholeLoadSettlesInOneWrite() async throws {
        try writeRootRecord()
        try admitSam()
        let other = LocalIdentities.softwareForTesting()
        try writeFile(by: sam.author, ops: [op("01", by: sam.author)])
        try writeFile(by: other.author, ops: [op("02", by: other.author)])

        let before = rootState.persistCountForTesting
        _ = try await load()
        XCTAssertEqual(
            rootState.persistCountForTesting, before + 1,
            "two foreign streams, one rewrite of the memory")
    }

    // MARK: - A translation stream

    /// The other families answer to the same memory, because a mark names them
    /// too: a translation sidecar this Mac has read and can no longer find is
    /// the same defect one directory over.
    func test_aTranslationStreamIsRememberedAndItsTruncationNoticed() async throws {
        try writeRootRecord()
        try admitSam()
        let url = try writeTranslation(
            by: sam.translator, records: ["01", "02", "03"])

        _ = try readTranslations()
        XCTAssertTrue(truncations().isEmpty)

        try truncate(url, toFirst: 1)
        _ = try readTranslations()

        let found = truncations()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(
            found.first?.streamKey,
            "translation:\(docId).es.\(sam.translator.slug.raw)")
    }

    private func writeTranslation(
        by identity: DeviceIdentity, records: [String]
    ) throws -> URL {
        let dir = TranslationStore.directoryURL(in: projectURL)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = JSONLAppendStore<TranslationRecord>.dateEncoding
        var bytes = Data()
        var head: String?
        for opId in records {
            let record = TranslationRecord(
                opId: opId, paragraphId: "aaaa", language: "es",
                text: opId, sourceHash: "h",
                at: Date(timeIntervalSince1970: 0))
            let line = OpLogChain.chainedLine(
                elementJSON: try encoder.encode(record),
                prev: head ?? OpLogChain.genesis)
            bytes.append(line)
            bytes.append(0x0A)
            head = OpLogChain.lineHash(line)
        }
        let seal = try OpLogChain.Seal.line(
            head: try XCTUnwrap(head), identity: identity,
            at: Date(timeIntervalSince1970: 50))
        bytes.append(seal)
        bytes.append(0x0A)
        let url = dir.appendingPathComponent(
            "\(docId).es.\(identity.slug.raw).jsonl")
        try bytes.write(to: url, options: .atomic)
        return url
    }

    private func readTranslations() throws -> [TranslationRecord] {
        try TranslationStore.loadMerged(
            forDocId: docId, language: "es", in: projectURL,
            identities: root, state: rootState)
    }

    // MARK: - Job 2: a sweep must not omit a stream this Mac applied

    /// **The hook Task 7 built, supplied.** A stream this Mac remembers and
    /// cannot find refuses the sweep by name, rather than producing a mark
    /// that judges every line of it new.
    func test_aRememberedStreamThatHasVanishedRefusesTheSweep() async throws {
        try writeRootRecord()
        try admitSam()
        let url = try writeFile(by: sam.author, ops: [op("01", by: sam.author)])
        _ = try await load()

        let expected = rootState.foreignStreams(
            inRoot: projectURL, writtenBy: [samSlug])
        XCTAssertEqual(Set(expected.keys), [samStreamKey])

        // iCloud takes the file away mid-sync.
        try FileManager.default.removeItem(at: url)
        let table = try await reader().trust()

        XCTAssertThrowsError(
            try OpLogStore.seenPositions(
                ofDeviceIds: Set(sam.all.map(\.deviceId)), in: projectURL,
                trust: table, expecting: expected)
        ) { error in
            guard case let OpLogStore.ReadError.streamMissingFromSweep(key) = error
            else { return XCTFail("a stream this Mac had applied is missing") }
            XCTAssertEqual(key, self.samStreamKey)
        }

        // Its converse, and the reason the memory is of FOREIGN streams only:
        // a stream nobody has ever read is honest late sync, is not expected,
        // and the sweep answers.
        XCTAssertNoThrow(
            try OpLogStore.seenPositions(
                ofDeviceIds: Set(sam.all.map(\.deviceId)), in: projectURL,
                trust: table, expecting: [:]))
    }

    // MARK: - A stream that came back NAMED and SHORT (final fix wave, W2)

    /// **The rotation mid-sync**, which is the case checking NAMES could not
    /// see and the shipped Revoke button walks straight into.
    ///
    /// Sam's Mac rotates: the live tail is sealed into a `.mzseg` and the tail
    /// is deleted. The two changes are two files and they sync independently,
    /// so the root's disk can hold the DELETION without yet holding the
    /// segment. The stream key is still there — a fresh tail exists — so the
    /// old guard saw the name come back and let the sweep through with a mark
    /// that had forgotten a whole segment. The root presses Revoke (*keep what
    /// was applied*); the segment arrives; every line in it is unlisted and
    /// unmarked, judges NEW, and is set aside. The mark is a signed shared
    /// event, so every device inherits that cut.
    func test_aRotationWhoseSegmentHasNotArrivedYetRefusesTheSweep() async throws {
        try writeRootRecord()
        try admitSam()
        try writeFile(
            by: sam.author, ops: ["01", "02"].map { op($0, by: sam.author) })
        let rotated = try await samsStore().sealTailIfNeeded(
            docId: docId, deviceSlug: sam.author.slug, threshold: 1)
        let segment = try XCTUnwrap(rotated)
        try writeFile(by: sam.author, ops: [op("03", by: sam.author)])
        _ = try await load()

        let expected = rootState.foreignStreams(
            inRoot: projectURL, writtenBy: [samSlug])
        XCTAssertFalse(
            expected[samStreamKey]?.segmentDigests.isEmpty ?? true,
            "this Mac remembers taking the segment in whole")

        // The segment has not reached this disk yet, while the new tail has.
        try FileManager.default.removeItem(at: segment)
        try? FileManager.default.removeItem(
            at: OpLogStore.segmentSignatureURL(for: segment))
        let table = try await reader().trust()

        // The NAME is still there — which is exactly why a name was not enough.
        let short = try OpLogStore.seenPositions(
            ofDeviceIds: Set(sam.all.map(\.deviceId)), in: projectURL, trust: table)
        XCTAssertNotNil(short[samStreamKey], "the stream is named")
        XCTAssertTrue(short[samStreamKey]?.segments.isEmpty ?? false,
                      "and its position has forgotten the segment")

        for seen in [true, false] {
            XCTAssertThrowsError(
                seen
                    ? try OpLogStore.seenPositions(
                        ofDeviceIds: Set(sam.all.map(\.deviceId)), in: projectURL,
                        trust: table, expecting: expected)
                    : try OpLogStore.appliedPositions(
                        ofDeviceIds: Set(sam.all.map(\.deviceId)), in: projectURL,
                        trust: table, expecting: expected)
            ) { error in
                guard case let OpLogStore.ReadError
                    .streamMissingFromSweep(key) = error
                else { return XCTFail("\(error)") }
                XCTAssertEqual(key, self.samStreamKey)
            }
        }
    }

    /// **The converse: a stream that legitimately GREW is not refused.** A new
    /// segment AND a new tail is what an honest rotation looks like once both
    /// halves have arrived, and a guard that refused it would refuse every verb
    /// after every maintenance pass.
    func test_aStreamThatGrewIsNotRefused() async throws {
        try writeRootRecord()
        try admitSam()
        try writeFile(by: sam.author, ops: [op("01", by: sam.author)])
        _ = try await load()
        let before = rootState.foreignStreams(
            inRoot: projectURL, writtenBy: [samSlug])
        XCTAssertNotNil(before[samStreamKey])

        // Sam rotates and writes on. Both halves are here.
        _ = try await samsStore().sealTailIfNeeded(
            docId: docId, deviceSlug: sam.author.slug, threshold: 1)
        try writeFile(by: sam.author, ops: [op("02", by: sam.author)])

        let table = try await reader().trust()
        XCTAssertNoThrow(
            try OpLogStore.seenPositions(
                ofDeviceIds: Set(sam.all.map(\.deviceId)), in: projectURL,
                trust: table, expecting: before))
        XCTAssertNoThrow(
            try OpLogStore.appliedPositions(
                ofDeviceIds: Set(sam.all.map(\.deviceId)), in: projectURL,
                trust: table, expecting: before))
    }

    /// **A tail somebody cut back is refused too** — the same predicate's other
    /// arm, and the one a load merely REPORTS. A verb that marks may not
    /// proceed over it, because the line it would record is behind lines this
    /// Mac had applied.
    func test_aTailCutBackBehindWhatThisMacAppliedRefusesTheSweep() async throws {
        try writeRootRecord()
        try admitSam()
        let url = try writeFile(
            by: sam.author,
            ops: ["01", "02", "03"].map { op($0, by: sam.author) })
        _ = try await load()
        let expected = rootState.foreignStreams(
            inRoot: projectURL, writtenBy: [samSlug])

        try truncate(url, toFirst: 1)
        let table = try await reader().trust()

        let short = try OpLogStore.seenPositions(
            ofDeviceIds: Set(sam.all.map(\.deviceId)), in: projectURL, trust: table)
        XCTAssertNotNil(short[samStreamKey], "the stream is still named")

        XCTAssertThrowsError(
            try OpLogStore.seenPositions(
                ofDeviceIds: Set(sam.all.map(\.deviceId)), in: projectURL,
                trust: table, expecting: expected))
    }

    /// The same, for the revocation's question — *keep what this Mac had
    /// applied* is the act a short mark damages most.
    func test_theAppliedSweepRefusesOverAVanishedStreamToo() async throws {
        try writeRootRecord()
        try admitSam()
        let url = try writeFile(by: sam.author, ops: [op("01", by: sam.author)])
        _ = try await load()
        let expected = rootState.foreignStreams(
            inRoot: projectURL, writtenBy: [samSlug])
        try FileManager.default.removeItem(at: url)
        let table = try await reader().trust()

        XCTAssertThrowsError(
            try OpLogStore.appliedPositions(
                ofDeviceIds: Set(sam.all.map(\.deviceId)), in: projectURL,
                trust: table, expecting: expected))
    }

    // MARK: - The memory itself

    /// A state file written before P3a decodes, keeps its heads, and answers
    /// the never-seen-anybody case for the fields it has never heard of.
    func test_anOlderStateFileDecodes() throws {
        let url = projectURL.appendingPathComponent("legacy-state.json")
        let identity = DeviceIdentity.softwareForTesting()
        let legacy: [String: Any] = [
            "identity": identity.fingerprint,
            "heads": ["abc/one.jsonl": "deadbeef"],
            "previousHeads": [:],
            "verifiedSegments": ["digest"],
            // A root that is still on disk, so the pruning pass at `init`
            // keeps the head and this test is about the DECODE.
            "roots": ["abc": projectURL.path],
        ]
        try JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys])
            .write(to: url, options: .atomic)

        let loaded = OpLogDeviceState(fileURL: url, identity: identity.fingerprint)
        XCTAssertEqual(loaded.head(for: "abc/one.jsonl"), "deadbeef")
        XCTAssertTrue(loaded.isVerified(segmentDigest: "digest"))
        XCTAssertTrue(loaded.truncations(inRoot: projectURL).isEmpty)
        XCTAssertTrue(
            loaded.foreignStreams(
            inRoot: projectURL, writtenBy: ["any"]).isEmpty)
    }

    /// **Pruned from day one**, by the rule that already prunes heads: a
    /// project that is gone takes its memory with it, and a project on an
    /// unmounted volume keeps it (`rootIsGone`'s second clause).
    func test_pruneDropsAGoneProjectsForeignStreams() throws {
        let parent = TestTemp.root
            .appendingPathComponent("foreign-prune-\(UUID().uuidString)")
        let gone = parent.appendingPathComponent("book")
        try FileManager.default.createDirectory(
            at: gone, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let url = projectURL.appendingPathComponent("prune-state.json")
        let identity = DeviceIdentity.softwareForTesting()
        let memory = OpLogDeviceState(fileURL: url, identity: identity.fingerprint)
        memory.settleForeign([.init(
            streamKey: "doc-x.sam", root: gone,
            memory: .init(deviceSlug: "sam", head: "abc", segmentDigests: []),
            truncation: .init(
                streamKey: "doc-x.sam", deviceSlug: "sam",
                lost: "abc", noticedAt: Date(timeIntervalSince1970: 1)))])
        XCTAssertEqual(memory.truncations(inRoot: gone).count, 1)

        // The project goes; its enclosing folder stays, which is what tells a
        // deletion from an unmounted volume.
        try FileManager.default.removeItem(at: gone)
        let reopened = OpLogDeviceState(fileURL: url, identity: identity.fingerprint)
        XCTAssertTrue(reopened.truncations(inRoot: gone).isEmpty)
        XCTAssertTrue(
            reopened.foreignStreams(
            inRoot: gone, writtenBy: ["sam"]).isEmpty)
    }

    // MARK: - A loss the writer has been shown (P3b Task 6)

    /// **The one comparison, three answers.** `settle` used to recompute the
    /// rotation tolerance and the missing-digest set beside its call to
    /// `loss`, which is two spellings of the same arithmetic — one deciding
    /// *was anything lost*, the other *may I keep the head I remembered*.
    func test_theComparisonAnswersRotationAndMissingBesideTheLoss() throws {
        let remembered = OpLogDeviceState.ForeignStreamMemory(
            deviceSlug: "sam", head: "line-a", segmentDigests: ["seg-1"])

        // A rotation: a digest this device had not seen, and the remembered
        // line no longer in the tail. Nothing was lost.
        let rotation = ForeignStreamWatch.outcome(
            remembered: remembered,
            found: .init(digests: ["seg-1", "seg-2"], holdsRemembered: false,
                         answered: true))
        XCTAssertTrue(rotation.rotated)
        XCTAssertTrue(rotation.missingSegments.isEmpty)
        XCTAssertNil(rotation.loss)

        // A segment that is gone, with no new one to explain it.
        let gone = ForeignStreamWatch.outcome(
            remembered: remembered,
            found: .init(digests: [], holdsRemembered: true, answered: true))
        XCTAssertFalse(gone.rotated)
        XCTAssertEqual(gone.missingSegments, ["seg-1"])
        XCTAssertEqual(gone.loss, .segment("seg-1"))

        // A `.mzseg` that is present and will not settle is not a deletion,
        // and the missing set says so rather than the caller remembering to.
        let unsettled = ForeignStreamWatch.outcome(
            remembered: remembered,
            found: .init(digests: [], sawUnsettledSegment: true,
                         holdsRemembered: true, answered: true))
        XCTAssertTrue(unsettled.missingSegments.isEmpty)
        XCTAssertNil(unsettled.loss)

        // And `loss` is that field, never a second opinion.
        for found: ForeignStreamWatch.Found in [
            .init(digests: ["seg-1", "seg-2"], holdsRemembered: false, answered: true),
            .init(digests: [], holdsRemembered: true, answered: true),
            .init(),
        ] {
            XCTAssertEqual(
                ForeignStreamWatch.loss(remembered: remembered, found: found),
                ForeignStreamWatch.outcome(
                    remembered: remembered, found: found).loss)
        }
    }

    /// **The escape.** A stream this Mac remembers and cannot find refuses
    /// every marking verb — rightly, while it might come back, and for ever
    /// once it cannot. Once the writer has been shown the loss and put it
    /// down, it stops being expected and the sweeps answer.
    func test_anAcknowledgedLossStopsBeingExpected() async throws {
        try writeRootRecord()
        try admitSam()
        let url = try writeFile(
            by: sam.author,
            ops: ["01", "02", "03"].map { op($0, by: sam.author) })
        _ = try await load()
        try truncate(url, toFirst: 1)
        _ = try await load()
        XCTAssertEqual(truncations().count, 1)

        let table = try await reader().trust()
        let ids = Set(sam.all.map(\.deviceId))
        func sweep() throws -> PermitMark {
            try OpLogStore.seenPositions(
                ofDeviceIds: ids, in: projectURL, trust: table,
                expecting: rootState.expectedStreams(
                    inRoot: projectURL, writtenBy: [samSlug]))
        }
        XCTAssertThrowsError(try sweep(), "unacknowledged, it refuses as it did")

        rootState.acknowledgeLoss(samStreamKey, inRoot: projectURL)

        XCTAssertNoThrow(try sweep())
        XCTAssertTrue(
            rootState.expectedStreams(
                inRoot: projectURL, writtenBy: [samSlug]).isEmpty,
            "the escape is the EXPECTATION, and it is one function")
        XCTAssertFalse(
            rootState.foreignStreams(
                inRoot: projectURL, writtenBy: [samSlug]).isEmpty,
            "the memory itself is untouched — the stream is still watched")
    }

    /// **The loss is still a fact, and still drawn**, carrying that it has
    /// been put down. A drawer that dropped an acknowledged row would take the
    /// explanation away in the same press that changed what the book waits
    /// for.
    func test_anAcknowledgedLossIsStillDrawnAndSaysSo() async throws {
        try writeRootRecord()
        try admitSam()
        let url = try writeFile(
            by: sam.author, ops: ["01", "02"].map { op($0, by: sam.author) })
        _ = try await load()
        try truncate(url, toFirst: 1)
        _ = try await load()

        let table = try await reader().trust()
        var drawn = OpLogStore.lostHistory(
            in: projectURL, state: rootState, trust: table)
        XCTAssertEqual(drawn.map(\.streamKey), [samStreamKey])
        XCTAssertEqual(drawn.first?.label, "Sam")
        XCTAssertEqual(drawn.first?.what, .line)
        XCTAssertEqual(drawn.first?.acknowledged, false)
        XCTAssertNotNil(drawn.first?.noticedAt)

        rootState.acknowledgeLoss(samStreamKey, inRoot: projectURL)
        drawn = OpLogStore.lostHistory(
            in: projectURL, state: rootState, trust: table)
        XCTAssertEqual(drawn.map(\.streamKey), [samStreamKey])
        XCTAssertEqual(drawn.first?.acknowledged, true)
    }

    /// **A stream with no file at all is lost history too** — and it is the
    /// case a LOAD says nothing about (`settle`: a missing stream is not a
    /// truncated one), which is exactly the case a marking verb refuses over.
    /// Without this the refusal's *History shows what this book is missing*
    /// points at an empty drawer.
    func test_aStreamWithNoFileAtAllIsDrawnAndCanBeAcknowledged() async throws {
        try writeRootRecord()
        try admitSam()
        let url = try writeFile(by: sam.author, ops: [op("01", by: sam.author)])
        _ = try await load()
        XCTAssertNotNil(rootState.foreignStream(samStreamKey, inRoot: projectURL))

        try FileManager.default.removeItem(at: url)
        _ = try await load()
        XCTAssertTrue(
            truncations().isEmpty,
            "a load records nothing about a stream whose every file is gone")

        let table = try await reader().trust()
        let drawn = OpLogStore.lostHistory(
            in: projectURL, state: rootState, trust: table)
        XCTAssertEqual(drawn.map(\.streamKey), [samStreamKey])
        XCTAssertEqual(drawn.first?.what, .absent)
        XCTAssertNil(drawn.first?.noticedAt, "no load ever dated it")
        XCTAssertTrue(drawn.first?.sentence.contains("Sam") ?? false)

        let ids = Set(sam.all.map(\.deviceId))
        XCTAssertThrowsError(
            try OpLogStore.seenPositions(
                ofDeviceIds: ids, in: projectURL, trust: table,
                expecting: rootState.expectedStreams(
                    inRoot: projectURL, writtenBy: [samSlug])))

        rootState.acknowledgeLoss(samStreamKey, inRoot: projectURL)
        XCTAssertNoThrow(
            try OpLogStore.seenPositions(
                ofDeviceIds: ids, in: projectURL, trust: table,
                expecting: rootState.expectedStreams(
                    inRoot: projectURL, writtenBy: [samSlug])))

        // And it is STILL drawn: the drawer reads the memory itself, never
        // the sweeps' expectation, or the row explaining why this book no
        // longer waits for that stream would vanish in the same press.
        let after = OpLogStore.lostHistory(
            in: projectURL, state: rootState, trust: table)
        XCTAssertEqual(after.map(\.streamKey), [samStreamKey])
        XCTAssertEqual(after.first?.acknowledged, true)
    }

    /// A healthy book draws nothing: the drawer is a list of what is missing,
    /// and a folder where everything remembered is present has nothing in it.
    func test_aBookThatIsMissingNothingDrawsNothing() async throws {
        try writeRootRecord()
        try admitSam()
        try writeFile(by: sam.author, ops: [op("01", by: sam.author)])
        _ = try await load()

        let table = try await reader().trust()
        XCTAssertTrue(OpLogStore.lostHistory(
            in: projectURL, state: rootState, trust: table).isEmpty)
    }

    /// **The acknowledgement goes with the bytes it was about.** What came
    /// back is expected again, and what goes missing NEXT is a new fact that
    /// the old press does not excuse.
    func test_whatComesBackIsExpectedAgainAndANewLossIsNotCovered() async throws {
        try writeRootRecord()
        try admitSam()
        let url = try writeFile(
            by: sam.author,
            ops: ["01", "02", "03"].map { op($0, by: sam.author) })
        _ = try await load()
        let whole = try Data(contentsOf: url)

        try truncate(url, toFirst: 1)
        _ = try await load()
        rootState.acknowledgeLoss(samStreamKey, inRoot: projectURL)
        XCTAssertFalse(rootState.acknowledgedLosses(inRoot: projectURL).isEmpty)

        // The file comes back whole.
        try whole.write(to: url, options: .atomic)
        _ = try await load()
        XCTAssertTrue(truncations().isEmpty)
        XCTAssertTrue(
            rootState.acknowledgedLosses(inRoot: projectURL).isEmpty,
            "nothing is missing, so there is nothing put down")
        XCTAssertFalse(
            rootState.expectedStreams(
                inRoot: projectURL, writtenBy: [samSlug]).isEmpty,
            "and the stream is expected again")

        // And it is cut back a second time, differently.
        try truncate(url, toFirst: 2)
        _ = try await load()
        XCTAssertEqual(truncations().count, 1)
        XCTAssertTrue(
            rootState.acknowledgedLosses(inRoot: projectURL).isEmpty,
            "a second loss is a second fact")
        let table = try await reader().trust()
        XCTAssertThrowsError(
            try OpLogStore.seenPositions(
                ofDeviceIds: Set(sam.all.map(\.deviceId)), in: projectURL,
                trust: table,
                expecting: rootState.expectedStreams(
                    inRoot: projectURL, writtenBy: [samSlug])))
    }

    /// **A stream that goes on getting shorter is ONE standing fact**, and the
    /// writer's acknowledgement of it stands with it.
    ///
    /// Measured rather than assumed: while a loss stands, the memory does not
    /// move on (`settle` keeps the position whose absence IS the finding), so
    /// a second cut reports the same lost line, on the same day, as the same
    /// row. There is nothing new for the writer to be shown, so re-asking
    /// would be asking twice about one thing — and the book would wait again
    /// for a stream they have already said is gone.
    ///
    /// The clear-on-a-different-loss clause in `settleForeign` is therefore
    /// defensive here rather than exercised: it is reachable only through the
    /// path the test above takes, where the bytes come back and go again, and
    /// that path clears the acknowledgement on the way past.
    func test_aStreamThatKeepsShrinkingIsOneStandingFactAlreadyPutDown() async throws {
        try writeRootRecord()
        try admitSam()
        let url = try writeFile(
            by: sam.author,
            ops: ["01", "02", "03", "04"].map { op($0, by: sam.author) })
        _ = try await load()

        try truncate(url, toFirst: 3)
        _ = try await load()
        let first = try XCTUnwrap(truncations().first)
        rootState.acknowledgeLoss(samStreamKey, inRoot: projectURL)

        try truncate(url, toFirst: 1)
        _ = try await load()

        XCTAssertEqual(truncations().count, 1)
        XCTAssertEqual(truncations().first?.lost, first.lost,
                       "the memory froze at the position whose absence is the finding")
        XCTAssertEqual(truncations().first?.noticedAt, first.noticedAt)
        XCTAssertFalse(
            rootState.acknowledgedLosses(inRoot: projectURL).isEmpty,
            "the same fact, already put down")
    }

    /// **A stream that comes back ROTATED is expected again** (fix round 1,
    /// Minor 3).
    ///
    /// The clearing rule used to have two clauses — a DIFFERENT truncation, or
    /// `clearsTruncation` — and neither sees this shape: a rotated return
    /// answers `loss` nil (the rotation tolerance) while `clearsTruncation` is
    /// false, because the tail does not hold the remembered line. The memory
    /// moved on and the acknowledgement survived it, so the sweeps went on
    /// excusing a stream that was whole.
    func test_aRotatedReturnClearsTheAcknowledgementAndIsExpectedAgain() async throws {
        try writeRootRecord()
        try admitSam()
        let url = try writeFile(
            by: sam.author,
            ops: ["01", "02", "03"].map { op($0, by: sam.author) })
        _ = try await load()
        try truncate(url, toFirst: 1)
        _ = try await load()
        XCTAssertEqual(truncations().count, 1)
        rootState.acknowledgeLoss(samStreamKey, inRoot: projectURL)
        XCTAssertTrue(
            rootState.expectedStreams(
                inRoot: projectURL, writtenBy: [samSlug]).isEmpty,
            "the premise: the sweeps are excusing this stream")

        // Sam's Mac writes on and rotates: the stream takes in a segment this
        // Mac has never seen, and the tail that remains holds no line it
        // remembers. Nothing was lost — that is the rotation tolerance — but
        // `clearsTruncation` cannot say so.
        try writeFile(
            by: sam.author, ops: ["04", "05"].map { op($0, by: sam.author) })
        _ = try await samsStore().sealTailIfNeeded(
            docId: docId, deviceSlug: sam.author.slug, threshold: 1)
        try writeFile(by: sam.author, ops: [op("06", by: sam.author)])
        _ = try await load()

        XCTAssertTrue(
            rootState.acknowledgedLosses(inRoot: projectURL).isEmpty,
            "a stream that answered and lost nothing is expected again")
        XCTAssertFalse(
            rootState.expectedStreams(
                inRoot: projectURL, writtenBy: [samSlug]).isEmpty)
    }

    /// **The converse, at the door itself**: an update that carries a memory
    /// AND a standing truncation keeps the acknowledgement. The condition is
    /// *answered and nothing lost*, never *answered*.
    ///
    /// `ForeignStreamWatch.settle` never writes both together — a memory is
    /// written only where the loss is nil — so this is asserted of
    /// `settleForeign` directly, which is the shape a second caller could
    /// produce.
    func test_aMemoryWrittenBesideAStandingLossKeepsTheAcknowledgement() throws {
        let memory = OpLogDeviceState.ForeignStreamMemory(
            deviceSlug: samSlug, head: "aaaa", segmentDigests: [])
        rootState.settleForeign([.init(
            streamKey: samStreamKey, root: projectURL,
            memory: memory,
            truncation: .init(
                streamKey: samStreamKey, deviceSlug: samSlug,
                lost: "aaaa", noticedAt: Date(timeIntervalSince1970: 1)))])
        rootState.acknowledgeLoss(samStreamKey, inRoot: projectURL)

        rootState.settleForeign([.init(
            streamKey: samStreamKey, root: projectURL,
            memory: memory,
            truncation: .init(
                streamKey: samStreamKey, deviceSlug: samSlug,
                lost: "aaaa", noticedAt: Date(timeIntervalSince1970: 2)))])

        XCTAssertFalse(
            rootState.acknowledgedLosses(inRoot: projectURL).isEmpty,
            "the loss still stands, so what the writer put down still stands")
    }

    // MARK: - What the rows say (fix round 1, Important 1)

    /// **An absent stream is not asserted to be gone.** `settle`'s own rule is
    /// that a stream with no file is MISSING rather than truncated — iCloud
    /// has moved it, or a sync is halfway through — and the row carries a
    /// control, so a writer told their collaborator's history is gone can
    /// press Acknowledge over a stream that was only ever mid-sync.
    func test_theAbsentRowSaysWhatIsKnownAndTheTruncationRowIsUnchanged() async throws {
        try writeRootRecord()
        try admitSam()
        let url = try writeFile(by: sam.author, ops: [op("01", by: sam.author)])
        _ = try await load()
        try FileManager.default.removeItem(at: url)
        _ = try await load()
        let table = try await reader().trust()

        let absent = try XCTUnwrap(OpLogStore.lostHistory(
            in: projectURL, state: rootState, trust: table).first)
        XCTAssertEqual(absent.what, .absent)
        XCTAssertTrue(absent.sentence.contains("can\u{2019}t find"), absent.sentence)
        XCTAssertTrue(absent.sentence.contains("may still be syncing"), absent.sentence)
        XCTAssertFalse(
            absent.sentence.contains("gone from the folder"),
            "what this Mac cannot know is not stated as a fact: \(absent.sentence)")
        XCTAssertFalse(
            absent.sentence.contains("not in this book any more"), absent.sentence)

        // A witnessed truncation keeps its wording, because that one WAS seen:
        // this Mac held the remembered line and the bytes that no longer carry
        // it, in one reading.
        let shortened = OpLogStore.LostHistory(
            streamKey: samStreamKey, deviceSlug: samSlug, label: "Sam",
            what: .line, noticedAt: Date(timeIntervalSince1970: 1),
            acknowledged: false)
        XCTAssertTrue(
            shortened.sentence.contains("history here is shorter than it was"),
            shortened.sentence)
        XCTAssertTrue(
            shortened.sentence.contains("what is gone is gone from the folder"),
            shortened.sentence)
    }

    /// The cost of acknowledging is ONE sentence, and the row after the press
    /// carries it — the control before the press carries the same one
    /// (`HistoryPane.acknowledgeLostHelp`, pinned on the Mac side).
    func test_theCostOfAcknowledgingIsOneSentence() {
        XCTAssertTrue(
            OpLogStore.LostHistory.acknowledgedSentence.hasSuffix(
                OpLogStore.LostHistory.costOfAcknowledging),
            OpLogStore.LostHistory.acknowledgedSentence)
        XCTAssertTrue(
            OpLogStore.LostHistory.costOfAcknowledging.contains(
                "judged as written after that change"),
            OpLogStore.LostHistory.costOfAcknowledging)
    }

    /// **The acknowledgement never enters a mark.** Two Macs reading the same
    /// bytes, one of which has been told, compute the same positions for every
    /// stream both can read — a mark is derived from the shared bytes alone,
    /// or a fresh Mac and the root cut the same file in two places.
    func test_anAcknowledgementChangesNoPosition() async throws {
        try writeRootRecord()
        try admitSam()
        let url = try writeFile(
            by: sam.author,
            ops: ["01", "02", "03"].map { op($0, by: sam.author) })
        _ = try await load()
        try truncate(url, toFirst: 2)
        _ = try await load()

        let table = try await reader().trust()
        let ids = Set(sam.all.map(\.deviceId))
        // The other Mac: no memory at all, so nothing to expect and nothing
        // to acknowledge.
        let fresh = state("fresh")
        let theirs = try OpLogStore.seenPositions(
            ofDeviceIds: ids, in: projectURL, trust: table,
            expecting: fresh.expectedStreams(
                inRoot: projectURL, writtenBy: [samSlug]))

        rootState.acknowledgeLoss(samStreamKey, inRoot: projectURL)
        let mine = try OpLogStore.seenPositions(
            ofDeviceIds: ids, in: projectURL, trust: table,
            expecting: rootState.expectedStreams(
                inRoot: projectURL, writtenBy: [samSlug]))

        XCTAssertEqual(mine, theirs, "the same bytes, the same mark")
    }

    /// Pruned with its book, like the memory and the finding beside it.
    func test_pruneDropsAGoneProjectsAcknowledgements() throws {
        let parent = TestTemp.root
            .appendingPathComponent("ack-prune-\(UUID().uuidString)")
        let gone = parent.appendingPathComponent("book")
        try FileManager.default.createDirectory(
            at: gone, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let url = projectURL.appendingPathComponent("ack-state.json")
        let identity = DeviceIdentity.softwareForTesting()
        let memory = OpLogDeviceState(fileURL: url, identity: identity.fingerprint)
        memory.acknowledgeLoss("doc-x.sam", inRoot: gone)
        XCTAssertEqual(memory.acknowledgedLosses(inRoot: gone).count, 1)

        try FileManager.default.removeItem(at: gone)
        let reopened = OpLogDeviceState(fileURL: url, identity: identity.fingerprint)
        XCTAssertTrue(reopened.acknowledgedLosses(inRoot: gone).isEmpty)
    }

    /// A state file written before this field decodes and answers *nobody has
    /// put anything down*, which is the truth about every book that has never
    /// lost a stream.
    func test_aStateFileWrittenBeforeAcknowledgementsDecodes() throws {
        let url = projectURL.appendingPathComponent("pre-ack-state.json")
        let identity = DeviceIdentity.softwareForTesting()
        let legacy: [String: Any] = [
            "identity": identity.fingerprint,
            "heads": [:],
            "previousHeads": [:],
            "verifiedSegments": [String](),
            "roots": [:],
        ]
        try JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys])
            .write(to: url, options: .atomic)

        let loaded = OpLogDeviceState(fileURL: url, identity: identity.fingerprint)
        XCTAssertTrue(loaded.acknowledgedLosses(inRoot: projectURL).isEmpty)
    }

    // MARK: - The finding, as P3b will read it

    /// The door names the device the way every other finding names one, and
    /// answers the stream's own slug where there is no table to ask.
    func test_theFindingNamesTheDevice() async throws {
        try writeRootRecord()
        try admitSam()
        let url = try writeFile(
            by: sam.author, ops: ["01", "02"].map { op($0, by: sam.author) })
        _ = try await load()
        try truncate(url, toFirst: 1)
        _ = try await load()

        let named = OpLogStore.truncatedStreams(
            in: projectURL, state: rootState, trust: try await reader().trust())
        XCTAssertEqual(named.map(\.label), ["Sam"])
        XCTAssertEqual(named.map(\.streamKey), [samStreamKey])

        let keyless = OpLogStore.truncatedStreams(in: projectURL, state: rootState)
        XCTAssertEqual(
            keyless.map(\.label), [samSlug],
            "with no table to ask, the stream still names itself")
    }

    /// And the integrity channel carries it — a finding, never a refusal: it
    /// makes the report unhealthy and does NOT block a backup, because the
    /// surviving words are exactly what a backup is for.
    func test_theIntegrityReportCarriesItAndDoesNotBlockABackup() async throws {
        try writeRootRecord()
        try admitSam()
        let url = try writeFile(
            by: sam.author, ops: ["01", "02"].map { op($0, by: sam.author) })
        _ = try await load()
        try truncate(url, toFirst: 1)
        _ = try await load()

        let report = try await ProjectIntegrity.check(
            projectURL: projectURL, state: rootState)
        XCTAssertEqual(report.truncatedStreams.map(\.streamKey), [samStreamKey])
        XCTAssertFalse(report.isHealthy)
        XCTAssertFalse(report.blocksBackup)

        let keyless = try await ProjectIntegrity.check(projectURL: projectURL)
        XCTAssertTrue(
            keyless.truncatedStreams.isEmpty,
            "a check with no memory to read honestly knows of none")
    }
}
