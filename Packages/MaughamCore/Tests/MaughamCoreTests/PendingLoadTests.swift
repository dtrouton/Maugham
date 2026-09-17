import Foundation
import XCTest
@testable import MaughamCore

/// **Pending** — what a load does with a sealed span whose key this device's
/// chain says nothing about (spec §3).
///
/// The four states a foreign seal can be in, all four exercised end to end
/// through a real project directory, a real registry folder and the real
/// `OpLogStore` load:
///
/// | The registry says | The lines are | Applied? | Recorded? |
/// |---|---|---|---|
/// | nothing about this key, and there IS a chain | `pending` | no | no |
/// | that key is admitted | `verified` | yes | — |
/// | there is no chain here at all (B3) | `unsignedHistory` | yes | — |
/// | that key was admitted and revoked | `quarantined` | no | a `.lines` record |
///
/// The middle two are P1's behaviour, and the third is the arm every existing
/// suite in this package runs on: a project with no `.maugham/people` resolves
/// to `.noChain`, so nothing in P1 moved.
@MainActor
final class PendingLoadTests: XCTestCase {

    private let docId = "doc-pending"
    private var projectURL: URL!

    /// The root: this device, and the one that judges.
    private var root: LocalIdentities!
    private var rootState: OpLogDeviceState!
    /// A second device, unknown to the registry until a test says otherwise.
    /// Four actors, because one of the tests below is about a device that has
    /// written as two of them.
    private var strangerDevice: LocalIdentities!
    private var stranger: DeviceIdentity!
    private var strangerState: OpLogDeviceState!
    /// A third device in nobody's chain, used to read the same project.
    private var outsider: LocalIdentities!
    private var outsiderState: OpLogDeviceState!

    /// A registry memory of this suite's own, so nothing here reaches the
    /// process-wide cache beside the machine's real keys.
    private var cache: RegistryCache!

