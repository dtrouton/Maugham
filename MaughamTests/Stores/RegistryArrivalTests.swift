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
}
