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
        let manifest = InboxManifest.inboxManifestURL(
            forDeviceSlug: DeviceSlug.make(from: "stranger-phone"), in: projectURL)
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
}
