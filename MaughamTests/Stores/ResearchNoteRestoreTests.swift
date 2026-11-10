import XCTest
@testable import Maugham
@testable import MaughamCore

/// **A Research note put back to a kept version** (note versions plan 2,
/// Task 5): `DocumentStore.restoreResearchNote` goes through the note door
/// with `restoring: true`, so what it replaces is kept and restoring again
/// undoes it.
@MainActor
final class ResearchNoteRestoreTests: XCTestCase {

    private var projectURL: URL!
    private var stores: [DocumentStore] = []

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("noterestore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let identities = LocalIdentities.softwareForTesting()
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("op-log-state.json"))
        Document.registryCacheForTesting = RegistryCache(
            fileURL: projectURL.appendingPathComponent("registry-cache.json"),
            identity: identities.author.fingerprint)
        Document.admissionMemoryForTesting = AdmissionMemory(
            fileURL: projectURL.appendingPathComponent("admission-memory.json"),
            identity: identities.author.fingerprint)
    }

    override func tearDown() async throws {
        for store in stores { await store.close() }
        stores = []
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        try? FileManager.default.removeItem(at: projectURL)
    }

    private func openBook() async throws -> (DocumentStore, ProjectStore) {
        try "Words.\n".write(to: file("manuscript/a.md"), atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [StructureItem(id: "doc-a", title: "A", type: .document, path: "manuscript/a.md")],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: file(ProjectManifest.fileName))
        let store = try await DocumentStore.open(url: projectURL)
        stores.append(store)
        let doc = try await Document.load(
            url: file("manuscript/a.md"), actor: .author, session: "boot", presenter: nil)
        await doc.close()
        let projectStore = try await ProjectStore.load(from: projectURL)
        projectStore.documentStore = store
        store.projectStore = projectStore
        return (store, projectStore)
    }

    private func file(_ relative: String) -> URL { projectURL.appendingPathComponent(relative) }

    private func note(_ bytes: Data, in projectStore: ProjectStore) async throws -> ResearchItem {
        let item = try await projectStore.createResearchNote(scope: .shared, title: "Notes")
        try bytes.write(to: file(try XCTUnwrap(item.path)))
        return item
    }

    private func bytes(of item: ResearchItem, _ projectStore: ProjectStore) throws -> Data {
        let now = try XCTUnwrap(projectStore.findResearchItem(id: item.id, in: projectStore.manifest.research))
        return try Data(contentsOf: file(try XCTUnwrap(now.path)))
    }

    private func versions(of item: ResearchItem) -> [ResearchVersion] {
        ResearchVersionStore(projectURL: projectURL).versions(itemId: item.id)
    }

    /// Keeps `kept` as a version of `item` by saving over it, then leaves `final` on disk.
    private func versionOf(_ kept: Data, final: String, _ item: ResearchItem, _ projectStore: ProjectStore,
                           _ store: DocumentStore) async throws -> ResearchVersion {
        try kept.write(to: file(try XCTUnwrap(item.path)))
        await store.saveResearchNote(itemId: item.id, text: final)
        return try XCTUnwrap(versions(of: item).first)
    }

    func test_restoringPutsTheVersionBack_andKeepsWhatItReplaced_soRestoringAgainUndoesIt() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await note(Data("One.".utf8), in: projectStore)
        let v1 = try await versionOf(Data("One.".utf8), final: "Two.", item, projectStore, store)
        XCTAssertEqual(versions(of: item).count, 1)

        try await store.restoreResearchNote(itemId: item.id, to: v1, shareIsReadOnly: false)
        XCTAssertEqual(try bytes(of: item, projectStore), Data("One.".utf8))
        let after = versions(of: item)
        XCTAssertEqual(after.count, 2, "the text the restore replaced is kept")

        let kept = try XCTUnwrap(after.first { $0.name != v1.name })
        try await store.restoreResearchNote(itemId: item.id, to: kept, shareIsReadOnly: false)
        XCTAssertEqual(try bytes(of: item, projectStore), Data("Two.".utf8), "restoring again undoes it")
    }

    func test_restoringTheSameTextWritesNothing() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await note(Data("Same.".utf8), in: projectStore)
        let v1 = try await versionOf(Data("Same.".utf8), final: "Other.", item, projectStore, store)
        try await store.restoreResearchNote(itemId: item.id, to: v1, shareIsReadOnly: false)
        let count = versions(of: item).count
        try await store.restoreResearchNote(itemId: item.id, to: v1, shareIsReadOnly: false)
        XCTAssertEqual(versions(of: item).count, count, "the note already held it: nothing kept")
        XCTAssertEqual(try bytes(of: item, projectStore), Data("Same.".utf8))
    }

    func test_aViewOnlyShareRefusesANoteRestore() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await note(Data("One.".utf8), in: projectStore)
        let v1 = try await versionOf(Data("One.".utf8), final: "Two.", item, projectStore, store)
        do {
            try await store.restoreResearchNote(itemId: item.id, to: v1, shareIsReadOnly: true)
            XCTFail("refused")
        } catch let refused as ResearchTableHost.Refused {
            XCTAssertEqual(refused.reason, .viewOnlyShare)
        }
        XCTAssertEqual(try bytes(of: item, projectStore), Data("Two.".utf8))
    }

    func test_aTablePayloadIsNotRestoredIntoANote() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await note(Data("Note.".utf8), in: projectStore)
        let tableVersion = ResearchVersion(itemId: item.id, name: "x", savedAt: Date(), writtenBy: nil,
                                           payload: .table)
        do {
            try await store.restoreResearchNote(itemId: item.id, to: tableVersion, shareIsReadOnly: false)
            XCTFail("refused")
        } catch is ResearchNoteRestoreError {}
        XCTAssertEqual(try bytes(of: item, projectStore), Data("Note.".utf8))
    }

    /// A BOM and CRLF in the kept bytes survive a restore byte for byte.
    func test_aBOMAndCRLFSurviveARestore() async throws {
        let (store, projectStore) = try await openBook()
        let original = Data([0xEF, 0xBB, 0xBF] + Array("Line\r\nTwo\r\n".utf8))
        let item = try await note(original, in: projectStore)
        let v1 = try await versionOf(original, final: "Plain.", item, projectStore, store)
        try await store.restoreResearchNote(itemId: item.id, to: v1, shareIsReadOnly: false)
        XCTAssertEqual(try bytes(of: item, projectStore), original)
    }

    /// Bytes that are not UTF-8 are refused, and the note is untouched.
    func test_aVersionThatIsNotUTF8IsRefused() async throws {
        let (store, projectStore) = try await openBook()
        let bad = Data([0x48, 0xFF, 0xFE, 0x69])
        let item = try await note(bad, in: projectStore)
        let v1 = try await versionOf(bad, final: "Fine.", item, projectStore, store)
        do {
            try await store.restoreResearchNote(itemId: item.id, to: v1, shareIsReadOnly: false)
            XCTFail("refused")
        } catch is ResearchNoteRestoreError {}
        XCTAssertEqual(try bytes(of: item, projectStore), Data("Fine.".utf8))
    }

    /// A restore whose replaced text cannot be kept is not made, says it was
    /// the restored version, and leaves the note as it was.
    /// Disable experiment: drop `restoring: true` from the verb and the
    /// notice names "your edits" instead.
    func test_aRestoreWhoseKeepFailsIsNotMade_andSaysItWasTheRestoredVersion() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await note(Data("One.".utf8), in: projectStore)
        let v1 = try await versionOf(Data("One.".utf8), final: "Two.", item, projectStore, store)
        var heard: [String] = []
        let observer = NotificationCenter.default.addObserver( // adr-0021-ok: a test observing the production post, not a production subscription
            forName: .maughamDocumentNotice, object: nil, queue: nil
        ) { note in
            if let m = note.userInfo?[MaughamEvent.noticeMessageKey] as? String {
                MainActor.assumeIsolated { heard.append(m) }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let folder = file(ResearchVersionStore.folder).appendingPathComponent(item.id)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        do {
            try await store.restoreResearchNote(itemId: item.id, to: v1, shareIsReadOnly: false)
            XCTFail("refused")
        } catch let error as ResearchNoteRestoreError {
            XCTAssertTrue(error.message.contains("note is as it was"), error.message)
        }
        XCTAssertEqual(try bytes(of: item, projectStore), Data("Two.".utf8))
        XCTAssertTrue(heard.contains { $0.contains("the restored version wasn’t saved over it") }, "\(heard)")
    }
}
