import Foundation
import XCTest
@testable import MaughamCore

/// **An actor key minted mid-session reaches this device's record before its
/// first line does** (P3b smoke find F6).
///
/// `LocalIdentities` is lazy — the assistant's key exists only once MCP writes
/// — and `RegistryPresence.ensureDeviceRecord` runs at project OPEN. So on the
/// smoke rig Ren's first `add_comment` minted her assistant key and signed her
/// note with it while her device record still listed `author` alone, and the
/// root Mac held the note as a stranger's until Ren's Mac relaunched. Every
/// Mac's first Claude write in a session was invisible to every other Mac.
///
/// The test that would have caught it is the cross-device one: Ren declares
/// herself at open with one actor, the root admits her, and a line signed by a
/// key she mints AFTERWARDS is read on the root's Mac with no reopen of
/// anything.
@MainActor
final class MidSessionActorTests: XCTestCase {

    private let docId = "doc-midsession"
    private var projectURL: URL!

    /// The root's Mac: all four keys, and the one reading.
    private var root: LocalIdentities!
    private var rootState: OpLogDeviceState!
    /// Ren's Mac: keys that appear one at a time, exactly as a real Mac's do.
    private var ren: LocalIdentities!
    private var renState: OpLogDeviceState!
    private var cache: RegistryCache!

