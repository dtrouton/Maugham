import XCTest
import MaughamCore
@testable import Maugham

/// What a promotion's MARK means once it can name a `Statement` (M1A Task 7).
///
/// A card promoted to craft intent carries a statement id in
/// `CanvasNode.promotedItemID`, and a statement lives in `manifest.statements`
/// and never in `manifest.research`. Two readers resolve that id — the
/// promotion sheet's `ArtifactIndex`, built once when it opens, and the canvas
/// inspector's deferred lookup — and this file holds them to one answer.
@MainActor
final class PromotionStatementMarkTests: XCTestCase {

    private var temp: TempDirectory!
    private var documentStores: [DocumentStore] = []

    override func setUp() async throws { temp = TempDirectory() }

    override func tearDown() async throws {
        for ds in documentStores { await ds.close() }
        documentStores = []
        temp = nil
    }

    /// A novel with one chapter, so a document-scoped statement has a document
    /// to be about. `PromotionPerformerTests.makeProject`'s pattern.
    private func makeProject() async throws -> ProjectStore {
        let tmp = temp.url.appendingPathComponent("PSM-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        for sub in ["manuscript", "research"] {
            try FileManager.default.createDirectory(
                at: tmp.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try "Chapter 1\n".write(to: tmp.appendingPathComponent("manuscript/c1.md"),
                                atomically: true, encoding: .utf8)
        let chapter = StructureItem(id: "ch-1", title: "Chapter 1", type: .document,
                                    path: "manuscript/c1.md")
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(), structure: [chapter], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        let ds = try await DocumentStore.open(url: tmp)
        store.documentStore = ds
        documentStores.append(ds)
        return store
    }

    private func index(_ store: ProjectStore) -> ArtifactIndex {
        ArtifactIndex.over(research: store.manifest.research,
                           statements: store.manifest.statements,
                           structure: store.manifest.structure)
    }

    // MARK: - The name

    /// The project's intent answers with the bare name — which is what shipped
    /// before M1A, and the writer's word for the thing did not change.
    func test_theProjectsIntentIsNamedWithoutADocument() async throws {
        let store = try await makeProject()
        let statement = try await store.createStatement(kind: .intent, scope: .project)
        XCTAssertEqual(index(store).title(of: statement.id), ArtifactIndex.intentTitle)
    }

    /// A document-scoped intent names its document. Two chapters' intents both
    /// reading `Became “Craft Intent”` describes neither, and a chapter's intent
    /// is the ordinary case as of M1A.
    func test_aDocumentScopedIntentNamesItsDocument() async throws {
        let store = try await makeProject()
        let statement = try await store.createStatement(kind: .intent,
                                                        scope: .document("ch-1"))
        let title = try XCTUnwrap(index(store).title(of: statement.id))
        XCTAssertTrue(title.contains("Chapter 1"),
                      "a card promoted to a chapter's intent must say which — "
                      + "found: \(title)")
        XCTAssertTrue(title.contains(ArtifactIndex.intentTitle), "found: \(title)")
    }

    /// A document that has since been RENAMED reads with its current title,
    /// because the name is composed at read time and never stored. (The path
    /// deliberately does not move — tripwire 22, `Statement.path`.)
    func test_theNameFollowsARename() async throws {
        let store = try await makeProject()
        let statement = try await store.createStatement(kind: .intent,
                                                        scope: .document("ch-1"))
        store.manifest.structure = [
            StructureItem(id: "ch-1", title: "The falls", type: .document,
                          path: "manuscript/c1.md")]
        let title = try XCTUnwrap(index(store).title(of: statement.id))
        XCTAssertTrue(title.contains("The falls"), "found: \(title)")
    }

    /// The kind, which is what stops a research-note promotion writing over a
    /// statement (`PromotionPerformer.refuseIfNotAResearchNote`). Without a
    /// statement in the index at all, `ArtifactKind.craftIntent` is unreachable
    /// and that refusal is gone.
    func test_anIntentStatementIsACraftIntentToTheIndex() async throws {
        let store = try await makeProject()
        let statement = try await store.createStatement(kind: .intent, scope: .project)
        XCTAssertEqual(index(store).kind(of: statement.id), .craftIntent)
    }

    /// **Only `.intent` is indexed.** Nothing writes a mark naming another kind,
    /// and an entry claiming a visual-language statement is a craft intent would
    /// be a false answer to the reader that decides whether a file is written
    /// over.
    func test_aVisualLanguageStatementIsNotAnArtifactAMarkCanName() async throws {
        let store = try await makeProject()
        let visual = try await store.createStatement(kind: .visualLanguage, scope: .project)
        XCTAssertNil(index(store).title(of: visual.id))
        XCTAssertNil(index(store).kind(of: visual.id))
    }

    /// **The two readers agree.** The sheet reads the index; the canvas
    /// inspector reads `ProjectWindow.artifactTitle`, which is deferred so that
    /// selecting an unpromoted card walks nothing. Two spellings of one name is
    /// how a card comes to say different things about what it became in two
    /// places on the same screen.
    func test_theInspectorsDeferredLookupAndTheSheetsIndexNameAStatementAlike() async throws {
        let store = try await makeProject()
        for scope: Statement.Scope in [.project, .document("ch-1")] {
            let statement = try await store.createStatement(kind: .intent, scope: scope)
            XCTAssertEqual(ProjectWindow.artifactTitle(statement.id, in: store),
                           index(store).title(of: statement.id),
                           "scope: \(scope.rawValue)")
            XCTAssertNotNil(ProjectWindow.artifactTitle(statement.id, in: store),
                            "the control: both really did resolve it")
        }
    }

    /// The control for that agreement: a research item is still resolved by
    /// both, and an id neither holds is nil in both.
    func test_theTwoReadersAlsoAgreeAboutAResearchItemAndAboutNothing() async throws {
        let store = try await makeProject()
        let note = try await store.addResearchTextNote(parentId: nil, title: "The falls")
        XCTAssertEqual(ProjectWindow.artifactTitle(note.id, in: store), "The falls")
        XCTAssertEqual(index(store).title(of: note.id), "The falls")
        XCTAssertNil(ProjectWindow.artifactTitle("res-nope", in: store))
        XCTAssertNil(index(store).title(of: "res-nope"))
    }

    // MARK: - Where Open goes

    /// **Open** on a statement mark means the Intent pane. Sent to the Research
    /// pane instead it selects an id no research tree holds, and the writer's
    /// intent is nowhere — the pane says "Select an item".
    func test_openingAStatementMarkGoesToItsOwnPane() async throws {
        let store = try await makeProject()
        for scope: Statement.Scope in [.project, .document("ch-1")] {
            let statement = try await store.createStatement(kind: .intent, scope: scope)
            XCTAssertEqual(ProjectWindow.statementPane(forMark: statement.id, in: store),
                           .intent, "scope: \(scope.rawValue)")
        }
    }

    /// The control: a research mark still means the Research pane, and so does
    /// an id nothing holds — nil is what sends `openPromotedArtifact` down the
    /// path it has always taken.
    func test_openingAResearchMarkStillGoesToResearch() async throws {
        let store = try await makeProject()
        let note = try await store.addResearchTextNote(parentId: nil, title: "The falls")
        XCTAssertNil(ProjectWindow.statementPane(forMark: note.id, in: store))
        XCTAssertNil(ProjectWindow.statementPane(forMark: "res-nope", in: store))
    }
}
