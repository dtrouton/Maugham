// MaughamTests/Stores/DocumentStoreAdmissionTests.swift
import XCTest
@testable import MaughamCore
@testable import Maugham

/// **Admitting a device applies what it held, on the next read of the same
/// store** (signed op log P2b, spec §4.1–4.2).
///
/// The sheet is a value and a view; this suite is about the two production
/// paths behind it — `DocumentStore.admit`, which the sheet's Admit runs, and
/// the silent admission at open that decision B2 promises. Both are exercised
/// against a real temp project, a real registry folder and a real stranger's
/// sealed file, because the whole promise is about what a LOAD does afterwards.
@MainActor
final class DocumentStoreAdmissionTests: XCTestCase {

    private var projectURL: URL!
    private var cache: RegistryCache!
    private var memory: AdmissionMemory!
    private var strangerDevice: LocalIdentities!
    private var stranger: DeviceIdentity!
    private var strangerState: OpLogDeviceState!

    override func setUp() async throws {
        let (dir, _) = try makeTestProject(prefix: "ADMIT", initialMd: "Hello.\n")
        projectURL = dir
        strangerDevice = .softwareForTesting()
        stranger = strangerDevice.author
        strangerState = OpLogDeviceState(
            fileURL: dir.appendingPathComponent("stranger-state.json"))
        // A registry memory and a label memory of this suite's own, so nothing
        // here reaches the process-wide files beside this machine's real keys.
        cache = RegistryCache(
            fileURL: dir.appendingPathComponent("registry-cache.json"),
            identity: "test")
        memory = AdmissionMemory(
            fileURL: dir.appendingPathComponent("admission-memory.json"),
            identity: "test")
        Document.registryCacheForTesting = cache
        Document.admissionMemoryForTesting = memory
    }

    override func tearDown() async throws {
        // Process-wide seams: a leak would change who every later test's load
        // thinks this device is, and which folder it remembers.
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        if let projectURL { try? FileManager.default.removeItem(at: projectURL) }
    }

    // MARK: - Fixtures

