import XCTest
import MaughamCore
@testable import Maugham

/// Shell plan 2, Task 1 — `ResolveReader`: what a scope holds, read without
/// loading a document. The `snapshot` tests are pure; the fixture tests read a
/// real project whose piece is closed; the census pins that no Resolve source
/// loads.
///
/// Paragraph ids are 4-char from `ParagraphID`'s alphabet (tripwire 8): the
/// fixture's ops cross the `.md` ↔ op-log boundary.
@MainActor
final class ResolveReaderTests: XCTestCase {

    // MARK: - Pure builders

    private let t = Date(timeIntervalSince1970: 1_700_000_000)

    private func note(_ id: String, on docId: String, pid: String? = "aa11",
                      status: AnnotationStatus = .open, runId: String? = nil) -> ProjectAnnotation {
        ProjectAnnotation(docId: docId, annotation: Annotation(
            id: id, kind: .comment, paragraphId: pid, body: id, suggestedText: nil, priorText: nil,
            createdAt: t, createdBySession: nil, status: status, userResponse: nil,
            resolvedAt: nil, isStale: false, compilerRunId: runId))
    }

    private func todo(_ id: String, on docId: String?, pid: String? = nil,
                      status: TaskStatus = .open) -> WriterTask {
        WriterTask(id: id, kind: .paneCreated,
                   anchor: docId.map { TaskAnchor(docId: $0, paragraphId: pid) },
                   body: id, status: status, priority: 0, parentTaskId: nil,
                   createdAt: t, createdBySession: nil)
    }

    private func strain(_ id: String, on docId: String, pid: String = "aa11",
                        text: String = "Two opens.") -> Diagnostic {
        Diagnostic(id: id, docId: docId, anchor: .init(paragraphId: pid, anchorText: text),
                   body: id, category: nil, runId: "run-1", kind: .conformanceStrain)
    }

    private func walk(_ notes: [ProjectAnnotation], unreadable: [String] = [],
                      sequences: [String: [String]] = [:]) -> ProjectAnnotationsSnapshot {
        ProjectAnnotationsSnapshot(annotations: notes, unreadableDocIds: unreadable, sequences: sequences)
    }

    private func ids(_ snapshot: ResolveSnapshot) -> Set<String> { Set(snapshot.items.map(\.id)) }

    private let book = ResolveScope.pieces(docIds: ["doc-a", "doc-b", "doc-c"], includesBookLevel: true)
    private let part = ResolveScope.pieces(docIds: ["doc-a", "doc-b"], includesBookLevel: false)
    private let figure = "fig-aaaa1111"

    /// Notes, to-dos and strains on three chapters, a figure and the Book.
    private func everything(scope: ResolveScope) -> ResolveSnapshot {
        ResolveReader.snapshot(
            scope: scope,
            annotations: walk([note("n-a", on: "doc-a"), note("n-b", on: "doc-b"),
                               note("n-c", on: "doc-c"), note("n-f", on: figure, pid: nil)],
                              sequences: ["doc-a": ["aa11"], "doc-b": ["aa11"], "doc-c": ["aa11"]]),
            tasks: [todo("t-a", on: "doc-a"), todo("t-c", on: "doc-c"),
                    todo("t-book", on: ProjectStore.projectTasksDocId), todo("t-none", on: nil)],
            findings: ["doc-a": [strain("s-a", on: "doc-a")], "doc-c": [strain("s-c", on: "doc-c")]],
            paragraphText: ["aa11": "Two opens."])
    }

    // MARK: - Scopes

    func test_aPieceScopeHoldsThatPiecesOpenNotesTodosAndFindings() {
        let read = everything(scope: .piece(docId: "doc-a"))
        XCTAssertEqual(ids(read), ["note:doc-a/n-a", "todo:doc-a/t-a", "finding:doc-a/s-a"])
        XCTAssertEqual(read.paragraphText, ["aa11": "Two opens."], "a piece carries its paragraphs")
        XCTAssertEqual(read.sequences, ["doc-a": ["aa11"]])
    }

    func test_aBookScopeHoldsEveryPieceAndTheBookLevelTodos() {
        let read = everything(scope: book)
        XCTAssertEqual(ids(read), [
            "note:doc-a/n-a", "note:doc-b/n-b", "note:doc-c/n-c", "note:\(figure)/n-f",
            "todo:doc-a/t-a", "todo:doc-c/t-c",
            "todo:\(ProjectStore.projectTasksDocId)/t-book", "todo:\(ProjectStore.projectTasksDocId)/t-none",
            "finding:doc-a/s-a", "finding:doc-c/s-c",
        ])
        XCTAssertEqual(read.paragraphText, [:], "only a piece carries paragraph text")
    }

    func test_aPartScopeHoldsOnlyItsOwnPiecesAndNoBookLevelTodos() {
        let read = everything(scope: part)
        XCTAssertEqual(ids(read), ["note:doc-a/n-a", "note:doc-b/n-b", "todo:doc-a/t-a", "finding:doc-a/s-a"])
        XCTAssertEqual(Set(read.sequences.keys), ["doc-a", "doc-b"])
    }

