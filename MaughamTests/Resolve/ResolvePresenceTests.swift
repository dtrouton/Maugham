import XCTest
import AppKit
import ApplicationServices
import SwiftUI
import MaughamCore
@testable import Maugham

/// Shell plan 4, Task 3 — the tree's "something to resolve" mark
/// (`ResolvePresence`). The `marks` tests are pure over a Book-scope read;
/// the censuses pin that the read is the window's and loads nothing; the
/// mounted tests draw the mark through the tree host's own builder and read
/// the window's watch filling it from the stores.
///
/// Paragraph ids are 4-char from `ParagraphID`'s alphabet (tripwire 8).
@MainActor
final class ResolvePresenceTests: XCTestCase {

    // MARK: - Pure builders

    private let t = Date(timeIntervalSince1970: 1_700_000_000)

    private func note(_ id: String, on docId: String, pid: String? = "aa11",
                      status: AnnotationStatus = .open) -> ProjectAnnotation {
        ProjectAnnotation(docId: docId, annotation: Annotation(
            id: id, kind: .comment, paragraphId: pid, body: id, suggestedText: nil, priorText: nil,
            createdAt: t, createdBySession: nil, status: status, userResponse: nil,
            resolvedAt: nil, isStale: false, compilerRunId: nil))
    }

    private func todo(_ id: String, on docId: String?, pid: String? = nil) -> WriterTask {
        WriterTask(id: id, kind: .paneCreated,
                   anchor: docId.map { TaskAnchor(docId: $0, paragraphId: pid) },
                   body: id, status: .open, priority: 0, parentTaskId: nil,
                   createdAt: t, createdBySession: nil)
    }

    private func strain(_ id: String, on docId: String, text: String) -> Diagnostic {
        Diagnostic(id: id, docId: docId, anchor: .init(paragraphId: "aa11", anchorText: text),
                   body: id, category: nil, runId: "run-1", kind: .conformanceStrain)
    }

    /// A Book: `doc-a` at the top, a Part `grp-1` holding `doc-b` and a
    /// nested Part `grp-2` holding `doc-c`, and a reference piece `doc-r`.
    private let structure: [StructureItem] = [
        StructureItem(id: "doc-a", title: "A", type: .document, path: "manuscript/a.md"),
        StructureItem(id: "grp-1", title: "Part One", type: .group, children: [
            StructureItem(id: "doc-b", title: "B", type: .document, path: "manuscript/b.md"),
            StructureItem(id: "grp-2", title: "Part Two", type: .group, children: [
                StructureItem(id: "doc-c", title: "C", type: .document, path: "manuscript/c.md"),
            ]),
        ]),
        StructureItem(id: "doc-r", title: "R", type: .document, path: "manuscript/r.md",
                      pieceKind: .reference),
    ]

    private var book: ResolveScope {
        ResolveScope.of(.project, readIn: nil, sourceLanguage: "en", structure: structure, projectType: .novel)
    }

    private func read(notes: [ProjectAnnotation] = [], todos: [WriterTask] = [],
                      figureOwners: [String: String?] = [:],
                      unreadable: [String] = []) -> ResolveSnapshot {
        ResolveReader.snapshot(
            scope: book,
            annotations: ProjectAnnotationsSnapshot(annotations: notes, unreadableDocIds: unreadable,
                                                    sequences: [:]),
            tasks: todos, findings: [:], paragraphText: [:], figureOwners: figureOwners)
    }

    private func marks(_ snapshot: ResolveSnapshot, figureOwners: [String: String?] = [:],
                       sceneIndex: [String: Int]? = nil) -> ResolvePresence.Marks {
        ResolvePresence.marks(snapshot, structure: structure, figureOwners: figureOwners,
                              sceneIndex: sceneIndex)
    }

    // MARK: - Pieces

    func test_aChapterWithAnOpenNoteIsMarked() {
        let m = marks(read(notes: [note("n-a", on: "doc-a"), note("n-b", on: "doc-b", status: .accepted)]))
        XCTAssertEqual(m.pieces, ["doc-a"], "an open note marks its chapter; a settled one does not")
    }

    func test_aClosedChaptersToDoMarksIt() {
        let m = marks(read(todos: [todo("t-a", on: "doc-a")]))
        XCTAssertEqual(m.pieces, ["doc-a"])
    }

    func test_aLiveStrainMarksAndAStaleOneDoesNot() {
        // `DiagnosticsStore.live`'s rule: an anchored strain lives while its
        // paragraph still says what it quoted.
        let sidecar = ["doc-a": [strain("s-live", on: "doc-a", text: "Two opens.")],
                       "doc-b": [strain("s-stale", on: "doc-b", text: "Gone.")]]
        let snapshot = ResolveReader.gather(
            scope: book,
            annotations: ProjectAnnotationsSnapshot(annotations: [], unreadableDocIds: [], sequences: [:]),
            tasks: [], figureOwners: [:],
            liveFindings: { docId, currentText in
                (sidecar[docId] ?? []).filter { currentText($0.anchor!.paragraphId) == $0.anchor!.anchorText }
            },
            paragraphs: { _ in ["aa11": "Two opens."] })
        XCTAssertEqual(marks(snapshot).pieces, ["doc-a"])
    }

    func test_aFiguresNoteMarksItsOwningPiece() {
        let owners: [String: String?] = ["fig-aaaa1111": "doc-a"]
        let m = marks(read(notes: [note("n-f", on: "fig-aaaa1111", pid: nil)], figureOwners: owners),
                      figureOwners: owners)
        XCTAssertEqual(m.pieces, ["doc-a"])
    }

    func test_anUnownedFiguresNoteMarksTheBookOnly() {
        let owners: [String: String?] = ["fig-aaaa1111": nil]
        let m = marks(read(notes: [note("n-f", on: "fig-aaaa1111", pid: nil)], figureOwners: owners),
                      figureOwners: owners)
        XCTAssertEqual(m.pieces, [])
        XCTAssertTrue(m.book)
    }

