// MaughamTests/Stores/RegistryArrivalTests.swift
import XCTest
@testable import MaughamCore
@testable import Maugham

/// **A record that syncs in AFTER the lines it vouches for re-judges them**
/// (P3b review, Important #1).
///
/// iCloud delivers files in no promised order. On the receiving Mac an op line
/// can land before the device record that names its key; the line is held as a
/// stranger's, and until this route existed a registry file change was an
/// `.unknownSidecar` to the presenter — nothing re-read, and the line stayed
/// held until another op landed or the book was reopened. These tests deliver
/// the two files in that order, through the presenter's own entry point, and
/// assert the line applies with no reopen; and that this Mac's OWN writes to
/// its record re-judge nothing.
@MainActor
final class RegistryArrivalTests: XCTestCase {

    private var projectURL: URL!
    private var ren: LocalIdentities!
    private var renState: OpLogDeviceState!

    override func setUp() async throws {
        let (dir, _) = try makeTestProject(prefix: "REGARRIVE", initialMd: "Hello.\n")
        projectURL = dir
        ren = .softwareForTesting()
        renState = OpLogDeviceState(fileURL: dir.appendingPathComponent("ren-state.json"))
        Document.registryCacheForTesting = RegistryCache(
            fileURL: dir.appendingPathComponent("registry-cache.json"), identity: "test")
        Document.admissionMemoryForTesting = AdmissionMemory(
            fileURL: dir.appendingPathComponent("admission-memory.json"), identity: "test")
        Document.localIdentitiesForTesting = LocalIdentities.forTesting(
            author: .softwareForTesting())
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: dir.appendingPathComponent("op-log-state.json"))
    }

    override func tearDown() async throws {
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        if let projectURL { try? FileManager.default.removeItem(at: projectURL) }
    }

    private var docURL: URL { projectURL.appendingPathComponent("manuscript/c1.md") }

    // MARK: - The ordered delivery

    /// **The op file first, the record second — and the line applies without a
    /// reopen.** Ren is admitted; her Mac has not declared itself here yet, so
    /// the note her Claude writes is signed by a key no record names and is
    /// HELD. Then her device record syncs in, naming that key, and the
    /// presenter's registry route re-judges the open document.
    func test_aRecordArrivingAfterItsLineAppliesTheLineWithNoReopen() async throws {
        let store = try await DocumentStore.open(url: projectURL)
        let doc = try await Document.load(
            url: docURL, actor: .author, session: "s", presenter: nil)
        store.register(document: doc, for: "manuscript/c1.md")
        _ = try await store.admit(
            device: ren.author.fingerprint, label: "Ren", ownName: "Ren’s Mac")

        // Ren's note, signed and sealed by her assistant key. Her Mac has no
        // record in this book, so nothing declares the key first.
        let rens = OpLogStore(projectURL: projectURL, identities: ren, state: renState)
        try await rens.append(Op(
            opId: "note01", docId: doc.docId, at: Date(timeIntervalSince1970: 0),
            device: ren.assistant.deviceId, session: "s", kind: .claudeComment,
            changes: [.init(paragraphId: "aaaa", prior: nil, next: "note01")],
            sequence: ["aaaa"]))
        try await rens.sealChain(docId: doc.docId)
        let opFile = OpLogStore.opLogFileURL(
            forDocId: doc.docId, deviceSlug: ren.assistant.slug, in: projectURL)
        store.presenterDidChangeSubitem(at: opFile)
        try await doc.handleExternalLogChange()
        XCTAssertGreaterThan(doc.provenance?.pendingLines ?? 0, 0,
                             "precondition: the line arrived first and is held")

        // The record arrives second.
        let recordFile = try XCTUnwrap(try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: ren, name: "Ren’s Mac", kind: .mac))
        store.presenterDidChangeSubitem(at: recordFile)
        await store.flushRegistryChangeForTesting()

        XCTAssertEqual(doc.provenance?.pendingLines, 0,
                       "the open document re-judged the line when its record landed")
        XCTAssertEqual(store.registrySettlesForTesting, 1)
        await doc.close()
    }

    // MARK: - F10: a stranger's record raises the question on arrival

    /// Verified reads the refresh below has paid for.
    private var resolves = 0
    /// Inbox recounts it has paid for.
    private var recounts = 0

    /// `AdmissionModifier.recompute`'s refresh, wired as it wires it — the
    /// window's half cannot be mounted here, and the decision it makes is this
    /// call over this store, the real folder listing, the real silent admission
    /// and the real verified read. `resolves` counts the last.
    private func refreshAfterTheSettle(_ store: DocumentStore) async -> [AdmissionRequest]? {
        let url = projectURL!
        let identities = Document.loadIdentities
        let cache = Document.loadRegistryCache
        let me = identities.author.fingerprint
        return await AdmissionDecision.refreshedRequests(
            cause: .settle,
            heldLines: { store.heldLinesByDevice() },
            heldStreams: { store.heldLines().streams },
            arrivedDevices: {
                AdmissionDecision.devicesWithNoPersonRecord(in: url, excluding: me)
            },
            recountCaptures: {
                self.recounts += 1
                await store.inboxStore.refresh()
            },
            thisDevice: me,
            memory: Document.loadAdmissionMemory.remembered,
            admitRemembered: { _ = await store.admitRemembered() },
            resolve: {
                self.resolves += 1
                guard let verified = try? TrustResolution.resolveVerified(
                    projectURL: url, identities: identities, cache: cache)
                else { return nil }
                return (verified.registry, AdmissionDecision.askingRoot(
                    in: verified.registry, thisDevice: me))
            })
    }

    /// Ren's sealed author lines in the open chapter, held because nothing in
    /// this book names her key.
    private func rensLinesArrive(in doc: Document, at store: DocumentStore) async throws {
        let rens = OpLogStore(projectURL: projectURL, identities: ren, state: renState)
        try await rens.append(Op(
            opId: "ren01", docId: doc.docId, at: Date(timeIntervalSince1970: 0),
            device: ren.author.deviceId, session: "s", kind: .typingBurst,
            changes: [.init(paragraphId: "aaaa", prior: nil, next: "ren01")],
            sequence: ["aaaa"]))
        try await rens.sealChain(docId: doc.docId)
        let opFile = OpLogStore.opLogFileURL(
            forDocId: doc.docId, deviceSlug: ren.author.slug, in: projectURL)
        store.presenterDidChangeSubitem(at: opFile)
        try await doc.handleExternalLogChange()
        XCTAssertGreaterThan(
            store.heldLinesByDevice()[ren.author.fingerprint] ?? 0, 0,
            "precondition: her lines are held in the open chapter")
    }

    /// Somebody else's book, with THIS Mac admitted into it: `theirs` is the
    /// root, written before this Mac ever opens, so `ensureRootIfEmpty` finds
    /// people and writes nothing.
    private func beAdmittedIntoSomebodyElsesBook() throws {
        let theirs = DeviceIdentity.softwareForTesting()
        try RegistryWriter.write(
            PersonRecord(
                person: theirs.fingerprint, label: "Amelia", ownName: "Amelia’s Mac",
                admittedAt: Date(timeIntervalSince1970: 10),
                admittedBy: theirs.fingerprint),
            signedBy: theirs, in: projectURL)
        let scratch = projectURL.appendingPathComponent("theirs", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        _ = try RegistryAdmission.admit(
            device: Document.loadIdentities.author.fingerprint,
            label: "Denver", ownName: "Denver’s Mac",
            in: projectURL, by: theirs,
            cache: RegistryCache(
                fileURL: scratch.appendingPathComponent("cache.json"), identity: "theirs"),
            memory: AdmissionMemory(
                fileURL: scratch.appendingPathComponent("memory.json"), identity: "theirs"))
    }

    private func rensRecordArrives(at store: DocumentStore) async throws {
        let recordFile = try XCTUnwrap(try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: ren, name: "Ren’s Mac", kind: .mac))
        store.presenterDidChangeSubitem(at: recordFile)
        await store.flushRegistryChangeForTesting()
    }

    /// **The ruling, on disk** (Denver, 2026-09-24): Ren's Mac declares itself
    /// in this book and nothing of hers has reached this Mac. The arrival
    /// settles — the event the window's queue is re-derived on — and the
    /// refresh that follows asks about her, with nothing waiting.
    func test_aStrangersRecordArrivingWithNoLinesRaisesTheQuestion() async throws {
        let store = try await DocumentStore.open(url: projectURL)
        XCTAssertEqual(store.heldLinesByDevice(), [:], "precondition: nothing of hers is held")

        try await rensRecordArrives(at: store)

        XCTAssertEqual(store.registrySettlesForTesting, 1,
                       "her record is not an echo, so it settles and the window re-derives")
        let requests = await refreshAfterTheSettle(store)
        XCTAssertEqual(requests?.map(\.fingerprint), [ren.author.fingerprint])
        XCTAssertEqual(requests?.first?.ownName, "Ren’s Mac")
        XCTAssertEqual(requests?.first?.waitingCount, 0)
        XCTAssertEqual(requests?.first.map(AdmissionSheet.waitingLine(for:)),
                       "Nothing from it has reached this Mac yet.")
    }

    // MARK: Ruling AA — only a root is asked, record-only or with lines

    func test_theRootIsAskedAboutAStrangerWhoseLinesAreHeldInAnOpenChapter() async throws {
        let store = try await DocumentStore.open(url: projectURL)
        let doc = try await Document.load(
            url: docURL, actor: .author, session: "s", presenter: nil)
        store.register(document: doc, for: "manuscript/c1.md")

        try await rensLinesArrive(in: doc, at: store)
        let requests = await refreshAfterTheSettle(store)

        XCTAssertEqual(requests?.map(\.fingerprint), [ren.author.fingerprint])
        XCTAssertGreaterThan(requests?.first?.waitingCount ?? 0, 0)
        await doc.close()
    }

    func test_anAdmittedMacIsNotAskedAboutARecordOnlyStranger() async throws {
        try beAdmittedIntoSomebodyElsesBook()
        let store = try await DocumentStore.open(url: projectURL)

        try await rensRecordArrives(at: store)
        let requests = await refreshAfterTheSettle(store)

        XCTAssertEqual(requests, [],
                       "this Mac was let in, holds no root record, and cannot let anybody in")
        XCTAssertEqual(store.registrySettlesForTesting, 1,
                       "the premise: her record arrived and settled here too")
    }

    func test_anAdmittedMacIsNotAskedAboutAStrangerWithLinesInAnOpenChapter() async throws {
        try beAdmittedIntoSomebodyElsesBook()
        let store = try await DocumentStore.open(url: projectURL)
        let doc = try await Document.load(
            url: docURL, actor: .author, session: "s", presenter: nil)
        store.register(document: doc, for: "manuscript/c1.md")

        try await rensLinesArrive(in: doc, at: store)
        let requests = await refreshAfterTheSettle(store)

        XCTAssertEqual(requests, [])
        await doc.close()
    }

    // MARK: Ruling AB — a retired record is not waiting

    private func rensRetiredRecordArrives(at store: DocumentStore) async throws {
        _ = try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: ren, name: "Ren’s old Mac", kind: .mac)
        let scratch = projectURL.appendingPathComponent("ren", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let record = try RegistryAdmission.retire(
            device: ren.author.fingerprint, in: projectURL, by: ren.author,
            cache: RegistryCache(
                fileURL: scratch.appendingPathComponent("cache.json"), identity: "ren"))
        XCTAssertNotNil(record.retiredAt, "precondition: the record says it retired")
        store.presenterDidChangeSubitem(
            at: RegistryWriter.url(.devices, fingerprint: ren.author.fingerprint,
                                   in: projectURL))
        await store.flushRegistryChangeForTesting()
    }

    func test_aRetiredRecordIsNotWaitingInThePreCheck() async throws {
        let store = try await DocumentStore.open(url: projectURL)
        try await rensRetiredRecordArrives(at: store)

        XCTAssertEqual(AdmissionDecision.devicesWithNoPersonRecord(
            in: projectURL, excluding: Document.loadIdentities.author.fingerprint), [])
        let requests = await refreshAfterTheSettle(store)
        XCTAssertEqual(requests, [])
        XCTAssertEqual(resolves, 0, "a retired machine costs no verified read")
        XCTAssertEqual(recounts, 0)
    }

    /// And a retired machine this Mac once named is not let in mid-session by
    /// its record's arrival — the record arm of the silent admission never
    /// sees it.
    func test_aRememberedRetiredRecordIsNotSilentlyAdmittedMidSession() async throws {
        let store = try await DocumentStore.open(url: projectURL)
        Document.loadAdmissionMemory.remember(
            ren.author.fingerprint, label: "Ren", ownName: "Ren’s old Mac")
        try await rensRetiredRecordArrives(at: store)

        let requests = await refreshAfterTheSettle(store)

        XCTAssertEqual(requests, [])
        let registry = try TrustResolution.resolveVerified(
            projectURL: projectURL, identities: Document.loadIdentities,
            cache: Document.loadRegistryCache).registry
        XCTAssertNil(registry.person(ren.author.fingerprint),
                     "nobody was let in")
    }

    /// **And not at the next OPEN either** (P3c whole-branch fix wave, I2):
    /// `DocumentStore.open` walks the silent admission directly, and it must
    /// give the mid-session answer — one question, one answer, whichever event
    /// comes first. Pinned through the real open.
    func test_aRememberedRetiredRecordIsNotSilentlyAdmittedAtOpen() async throws {
        let store = try await DocumentStore.open(url: projectURL)
        Document.loadAdmissionMemory.remember(
            ren.author.fingerprint, label: "Ren", ownName: "Ren’s old Mac")
        try await rensRetiredRecordArrives(at: store)

        _ = try await DocumentStore.open(url: projectURL)

        let registry = try TrustResolution.resolveVerified(
            projectURL: projectURL, identities: Document.loadIdentities,
            cache: Document.loadRegistryCache).registry
        XCTAssertNil(registry.person(ren.author.fingerprint),
                     "the open let nobody in")
    }

    /// **A machine this Mac has named before joins on its record's arrival,
    /// silently** — nothing of it is held, and no sheet is put up.
    func test_aRememberedMachinesRecordArrivingIsAdmittedWithNoSheet() async throws {
        let store = try await DocumentStore.open(url: projectURL)
        Document.loadAdmissionMemory.remember(
            ren.author.fingerprint, label: "Ren", ownName: "Ren’s Mac")

        try await rensRecordArrives(at: store)
        let requests = await refreshAfterTheSettle(store)

        XCTAssertEqual(requests, [], "no sheet")
        let registry = try TrustResolution.resolveVerified(
            projectURL: projectURL, identities: Document.loadIdentities,
            cache: Document.loadRegistryCache).registry
        XCTAssertEqual(registry.person(ren.author.fingerprint)?.label, "Ren",
                       "she was let in under the label this Mac gave her before")
        XCTAssertEqual(resolves, 0,
                       "and with nobody left to ask about, no verified read was paid for")
    }

    /// **A book of admitted people pays for no verified read** on a settle:
    /// every device file has a person file beside it, and the folder listing
    /// is the whole of the cost.
    func test_aBookOfAdmittedPeopleResolvesNothingOnASettle() async throws {
        let store = try await DocumentStore.open(url: projectURL)
        _ = try await store.admit(
            device: ren.author.fingerprint, label: "Ren", ownName: "Ren’s Mac")
        try await rensRecordArrives(at: store)

        let requests = await refreshAfterTheSettle(store)

        XCTAssertEqual(requests, [])
        XCTAssertEqual(resolves, 0, "zero verified resolves")
    }

    /// The pre-check reads NAMES: a device file with no person file beside it,
    /// never this Mac's own, never a record's contents.
    func test_thePreCheckListsDevicesWithNoPersonFileAndLeavesThisMacOut() async throws {
        _ = try await DocumentStore.open(url: projectURL)
        let me = Document.loadIdentities.author.fingerprint
        XCTAssertEqual(AdmissionDecision.devicesWithNoPersonRecord(
            in: projectURL, excluding: me), [],
            "this Mac is the root: its device file has its person file beside it")

        _ = try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: ren, name: "Ren’s Mac", kind: .mac)
        XCTAssertEqual(AdmissionDecision.devicesWithNoPersonRecord(
            in: projectURL, excluding: me), [ren.author.fingerprint])
        XCTAssertEqual(AdmissionDecision.devicesWithNoPersonRecord(
            in: projectURL, excluding: ren.author.fingerprint), [],
            "a Mac's own record is never somebody to look for")

        // Unverified on purpose: a file that is not a record at all is still
        // a name, and the verified read — not this listing — refuses it.
        let bogus = RegistryWriter.directoryURL(.devices, in: projectURL)
            .appendingPathComponent("abcd1234.json")
        try Data("not a record".utf8).write(to: bogus)
        XCTAssertTrue(AdmissionDecision.devicesWithNoPersonRecord(
            in: projectURL, excluding: me).contains("abcd1234"))
    }

    // MARK: - Echoes

    /// **This Mac re-signing its own record re-judges nothing.** The mid-session
    /// declaration (F6) rewrites exactly this file, and it moves no verdict
    /// here: this device's keys read as its own whatever its record says.
    func test_thisMacsOwnRecordChangingIsAnEchoAndSettlesNothing() async throws {
        let store = try await DocumentStore.open(url: projectURL)
        let recordFile = try XCTUnwrap(try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: Document.loadIdentities,
            name: "A renamed Mac", kind: .mac))

        store.presenterDidChangeSubitem(at: recordFile)
        await store.flushRegistryChangeForTesting()

        XCTAssertEqual(store.registrySettlesForTesting, 0)
    }

    /// And a verb of this Mac's own that writes somebody else's record —
    /// admission — settles itself, so its callback finds nothing new.
    func test_thisMacsOwnAdmissionIsAnEchoAndSettlesNothingMore() async throws {
        let store = try await DocumentStore.open(url: projectURL)
        _ = try await store.admit(
            device: ren.author.fingerprint, label: "Ren", ownName: "Ren’s Mac")

        store.presenterDidChangeSubitem(
            at: RegistryWriter.url(.people, fingerprint: ren.author.fingerprint,
                                   in: projectURL))
        await store.flushRegistryChangeForTesting()

        XCTAssertEqual(store.registrySettlesForTesting, 0)
    }

    // MARK: - The decision, both directions

    func test_onlyThisDevicesOwnDeviceRecordChangingIsAnEcho() {
        let me = "aaaa"
        let mine = "\(RegistryDirectory.devices.rawValue)/\(me).json"
        let theirs = "\(RegistryDirectory.devices.rawValue)/bbbb.json"
        let person = "\(RegistryDirectory.people.rawValue)/\(me).json"

        XCTAssertTrue(DocumentStore.registryChangeIsAnEcho(
            before: [mine: "1"], after: [mine: "1"], myDevice: me), "no change")
        XCTAssertTrue(DocumentStore.registryChangeIsAnEcho(
            before: [mine: "1"], after: [mine: "2"], myDevice: me), "my own record")
        XCTAssertFalse(DocumentStore.registryChangeIsAnEcho(
            before: [mine: "1"], after: [mine: "1", theirs: "1"], myDevice: me),
            "another device's record arriving")
        XCTAssertFalse(DocumentStore.registryChangeIsAnEcho(
            before: [mine: "1", person: "1"], after: [mine: "2", person: "2"],
            myDevice: me),
            "my PERSON record moving is somebody's admission, not an echo")
        XCTAssertFalse(DocumentStore.registryChangeIsAnEcho(
            before: [mine: "1", theirs: "1"], after: [mine: "1"], myDevice: me),
            "a record disappearing")
    }

    // MARK: - Classification

    /// Every registry folder routes as `.registry`, asked of the one function
    /// that spells them (tripwire 40).
    func test_everyRegistryFolderIsClassifiedAsTheRegistry() {
        for directory in RegistryDirectory.allCases {
            let file = RegistryWriter.directoryURL(directory, in: projectURL)
                .appendingPathComponent("abcd.json")
            guard case .registry = MaughamSidecarPath.classify(
                url: file, projectURL: projectURL)
            else {
                return XCTFail("\(directory) is not routed as the registry")
            }
        }
    }

    // MARK: - Plan 1's pre-check limits (P3c plan 2 Task 8)

    /// **A corrupt person file no longer hides a record-only stranger.**
    /// Matched by name alone, `people/<fp>.json` that will not read read as
    /// *already let in*, and the verified read that would have refused it was
    /// never paid for. Now a matched person file must parse, and one that does
    /// not is a device worth a look — both directions.
    func test_anUnreadablePersonFileCountsAsWorthALook() async throws {
        let store = try await DocumentStore.open(url: projectURL)
        _ = try await store.admit(
            device: ren.author.fingerprint, label: "Ren", ownName: "Ren’s Mac")
        try await rensRecordArrives(at: store)
        let me = Document.loadIdentities.author.fingerprint
        XCTAssertEqual(AdmissionDecision.devicesWithNoPersonRecord(
            in: projectURL, excluding: me), [],
            "premise: her person file reads, so she is not looked for")
        _ = await refreshAfterTheSettle(store)
        XCTAssertEqual(resolves, 0, "and nothing is resolved")

        try Data("{ not json".utf8).write(to: RegistryWriter.url(
            .people, fingerprint: ren.author.fingerprint, in: projectURL))

        XCTAssertEqual(AdmissionDecision.devicesWithNoPersonRecord(
            in: projectURL, excluding: me), [ren.author.fingerprint],
            "an unreadable person file is no person record to the pre-check")
        _ = await refreshAfterTheSettle(store)
        XCTAssertEqual(resolves, 1, "so the verified read is paid for, and it decides")
    }

    /// **The non-root skip, by filename** — `mayHoldARootRecord`. A root's
    /// record is filed under its own fingerprint and names itself as its
    /// admitter; an admitted Mac's names somebody else; a Mac with no person
    /// file has no root record. A file that will not read errs toward the look.
    func test_mayHoldARootRecordReadsTheOneFileByName() async throws {
        let store = try await DocumentStore.open(url: projectURL)  // this Mac roots the book
        let me = Document.loadIdentities.author.fingerprint
        XCTAssertTrue(AdmissionDecision.mayHoldARootRecord(me, in: projectURL),
                      "the root's own self-admitted record")

        XCTAssertFalse(AdmissionDecision.mayHoldARootRecord(
            ren.author.fingerprint, in: projectURL), "no person file: no root record")

        _ = try await store.admit(
            device: ren.author.fingerprint, label: "Ren", ownName: "Ren’s Mac")
        XCTAssertFalse(AdmissionDecision.mayHoldARootRecord(
            ren.author.fingerprint, in: projectURL),
            "an admitted Mac's record names its admitter, not itself")

        try Data("{ not json".utf8).write(to: RegistryWriter.url(
            .people, fingerprint: ren.author.fingerprint, in: projectURL))
        XCTAssertTrue(AdmissionDecision.mayHoldARootRecord(
            ren.author.fingerprint, in: projectURL),
            "unreadable: look, and let the verified read decide")
    }

    /// **A non-root Mac skips the admission resolve entirely** — the
    /// production closure, on disk. Ren's Mac, admitted here, sees a stranger's
    /// device record arrive; it pays for no listing, no recount and no verified
    /// read, and answers nobody. The root, in the same folder, still looks.
    func test_aNonRootMacSkipsTheAdmissionResolve() async throws {
        let store = try await DocumentStore.open(url: projectURL)  // this Mac roots it
        _ = try await store.admit(
            device: ren.author.fingerprint, label: "Ren", ownName: "Ren’s Mac")
        try await rensRecordArrives(at: store)
        let kit = LocalIdentities.softwareForTesting()
        _ = try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: kit, name: "Kit’s Mac", kind: .mac)

        func refresh(asDevice device: String)
            async -> (answer: [AdmissionRequest]?, counted: Int, resolved: Int)
        {
            var counted = 0
            var resolved = 0
            let url = projectURL!
            let identities = Document.loadIdentities
            let cache = Document.loadRegistryCache
            let answer = await AdmissionDecision.refreshedRequests(
                cause: .settle,
                holdsARootRecord: { AdmissionDecision.mayHoldARootRecord(device, in: url) },
                heldLines: { counted += 1; return [:] },
                arrivedDevices: {
                    AdmissionDecision.devicesWithNoPersonRecord(in: url, excluding: device)
                },
                thisDevice: device,
                memory: [:],
                admitRemembered: {},
                resolve: {
                    resolved += 1
                    guard let verified = try? TrustResolution.resolveVerified(
                        projectURL: url, identities: identities, cache: cache)
                    else { return nil }
                    return (verified.registry, AdmissionDecision.askingRoot(
                        in: verified.registry, thisDevice: device))
                })
            return (answer, counted, resolved)
        }

        let asRen = await refresh(asDevice: ren.author.fingerprint)
        XCTAssertEqual(asRen.answer, [], "an admitted Mac is asked about nobody")
        XCTAssertEqual(asRen.counted, 0, "counts nothing")
        XCTAssertEqual(asRen.resolved, 0, "and resolves nothing to learn it")

        let asRoot = await refresh(asDevice: Document.loadIdentities.author.fingerprint)
        XCTAssertEqual(asRoot.answer?.map(\.fingerprint), [kit.author.fingerprint],
                       "the root is asked about Kit")
        XCTAssertGreaterThan(asRoot.counted, 0, "having counted")
        XCTAssertEqual(asRoot.resolved, 1, "and resolved once")
    }
}
