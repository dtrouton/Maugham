// MaughamTests/Stores/NarrowingSchemaGateTests.swift
import XCTest
@testable import MaughamCore
@testable import Maugham

/// **The first narrowing shuts older builds out of the book** (signed op log
/// P3b Task 3's MUST; P3 handoff, *What P3b is*).
///
/// A v0.40 Mac has no permit layer. Put it in a narrowed book and it applies
/// the reviewer's refused text, folds it into the manuscript, and its own next
/// burst re-asserts those words under its own book-author key — where every
/// signed Mac then has to take them. The writer's demotion is undone by the
/// oldest machine in the house, silently. `ProjectManifest.decodeGuardingSchema`
/// is the only thing that stops it, and it stops it by refusing the project.
///
/// So: **gate, then event, then record**, and a gate that could not be written
/// refuses the act with nothing written at all. This suite drives the two
/// production verbs that can narrow — `DocumentStore.changePermit` (both
/// arities) and `DocumentStore.admit` — against a real project whose manifest
/// starts at the previous schema.
@MainActor
final class NarrowingSchemaGateTests: XCTestCase {

    private var projectURL: URL!
    private var cache: RegistryCache!
    private var memory: AdmissionMemory!
    private var strangerDevice: LocalIdentities!
    private var stranger: DeviceIdentity!
    private var strangerState: OpLogDeviceState!

    /// The number a book that has never been narrowed carries. Written out
    /// rather than derived, so this suite fails the day the gate stops moving
    /// anything.
    private let beforeTheGate = 8

    override func setUp() async throws {
        let (dir, _) = try makeTestProject(prefix: "GATE", initialMd: "Hello.\n")
        projectURL = dir
        // `makeTestProject` stamps THIS build's number; a book the gate has
        // anything to do is one written by an older one.
        try writeManifestSchema(beforeTheGate)
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
        if let projectURL { try? FileManager.default.removeItem(at: projectURL) }
        projectURL = nil
    }

    // MARK: - Fixtures

    private var manifestURL: URL {
        projectURL.appendingPathComponent(ProjectManifest.fileName)
    }

    private func writeManifestSchema(_ version: Int) throws {
        var manifest = try ProjectManifest.makeDecoder()
            .decode(ProjectManifest.self, from: Data(contentsOf: manifestURL))
        manifest.schemaVersion = version
        try ProjectManifest.makeEncoder().encode(manifest).write(to: manifestURL)
    }

    private func manifestSchemaOnDisk() throws -> Int {
        try ProjectManifest.makeDecoder()
            .decode(ProjectManifest.self, from: Data(contentsOf: manifestURL))
            .schemaVersion
    }

    private func manifestBytes() throws -> Data { try Data(contentsOf: manifestURL) }