    func test_theBooksOwnToDosMarkTheBookRow() {
        let m = marks(read(todos: [todo("t-book", on: ProjectStore.projectTasksDocId)]))
        XCTAssertEqual(m.pieces, [], "no chapter carries the Book's own to-do")
        XCTAssertTrue(m.book)
    }

    func test_theBookIsMarkedWhenAnythingInsideIs() {
        XCTAssertTrue(marks(read(notes: [note("n-c", on: "doc-c")])).book)
    }

    func test_nothingWaitingMarksNothing() {
        XCTAssertEqual(marks(read(notes: [note("n-a", on: "doc-a", status: .rejected)])), .none,
                       "a quiet book stays quiet")
    }

    // MARK: - Parts

    func test_aPartIsMarkedWhenAChildIs() {
        let m = marks(read(notes: [note("n-c", on: "doc-c")]))
        XCTAssertEqual(m.pieces, ["doc-c", "grp-2", "grp-1"], "every Part above the chapter")
        XCTAssertTrue(ResolvePresence.partHasMark("grp-1", marks: m, structure: structure))

        let quiet = marks(read(notes: [note("n-a", on: "doc-a")]))
        XCTAssertFalse(quiet.pieces.contains("grp-1"), "a Part with nothing under it stays quiet")
        XCTAssertFalse(ResolvePresence.partHasMark("grp-1", marks: quiet, structure: structure))
        XCTAssertFalse(ResolvePresence.partHasMark("doc-a", marks: quiet, structure: structure),
                       "a chapter is not a Part")
    }

    // MARK: - Scenes

    func test_aSceneIsMarkedWhereItsItemsFall() {
        let script: [StructureItem] = [
            StructureItem(id: "doc-s", title: "Scene 1", type: .document, path: "script.fountain"),
        ]
        let scope = ResolveScope.of(.project, readIn: nil, sourceLanguage: "en", structure: script, projectType: .screenplay)
        let snapshot = ResolveReader.snapshot(
            scope: scope,
            annotations: ProjectAnnotationsSnapshot(
                annotations: [note("n-2", on: "doc-s", pid: "bb22")], unreadableDocIds: [], sequences: [:]),
            tasks: [todo("t-0", on: "doc-s", pid: "aa11")],
            findings: [:], paragraphText: [:], figureOwners: [:])
        // aa11 sits before the first slugline (absent); bb22 in scene 2.
        let m = ResolvePresence.marks(snapshot, structure: script, figureOwners: [:],
                                      sceneIndex: ["bb22": 2, "cc33": 0])
        XCTAssertEqual(m.scenes, [2], "only the scene an item falls in")
        XCTAssertEqual(m.pieces, ["doc-s"], "the script row carries every item, before the first scene too")

        let before = ResolvePresence.marks(
            ResolveReader.snapshot(scope: scope,
                                   annotations: ProjectAnnotationsSnapshot(annotations: [], unreadableDocIds: [],
                                                                           sequences: [:]),
                                   tasks: [todo("t-0", on: "doc-s", pid: "aa11")],
                                   findings: [:], paragraphText: [:], figureOwners: [:]),
            structure: script, figureOwners: [:], sceneIndex: ["bb22": 2])
        XCTAssertEqual(before.scenes, [], "an item before the first slugline marks the script row only")
        XCTAssertEqual(before.pieces, ["doc-s"])
    }

    func test_theSceneIndexIsTheScriptsOwn() {
        let snapshot = ResolveSnapshot(items: [], sequences: ["doc-s": ["aa11", "bb22"]],
                                       paragraphText: ["aa11": "A cold open.", "bb22": "INT. KITCHEN - DAY"],
                                       unreadableDocIds: [])
        let text = "A cold open.\n\nINT. KITCHEN - DAY"
        let script = FountainTokenizer().parse(text)
        let index = ResolvePresence.sceneIndex(snapshot, scope: .piece(docId: "doc-s", includesBookLevel: true),
                                               script: script)
        XCTAssertEqual(index, ["bb22": 0])
        XCTAssertNil(ResolvePresence.sceneIndex(snapshot, scope: book, script: script),
                     "a Book of chapters has no scenes")
    }

    // MARK: - Never marked

    func test_aReferencePieceIsNeverMarked() {
        let snapshot = ResolveSnapshot(items: [.note(note("n-r", on: "doc-r")),
                                               .todo(todo("t-r", on: "doc-r"))],
                                       sequences: [:], paragraphText: [:], unreadableDocIds: [])
        XCTAssertEqual(marks(snapshot), .none)
        let owners: [String: String?] = ["fig-aaaa1111": "doc-r"]
        XCTAssertEqual(marks(read(notes: [note("n-f", on: "fig-aaaa1111", pid: nil)],
                                  figureOwners: owners), figureOwners: owners).pieces, [],
                       "nor through a figure it owns")
    }

    // MARK: - Could not be read (RULING-54; controller's ruling, fix round 1)

    func test_anUnreadablePieceIsUnknownNotQuiet() {
        let m = marks(read(unreadable: ["doc-b"]))
        XCTAssertFalse(m.pieces.contains("doc-b"))
        XCTAssertEqual(ResolvePresence.rowMark(.item("doc-b"), in: m), .unknown,
                       "a chapter that would not read never looks quiet")
        XCTAssertEqual(ResolvePresence.rowMark(.item("grp-1"), in: m), .unknown, "its Part rolls up")
        XCTAssertEqual(ResolvePresence.rowMark(.book, in: m), .unknown, "and the Book")
        XCTAssertEqual(ResolvePresence.rowMark(.item("doc-a"), in: m), .quiet)
    }

    func test_aFilledDotWinsOverAnUnknown() {
        // Something listed on the unreadable piece itself: the dot.
        let own = marks(read(todos: [todo("t-b", on: "doc-b")], unreadable: ["doc-b"]))
        XCTAssertEqual(ResolvePresence.rowMark(.item("doc-b"), in: own), .something)
        XCTAssertFalse(own.unknown.contains("doc-b"))

        // A Part holding one marked and one unreadable piece: the dot.
        let part = marks(read(notes: [note("n-c", on: "doc-c")], unreadable: ["doc-b"]))
        XCTAssertEqual(ResolvePresence.rowMark(.item("doc-b"), in: part), .unknown)
        XCTAssertEqual(ResolvePresence.rowMark(.item("grp-1"), in: part), .something)
        XCTAssertEqual(ResolvePresence.rowMark(.item("grp-2"), in: part), .something)
        XCTAssertEqual(ResolvePresence.rowMark(.book, in: part), .something)
        XCTAssertFalse(part.bookUnknown)
    }