    /// This Mac, with a software key, so the records and seals it writes
    /// actually sign on a machine — or a CI runner — with no enclave.
    @discardableResult
    private func beThisMac() -> LocalIdentities {
        let identities = LocalIdentities.forTesting(author: .softwareForTesting())
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("op-log-state.json"))
        return identities
    }

    private var docURL: URL { projectURL.appendingPathComponent("manuscript/c1.md") }

    private func openDocument() async throws -> Document {
        try await Document.load(
            url: docURL, actor: .author, session: "s", presenter: nil)
    }

    /// The stranger's own per-device file for this document: chained and sealed
    /// under a key nothing in this book names.
    private func writeStrangerFile(docId: String, opIds: [String]) async throws {
        let store = OpLogStore(
            projectURL: projectURL, identity: stranger, state: strangerState)
        for id in opIds {
            try await store.append(Op(
                opId: id, docId: docId, at: Date(timeIntervalSince1970: 0),
                device: stranger.deviceId, session: "s", kind: .typingBurst,
                changes: [.init(paragraphId: "aaaa", prior: nil, next: id)],
                sequence: ["aaaa"]))
        }
        let sealed = try await store.sealChain(docId: docId)
        XCTAssertTrue(sealed, "the stranger's file is sealed")
    }

    private func registry() throws -> Registry {
        try RegistryReader.load(projectURL: projectURL)
    }

    // MARK: - The sheet's own verb

    func test_admittingAStrangerAppliesWhatItHeldOnTheSameStoresNextRead() async throws {
        let mine = beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        let doc = try await openDocument()
        let docId = doc.docId
        store.register(document: doc, for: "manuscript/c1.md")
        await doc.close()

        try await writeStrangerFile(docId: docId, opIds: ["02", "03"])

        // The read that HOLDS: the stranger is nobody this book names.
        let held = try await openDocument()
        store.register(document: held, for: "manuscript/c1.md")
        XCTAssertGreaterThan(held.provenance?.pendingLines ?? 0, 0,
                             "the stranger's history is held, not applied")
        // Two ops and the seal that holds them: THREE lines are held, and the
        // writer is waiting on TWO of them. `pendingByDevice` counts ops alone
        // (P2b Task 10) because every reader of it puts a noun after the number
        // — *2 notes from Denver's iPhone* — and a seal is not a note.
        XCTAssertEqual(held.provenance?.pendingLines, 3)
        XCTAssertEqual(held.provenance?.pendingByDevice[stranger.fingerprint], 2,
                       "and they are counted under the device waiting for admission")
        let before = try await held.opStore.loadDiagnosed(docId: docId)
        XCTAssertFalse(before.ops.map(\.opId).contains("02"),
                       "nothing the stranger wrote is in the draft")

        _ = try await store.admit(
            device: stranger.fingerprint, label: "Denver", ownName: "Denver’s iPhone")

        let after = try await held.opStore.loadDiagnosed(docId: docId)
        XCTAssertTrue(after.ops.map(\.opId).contains("02"),
                      "the SAME store applies the held ops on its next read — "
                      + "admission re-resolves rather than waiting for a new store")
        XCTAssertTrue(after.ops.map(\.opId).contains("03"))
        XCTAssertEqual(after.provenance.pendingLines, 0,
                       "nothing is waiting any more")

        let record = try XCTUnwrap(try registry().person(stranger.fingerprint))
        XCTAssertEqual(record.label, "Denver")
        XCTAssertEqual(record.ownName, "Denver’s iPhone")
        XCTAssertEqual(record.admittedBy, mine.author.fingerprint,
                       "signed by this Mac's author key, which is what a reader verifies")
        await held.close()
    }

    func test_admittingRemembersTheLabelSoNoLaterBookAsksAgain() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)

        _ = try await store.admit(
            device: stranger.fingerprint, label: "Denver", ownName: "Denver’s iPhone")

        XCTAssertEqual(memory.label(for: stranger.fingerprint)?.label, "Denver",
                       "decision B2: one sheet per device, then silently everywhere")
    }

    func test_aMacThatIsNotTheRootRefusesRatherThanWritingARecordNobodyTakes() async throws {
        beThisMac()
        // Somebody else's book: a root that is not this Mac, written before it
        // ever opens, so `ensureRootIfEmpty` finds people and writes nothing.
        let theirs = DeviceIdentity.softwareForTesting()
        try RegistryWriter.write(
            PersonRecord(
                person: theirs.fingerprint, label: "Amelia", ownName: "Amelia’s Mac",
                admittedAt: Date(timeIntervalSince1970: 10),
                admittedBy: theirs.fingerprint),
            signedBy: theirs, in: projectURL)
        let store = try await DocumentStore.open(url: projectURL)

        do {
            _ = try await store.admit(
                device: stranger.fingerprint, label: "Denver", ownName: "iPhone")
            XCTFail("a non-root's admission is a record every reader lists as malformed")
        } catch let error as RegistryAdmissionError {
            XCTAssertEqual(error, .notARoot)
            XCTAssertFalse(
                AdmissionDecision.refusal(error).isEmpty,
                "and the sheet has a sentence for it (RULING-7)")
        }
        XCTAssertNil(try registry().person(stranger.fingerprint),
                     "nothing was written")
    }

    // MARK: - The re-stamp is a CHANGE, not a callback (review's Important 2)

    /// `Document` is `@Observable` and `HistoryPane` reads `provenance` in
    /// `body`, so an unconditional re-stamp is an observable write on every
    /// presenter callback — and the callback fires on this device's OWN
    /// appends, which is what the echo guard beside it exists for. With the
    /// pane open that recomputed the document's whole merged history on the
    /// main actor, per typing burst.
    func test_anEchoOfThisDevicesOwnWriteDoesNotMoveProvenance() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        let doc = try await openDocument()
        store.register(document: doc, for: "manuscript/c1.md")

        let before = try XCTUnwrap(doc.provenance)
        // Exactly what the presenter delivers when our own append lands.
        try await doc.handleExternalLogChange()

        XCTAssertEqual(doc.provenance, before,
                       "an echo re-reads and finds the same account of the file")
        await doc.close()
    }

    /// And the other half: when the file really has changed underneath, the
    /// count moves. A guard that never assigned would be just as wrong.
    func test_aStrangersFileArrivingDoesMoveProvenance() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        let doc = try await openDocument()
        store.register(document: doc, for: "manuscript/c1.md")
        XCTAssertEqual(doc.provenance?.pendingLines, 0, "nothing is held yet")

        try await writeStrangerFile(docId: doc.docId, opIds: ["02"])
        try await doc.handleExternalLogChange()

        XCTAssertGreaterThan(doc.provenance?.pendingLines ?? 0, 0,
                             "held lines produce no op, so only the re-stamp can see them")
        await doc.close()
    }

    // MARK: - Silent admission at open (decision B2)

    func test_openAdmitsADeviceThisMacHasAlreadyNamed() async throws {
        let mine = beThisMac()
        // This Mac has met the phone before, in another book.
        memory.remember(
            stranger.fingerprint, label: "Denver", ownName: "Denver’s iPhone")
        // And the phone has declared itself in THIS one.
        try RegistryWriter.write(
            DeviceRecord(
                device: stranger.fingerprint, name: "Denver’s iPhone", kind: .phone,
                actors: [DeviceActor.author.rawValue: stranger.fingerprint],
                madeAt: Date(timeIntervalSince1970: 5)),
            signedBy: stranger, in: projectURL)

        _ = try await DocumentStore.open(url: projectURL)

        let record = try XCTUnwrap(try registry().person(stranger.fingerprint))
        XCTAssertEqual(record.label, "Denver",
                       "admitted at open, with the remembered label, without asking")
        XCTAssertEqual(record.ownName, "Denver’s iPhone",
                       "under the name the device gives itself in THIS folder")
        XCTAssertEqual(record.admittedBy, mine.author.fingerprint)
    }

    func test_openAdmitsNobodyItHasNotNamed() async throws {
        beThisMac()
        try RegistryWriter.write(
            DeviceRecord(
                device: stranger.fingerprint, name: "Denver’s iPhone", kind: .phone,
                actors: [DeviceActor.author.rawValue: stranger.fingerprint],
                madeAt: Date(timeIntervalSince1970: 5)),
            signedBy: stranger, in: projectURL)

        _ = try await DocumentStore.open(url: projectURL)

        XCTAssertNil(try registry().person(stranger.fingerprint),
                     "an unremembered device waits for the sheet")
    }
}