    @discardableResult
    private func beThisMac() -> LocalIdentities {
        let identities = LocalIdentities.forTesting(author: .softwareForTesting())
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("op-log-state.json"))
        return identities
    }

    private var docURL: URL { projectURL.appendingPathComponent("manuscript/c1.md") }

    private func registry() throws -> Registry {
        try RegistryReader.load(projectURL: projectURL)
    }

    private func events() throws -> [PermitEvent] {
        try registry().events.sorted { $0.event < $1.event }
    }

    /// The stranger's own sealed file, so an admission has something to apply.
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

    private func admitStranger(_ store: DocumentStore) async throws {
        _ = try await store.admit(
            device: stranger.fingerprint, label: "Sam", ownName: "Sam’s Mac")
    }

    // MARK: - The gate fires, and in the right order

    /// **A demotion raises the number on disk.**
    func test_theFirstNarrowingRaisesTheManifestSchema() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        try await admitStranger(store)
        XCTAssertEqual(try manifestSchemaOnDisk(), beforeTheGate,
                       "an admission narrows nobody")

        _ = try await store.changePermit(person: stranger.fingerprint, to: .reviewer)

        XCTAssertEqual(
            try manifestSchemaOnDisk(), ProjectManifest.currentSchemaVersion,
            "a build without a permit layer must now refuse this book")
    }

    /// **And it is raised BEFORE the event exists** — the whole point of the
    /// order. A gate that cannot be written refuses, and a refusal leaves no
    /// event, no record and no half-narrowed book.
    func test_aGateThatCannotBeWrittenRefusesAndWritesNoEvent() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        try await admitStranger(store)
        let eventsBefore = try events().map(\.event)
        let roleBefore = try registry().person(stranger.fingerprint)?.role

        // The manifest cannot be read: the gate is the first thing that fails.
        try FileManager.default.removeItem(at: manifestURL)

        do {
            _ = try await store.changePermit(
                person: stranger.fingerprint, to: .reviewer)
            XCTFail("a book that cannot be gated is not narrowed")
        } catch let error as RegistryAdmissionError {
            guard case .manifestNotGated(_, let act) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(act, .permitChange)
        }

        XCTAssertEqual(try events().map(\.event), eventsBefore, "no event")
        XCTAssertEqual(
            try registry().person(stranger.fingerprint)?.role, roleBefore,
            "and no re-signed record")
    }

    /// **A narrowing ADMISSION gates too.** Letting somebody in as a reviewer
    /// narrows the book exactly as demoting somebody does.
    func test_aNarrowingAdmissionGatesAsWell() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        let doc = try await Document.load(
            url: docURL, actor: .author, session: "s", presenter: nil)
        let docId = doc.docId
        await doc.close()
        try await writeStrangerFile(docId: docId, opIds: ["02"])

        _ = try await store.admit(
            device: stranger.fingerprint, label: "Sam", ownName: "Sam’s Mac",
            permit: .reviewer)

        XCTAssertEqual(
            try manifestSchemaOnDisk(), ProjectManifest.currentSchemaVersion)
    }

    /// **`changePermit(everyRecordOf:)` gates ONCE, first** — before the first
    /// of the records moves, because the gate is about the BOOK.
    func test_thePluralVerbGatesBeforeAnyRecordMoves() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        try await admitStranger(store)

        let moved = try await store.changePermit(
            everyRecordOf: stranger.fingerprint, to: .reviewer)

        XCTAssertEqual(moved.count, 1)
        XCTAssertEqual(
            try manifestSchemaOnDisk(), ProjectManifest.currentSchemaVersion)
    }

    func test_thePluralVerbRefusesEntirelyWhenTheGateCannotBeWritten() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        try await admitStranger(store)
        let eventsBefore = try events().map(\.event)
        try FileManager.default.removeItem(at: manifestURL)

        do {
            _ = try await store.changePermit(
                everyRecordOf: stranger.fingerprint, to: .reviewer)
            XCTFail("the whole act or none of it")
        } catch let error as RegistryAdmissionError {
            guard case .manifestNotGated = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try events().map(\.event), eventsBefore)
    }

    // MARK: - The other direction: nothing that is not a narrowing touches it

    /// **An ordinary admission leaves the manifest BYTE-identical.** The whole
    /// virtue of gating at the first narrowing rather than at first sight of a
    /// register is that a book nobody has narrowed goes on opening everywhere.
    func test_anAdmissionLeavesTheManifestUntouched() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        let before = try manifestBytes()

        try await admitStranger(store)

        XCTAssertEqual(try manifestSchemaOnDisk(), beforeTheGate,
                       "an admission narrows nobody, so nothing gates")
        XCTAssertEqual(try manifestBytes(), before)
    }

    /// A revocation, a retirement and a rename install no permit, so none of
    /// them is a narrowing and none of them writes a manifest byte.
    func test_theOtherRegistryVerbsLeaveTheManifestUntouched() async throws {
        let mine = beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        try await admitStranger(store)
        let before = try manifestBytes()

        _ = try await store.rename(person: stranger.fingerprint, to: "Samantha")
        _ = try await store.revoke(person: stranger.fingerprint)
        _ = try await store.retire(device: mine.author.fingerprint)

        XCTAssertEqual(try manifestSchemaOnDisk(), beforeTheGate,
                       "none of the three installs a permit")
        XCTAssertEqual(try manifestBytes(), before)
    }

    /// **The SECOND narrowing writes no manifest either** — the gate raises the
    /// number once and then has nothing to do.
    func test_aSecondNarrowingWritesNoManifest() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        try await admitStranger(store)
        _ = try await store.changePermit(person: stranger.fingerprint, to: .reviewer)
        let afterFirst = try manifestBytes()

        _ = try await store.changePermit(
            person: stranger.fingerprint, to: .author(.pieces(["doc-test"])))

        XCTAssertEqual(try manifestBytes(), afterFirst)
    }

    /// **A promotion back to the whole book leaves the gate standing.**
    /// Narrowing is sticky (`TrustTable.hasNarrowingPermits` reads every entry
    /// of every timeline), so a book that has ever been narrowed still needs a
    /// reader that can judge — and the number must not come back down.
    func test_promotingBackToTheWholeBookDoesNotUngateTheBook() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        try await admitStranger(store)
        _ = try await store.changePermit(person: stranger.fingerprint, to: .reviewer)

        _ = try await store.changePermit(
            person: stranger.fingerprint, to: .bookAuthor)

        XCTAssertEqual(
            try manifestSchemaOnDisk(), ProjectManifest.currentSchemaVersion)
    }

    // MARK: - The gate has to STICK

    /// **The live `ProjectStore` learns what disk now says.**
    ///
    /// `ProjectStore` holds the manifest and re-encodes its own copy on every
    /// structural save, and `schemaVersion` is DECODED rather than re-stamped —
    /// so a gate written behind the live store's back is undone by the writer's
    /// next chapter rename, and the book is narrowed and ungated with nothing
    /// anywhere saying so.
    func test_theNextOrdinaryManifestSaveDoesNotPutTheNumberBack() async throws {
        beThisMac()
        let store = try await DocumentStore.open(url: projectURL)
        let projectStore = try await ProjectStore.load(from: projectURL)
        projectStore.documentStore = store
        store.projectStore = projectStore
        XCTAssertEqual(projectStore.manifest.schemaVersion, beforeTheGate)
        try await admitStranger(store)

        _ = try await store.changePermit(person: stranger.fingerprint, to: .reviewer)
        // The ordinary save every structural edit makes.
        try await projectStore.renameStructureItem(id: "doc-test", newTitle: "C1a")

        XCTAssertEqual(
            try manifestSchemaOnDisk(), ProjectManifest.currentSchemaVersion,
            "the writer's next rename must not un-gate a narrowed book")
        XCTAssertEqual(
            projectStore.manifest.schemaVersion,
            ProjectManifest.currentSchemaVersion)
    }
}