    func test_anUnreadableFigureMakesItsOwnerUnknown() {
        let owners: [String: String?] = ["fig-aaaa1111": "doc-a", "fig-bbbb2222": nil]
        let owned = marks(read(figureOwners: owners, unreadable: ["fig-aaaa1111"]), figureOwners: owners)
        XCTAssertEqual(ResolvePresence.rowMark(.item("doc-a"), in: owned), .unknown,
                       "Status's em dash rule: the owner of an unreadable figure")
        XCTAssertEqual(owned.unknown, ProjectStore.unknownCounts(unreadableDocIds: ["fig-aaaa1111"], owners: owners)
            .subtracting(["fig-aaaa1111"]), "the same pieces Status draws an em dash for")

        let unowned = marks(read(figureOwners: owners, unreadable: ["fig-bbbb2222"]), figureOwners: owners)
        XCTAssertEqual(unowned.unknown, [])
        XCTAssertEqual(ResolvePresence.rowMark(.book, in: unowned), .unknown, "an unowned figure: the Book")
    }

    func test_aReferencePieceIsNeverUnknown() {
        XCTAssertEqual(marks(read(unreadable: ["doc-r"])).unknown, [])
    }

    // MARK: - What each row draws

    /// The one decision every row calls, as a table.
    func test_whatEachRowDraws() {
        let m = ResolvePresence.Marks(pieces: ["doc-a", "grp-1"], book: true, scenes: [2],
                                      unknown: ["doc-b"], bookUnknown: false)
        let table: [(ResolvePresence.Row, ResolvePresence.RowMark)] = [
            (.item("doc-a"), .something), (.item("grp-1"), .something),
            (.item("doc-b"), .unknown), (.item("doc-c"), .quiet),
            (.book, .something), (.scene(2), .something), (.scene(0), .quiet),
        ]
        for (row, expected) in table {
            XCTAssertEqual(ResolvePresence.rowMark(row, in: m), expected, "\(row)")
        }
        let unknownBook = ResolvePresence.Marks(pieces: [], book: false, scenes: [],
                                                unknown: ["doc-b"], bookUnknown: true)
        XCTAssertEqual(ResolvePresence.rowMark(.book, in: unknownBook), .unknown)
        for row in [ResolvePresence.Row.item("doc-a"), .book, .scene(0)] {
            XCTAssertEqual(ResolvePresence.rowMark(row, in: .none), .quiet, "a quiet book draws nothing")
        }
        XCTAssertEqual(ResolvePresenceMark.somethingLabel, "Something to resolve")
        XCTAssertEqual(ResolvePresenceMark.unknownLabel, "Could not be read")
    }

    // MARK: - Censuses

    private static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func source(_ path: String) throws -> String {
        Self.codeOnly(try String(contentsOf: SourceTree.repoRoot.appendingPathComponent(path), encoding: .utf8))
    }

    /// Each row kind's call, the window's mount, the hand-off at the `List`
    /// and the watch's writes — every link the pure tests cannot see.
    static let wiring: [(file: String, spelling: String, what: String)] = [
        ("Maugham/Views/BinderRow.swift",
         "ResolvePresenceMark(ResolvePresence.rowMark(.item(item.id), in: presence))", "a chapter and a Part"),
        ("Maugham/Views/PieceRow.swift",
         "ResolvePresenceMark(ResolvePresence.rowMark(.item(piece.id), in: presence))", "a Collection piece"),
        ("Maugham/Views/ProjectRowLabel.swift",
         "ResolvePresenceMark(ResolvePresence.rowMark(.book, in: presence))", "the Book"),
        ("Maugham/Views/SceneNavigatorPane.swift",
         "ResolvePresenceMark(ResolvePresence.rowMark(.item(documentID), in: treeState.presence))", "the Script"),
        ("Maugham/Views/SceneNavigatorPane.swift",
         "mark: ResolvePresence.rowMark(.scene(index), in: treeState.presence)", "a scene"),
        ("Maugham/Views/SceneNavigatorPane.swift", "ResolvePresenceMark(mark)", "a scene draws its mark"),
        ("Maugham/Views/TreeTopRows.swift",
         ".environment(\\.resolvePresence, state.presence)", "every tree's List hands its rows the marks"),
        ("Maugham/Views/ProjectWindow.swift",
         ".modifier(ResolvePresenceWiring(", "the window mounts the read (and Status's to-dos with it)"),
        ("Maugham/Views/TreeEditionRows.swift",
         "ResolvePresenceMark(ResolvePresence.rowMark(.edition(row.language), in: presence))",
         "an edition (shell p4 Task 6)"),
        ("Maugham/Views/Resolve/ResolvePresence.swift",
         "if state.presence != marks { state.presence = marks }", "the watch writes the marks"),
        ("Maugham/Views/Resolve/ResolvePresence.swift",
         "if state.openToDos != reader.openToDos { state.openToDos = reader.openToDos }",
         "the watch writes Status's to-dos"),
    ]

    static func missing(in sources: [String: String]) -> [String] {
        wiring.filter { !(sources[$0.file] ?? "").contains($0.spelling) }.map(\.what)
    }

    func test_theRowsAndTheWindowAreWired() throws {
        var sources: [String: String] = [:]
        for file in Set(Self.wiring.map(\.file)) { sources[file] = try source(file) }
        XCTAssertEqual(Self.missing(in: sources), [])

        // The census reads: a row that lost its call, or a commented-out
        // mount, is caught.
        var planted = sources
        planted["Maugham/Views/BinderRow.swift"] = "struct BinderRow {}"
        XCTAssertEqual(Self.missing(in: planted), ["a chapter and a Part"])
        planted = sources
        planted["Maugham/Views/ProjectWindow.swift"] = Self.codeOnly("// .modifier(ResolvePresenceWiring(")
        XCTAssertEqual(Self.missing(in: planted), ["the window mounts the read (and Status's to-dos with it)"])
    }

