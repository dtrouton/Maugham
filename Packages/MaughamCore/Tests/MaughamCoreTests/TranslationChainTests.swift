import XCTest
@testable import MaughamCore

/// A translation line is a line of history like any other.
///
/// Until P1b the translation sidecar was the one append-only stream on the
/// device that nothing vouched for: `appendBatch` serialized the records and
/// wrote them straight through `NSFileCoordinator`, with no `prev`, no seal and
/// no walk on the way back in. Anything with write access to the project could
/// put a paragraph of Spanish into the writer's book and no read would notice.
///
/// Now the batch is N chained lines and one seal, and *who wrote it* is the key
/// it is signed with — the `translator` for the pipeline and
/// `write_translation`, the `author` for the writer's own edits in the
/// Translation Review pane.
@MainActor
final class TranslationChainTests: XCTestCase {

    private let docId = "doc-chain"
    private var projectURL: URL!
    private var mine: LocalIdentities!
    private var myState: OpLogDeviceState!

    override func setUp() async throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("trchain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".maugham"),
            withIntermediateDirectories: true)
        mine = .softwareForTesting()
        myState = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("my-state.json"),
            identity: mine.author.fingerprint)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - Fixture

    private func record(_ paragraphId: String, _ text: String?) -> TranslationRecord {
        TranslationRecord(paragraphId: paragraphId, language: "es",
                          text: text, sourceHash: "h")
    }

    /// A record encoded exactly as the store encodes one — the ISO8601 date
    /// strategy included. A bare `JSONEncoder` writes `at` as a number, which
    /// the reader's decoder rejects, so a fixture built with one would be
    /// dropped by the PARSER and prove nothing about the walk.
    private func encoded(_ record: TranslationRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = JSONLAppendStore<TranslationRecord>.dateEncoding
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(record)
    }

    private func write(_ records: [TranslationRecord], as identity: DeviceIdentity,
                       trusting identities: LocalIdentities? = nil,
                       state: OpLogDeviceState? = nil) async throws {
        try await TranslationStore.appendBatch(
            records, forDocId: docId, language: "es",
            identity: identity, identities: identities ?? mine,
            state: state ?? myState, in: projectURL)
    }

    private func fileURL(of identity: DeviceIdentity) -> URL {
        TranslationStore.fileURL(forDocId: docId, language: "es",
                                 deviceSlug: identity.slug, in: projectURL)
    }

    private func bytes(of identity: DeviceIdentity) throws -> Data {
        try Data(contentsOf: fileURL(of: identity))
    }

    private func lines(of identity: DeviceIdentity) throws -> [Data] {
        try bytes(of: identity)
            .split(separator: 0x0A, omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
            .map { Data($0) }
    }

    /// The walk this device performs on its own next read.
    private func walk(_ identity: DeviceIdentity,
                      trusting identities: LocalIdentities? = nil) throws
    -> OpLogChain.Verification {
        let url = fileURL(of: identity)
        let trusted = (identities ?? mine).fingerprints
        return OpLogChain.verify(
            bytes: try bytes(of: identity),
            trusted: { trusted.contains($0) },
            rememberedHead: myState.head(for: OpLogDeviceState.fileKey(url)))
    }

    private func merged() -> [TranslationRecord] {
        TranslationStore.loadMerged(forDocId: docId, language: "es", in: projectURL,
                                    identities: mine, state: myState)
    }

    // MARK: - (a) A batch is N chained lines and one seal

    /// The batch is the unit `write_translation` means, so it is one coordinated
    /// write — but each line inside it names the one before it. Chaining every
    /// line onto the *same* head would leave every line after the first with a
    /// `prev` that is not the running head, which is `prevMismatch`: the batch
    /// would quarantine itself on the next read.
    func test_aBatchIsNChainedLinesAndOneSeal() async throws {
        try await write((0..<3).map { record("aaa\($0)", "t\($0)") }, as: mine.translator)

        let all = try lines(of: mine.translator)
        XCTAssertEqual(all.filter { !OpLogChain.isSealLine($0) }.count, 3,
                       "three records, three lines")
        XCTAssertEqual(all.filter { OpLogChain.isSealLine($0) }.count, 1,
                       "one batch, one seal — a seal per record would spend "
                       + "three enclave signatures to say one thing")

        let verification = try walk(mine.translator)
        XCTAssertNil(verification.breakReason,
                     "every line in the batch chains onto the one before it")
        XCTAssertEqual(verification.legacyCount, 0,
                       "nothing in a batch this device wrote is unchained")
    }

    /// The seal over a translation batch is signed by the actor that WROTE it.
    /// The role is in the key, so a line the pipeline filed cannot later be
    /// mistaken for one the writer typed.
    func test_theSealNamesTheWritingActorsKey() async throws {
        try await write([record("aaaa", "Hola")], as: mine.translator)
        let translatorSeal = try lines(of: mine.translator).compactMap(OpLogChain.Seal.parse)
        XCTAssertEqual(translatorSeal.count, 1)
        XCTAssertEqual(translatorSeal.first?.key, mine.translator.fingerprint)
        XCTAssertNotEqual(translatorSeal.first?.key, mine.author.fingerprint,
                          "a translation is not signed with the writer's key")

        try await write([record("bbbb", nil)], as: mine.author)
        let authorSeal = try lines(of: mine.author).compactMap(OpLogChain.Seal.parse)
        XCTAssertEqual(authorSeal.first?.key, mine.author.fingerprint)
    }

    /// A second batch chains onto the first batch's seal rather than starting
    /// over, so the file is one chain from its first line to its last.
    func test_aSecondBatchChainsOntoTheFirstBatchesSeal() async throws {
        try await write([record("aaaa", "uno")], as: mine.translator)
        try await write([record("bbbb", "dos"), record("cccc", "tres")], as: mine.translator)

        let verification = try walk(mine.translator)
        XCTAssertNil(verification.breakReason)
        XCTAssertEqual(try lines(of: mine.translator).filter(OpLogChain.isSealLine).count, 2)
        XCTAssertEqual(merged().count, 3)
    }

    // MARK: - (b) The whole device is trusted, not just the signer

    /// **The trust set is all four actors.** The author's load of the file the
    /// TRANSLATOR wrote and sealed must read as this device's own word. A
    /// policy trusting only its signer would classify the translator's seal as
    /// a stranger's — `unsignedHistory`, counted in the History pane as
    /// "changes from another device", for work this very Mac did.
    func test_theAuthorsLoadOfTheTranslatorsFileVerifiesEveryLine() async throws {
        try await write([record("aaaa", "Hola"), record("bbbb", "Adiós")],
                        as: mine.translator)

        let verification = try walk(mine.translator)
        XCTAssertEqual(verification.foreignSealCount, 0,
                       "the translator's key is this device's key")
        XCTAssertEqual(verification.verifiedCount, verification.lines.count,
                       "every line — records and seal — is verified. States: "
                       + verification.lines.map { "\($0.state)" }.joined(separator: ", "))
        XCTAssertEqual(verification.unsealedCount, 0)
        XCTAssertTrue(verification.quarantined.isEmpty)
    }

    /// The converse, and the reason the assertion above is worth making: read
    /// under the author's fingerprint ALONE — the `ChainPolicy` default — the
    /// same file is unsigned history.
    func test_underTheSignerAloneTheSameFileReadsAsAnotherDevices() async throws {
        try await write([record("aaaa", "Hola")], as: mine.translator)

        let url = fileURL(of: mine.translator)
        let narrow = OpLogChain.verify(
            bytes: try bytes(of: mine.translator),
            trusted: { $0 == self.mine.author.fingerprint },
            rememberedHead: myState.head(for: OpLogDeviceState.fileKey(url)))
        XCTAssertEqual(narrow.foreignSealCount, 1)
        XCTAssertEqual(narrow.verifiedCount, 0,
                       "this is what the one-fingerprint default costs")
    }

    // MARK: - (c) The writer's own edit is the author's, and it wins

    /// The pipeline translates into the TRANSLATOR's file; the writer's own
    /// purge in the Translation Review pane lands in the AUTHOR's. Two files,
    /// two keys, one merged answer.
    ///
    /// The merge rule is pinned rather than assumed: `latestByParagraph` walks
    /// records in ascending `opId` and lets the last one stand (a tombstone
    /// removing the key). `ULID.generate()` is process-monotonic, so the edit
    /// made second carries the higher opId — asserted here, so this test fails
    /// loudly rather than passing by luck if that ever stops being true.
    func test_theWritersOwnEditLandsInTheAuthorsFileAndWinsTheMerge() async throws {
        let translated = record("aaaa", "Hola")
        try await write([translated], as: mine.translator)

        let writersOwn = record("aaaa", "Hola de nuevo")
        try await write([writersOwn], as: mine.author)

        XCTAssertGreaterThan(writersOwn.opId, translated.opId,
                             "the merge rule is last-opId-wins, so the second "
                             + "write must carry the higher opId")

        // Two files, each holding only its own actor's line.
        XCTAssertEqual(try lines(of: mine.translator)
            .filter { !OpLogChain.isSealLine($0) }.count, 1)
        XCTAssertEqual(try lines(of: mine.author)
            .filter { !OpLogChain.isSealLine($0) }.count, 1)
        XCTAssertFalse(
            String(data: try bytes(of: mine.translator), encoding: .utf8)!
                .contains("Hola de nuevo"),
            "the writer's edit is not written into the pipeline's file")

        // And one merged answer: the writer's.
        let all = merged()
        XCTAssertEqual(all.count, 2, "both lines survive the merge")
        XCTAssertEqual(TranslationStore.latestByParagraph(all)["aaaa"]?.text,
                       "Hola de nuevo")
    }

    /// The same shape with a tombstone, which is what the orphan purge actually
    /// writes: the author's removal outranks the translator's paragraph.
    func test_theWritersPurgeRemovesTheTranslatorsParagraph() async throws {
        try await write([record("aaaa", "Hola")], as: mine.translator)
        try await write([record("aaaa", nil)], as: mine.author)

        XCTAssertTrue(TranslationStore.latestByParagraph(merged()).isEmpty)
    }

    // MARK: - (d) A stranger's file is history, not damage

    /// Another Mac's translation file carries a seal under a key this device
    /// does not hold. That is not a break — it is somebody else's history, and
    /// the writer's own merged read must still contain it. Quarantining it
    /// would silently drop a whole device's translations.
    func test_aStrangerSignedFileIsUnsignedHistoryAndStillMerges() async throws {
        let stranger = LocalIdentities.softwareForTesting()
        let strangerState = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("stranger-state.json"),
            identity: stranger.author.fingerprint)
        try await write([record("aaaa", "Hola")], as: stranger.translator,
                        trusting: stranger, state: strangerState)
        try await write([record("bbbb", "Adiós")], as: mine.translator)

        let theirWalk = try walk(stranger.translator)
        XCTAssertEqual(theirWalk.foreignSealCount, 1)
        XCTAssertTrue(theirWalk.quarantined.isEmpty,
                      "a foreign seal is history, never damage")

        XCTAssertEqual(Set(merged().map(\.paragraphId)), ["aaaa", "bbbb"])
    }

    /// **What the narrow trust set actually costs, on the read path.**
    ///
    /// `resolveAbsentHead`'s cut-short rule falls back to *the last thing this
    /// device signed* — `lastTrustedSealIndex`, which is a seal whose key the
    /// caller TRUSTS. Read with the author's fingerprint alone, the
    /// translator's own seals are a stranger's, there is no anchor to fall back
    /// to, and a file cut short and rewritten by something else applies whole.
    /// With all four actors trusted the forged line is held back.
    func test_aTranslatorFileCutShortIsAnchoredOnTheTranslatorsOwnSeal() async throws {
        try await write([record("aaaa", "Hola")], as: mine.translator)
        try await write([record("bbbb", "Adiós")], as: mine.translator)

        // Cut the file back to its first batch, then chain a line of somebody
        // else's onto that batch's seal: the head is now neither the head this
        // device remembers nor the one before it, which is the cut-short case.
        let url = fileURL(of: mine.translator)
        let kept = Array(try lines(of: mine.translator).prefix(2))
        var rebuilt = Data()
        for line in kept {
            rebuilt.append(line)
            rebuilt.append(0x0A)
        }
        let forged = OpLogChain.chainedLine(
            elementJSON: try encoded(record("zzzz", "no soy yo")),
            prev: OpLogChain.lineHash(kept[1]))
        rebuilt.append(forged)
        rebuilt.append(0x0A)
        try rebuilt.write(to: url, options: .atomic)

        XCTAssertEqual(merged().map(\.paragraphId), ["aaaa"],
                       "everything after the translator's last own seal is held "
                       + "back — which needs the translator's seal to be "
                       + "TRUSTED, not read as another device's")
    }

    // MARK: - (e) A break is set aside, under the manuscript's own docId

    /// Something appended a line of its own into the writer's translation file.
    /// The walk stops there, the read applies what came before it, and the held
    /// back bytes are filed where the writer can find them — under the
    /// MANUSCRIPT's docId, because the language is in the filename and a
    /// `.lines` record belongs beside the document History already shows.
    func test_aForeignLineIsHeldBackAndRecordedUnderTheManuscriptsDocId() async throws {
        try await write([record("aaaa", "Hola")], as: mine.translator)

        let url = fileURL(of: mine.translator)
        let intruder = try encoded(record("zzzz", "no soy yo"))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: intruder + Data([0x0A]))
        try handle.close()

        let all = merged()
        XCTAssertEqual(all.map(\.paragraphId), ["aaaa"],
                       "the line written after this device's head is not applied")

        let filed = OpLogQuarantine.records(forDocId: docId, in: projectURL)
        XCTAssertEqual(filed.count, 1,
                       "the held-back line is recorded under the MANUSCRIPT's "
                       + "docId, so it files beside the document History "
                       + "already shows")
        XCTAssertEqual(filed.first?.kind, .lines)
        XCTAssertEqual(filed.first?.originalName, url.lastPathComponent)
    }
}