    func test_aFigureScopeHoldsThatFiguresNotes() {
        let read = everything(scope: .figure(id: figure))
        XCTAssertEqual(ids(read), ["note:\(figure)/n-f"])
        // A figure's notes come at Book and figure scope only — never a piece's.
        XCTAssertFalse(ids(everything(scope: .piece(docId: "doc-a"))).contains("note:\(figure)/n-f"))
        XCTAssertFalse(ids(everything(scope: part)).contains("note:\(figure)/n-f"))
    }

    func test_editionCanvasInboxPaletteAreOutside() {
        XCTAssertEqual(everything(scope: .outside), .empty)
    }

    func test_aReferencePieceIsElsewhereAndAddsNothingToTheBook() {
        let read = ResolveReader.snapshot(
            scope: .elsewhere(docId: "doc-r"),
            annotations: walk([note("n-r", on: "doc-r")]),
            tasks: [todo("t-r", on: "doc-r")], findings: ["doc-r": [strain("s-r", on: "doc-r")]],
            paragraphText: [:])
        XCTAssertEqual(read, .empty)
    }

    // MARK: - Kinds

    func test_aCheckMintedNoteAppearsOnceAsANote() {
        let read = ResolveReader.snapshot(
            scope: .piece(docId: "doc-a"),
            annotations: walk([note("q-1", on: "doc-a", runId: "run-1")]),
            tasks: [], findings: [:], paragraphText: [:])
        XCTAssertEqual(read.items.count, 1)
        guard case .note(let n) = read.items.first else { return XCTFail("a check's question is a note") }
        XCTAssertEqual(n.annotation.compilerRunId, "run-1")
    }

    func test_onlyASidecarStrainIsReplacedByTheNextCheck() {
        let read = ResolveReader.snapshot(
            scope: .piece(docId: "doc-a"),
            annotations: walk([note("q-1", on: "doc-a", runId: "run-1")]),
            tasks: [todo("t-a", on: "doc-a")],
            findings: ["doc-a": [strain("s-a", on: "doc-a")]], paragraphText: [:])
        let replaced = read.items.filter(\.isReplacedByTheNextCheck).map(\.id)
        XCTAssertEqual(replaced, ["finding:doc-a/s-a"])
        XCTAssertEqual(read.items.count, 3)
    }

    func test_settledNotesAndDoneTodosAreNotItems() {
        let settled: [AnnotationStatus] = [.accepted, .rejected, .archived, .stetted]
        let read = ResolveReader.snapshot(
            scope: .piece(docId: "doc-a"),
            annotations: walk(settled.map { note("n-\($0.rawValue)", on: "doc-a", status: $0) }
                              + [note("n-open", on: "doc-a")]),
            tasks: [todo("t-done", on: "doc-a", status: .done),
                    todo("t-archived", on: "doc-a", status: .archived), todo("t-open", on: "doc-a")],
            findings: [:], paragraphText: [:])
        XCTAssertEqual(ids(read), ["note:doc-a/n-open", "todo:doc-a/t-open"])
    }

    func test_anUnreadablePieceIsNamedNotEmpty() {
        let read = ResolveReader.snapshot(
            scope: part, annotations: walk([note("n-a", on: "doc-a")], unreadable: ["doc-b", "doc-z"]),
            tasks: [], findings: [:], paragraphText: [:])
        XCTAssertEqual(read.unreadableDocIds, ["doc-b"], "named, and only the scope's own")
        XCTAssertEqual(ids(read), ["note:doc-a/n-a"], "one unreadable piece costs the others nothing")
    }

    func test_itemIdsAreKindPrefixedAndUnique() {
        let read = everything(scope: book)
        XCTAssertEqual(Set(read.items.map(\.id)).count, read.items.count)
        XCTAssertEqual(ResolveItem.todo(todo("t-none", on: nil)).docId, ProjectStore.projectTasksDocId)
        XCTAssertEqual(ResolveItem.todo(todo("t-p", on: "doc-a", pid: "bb22")).paragraphId, "bb22")
        XCTAssertEqual(ResolveItem.finding(docId: "doc-a", strain("s", on: "doc-a")).paragraphId, "aa11")
    }

    // MARK: - The read, on a real project whose piece is closed

    private struct Fixture {
        let store: ProjectStore
        let ds: DocumentStore
        let diagnostics: DiagnosticsStore
    }

    /// A novel of one Part holding `doc-a` (closed: its op log seeded through
    /// the production store with one open note on `bb22`, one inline to-do in
    /// `aa11`) and `doc-b` (no op log).
    private func makeFixture() async throws -> Fixture {
        let root = TestTemp.root.appendingPathComponent("RESOLVE-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        for name in ["a", "b"] {
            try Data("\(name) body.".utf8).write(to: root.appendingPathComponent("manuscript/\(name).md"))
        }
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [StructureItem(id: "grp-1", title: "Part One", type: .group, children: [
                StructureItem(id: "doc-a", title: "A", type: .document, path: "manuscript/a.md"),
                StructureItem(id: "doc-b", title: "B", type: .document, path: "manuscript/b.md"),
            ])],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: root.appendingPathComponent(ProjectManifest.fileName))