    private static let rowFiles = [
        "Maugham/Views/BinderRow.swift", "Maugham/Views/PieceRow.swift",
        "Maugham/Views/ProjectRowLabel.swift", "Maugham/Views/SceneNavigatorPane.swift",
        "Maugham/Views/BinderView.swift", "Maugham/Views/CollectionPiecesPane.swift",
        "Maugham/Views/TreeTopRows.swift", "Maugham/Views/TreeEditionRows.swift",
    ]
    private static let readSpellings = ["ResolveReader", "ResolvePresence.marks(", "ResolvePresenceReader",
                                        "ResolvePane.refreshed("]

    static func readOffenders(in sources: [String: String]) -> [String] {
        sources.flatMap { name, text in
            readSpellings.filter { text.contains($0) }.map { "\(name): \($0)" }
        }.sorted()
    }

    /// No row reads: every row asks `rowMark` of the window's marks.
    func test_thePresenceReadIsOnTheWindowNotARow() throws {
        var sources: [String: String] = [:]
        for path in Self.rowFiles { sources[path] = try source(path) }
        XCTAssertEqual(Self.readOffenders(in: sources), [])
        XCTAssertEqual(Self.readOffenders(in: ["Planted.swift": "let s = ResolveReader.read(scope: x)"]),
                       ["Planted.swift: ResolveReader"], "the census reads")
    }

    func test_noPresenceSourceLoadsADocument() throws {
        let path = "Maugham/Views/Resolve/ResolvePresence.swift"
        XCTAssertEqual(ResolveReaderTests.offenders(in: [path: try source(path)]), [])
    }

    // MARK: - The reader, driven as the watch drives it (no view, no wait)

    private var temp: TempDirectory!
    private var documentStores: [DocumentStore] = []

    override func setUp() async throws { temp = TempDirectory() }

    override func tearDown() async throws {
        for ds in documentStores { await ds.close() }
        documentStores.removeAll()
        temp?.cleanup()
        temp = nil
    }

    struct Book {
        let store: ProjectStore
        let documentStore: DocumentStore
        let url: URL
        let ids: [String]
    }

    /// A novel: Part `grp-1` holds the first two chapters, Part `grp-2` the
    /// rest. Each chapter in `noted` carries one open note in its op log;
    /// every chapter is closed.
    static func book(in root: URL, chapters: Int, noted: Set<Int>) async throws -> Book {
        let url = root.appendingPathComponent("PRESENCE-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: url.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        var items: [StructureItem] = []
        var ids: [String] = []
        for index in 0..<chapters {
            let id = String(format: "doc-c%03d", index)
            let path = "manuscript/\(id).md"
            try Data("Chapter \(index).\n\nMore words here.".utf8).write(to: url.appendingPathComponent(path))
            items.append(StructureItem(id: id, title: "C\(index)", type: .document, path: path))
            ids.append(id)
        }
        let structure = [
            StructureItem(id: "grp-1", title: "Part One", type: .group, children: Array(items.prefix(2))),
            StructureItem(id: "grp-2", title: "Part Two", type: .group, children: Array(items.dropFirst(2))),
        ]
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: structure, research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: url.appendingPathComponent(ProjectManifest.fileName))
        for index in noted.sorted() {
            try await addNote(to: ids[index], in: url, body: "note on \(ids[index])")
        }
        let store = try await ProjectStore.load(from: url)
        let documentStore = try await DocumentStore.open(url: url)
        store.documentStore = documentStore
        documentStore.projectStore = store
        return Book(store: store, documentStore: documentStore, url: url, ids: ids)
    }

    /// A note landing on a closed chapter, through the production document.
    static func addNote(to id: String, in url: URL, body: String) async throws {
        let doc = try await Document.load(
            url: url.appendingPathComponent("manuscript/\(id).md"), actor: .author,
            session: "boot", presenter: nil)
        let pid = try XCTUnwrap(doc.sequence.first)
        _ = try await doc.addAnnotation(kind: .comment, paragraphId: pid, body: body)
        await doc.close()
    }

    private func book(chapters: Int = 4, noted: Set<Int>) async throws -> Book {
        let book = try await Self.book(in: temp.url, chapters: chapters, noted: noted)
        documentStores.append(book.documentStore)
        return book
    }

    /// The watch's `key` and `update`, as the view runs them.
    @MainActor final class Watch {
        let book: Book
        let reader = ResolvePresenceReader()
        var token = 0
        init(_ book: Book) { self.book = book }

        @MainActor var key: ResolvePresenceReader.Key {
            ResolvePresenceReader.key(store: book.store, documentStore: book.documentStore,
                                      diagnostics: nil, annotationsToken: token, script: nil)
        }

        /// What the view's two tasks do — `update` on the key, then the walk
        /// it asks for — run until the key is still and nothing is asked.
        @MainActor func update() async {
            for _ in 0..<4 {
                let now = key
                reader.update(now, store: book.store, documentStore: book.documentStore, diagnostics: nil)
                while let request = reader.pendingRequest {
                    await reader.run(request, store: book.store, documentStore: book.documentStore,
                                     diagnostics: nil)
                }
                if key == now { return }
            }
        }

        /// Walks the reader has asked for.
        @MainActor var walks: Int { reader.walksRequested }
    }

    func test_theReaderMarksClosedChaptersFromTheStores() async throws {
        let book = try await book(noted: [1, 3])
        let watch = Watch(book)
        await watch.update()
        XCTAssertEqual(watch.reader.marks.pieces, ["doc-c001", "doc-c003", "grp-1", "grp-2"])
        XCTAssertTrue(watch.reader.marks.book)
        XCTAssertNil(book.documentStore.document(forDocId: "doc-c001"), "the read opened no piece")
        XCTAssertEqual(watch.key.structure, book.store.manifest.structure, "the tree's shape is in the key")
    }