    override func setUp() async throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".maugham/ops"),
            withIntermediateDirectories: true)
        root = .softwareForTesting()
        strangerDevice = .softwareForTesting()
        stranger = strangerDevice.author
        outsider = .softwareForTesting()
        rootState = state("root")
        strangerState = state("stranger")
        outsiderState = state("outsider")
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

    private func op(_ opId: String, device: DeviceIdentity) -> Op {
        Op(opId: opId, docId: docId, at: Date(timeIntervalSince1970: 0),
           device: device.deviceId, session: "s", kind: .typingBurst,
           changes: [.init(paragraphId: "aaaa", prior: nil, next: opId)],
           sequence: ["aaaa"])
    }

    /// The root's own self-signed person record: this device admitted itself,
    /// which is what gives it a chain to judge by at all.
    private func writeRootRecord() throws {
        let record = PersonRecord(
            person: root.author.fingerprint, label: "Denver",
            ownName: "Denver's MacBook",
            admittedAt: Date(timeIntervalSince1970: 10),
            admittedBy: root.author.fingerprint)
        try RegistryWriter.write(record, signedBy: root.author, in: projectURL)
    }

    /// The root's word about the stranger — admitted, or admitted and revoked.
    private func writeStrangerRecord(
        revokedAt: Date? = nil, highestOpIdSeen: String? = nil
    ) throws {
        let record = PersonRecord(
            person: stranger.fingerprint, label: "Denver",
            ownName: "Denver's other Mac",
            admittedAt: Date(timeIntervalSince1970: 20),
            admittedBy: root.author.fingerprint,
            revokedAt: revokedAt,
            revokedBy: revokedAt == nil ? nil : root.author.fingerprint,
            highestOpIdSeen: highestOpIdSeen)
        try RegistryWriter.write(record, signedBy: root.author, in: projectURL)
    }

    /// The stranger's own device record, self-signed, optionally saying it has
    /// stopped writing.
    private func writeStrangerDeviceRecord(retiredAt: Date? = nil) throws {
        try RegistryWriter.write(
            DeviceRecord(
                device: stranger.fingerprint, name: "Denver's other Mac", kind: .mac,
                actors: [DeviceActor.author.rawValue: stranger.fingerprint],
                madeAt: Date(timeIntervalSince1970: 5), retiredAt: retiredAt),
            signedBy: stranger, in: projectURL)
    }

    /// `person` admitted under `rootIdentity`'s chain — self-signed when the
    /// two are the same key, which is what makes `rootIdentity` a root.
    private func admit(
        _ person: String, under rootIdentity: DeviceIdentity, at seconds: TimeInterval
    ) throws {
        try RegistryWriter.write(
            PersonRecord(
                person: person, label: "Denver", ownName: "A Mac",
                admittedAt: Date(timeIntervalSince1970: seconds),
                admittedBy: rootIdentity.fingerprint),
            signedBy: rootIdentity, in: projectURL)
    }

    /// The stranger's own per-device file: chained and sealed under its key.
    @discardableResult
    private func writeStrangerFile(_ opIds: [String]) async throws -> Int {
        let store = OpLogStore(
            projectURL: projectURL, identity: stranger, state: strangerState)
        for id in opIds { try await store.append(op(id, device: stranger)) }
        let sealed = try await store.sealChain(docId: docId)
        XCTAssertTrue(sealed, "the stranger's file is sealed")
        return opIds.count + 1   // the ops, plus the one seal line
    }

    /// This device's own file, chained and sealed under its author key.
    private func writeMyOwnFile(_ opIds: [String]) async throws {
        let store = reader()
        for id in opIds { try await store.append(op(id, device: root.author)) }
        let sealed = try await store.sealChain(docId: docId)
        XCTAssertTrue(sealed, "this device's own file is sealed")
    }

    private func reader() -> OpLogStore {
        OpLogStore(projectURL: projectURL, identities: root,
                   state: rootState, cache: cache)
    }

    private func linesRecords() -> [QuarantineRecord] {
        OpLogQuarantine.records(forDocId: docId, in: projectURL)
            .filter { $0.kind == .lines }
    }

    // MARK: - A stranger's span is HELD

    func test_aStrangersSealedSpanIsHeldRatherThanApplied() async throws {
        try writeRootRecord()
        try await writeMyOwnFile(["01"])
        let strangerLines = try await writeStrangerFile(["02", "03"])

        let load = try await reader().loadDiagnosed(docId: docId)

        XCTAssertEqual(load.ops.map(\.opId), ["01"],
                       "only this device's own op is applied")
        XCTAssertEqual(load.provenance.pendingLines, strangerLines,
                       "every line of the stranger's file is held")
        XCTAssertEqual(load.provenance.quarantinedLines, 0,
                       "held is not quarantined — nothing broke")
        XCTAssertEqual(load.provenance.unsignedHistoryLines, 0,
                       "there IS a chain here, so nothing falls back to B3")

        let strangersFile = load.provenance.files.first {
            $0.name.contains(stranger.slug.raw)
        }
        XCTAssertEqual(strangersFile?.pendingByDevice[stranger.fingerprint], 2,
                       """
                       held OPS are counted under the key that sealed them — \
                       two, not the three lines the file holds. The seal is \
                       held with the span it closes and is counted nowhere: \
                       every reader of this number puts a noun after it, and a \
                       seal is neither a capture nor a note (P2b Task 10).
                       """)
        XCTAssertEqual(strangersFile?.pending, strangerLines,
                       "while the LINE tally still counts the seal, because it "
                       + "is a line and it is held")
    }

    /// **N ops and M seals count N** (P2b Task 10, from Task 6's review).
    ///
    /// The count is read as a noun — *3 captures waiting*, *2 notes from this
    /// iPhone* — and a seal is neither. A two-op file with one seal read *3*
    /// under P2b's first draft, which is three surfaces telling the writer they
    /// have something they have not got.
    func test_heldSealsAreNotCountedAsThingsTheWriterIsWaitingFor() async throws {
        try writeRootRecord()
        // Three ops in one file, sealed twice: the seal after the first two,
        // and the seal after the third.
        let store = OpLogStore(
            projectURL: projectURL, identity: stranger, state: strangerState)
        try await store.append(op("02", device: stranger))
        try await store.append(op("03", device: stranger))
        var sealed = try await store.sealChain(docId: docId)
        XCTAssertTrue(sealed)
        try await store.append(op("04", device: stranger))
        sealed = try await store.sealChain(docId: docId)
        XCTAssertTrue(sealed)

        let load = try await reader().loadDiagnosed(docId: docId)

        XCTAssertEqual(load.provenance.pendingLines, 5,
                       "five lines are held: three ops and two seals")
        XCTAssertEqual(load.provenance.pendingByDevice,
                       [stranger.fingerprint: 3],
                       "and the writer is waiting on THREE of them")
    }

    func test_holdingALineRecordsNothingAnywhere() async throws {
        try writeRootRecord()
        try await writeStrangerFile(["02"])

        _ = try await reader().loadDiagnosed(docId: docId)

        XCTAssertTrue(linesRecords().isEmpty,
                      "a held line is not forensics — the writer admits the device or does not")
    }

    // MARK: - Admitting applies what was held

    func test_admittingTheStrangerAppliesEverythingItHeld() async throws {
        try writeRootRecord()
        try await writeMyOwnFile(["01"])
        try await writeStrangerFile(["02", "03"])

        let before = try await reader().loadDiagnosed(docId: docId)
        XCTAssertEqual(before.ops.map(\.opId), ["01"])

        try writeStrangerRecord()

        let after = try await reader().loadDiagnosed(docId: docId)
        XCTAssertEqual(after.ops.map(\.opId), ["01", "02", "03"],
                       "admission re-reads; nothing was rewritten to make it apply")
        XCTAssertEqual(after.provenance.pendingLines, 0)
        XCTAssertEqual(after.provenance.quarantinedLines, 0)
        XCTAssertEqual(after.provenance.unsignedHistoryLines, 0,
                       "an admitted device's word is verified, not history")
    }

    // MARK: - No chain at all (decision B3)

    func test_withNoChainOfItsOwnAReaderAppliesEveryonesLinesAsUnsignedHistory() async throws {
        try writeRootRecord()
        try await writeMyOwnFile(["01"])
        try await writeStrangerFile(["02", "03"])

        // A third device: not the root, not admitted, and with a memory of its
        // own that has never joined anything.
        let outsiderCache = RegistryCache(
            fileURL: projectURL.appendingPathComponent("outsider-cache.json"),
            identity: outsider.author.fingerprint)
        let load = try await OpLogStore(
            projectURL: projectURL, identities: outsider,
            state: outsiderState, cache: outsiderCache
        ).loadDiagnosed(docId: docId)

        XCTAssertEqual(load.ops.map(\.opId), ["01", "02", "03"],
                       "a device that judges nobody applies everything (B3)")
        XCTAssertEqual(load.provenance.pendingLines, 0,
                       "nothing is held by a reader with no chain")
        XCTAssertEqual(load.provenance.quarantinedLines, 0)
        XCTAssertGreaterThan(load.provenance.unsignedHistoryLines, 0)
        XCTAssertEqual(load.provenance.verifiedLines, 0,
                       "none of these keys is the outsider's own")
    }

    // MARK: - Revoked

    func test_aRevokedDevicesSpanIsQuarantinedInTheRevocationsOwnWords() async throws {
        try writeRootRecord()
        try await writeMyOwnFile(["01"])
        let strangerLines = try await writeStrangerFile(["02", "03"])
        try writeStrangerRecord(
            revokedAt: Date(timeIntervalSince1970: 30), highestOpIdSeen: "01")

        let load = try await reader().loadDiagnosed(docId: docId)

        XCTAssertEqual(load.ops.map(\.opId), ["01"],
                       "a revoked device's ops are refused, not held")
        XCTAssertEqual(load.provenance.quarantinedLines, strangerLines)
        XCTAssertEqual(load.provenance.pendingLines, 0,
                       "revocation is a fact about a key, never a silence about it")

        let record = linesRecords().first
        XCTAssertEqual(record?.reason, "written after this device's access was withdrawn")
    }

    /// **The split** (spec §5). A revoked device's span is refused whole, and
    /// the writer is owed which half is which: a line whose opId the root had
    /// already applied may be late sync or may be backdated, and a line above
    /// that mark was written after the door closed. Two records, two sentences,
    /// one refusal.
    func test_aRevokedSpanIsSplitByTheOpIdTheRootHadApplied() async throws {
        let first = "01K5Q8ZJ3M0000000000000001"
        let second = "01K5Q8ZJ3M0000000000000002"
        try writeRootRecord()
        try await writeMyOwnFile(["01K5Q8ZJ3M0000000000000000"])
        try await writeStrangerFile([first, second])
        try writeStrangerRecord(
            revokedAt: Date(timeIntervalSince1970: 30), highestOpIdSeen: first)

        let load = try await reader().loadDiagnosed(docId: docId)

        XCTAssertEqual(load.ops.map(\.opId), ["01K5Q8ZJ3M0000000000000000"],
                       "every line of a revoked key is refused, both sides of the line")
        XCTAssertEqual(load.provenance.quarantinedLines, 3)

        let reasons = Set(linesRecords().map(\.reason))
        XCTAssertEqual(reasons, [
            "written after this device's access was withdrawn",
            "may be late sync, or may be backdated",
        ], "\(linesRecords().map(\.reason))")
    }

    /// The mark is what makes the split; with no mark there is no *before*.
    func test_aRevocationWithNoMarkPutsEverythingAfterIt() async throws {
        try writeRootRecord()
        try await writeStrangerFile(["01K5Q8ZJ3M0000000000000001"])
        try writeStrangerRecord(
            revokedAt: Date(timeIntervalSince1970: 30), highestOpIdSeen: nil)

        _ = try await reader().loadDiagnosed(docId: docId)

        XCTAssertEqual(linesRecords().map(\.reason),
                       ["written after this device's access was withdrawn"])
    }

    /// Everything the stranger wrote is at or below the mark: one record, and
    /// it is the gentler sentence.
    func test_aRevokedSpanEntirelyBelowTheMarkIsOnlyEverLate() async throws {
        try writeRootRecord()
        try await writeStrangerFile(["01K5Q8ZJ3M0000000000000001"])
        try writeStrangerRecord(
            revokedAt: Date(timeIntervalSince1970: 30),
            highestOpIdSeen: "01K5Q8ZJ3M0000000000000009")

        _ = try await reader().loadDiagnosed(docId: docId)

        let reasons = linesRecords().map(\.reason)
        XCTAssertEqual(
            reasons.filter { $0 == "may be late sync, or may be backdated" }.count, 1)
        XCTAssertFalse(
            reasons.contains("written after this device's access was withdrawn"),
            "the seal line goes with the ops it sealed when none of them is late")
    }

    // MARK: - Retired

    /// **A retired device's future is set aside in its own words** (spec §5).
    /// Nothing it wrote before it stopped is touched; this file was sealed
    /// after, so the whole of it is refused — and the record says *retired*
    /// rather than *withdrawn*, because nobody withdrew anything.
    func test_aRetiredDevicesLaterSpanIsSetAsideAsAfterRetirement() async throws {
        try writeRootRecord()
        try await writeMyOwnFile(["01K5Q8ZJ3M0000000000000000"])
        try await writeStrangerFile(["01K5Q8ZJ3M0000000000000001"])
        try writeStrangerRecord()
        try writeStrangerDeviceRecord(retiredAt: Date(timeIntervalSince1970: 1))

        let load = try await reader().loadDiagnosed(docId: docId)

        XCTAssertEqual(load.ops.map(\.opId), ["01K5Q8ZJ3M0000000000000000"])
        XCTAssertGreaterThan(load.provenance.quarantinedLines, 0)
        XCTAssertEqual(linesRecords().map(\.reason),
                       ["written after this device was retired"])
    }

    /// And its past is its own: a device admitted, writing, and only then
    /// retiring keeps every line it sealed before the date.
    func test_aRetiredDevicesEarlierSpanStaysVerified() async throws {
        try writeRootRecord()
        try await writeStrangerFile(["01K5Q8ZJ3M0000000000000001"])
        try writeStrangerRecord()
        try writeStrangerDeviceRecord(
            retiredAt: Date(timeIntervalSince1970: 4_000_000_000))

        let load = try await reader().loadDiagnosed(docId: docId)

        XCTAssertEqual(load.ops.map(\.opId), ["01K5Q8ZJ3M0000000000000001"],
                       "sealed long before it retired")
        XCTAssertEqual(load.provenance.quarantinedLines, 0)
        XCTAssertTrue(linesRecords().isEmpty)
    }

    // MARK: - Held lines are counted per DEVICE

    /// A device holds four actor keys. A phone that has written as both its
    /// author and its assistant is ONE device waiting for admission, and a
    /// count keyed on the seal's key would say two.
    func test_twoActorKeysOfOneDeviceAreOneDeviceWaiting() async throws {
        try writeRootRecord()
        // The stranger's own device record, which is what maps its assistant
        // key back to it. Self-signed by its author key, as the reader requires.
        try RegistryWriter.write(
            DeviceRecord(
                device: stranger.fingerprint, name: "Denver's iPhone", kind: .phone,
                actors: [
                    DeviceActor.author.rawValue: stranger.fingerprint,
                    DeviceActor.assistant.rawValue: strangerDevice.assistant.fingerprint,
                ],
                madeAt: Date(timeIntervalSince1970: 5)),
            signedBy: stranger, in: projectURL)

        let store = OpLogStore(
            projectURL: projectURL, identities: strangerDevice, state: strangerState)
        try await store.append(op("02", device: strangerDevice.author))
        try await store.append(op("03", device: strangerDevice.assistant))
        let sealed = try await store.sealChain(docId: docId)
        XCTAssertTrue(sealed, "both of the stranger's actor files are sealed")

        let load = try await reader().loadDiagnosed(docId: docId)

        XCTAssertEqual(load.ops.count, 0, "nothing the stranger wrote is applied")
        XCTAssertEqual(load.provenance.pendingLines, 4,
                       "two ops and two seals, over two files")
        XCTAssertEqual(load.provenance.pendingByDevice,
                       [stranger.fingerprint: 2],
                       "one device is waiting, not two — and it is waiting "
                       + "with two OPS, not with four lines (P2b Task 10)")
    }

    // MARK: - A rotated segment is judged like a live tail (P2b Task 10)

    /// **A stranger's ROTATED history is held, exactly as its live tail is.**
    ///
    /// A `.mzseg` whose container signature this device cannot call its own
    /// falls through to a line-by-line walk, and until P2b's final wave that
    /// walk was KEYLESS: every seal inside it answered `.noChain` and its span
    /// was applied as unsigned history. So a stranger's `.jsonl` was held and
    /// the same stranger's segment was applied unread — rotation, which is
    /// maintenance a device performs on itself, silently admitted it. This is
    /// a P1 behaviour change and ADR 0032 §6 records it.
    func test_aStrangersRotatedSegmentIsHeldJustAsItsTailIs() async throws {
        try writeRootRecord()
        let store = OpLogStore(
            projectURL: projectURL, identity: stranger, state: strangerState)
        try await store.append(op("02", device: stranger))
        try await store.append(op("03", device: stranger))
        let sealed = try await store.sealChain(docId: docId)
        XCTAssertTrue(sealed)
        // Rotate the sealed tail into a segment. The signature beside it is the
        // stranger's, so it cannot settle this device's read.
        let segment = try await store.sealTailIfNeeded(
            docId: docId, deviceSlug: stranger.slug, threshold: 0)
        XCTAssertEqual(segment?.pathExtension, "mzseg",
                       "the stranger's history is rotated into a segment")

        let load = try await reader().loadDiagnosed(docId: docId)

        XCTAssertEqual(load.ops.count, 0,
                       "a stranger's rotated history is no more applied than its tail")
        XCTAssertEqual(load.provenance.unsignedHistoryLines, 0,
                       "and it is not quietly filed as unsigned history, which "
                       + "is what the keyless fallback walk used to do")
        XCTAssertEqual(load.provenance.pendingByDevice,
                       [stranger.fingerprint: 2],
                       "the same two ops are waiting, in the same device's name")
    }

    /// The converse, and the half a keyless walk could not answer either:
    /// **this device's OWN inner seals settle `verified`.**
    ///
    /// A segment whose container signature is gone — the sidecar deleted, a
    /// segment minted before signatures existed — is walked rather than
    /// settled. The lines inside it are still sealed by this device's own key,
    /// and under the keyless walk they came back as somebody else's unsigned
    /// history: this Mac's own work, in the History pane, attributed to nobody.
    func test_thisDevicesOwnInnerSealsSettleVerifiedInAWalkedSegment() async throws {
        try writeRootRecord()
        let store = reader()
        try await store.append(op("01", device: root.author))
        try await store.append(op("02", device: root.author))
        let sealed = try await store.sealChain(docId: docId)
        XCTAssertTrue(sealed)
        let segment = try await store.sealTailIfNeeded(
            docId: docId, deviceSlug: root.author.slug, threshold: 0)
        let url = try XCTUnwrap(segment)
        // Take the container signature away: the segment can no longer settle
        // whole, so the fallback walk is what judges its lines.
        try FileManager.default.removeItem(at: OpLogStore.segmentSignatureURL(for: url))

        let load = try await reader().loadDiagnosed(docId: docId)

        XCTAssertEqual(load.ops.map(\.opId), ["01", "02"],
                       "this device's own ops are applied either way")
        XCTAssertEqual(load.provenance.unsignedHistoryLines, 0,
                       "and they are NOT unsigned history — this Mac wrote them "
                       + "and holds the key that sealed them")
        XCTAssertEqual(load.provenance.pendingLines, 0,
                       "nor is this device's own hand held from itself")
        XCTAssertGreaterThan(load.provenance.verifiedLines, 0,
                             "the walk recognises the seal as ours and settles "
                             + "the span verified")
    }

    // MARK: - Resolving

    /// A Mac that is its own root joins nothing: there is no chain of anybody
    /// else's for it to be on, and a join recorded here would have every
    /// surface that reads it say *this Mac joined its own chain*.
    func test_aDeviceThatIsItsOwnRootJoinsNothing() throws {
        try writeRootRecord()

        let table = try TrustResolution.resolve(
            projectURL: projectURL, identities: root, cache: cache)

        XCTAssertEqual(table.myRoot, root.author.fingerprint)
        XCTAssertEqual(table.ownRootRecord, root.author.fingerprint)
        XCTAssertEqual(table.admittingRoots, [])
        XCTAssertNil(cache.joinedRoot(for: projectURL),
                     "being your own root is not joining one")
    }

    /// B1's sharpest case, and it needs no malice: two Macs both open an empty
    /// book before sync converges, each writes itself a root, then one admits
    /// the other. A device that JOINED on *a root names me* would lose its own
    /// root to the other one on the very next resolve — arm 1 outranks arm 2 —
    /// and every peer it had admitted would turn `.otherRoot` and be
    /// quarantined. A device on a root of its own joins nobody.
    func test_aDeviceOnItsOwnRootNeverJoinsARootThatNamesIt() throws {
        try writeRootRecord()
        try admit(stranger.fingerprint, under: root.author, at: 20)

        // The other Mac: its own root, and it takes this device into its chain
        // by one of the OTHER three actor keys. It has to be another key: a
        // person record is named by its fingerprint, so an admission of this
        // device's AUTHOR key would overwrite the very root record above rather
        // than sit beside it, which is a different event and a different fix.
        let other = DeviceIdentity.softwareForTesting()
        try admit(other.fingerprint, under: other, at: 30)
        try admit(root.assistant.fingerprint, under: other, at: 40)

        let first = try TrustResolution.resolve(
            projectURL: projectURL, identities: root, cache: cache)
        XCTAssertEqual(first.myRoot, root.author.fingerprint)
        XCTAssertEqual(first.ownRootRecord, root.author.fingerprint)
        XCTAssertNil(cache.joinedRoot(for: projectURL),
                     "a device already on a root of its own joins nobody")
        XCTAssertEqual(cache.claimants(for: projectURL), [other.fingerprint],
                       "the other Mac is listed as claiming this book")

        // The resolve that would have gone wrong: arm 1 has nothing to outrank
        // arm 2 with, so the chain is exactly where it was.
        let second = try TrustResolution.resolve(
            projectURL: projectURL, identities: root, cache: cache)
        XCTAssertEqual(second.myRoot, root.author.fingerprint)
        XCTAssertEqual(second.verdict(forSealKey: stranger.fingerprint),
                       .admitted(person: stranger.fingerprint),
                       "and this device's own admittee is still admitted")
        XCTAssertEqual(cache.claimants(for: projectURL), [other.fingerprint],
                       "recorded once, not once per load")
    }

    /// B1, both halves: the FOREIGN root that first names this device is
    /// joined, and a second one arriving later is recorded as a claimant while
    /// the join stands.
    func test_theFirstForeignRootIsJoinedAndTheSecondIsAClaimant() throws {
        // This device is nobody's root here; two other Macs each admit it.
        let first = DeviceIdentity.softwareForTesting()
        let second = DeviceIdentity.softwareForTesting()
        try admit(first.fingerprint, under: first, at: 10)     // the first root itself
        try admit(root.author.fingerprint, under: first, at: 20)

        let joined = try TrustResolution.resolve(
            projectURL: projectURL, identities: root, cache: cache)
        XCTAssertEqual(joined.myRoot, first.fingerprint)
        XCTAssertEqual(cache.joinedRoot(for: projectURL), first.fingerprint,
                       "the root that took this device in is the one it is on")
        XCTAssertEqual(cache.claimants(for: projectURL), [])

        // Now a second root sets itself up and claims this device too.
        try admit(second.fingerprint, under: second, at: 30)   // the second root itself
        try admit(root.author.fingerprint, under: second, at: 40)

        let claimed = try TrustResolution.resolve(
            projectURL: projectURL, identities: root, cache: cache)
        XCTAssertEqual(claimed.myRoot, first.fingerprint,
                       "a device never switches roots on its own (B1)")
        XCTAssertEqual(cache.claimants(for: projectURL), [second.fingerprint],
                       "the second claimant is recorded, loudly, and never merged")
    }

    /// **A claim this device REFUSED is still recorded** (fix round 1, I1).
    ///
    /// The same-authority rule keeps the second root's admission out of the
    /// registry — that is the point of it — but the registry is where
    /// `admittingRoots` comes from, so the refusal takes the claim off the only
    /// path B1 had to see it. `TrustResolution` reads the `.signerChanged`
    /// listing instead, so the writer is shown the claimant even though nothing
    /// about this device's chain moved.
    ///
    /// The test above is the same story with the folder's copy still in the
    /// registry; this one reaches the claimant through the listing alone.
    func test_aRefusedClaimIsStillRecordedAsAClaimant() throws {
        let first = DeviceIdentity.softwareForTesting()
        let second = DeviceIdentity.softwareForTesting()
        try admit(first.fingerprint, under: first, at: 10)
        try admit(root.author.fingerprint, under: first, at: 20)

        // Verified once, so this device REMEMBERS being on the first root.
        _ = try TrustResolution.resolve(
            projectURL: projectURL, identities: root, cache: cache)
        XCTAssertEqual(cache.joinedRoot(for: projectURL), first.fingerprint)

        // The second root writes its own admission over the same record.
        try admit(second.fingerprint, under: second, at: 30)
        try admit(root.author.fingerprint, under: second, at: 40)

        let table = try TrustResolution.resolve(
            projectURL: projectURL, identities: root, cache: cache)

        XCTAssertEqual(table.myRoot, first.fingerprint,
                       "the refusal is what keeps this device on the root it joined")
        XCTAssertEqual(cache.claimants(for: projectURL), [second.fingerprint],
                       "and the claim it refused is recorded, not swallowed")
        XCTAssertEqual(makeSameCache().claimants(for: projectURL), [second.fingerprint],
                       "persisted, so a surface can show it after a relaunch")
    }

    /// Recorded once, however many times the project is opened — and the
    /// listing is the same listing every time, so this is the clause that
    /// matters.
    func test_aRefusedClaimIsRecordedOncePerClaimant() throws {
        let first = DeviceIdentity.softwareForTesting()
        let second = DeviceIdentity.softwareForTesting()
        try admit(first.fingerprint, under: first, at: 10)
        try admit(root.author.fingerprint, under: first, at: 20)
        _ = try TrustResolution.resolve(
            projectURL: projectURL, identities: root, cache: cache)

        try admit(second.fingerprint, under: second, at: 30)
        try admit(root.author.fingerprint, under: second, at: 40)
        for _ in 0..<3 {
            _ = try TrustResolution.resolve(
                projectURL: projectURL, identities: root, cache: cache)
        }

        XCTAssertEqual(cache.claimants(for: projectURL), [second.fingerprint])
    }

    /// **A device is nobody's claimant to itself** (fix round 1, M1). A key of
    /// OURS displacing a record of ours is this device re-signing its own
    /// history; listing ourselves would be a permanent warning nobody can
    /// answer.
    func test_thisDevicesOwnKeyDisplacingItsOwnRecordClaimsNothing() throws {
        let first = DeviceIdentity.softwareForTesting()
        try admit(first.fingerprint, under: first, at: 10)
        try admit(root.author.fingerprint, under: first, at: 20)
        _ = try TrustResolution.resolve(
            projectURL: projectURL, identities: root, cache: cache)

        // This device writes its own self-signed root record over the
        // admission it was remembered under — a different signer, so the rule
        // refuses it, but the signer is us.
        try admit(root.author.fingerprint, under: root.author, at: 30)

        // The branch under test is reached: without this the assertion below
        // would pass on a folder that displaced nothing.
        let listings = try cache.reconcile(
            folder: try RegistryReader.load(projectURL: projectURL),
            cached: cache.cached(for: projectURL), in: projectURL).registry.malformed
        XCTAssertEqual(
            listings.map(\.reason),
            [.signerChanged(expected: first.fingerprint,
                            found: root.author.fingerprint)],
            "the same-authority rule did refuse it — the signer is simply ours")

        _ = try TrustResolution.resolve(
            projectURL: projectURL, identities: root, cache: cache)

        XCTAssertEqual(cache.claimants(for: projectURL), [],
                       "this device does not claim its own book")
    }

    // MARK: - A second root is a claimant however it got there (smoke find 9)

    /// **The two-root merge, from the side that did not begin it.**
    ///
    /// B claims the book: it writes its own root record and a claim record
    /// adopting A's root. Nothing in that names one of A's keys — a claim is
    /// signed by B about B — so neither of the older rules sees it: it reaches
    /// no `admittingRoots` and displaces no record of A's. Before this rule A's
    /// People & Devices listed nothing of B and offered no Merge, so the merge
    /// B had started could never be finished from A's side.
    func test_aRootThatAdoptedMineIsListedAsAClaimant() throws {
        try writeRootRecord()

        // B: a Mac that rooted itself here and adopted A's chain.
        let other = LocalIdentities.softwareForTesting()
        let otherCache = RegistryCache(
            fileURL: projectURL.appendingPathComponent("other-cache.json"),
            identity: other.author.fingerprint)
        try RegistryAdmission.claim(
            adopting: [root.author.fingerprint], in: projectURL,
            by: other.author, cache: otherCache)

        let table = try TrustResolution.resolve(
            projectURL: projectURL, identities: root, cache: cache)

        XCTAssertEqual(table.myRoot, root.author.fingerprint,
                       "B's claim moves nobody's root (B1)")
        XCTAssertEqual(table.adoptedRoots, [],
                       "and A has not reciprocated, so it verifies nothing of B's")
        XCTAssertEqual(cache.claimants(for: projectURL), [other.author.fingerprint],
                       "but B is listed, so the writer can answer it")
        XCTAssertEqual(makeSameCache().claimants(for: projectURL),
                       [other.author.fingerprint],
                       "and it survives the launch that draws it")
    }

    /// Step 19 of the smoke script: two Macs each rooted an empty book before
    /// sync converged and neither has claimed anything. There is no claim
    /// record and no admission either way — just a second root in the folder,
    /// which is the whole of what makes it a claimant.
    func test_aSecondRootBesideMineIsAClaimantWithNoClaimAtAll() throws {
        try writeRootRecord()
        let other = DeviceIdentity.softwareForTesting()
        try admit(other.fingerprint, under: other, at: 30)

        _ = try TrustResolution.resolve(
            projectURL: projectURL, identities: root, cache: cache)

        XCTAssertEqual(cache.claimants(for: projectURL), [other.fingerprint])
    }

    /// The other direction of the same rule: a root **this** device has adopted
    /// is merged, and merged is this device's own answer to the question the
    /// claimant list exists to ask. Listing it anyway would put the offer back
    /// in front of a writer who has already taken it.
    func test_aRootThisDeviceHasAdoptedIsNotAClaimant() throws {
        try writeRootRecord()
        let other = DeviceIdentity.softwareForTesting()
        try admit(other.fingerprint, under: other, at: 30)

        try RegistryAdmission.claim(
            adopting: [other.fingerprint], in: projectURL,
            by: root.author, cache: cache)

        let table = try TrustResolution.resolve(
            projectURL: projectURL, identities: root, cache: cache)

        XCTAssertEqual(table.adoptedRoots, [other.fingerprint])
        XCTAssertEqual(cache.claimants(for: projectURL), [],
                       "a root this device took in is merged, never claiming")
    }

    /// And the root this device is ON is never its own claimant — the rule
    /// reads every root in the folder, so the one it belongs to has to be
    /// excluded by name or every joined device would warn about its own chain.
    func test_theRootThisDeviceIsOnIsNotAClaimant() throws {
        let host = DeviceIdentity.softwareForTesting()
        try admit(host.fingerprint, under: host, at: 10)
        try admit(root.author.fingerprint, under: host, at: 20)

        let table = try TrustResolution.resolve(
            projectURL: projectURL, identities: root, cache: cache)

        XCTAssertEqual(table.myRoot, host.fingerprint)
        XCTAssertEqual(cache.claimants(for: projectURL), [])
    }

    /// **A verdict is not what this rule touches.** Listing B as a claimant is
    /// about what People & Devices shows; what B's keys are to this device is
    /// `TrustTable`'s answer, and it is the same before and after — refused,
    /// as another claimant's.
    func test_listingAClaimantChangesNoVerdict() throws {
        try writeRootRecord()
        let other = DeviceIdentity.softwareForTesting()
        try admit(other.fingerprint, under: other, at: 30)

        let table = try TrustResolution.resolve(
            projectURL: projectURL, identities: root, cache: cache)

        XCTAssertEqual(table.verdict(forSealKey: other.fingerprint),
                       .otherRoot(root: other.fingerprint))
        XCTAssertEqual(table.verdict(forSealKey: root.author.fingerprint), .mine)
    }

    /// A second memory over the same file, to prove a claimant survives the
    /// process rather than living in one instance.
    private func makeSameCache() -> RegistryCache {
        RegistryCache(
            fileURL: projectURL.appendingPathComponent("registry-cache.json"),
            identity: root.author.fingerprint)
    }

    /// The registry folder deleted wholesale is a vanished chain, not the
    /// absence of one: this device's memory puts the records back.
    func test_aRegistryDeletedWholesaleIsRestoredRatherThanBelieved() async throws {
        try writeRootRecord()
        try await writeMyOwnFile(["01"])
        try await writeStrangerFile(["02"])
        _ = try await reader().loadDiagnosed(docId: docId)   // remembers the registry

        for directory in RegistryDirectory.allCases {
            try? FileManager.default.removeItem(
                at: RegistryWriter.directoryURL(directory, in: projectURL))
        }
        XCTAssertFalse(TrustResolution.hasRegistry(in: projectURL))

        let table = try TrustResolution.resolve(
            projectURL: projectURL, identities: root, cache: cache)

        XCTAssertEqual(table.myRoot, root.author.fingerprint,
                       "the chain is what it was; deleting a folder does not end it")
        XCTAssertEqual(table.verdict(forSealKey: stranger.fingerprint),
                       .stranger(device: nil),
                       "and the stranger is still held, not applied as unsigned history")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: RegistryWriter.url(
                    .people, fingerprint: root.author.fingerprint,
                    in: projectURL).path),
            "the record is put back where it was")
    }

    /// A project with no registry folder at all answers `.noChain` and touches
    /// nothing: no read, and no cache entry minted for having been opened. That
    /// is every project written before this milestone, so it is also the arm
    /// every other suite in this package runs on.
    func test_aProjectWithNoRegistryResolvesToNoChainAndRemembersNothing() throws {
        let table = try TrustResolution.resolve(
            projectURL: projectURL, identities: root, cache: cache)

        XCTAssertNil(table.myRoot)
        XCTAssertEqual(table.verdict(forSealKey: stranger.fingerprint), .noChain,
                       "with no chain, nobody is judged (B3)")
        XCTAssertEqual(table.verdict(forSealKey: root.assistant.fingerprint), .mine,
                       "a device still knows its own hand")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.fileURL.path),
                       "opening a project that never joined a chain writes nothing")
    }

    /// Spec §4.1: admitting a device applies what it was holding on the next
    /// READ, not on the next window. The store re-resolves when the registry
    /// folder has changed under it.
    func test_admittingOnALiveStoreAppliesTheHeldOpsOnTheNextRead() async throws {
        try writeRootRecord()
        try await writeMyOwnFile(["01"])
        try await writeStrangerFile(["02", "03"])

        let store = reader()
        let before = try await store.loadDiagnosed(docId: docId)
        XCTAssertEqual(before.ops.map(\.opId), ["01"])

        try writeStrangerRecord()

        let after = try await store.loadDiagnosed(docId: docId)
        XCTAssertEqual(after.ops.map(\.opId), ["01", "02", "03"],
                       "the same store, re-resolved because the registry changed")
        XCTAssertEqual(after.provenance.pendingLines, 0)
    }

    /// And the explicit door, for the caller that just wrote the record itself
    /// and should not have to hope a modification time moved far enough.
    func test_invalidatingTheTableMakesTheNextReadResolveAfresh() async throws {
        try writeRootRecord()
        try await writeStrangerFile(["02"])

        let store = reader()
        _ = try await store.loadDiagnosed(docId: docId)
        try writeStrangerRecord()
        store.invalidateTrust()

        let after = try await store.loadDiagnosed(docId: docId)
        XCTAssertEqual(after.ops.map(\.opId), ["02"])
    }

    // MARK: - An unreadable registry record (RULING-54)

    /// A record that is present and cannot be read refuses the load by name.
    /// Judging nobody instead would apply a stranger's whole history as this
    /// project's own, silently — the shape RULING-54 exists to forbid.
    func test_anUnreadableRegistryRecordRefusesTheLoadByName() async throws {
        try XCTSkipIf(getuid() == 0, "root reads a mode-000 file, so nothing is refused")
        try writeRootRecord()
        try await writeMyOwnFile(["01"])
        let record = RegistryWriter.url(
            .people, fingerprint: root.author.fingerprint, in: projectURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: record.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: record.path)
        }

        do {
            _ = try await reader().loadDiagnosed(docId: docId)
            XCTFail("an unreadable registry record must refuse the load")
        } catch let error as OpLogStore.ReadError {
            guard case let .unreadableFile(name, _, kind) = error else {
                return XCTFail("the wrong ReadError: \(error)")
            }
            XCTAssertEqual(name, record.lastPathComponent)
            XCTAssertEqual(kind, .registry)
        }

        XCTAssertThrowsError(
            try OpLogStore.loadSyncMerged(
                forDocId: docId, in: projectURL, identities: root, state: rootState),
            "the synchronous reader refuses it too")
    }

    /// The read-only recovery rung does not refuse the whole document over it —
    /// but it does not swallow it either. The record is NAMED beside whatever
    /// op-log files could not be opened.
    func test_theReadOnlyRungNamesTheUnreadableRecordRatherThanSwallowingIt() async throws {
        try XCTSkipIf(getuid() == 0, "root reads a mode-000 file, so nothing is refused")
        try writeRootRecord()
        try await writeMyOwnFile(["01"])
        let record = RegistryWriter.url(
            .people, fingerprint: root.author.fingerprint, in: projectURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: record.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: record.path)
        }

        let partial = await reader().loadDiagnosedPartial(docId: docId)

        XCTAssertEqual(partial.ops.map(\.opId), ["01"],
                       "the rung applies what it can read")
        XCTAssertTrue(
            partial.unreadableFiles.contains { $0.name == record.lastPathComponent },
            "and names the record that stopped it judging anyone")
    }

    // MARK: - Another claimant's

    func test_aSecondClaimantsSpanIsQuarantinedInItsOwnWords() async throws {
        try writeRootRecord()
        try await writeMyOwnFile(["01"])
        let strangerLines = try await writeStrangerFile(["02"])

        // A second root, which admitted the stranger into ITS chain.
        let claimant = DeviceIdentity.softwareForTesting()
        try admit(claimant.fingerprint, under: claimant, at: 30)
        try admit(stranger.fingerprint, under: claimant, at: 40)

        let load = try await reader().loadDiagnosed(docId: docId)

        XCTAssertEqual(load.ops.map(\.opId), ["01"])
        XCTAssertEqual(load.provenance.quarantinedLines, strangerLines)
        XCTAssertEqual(load.provenance.pendingLines, 0,
                       "a claimant's chain is refused, never merely held")
        XCTAssertEqual(linesRecords().first?.reason,
                       "written under another claimant's copy of this book")
    }

    // MARK: - The two readers agree

    func test_theSynchronousReaderHoldsExactlyWhatTheCoordinatedOneHeld() async throws {
        try writeRootRecord()
        try await writeMyOwnFile(["01"])
        try await writeStrangerFile(["02", "03"])

        let coordinated = try await reader().loadDiagnosed(docId: docId)
        let synchronous = try OpLogStore.loadSyncMerged(
            forDocId: docId, in: projectURL,
            identities: root, state: rootState,
            trust: try TrustResolution.resolve(
                projectURL: projectURL, identities: root, cache: cache))

        XCTAssertEqual(synchronous.map(\.opId), coordinated.ops.map(\.opId))
    }
}
