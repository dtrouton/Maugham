import XCTest
@testable import MaughamCore
@testable import Maugham

/// **`update_note`** (note versions plan 2, Task 6; ADR 0034): the assistant
/// replaces an existing Research note's body through the note door
/// (`DocumentStore.saveResearchNote(by: .assistant)`), so what it replaces is
/// kept as a version marked as the assistant's and the writer can restore it.
/// Nothing but a Research note is ever written: never the manuscript.
@MainActor
final class UpdateNoteToolTests: XCTestCase {

    private var projectURL: URL!
    private var stores: [DocumentStore] = []

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("updatenote-\(UUID().uuidString)")
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
        MCPShareLock.readerForTesting = nil
        for store in stores { await store.close() }
        stores = []
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - Fixture

    private struct Book {
        let ds: DocumentStore
        let store: ProjectStore
        let registry: ProjectRegistry
        let id: String
    }

    private func file(_ relative: String) -> URL { projectURL.appendingPathComponent(relative) }

    private func openBook() async throws -> Book {
        try "Opening.\n".write(to: file("manuscript/a.md"), atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [StructureItem(id: "doc-a", title: "Chapter A", type: .document,
                                      path: "manuscript/a.md")],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: file(ProjectManifest.fileName))
        let ds = try await DocumentStore.open(url: projectURL)
        stores.append(ds)
        let doc = try await Document.load(
            url: file("manuscript/a.md"), actor: .author, session: "boot", presenter: nil)
        await doc.close()
        let store = try await ProjectStore.load(from: projectURL)
        store.documentStore = ds
        ds.projectStore = store
        let registry = ProjectRegistry()
        registry.register(url: projectURL, store: store)
        return Book(ds: ds, store: store, registry: registry, id: ProjectIdentifier.id(for: projectURL))
    }

    /// A Research note holding `text`.
    private func note(_ book: Book, _ text: String, title: String = "Notes") async throws -> ResearchItem {
        let item = try await book.store.addResearchTextNote(parentId: nil, title: title)
        try Data(text.utf8).write(to: file(try XCTUnwrap(item.path)))
        return item
    }

    /// An asset imported from a file named `name` holding `bytes`.
    private func asset(_ book: Book, named name: String, _ bytes: Data) async throws -> ResearchItem {
        let outside = TestTemp.root.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let source = outside.appendingPathComponent(name)
        try bytes.write(to: source)
        return try await book.store.addResearchAsset(parentId: nil, fromURL: source)
    }

    private func text(of item: ResearchItem) throws -> String {
        try String(contentsOf: file(try XCTUnwrap(item.path)), encoding: .utf8)
    }

    private func versions(of item: ResearchItem) -> [ResearchVersion] {
        ResearchVersionStore(projectURL: projectURL).versions(itemId: item.id)
    }

    private func keptText(_ version: ResearchVersion) throws -> String {
        String(decoding: try ResearchVersionStore(projectURL: projectURL).read(version).0, as: UTF8.self)
    }