    /// **I1**: a chapter moved into another Part with the document order
    /// unchanged moves no read key; its Parts' marks still follow.
    func test_aChapterMovedBetweenPartsMovesThePartsMarks() async throws {
        let book = try await book(noted: [1])
        let watch = Watch(book)
        await watch.update()
        XCTAssertEqual(watch.reader.marks.pieces, ["doc-c001", "grp-1"], "premise")

        // doc-c001 becomes Part Two's first chapter: the pre-order is the same.
        let before = watch.key
        var moved = book.store.manifest.structure
        let chapter = moved[0].children!.removeLast()
        moved[1].children!.insert(chapter, at: 0)
        let after = ResolvePresenceReader.Key(read: before.read, script: before.script, open: before.open,
                                              structure: moved, figureOwners: before.figureOwners)
        XCTAssertEqual(ResolveScope.of(.project, readIn: nil, sourceLanguage: "en", structure: moved, projectType: .novel), before.read.scope,
                       "premise: the document order did not move")
        let walks = watch.walks
        watch.reader.update(after, store: book.store, documentStore: book.documentStore, diagnostics: nil)
        XCTAssertEqual(watch.reader.marks.pieces, ["doc-c001", "grp-2"], "the marks follow the chapter")
        XCTAssertEqual(watch.walks, walks, "a re-mark, not a re-read")
    }

    /// **I1, figures**: a figure changing owner moves its notes' mark.
    func test_aFigureChangingOwnerMovesItsMark() async throws {
        let book = try await book(noted: [])
        let watch = Watch(book)
        await watch.update()
        let base = watch.key
        let figure = "fig-aaaa1111"
        // The figure's note, held as the walk would hold it.
        let snapshot = ResolveSnapshot(items: [.note(note("n-f", on: figure, pid: nil))],
                                       sequences: [:], paragraphText: [:], unreadableDocIds: [])
        let structure = book.store.manifest.structure
        let onC0 = ResolvePresence.marks(snapshot, structure: structure,
                                         figureOwners: [figure: "doc-c000"], sceneIndex: nil)
        let onC3 = ResolvePresence.marks(snapshot, structure: structure,
                                         figureOwners: [figure: "doc-c003"], sceneIndex: nil)
        XCTAssertNotEqual(onC0.pieces, onC3.pieces, "premise: the owner decides")
        // The reader re-marks on an owner change with nothing else moved.
        let moved = ResolvePresenceReader.Key(read: base.read, script: base.script, open: base.open,
                                              structure: base.structure,
                                              figureOwners: [figure: "doc-c003"])
        XCTAssertNotEqual(moved, base, "the owners are in the key")
        // Status's to-dos follow the owner on the same re-mark.
        let figureToDo = [ResolveItem.todo(todo("t-f", on: figure))]
        XCTAssertEqual(ResolvePresence.openToDos(figureToDo, figureOwners: [figure: "doc-c000"]), ["doc-c000": 1])
        XCTAssertEqual(ResolvePresence.openToDos(figureToDo, figureOwners: [figure: "doc-c003"]), ["doc-c003": 1])
        // The reader recomputes both from one update.
        watch.reader.update(moved, store: book.store, documentStore: book.documentStore, diagnostics: nil)
        XCTAssertEqual(watch.reader.openToDos, ResolvePresence.openToDos(
            watch.reader.snapshot.items, figureOwners: moved.figureOwners))
    }

    /// **I2**: opening, editing, typing in and closing a piece walk nothing;
    /// a closed piece's last state is folded in, never lost.
    func test_navigationAndTypingWalkNothing() async throws {
        let book = try await book(chapters: 6, noted: [2, 4])
        let watch = Watch(book)
        await watch.update()
        let walks = watch.walks
        let taskWalks = book.store._debugTasksRebuildCount

        // Open a quiet chapter.
        let id = book.ids[0]
        let doc = try await Document.load(
            url: book.url.appendingPathComponent("manuscript/\(id).md"), actor: .author,
            session: "s", presenter: nil)
        book.documentStore.register(document: doc, for: "manuscript/\(id).md")
        await watch.update()
        XCTAssertFalse(watch.reader.marks.pieces.contains(id))

        // Typing and its burst flush.
        doc.setFullText("Chapter 0, typed.\n\nMore words here.")
        await watch.update()
        try await doc.flushBurstNow()
        await watch.update()

        // A note on the open piece.
        let pid = try XCTUnwrap(doc.sequence.first)
        _ = try await doc.addAnnotation(kind: .comment, paragraphId: pid, body: "while open")
        await watch.update()
        XCTAssertTrue(watch.reader.marks.pieces.contains(id), "the open piece's note marks it live")

        // A to-do typed into the open piece: Status's count moves on the same
        // refresh as the mark (Task 4's column rides this read).
        XCTAssertNil(watch.reader.openToDos[id], "premise")
        doc.setFullText("Chapter 0, typed.\n\n- [ ] check the date")
        try await doc.flushBurstNow()
        await watch.update()
        XCTAssertEqual(watch.reader.openToDos[id], 1, "the to-do counts live, with no walk")

        // Close it: its note stays, folded in from its own last state.
        book.documentStore.unregister(path: "manuscript/\(id).md")
        await doc.close()
        await watch.update()
        XCTAssertTrue(watch.reader.marks.pieces.contains(id), "a closed piece keeps its mark")
        XCTAssertEqual(watch.reader.openToDos[id], 1, "and its to-do count")
        XCTAssertEqual(watch.reader.marks.pieces, [id, "doc-c002", "doc-c004", "grp-1", "grp-2"])

        XCTAssertEqual(watch.walks, walks, "no annotation walk on navigation or typing")
        XCTAssertEqual(book.store._debugTasksRebuildCount, taskWalks, "no task walk either")

        // The closed piece's next event walks once, and agrees.
        watch.token += 1
        await watch.update()
        XCTAssertEqual(watch.walks, walks + 1)
        XCTAssertEqual(watch.reader.marks.pieces, [id, "doc-c002", "doc-c004", "grp-1", "grp-2"])
        XCTAssertEqual(watch.reader.openToDos, [id: 1], "the walk agrees with the folded count")
    }

