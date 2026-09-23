// MaughamTests/Stores/LostHistoryTests.swift
import XCTest
@testable import MaughamCore
@testable import Maugham

/// **A loss the writer has been shown stops being expected** (signed op log
/// P3b Task 6, spec §4.7).
///
/// P3a gave every marking verb a memory to check itself against: a stream this
/// Mac has applied from and can no longer find refuses the act, rather than
/// producing a mark that draws the line at the beginning of that stream and
/// silently sets aside — or reaches back through — everything in it. That is
/// the right answer while the file might come back.
///
/// It is the wrong answer for ever. iCloud can lose a file; a collaborator can
/// delete a folder; a backup can be restored short. The memory then names a
/// stream nothing will ever produce again, and Revoke, Re-admit and *make Sam
/// a reviewer* refuse on that book for the rest of its life, naming a filename
/// the writer can do nothing about.
///
/// So the loss becomes a FACT the writer can be shown and put down. History
/// draws it; **Acknowledge** records — on this device, never in the book — that
/// they know that history is gone; and from then on the sweeps stop expecting
/// that stream. If the bytes come back, the finding and the acknowledgement
/// both clear and the stream is expected again.
///
/// This suite drives the real production verbs over a real project: the
/// refusal first (that is the bug), then the escape, then both directions of
/// it.
@MainActor
final class LostHistoryTests: XCTestCase {

    private var projectURL: URL!
    private var cache: RegistryCache!
    private var memory: AdmissionMemory!
    private var mine: LocalIdentities!
    private var sam: LocalIdentities!
    private var samState: OpLogDeviceState!
    /// A Mac that signs nothing — the unsigned door's own subject, and what
    /// makes the SNAPSHOT sweep (rather than a person's) refuse.
    private let ghost = DeviceSlug.unsafeForTesting("ghostmac")

