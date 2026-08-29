import MaughamCore
import XCTest
@testable import Maugham

/// **Translator's note…** — the author's Kundera move (translation pipeline
/// spec §3): a directive minted from the English through the one door,
/// `RulingPerformer.rule`, into the home the writer chose.
@MainActor
final class TranslatorsNoteTests: XCTestCase {

    private struct Harness {
        let projectURL: URL
        let projectStore: ProjectStore
        let documentStore: DocumentStore
        let doc: Document
    }

    /// `TranslatorEnvironmentTests.makeHarness`'s project, minus the
    /// environment: a real `Document.load` is what mints the ¶ids every test
    /// here names.
    private func makeHarness() async throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranslatorsNote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let path = "manuscript/c1.md"
        try "The fog came in.\n\nShe closed the door.\n\nNobody spoke."
            .write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "Note", author: "A",
            created: Date(), modified: Date(),
            structure: [StructureItem(id: "doc-1", title: "Chapter 1",
                                      type: .document, path: path)],
            research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: root.appendingPathComponent("project.maugham.json"))

        let projectStore = try await ProjectStore.load(from: root)
        let documentStore = try await DocumentStore.open(url: root)
        projectStore.documentStore = documentStore
        let doc = try await Document.load(
            url: root.appendingPathComponent(path),
            device: "test", session: "s", presenter: nil)
        documentStore.register(document: doc, for: path)
        return Harness(projectURL: root, projectStore: projectStore,
                       documentStore: documentStore, doc: doc)
    }

    func test_everyEditionLandsInThePiecesOwnIntent() async throws {
        let h = try await makeHarness()
        let id = h.doc.sequence[1]
        let target = TranslatorsNote.Target(
            docId: h.doc.docId, paragraphId: id, excerpt: "She closed the door.", editions: [])

        let refusal = await TranslatorsNote.commit(
            "one sentence, not two — it is a door closing",
            target: target, home: .everyEdition, store: h.projectStore, world: nil)

        XCTAssertNil(refusal)
        let statement = try XCTUnwrap(h.projectStore.statement(
            kind: .intent, scope: .document(h.doc.docId)))
        let rulings = RulingsSection.parse(try h.projectStore.statementText(of: statement)).rulings
        XCTAssertEqual(rulings.count, 1)
        XCTAssertEqual(rulings[0].directive?.paragraphId, id)
        XCTAssertEqual(rulings[0].directive?.text, "one sentence, not two - it is a door closing",
                       "the em-dash became a hyphen and the line still parses as a directive")
        XCTAssertEqual(rulings[0].provenance, Ruling.Provenance.translatorsNote)
        XCTAssertNotNil(rulings[0].ruledOn)
        await h.documentStore.close()
    }

    func test_thisEditionOnlyLandsInThatLanguagesBriefAtProjectScope() async throws {
        let h = try await makeHarness()
        let id = h.doc.sequence[0]
        let target = TranslatorsNote.Target(
            docId: h.doc.docId, paragraphId: id, excerpt: "The fog came in.", editions: ["es"])

        let refusal = await TranslatorsNote.commit(
            "do not elevate this", target: target, home: .edition("es"),
            store: h.projectStore, world: nil)

        XCTAssertNil(refusal)
        let brief = try XCTUnwrap(h.projectStore.statement(kind: .editionBrief("es"), scope: .project))
        let rulings = RulingsSection.parse(try h.projectStore.statementText(of: brief)).rulings
        XCTAssertEqual(rulings.first?.directive?.paragraphId, id)
        XCTAssertNil(h.projectStore.statement(kind: .intent, scope: .document(h.doc.docId)),
                     "nothing was written to the other home")
        await h.documentStore.close()
    }

    func test_anEmptyInstructionIsRefusedInWordsAndWritesNothing() async throws {
        let h = try await makeHarness()
        let target = TranslatorsNote.Target(
            docId: h.doc.docId, paragraphId: h.doc.sequence[0], excerpt: "x", editions: [])
        let refusal = await TranslatorsNote.commit(
            "   ", target: target, home: .everyEdition, store: h.projectStore, world: nil)
        XCTAssertEqual(refusal, TranslatorsNoteCopy.emptyRefusal)
        XCTAssertNil(h.projectStore.statement(kind: .intent, scope: .document(h.doc.docId)))
        await h.documentStore.close()
    }

    func test_destinationIsTheOneSpellingOfWhereANoteGoes() {
        let every = TranslatorsNote.destination(home: .everyEdition, docId: "doc-1")
        XCTAssertEqual(every.kind, .intent)
        XCTAssertEqual(every.scope, .document("doc-1"))
        let one = TranslatorsNote.destination(home: .edition("fr"), docId: "doc-1")
        XCTAssertEqual(one.kind, .editionBrief("fr"))
        XCTAssertEqual(one.scope, .project)
    }

    /// The "This edition only" choices are every edition the book has, by the
    /// desk's own union — translation files, stored roles — plus a brief that
    /// exists with neither.
    func test_editionsAreTheUnionOfFilesRolesAndBriefs() async throws {
        let h = try await makeHarness()
        try await TranslationStore.append(
            TranslationRecord(paragraphId: h.doc.sequence[0], language: "es", text: "…",
                              sourceHash: TranslationHash.hash("x")),
            forDocId: h.doc.docId, deviceSlug: DeviceSlug.make(from: "t"), in: h.projectURL)
        _ = try await h.projectStore.readerRole(for: "de")
        _ = try await h.projectStore.createStatement(kind: .editionBrief("fr"), scope: .project)

        XCTAssertEqual(
            TranslatorsNote.editions(manifest: h.projectStore.manifest, docId: h.doc.docId,
                                     projectURL: h.projectURL),
            ["de", "es", "fr"])
        await h.documentStore.close()
    }

    /// The target is read off the caret: the paragraph under it, an excerpt of
    /// its display text, and the editions the sheet offers. No paragraph (an
    /// empty document) → no target.
    func test_targetIsReadOffTheCaret() async throws {
        let h = try await makeHarness()
        h.doc.cursorLocation = 0
        let target = try XCTUnwrap(TranslatorsNote.target(
            for: h.doc, docId: h.doc.docId, manifest: h.projectStore.manifest,
            projectURL: h.projectURL))
        XCTAssertEqual(target.paragraphId, h.doc.sequence[0])
        XCTAssertEqual(target.excerpt, "The fog came in.")
        XCTAssertEqual(target.docId, h.doc.docId)
        await h.documentStore.close()
    }

    // MARK: - The doors

    /// The window command is in the Edit menu with a ⌘⌥ letter, and that
    /// letter is on the cheatsheet — `DocSyncTests` enforces the second half;
    /// this pins the first.
    func test_theCommandIsBoundInTheAppAndListedOnTheCheatsheet() throws {
        let app = try String(contentsOf: repoFile("Maugham/MaughamApp.swift"), encoding: .utf8)
        XCTAssertTrue(app.contains("MaughamEvent.post(.maughamTranslatorsNote, to: .keyWindow)"))
        XCTAssertTrue(app.contains(".keyboardShortcut(\"c\", modifiers: [.command, .option])"))
        let listed = KeyboardShortcuts.all.flatMap(\.items)
            .contains { $0.shortcut == "⌘⌥C" && $0.label.contains("Translator") }
        XCTAssertTrue(listed)
    }

    func test_theSelectionToolbarOffersItAndPostsTheSameCommand() throws {
        XCTAssertTrue(SelectionToolbarView.Kind.allCases.contains(.translatorsNote))
        let coordinator = try String(
            contentsOf: repoFile("Maugham/Editor/EditorCoordinator+ReviewRender.swift"),
            encoding: .utf8)
        XCTAssertTrue(coordinator.contains(
            "case .translatorsNote: MaughamEvent.post(.maughamTranslatorsNote, to: .keyWindow)"))
    }

    private func repoFile(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(relative)
    }
}