    /// A burst of closed-piece events is one walk: the token settles once.
    func test_aBurstOfClosedPieceEventsIsOneWalk() async throws {
        let book = try await book(chapters: 6, noted: [])
        let watch = Watch(book)
        await watch.update()
        let walks = watch.walks
        for index in 1...4 {
            try await Self.addNote(to: book.ids[index], in: book.url, body: "round \(index)")
        }
        // The watch's coalescing: four events heard, the token moves once.
        watch.token += 1
        await watch.update()
        XCTAssertEqual(watch.walks, walks + 1, "one walk for the burst")
        XCTAssertEqual(watch.reader.marks.pieces, Set(book.ids[1...4]).union(["grp-1", "grp-2"]))
        XCTAssertGreaterThan(ResolvePresenceReader.coalesce, .zero)
    }

    // MARK: - The walk, off the main actor (fix round 2)

    /// The one-shot answer: the store's own synchronous walk, gathered as
    /// To resolve gathers it — what the chunked walk must end at.
    private func oneShot(_ book: Book) -> (ResolvePresence.Marks, [String: Int]) {
        let manifest = book.store.manifest
        let read = ResolveReader.read(
            scope: ResolveScope.of(.project, readIn: nil, sourceLanguage: "en", structure: manifest.structure, projectType: manifest.type),
            store: book.store, documentStore: book.documentStore, diagnostics: nil)
        let owners = ProjectStore.figureNoteOwners(manifest.figures ?? [])
        return (ResolvePresence.marks(read, structure: manifest.structure, figureOwners: owners, sceneIndex: nil),
                ResolvePresence.openToDos(read.items, figureOwners: owners))
    }

    /// **The walk yields between pieces**: a 20-chapter book is read in
    /// several main-actor steps; with every step already produced, a
    /// main-actor task queued during one step runs before the next (the
    /// loop's `Task.yield`); the marks fill in as it goes, and they end
    /// identical to the one-shot read.
    func test_theWalkYieldsBetweenPiecesAndEndsAtTheOneShotAnswer() async throws {
        let book = try await book(chapters: 20, noted: Set(stride(from: 0, to: 20, by: 3)))
        try await Self.addToDo(to: book.ids[4], in: book.url)
        let watch = Watch(book)
        watch.reader.update(watch.key, store: book.store, documentStore: book.documentStore, diagnostics: nil)
        let request = try XCTUnwrap(watch.reader.pendingRequest, "the first update asks for a walk")
        XCTAssertEqual(watch.reader.marks.pieces, [], "nothing read, nothing drawn")
        XCTAssertEqual(watch.reader.marks.unknown, [], "and never the ring for a piece not yet read")

        // Every step already produced and waiting (the producer the fast
        // side), so only the loop's own yield lets other main-actor work in.
        var produced: [ResolveChunkedWalk.Step] = []
        ResolveChunkedWalk.run(ResolveChunkedWalk.inputs(for: request, store: book.store)) { produced.append($0) }
        let buffered = ImmediateSteps(steps: produced)

        final class Log { var order: [String] = []; var marked: [Int] = [] }
        let log = Log()
        await watch.reader.run(request, steps: buffered, store: book.store,
                               documentStore: book.documentStore, diagnostics: nil) {
            log.order.append("step")
            log.marked.append(watch.reader.marks.pieces.filter { $0.hasPrefix("doc-") }.count)
            // Queued behind this step: it must run before the next one.
            if log.order.count == 1 { Task { @MainActor in log.order.append("other") } }
        }
        let steps = log.order.filter { $0 == "step" }.count
        XCTAssertGreaterThanOrEqual(steps, 3, "read in chunks, not one step: \(log.order)")
        XCTAssertEqual(Array(log.order.prefix(3)), ["step", "other", "step"],
                       "a main-actor task queued during a step runs before the next: \(log.order)")
        XCTAssertEqual(log.marked, log.marked.sorted(), "the marks only fill in")

        let (marks, toDos) = oneShot(book)
        XCTAssertEqual(watch.reader.marks, marks, "the chunked walk ends where the one-shot read does")
        XCTAssertEqual(watch.reader.openToDos, toDos)
        XCTAssertEqual(toDos[book.ids[4]], 1)
        XCTAssertNil(watch.reader.pendingRequest)
    }

