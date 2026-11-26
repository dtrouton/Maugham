import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **An open statement follows a peer's synced change** (shell plan 3 Task 4
/// fix 2, item 5). The `.opLog` presenter arm re-reads an OPEN statement
/// `Document` through the manuscript's own re-read
/// (`DocumentStore.reReadAfterExternalChange` → `Document.handleExternalLogChange`),
/// so the writer's next keystroke builds on the merged text and the op log's
/// merge keeps both hands' words — the manuscript's `ExternalMergePendingTests`
/// assertions, for a statement.
@MainActor
final class StatementPeerArrivalTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    private struct Fixture {
        let root: URL
        let store: ProjectStore
        let ds: DocumentStore
        let statement: Statement
    }

    /// A keyless novel (no register: every device's lines are kept) with one
    /// piece whose intent reads "Alpha original." / "Beta original.".
    private func makeFixture() async throws -> Fixture {
        let root = TestTemp.root.appendingPathComponent("PEER-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try Data("a body.".utf8).write(to: root.appendingPathComponent("manuscript/a.md"))
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [StructureItem(id: "doc-a", title: "A", type: .document, path: "manuscript/a.md")],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: root.appendingPathComponent(ProjectManifest.fileName))
        let store = try await ProjectStore.load(from: root)
        let ds = try await DocumentStore.open(url: root)
        store.documentStore = ds
        ds.projectStore = store
        addTeardownBlock { try? fm.removeItem(at: root) }
        let statement = try await store.createStatement(kind: .intent, scope: .document("doc-a"))
        try await store.mutateStatementText(of: statement, session: "peer-test") { _ in
            "Alpha original.\n\nBeta original."
        }
        return Fixture(root: root, store: store, ds: ds, statement: statement)
    }

    /// The statement's `Document`, opened and registered as a pane opens it.
    private func openAsAPane(_ f: Fixture) async throws -> Document {
        let document = try await Document.load(
            url: f.store.resolvedProjectPath(f.statement.path), actor: .author,
            session: "pane", presenter: nil)
        f.store.noteStatementDocumentOpened(document, id: f.statement.id)
        return document
    }

    /// A peer's op lands on disk and the presenter fires, as sync delivers it.
    private func arrive(_ op: Op, in f: Fixture) async throws {
        try await OpLogStore(projectURL: f.root).append(op)
        let log = try XCTUnwrap(OpLogStore.opLogFileURLs(forDocId: f.statement.id, in: f.root).first)
        f.ds.presenterDidChangeSubitem(at: log)
    }

    private func peerOp(_ docId: String, _ changes: [Op.ParagraphChange], sequence: [String]? = nil) -> Op {
        Op(opId: ULID.generate(), docId: docId, at: Date(), device: "peer-mac", session: "peer-session",
           kind: .typingBurst, changes: changes, sequence: sequence, provenance: nil)
    }

    private func derived(_ f: Fixture) throws -> String {
        try f.store.statementText(of: f.statement)
    }

    /// A peer's change to paragraph P arrives while the statement is open: the
    /// open document shows it (the writer's un-bursted edit elsewhere kept),
    /// and the writer then types in P — both hands' words survive.
    func test_aPeersChangeReachesTheOpenStatementAndSurvivesTheWritersNextEdit() async throws {
        let f = try await makeFixture()
        let doc = try await openAsAPane(f)
        let p2 = doc.sequence[1]
        doc.setFullText("Alpha EDITED.\n\nBeta original.")
        let revision = f.store.statementTextRevision

        try await arrive(peerOp(doc.docId, [.init(paragraphId: p2, prior: "Beta original.", next: "Beta FROMPEER.")]), in: f)
        await pumpUntil(deadline: 5) { doc.displayText.contains("Beta FROMPEER.") }
        XCTAssertTrue(doc.displayText.contains("Beta FROMPEER."), "the open statement re-read the peer's op")
        XCTAssertTrue(doc.displayText.contains("Alpha EDITED."), "the writer's un-bursted edit survives the merge")
        XCTAssertGreaterThan(f.store.statementTextRevision, revision, "a foreign arrival bumps the revision")

        // The writer types in the peer's paragraph, on the merged text.
        doc.setFullText(doc.displayText.replacingOccurrences(of: "Beta FROMPEER.", with: "Beta FROMPEER, and mine."))
        await f.store.closeStatementDocument(doc, id: f.statement.id)
        let text = try derived(f)
        XCTAssertTrue(text.contains("Alpha EDITED."), text)
        XCTAssertTrue(text.contains("Beta FROMPEER, and mine."), "the peer's words are under the writer's: \(text)")
    }

    /// A peer's inserted paragraph survives the writer's next insert.
    func test_aPeersInsertedParagraphSurvivesTheWritersNextInsert() async throws {
        let f = try await makeFixture()
        let doc = try await openAsAPane(f)
        let (p1, p2) = (doc.sequence[0], doc.sequence[1])

        try await arrive(peerOp(doc.docId, [.init(paragraphId: "pq7z", prior: nil, next: "Peer inserted.")],
                                sequence: [p1, "pq7z", p2]), in: f)
        await pumpUntil(deadline: 5) { doc.displayText.contains("Peer inserted.") }
        XCTAssertEqual(doc.sequence, [p1, "pq7z", p2], "the open statement took the peer's order")

        doc.setFullText(doc.displayText + "\n\nWriter added.")
        await f.store.closeStatementDocument(doc, id: f.statement.id)
        let text = try derived(f)
        XCTAssertTrue(text.contains("Peer inserted."), "the writer's insert did not drop the peer's paragraph: \(text)")
        XCTAssertTrue(text.contains("Writer added."), text)
    }

    /// Our own flush is the re-read's echo: nothing changes and nothing bumps.
    func test_ourOwnFlushIsAnEchoAndBumpsNothing() async throws {
        let f = try await makeFixture()
        let doc = try await openAsAPane(f)
        doc.setFullText("Alpha mine.\n\nBeta original.")
        try await doc.flushBurstNow()
        let revision = f.store.statementTextRevision
        let log = try XCTUnwrap(OpLogStore.opLogFileURLs(forDocId: f.statement.id, in: f.root).first)
        f.ds.presenterDidChangeSubitem(at: log)
        await waitOut(0.3)
        XCTAssertEqual(f.store.statementTextRevision, revision)
        XCTAssertEqual(doc.displayText, "Alpha mine.\n\nBeta original.")
        f.store.forgetStatementDocument(id: f.statement.id)
        await doc.close()
    }

    /// The pane's editor follows the re-read (through its one binding).
    func test_aPeersChangeReachesTheMountedStatementEditor() async throws {
        let f = try await makeFixture()
        let suite = "peer-arrival-\(UUID().uuidString)"
        let preferences = UserPreferences(defaults: UserDefaults(suiteName: suite)!)
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let window = TestWindow.mount(
            AnyView(StatementEditorHost(store: f.store, documentStore: f.ds, kind: .intent,
                                        scope: .document("doc-a"), posture: .author)
                .environment(preferences)),
            size: CGSize(width: 320, height: 400))
        addTeardownBlock { @MainActor in window.contentView = NSView(frame: .zero) }
        await pumpUntil(deadline: 5) { f.store.openStatementDocument(id: f.statement.id) != nil }
        let doc = try XCTUnwrap(f.store.openStatementDocument(id: f.statement.id))
        func editorText() -> String {
            guard let root = window.contentView else { return "" }
            var stack: [NSView] = [root]
            while let view = stack.popLast() {
                if let text = view as? MaughamTextView { return text.string }
                stack += view.subviews
            }
            return ""
        }
        await pumpUntil(deadline: 5) { editorText().contains("Beta original.") }

        try await arrive(peerOp(doc.docId, [.init(paragraphId: doc.sequence[1], prior: "Beta original.",
                                                  next: "Beta FROMPEER.")]), in: f)
        await pumpUntil(deadline: 5) { editorText().contains("Beta FROMPEER.") }
        XCTAssertTrue(editorText().contains("Beta FROMPEER."), "the editor shows the peer's words: \(editorText())")
    }
}
