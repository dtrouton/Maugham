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

    /// The piece's id **without opening it** (fix round 1, C2).
    ///
    /// `docId()` below LOADS the document, and on this Mac — the root, an
    /// author of the whole book — a load of a piece with no history bootstraps
    /// it. That is a book author writing the piece's text, which is exactly
    /// what makes §4.5 stop applying: the piece becomes claimed and her lines
    /// are refused rather than held. So a test about the unclaimed case has to
    /// learn the id from the manifest and leave the file alone.
    private func pieceIdFromManifest() throws -> String {
        let manifest = try ProjectManifest.makeDecoder()
            .decode(ProjectManifest.self, from: Data(contentsOf: manifestURL))
        return try XCTUnwrap(
            TreeWalk.collect(in: manifest.structure) { $0.type == .document }
                .first?.id)
    }

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

    // MARK: - P3b Task 5: the pane's verbs, driven from the store

    /// **The pane's verb reaches every machine of one writer** — and the
    /// single-record primitive is never what a surface presses (the census in
    /// `TripwireGrepTests` is the other half of this).
    func test_thepanesPermitChangeMovesEveryRecordUnderOneLabel() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        let herPhone = DeviceIdentity.softwareForTesting()
        try await writeStrangerFile(docId: try await docId(), opIds: ["02"])
        _ = try await store.admit(
            device: stranger.fingerprint, label: "Sam", ownName: "Sam’s Mac")
        _ = try await store.admit(
            device: herPhone.fingerprint, label: "Sam", ownName: "Sam’s iPhone")

        _ = try await store.changePermit(
            everyRecordOf: stranger.fingerprint, to: .reviewer)

        let registry = try self.registry()
        XCTAssertEqual(registry.person(stranger.fingerprint)?.role,
                       Permit.reviewerRole)
        XCTAssertEqual(registry.person(herPhone.fingerprint)?.role,
                       Permit.reviewerRole,
                       "her phone moved too, or she goes on writing from it")
    }

    // MARK: - The question reaches a window (fix round 1, C2)

    /// **A piece start is ANNOUNCED.** Before this the only trigger was the
    /// stranger narrowing, and a person who may write some of this book is not
    /// a stranger — so §4.5's question had no way of reaching a window
    /// mid-session at all, which is to say it was never shown to anybody.
    ///
    /// Asserted on the EVENT rather than on a mounted sheet (tripwire 33): the
    /// post is the wiring, and what the window then does with it is
    /// `LoadQuestions`', pinned without a window of its own.
    func test_aPieceStartAnnouncesItselfToTheWindow() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        let piece = try pieceIdFromManifest()
        try await writeStrangerFile(docId: piece, opIds: ["02"])
        _ = try await store.admit(
            device: stranger.fingerprint, label: "Sam", ownName: "Sam’s Mac",
            permit: PermitControl.permit(for: .somePieces, pieces: ["ch-A"]))

        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: Notification.Name.maughamAdmissionRequested, object: nil,
            queue: .main) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        // A load of the piece she opened: the walk stamps her on it, and
        // registering the finished load is what tells the window.
        let doc = try await Document.load(
            url: docURL, actor: .author, session: "s", presenter: nil)
        store.register(document: doc, for: "manuscript/c1.md")
        XCTAssertFalse(doc.startedAPiece.isEmpty, "the walk said so")
        XCTAssertEqual(posts, 1, "and the window was told once")

        // **A second load of the same document does not ask again.** The
        // memory is per (holder, piece) and is never emptied.
        store.register(document: doc, for: "manuscript/c1.md")
        XCTAssertEqual(posts, 1)
        await doc.close()
    }

    /// **A question the writer has already closed never posts.** *Not now* is
    /// remembered on this Mac for good; a load that finds the same held span
    /// says nothing about it.
    func test_aPieceQuestionPutOffIsNeverAnnouncedAgain() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        let piece = try pieceIdFromManifest()
        try await writeStrangerFile(docId: piece, opIds: ["02"])
        _ = try await store.admit(
            device: stranger.fingerprint, label: "Sam", ownName: "Sam’s Mac",
            permit: PermitControl.permit(for: .somePieces, pieces: ["ch-A"]))
        store.notNowAboutPiece(person: stranger.fingerprint, docId: piece)

        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: Notification.Name.maughamAdmissionRequested, object: nil,
            queue: .main) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        let doc = try await Document.load(
            url: docURL, actor: .author, session: "s", presenter: nil)
        store.register(document: doc, for: "manuscript/c1.md")
        XCTAssertFalse(doc.startedAPiece.isEmpty, "it is still held")
        XCTAssertEqual(posts, 0, "and the writer has already been asked")
        await doc.close()
    }

    // MARK: - §4.5's answer (Task 7 fix round 1, I1)

    /// **`pieceIsTheirs` ADDS a piece — it does not replace her scope.**
    ///
    /// The defect this pins is one line long and silent in the worst
    /// direction: building the new permit from `[docId]` alone rather than
    /// from what she already holds would answer *yes, this piece is hers* by
    /// taking every other piece away from her, and the writer pressed a button
    /// that said *Nothing else they may write changes*.
    func test_sayingAPieceIsTheirsAddsItToWhatTheyAlreadyHold() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        let piece = try await docId()
        try await writeStrangerFile(docId: piece, opIds: ["02"])
        _ = try await store.admit(
            device: stranger.fingerprint, label: "Sam", ownName: "Sam’s Mac",
            permit: PermitControl.permit(for: .somePieces, pieces: ["ch-A"]))

        _ = try await store.pieceIsTheirs(
            person: stranger.fingerprint, docId: piece)

        let record = try XCTUnwrap(registry().person(stranger.fingerprint))
        XCTAssertEqual(record.role, Permit.authorRole)
        XCTAssertEqual(record.scope, Permit.piecesScope)
        XCTAssertEqual(
            Set(record.pieces ?? []), ["ch-A", piece],
            "she keeps the piece she already had AND gains this one")
    }

    /// And it records the question ANSWERED on this Mac, so nothing puts it
    /// again — the signed event is what makes it true for the book; this is
    /// only what stops this window asking about what it has written down.
    func test_answeringThePieceQuestionClosesItOnThisMac() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        let piece = try await docId()
        try await writeStrangerFile(docId: piece, opIds: ["02"])
        _ = try await store.admit(
            device: stranger.fingerprint, label: "Sam", ownName: "Sam’s Mac",
            permit: PermitControl.permit(for: .somePieces, pieces: ["ch-A"]))
        XCTAssertTrue(store.closedPieceQuestions().isEmpty)

        _ = try await store.pieceIsTheirs(
            person: stranger.fingerprint, docId: piece)

        XCTAssertTrue(store.closedPieceQuestions().contains(
            .init(person: stranger.fingerprint, docId: piece)))
    }

    /// **Theirs brings her words in — the smoke's own route, end to end**
    /// (P3b smoke find F9). A stranger opens a piece and writes in it; the
    /// root lets her in as an author of a DIFFERENT piece, so the admission's
    /// mark names her line; the load asks *is it theirs?*; the writer answers
    /// Theirs; and the next load applies what she wrote. Before the fix the
    /// answer's event carried the admission's position forward over the
    /// settling cut and her line stayed held for good.
    func test_theirsBringsAStrangersHeldWordsIntoThePieceSheStarted() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        let piece = try pieceIdFromManifest()
        try await writeStrangerFile(docId: piece, opIds: ["herOpening"])
        _ = try await store.admit(
            device: stranger.fingerprint, label: "Sam", ownName: "Sam’s Mac",
            permit: PermitControl.permit(for: .somePieces, pieces: ["ch-A"]))

        let asked = try await Document.load(
            url: docURL, actor: .author, session: "s", presenter: nil)
        XCTAssertEqual(asked.startedAPiece, [stranger.fingerprint], "the question is put")
        XCTAssertFalse(asked.opLogSnapshot.contains { $0.opId == "herOpening" })
        await asked.close()

        _ = try await store.pieceIsTheirs(person: stranger.fingerprint, docId: piece)

        let answered = try await Document.load(
            url: docURL, actor: .author, session: "s", presenter: nil)
        defer { Task { await answered.close() } }
        XCTAssertTrue(
            answered.opLogSnapshot.contains { $0.opId == "herOpening" },
            "her words came in")
        XCTAssertTrue(answered.startedAPiece.isEmpty, "and nothing of hers is waiting")
    }

    /// **A reviewer is refused, and refused in the act's own words.** §4.5 can
    /// only hold a line for somebody who may already write SOME of this book,
    /// so a reviewer reaching this verb means the permit moved under the
    /// question — and answering it anyway would install a rung nobody chose.
    func test_sayingAPieceIsAReviewersIsRefused() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        let piece = try await docId()
        try await writeStrangerFile(docId: piece, opIds: ["02"])
        _ = try await store.admit(
            device: stranger.fingerprint, label: "Sam", ownName: "Sam’s Mac",
            permit: .reviewer)

        do {
            _ = try await store.pieceIsTheirs(
                person: stranger.fingerprint, docId: piece)
            XCTFail("a reviewer may write no piece of this book")
        } catch is PieceIsTheirsRefused {
            XCTAssertEqual(
                try registry().person(stranger.fingerprint)?.role,
                Permit.reviewerRole, "and nothing was changed")
        }
    }

    /// Somebody this book has never let in is refused too, by the registry's
    /// own word rather than by this verb's.
    func test_sayingAPieceIsAStrangersIsRefused() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        let piece = try await docId()

        do {
            _ = try await store.pieceIsTheirs(
                person: stranger.fingerprint, docId: piece)
            XCTFail("there is nobody here to give a piece to")
        } catch let error as RegistryAdmissionError {
            XCTAssertEqual(
                error, .notAdmitted(fingerprint: stranger.fingerprint))
        }
    }

    /// **Re-admission installs what the writer confirmed, not the default**
    /// (Task 4's review, the Critical). The pane reads her permit off her
    /// timeline and hands it back; `DocumentStore.admit`'s own default is the
    /// whole book, which is what she would silently have come back as.
    func test_areadmissionInstallsThePermitItIsGivenAndNotTheWholeBook() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        let piece = try await docId()
        try await writeStrangerFile(docId: piece, opIds: ["02"])
        _ = try await store.admit(
            device: stranger.fingerprint, label: "Sam", ownName: "Sam’s Mac",
            permit: .author(.pieces([piece])))
        _ = try await store.revoke(person: stranger.fingerprint)

        // What the pane reads off her timeline, which is what it proposes.
        let held = PermitTimeline(
            about: stranger.fingerprint, in: try registry()).current
        XCTAssertEqual(held, .author(.pieces([piece])))

        _ = try await store.admit(
            device: stranger.fingerprint, label: "Sam", ownName: "Sam’s Mac",
            permit: held)

        XCTAssertEqual(
            try registry().person(stranger.fingerprint).map(Permit.permit(recordedIn:)),
            .author(.pieces([piece])),
            "she comes back as what she was, never as an author of the novel")
        XCTAssertEqual(try events().last?.kind, .readmitted)
    }

    /// **Bringing a record up to its history writes no event and pays for
    /// nothing** — there is no permit change here, so no photograph and no
    /// gate are owed, and neither is taken.
    func test_theresignVerbWritesARecordAndNoEventAndGatesNothing() async throws {
        beThisMac()
        try manifestFromAnOlderBuild()
        let store = try await DocumentStore.open(url: projectURL)
        try await writeStrangerFile(docId: try await docId(), opIds: ["02"])
        _ = try await store.admit(
            device: stranger.fingerprint, label: "Sam", ownName: "Sam’s Mac")
        // Spec §3.2's crash window: the event landed, the record did not.
        try RegistryWriter.write(
            PermitEvent(
                event: PermitEvent.mintID(subject: stranger.fingerprint),
                kind: .roleChanged, subject: stranger.fingerprint,
                role: Permit.reviewerRole, scope: Permit.bookScope, pieces: [],
                mark: [:], at: Date(timeIntervalSince1970: 99),
                by: Document.loadIdentities.author.fingerprint),
            signedBy: Document.loadIdentities.author, in: projectURL)
        let before = try events().count
        let manifest = try manifestBytes()

        _ = try await store.resignRecord(person: stranger.fingerprint)

        XCTAssertEqual(
            try registry().person(stranger.fingerprint).map(Permit.permit(recordedIn:)),
            .reviewer)
        XCTAssertEqual(try events().count, before, "no event")
        XCTAssertEqual(try manifestBytes(), manifest,
                       "and no gate: nothing narrowed, so nothing is owed")
    }

    /// **F4's press, end to end.** The record on disk will not verify and this
    /// Mac holds no earlier bytes for it; afterwards the reader accepts it.
    func test_thismacWritesItsOwnDeviceRecordAgainThroughTheStore() async throws {
        let mine = beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        let ref = RecordRef(directory: .devices,
                            fingerprint: mine.author.fingerprint)
        let url = RegistryWriter.url(
            .devices, fingerprint: mine.author.fingerprint, in: projectURL)
        var object = try JSONSerialization.jsonObject(
            with: try Data(contentsOf: url)) as! [String: Any]
        object["name"] = "tampered"
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: url)
        XCTAssertFalse(try registry().malformed.isEmpty)

        _ = try await store.writeOwnRecordAgain(ref)

        XCTAssertTrue(try registry().malformed.isEmpty,
                      "the reader accepts it now")
        XCTAssertNotNil(try registry().devices
            .first { $0.device == mine.author.fingerprint })
    }

    /// And the reading both surfaces share: what a narrowing would cost this
    /// book, and which of its streams answer to no key.
    func test_theunsignedReadingNamesTheStreamNoKeyCanName() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        let piece = try await docId()
        // A file with a slug no device record names — the unsigned door's own
        // subject, and the one this Mac cannot attribute.
        let ghost = projectURL.appendingPathComponent(
            ".maugham/ops/\(piece).ghostmac-0badf00d.jsonl")
        try Data("{\"opId\":\"01\"}\n".utf8).write(to: ghost)

        let reading = await store.unsignedReading()

        XCTAssertNil(reading.refusal)
        XCTAssertFalse(reading.alreadyNarrowed)
        XCTAssertTrue(reading.holdsAnUnsignedStream)
        XCTAssertTrue(reading.streams.contains("ghostmac-0badf00d"),
                      "named by the SLUG, as the held-line door names it: "
                      + "\(reading.streams)")
        XCTAssertNil(reading.narrowedAt,
                     "nobody has been narrowed, so there is no day to date "
                     + "History's unsigned entry with")
    }

    /// **The cost rule, in both directions** (P3b Task 10). History draws an
    /// unsigned entry only in a narrowed book, so its read asks
    /// `onlyIfNarrowed` and an UN-narrowed book pays for no walk at all — while
    /// the sheet's and the pane's own read, whose whole sentence is about the
    /// book *before* its first narrowing, passes nothing and still gets the
    /// streams.
    func test_theNarrowedOnlyReadingWalksNothingInAnUnNarrowedBook() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        let piece = try await docId()
        let ghost = projectURL.appendingPathComponent(
            ".maugham/ops/\(piece).ghostmac-0badf00d.jsonl")
        try Data("{\"opId\":\"01\"}\n".utf8).write(to: ghost)

        let forHistory = await store.unsignedReading(onlyIfNarrowed: true)

        XCTAssertNil(forHistory.refusal)
        XCTAssertFalse(forHistory.alreadyNarrowed)
        XCTAssertTrue(forHistory.streams.isEmpty,
                      "the walk is not paid for where nothing can be drawn")
        XCTAssertNil(forHistory.narrowedAt)

        let forTheSheet = await store.unsignedReading()
        XCTAssertTrue(forTheSheet.streams.contains("ghostmac-0badf00d"),
                      "premise: the same folder, read the other way, sees it")
    }
}