    /// **A change arriving mid-walk is neither lost nor counted twice**, with
    /// the walk's real reads interleaved with the writes (the producer
    /// stepped by hand, no sleeps): half the walk reads; notes land in a piece
    /// it has read and one it has not, and a piece opens and gains a note;
    /// the rest of the walk reads AFTER those writes and lands; then the
    /// token moves and a new walk settles it.
    func test_aChangeMidWalkIsNeitherLostNorCountedTwice() async throws {
        let book = try await book(chapters: 6, noted: [0, 5])
        let watch = Watch(book)
        watch.reader.update(watch.key, store: book.store, documentStore: book.documentStore, diagnostics: nil)
        let first = try XCTUnwrap(watch.reader.pendingRequest)
        var inputs = ResolveChunkedWalk.inputs(for: first, store: book.store)
        inputs.chunkSize = 2
        var walker = ResolveChunkedWalk.Walker(inputs)
        func step() throws {
            let next = try XCTUnwrap(walker.next())
            watch.reader.apply(next, generation: first.generation, store: book.store,
                               documentStore: book.documentStore, diagnostics: nil)
        }
        try step()          // trust, and every piece's fingerprint
        try step()          // c000, c001 read

        // Mid-walk writes.
        try await Self.addNote(to: book.ids[0], in: book.url, body: "second on c000")
        try await Self.addNote(to: book.ids[5], in: book.url, body: "second on c005")
        let openId = book.ids[3]
        let doc = try await Document.load(
            url: book.url.appendingPathComponent("manuscript/\(openId).md"), actor: .author,
            session: "s", presenter: nil)
        book.documentStore.register(document: doc, for: "manuscript/\(openId).md")
        _ = try await doc.addAnnotation(kind: .comment, paragraphId: try XCTUnwrap(doc.sequence.first),
                                        body: "live on c003")
        // The events are still settling: the key moves only by the open piece.
        watch.reader.update(watch.key, store: book.store, documentStore: book.documentStore, diagnostics: nil)

        // The rest of the walk reads now, after the writes.
        let late = try XCTUnwrap(walker.next())          // c002, c003
        let last = try XCTUnwrap(walker.next())          // c004, c005
        guard case .pieces(let reads) = last,
              case .read(_, let c005Notes, _, _, _, let c005Token)? = reads.first(where: { $0.docId == book.ids[5] })
        else { return XCTFail("c005 is read in the last chunk") }
        XCTAssertEqual(c005Notes.count, 2, "premise: the read came after the write")
        XCTAssertNotEqual(c005Token, DerivedManuscriptCache.token(forDocId: book.ids[5], in: book.url),
                          "its fingerprint was taken before the write, so it is never trusted past it")
        for next in [late, last] {
            watch.reader.apply(next, generation: first.generation, store: book.store,
                               documentStore: book.documentStore, diagnostics: nil)
        }
        while let next = walker.next() {   // the (empty) figures
            watch.reader.apply(next, generation: first.generation, store: book.store,
                               documentStore: book.documentStore, diagnostics: nil)
        }

        // The closed pieces' events settle into one token move: a new walk.
        watch.token += 1
        await watch.update()

        func notes(on docId: String) -> [String] {
            watch.reader.snapshot.items.compactMap {
                if case .note(let n) = $0, n.docId == docId { return n.annotation.body } else { return nil }
            }.sorted()
        }
        XCTAssertEqual(notes(on: book.ids[0]), ["note on doc-c000", "second on c000"], "not lost")
        XCTAssertEqual(notes(on: book.ids[5]), ["note on doc-c005", "second on c005"], "not doubled")
        XCTAssertEqual(notes(on: openId), ["live on c003"], "the open piece counts once, live")
        let ids = watch.reader.snapshot.items.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "no item twice")
        XCTAssertEqual(watch.reader.marks.pieces, [book.ids[0], openId, book.ids[5], "grp-1", "grp-2"])

