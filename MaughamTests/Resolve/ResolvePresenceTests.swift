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
        ResolveScope.of(.project, structure: structure, projectType: .novel)
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
        let scope = ResolveScope.of(.project, structure: script, projectType: .screenplay)
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

    func test_anUnreadablePieceCarriesNoMark() {
        let m = marks(read(todos: [todo("t-b", on: "doc-b")], unreadable: ["doc-b"]))
        XCTAssertFalse(m.pieces.contains("doc-b"), "no mark, and no claim of emptiness either")
    }

    // MARK: - Censuses

    private static let rowFiles = [
        "Maugham/Views/BinderRow.swift", "Maugham/Views/PieceRow.swift",
        "Maugham/Views/ProjectRowLabel.swift", "Maugham/Views/SceneNavigatorPane.swift",
        "Maugham/Views/BinderView.swift", "Maugham/Views/CollectionPiecesPane.swift",
        "Maugham/Views/TreeTopRows.swift",
    ]
    private static let readSpellings = ["ResolveReader", "ResolvePresence.marks(", "ResolvePane.refreshed("]

    static func readOffenders(in sources: [String: String]) -> [String] {
        sources.flatMap { name, text in
            readSpellings.filter { text.contains($0) }.map { "\(name): \($0)" }
        }.sorted()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: SourceTree.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// No row reads: every row looks its id up in the window's marks, and the
    /// one read is mounted on the window.
    func test_thePresenceReadIsOnTheWindowNotARow() throws {
        var sources: [String: String] = [:]
        for path in Self.rowFiles { sources[path] = try source(path) }
        XCTAssertEqual(Self.readOffenders(in: sources), [])
        XCTAssertEqual(Self.readOffenders(in: ["Planted.swift": "let s = ResolveReader.read(scope: x)"]),
                       ["Planted.swift: ResolveReader"], "the census reads")

        XCTAssertTrue(try source("Maugham/Views/ProjectWindow.swift")
            .contains(".modifier(ResolvePresenceWiring("), "the window mounts the read")
        XCTAssertTrue(try source("Maugham/Views/TreeTopRows.swift")
            .contains(".environment(\\.resolvePresence, state.presence)"),
                      "every tree's `List` hands its rows the marks")
    }

    func test_noPresenceSourceLoadsADocument() throws {
        let path = "Maugham/Views/Resolve/ResolvePresence.swift"
        XCTAssertEqual(ResolveReaderTests.offenders(in: [path: try source(path)]), [])
    }

    // MARK: - Mounted

    private var windows: [NSWindow] = []
    private var documentStores: [DocumentStore] = []

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        for ds in documentStores { await ds.close() }
        documentStores.removeAll()
    }

    /// A novel: `doc-a` at the top (closed, one open note), and Part `grp-1`
    /// holding `doc-b` (closed, one open to-do) and `doc-c` (quiet).
    private func novel() async throws -> ProjectStore {
        let root = TestTemp.root.appendingPathComponent("PRESENCE-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        for name in ["a", "b", "c"] {
            try Data("\(name) body.".utf8).write(to: root.appendingPathComponent("manuscript/\(name).md"))
        }
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [
                StructureItem(id: "doc-a", title: "A", type: .document, path: "manuscript/a.md"),
                StructureItem(id: "grp-1", title: "Part One", type: .group, children: [
                    StructureItem(id: "doc-b", title: "B", type: .document, path: "manuscript/b.md"),
                    StructureItem(id: "doc-c", title: "C", type: .document, path: "manuscript/c.md"),
                ]),
            ],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: root.appendingPathComponent(ProjectManifest.fileName))

        let log = OpLogStore(projectURL: root)
        try await log.append(Op(
            opId: "01AAAA", docId: "doc-a", at: t, device: "mac", session: "s", kind: .bootstrap,
            changes: [.init(paragraphId: "bb22", prior: nil, next: "Two opens.")],
            sequence: ["bb22"]))
        try await log.append(Op(
            opId: "01BBB1", docId: "doc-a", at: t, device: "mac", session: "s", kind: .claudeComment,
            changes: [.init(paragraphId: "bb22", prior: "Two opens.", next: "")],
            provenance: Op.Provenance(sessionId: "s", annotationBody: "closed note")))
        try await log.append(Op(
            opId: "01CCCC", docId: "doc-b", at: t, device: "mac", session: "s", kind: .bootstrap,
            changes: [.init(paragraphId: "aa11", prior: nil, next: "- [ ] fix the dock")],
            sequence: ["aa11"]))

        let store = try await ProjectStore.load(from: root)
        let ds = try await DocumentStore.open(url: root)
        store.documentStore = ds
        ds.projectStore = store
        documentStores.append(ds)
        addTeardownBlock { try? fm.removeItem(at: root) }
        return store
    }

    /// The window's watch fills the marks from the stores, the pieces closed.
    func test_theWindowsWatchMarksClosedChaptersFromTheStores() async throws {
        let store = try await novel()
        let ds = try XCTUnwrap(store.documentStore)
        let state = BinderTreeSectionsState()
        let window = TestWindow.mount(
            Color.clear.modifier(ResolvePresenceWiring(
                store: store, documentStore: ds, url: store.url, window: nil, state: state,
                diagnostics: nil, script: nil)),
            size: CGSize(width: 100, height: 100))
        windows.append(window)

        let filled = await pumpUntil(deadline: 5) { state.presence != .none }
        XCTAssertTrue(filled, "the watch never wrote the marks")
        XCTAssertEqual(state.presence.pieces, ["doc-a", "doc-b", "grp-1"])
        XCTAssertTrue(state.presence.book)
        XCTAssertNil(ds.document(forDocId: "doc-a"), "the read opened no piece")
    }

    /// Every label (`AXDescription`) and title under `element`.
    static func axDescriptions(under element: AXUIElement, depth: Int = 0) -> [String] {
        guard depth < 60 else { return [] }
        var out: [String] = []
        for attribute in [kAXDescriptionAttribute, kAXTitleAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               let text = value as? String, !text.isEmpty { out.append(text) }
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return out }
        return out + list.flatMap { axDescriptions(under: $0, depth: depth + 1) }
    }

    /// **A book with one marked chapter draws the mark on exactly the marked
    /// rows**: the chapter, the Book, and — collapsed or open — its Part.
    func test_aMarkedChapterDrawsTheMarkOnItsRowsOnly() async throws {
        let store = try await novel()
        let read = ResolveReader.read(
            scope: ResolveScope.of(.project, structure: store.manifest.structure, projectType: .novel),
            store: store, documentStore: try XCTUnwrap(store.documentStore), diagnostics: nil)
        // Only doc-b's to-do: one marked chapter, inside the Part.
        let one = ResolveSnapshot(items: read.items.filter { $0.docId == "doc-b" },
                                  sequences: read.sequences, paragraphText: [:], unreadableDocIds: [])
        let state = BinderTreeSectionsState()
        state.presence = ResolvePresence.marks(
            one, structure: store.manifest.structure, figureOwners: [:], sceneIndex: nil)
        state.expandedStructureGroups = ["grp-1"]
        var subject = WindowSubject(open: .project, faces: .project)
        let binding = Binding(get: { subject }, set: { subject = $0 })
        let window = TestWindow.mount(
            TreeHostFixture.binder(store: store, subject: binding, treeState: state),
            size: CGSize(width: 320, height: 600))
        windows.append(window)
        pump(0.4)

        // Read through the accessibility API itself, the app's windows only
        // (never its menus): the KVC walk (`axElements`) stops at the
        // outline, and a Part's label is read with its title ("Part One,
        // Something to resolve").
        func dots() throws -> Int {
            try requireAssistiveClient()
            var windows: CFTypeRef?
            guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()),
                                                kAXWindowsAttribute as CFString, &windows) == .success,
                  let list = windows as? [AXUIElement] else { return 0 }
            return list.flatMap { Self.axDescriptions(under: $0) }
                .filter { $0.contains(ResolvePresenceDot.label) }.count
        }
        XCTAssertEqual(try dots(), 3, "doc-b, its Part and the Book; doc-a and doc-c stay quiet")

        state.expandedStructureGroups = []
        pump(0.4)
        XCTAssertEqual(try dots(), 2, "a collapsed Part still says something inside waits")

        state.presence = .none
        pump(0.4)
        XCTAssertEqual(try dots(), 0, "a quiet book draws nothing")
    }
}