        let log = OpLogStore(projectURL: root)
        try await log.append(Op(
            opId: "01AAAA", docId: "doc-a", at: t, device: "mac", session: "s", kind: .bootstrap,
            changes: [.init(paragraphId: "aa11", prior: nil, next: "- [ ] fix the dock"),
                      .init(paragraphId: "bb22", prior: nil, next: "Two opens.")],
            sequence: ["aa11", "bb22"]))
        try await log.append(Op(
            opId: "01BBB1", docId: "doc-a", at: t, device: "mac", session: "s", kind: .claudeComment,
            changes: [.init(paragraphId: "bb22", prior: "Two opens.", next: "")],
            provenance: Op.Provenance(sessionId: "s", annotationBody: "closed note")))

        let store = try await ProjectStore.load(from: root)
        let ds = try await DocumentStore.open(url: root)
        store.documentStore = ds
        ds.projectStore = store
        let diagnostics = DiagnosticsStore(projectRoot: root, device: DeviceSlug.make(from: "test-mac"))
        addTeardownBlock { try? fm.removeItem(at: root) }
        return Fixture(store: store, ds: ds, diagnostics: diagnostics)
    }

    private func check(_ strains: [Diagnostic], on docId: String, in f: Fixture) {
        f.diagnostics.replace(
            run: CompilerRun(id: "run-1", at: t, model: "test-model", lastOpId: "01BBB1",
                             deltaSummary: "1 new", intentSnapshot: nil, passId: nil, round: nil,
                             freshEyes: nil, kind: .check),
            diagnostics: strains, docId: docId)
    }

    func test_readingAClosedPieceRegistersNoDocument() async throws {
        let f = try await makeFixture()
        XCTAssertNil(f.ds.document(forDocId: "doc-a"), "premise: the piece is closed")

        let read = ResolveReader.read(scope: .piece(docId: "doc-a"), store: f.store,
                                      documentStore: f.ds, diagnostics: nil)

        let notes = read.items.compactMap { if case .note(let n) = $0 { return n.annotation.body } else { return nil } }
        let todos = read.items.compactMap { if case .todo(let t) = $0 { return t.body } else { return nil } }
        XCTAssertEqual(notes, ["closed note"])
        XCTAssertEqual(todos, ["fix the dock"])
        XCTAssertEqual(read.paragraphText["bb22"], "Two opens.", "the closed piece's text, derived")
        XCTAssertEqual(read.sequences["doc-a"], ["aa11", "bb22"])
        XCTAssertTrue(read.unreadableDocIds.isEmpty)
        XCTAssertNil(f.ds.document(forDocId: "doc-a"), "reading registered no document")
        XCTAssertTrue(f.ds.allOpenDocuments().isEmpty)
    }

    func test_aStrainWhoseAnchorTextChangedIsDropped() async throws {
        let f = try await makeFixture()
        check([strain("s-live", on: "doc-a", pid: "bb22", text: "Two opens."),
               strain("s-stale", on: "doc-a", pid: "bb22", text: "Two opened, once.")],
              on: "doc-a", in: f)

        let read = ResolveReader.read(scope: .piece(docId: "doc-a"), store: f.store,
                                      documentStore: f.ds, diagnostics: f.diagnostics)

        let findings = read.items.filter(\.isReplacedByTheNextCheck).map(\.id)
        XCTAssertEqual(findings, ["finding:doc-a/s-live"],
                       "a strain survives only while its paragraph still says what it quoted")
        XCTAssertNil(f.ds.document(forDocId: "doc-a"))
    }

    // MARK: - Census

    /// What a Resolve source must never spell: a load of any kind.
    static let forbidden = ["Document.load(", ".load(url:", "withAnnotationDocument", "withStatementDocument"]

    static func offenders(in sources: [String: String]) -> [String] {
        sources.flatMap { name, text in
            forbidden.filter { text.contains($0) }.map { "\(name): \($0)" }
        }.sorted()
    }

    func test_noResolveSourceLoadsADocument() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = repo.appendingPathComponent("Maugham/Views/Resolve")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".swift") }
        XCTAssertTrue(names.contains("ResolveReader.swift"), "the census must read the reader itself")
        var sources: [String: String] = [:]
        for name in names {
            sources[name] = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
        }
        XCTAssertEqual(Self.offenders(in: sources), [])

        // The planted offender: every forbidden spelling is caught.
        for spelling in Self.forbidden {
            let planted = sources.merging(["Planted.swift": "let d = try await \(spelling)x)"]) { $1 }
            XCTAssertEqual(Self.offenders(in: planted), ["Planted.swift: \(spelling)"],
                           "the census must catch \(spelling)")
        }
    }
}
