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

    /// `writeStrangerFile` for any device — the I3 pair needs a SECOND
    /// machine of the same writer, with a file and a chain of its own.
    ///
    /// It APPENDS: the store chains from the head its own state remembers, so
    /// a second call adds lines after the first's seal rather than rewriting
    /// the file. That matters for a mark, which names a line by its hash.
    private func writeFile(
        docId: String, opIds: [String],
        by identity: DeviceIdentity, state: OpLogDeviceState
    ) async throws {
        let store = OpLogStore(
            projectURL: projectURL, identity: identity, state: state)
        for id in opIds {
            try await store.append(Op(
                opId: id, docId: docId, at: Date(timeIntervalSince1970: 0),
                device: identity.deviceId, session: "s", kind: .typingBurst,
                changes: [.init(paragraphId: "aaaa", prior: nil, next: id)],
                sequence: ["aaaa"]))
        }
        let sealed = try await store.sealChain(docId: docId)
        XCTAssertTrue(sealed, "the file is sealed")
    }

    private func registry() throws -> Registry {
        try RegistryReader.load(projectURL: projectURL)
    }

    /// A store that judges as THIS Mac does — the suite's injected identities,
    /// device state and registry memory, exactly as a load builds one
    /// (`Document.makeLoadOpStore`).
    ///
    /// A bare `OpLogStore(projectURL:)` takes `.current`, which on a test
    /// machine is nobody this fixture's registry names: `myRoot` resolves nil,
    /// every seal answers `.noChain`, and the file is applied as unsigned
    /// history — so an assertion that a revoked device's ops are APPLIED would
    /// pass whether or not re-admission works at all.
    private func reader() -> OpLogStore {
        Document.makeLoadOpStore(projectURL: projectURL, presenter: nil)
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

    // MARK: - A device that has only CAPTURED (whole-branch review, C1)

    /// The stranger's own capture stream: chained and sealed under a key
    /// nothing in this book names, written into `inbox.<slug>.jsonl` and into
    /// no chapter at all. This is the ordinary paired-release phone — the
    /// capture tab is its first one.
    private func writeStrangerCaptures(_ ids: [String]) async throws {
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".maugham/inbox"),
            withIntermediateDirectories: true)
        // **The slug is the device's own** (P3a Task 6). Every P1b-or-later
        // writer names its manifest off `identity.slug`, which is
        // `<actor>-<fingerprint…>`; a hand-built string here is a shape no
        // production device can produce, and under the permit check it is a
        // capture whose ACTOR cannot be named, which is held rather than
        // applied. A fixture made realistic — no assertion in this test moved.
        let manifest = InboxManifest.inboxManifestURL(
            forDeviceSlug: stranger.slug, in: projectURL)
        let store = JSONLAppendStore<InboxEntry>(
            fileURL: manifest,
            chain: ChainPolicy(
                identity: stranger, state: strangerState,
                docId: InboxManifest.chainDocId, projectURL: projectURL))
        for (index, id) in ids.enumerated() {
            try await store.append(InboxEntry(
                id: id, createdAt: Date(timeIntervalSince1970: 100 + Double(index)),
                deviceId: stranger.deviceId, kind: .text, inlineText: id))
        }
        try await store.appendSeal()
    }

    /// **A phone used only for capture can be admitted** — the seam between the
    /// inbox half (Task 7) and the sheet half (Task 1), which no per-task
    /// review could see.
    ///
    /// Before the fix, `AdmissionModifier.recompute` built its pending map from
    /// the open documents alone. This writer has no open document holding a
    /// line — their phone writes captures and nothing else — so the queue came
    /// back empty and all three *Admit…* controls did nothing: no sheet, no
    /// error, no log line, with the captures held and invisible.
    ///
    /// Pinned at the store's own seam rather than through a window, because
    /// that is where the defect was: `heldLinesByDevice` is the union both
    /// surfaces read, and `AdmissionDecision.requests` is the one authority on
    /// who is a stranger.
    func test_anInboxOnlyStrangerIsAskedAboutAndAdmitting_appliesItsCaptures() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        try await writeStrangerCaptures(["c1", "c2"])
        await store.inboxStore.refresh()

        XCTAssertTrue(store.allOpenDocuments().isEmpty,
                      "no chapter is open, and none of this writer's are holding a line")
        XCTAssertTrue(store.inboxStore.entries.isEmpty,
                      "held is not applied: \(store.inboxStore.entries.map(\.id))")

        let held = store.heldLinesByDevice()
        XCTAssertEqual(held[stranger.fingerprint], 2,
                       """
                       the window's union sees the capture stream as well as \
                       the open documents; built from the documents alone this \
                       was empty and every Admit… in the app was inert. Got \
                       \(held)
                       """)

        let verified = try TrustResolution.resolveVerified(
            projectURL: projectURL, identities: Document.loadIdentities, cache: cache)
        let requests = AdmissionDecision.requests(
            pending: held, registry: verified.registry,
            memory: memory.remembered, myRoot: verified.table.myRoot)
        XCTAssertEqual(requests.map(\.fingerprint), [stranger.fingerprint],
                       "so the sheet's queue has exactly this device in it")
        XCTAssertEqual(requests.first?.waitingCount, 2)

        _ = try await store.admit(
            device: stranger.fingerprint, label: "Denver", ownName: "Denver’s iPhone")
        await store.inboxStore.refresh()

        XCTAssertEqual(store.inboxStore.entries.map(\.id).sorted(), ["c1", "c2"],
                       "and Admit puts the writer's captures in the inbox")
        XCTAssertTrue(store.heldLinesByDevice().isEmpty,
                      "with nothing left waiting: \(store.heldLinesByDevice())")
    }

    /// **And the window's own queue is built from that union, not from the
    /// open documents** — the half the store test above cannot see, because
    /// `AdmissionModifier.recompute` is a private method of a `ViewModifier`.
    ///
    /// Read off the source rather than mounted (tripwire 33: no test presses a
    /// control and waits for its effect). The defect was one expression: a
    /// `reduce` over `allOpenDocuments()`'s provenance, with the capture stream
    /// nowhere in it.
    func test_theAdmissionQueueIsBuiltFromTheStoresUnionAndNotFromOpenDocumentsAlone() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Maugham/Views/AdmissionModifier.swift"),
            encoding: .utf8)

        XCTAssertTrue(
            source.contains("documentStore.heldLinesByDevice()"),
            "the queue reads the one union both surfaces read")
        XCTAssertFalse(
            source.contains("allOpenDocuments()"),
            """
            …and nothing here derives its own pending map from the open \
            documents. Built that way, a phone used only for capture produced \
            an empty queue and all three Admit… controls did nothing.
            """)
        XCTAssertTrue(
            source.contains("await documentStore.inboxStore.refresh()"),
            "and the writer's own press measures against a current count")
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

    // MARK: - What a revocation costs (find 5, ruled 2026-09-18)

    /// **The mark is taken over the whole project, not over what is open.**
    ///
    /// `highestOpIdSeen` is this Mac's record of how far it had got with that
    /// device, and a revocation now KEEPS everything at or below it. Computed
    /// over the open documents alone the mark is nil for a writer who revokes
    /// from Project Settings with no chapter open — which is the ordinary way
    /// to reach the button — and nil means *keep nothing*. Every paragraph that
    /// device ever contributed would leave the book, silently, in the
    /// gentlest-sounding of the two choices.
    /// **A revocation takes the words out of a chapter that is OPEN** (Denver's
    /// re-smoke, 2026-09-19), under either scope, and re-admission puts them
    /// back.
    ///
    /// Every verb before this one only ever ADDED: admission let a held span
    /// through, a peer's op synced in. So `handleExternalLogChange`'s echo guard
    /// asked *is there anything new* and returned when there was not — which is
    /// exactly what a revocation produces, a load that comes back SHORTER. The
    /// record was written, the `.lines` record filed in the same second, and the
    /// revoked device's paragraph stayed in the draft, in `displayText` and in
    /// the autosaved `.md` until the project was closed and reopened.
    private func revocationEmptiesAnOpenChapter(
        keeping scope: RevocationScope
    ) async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        let doc = try await openDocument()
        store.register(document: doc, for: "manuscript/c1.md")
        let docId = doc.docId
        let mine = doc.sequence
        await doc.close()

        try await writeStrangerParagraph(docId: docId, after: mine)
        _ = try await store.admit(
            device: stranger.fingerprint, label: "Denver", ownName: "Denver’s iPhone")

        let open = try await openDocument()
        store.register(document: open, for: "manuscript/c1.md")
        XCTAssertTrue(open.displayText.contains(Self.theirWords),
                      "premise: their paragraph is in the open chapter")

        _ = try await store.revoke(person: stranger.fingerprint, keeping: scope)

        XCTAssertFalse(
            open.opLogSnapshot.map(\.opId).contains(Self.theirOpId),
            "the live document is rebuilt from what the reader now keeps")
        XCTAssertFalse(open.displayText.contains(Self.theirWords),
                       "and the writer stops looking at words this book no longer applies")
        XCTAssertGreaterThan(open.provenance?.quarantinedLines ?? 0, 0,
                             "counted as refused, not silently absent")
        XCTAssertFalse(linesRecords(forDocId: docId).isEmpty, "and filed")

        _ = try await store.admit(
            device: stranger.fingerprint, label: "Denver", ownName: "Denver’s iPhone")

        XCTAssertTrue(open.displayText.contains(Self.theirWords),
                      "re-admission is revocation's inverse in the open document too")
        await open.close()
    }

    func test_atotalRevocationEmptiesAnOpenChapter() async throws {
        try await revocationEmptiesAnOpenChapter(keeping: .nothing)
    }

    /// **The gentle scope removes nothing from an open chapter, and cannot** —
    /// find 5's ruling, seen from the live document.
    ///
    /// The mark is the highest opId this Mac APPLIES from that device, taken
    /// over the whole project and over the open documents' own memory, so every
    /// applied op is at or below it by construction. There is no gentle
    /// revocation that takes a word off the screen; what it refuses is what
    /// arrives afterwards, which never enters the document at all.
    ///
    /// The pair matters: without this, the fix above could have been "rebuild
    /// on every revocation" and nobody would notice it was throwing away the
    /// writer's draft under the button that promises not to.
    func test_agentleRevocationLeavesWhatWasAlreadyAppliedOnScreen() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        let doc = try await openDocument()
        store.register(document: doc, for: "manuscript/c1.md")
        let docId = doc.docId
        let mine = doc.sequence
        await doc.close()
        try await writeStrangerParagraph(docId: docId, after: mine)
        _ = try await store.admit(
            device: stranger.fingerprint, label: "Denver", ownName: "Denver’s iPhone")

        let open = try await openDocument()
        store.register(document: open, for: "manuscript/c1.md")
        XCTAssertTrue(open.displayText.contains(Self.theirWords), "premise")

        let record = try await store.revoke(
            person: stranger.fingerprint, keeping: .whatWasApplied)

        XCTAssertEqual(record.highestOpIdSeen, Self.theirOpId,
                       "the mark is their newest applied op, so nothing of "
                           + "theirs is above it")
        XCTAssertTrue(open.displayText.contains(Self.theirWords),
                      "and their paragraph stays exactly where the writer has "
                          + "been reading it")
        XCTAssertEqual(open.provenance?.quarantinedLines, 0)
        await open.close()
    }

    /// The other half of the promise: a chapter the revoked device never wrote
    /// in is not disturbed at all — the guard still returns for it, so the
    /// writer's caret and their un-bursted words are where they left them.
    func test_achapterTheRevokedDeviceNeverWroteInIsLeftAlone() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        _ = try await store.admit(
            device: stranger.fingerprint, label: "Denver", ownName: "Denver’s iPhone")
        // Their work is somewhere else entirely.
        try await writeStrangerFile(docId: "doc-elsewhere", opIds: [
            "01K5Q8ZJ3M0000000000000009",
        ])

        let open = try await openDocument()
        store.register(document: open, for: "manuscript/c1.md")
        let before = open.displayText
        let mirrorBefore = open.opLogSnapshot.map(\.opId)

        _ = try await store.revoke(person: stranger.fingerprint, keeping: .nothing)

        XCTAssertEqual(open.displayText, before, "untouched")
        XCTAssertEqual(open.opLogSnapshot.map(\.opId), mirrorBefore)
        await open.close()
    }

    /// The revoked device's own paragraph, APPENDED to this document rather
    /// than replacing it: an op declares the whole sequence, so a fixture whose
    /// sequence names only its own paragraph would drop the writer's by
    /// last-writer-wins and prove nothing about a revocation. The op id sorts
    /// after anything minted today, so its sequence is the one that stands.
    private static let theirOpId = "01Z0Q8ZJ3M0000000000000009"
    private static let theirWords = "a sentence from their Mac"

    private func writeStrangerParagraph(docId: String, after mine: [String]) async throws {
        let store = OpLogStore(
            projectURL: projectURL, identity: stranger, state: strangerState)
        try await store.append(Op(
            opId: Self.theirOpId, docId: docId, at: Date(timeIntervalSince1970: 0),
            device: stranger.deviceId, session: "s", kind: .typingBurst,
            changes: [.init(paragraphId: "aaaa", prior: nil, next: Self.theirWords)],
            sequence: mine + ["aaaa"]))
        let sealed = try await store.sealChain(docId: docId)
        XCTAssertTrue(sealed)
    }

    private func linesRecords(forDocId docId: String) -> [QuarantineRecord] {
        OpLogQuarantine.records(forDocId: docId, in: projectURL)
            .filter { $0.kind == .lines }
    }

    func test_therevocationMarkIsTakenOverChaptersNobodyHasOpened() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        _ = try await store.admit(
            device: stranger.fingerprint, label: "Denver", ownName: "Denver’s iPhone")

        // Their work lives in a chapter this window has never opened.
        try await writeStrangerFile(docId: "doc-closed", opIds: [
            "01K5Q8ZJ3M0000000000000001", "01K5Q8ZJ3M0000000000000002",
        ])
        XCTAssertTrue(store.allOpenDocuments().isEmpty, "premise: nothing is open")

        let record = try await store.revoke(person: stranger.fingerprint)

        XCTAssertEqual(record.highestOpIdSeen, "01K5Q8ZJ3M0000000000000002",
                       "the highest op this Mac had applied from them, wherever it lives")

        let after = try await reader().loadDiagnosed(docId: "doc-closed")
        XCTAssertEqual(after.ops.map(\.opId),
                       ["01K5Q8ZJ3M0000000000000001", "01K5Q8ZJ3M0000000000000002"],
                       "and a revocation does not reach into a chapter to take back "
                           + "work that was already in it")
        XCTAssertEqual(after.provenance.quarantinedLines, 0)
    }

    /// **A gentle revocation of a device this book applies nothing from still
    /// records which button was pressed** (find-5 review, the High).
    ///
    /// Nil is the ONE wire spelling of *set aside everything it wrote*, and the
    /// gentle press used to write it whenever the sweep found nothing — so
    /// History narrated the writer's gentle choice as the harsh one and no
    /// later read could tell them apart. The lowest ULID keeps exactly nothing,
    /// which is the truth here, and leaves a mark on the record.
    func test_agentleRevocationOfADeviceWithNoAppliedWorkStillRecordsAMark() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        _ = try await store.admit(
            device: stranger.fingerprint, label: "Denver", ownName: "Denver’s iPhone")

        let record = try await store.revoke(person: stranger.fingerprint)

        XCTAssertEqual(record.highestOpIdSeen, RevocationScope.nothingAppliedMark)
        XCTAssertEqual(
            TrustEvents.derive(
                registry: try registry(), cache: cache,
                mine: Document.loadIdentities, for: projectURL)
                .first { $0.subject == stranger.fingerprint && $0.kind != .admitted }?.kind,
            .revoked,
            "History reads it as the plain revocation it was")
    }

    /// **The writer's other choice, and its way back.** A total revocation
    /// takes the whole history out of the book; re-admitting puts all of it
    /// back, and the set-aside sentence stops claiming what is applied again
    /// (find 7's rule, over find 5's records).
    func test_atotalRevocationSetsAsideEverythingAndReadmissionPutsItBack() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        _ = try await store.admit(
            device: stranger.fingerprint, label: "Denver", ownName: "Denver’s iPhone")
        try await writeStrangerFile(docId: "doc-closed", opIds: [
            "01K5Q8ZJ3M0000000000000001", "01K5Q8ZJ3M0000000000000002",
        ])

        let record = try await store.revoke(
            person: stranger.fingerprint, keeping: .nothing)
        XCTAssertNil(record.highestOpIdSeen,
                     "no mark is how the record says nothing of theirs stands")

        let revoked = try await reader().loadDiagnosed(docId: "doc-closed")
        XCTAssertEqual(revoked.ops, [], "every paragraph of theirs has left the book")
        let records = OpLogQuarantine.records(forDocId: "doc-closed", in: projectURL)
        XCTAssertEqual(records.count, 1, "one record, one cause")
        XCTAssertEqual(
            OpLogQuarantine.setAsideChangeCount(records: records, in: projectURL), 2,
            "and History counts their two changes")

        _ = try await store.admit(
            device: stranger.fingerprint, label: "Denver", ownName: "Denver’s iPhone")

        let readmitted = try await reader().loadDiagnosed(docId: "doc-closed")
        XCTAssertEqual(readmitted.ops.map(\.opId),
                       ["01K5Q8ZJ3M0000000000000001", "01K5Q8ZJ3M0000000000000002"],
                       "re-admission is revocation's inverse")
        XCTAssertEqual(
            OpLogQuarantine.setAsideChangeCount(
                records: OpLogQuarantine.records(forDocId: "doc-closed", in: projectURL),
                in: projectURL,
                applied: Set(readmitted.ops.map(\.opId))),
            0,
            "the records stay as evidence; the sentence stops counting them (find 7)")
    }

    // MARK: - A revocation decided on a partial reading (find-5 re-review)

    /// **One file this Mac cannot read, and the whole verb refuses** — end to
    /// end, through the production verb, over a real project.
    ///
    /// The sentence has been pinned since the High was fixed; the BEHAVIOUR
    /// behind it had not been, and the sentence is the half that cannot go
    /// wrong quietly. What can is this: the sweep that computes
    /// `highestOpIdSeen` reads every per-device file in the project, and a file
    /// it cannot read makes the answer SHORT. A short mark does not fail — it
    /// silently widens what the revocation takes back, and the shortest answer
    /// of all is indistinguishable from the writer having pressed the other
    /// button. So the verb throws, naming the file, and touches nothing.
    ///
    /// Four things are asserted because a refusal that half-happened is worse
    /// than either outcome: the error and its NAME, the person record standing
    /// exactly as it did, no `.lines` record minted, and the device still
    /// applying — the writer pressed a button, was told why it did not happen,
    /// and nothing about their book moved.
    func test_arevocationRefusesRatherThanDecideOnAFileItCannotRead() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        _ = try await store.admit(
            device: stranger.fingerprint, label: "Denver", ownName: "Denver’s iPhone")
        try await writeStrangerFile(docId: "doc-closed", opIds: [
            "01K5Q8ZJ3M0000000000000001", "01K5Q8ZJ3M0000000000000002",
        ])
        let before = try XCTUnwrap(try registry().person(stranger.fingerprint))

        // One op-log file made unreadable — present, so it is not simply
        // absent, and refusing rather than skipping is the whole rule.
        let unreadable = try XCTUnwrap(
            try FileManager.default
                .contentsOfDirectory(atPath: opsDirectory.path)
                .first { $0.hasPrefix("doc-closed") && $0.hasSuffix(".jsonl") })
        let url = opsDirectory.appendingPathComponent(unreadable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: url.path)
        }

        do {
            _ = try await store.revoke(person: stranger.fingerprint)
            XCTFail("a revocation decided on a partial reading is the thing this refuses")
        } catch let error as RegistryAdmissionError {
            XCTAssertEqual(error, .historyUnreadable(name: unreadable),
                           "it names the file, because *try again* is only "
                               + "actionable if the writer can tell what is wrong")
        }

        let after = try XCTUnwrap(try registry().person(stranger.fingerprint))
        XCTAssertEqual(after, before, "the person record is byte-for-byte what it was")
        XCTAssertNil(after.revokedAt, "nobody was revoked")
        XCTAssertNil(after.highestOpIdSeen, "and no mark was recorded")
        XCTAssertEqual(
            OpLogQuarantine.records(forDocId: "doc-closed", in: projectURL), [],
            "nothing was set aside")
    }

    /// The permissions are restored before the assertion above needs the file
    /// again — this is the CONTROL that the refusal was the unreadable file's
    /// doing and not something about the fixture: with the file readable, the
    /// very same press succeeds.
    func test_thesameRevocationSucceedsOnceTheFileCanBeRead() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        _ = try await store.admit(
            device: stranger.fingerprint, label: "Denver", ownName: "Denver’s iPhone")
        try await writeStrangerFile(docId: "doc-closed", opIds: [
            "01K5Q8ZJ3M0000000000000001", "01K5Q8ZJ3M0000000000000002",
        ])

        let record = try await store.revoke(person: stranger.fingerprint)

        XCTAssertEqual(record.highestOpIdSeen, "01K5Q8ZJ3M0000000000000002")
    }

    private var opsDirectory: URL {
        projectURL.appendingPathComponent(".maugham/ops")
    }

    // MARK: - The permit verb, through the window (P3a Task 7, spec §6)

    private func events(about subject: String) throws -> [PermitEvent] {
        try registry().events
            .filter { $0.subject == subject }
            .sorted { $0.event < $1.event }
    }

    /// **A demotion takes what she writes afterwards and leaves what she wrote
    /// before it**, on the store's own next read — both halves of spec §5
    /// through the one production door P3b's pane will press.
    ///
    /// The mark is computed here, off the project, which is what makes the
    /// *before* half true: it names the position her file had reached when the
    /// writer pressed the control.
    func test_ademotionTakesWhatComesAfterItAndLeavesWhatCameBefore() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        let doc = try await openDocument()
        let docId = doc.docId
        store.register(document: doc, for: "manuscript/c1.md")
        await doc.close()
        try await writeStrangerFile(docId: docId, opIds: ["02", "03"])
        _ = try await store.admit(
            device: stranger.fingerprint, label: "Sam", ownName: "Sam’s Mac")
        let open = try await openDocument()
        store.register(document: open, for: "manuscript/c1.md")
        let before = try await open.opStore.loadDiagnosed(docId: docId)
        XCTAssertTrue(before.ops.map(\.opId).contains("03"))

        _ = try await store.changePermit(person: stranger.fingerprint, to: .reviewer)
        try await writeStrangerFile(docId: docId, opIds: ["04"])

        let after = try await reader().loadDiagnosed(docId: docId)
        XCTAssertTrue(
            after.ops.map(\.opId).contains("03"),
            "what she wrote as an author stays in the book")
        XCTAssertFalse(
            after.ops.map(\.opId).contains("04"),
            "and her manuscript text after the mark does not")
        XCTAssertEqual(
            try events(about: stranger.fingerprint).map(\.kind),
            [.admitted, .roleChanged])
        await open.close()
    }

    /// The record follows the event, and the two agree afterwards — which is
    /// what `recordBehindEvents` is the detector for.
    func test_thepermitChangeWritesBothAndLeavesNothingBehind() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        _ = try await store.admit(
            device: stranger.fingerprint, label: "Sam", ownName: "Sam’s Mac")

        let record = try await store.changePermit(
            person: stranger.fingerprint, to: .author(.pieces(["d-one"])))

        XCTAssertEqual(record.role, Permit.authorRole)
        XCTAssertEqual(record.scope, Permit.piecesScope)
        XCTAssertEqual(record.pieces, ["d-one"])
        XCTAssertFalse(RegistryAdmission.recordBehindEvents(
            person: stranger.fingerprint, in: try registry()))
    }

    /// **No surface, and no permit change, from a Mac that is not the root** —
    /// the refusal is thrown rather than swallowed (RULING-7).
    func test_anonRootCannotChangeAPermitThroughTheWindowEither() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        _ = try await store.admit(
            device: stranger.fingerprint, label: "Sam", ownName: "Sam’s Mac")
        // This Mac's own root record, removed: it is now on nobody's chain.
        try FileManager.default.removeItem(
            at: RegistryWriter.url(
                .people,
                fingerprint: try XCTUnwrap(Document.localIdentitiesForTesting)
                    .author.fingerprint,
                in: projectURL))
        cache.forget(projectURL)

        do {
            _ = try await store.changePermit(
                person: stranger.fingerprint, to: .reviewer)
            XCTFail("a Mac on no chain here changes nobody's permit")
        } catch let error as RegistryAdmissionError {
            XCTAssertEqual(error, .notARoot)
        }
    }

    // MARK: - Every machine of one writer (fix round 1, I3)

    /// **A demotion reaches every record under one label.** A permit lives on
    /// a person RECORD and a record is one device; P2b's admission merges a
    /// typed label matching a known one under that label's own spelling, so
    /// Sam's Mac and Sam's phone are two records the root has said are one
    /// person. Moving one of them leaves her writing manuscript text from the
    /// other, applied by every reader, with nothing saying why.
    func test_ademotionReachesEveryMachineUnderOneLabel() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        let doc = try await openDocument()
        let docId = doc.docId
        store.register(document: doc, for: "manuscript/c1.md")
        await doc.close()

        let secondDevice = LocalIdentities.softwareForTesting()
        let second = secondDevice.author
        let secondState = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("second-state.json"))
        try await writeStrangerFile(docId: docId, opIds: ["02"])
        try await writeFile(
            docId: docId, opIds: ["03"], by: second, state: secondState)
        _ = try await store.admit(
            device: stranger.fingerprint, label: "Sam", ownName: "Sam’s Mac")
        _ = try await store.admit(
            device: second.fingerprint, label: "Sam", ownName: "Sam’s iPhone")
        // This Mac's own bootstrap op is in the document too; what these
        // assertions are about is the two machines' lines.
        let before = Set(try await reader().loadDiagnosed(docId: docId).ops.map(\.opId))
        XCTAssertTrue(before.isSuperset(of: ["02", "03"]))

        let moved = try await store.changePermit(
            everyRecordOf: stranger.fingerprint, to: .reviewer)

        XCTAssertEqual(
            Set(moved.map(\.person)), [stranger.fingerprint, second.fingerprint],
            "both machines moved, each with its own event")
        try await writeStrangerFile(docId: docId, opIds: ["04"])
        try await writeFile(
            docId: docId, opIds: ["05"], by: second, state: secondState)

        let after = Set(try await reader().loadDiagnosed(docId: docId).ops.map(\.opId))
        XCTAssertTrue(
            after.isSuperset(of: ["02", "03"]),
            "what each machine wrote as an author stays in the book")
        XCTAssertTrue(
            after.isDisjoint(with: ["04", "05"]),
            "and manuscript text from EITHER machine is refused after its own mark")
    }

    /// The up-front refusal: a label shared with the ROOT refuses the whole
    /// act rather than demoting the collaborator and stopping at the root.
    func test_thewholeActIsRefusedWhenOneRecordIsTheRoot() async throws {
        let mine = beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        // The root's own label, given to the stranger too — the state P2b's
        // *this is also…* produces when the writer merges a device under their
        // own name.
        let rootLabel = try XCTUnwrap(registry().person(mine.author.fingerprint)?.label)
        _ = try await store.admit(
            device: stranger.fingerprint, label: rootLabel, ownName: "Sam’s Mac")

        do {
            _ = try await store.changePermit(
                everyRecordOf: stranger.fingerprint, to: .reviewer)
            XCTFail("a set holding the root is refused entire")
        } catch let error as RegistryAdmissionError {
            XCTAssertEqual(
                error, .cannotChangeARoot(fingerprint: mine.author.fingerprint))
        }
        XCTAssertEqual(
            try registry().person(stranger.fingerprint)?.role, Permit.authorRole,
            "and nothing was half-applied")
    }

    /// **A sweep that came back short refuses, and writes nothing** (I2). The
    /// translations folder exists and will not list, so the positions this
    /// mark would record are a reading Maugham knows is incomplete — and a
    /// stream a mark does not name is judged wholly NEW.
    func test_apermitChangeRefusesOverAFolderItCannotList() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        _ = try await store.admit(
            device: stranger.fingerprint, label: "Sam", ownName: "Sam’s Mac")
        let translations = projectURL.appendingPathComponent(".maugham/translations")
        try FileManager.default.createDirectory(
            at: translations, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: translations.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: translations.path)
        }

        do {
            _ = try await store.changePermit(person: stranger.fingerprint, to: .reviewer)
            XCTFail("a short reading is a refusal, never a shorter mark")
        } catch let error as RegistryAdmissionError {
            guard case .historyUnreadable(let name, let act) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(name, ".maugham/translations")
            XCTAssertEqual(act, .permitChange, "and the sentence says which act")
        }
        XCTAssertEqual(
            try registry().person(stranger.fingerprint)?.role, Permit.authorRole)
        XCTAssertTrue(
            try registry().events.isEmpty || !registry().events.contains {
                $0.subject == stranger.fingerprint && $0.kind == .roleChanged
            },
            "no event, no record — nothing was changed")
    }

    // MARK: - P3a Task 9: a stream this Mac applied, missing at sweep time

    /// **A mark that does not NAME a stream judges every line of it new**, so a
    /// stream that is simply absent — iCloud has moved it, a sync is halfway
    /// through — would make a demotion reach back through the whole of it. This
    /// Mac remembers which streams it has applied, so the verb refuses by name
    /// and writes nothing (P3a Task 9, spec §4.7's second job).
    func test_apermitChangeRefusesOverAStreamThisMacHadApplied() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        let doc = try await openDocument()
        let docId = doc.docId
        store.register(document: doc, for: "manuscript/c1.md")
        await doc.close()
        try await writeStrangerFile(docId: docId, opIds: ["02", "03"])
        _ = try await store.admit(
            device: stranger.fingerprint, label: "Sam", ownName: "Sam’s Mac")
        // The read that REMEMBERS where her stream stood.
        let read = try await openDocument()
        let appliedIds = try await read.opStore.loadDiagnosed(docId: docId).ops.map(\.opId)
        XCTAssertTrue(
            appliedIds.contains("02"),
            "this Mac applied her lines, which is what makes the memory a fact")
        await read.close()

        let streamKey = try XCTUnwrap(PermitMark.streamKey(of: OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: stranger.slug, in: projectURL)))
        try FileManager.default.removeItem(at: OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: stranger.slug, in: projectURL))

        do {
            _ = try await store.changePermit(person: stranger.fingerprint, to: .reviewer)
            XCTFail("a stream this Mac had applied and cannot find is a refusal")
        } catch let error as RegistryAdmissionError {
            guard case .historyUnreadable(let name, let act) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(name, streamKey, "the refusal names the stream")
            XCTAssertEqual(act, .permitChange, "and the sentence says which act")
        }
        XCTAssertEqual(
            try registry().person(stranger.fingerprint)?.role, Permit.authorRole)
        XCTAssertFalse(
            try registry().events.contains {
                $0.subject == stranger.fingerprint && $0.kind == .roleChanged
            },
            "no event, no record — nothing was changed")
    }

    /// The same, for the act a short mark damages most: *revoke, keeping what
    /// this Mac had applied* would set aside words already in front of the
    /// writer.
    func test_arevocationRefusesOverAStreamThisMacHadApplied() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        let doc = try await openDocument()
        let docId = doc.docId
        store.register(document: doc, for: "manuscript/c1.md")
        await doc.close()
        try await writeStrangerFile(docId: docId, opIds: ["02"])
        _ = try await store.admit(
            device: stranger.fingerprint, label: "Sam", ownName: "Sam’s Mac")
        let read = try await openDocument()
        _ = try await read.opStore.loadDiagnosed(docId: docId)
        await read.close()
        try FileManager.default.removeItem(at: OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: stranger.slug, in: projectURL))

        do {
            _ = try await store.revoke(person: stranger.fingerprint)
            XCTFail("nothing is taken back on a reading this Mac knows is short")
        } catch let error as RegistryAdmissionError {
            guard case .historyUnreadable = error else { return XCTFail("\(error)") }
        }
        XCTAssertNil(
            try registry().person(stranger.fingerprint)?.revokedAt,
            "no record — nothing was changed")
    }

    /// **The other direction, and it is the point of the memory being of
    /// streams this Mac has READ.** A device whose file this Mac has never
    /// loaded is honest late sync: it is not expected, the sweep answers, and
    /// the verb goes through.
    func test_astreamThisMacNeverReadIsNotExpectedAndTheVerbGoesThrough() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        let doc = try await openDocument()
        let docId = doc.docId
        store.register(document: doc, for: "manuscript/c1.md")
        await doc.close()
        try await writeStrangerFile(docId: docId, opIds: ["02"])
        _ = try await store.admit(
            device: stranger.fingerprint, label: "Sam", ownName: "Sam’s Mac")
        // No load of the document since her file arrived, so nothing of hers
        // is remembered — and then it goes away again.
        try FileManager.default.removeItem(at: OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: stranger.slug, in: projectURL))

        _ = try await store.changePermit(person: stranger.fingerprint, to: .reviewer)
        XCTAssertEqual(
            try registry().person(stranger.fingerprint)?.role, Permit.reviewerRole)
    }

    /// **`retire` EXPECTS no stream, and that is a ruling rather than an
    /// oversight.** Its subject is THIS device, whose streams live in
    /// `OpLogDeviceState.heads` and never in the foreign memory, so the
    /// expected set is empty however much of its own history it has written —
    /// and a missing own file is simply an absent one, which nothing demands
    /// the sweep name. (A folder it cannot LIST is a different matter and
    /// refuses; fix round 2 made that rule the same for all four verbs, and its
    /// own test is below.)
    func test_retiringExpectsNoneOfItsOwnStreamsAndStillStandsTheMacDown() async throws {
        let mine = beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        let doc = try await openDocument()
        let docId = doc.docId
        store.register(document: doc, for: "manuscript/c1.md")
        try await doc.setFullText("Hello, and a second line.\n")
        await doc.close()
        XCTAssertTrue(
            DocumentStore.expectedStreams(
                ofDeviceIds: [mine.author.deviceId], in: projectURL,
                state: Document.loadDeviceState).isEmpty,
            "this device's own streams are `heads`' business, not this memory's")
        let ownFile = OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: mine.author.slug, in: projectURL)
        try? FileManager.default.removeItem(at: ownFile)

        let record = try await store.retire(device: mine.author.fingerprint)
        XCTAssertNotNil(record.retiredAt)
    }

    /// **A present, readable foreign file that answered NOTHING must not block
    /// the root for ever** (fix round 1's Important). A zero-byte `.jsonl` that
    /// synced ahead of its contents yields no line this Mac ever saw and no
    /// segment it took in whole, so `positions` names no such stream — and if
    /// the memory recorded it anyway, every verb of the root's would refuse
    /// against a name the sweep can never produce, over a file sitting there
    /// perfectly readable, with nothing the writer could do about it.
    func test_apresentFileThatAnsweredNothingDoesNotBlockThePermitVerbs() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        let doc = try await openDocument()
        let docId = doc.docId
        store.register(document: doc, for: "manuscript/c1.md")
        await doc.close()
        _ = try await store.admit(
            device: stranger.fingerprint, label: "Sam", ownName: "Sam\u{2019}s Mac")
        // Her file arrives with nothing in it yet, and this Mac reads the
        // chapter while it is like that.
        try Data().write(
            to: OpLogStore.opLogFileURL(
                forDocId: docId, deviceSlug: stranger.slug, in: projectURL),
            options: .atomic)
        let read = try await openDocument()
        _ = try await read.opStore.loadDiagnosed(docId: docId)
        await read.close()

        _ = try await store.changePermit(person: stranger.fingerprint, to: .reviewer)
        XCTAssertEqual(
            try registry().person(stranger.fingerprint)?.role, Permit.reviewerRole,
            "a file that told this Mac nothing is not a reason to refuse for ever")
    }

    /// **The plural verb sweeps every record BEFORE it writes any of them**
    /// (fix round 1, minor 2). A stream that has gone missing under the machine
    /// the loop reaches LAST is knowable up front, and a writer who is going to
    /// be refused should be refused with nothing changed rather than with two
    /// of three records already re-signed.
    func test_ademotionOfAWriterRefusesBeforeAnyRecordMovesWhenOneStreamIsGone()
        async throws
    {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        let doc = try await openDocument()
        let docId = doc.docId
        store.register(document: doc, for: "manuscript/c1.md")
        await doc.close()

        let secondDevice = LocalIdentities.softwareForTesting()
        let second = secondDevice.author
        let secondState = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("second-state.json"))
        let thirdDevice = LocalIdentities.softwareForTesting()
        let third = thirdDevice.author
        let thirdState = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("third-state.json"))
        try await writeStrangerFile(docId: docId, opIds: ["02"])
        try await writeFile(docId: docId, opIds: ["03"], by: second, state: secondState)
        try await writeFile(docId: docId, opIds: ["04"], by: third, state: thirdState)
        for (device, own) in [(stranger!, "Sam\u{2019}s Mac"), (second, "Sam\u{2019}s iPhone"),
                              (third, "Sam\u{2019}s iPad")] {
            _ = try await store.admit(
                device: device.fingerprint, label: "Sam", ownName: own)
        }
        // The read that remembers all three streams.
        let read = try await openDocument()
        _ = try await read.opStore.loadDiagnosed(docId: docId)
        await read.close()

        // Whichever of them the loop reaches LAST loses its file.
        let records = RegistryAdmission.records(
            sharingLabelWith: stranger.fingerprint, in: try registry())
        let last = try XCTUnwrap(records.last)
        let slug = try XCTUnwrap(
            [stranger!, second, third].first { $0.fingerprint == last.person }?.slug)
        try FileManager.default.removeItem(at: OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: slug, in: projectURL))

        do {
            _ = try await store.changePermit(
                everyRecordOf: stranger.fingerprint, to: .reviewer)
            XCTFail("a sweep that cannot answer refuses before anything is written")
        } catch let error as RegistryAdmissionError {
            guard case .historyUnreadable = error else { return XCTFail("\(error)") }
        }

        let after = try registry()
        XCTAssertTrue(
            after.people.allSatisfy { $0.role == nil || $0.role == Permit.authorRole },
            "no record moved")
        XCTAssertTrue(
            after.events.allSatisfy { $0.kind != .roleChanged },
            "and no event was written — not one, not two")
    }

    // MARK: - Fix round 2

    /// **A retirement refuses over a short reading too**, exactly as the other
    /// three marking verbs do. It used to record `.nothingApplied` and let the
    /// retirement through — and an empty mark calls EVERY paragraph that
    /// machine ever wrote *written while retired*, so P3b's *N paragraphs were
    /// written on it while retired* would offer the writer their whole history
    /// as something to bring back in.
    func test_aretirementRefusesOverAFolderItCannotList() async throws {
        let mine = beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        let translations = projectURL.appendingPathComponent(".maugham/translations")
        try FileManager.default.createDirectory(
            at: translations, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: translations.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: translations.path)
        }

        do {
            _ = try await store.retire(device: mine.author.fingerprint)
            XCTFail("a retirement decided on a partial reading marks everything")
        } catch let error as RegistryAdmissionError {
            guard case .historyUnreadable(let name, let act) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(name, ".maugham/translations")
            XCTAssertEqual(act, .retirement, "and the sentence says which act")
        }
        XCTAssertNil(
            try registry().devices.first { $0.device == mine.author.fingerprint }?.retiredAt,
            "nothing was changed")
        XCTAssertTrue(
            try registry().events.filter { $0.kind == .retired }.isEmpty,
            "and no event either")
    }

    /// The converse, so the refusal above is about the reading and not about
    /// retirement: with the folder readable the very same press succeeds and
    /// records a real mark.
    func test_thesameRetirementSucceedsOnceTheFolderCanBeListed() async throws {
        let mine = beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        let doc = try await openDocument()
        store.register(document: doc, for: "manuscript/c1.md")
        await doc.close()

        _ = try await store.retire(device: mine.author.fingerprint)

        let event = try XCTUnwrap(
            try registry().events.first { $0.kind == .retired })
        XCTAssertFalse(
            event.mark.isEmpty,
            "its own files' positions, which is what *written while retired* is "
                + "derived from")
    }

    /// **A revoked machine of the same writer is left out** (minor A). Its
    /// lines are refused by the VERDICT, which outranks any permit, so a
    /// `roleChanged` on its record would put *became a reviewer* in History
    /// after the revocation — about a machine already shut out.
    func test_ademotionSkipsARevokedMachineOfTheSameWriter() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        let secondDevice = LocalIdentities.softwareForTesting()
        let second = secondDevice.author
        _ = try await store.admit(
            device: stranger.fingerprint, label: "Sam", ownName: "Sam’s Mac")
        _ = try await store.admit(
            device: second.fingerprint, label: "Sam", ownName: "Sam’s old Mac")
        _ = try await store.revoke(person: second.fingerprint)

        let moved = try await store.changePermit(
            everyRecordOf: stranger.fingerprint, to: .reviewer)

        XCTAssertEqual(moved.map(\.person), [stranger.fingerprint])
        XCTAssertTrue(
            try registry().events.filter {
                $0.subject == second.fingerprint && $0.kind == .roleChanged
            }.isEmpty,
            "no *became a reviewer* row after a revocation")
        XCTAssertEqual(
            try registry().person(second.fingerprint)?.role, Permit.authorRole,
            "and its record was not re-signed for nothing")
    }

    /// And the other side of the same rule: a RETIRED machine IS included,
    /// because its pre-retirement lines are still judged by permit.
    func test_ademotionReachesARetiredMachineOfTheSameWriter() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        let secondDevice = LocalIdentities.softwareForTesting()
        let second = secondDevice.author
        _ = try await store.admit(
            device: stranger.fingerprint, label: "Sam", ownName: "Sam’s Mac")
        _ = try await store.admit(
            device: second.fingerprint, label: "Sam", ownName: "Sam’s old Mac")
        // `admit` writes a PERSON record; a device's own record is its own to
        // write, and a retirement edits that one.
        try RegistryWriter.write(
            DeviceRecord(
                device: second.fingerprint, name: "Sam’s old Mac", kind: .mac,
                actors: [DeviceActor.author.rawValue: second.fingerprint],
                madeAt: Date(timeIntervalSince1970: 5)),
            signedBy: second, in: projectURL)
        // The device retires ITSELF — the one registry verb nobody else can
        // perform on your behalf.
        try RegistryWriter.resign(
            try XCTUnwrap(try registry().devices.first { $0.device == second.fingerprint }),
            signedBy: second, in: projectURL
        ) { object in
            object["retiredAt"] = try RegistryCanonical.dateString(
                Date(timeIntervalSince1970: 500))
        }

        let moved = try await store.changePermit(
            everyRecordOf: stranger.fingerprint, to: .reviewer)

        XCTAssertEqual(
            Set(moved.map(\.person)), [stranger.fingerprint, second.fingerprint])
        XCTAssertEqual(
            try registry().person(second.fingerprint)?.role, Permit.reviewerRole)
    }

    /// A revoked SUBJECT refuses rather than quietly doing nothing — the loop
    /// would otherwise skip her own record and the pane would draw the old
    /// permit with no sentence saying why.
    func test_ademotionOfARevokedPersonRefuses() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        _ = try await store.admit(
            device: stranger.fingerprint, label: "Sam", ownName: "Sam’s Mac")
        _ = try await store.revoke(person: stranger.fingerprint)

        do {
            _ = try await store.changePermit(
                everyRecordOf: stranger.fingerprint, to: .reviewer)
            XCTFail("re-admit her first; a re-admission carries its own permit")
        } catch let error as RegistryAdmissionError {
            XCTAssertEqual(error, .notAdmitted(fingerprint: stranger.fingerprint))
        }
    }

    /// **The open-time silent admission signs the SAME mark the mid-session
    /// one does.** `DocumentStore.open` called `admitRemembered` with no mark
    /// closure, so the event it signed carried an empty mark — *everything
    /// after the beginning* — while the identical act performed a minute later
    /// carried a swept one.
    func test_theOpenTimeSilentAdmissionCarriesTheSweptMark() async throws {
        beThisMac()
        // A first open, so this Mac is the root and the document exists.
        let store = try await DocumentStore.open(url: projectURL)
        let doc = try await openDocument()
        let docId = doc.docId
        store.register(document: doc, for: "manuscript/c1.md")
        await doc.close()
        try await writeStrangerFile(docId: docId, opIds: ["02", "03"])
        memory.remember(
            stranger.fingerprint, label: "Sam", ownName: "Sam’s Mac")
        try RegistryWriter.write(
            DeviceRecord(
                device: stranger.fingerprint, name: "Sam’s Mac", kind: .mac,
                actors: [DeviceActor.author.rawValue: stranger.fingerprint],
                madeAt: Date(timeIntervalSince1970: 5)),
            signedBy: stranger, in: projectURL)

        _ = try await DocumentStore.open(url: projectURL)

        let event = try XCTUnwrap(
            try registry().events.first { $0.subject == stranger.fingerprint })
        XCTAssertEqual(event.kind, .silentlyAdmitted)
        XCTAssertFalse(
            event.mark.isEmpty,
            "the open swept her streams, exactly as the mid-session path does")
        let key = try XCTUnwrap(PermitMark.streamKey(of: OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: stranger.slug, in: projectURL)))
        XCTAssertNotNil(event.mark[key]?.line, "and named the stream it read")
    }

    // MARK: - The fourth act (P3a Task 10, from Task 7's fix-round-2 carry)

    /// **An admission refuses over a short reading too, and says so in its own
    /// words** — the last of the four acts that compute a mark.
    ///
    /// Three of them were pinned when the `Act` vocabulary landed (a
    /// revocation's is the default, a permit change's and a retirement's have
    /// tests of their own) and this one was not, which left the sentence a
    /// writer sees after pressing **Admit…** unguarded: the arm that produces
    /// it is one `act:` label away from telling them *a revocation* was
    /// refused.
    ///
    /// The refusal itself matters as much as its wording. An admission's mark
    /// is where the new permit STARTS, so one recorded over a folder that
    /// would not list is a demotion at the door, reaching back through
    /// everything that person ever wrote.
    func test_anadmissionRefusesOverAFolderItCannotListAndNamesItsOwnAct() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        let translations = projectURL.appendingPathComponent(".maugham/translations")
        try FileManager.default.createDirectory(
            at: translations, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: translations.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: translations.path)
        }

        do {
            _ = try await store.admit(
                device: stranger.fingerprint, label: "Sam", ownName: "Sam’s Mac")
            XCTFail("an admission decided on a partial reading puts everything "
                    + "she ever wrote under the permit she is let in with")
        } catch let error as RegistryAdmissionError {
            guard case .historyUnreadable(let name, let act) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(name, ".maugham/translations")
            XCTAssertEqual(act, .admission, "and the sentence says which act")
        }

        XCTAssertNil(try registry().person(stranger.fingerprint),
                     "nobody was admitted")
        XCTAssertTrue(try registry().events.isEmpty,
                      "and no event was written")
    }

    /// The control, so the refusal above is about the reading and not about
    /// admission: with the folder readable the very same press succeeds.
    func test_thesameAdmissionSucceedsOnceTheFolderCanBeListed() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".maugham/translations"),
            withIntermediateDirectories: true)

        let record = try await store.admit(
            device: stranger.fingerprint, label: "Sam", ownName: "Sam’s Mac")

        XCTAssertEqual(record.person, stranger.fingerprint)
    }
}
