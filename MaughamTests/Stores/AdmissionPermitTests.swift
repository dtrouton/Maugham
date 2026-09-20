// MaughamTests/Stores/AdmissionPermitTests.swift
import XCTest
@testable import MaughamCore
@testable import Maugham

/// **The sheet's Admit carries a permit, and pays for it only where it is
/// owed** (signed op log P3b Task 4, spec §7.1).
///
/// The store verb is where the three prices of a narrowing admission meet: the
/// book's unsigned photograph (Task 1), the schema gate that shuts older builds
/// out (Task 3), and the event itself. All three belong to an act that WRITES a
/// permit — and `RegistryAdmission.admit` over somebody already standing here
/// writes none, whatever it is asked for (Task 1's review, Minor 7). This suite
/// drives both directions against a real project, a real registry folder and a
/// real stranger's sealed file.
@MainActor
final class AdmissionPermitTests: XCTestCase {

    private var projectURL: URL!
    private var cache: RegistryCache!
    private var memory: AdmissionMemory!
    private var strangerDevice: LocalIdentities!
    private var stranger: DeviceIdentity!
    private var strangerState: OpLogDeviceState!

    override func setUp() async throws {
        let (dir, _) = try makeTestProject(prefix: "APERMIT", initialMd: "Hello.\n")
        projectURL = dir
        strangerDevice = .softwareForTesting()
        stranger = strangerDevice.author
        strangerState = OpLogDeviceState(
            fileURL: dir.appendingPathComponent("stranger-state.json"))
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
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        // The fixtures below chmod a file to nothing; put it back or the
        // removal leaves the fixture behind (the $TMPDIR leak, 2026-09-11).
        for url in unreadable {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: url.path)
        }
        unreadable = []
        if let projectURL { try? FileManager.default.removeItem(at: projectURL) }
        projectURL = nil
    }

    // MARK: - Fixtures

    @discardableResult
    private func beThisMac() -> LocalIdentities {
        let identities = LocalIdentities.forTesting(author: .softwareForTesting())
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("op-log-state.json"))
        return identities
    }

    private var docURL: URL { projectURL.appendingPathComponent("manuscript/c1.md") }
    private var manifestURL: URL {
        projectURL.appendingPathComponent(ProjectManifest.fileName)
    }

    private func manifestBytes() throws -> Data { try Data(contentsOf: manifestURL) }

    /// A book written by an older build, so the gate has something to do.
    private func manifestFromAnOlderBuild() throws {
        var manifest = try ProjectManifest.makeDecoder()
            .decode(ProjectManifest.self, from: Data(contentsOf: manifestURL))
        manifest.schemaVersion = ProjectManifest.currentSchemaVersion - 1
        try ProjectManifest.makeEncoder().encode(manifest).write(to: manifestURL)
    }

    private func manifestSchemaOnDisk() throws -> Int {
        try ProjectManifest.makeDecoder()
            .decode(ProjectManifest.self, from: Data(contentsOf: manifestURL))
            .schemaVersion
    }

    private func registry() throws -> Registry {
        try RegistryReader.load(projectURL: projectURL)
    }

    private func events() throws -> [PermitEvent] {
        try registry().events.sorted { $0.event < $1.event }
    }

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
        _ = try await store.sealChain(docId: docId)
    }

    /// **A file only the WHOLE-BOOK sweep reads, and cannot.**
    ///
    /// The one observable difference between *the photograph was taken* and
    /// *it was not* is the sweep's own refusal — and it has to be a refusal the
    /// PERSON sweep does not share, or the test cannot tell the two sweeps
    /// apart. `seenPositions` skips a file whose slug is not the subject's
    /// before it reads a byte (`positions`' `slugs.contains(slug)` guard);
    /// `unattributablePositions` reads every stream in the book. So: a third
    /// machine's op-log file, present and unreadable.
    ///
    /// (An unreadable `.maugham/translations` — the fixture the P3a admission
    /// tests use — refuses BOTH, because the mark sweep lists that folder too.
    /// It proved nothing about which sweep ran.)
    private func makeTheWholeBookSweepRefuse(docId: String) throws {
        let ghost = projectURL.appendingPathComponent(
            ".maugham/ops/\(docId).ghostmac-0badf00d.jsonl")
        try Data("{}\n".utf8).write(to: ghost)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: ghost.path)
        unreadable.append(ghost)
    }

    /// Files this suite made unreadable, put back in `tearDown` so the fixture
    /// can be removed.
    private var unreadable: [URL] = []

    private func docId() async throws -> String {
        let doc = try await Document.load(
            url: docURL, actor: .author, session: "s", presenter: nil)
        let id = doc.docId
        await doc.close()
        return id
    }

    // MARK: - A reviewer admission writes the rung, the photograph and the gate

    func test_admittingAReviewerWritesTheRungTheSnapshotAndTheGate() async throws {
        beThisMac()
        try manifestFromAnOlderBuild()
        let store = try await DocumentStore.open(url: projectURL)
        try await writeStrangerFile(docId: try await docId(), opIds: ["02"])

        _ = try await store.admit(
            device: stranger.fingerprint, label: "Sam", ownName: "Sam’s Mac",
            permit: PermitControl.permit(for: .reviewer, pieces: []))

        let event = try XCTUnwrap(try events().last)
        XCTAssertEqual(event.subject, stranger.fingerprint)
        XCTAssertEqual(event.kind, .admitted)
        XCTAssertEqual(Permit(event: event), .reviewer,
                       "the rung the sheet asked for is the rung the book records")
        XCTAssertNotNil(event.unsigned,
                        "a narrowing event carries the book's photograph")
        XCTAssertEqual(
            try manifestSchemaOnDisk(), ProjectManifest.currentSchemaVersion,
            "and older builds are shut out before the event exists")
        XCTAssertEqual(try registry().person(stranger.fingerprint)?.role,
                       Permit.reviewerRole)
    }

    func test_admittingAnAuthorOfSomePiecesWritesTheList() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        let piece = try await docId()
        try await writeStrangerFile(docId: piece, opIds: ["02"])

        _ = try await store.admit(
            device: stranger.fingerprint, label: "Sam", ownName: "Sam’s Mac",
            permit: PermitControl.permit(for: .somePieces, pieces: [piece]))

        let event = try XCTUnwrap(try events().last)
        XCTAssertEqual(Permit(event: event), .author(.pieces([piece])))
    }

    /// **The ordinary admission is untouched** — no photograph, no gate, and
    /// the manifest byte-identical. Every admission before this milestone was
    /// this one, and the default the sheet opens on still is.
    func test_anAdmissionOfAnAuthorOfTheWholeBookPaysForNothing() async throws {
        beThisMac()
        try manifestFromAnOlderBuild()
        let store = try await DocumentStore.open(url: projectURL)
        let piece = try await docId()
        try await writeStrangerFile(docId: piece, opIds: ["02"])
        let before = try manifestBytes()
        // The photograph, if one were taken, would refuse over this file.
        try makeTheWholeBookSweepRefuse(docId: piece)

        _ = try await store.admit(
            device: stranger.fingerprint, label: "Sam", ownName: "Sam’s Mac",
            permit: PermitControl.permit(for: .wholeBook, pieces: []))

        XCTAssertEqual(try manifestBytes(), before, "nothing gates")
        XCTAssertNil(try events().last?.unsigned, "and nothing is photographed")
        XCTAssertNotNil(try registry().person(stranger.fingerprint))
    }

    // MARK: - Minor 7: no sweep, no gate, where no event will be written

    /// **`admit` over somebody already standing here moves no permit** — Core
    /// carries their own stored role back into their record and writes no
    /// event at all. So the two prices of a narrowing act must not be paid:
    /// the book must not be gated, and the project's op log must not be swept.
    ///
    /// The sweep is observed by making it REFUSE: a folder it cannot read
    /// throws, and an act that swept would fail here. It succeeds.
    func test_anAdmitOverAStandingPersonSweepsNothingAndGatesNothing() async throws {
        beThisMac()
        try manifestFromAnOlderBuild()
        let store = try await DocumentStore.open(url: projectURL)
        let piece = try await docId()
        _ = try await store.admit(
            device: stranger.fingerprint, label: "Sam", ownName: "Sam’s Mac")
        let before = try manifestBytes()
        let eventsBefore = try events().map(\.event)
        try makeTheWholeBookSweepRefuse(docId: piece)

        // The same device, a corrected machine name, and a permit that would
        // narrow the book if this act installed one. It does not.
        _ = try await store.admit(
            device: stranger.fingerprint, label: "Sam",
            ownName: "Sam’s new Mac",
            permit: PermitControl.permit(for: .reviewer, pieces: []))

        XCTAssertEqual(try manifestBytes(), before,
                       "a rename does not shut older builds out of the book")
        XCTAssertEqual(try events().map(\.event), eventsBefore,
                       "and it writes no permit event")
        XCTAssertEqual(try registry().person(stranger.fingerprint)?.role,
                       Permit.authorRole,
                       "a standing person's permit is changePermit's to move")
        XCTAssertEqual(try registry().person(stranger.fingerprint)?.ownName,
                       "Sam’s new Mac", "the rename itself still happened")
    }

    /// **The converse, so the saving cannot quietly widen**: the same narrowing
    /// permit over somebody NOT standing here does sweep, and refuses over the
    /// same unreadable folder with nothing written.
    func test_theSameNarrowingOverAStrangerStillSweepsAndRefusesLoudly() async throws {
        beThisMac()
        try manifestFromAnOlderBuild()
        let store = try await DocumentStore.open(url: projectURL)
        let before = try manifestBytes()
        try makeTheWholeBookSweepRefuse(docId: try await docId())

        do {
            _ = try await store.admit(
                device: stranger.fingerprint, label: "Sam", ownName: "Sam’s Mac",
                permit: PermitControl.permit(for: .reviewer, pieces: []))
            XCTFail("a book this Mac could only half read must not be narrowed")
        } catch let error as RegistryAdmissionError {
            guard case .historyUnreadable(let name, let act) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(act, .admission)
            XCTAssertTrue(name.contains("ghostmac"),
                          "the refusal names the file the photograph tripped "
                          + "on, which is one the person sweep never reads: "
                          + "\(name)")
        }

        XCTAssertEqual(try manifestBytes(), before, "and nothing was gated")
        XCTAssertNil(try registry().person(stranger.fingerprint))
    }

    /// **A REVOKED record is not a standing one** — a re-admission is the
    /// revocation's inverse and installs the permit it is given, so it pays
    /// both prices. This is also the store-side drive of the P3a pin that a P2
    /// author let back in as a reviewer keeps the chapters she wrote.
    func test_readmittingSomebodyRevokedAsAReviewerWritesTheRungAndThePhotograph()
        async throws
    {
        beThisMac()
        try manifestFromAnOlderBuild()
        let store = try await DocumentStore.open(url: projectURL)
        let piece = try await docId()
        try await writeStrangerFile(docId: piece, opIds: ["02"])
        _ = try await store.admit(
            device: stranger.fingerprint, label: "Sam", ownName: "Sam’s Mac")
        _ = try await store.revoke(person: stranger.fingerprint)

        _ = try await store.admit(
            device: stranger.fingerprint, label: "Sam", ownName: "Sam’s Mac",
            permit: PermitControl.permit(for: .reviewer, pieces: []))

        let event = try XCTUnwrap(try events().last)
        XCTAssertEqual(event.kind, .readmitted,
                       "never `admitted` — an admitted event's permit would "
                       + "reach back through everything she ever wrote")
        XCTAssertEqual(Permit(event: event), .reviewer)
        XCTAssertNotNil(event.unsigned)
        XCTAssertFalse(event.mark.isEmpty,
                       "and the mark says where the new permit begins")
        XCTAssertEqual(
            try manifestSchemaOnDisk(), ProjectManifest.currentSchemaVersion)
    }

    // MARK: - The silent admission stays outside all of it (Task 3's carry)

    /// **`admitRemembered` admits book authors and nothing else.** It reaches
    /// Core directly, with no Mac store between it and the folder, so it is
    /// outside the gate by construction — which is harmless exactly as long as
    /// it can never narrow a book. Both halves pinned: the record it writes is
    /// an author of the whole book, and the manifest is byte-identical.
    func test_aRememberedAdmissionIsABookAuthorAndGatesNothing() async throws {
        beThisMac()
        try manifestFromAnOlderBuild()
        let store = try await DocumentStore.open(url: projectURL)
        try await writeStrangerFile(docId: try await docId(), opIds: ["02"])
        memory.remember(
            stranger.fingerprint, label: "Sam", ownName: "Sam’s Mac",
            at: Date(timeIntervalSince1970: 1))
        // `RegistryPresence.admitRemembered` walks the folder's DEVICE
        // records: a key no record names cannot be silently admitted, because
        // there is nothing there to have remembered.
        try RegistryWriter.write(
            DeviceRecord(
                device: stranger.fingerprint, name: "Sam’s Mac", kind: .mac,
                actors: [DeviceActor.author.rawValue: stranger.fingerprint],
                madeAt: Date(timeIntervalSince1970: 5)),
            signedBy: stranger, in: projectURL)
        let before = try manifestBytes()

        let admitted = await store.admitRemembered()

        XCTAssertEqual(admitted.map(\.person), [stranger.fingerprint])
        let record = try XCTUnwrap(try registry().person(stranger.fingerprint))
        XCTAssertEqual(
            Permit.parse(role: record.role, scope: record.scope,
                         pieces: record.pieces),
            .author(.book),
            "a device let in without being asked about is let in whole")
        XCTAssertEqual(try manifestBytes(), before)
        XCTAssertNil(try events().last?.unsigned)
    }

    // MARK: - The union the sheet decides from

    /// **The held-lines union carries the stream each holder was held in** —
    /// the fact `AdmissionDecision.standing` needs and the one only a file can
    /// supply.
    func test_theHeldLinesUnionNamesTheStreamTheLinesWereHeldIn() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        let doc = try await Document.load(
            url: docURL, actor: .author, session: "s", presenter: nil)
        let id = doc.docId
        await doc.close()
        try await writeStrangerFile(docId: id, opIds: ["02"])

        let held = try await Document.load(
            url: docURL, actor: .author, session: "s", presenter: nil)
        store.register(document: held, for: "manuscript/c1.md")

        let union = store.heldLines()
        XCTAssertEqual(union.counts[stranger.fingerprint], 1)
        XCTAssertEqual(
            union.streams[stranger.fingerprint],
            [stranger.slug.raw],
            "the slug of the file her lines are in, which is what says "
            + "whether her key is a person's at all")
        XCTAssertEqual(store.heldLinesByDevice(), union.counts,
                       "one walk, two readers")
        await held.close()
    }
}