        book.documentStore.unregister(path: "manuscript/\(openId).md")
        await doc.close()
    }

    /// A walk superseded by a token move hands nothing it read to the next
    /// walk's count twice: the late steps of the old walk are refused.
    func test_aSupersededWalksLateStepsAreRefused() async throws {
        let book = try await book(chapters: 6, noted: [0, 5])
        let watch = Watch(book)
        watch.reader.update(watch.key, store: book.store, documentStore: book.documentStore, diagnostics: nil)
        let first = try XCTUnwrap(watch.reader.pendingRequest)
        var steps: [ResolveChunkedWalk.Step] = []
        var inputs = ResolveChunkedWalk.inputs(for: first, store: book.store)
        inputs.chunkSize = 2
        ResolveChunkedWalk.run(inputs) { steps.append($0) }
        for step in steps.prefix(2) {
            watch.reader.apply(step, generation: first.generation, store: book.store,
                               documentStore: book.documentStore, diagnostics: nil)
        }
        watch.token += 1
        watch.reader.update(watch.key, store: book.store, documentStore: book.documentStore, diagnostics: nil)
        XCTAssertGreaterThan(try XCTUnwrap(watch.reader.pendingRequest).generation, first.generation)
        for step in steps.dropFirst(2) {
            XCTAssertFalse(watch.reader.apply(step, generation: first.generation, store: book.store,
                                              documentStore: book.documentStore, diagnostics: nil))
        }
        await watch.update()
        XCTAssertEqual(watch.reader.marks.pieces, [book.ids[0], book.ids[5], "grp-1", "grp-2"])
    }

    /// **I1 (round 3): a figure list change mid-walk is not lost.** The walk
    /// read `[fig-a, fig-b]`; while it ran, `fig-c` was added and `fig-b`
    /// (unreadable) deleted. The figures are stale again, a new walk reads
    /// them, and the deleted figure leaves no ring on the Book.
    func test_aFigureListChangeMidWalkIsNotLost() async throws {
        let book = try await book(chapters: 2, noted: [])
        func figure(_ id: String, on piece: String?) -> FigureRecord {
            FigureRecord(id: id, name: id, kind: .table, piece: piece, path: "figures/\(id).csv")
        }
        book.store.manifest.figures = [figure("fig-aaaa1111", on: nil), figure("fig-bbbb2222", on: nil)]
        let watch = Watch(book)
        watch.reader.update(watch.key, store: book.store, documentStore: book.documentStore, diagnostics: nil)
        let request = try XCTUnwrap(watch.reader.pendingRequest)
        XCTAssertTrue(request.readsFigures)
        var inputs = ResolveChunkedWalk.inputs(for: request, store: book.store)
        var steps: [ResolveChunkedWalk.Step] = []
        ResolveChunkedWalk.run(inputs) { steps.append($0) }
        inputs = ResolveChunkedWalk.inputs(for: request, store: book.store)
        // The figures step as the walk would have read it: fig-b would not read.
        steps = steps.map { step in
            guard case .figures = step else { return step }
            return .figures(ResolveChunkedWalk.FigureReads(
                figureIds: inputs.figures.map(\.id), notes: [:], unreadable: ["fig-bbbb2222"], cells: [:]))
        }
        for step in steps.dropLast() {
            watch.reader.apply(step, generation: request.generation, store: book.store,
                               documentStore: book.documentStore, diagnostics: nil)
        }

        // Mid-walk: fig-c added (owned by the first chapter), fig-b deleted.
        book.store.manifest.figures = [figure("fig-aaaa1111", on: nil),
                                       figure("fig-cccc3333", on: book.ids[0])]
        watch.reader.update(watch.key, store: book.store, documentStore: book.documentStore, diagnostics: nil)
        watch.reader.apply(try XCTUnwrap(steps.last), generation: request.generation, store: book.store,
                           documentStore: book.documentStore, diagnostics: nil)
        XCTAssertEqual(ResolvePresence.rowMark(.book, in: watch.reader.marks), .quiet,
                       "a deleted unreadable figure leaves no ring on the Book")

        watch.reader.finish(generation: request.generation)
        let again = try XCTUnwrap(watch.reader.pendingRequest, "the figures are read again")
        XCTAssertTrue(again.readsFigures)
        XCTAssertEqual(ResolveChunkedWalk.inputs(for: again, store: book.store).figures.map(\.id),
                       ["fig-aaaa1111", "fig-cccc3333"], "the added figure is read")
        // Its read lands: its note marks its owner.
        let note = ProjectAnnotation(docId: "fig-cccc3333", annotation: Annotation(
            id: "n-c", kind: .comment, paragraphId: nil, body: "on fig-c", suggestedText: nil, priorText: nil,
            createdAt: t, createdBySession: nil, status: .open, userResponse: nil,
            resolvedAt: nil, isStale: false, compilerRunId: nil))
        watch.reader.apply(.figures(ResolveChunkedWalk.FigureReads(
            figureIds: ["fig-aaaa1111", "fig-cccc3333"], notes: ["fig-cccc3333": [note.annotation]],
            unreadable: [], cells: [:])), generation: again.generation, store: book.store,
            documentStore: book.documentStore, diagnostics: nil)
        watch.reader.finish(generation: again.generation)
        XCTAssertNil(watch.reader.pendingRequest, "nothing stale")
        XCTAssertTrue(watch.reader.marks.pieces.contains(book.ids[0]), "the new figure's note marks its owner")
    }

    /// **Monotonic progress (round 3)**: three token moves each cut a walk
    /// after one chunk; once the events stop the walk still reaches every
    /// piece, and no unchanged piece is read twice.
    func test_restartsMidWalkStillReachTheEndAndReadNothingTwice() async throws {
        let book = try await book(chapters: 12, noted: Set(0..<12))
        let watch = Watch(book)
        watch.reader.update(watch.key, store: book.store, documentStore: book.documentStore, diagnostics: nil)
        for _ in 0..<3 {
            let request = try XCTUnwrap(watch.reader.pendingRequest)
            var inputs = ResolveChunkedWalk.inputs(for: request, store: book.store)
            inputs.chunkSize = 2
            var walker = ResolveChunkedWalk.Walker(inputs)
            for _ in 0..<2 {   // trust, then one chunk
                watch.reader.apply(try XCTUnwrap(walker.next()), generation: request.generation,
                                   store: book.store, documentStore: book.documentStore, diagnostics: nil)
            }
            watch.token += 1   // an event settles: the walk restarts
            watch.reader.update(watch.key, store: book.store, documentStore: book.documentStore, diagnostics: nil)
        }
        XCTAssertEqual(watch.reader.piecesRead, 6, "three cut walks, two new pieces each")
        await watch.update()
        XCTAssertEqual(watch.reader.marks.pieces, Set(book.ids).union(["grp-1", "grp-2"]), "every piece, in the end")
        XCTAssertEqual(watch.reader.piecesRead, 12, "each piece read once: unchanged pieces are skipped")
    }

    /// **Cancelling stops the producer and keeps nothing alive** (round 3):
    /// the reader's own loop is cancelled after its first change; the walk
    /// asks nothing more, its producer exits, and what it captured holds no
    /// store, document or window.
    func test_aCancelledWalkStopsItsProducerAndHoldsNothing() async throws {
        let book = try await book(chapters: 20, noted: Set(0..<20))
        let watch = Watch(book)
        watch.reader.update(watch.key, store: book.store, documentStore: book.documentStore, diagnostics: nil)
        let request = try XCTUnwrap(watch.reader.pendingRequest)

        let inputs = ResolveChunkedWalk.inputs(for: request, store: book.store)
        // Foundation's value types (URL, Data, Date) bridge to classes inside;
        // what matters is that nothing of ours — a store, a document, a
        // window, a reader — is in there.
        func references(_ value: Any, path: String = "inputs", depth: Int = 0) -> [String] {
            if value is URL || value is Data || value is Date || value is String { return [] }
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .class { return [path + ": \(type(of: value))"] }
            guard depth < 8 else { return [] }
            return mirror.children.flatMap { references($0.value, path: path + "." + ($0.label ?? "?"),
                                                        depth: depth + 1) }
        }
        XCTAssertEqual(references(inputs), [], "the producer's inputs are values only")

        let reader = watch.reader
        let store = book.store, documentStore = book.documentStore
        let exited = AsyncStream<Void>.makeStream()
        let consumer = Task { @MainActor in
            await reader.run(request, store: store, documentStore: documentStore, diagnostics: nil,
                             onProducerExit: { exited.continuation.yield(); exited.continuation.finish() },
                             onChange: { withUnsafeCurrentTask { $0?.cancel() } })
        }
        await consumer.value
        var iterator = exited.stream.makeAsyncIterator()
        _ = await iterator.next()   // the producer has stopped
        XCTAssertEqual(reader.pendingRequest, request, "a cancelled walk asks nothing more")
        XCTAssertEqual(reader.piecesRead, ResolveChunkedWalk.chunkSize,
                       "nothing past the step it was cancelled in is applied, buffered or not")
    }

    /// A to-do landing in a closed chapter, through the production document.
    static func addToDo(to id: String, in url: URL) async throws {
        let doc = try await Document.load(
            url: url.appendingPathComponent("manuscript/\(id).md"), actor: .author,
            session: "boot", presenter: nil)
        doc.setFullText("Chapter.\n\n- [ ] fix the date")
        try await doc.flushBurstNow()
        await doc.close()
    }
}

/// Steps already produced, handed out without ever suspending — so the only
/// suspension in the reader's loop is its own `Task.yield`.
struct ImmediateSteps: AsyncSequence {
    typealias Element = ResolveChunkedWalk.Step
    typealias Failure = Never
    let steps: [ResolveChunkedWalk.Step]

    struct AsyncIterator: AsyncIteratorProtocol {
        typealias Failure = Never
        var remaining: ArraySlice<ResolveChunkedWalk.Step>
        mutating func next() async -> ResolveChunkedWalk.Step? { remaining.popFirst() }
        mutating func next(isolation actor: isolated (any Actor)?) async -> ResolveChunkedWalk.Step? {
            remaining.popFirst()
        }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(remaining: steps[...]) }
}