    override func setUp() async throws {
        let (dir, _) = try makeTestProject(prefix: "LOST", initialMd: "Hello.\n")
        projectURL = dir
        sam = .softwareForTesting()
        samState = OpLogDeviceState(
            fileURL: dir.appendingPathComponent("sam-state.json"))
        cache = RegistryCache(
            fileURL: dir.appendingPathComponent("registry-cache.json"),
            identity: "test")
        memory = AdmissionMemory(
            fileURL: dir.appendingPathComponent("admission-memory.json"),
            identity: "test")
        Document.registryCacheForTesting = cache
        Document.admissionMemoryForTesting = memory
        mine = LocalIdentities.forTesting(author: .softwareForTesting())
        Document.localIdentitiesForTesting = mine
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: dir.appendingPathComponent("op-log-state.json"))
    }

    override func tearDown() async throws {
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        if let projectURL { try? FileManager.default.removeItem(at: projectURL) }
        projectURL = nil
    }

    // MARK: - Fixtures

    private var docURL: URL { projectURL.appendingPathComponent("manuscript/c1.md") }

    private var state: OpLogDeviceState { Document.loadDeviceState }

    /// Open the chapter once, which is what makes this Mac REMEMBER where every
    /// other device's stream stood. The whole mechanism hangs off a real load.
    @discardableResult
    private func openTheChapter() async throws -> String {
        let doc = try await Document.load(
            url: docURL, actor: .author, session: "s", presenter: nil)
        let docId = doc.docId
        await doc.close()
        return docId
    }

    /// Sam's own file: chained and sealed under her key, so the register can
    /// name it once she is admitted.
    @discardableResult
    private func writeSamsFile(docId: String, opIds: [String]) async throws -> URL {
        let store = OpLogStore(
            projectURL: projectURL, identity: sam.author, state: samState)
        for id in opIds {
            try await store.append(Op(
                opId: id, docId: docId, at: Date(timeIntervalSince1970: 0),
                device: sam.author.deviceId, session: "s", kind: .typingBurst,
                changes: [.init(paragraphId: "aaaa", prior: nil, next: id)],
                sequence: ["aaaa"]))
        }
        _ = try await store.sealChain(docId: docId)
        return OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: sam.author.slug, in: projectURL)
    }

    /// A stream that is CHAINED and that nothing seals — an enclave-less Mac's
    /// file, which no register can name a key for.
    @discardableResult
    private func writeGhostFile(docId: String, opIds: [String]) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        var bytes = Data()
        var head: String?
        for id in opIds {
            let element = try encoder.encode(Op(
                opId: id, docId: docId, at: Date(timeIntervalSince1970: 0),
                device: "ghost", session: "s", kind: .typingBurst,
                changes: [.init(paragraphId: "aaaa", prior: nil, next: id)],
                sequence: ["aaaa"]))
            let line = OpLogChain.chainedLine(
                elementJSON: element, prev: head ?? OpLogChain.genesis)
            bytes.append(line)
            bytes.append(0x0A)
            head = OpLogChain.lineHash(line)
        }
        let url = OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: ghost, in: projectURL)
        try bytes.write(to: url, options: .atomic)
        return url
    }

    private func admitSam(_ store: DocumentStore) async throws {
        _ = try await store.admit(
            device: sam.author.fingerprint, label: "Sam", ownName: "Sam’s Mac")
    }

    private func streamKey(of url: URL) throws -> String {
        try XCTUnwrap(PermitMark.streamKey(of: url))
    }

    private func refusedName(_ error: Error) -> String? {
        guard let error = error as? RegistryAdmissionError,
              case .historyUnreadable(let name, _) = error
        else { return nil }
        return name
    }

    // MARK: - The bug: a verb that refuses for ever

    /// **The reproduction.** This Mac reads Sam's file, the file goes away, and
    /// from then on every act that has to know how far this Mac had got with
    /// her refuses — for ever, with nothing the writer can do.
    func test_aStreamThatWentMissingRefusesTheActForEver() async throws {
        let store = try await DocumentStore.open(url: projectURL)
        let docId = try await openTheChapter()
        let hers = try await writeSamsFile(docId: docId, opIds: ["02"])
        try await admitSam(store)
        try await openTheChapter()
        let key = try streamKey(of: hers)
        XCTAssertNotNil(
            state.foreignStream(key, inRoot: projectURL),
            "this Mac has applied from her stream and remembers where it stood")

        try FileManager.default.removeItem(at: hers)

        for attempt in 1...2 {
            do {
                _ = try await store.changePermit(
                    person: sam.author.fingerprint, to: .reviewer)
                XCTFail("attempt \(attempt): a short mark must not be signed")
            } catch {
                XCTAssertEqual(refusedName(error), key)
            }
        }
    }

    // MARK: - The escape, both directions

    /// **An acknowledged loss stops being expected**, and the act goes through.
    func test_anAcknowledgedLossLetsTheActThrough() async throws {
        let store = try await DocumentStore.open(url: projectURL)
        let docId = try await openTheChapter()
        let hers = try await writeSamsFile(docId: docId, opIds: ["02"])
        try await admitSam(store)
        try await openTheChapter()
        let key = try streamKey(of: hers)
        try FileManager.default.removeItem(at: hers)
        // The load that meets the gap is what RECORDS it; the drawer draws
        // what that load found.
        try await openTheChapter()
        let standing = await store.lostHistory()
        XCTAssertEqual(standing.map(\.streamKey), [key])
        XCTAssertEqual(standing.first?.acknowledged, false)
        XCTAssertEqual(standing.first?.label, "Sam", "named the way the book names her")

        store.acknowledgeLostHistory(streamKey: key)

        let record = try await store.changePermit(
            person: sam.author.fingerprint, to: .reviewer)
        XCTAssertEqual(record.role, Permit.reviewerRole)
        let after = await store.lostHistory()
        XCTAssertEqual(
            after.first?.acknowledged, true,
            "the loss is still a fact — it is the EXPECTATION that was put down")
    }

    /// **And an UNacknowledged one refuses exactly as it did**, on the same
    /// folder, in the same test, so the two arms cannot drift apart.
    func test_anUnacknowledgedLossStillRefuses() async throws {
        let store = try await DocumentStore.open(url: projectURL)
        let docId = try await openTheChapter()
        let hers = try await writeSamsFile(docId: docId, opIds: ["02"])
        let other = LocalIdentities.softwareForTesting()
        let theirState = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("other-state.json"))
        let theirStore = OpLogStore(
            projectURL: projectURL, identity: other.author, state: theirState)
        try await theirStore.append(Op(
            opId: "03", docId: docId, at: Date(timeIntervalSince1970: 0),
            device: other.author.deviceId, session: "s", kind: .typingBurst,
            changes: [.init(paragraphId: "aaaa", prior: nil, next: "03")],
            sequence: ["aaaa"]))
        _ = try await theirStore.sealChain(docId: docId)
        let theirs = OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: other.author.slug, in: projectURL)
        try await admitSam(store)
        _ = try await store.admit(
            device: other.author.fingerprint, label: "Sam", ownName: "Sam’s phone")
        try await openTheChapter()

        try FileManager.default.removeItem(at: hers)
        try FileManager.default.removeItem(at: theirs)
        try await openTheChapter()

        // One of her two machines is acknowledged; the other is not.
        store.acknowledgeLostHistory(streamKey: try streamKey(of: hers))

        do {
            _ = try await store.changePermit(
                everyRecordOf: sam.author.fingerprint, to: .reviewer)
            XCTFail("a loss nobody has been shown still refuses")
        } catch {
            XCTAssertEqual(refusedName(error), try streamKey(of: theirs))
        }
    }

    /// **Bytes that come back are expected again**, and the acknowledgement
    /// goes with the finding it was about: putting down a loss must not make
    /// this Mac blind to the next one.
    func test_whatComesBackIsExpectedAgainAndTheAcknowledgementIsGone() async throws {
        let store = try await DocumentStore.open(url: projectURL)
        let docId = try await openTheChapter()
        let hers = try await writeSamsFile(docId: docId, opIds: ["02"])
        try await admitSam(store)
        try await openTheChapter()
        let key = try streamKey(of: hers)
        let whole = try Data(contentsOf: hers)

        try FileManager.default.removeItem(at: hers)
        try await openTheChapter()
        store.acknowledgeLostHistory(streamKey: key)
        let put = await store.lostHistory()
        XCTAssertEqual(put.first?.acknowledged, true)

        try whole.write(to: hers, options: .atomic)
        try await openTheChapter()

        let back = await store.lostHistory()
        XCTAssertTrue(
            back.isEmpty,
            "what came back is not missing, so there is no finding to acknowledge")
        XCTAssertNotNil(
            state.foreignStream(key, inRoot: projectURL),
            "and the stream is watched again")

        // It goes away a second time: the finding is new, and nothing about
        // the first one excuses it.
        try FileManager.default.removeItem(at: hers)
        try await openTheChapter()
        let again = await store.lostHistory()
        XCTAssertEqual(again.first?.acknowledged, false)
        do {
            _ = try await store.changePermit(
                person: sam.author.fingerprint, to: .reviewer)
            XCTFail("a second loss is a second fact")
        } catch {
            XCTAssertEqual(refusedName(error), key)
        }
    }

    // MARK: - T6×T1: the snapshot sweep takes the same escape

    /// **An acknowledged loss is out of the PHOTOGRAPH's expectation too**
    /// (T6×T1, ruled: one rule for every sweep).
    ///
    /// The unsigned snapshot's sweep expects every remembered stream no key can
    /// name — which is exactly the enclave-less Mac whose file is most likely
    /// to go missing and least likely to come back. Without this, one such
    /// stream stops the book from ever having a reviewer.
    ///
    /// *The stated cost*: history that returns AFTER a narrowing pressed over
    /// an acknowledged loss falls outside the photograph, so it is judged as
    /// written after that change. The confirmation says so before the press.
    func test_anAcknowledgedUnsignedStreamDoesNotRefuseTheNarrowing() async throws {
        let store = try await DocumentStore.open(url: projectURL)
        let docId = try await openTheChapter()
        try await writeSamsFile(docId: docId, opIds: ["02"])
        try await admitSam(store)
        let theirs = try writeGhostFile(docId: docId, opIds: ["04"])
        try await openTheChapter()
        let key = try streamKey(of: theirs)
        XCTAssertNotNil(state.foreignStream(key, inRoot: projectURL))

        try FileManager.default.removeItem(at: theirs)
        try await openTheChapter()

        do {
            _ = try await store.changePermit(
                person: sam.author.fingerprint, to: .reviewer)
            XCTFail("the photograph would have been short")
        } catch {
            XCTAssertEqual(refusedName(error), key)
        }

        store.acknowledgeLostHistory(streamKey: key)

        _ = try await store.changePermit(
            person: sam.author.fingerprint, to: .reviewer)
        XCTAssertEqual(
            try RegistryReader.load(projectURL: projectURL)
                .person(sam.author.fingerprint)?.role,
            Permit.reviewerRole)
    }

    // MARK: - The acknowledgement never enters a mark

    /// **Two Macs, one of them acknowledged, the same bytes ⇒ the same mark**
    /// for every stream both can read. An acknowledgement decides
    /// refuse-or-proceed and never a position's contents, or a fresh Mac and
    /// the root would cut the same file in two places.
    func test_anAcknowledgementNeverChangesAMark() async throws {
        let store = try await DocumentStore.open(url: projectURL)
        let docId = try await openTheChapter()
        let hers = try await writeSamsFile(docId: docId, opIds: ["02"])
        try await admitSam(store)
        try writeGhostFile(docId: docId, opIds: ["04"])
        try await openTheChapter()

        let table = try TrustResolution.resolveVerified(
            projectURL: projectURL, identities: mine, cache: cache).table
        let ids = Set(sam.all.map(\.deviceId))
        let before = try OpLogStore.seenPositions(
            ofDeviceIds: ids, in: projectURL, trust: table,
            expecting: DocumentStore.expectedStreams(
                ofDeviceIds: ids, in: projectURL, state: state))
        let photographBefore = try OpLogStore.unattributablePositions(
            in: projectURL, trust: table,
            expecting: DocumentStore.everyExpectedStream(
                in: projectURL, state: state))

        store.acknowledgeLostHistory(streamKey: try streamKey(of: hers))

        let after = try OpLogStore.seenPositions(
            ofDeviceIds: ids, in: projectURL, trust: table,
            expecting: DocumentStore.expectedStreams(
                ofDeviceIds: ids, in: projectURL, state: state))
        let photographAfter = try OpLogStore.unattributablePositions(
            in: projectURL, trust: table,
            expecting: DocumentStore.everyExpectedStream(
                in: projectURL, state: state))

        XCTAssertEqual(before, after, "the same bytes, the same positions")
        XCTAssertEqual(photographBefore, photographAfter)
    }

    // MARK: - Whose loss the confirmation is about (fix round 1, Minor 1)

    /// **A revocation is decided over ONE person's streams**, so the
    /// confirmation before it counts what was put down about THEM.
    ///
    /// The count was the book's, which over-states: a writer revoking Bob was
    /// told the act is being decided without history they had put down about
    /// Sam — history a revocation of Bob never reads
    /// (`expectedStreams(ofDeviceIds:)`). An over-statement on the screen
    /// before a destructive act is the kind a writer learns to skip.
    func test_theCountIsTheSubjectsForAnActThatSweepsOnePerson() async throws {
        let store = try await DocumentStore.open(url: projectURL)
        let docId = try await openTheChapter()
        let hers = try await writeSamsFile(docId: docId, opIds: ["02"])
        try await admitSam(store)
        // A second person, whose own stream this Mac has never lost.
        let bob = LocalIdentities.softwareForTesting()
        let bobState = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("bob-state.json"))
        let bobStore = OpLogStore(
            projectURL: projectURL, identity: bob.author, state: bobState)
        try await bobStore.append(Op(
            opId: "03", docId: docId, at: Date(timeIntervalSince1970: 0),
            device: bob.author.deviceId, session: "s", kind: .typingBurst,
            changes: [.init(paragraphId: "aaaa", prior: nil, next: "03")],
            sequence: ["aaaa"]))
        _ = try await bobStore.sealChain(docId: docId)
        _ = try await store.admit(
            device: bob.author.fingerprint, label: "Bob", ownName: "Bob\u{2019}s Mac")
        try await openTheChapter()

        try FileManager.default.removeItem(at: hers)
        try await openTheChapter()
        store.acknowledgeLostHistory(streamKey: try streamKey(of: hers))

        let counted = await store.acknowledgedLostHistory()
        XCTAssertEqual(counted.book, 1)
        XCTAssertEqual(counted.count(ofPerson: sam.author.fingerprint), 1,
                       "it was her machine")
        XCTAssertEqual(
            counted.count(ofPerson: bob.author.fingerprint), 0,
            "and revoking Bob is decided over nothing the writer put down")
    }

    /// The book that has put nothing down pays nothing to say so, and answers
    /// zero for everybody.
    func test_aBookWithNothingPutDownCountsNothing() async throws {
        let store = try await DocumentStore.open(url: projectURL)
        let docId = try await openTheChapter()
        try await writeSamsFile(docId: docId, opIds: ["02"])
        try await admitSam(store)
        try await openTheChapter()

        let counted = await store.acknowledgedLostHistory()
        XCTAssertEqual(counted.book, 0)
        XCTAssertEqual(counted.count(ofPerson: sam.author.fingerprint), 0)
    }
}