    private func params(_ book: Book, _ researchId: String, _ body: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "project_id": book.id, "research_id": researchId, "body": body])
    }

    @discardableResult
    private func update(_ book: Book, _ researchId: String, _ body: String) async throws -> UpdateNoteTool.Result {
        let data = try await UpdateNoteTool.handle(paramsJSON: try params(book, researchId, body),
                                                   registry: book.registry)
        return try JSONDecoder().decode(UpdateNoteTool.Result.self, from: data)
    }

    /// The `invalidArgument` message a call threw, or a failure.
    private func refusal(_ call: () async throws -> Void) async -> String {
        do {
            try await call()
            XCTFail("expected a refusal")
            return ""
        } catch MCPError.invalidArgument(let message) {
            return message
        } catch {
            XCTFail("expected invalidArgument, got \(error)")
            return ""
        }
    }

    private struct FakeShare: ShareMetadataReading {
        let canWrite: Bool?
        func read(for url: URL) -> ShareMetadata? {
            ShareMetadata(isShared: true, isOwner: false, canWrite: canWrite, ownerName: "Sam", currentUserName: "Ana")
        }
    }

    // MARK: - The write

    func test_itReplacesTheBody_keepsTheWritersText_andMarksTheVersion() async throws {
        let book = try await openBook()
        let item = try await note(book, "The writer's notes.\n")

        let result = try await update(book, item.id, "The assistant's rewrite.\n")

        XCTAssertEqual(try text(of: item), "The assistant's rewrite.\n")
        XCTAssertEqual(result.id, item.id)
        XCTAssertEqual(result.title, item.title)
        XCTAssertEqual(result.path, item.path)
        XCTAssertTrue(result.kept_previous_version)
        let kept = try XCTUnwrap(versions(of: item).first)
        XCTAssertEqual(versions(of: item).count, 1)
        XCTAssertEqual(kept.payload, .note)
        XCTAssertEqual(try keptText(kept), "The writer's notes.\n")
        XCTAssertEqual(kept.replacedBy, .assistant, "listed as \u{201C}Before the assistant\u{2019}s change\u{201D}")
        let record = try XCTUnwrap(try ResearchNoteRecord.read(forItem: item.id, in: projectURL))
        XCTAssertEqual(record.writtenBy, .assistant, "the text now on disk is the assistant's")
    }

    /// Tripwire 10: the response names the note, never carries its body.
    func test_theResultCarriesNoBody() async throws {
        let book = try await openBook()
        let item = try await note(book, "Before.")
        let body = String(repeating: "A long rewrite. ", count: 2000)
        let data = try await UpdateNoteTool.handle(paramsJSON: try params(book, item.id, body),
                                                   registry: book.registry)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("A long rewrite."))
        XCTAssertLessThan(data.count, 1024)
    }

    func test_aNoteOpenWithAnUnflushedEditKeepsThatEditAsTheVersion() async throws {
        let book = try await openBook()
        let item = try await note(book, "Saved earlier.")
        book.ds.researchNoteDoor.saveDelay = .seconds(3600)
        book.ds.scheduleNoteSave(itemId: item.id, text: "Typed, not yet saved.")
        XCTAssertTrue(book.ds.researchNoteHasPendingSave(itemId: item.id))

        try await update(book, item.id, "The assistant's version.")

        XCTAssertEqual(try text(of: item), "The assistant's version.")
        XCTAssertFalse(book.ds.researchNoteHasPendingSave(itemId: item.id), "the edit was flushed, not dropped")
        let marked = versions(of: item).filter { $0.replacedBy == .assistant }
        XCTAssertEqual(try marked.map(keptText), ["Typed, not yet saved."],
                       "the writer's unsaved edit is the version the assistant replaced")
    }

    /// The door could not save (a file at the path that will not read is
    /// never written over): the call says the note was not changed.
    func test_aSaveTheDoorRefusesSaysTheNoteWasNotChanged() async throws {
        let book = try await openBook()
        let item = try await note(book, "Before.")
        let url = file(try XCTUnwrap(item.path))
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let message = await refusal { try await self.update(book, item.id, "After.") }
        XCTAssertTrue(message.contains("wasn’t changed"), message)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue, "nothing was written over it")
        XCTAssertTrue(versions(of: item).isEmpty)
    }

    // MARK: - Refusals

    func test_itRefusesATable_APicture_APaletteCard_AGroup_sayingWhatEachIs() async throws {
        let book = try await openBook()
        let table = try await asset(book, named: "model.csv", Data("A,B\n1,2\n".utf8))
        let picture = try await asset(book, named: "harbour.png", Data([0x89, 0x50, 0x4E, 0x47]))
        let pdf = try await asset(book, named: "source.pdf", Data("%PDF-1.4\n".utf8))
        let card = try await book.store.addPaletteCard(title: "Fog", kind: .other)
        let cardText = try text(of: card)
        let group = try await book.store.addResearchItem(parentId: nil, title: "Sources", kind: nil)
        let link = try await book.store.addResearchLink(parentId: nil, title: "Archive",
                                                        url: "https://example.com")
        let tableBytes = try Data(contentsOf: file(try XCTUnwrap(table.path)))

        let cases: [(ResearchItem, String)] = [
            (table, "is a Research table, not a note; use write_research_cells."),
            (picture, "is a picture in Research, not a note"),
            (pdf, "is a PDF in Research, not a note"),
            (card, "is a palette card, not a note"),
            (group, "is a Research group, not a note"),
            (link, "is a web link in Research, not a note"),
        ]
        for (item, says) in cases {
            let message = await refusal { try await self.update(book, item.id, "Overwritten.") }
            XCTAssertTrue(message.hasPrefix("'\(item.title)' (\(item.id)) \(says)"), message)
        }
        XCTAssertEqual(try Data(contentsOf: file(try XCTUnwrap(table.path))), tableBytes)
        XCTAssertEqual(try text(of: card), cardText)
        for (item, _) in cases { XCTAssertTrue(versions(of: item).isEmpty) }
    }

    /// The hard invariant: MCP never writes manuscript text.
    func test_aManuscriptDocumentIsRefused_andNothingOnDiskChanges() async throws {
        let book = try await openBook()
        let before = try Data(contentsOf: file("manuscript/a.md"))
        let message = await refusal { try await self.update(book, "doc-a", "Rewritten chapter.") }
        XCTAssertTrue(message.hasPrefix("'Chapter A' (doc-a) is a manuscript document, not a Research note"), message)
        XCTAssertEqual(try Data(contentsOf: file("manuscript/a.md")), before)
        XCTAssertTrue(ResearchVersionStore(projectURL: projectURL).versions(itemId: "doc-a").isEmpty)
    }

    func test_aFigureIsRefusedSayingItIsAFigure() async throws {
        let book = try await openBook()
        let figure = try await book.store.createFigure(kind: .table, name: "summary", piece: nil)
        let message = await refusal { try await self.update(book, figure.id, "x") }
        XCTAssertTrue(message.hasPrefix("'summary' (\(figure.id)) is a figure, not a Research note"), message)
    }

    func test_itRefusesAViewOnlyShare_andWritesNothing() async throws {
        let book = try await openBook()
        let item = try await note(book, "Mine.")
        MCPShareLock.readerForTesting = FakeShare(canWrite: false)
        let sentence = "This share is view-only, so a research note can’t be changed."

        var message = await refusal { try await self.update(book, item.id, "Theirs.") }
        XCTAssertEqual(message, sentence)
        message = await refusal { try await self.update(book, "res-nope", "Theirs.") }
        XCTAssertEqual(message, sentence, "refused before the id is looked up")
        XCTAssertEqual(try text(of: item), "Mine.")
        XCTAssertTrue(versions(of: item).isEmpty)

        MCPShareLock.readerForTesting = FakeShare(canWrite: true)
        try await update(book, item.id, "Theirs.")
        XCTAssertEqual(try text(of: item), "Theirs.")
    }

    func test_anUnknownIdSaysToUseListResearch() async throws {
        let book = try await openBook()
        let message = await refusal { try await self.update(book, "res-nope", "x") }
        XCTAssertEqual(message, "No Research item with id 'res-nope'. Use list_research for the ids.")
    }

    func test_aProjectWhoseWindowIsNotReadyIsRefused() async throws {
        let book = try await openBook()
        let item = try await note(book, "Before.")
        book.store.documentStore = nil
        let message = await refusal { try await self.update(book, item.id, "After.") }
        XCTAssertEqual(message, "The project's window is not ready for a Research note.")
        XCTAssertEqual(try text(of: item), "Before.")
    }
}
