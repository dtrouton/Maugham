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

    // MARK: - Where the request lives, and who takes it back

    /// **The two lines that keep an Open request from outliving what it
    /// described** (fix round 2, N1) — neither of which any runtime test in this
    /// repo can reach, because nothing hosts a `ProjectWindow` and a segment
    /// switch destroying `StatementPane` is SwiftUI's own act.
    ///
    /// The defect: the pane kept a `@State` copy of the request and re-seeded it
    /// on `.onAppear` from the window's, which nothing cleared. So a request the
    /// writer had revoked by moving the binder came back on every later visit to
    /// the pane, for the life of the window, and typing went into a scope they
    /// had already declined. The asymmetry that made it a defect rather than a
    /// preference: the pane's *other* override, `prefersProjectScope`, re-seeds
    /// to its NEUTRAL value on remount, and the copy re-seeded to a stale one.
    ///
    /// So: the window revokes on the selection change (the state the rule is
    /// about is the window's, and it outlives the pane), and the pane keeps no
    /// copy at all — it reads `scopeRequest` where it needs it.
    ///
    /// **Comment-stripped**, for the reason four other censuses in this
    /// directory are: both files are more doc comment than code, and every token
    /// here is the sort of thing their prose discusses.
    func test_theWindowRevokesTheOpenRequestAndThePaneKeepsNoCopyOfIt() throws {
        let window = CanvasSourceCensus.commentsStripped(
            try CanvasSourceCensus.source(at: "Maugham/Views/ProjectWindow.swift"))

        // **WHERE, not merely whether** (fix round 3). `contains` alone left the
        // revocation free to move off the selection change while staying green,
        // which is N1 returning with the census none the wiser. The scan reads
        // the body of that one `.onChange` — from its head to the next modifier
        // that starts with `.onChange(of:`.
        let selectionArm = Self.body(ofOnChangeOf: "selectedItemId", in: window)
        XCTAssertNotNil(selectionArm,
                        "ProjectWindow no longer watches `selectedItemId`, so the "
                        + "scan below cannot mean anything")
        XCTAssertTrue(selectionArm?.contains("statementScopeRequest = nil") == true,
                      "the writer moving the binder does not revoke an Open "
                      + "request: one survives every later visit to the pane, "
                      + "over a selection they have moved")

        // The second revoker: the pane's own scope switch. Without it a
        // `.project` request cannot be got out of at all — no value of
        // `prefersProjectScope` contradicts one (N2).
        XCTAssertTrue(
            window.contains("onStatementScopeSwitchTouched: { statementScopeRequest = nil }"),
            "working the scope switch does not revoke the request, so the switch "
            + "is a control that does nothing on the commonest Open there is")

        let pane = CanvasSourceCensus.commentsStripped(
            try CanvasSourceCensus.source(at: "Maugham/Views/StatementPane.swift"))
        // **A COUNT, because `contains` was satisfied by any one site.** The pane
        // consults the live request in three places — `scope`, the switch's
        // LABEL (`selectedDocumentTitle` → `pickerDocumentId`) and the switch's
        // HIGHLIGHT (`scopeSwitch` → `switchShowsProject`) — and reintroducing a
        // `@State` copy for one while leaving the others is precisely the shape
        // N1 was. Fewer means that regression; more means a reader this census
        // has not been told about, which is the other way it goes stale.
        //
        // (This assertion was written expecting TWO, by an author who had added
        // the third an hour earlier. It went red immediately, which is what a
        // count is for and what a prose sentence would not have done.)
        XCTAssertEqual(
            pane.components(separatedBy: "requested: scopeRequest").count - 1, 3,
            "the pane consults the live request at some number of sites other "
            + "than its three (the scope, the switch's label, the switch's "
            + "highlight) — a copy standing in for one of them is N1")
        XCTAssertTrue(pane.contains("selection: scopeSwitch"),
                      "the switch is bound to something other than the derived "
                      + "scope, which is how its highlight came to contradict the "
                      + "pane under it (N2)")

        // The companion: prove the scan reports an absence rather than always
        // answering true, with a spelling that cannot exist in production.
        XCTAssertFalse(window.contains("statementScopeRequestNotAReal = nil"),
                       "the scan reads the file rather than always answering true")
        XCTAssertNil(Self.body(ofOnChangeOf: "notARealPieceOfState", in: window),
                     "and the closure-body scan reports an absence too")
        // And the arm that proves the STRIPPING, which the plant above cannot.
        XCTAssertFalse(
            CanvasSourceCensus.commentsStripped(
                "// statementScopeRequest = nil in prose\nlet x = 1")
                .contains("statementScopeRequest = nil"),
            "a census that reads comments is satisfied by a paragraph describing "
            + "the line it is meant to require")
    }

    /// The text of one `.onChange(of: <name>)` closure — from its head to
    /// whatever `.onChange(of:` comes next, or the end of the file.
    ///
    /// Crude on purpose: it is enough to say a line is in THAT arm rather than
    /// somewhere else in a 2,000-line view, which is the whole of what the
    /// census above needs. Nil when the view does not watch that state at all,
    /// so the caller can tell "not there" from "not watched".
    private static func body(ofOnChangeOf name: String, in source: String) -> String? {
        let head = ".onChange(of: \(name))"
        guard let start = source.range(of: head) else { return nil }
        let rest = source[start.upperBound...]
        guard let next = rest.range(of: ".onChange(of:") else { return String(rest) }
        return String(rest[..<next.lowerBound])
    }
}