    override func setUp() async throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("midsession-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".maugham/ops"),
            withIntermediateDirectories: true)
        root = .softwareForTesting()
        ren = .lazySoftwareForTesting()
        rootState = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("state-root.json"))
        renState = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("state-ren.json"))
        cache = RegistryCache(
            fileURL: projectURL.appendingPathComponent("registry-cache.json"),
            identity: root.author.fingerprint)
    }

    override func tearDown() async throws {
        let devices = RegistryWriter.directoryURL(.devices, in: projectURL)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: devices.path)
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - Fixture

    /// The smoke's state at the moment of the write: the root is the root, Ren
    /// declared herself at open having named only her author, and the root has
    /// admitted her.
    private func openedAndAdmitted() throws {
        let rootPerson = root.author.fingerprint
        try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: root, name: "Denver’s MacBook", kind: .mac)
        try RegistryPresence.ensureRootIfEmpty(
            in: projectURL, identities: root, writerName: "Denver")
        try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: ren, name: "Ren’s Mac", kind: .mac)
        XCTAssertEqual(
            try renRecord().actors.keys.sorted(), [DeviceActor.author.rawValue],
            "precondition: at open Ren's Mac had named its author and nothing else")
        try RegistryWriter.write(
            PersonRecord(
                person: ren.author.fingerprint, label: "Ren", ownName: "Ren’s Mac",
                admittedAt: Date(timeIntervalSince1970: 20), admittedBy: rootPerson),
            signedBy: root.author, in: projectURL)
    }

    private func renRecord() throws -> DeviceRecord {
        try XCTUnwrap(try RegistryReader.load(projectURL: projectURL).devices
            .first { $0.device == ren.author.fingerprint })
    }

    private func note(_ opId: String, by identity: DeviceIdentity) -> Op {
        Op(opId: opId, docId: docId, at: Date(timeIntervalSince1970: 0),
           device: identity.deviceId, session: "s", kind: .claudeComment,
           changes: [.init(paragraphId: "aaaa", prior: nil, next: opId)],
           sequence: ["aaaa"])
    }

    private func rootsReader() -> OpLogStore {
        OpLogStore(projectURL: projectURL, identities: root,
                   state: rootState, cache: cache)
    }

    // MARK: - The smoke, end to end

    /// **Ren's first Claude note, read on the root's Mac, with nobody
    /// reopening anything.** The assistant key is minted by the append itself
    /// — `ren.assistant` is named for the first time inside `note(_:by:)` —
    /// and the line it signs is sealed. The root's reader applies it and holds
    /// nothing: the record already named the key when the line was read.
    func test_aLineSignedByAKeyMintedAfterOpenIsTheAdmittedPersonsOnAnotherMac()
        async throws
    {
        try openedAndAdmitted()

        let rensStore = OpLogStore(
            projectURL: projectURL, identities: ren, state: renState)
        try await rensStore.append(note("01", by: ren.assistant))
        try await rensStore.sealChain(docId: docId)

        XCTAssertEqual(
            try renRecord().actors[DeviceActor.assistant.rawValue],
            ren.assistant.fingerprint,
            "the key her first Claude write minted is on her record")

        let loaded = try await rootsReader().loadDiagnosed(docId: docId)
        XCTAssertEqual(loaded.ops.map(\.opId), ["01"],
                       "the root applies Ren's note without anyone reopening")
        XCTAssertEqual(loaded.provenance.pendingStrangerOpLines, 0,
                       "and holds nothing of hers as a stranger's")
    }

    /// **The record is written BEFORE the line**, not after it: a reader
    /// meeting the line must already be able to find the record that names its
    /// key. Observed at the one moment it matters — the line's file does not
    /// exist yet when the record already lists the actor.
    func test_theRecordNamesTheKeyBeforeTheFirstLineExists() async throws {
        try openedAndAdmitted()
        let rensStore = OpLogStore(
            projectURL: projectURL, identities: ren, state: renState)
        let assistant = ren.assistant
        let lineFile = OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: assistant.slug, in: projectURL)

        var listedBeforeTheLine: Bool?
        rensStore.beforeChainedAppendForTesting = { [projectURL] in
            listedBeforeTheLine =
                !FileManager.default.fileExists(atPath: lineFile.path)
                && (try? RegistryReader.load(projectURL: projectURL!).devices
                    .first { $0.device == self.ren.author.fingerprint }?
                    .actors[DeviceActor.assistant.rawValue]) == assistant.fingerprint
        }
        try await rensStore.append(note("01", by: assistant))

        XCTAssertEqual(listedBeforeTheLine, true)
    }

    /// The translator's lines go through `TranslationStore`, not the op log,
    /// and its key is just as lazy — the pipeline's first run in a session is
    /// the case.
    func test_theTranslatorsFirstBatchDeclaresItsKey() async throws {
        try openedAndAdmitted()
        let translator = ren.translator

        try await TranslationStore.appendBatch(
            [TranslationRecord(paragraphId: "aaaa", language: "es",
                               text: "hola", sourceHash: "h")],
            forDocId: docId, language: "es",
            identity: translator, identities: ren,
            state: renState, in: projectURL)

        XCTAssertEqual(
            try renRecord().actors[DeviceActor.translator.rawValue],
            translator.fingerprint)
    }

    /// Maugham's own actor (the task rebalance) is the fourth, and has no path
    /// of its own: it appends through the op log like the assistant.
    func test_maughamsFirstLineDeclaresItsKey() async throws {
        try openedAndAdmitted()
        let rensStore = OpLogStore(
            projectURL: projectURL, identities: ren, state: renState)
        try await rensStore.append(note("01", by: ren.maugham))

        XCTAssertEqual(
            try renRecord().actors[DeviceActor.maugham.rawValue],
            ren.maugham.fingerprint)
    }

    // MARK: - What it does not do

    /// **No record here, no record written.** A project this device never
    /// declared itself in — the registry folder absent, or this Mac not in it
    /// — is declared at OPEN, where the machine's name is known. Creating a
    /// record from a write path would be deciding a name here, and this
    /// device's name is decided in one place.
    func test_aBookThisDeviceNeverDeclaredItselfInGetsNoRecordFromAWrite()
        async throws
    {
        let rensStore = OpLogStore(
            projectURL: projectURL, identities: ren, state: renState)
        try await rensStore.append(note("01", by: ren.assistant))

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: RegistryWriter.directoryURL(.devices, in: projectURL).path),
            "no registry folder was created by an append")
    }

    /// **A registry this device cannot write never costs the writer a line.**
    /// The declaration is best-effort: the words are safe first (constitution
    /// must #1), the line is written, and the record catches up at the next
    /// open — which is exactly the pre-fix behaviour, and no worse.
    func test_anUnwritableRegistryDoesNotRefuseTheLine() async throws {
        try openedAndAdmitted()
        let devices = RegistryWriter.directoryURL(.devices, in: projectURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: devices.path)

        let rensStore = OpLogStore(
            projectURL: projectURL, identities: ren, state: renState)
        try await rensStore.append(note("01", by: ren.assistant))

        let lineFile = OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: ren.assistant.slug, in: projectURL)
        let written = try String(contentsOf: lineFile, encoding: .utf8)
        XCTAssertTrue(written.contains("\"op_id\":\"01\""), "the line is on disk")
        XCTAssertNil(try renRecord().actors[DeviceActor.assistant.rawValue],
                     "and the record, which could not be written, was not")
    }

    /// A retired device is left alone, for `ensureDeviceRecord`'s reason: its
    /// retirement is its own signed act, and re-declaring it from a write would
    /// un-retire it.
    func test_aRetiredDevicesRecordIsNotReSignedByAWrite() throws {
        let author = ren.author
        try RegistryWriter.write(
            DeviceRecord(
                device: author.fingerprint, name: "Ren’s Mac", kind: .mac,
                actors: [DeviceActor.author.rawValue: author.fingerprint],
                madeAt: Date(timeIntervalSince1970: 1),
                retiredAt: Date(timeIntervalSince1970: 2)),
            signedBy: author, in: projectURL)

        XCTAssertNil(try RegistryPresence.declareActor(
            .assistant, in: projectURL, identities: ren))
        XCTAssertEqual(try renRecord().retiredAt, Date(timeIntervalSince1970: 2))
        XCTAssertNil(try renRecord().actors[DeviceActor.assistant.rawValue])
    }

    /// The author IS the device and is declared at open; a write as the author
    /// asks the registry nothing, so the keystroke path pays nothing for this.
    func test_theAuthorIsNeverDeclaredFromAWrite() throws {
        // A registry that would REFUSE a read: a present-and-unreadable record.
        let devices = RegistryWriter.directoryURL(.devices, in: projectURL)
        try FileManager.default.createDirectory(
            at: devices, withIntermediateDirectories: true)
        try Data("not json".utf8).write(
            to: devices.appendingPathComponent("\(ren.author.fingerprint).json"))

        XCTAssertNil(try RegistryPresence.declareActor(
            .author, in: projectURL, identities: ren),
            "no read happened, so nothing could throw")
    }

    /// Asked once per store per actor: a second line by the same actor reads no
    /// registry.
    func test_aSecondLineBySameActorDoesNotAskAgain() async throws {
        try openedAndAdmitted()
        let rensStore = OpLogStore(
            projectURL: projectURL, identities: ren, state: renState)
        try await rensStore.append(note("01", by: ren.assistant))

        let recordURL = RegistryWriter.url(
            .devices, fingerprint: ren.author.fingerprint, in: projectURL)
        let before = try Data(contentsOf: recordURL)
        try await rensStore.append(note("02", by: ren.assistant))
        XCTAssertEqual(try Data(contentsOf: recordURL), before)
        XCTAssertEqual(rensStore.declaredActorsForTesting, [.assistant])
    }
}
