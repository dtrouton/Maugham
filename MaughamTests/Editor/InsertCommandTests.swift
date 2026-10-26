// MaughamTests/Editor/InsertCommandTests.swift
import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// The Insert menu end to end (plan 3a Task 4; Insert ▸ Table makes a table
/// figure, report plan 7b Task 4): the command posted as the menu posts it,
/// answered by a mounted `EditorSurface` through Route A. Each insert
/// is one ⌘Z step that leaves the writer's earlier typing undoable; the
/// membrane refuses it in a read-only posture, review mode and translation
/// review; and a surface that is not a manuscript (a research note, a
/// statement) never answers. No clicks, no polling after a post: delivery is
/// synchronous on the main thread, so the test posts, then asserts — and
/// Insert ▸ Table's figure, made in a task, is awaited through its handle
/// (`tableFigureTask`).
@MainActor
final class InsertCommandTests: XCTestCase {
    override class func setUp() { FontWarmup.ensure() }

    // MARK: - Fixture

    /// The text a mounted surface's binding holds, and how often it was written.
    final class Box {
        var text: String
        var writes = 0
        var reported: [String] = []
        init(_ text: String) { self.text = text }
    }

    private var temp: TempDirectory!
    private var documentStores: [DocumentStore] = []

    override func setUp() async throws { temp = TempDirectory() }

    override func tearDown() async throws {
        for ds in documentStores { await ds.close() }
        documentStores.removeAll()
        temp.cleanup()
        temp = nil
    }

    struct Mounted {
        let box: Box
        let window: KeyTestWindow
        let textView: NSTextView
        let coordinator: EditorCoordinator
    }

    /// An `EditorSurface` mounted in a window that reports itself key, with the
    /// configuration a host would build. `answersInsertCommands` is what
    /// `EditorHost` says for a Markdown manuscript; the default (false) is what
    /// `ResearchNoteEditor` and `StatementEditorHost` build.
    private func mount(_ text: String, answersInsertCommands: Bool = true,
                       labelsElsewhere: (() -> Set<ManuscriptLabel>)? = nil,
                       tableFigureMaker: FigureIngest.TableFigureMaker? = nil) throws -> Mounted {
        let box = Box(text)
        let binding = Binding(get: { box.text },
                              set: { box.text = $0; box.writes += 1 })
        var configuration = EditorSurfaceConfiguration(
            presentation: .init(theme: .light, typography: .defaults, mode: ProseMode(),
                                typewriterScroll: false, sentenceFocus: false,
                                paragraphFocus: false, showElementGutter: false),
            control: EditorControl())
        configuration.answersInsertCommands = answersInsertCommands
        configuration.paragraphProviders.projectLabelsElsewhere = labelsElsewhere
        configuration.paragraphProviders.tableFigureMaker = tableFigureMaker
        configuration.paragraphProviders.commandFailureReporter = { box.reported.append($0) }
        let window = TestWindow.mount(EditorSurface(text: binding, configuration: configuration),
                                      size: CGSize(width: 700, height: 500),
                                      as: KeyTestWindow.self)
        addTeardownBlock { @MainActor in
            window.reportsKey = false
            window.close()
        }
        let textView = try XCTUnwrap(Self.textView(in: window.contentView),
                                     "the mounted surface has no text view")
        let coordinator = try XCTUnwrap(textView.delegate as? EditorCoordinator)
        XCTAssertTrue(window.isKeyWindow,
                      "the window must report key, or a .keyWindow post reaches nothing "
                      + "and every refusal below proves nothing")
        return Mounted(box: box, window: window, textView: textView, coordinator: coordinator)
    }

    private static func textView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let tv = view as? NSTextView { return tv }
        for sub in view.subviews { if let tv = textView(in: sub) { return tv } }
        return nil
    }

    /// Run `body` as one user event does: in its own top-level undo group.
    ///
    /// In the app, `NSApplication` closes the undo group a keystroke or a menu
    /// item opened when that event ends (`groupsByEvent`). The test host runs no
    /// event loop, so that group never closes — measured: `groupingLevel` stays
    /// 1 after a runloop spin, and the typing and the insert land in one group
    /// that a single ⌘Z takes back together. Bracketing each event by hand is
    /// the app's grouping, stated, not a weaker one.
    private func asOneEvent(_ m: Mounted, _ body: () -> Void) throws {
        let undo = try XCTUnwrap(m.textView.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
    }

    /// Type as the keyboard does (`insertText`, typing undo), one event.
    private func type(_ s: String, into m: Mounted) throws {
        m.window.makeFirstResponder(m.textView)
        m.textView.setSelectedRange(NSRange(location: (m.textView.string as NSString).length,
                                            length: 0))
        try asOneEvent(m) {
            m.textView.insertText(s, replacementRange: m.textView.selectedRange())
        }
    }

    /// A novel whose window's `DocumentStore` is open, and its first chapter.
    private func novel() async throws -> (ProjectStore, StructureItem) {
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: store.url)
        store.documentStore = ds
        documentStores.append(ds)
        return (store, try XCTUnwrap(store.manifest.structure.first))
    }

    /// The maker `EditorHost` builds, over a real store and chapter.
    private func maker(_ store: ProjectStore, _ chapter: StructureItem) throws
        -> FigureIngest.TableFigureMaker
    {
        let path = try XCTUnwrap(chapter.path)
        return { taken in
            try await FigureIngest.makeTableFigure(documentId: chapter.id, documentPath: path,
                                                   taken: taken, store: store)
        }
    }

    /// A maker that records what it was handed and makes nothing (so no line
    /// is written).
    private final class Recorder {
        var taken: [Set<String>] = []
    }

    private func recordingMaker(_ recorder: Recorder) -> FigureIngest.TableFigureMaker {
        { taken in
            recorder.taken.append(taken)
            throw CancellationError()
        }
    }

    /// ⌘⇧T as the menu posts it; then the figure's making and its line's
    /// landing awaited through `tableFigureTask`, never polled. Not bracketed
    /// as an event: the command registers nothing in its own event (the line
    /// lands in a task, in its own group), and AppKit opens an event's group
    /// only at a registration, so a bracket here would be an empty step the
    /// app never makes.
    private func insertTable(_ m: Mounted) async {
        m.coordinator.tableFigureTask = nil
        MaughamEvent.post(.maughamInsertTable, to: .keyWindow)
        await m.coordinator.tableFigureTask?.value
    }

    private func undo(_ m: Mounted) async {
        m.coordinator.figureBirthUndoTask = nil
        m.textView.undoManager?.undo()
        await m.coordinator.figureBirthUndoTask?.value
    }

    private func redo(_ m: Mounted) async {
        m.coordinator.figureBirthUndoTask = nil
        m.textView.undoManager?.redo()
        await m.coordinator.figureBirthUndoTask?.value
    }

    private func figureIds(_ store: ProjectStore) -> [String] {
        (store.manifest.figures ?? []).map(\.id)
    }

    private func trashedFigureIds(_ store: ProjectStore) -> [String] {
        store.trashEntries.compactMap { entry in
            guard entry.subject == .figure else { return nil }
            return (try? JSONDecoder().decode(FigureRecord.self, from: entry.itemMetadata))?.id
        }
    }

    // MARK: - One undo step

    /// **Insert ▸ Table makes a table figure** (report plan 7b Task 4): a
    /// 3×3 figure with a header row in the chapter's piece, named `table`, and
    /// its line written at the caret with a `tbl:` label equal to the name and
    /// `Caption` selected.
    func test_insertTableMakesAHeaderRowTableFigureAndWritesItsLineAtTheCaret() async throws {
        let (store, chapter) = try await novel()
        let m = try mount("", tableFigureMaker: try maker(store, chapter))
        try type("Intro", into: m)

        await insertTable(m)

        XCTAssertEqual(m.textView.string, "Intro\n\n![Caption](../figures/table.csv){#tbl:table}")
        XCTAssertEqual(m.box.text, m.textView.string, "the line reached the binding — the op log's door")
        XCTAssertEqual((m.textView.string as NSString).substring(with: m.textView.selectedRange()),
                       "Caption", "the caption is selected for the writer to type over")
        XCTAssertEqual(m.box.reported, [])
        let figure = try XCTUnwrap(store.manifest.figures?.first)
        XCTAssertEqual(store.manifest.figures?.count, 1)
        XCTAssertEqual(figure.kind, .table)
        XCTAssertEqual(figure.name, "table")
        XCTAssertEqual(figure.piece, chapter.id, "the figure is the chapter's piece's")
        XCTAssertEqual(figure.path, "figures/table.csv")
        let ds = try XCTUnwrap(store.documentStore)
        let doc = try await ds.openFigure(figureId: figure.id)
        XCTAssertEqual(doc.state.table.rows.count, 3)
        XCTAssertEqual(doc.state.table.columns.count, 3)
        XCTAssertEqual(doc.state.table.headerRows, 1, "the first row is a header row")
        await ds.closeFigure(figureId: figure.id)
        XCTAssertEqual(m.textView.undoManager?.undoActionName, "Insert Table")
    }

    /// **Review Focus 1, through the real command path** (the notification
    /// the menu posts, answered by the coordinator): type in the caption, ⌘Z
    /// takes back the typing only; ⌘Z takes back the line and sends the figure
    /// to the Trash; ⇧⌘Z brings the same figure id back with its line; ⌘Z
    /// removes it again; the typing before the insert is its own step.
    func test_insertTableTypeUndoRedoUndo() async throws {
        let (store, chapter) = try await novel()
        let m = try mount("", tableFigureMaker: try maker(store, chapter))
        try type("Intro", into: m)
        await insertTable(m)
        let figureId = try XCTUnwrap(figureIds(store).first)
        let line = "![Caption](../figures/table.csv){#tbl:table}"
        try asOneEvent(m) { m.textView.insertText("Costs", replacementRange: m.textView.selectedRange()) }
        XCTAssertEqual(m.textView.string, "Intro\n\n![Costs](../figures/table.csv){#tbl:table}")

        await undo(m)
        XCTAssertEqual(m.textView.string, "Intro\n\n" + line, "the first ⌘Z is the typing only")
        XCTAssertEqual(figureIds(store), [figureId])

        await undo(m)
        XCTAssertEqual(m.textView.string, "Intro", "the second ⌘Z takes the line back")
        XCTAssertEqual(figureIds(store), [], "…and the figure with it")
        XCTAssertEqual(trashedFigureIds(store), [figureId], "the figure is in the Trash")

        await redo(m)
        XCTAssertEqual(m.textView.string, "Intro\n\n" + line, "⇧⌘Z puts the line back")
        XCTAssertEqual(figureIds(store), [figureId], "…and the same figure, id kept")

        await undo(m)
        XCTAssertEqual(m.textView.string, "Intro")
        XCTAssertEqual(figureIds(store), [], "the redo re-registered its undo")
        XCTAssertEqual(trashedFigureIds(store), [figureId])

        await undo(m)
        XCTAssertEqual(m.textView.string, "", "the typing before the insert is its own step")
        XCTAssertEqual(m.box.reported, [])
    }

    /// R7b-9: the name, and so the label, steps clear of every `tbl:` name in
    /// use — a figure already called `table`, a `@tbl:table_2` reference in
    /// the text, a `tbl:table_3` another chapter defines — and never the label
    /// apart from the name.
    func test_insertTableStepsTheNameAndLabelPastTheTblNamesInUse() async throws {
        let (store, chapter) = try await novel()
        _ = try await store.createFigure(kind: .table, name: "table", piece: chapter.id)
        let m = try mount("See @tbl:table_2.", labelsElsewhere: {
            [ManuscriptLabel(reference: "tbl:table_3")!, ManuscriptLabel(reference: "fig:table_4")!]
        }, tableFigureMaker: try maker(store, chapter))
        m.window.makeFirstResponder(m.textView)
        m.textView.setSelectedRange(NSRange(location: (m.textView.string as NSString).length, length: 0))

        await insertTable(m)

        XCTAssertEqual(m.textView.string,
                       "See @tbl:table_2.\n\n![Caption](../figures/table_4.csv){#tbl:table_4}",
                       "a fig: label does not take a table's name")
        XCTAssertEqual(store.manifest.figures?.map(\.name), ["table", "table_4"])
    }

    /// R7b-6: the figure is made, but by the time its line would land the
    /// document can't be written (the posture locked meanwhile): the figure
    /// goes to the Trash, nothing is written, and the writer is told.
    func test_aRefusedLineSendsTheMadeFigureToTheTrashAndSaysSo() async throws {
        let (store, chapter) = try await novel()
        let real = try maker(store, chapter)
        var m: Mounted!
        m = try mount("Intro", tableFigureMaker: { taken in
            let birth = try await real(taken)
            m.coordinator.setLockEditing(true)
            return birth
        })
        m.window.makeFirstResponder(m.textView)
        await insertTable(m)

        XCTAssertEqual(m.textView.string, "Intro", "the refused line wrote nothing")
        XCTAssertEqual(figureIds(store), [], "the figure is no longer in the book")
        XCTAssertEqual(trashedFigureIds(store).count, 1, "it is in the Trash")
        XCTAssertEqual(m.box.reported, [
            "The table figure was made, but this document can’t be written to now, "
                + "so the figure went to the Trash.",
        ])
        XCTAssertFalse(m.textView.undoManager?.canUndo ?? true, "a refused line left an undo step")
    }

    /// A figure the store refuses to make writes nothing and is told.
    func test_aFigureTheStoreRefusesWritesNothingAndSaysWhy() async throws {
        let m = try mount("Intro", tableFigureMaker: { _ in
            throw FigureEditRefused(site: "createFigure")
        })
        m.window.makeFirstResponder(m.textView)
        await insertTable(m)
        XCTAssertEqual(m.textView.string, "Intro")
        XCTAssertEqual(m.box.reported, ["This Mac may not make a figure here, so no table was inserted."])
    }

    func test_theDiscardSentences() {
        XCTAssertEqual(
            EditorCoordinator.tableFigureDiscardMessage(.documentLeft, trashed: true, name: "table"),
            "The table figure was made, but its document was no longer open, so the figure went to the Trash.")
        XCTAssertEqual(
            EditorCoordinator.tableFigureDiscardMessage(.composing, trashed: false, name: "table_2"),
            "The table figure was made, but it wasn’t placed while you were composing text, "
                + "and it couldn’t be moved to the Trash: it stays in the book as “table_2”.")
        XCTAssertEqual(FigureIngest.tableFigureFailureMessage(for: CancellationError()),
                       "The table figure couldn’t be made, so no table was inserted.")
    }

    func test_insertFootnoteIsOneUndoStepAndTheCaretWaitsAtTheDefinition() throws {
        let m = try mount("")
        try type("A claim.", into: m)
        m.textView.setSelectedRange(NSRange(location: ("A claim" as NSString).length, length: 0))
        let undo = try XCTUnwrap(m.textView.undoManager)

        try asOneEvent(m) { MaughamEvent.post(.maughamInsertFootnote, to: .keyWindow) }

        XCTAssertEqual(m.textView.string, "A claim[^1].\n\n[^1]: ")
        XCTAssertEqual(m.textView.selectedRange(),
                       NSRange(location: ("A claim[^1].\n\n[^1]: " as NSString).length, length: 0),
                       "textDidChange's cursor restore must not pull the caret back")
        XCTAssertEqual(m.box.text, m.textView.string)

        undo.undo()
        XCTAssertEqual(m.textView.string, "A claim.")
        XCTAssertTrue(undo.canUndo, "the typing survives the footnote's undo")
    }

    /// The writer's real flow: type, insert a footnote, type the note. Each is
    /// its own ⌘Z step — the note's typing must not coalesce into the typing
    /// before the insert (whose range the insert has moved).
    func test_typingTheNoteAfterTheInsertIsItsOwnUndoStep() throws {
        let m = try mount("")
        try type("A claim.", into: m)
        try asOneEvent(m) { MaughamEvent.post(.maughamInsertFootnote, to: .keyWindow) }
        try asOneEvent(m) {
            m.textView.insertText("Source.", replacementRange: m.textView.selectedRange())
        }
        XCTAssertEqual(m.textView.string, "A claim.[^1]\n\n[^1]: Source.")
        let undo = try XCTUnwrap(m.textView.undoManager)

        undo.undo()
        XCTAssertEqual(m.textView.string, "A claim.[^1]\n\n[^1]: ", "⌘Z takes back the note")
        undo.undo()
        XCTAssertEqual(m.textView.string, "A claim.", "then the footnote")
        undo.undo()
        XCTAssertEqual(m.textView.string, "", "then the typing before it")
    }

    /// I1: the table's name is unique across the PROJECT. The host's
    /// `projectLabelsElsewhere` (another chapter defines `tbl:table`) reaches
    /// the maker as a taken name, asked when the command runs.
    func test_insertTableHandsTheMakerTheTblNamesOtherDocumentsDefine() async throws {
        var asked = 0
        let recorder = Recorder()
        let m = try mount("Text. See @tbl:cited.", labelsElsewhere: {
            asked += 1
            return [ManuscriptLabel(reference: "tbl:table")!,
                    ManuscriptLabel(reference: "fig:table_2")!]
        }, tableFigureMaker: recordingMaker(recorder))
        XCTAssertEqual(asked, 0, "the walk ran before any command — it must be per command")
        await insertTable(m)
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(recorder.taken, [["table", "cited"]],
                       "another chapter's tbl:table and this text's @tbl:cited are taken; a fig: is not")
    }

    /// Whole-branch review I1: before the window's reference index has built
    /// once, its cached index is empty. Insert Table in chapter 1 still steps
    /// past the `tbl:table` chapter 2 defines, because the host walks the
    /// project while no build has published. The host here is the one
    /// `EditorHost` wires, over a builder that never finishes.
    func test_insertTableBeforeTheIndexIsBuiltSkipsAnotherChaptersLabel() async throws {
        let gate = DispatchSemaphore(value: 0)
        let host = ReferenceIndexHost(builder: { snapshot, memo in
            gate.wait()
            return ReferenceIndexHost.build(snapshot, memo)
        })
        addTeardownBlock { gate.signal(); host.attach(nil) }
        let structure = [StructureItem(id: "ch1", title: "One", type: .document, path: "ch1.md"),
                         StructureItem(id: "ch2", title: "Two", type: .document, path: "ch2.md")]
        host.attach(ReferenceIndexHost.Project(
            structure: { structure },
            research: { [] },
            liveText: { _ in nil },
            tokens: { _ in [:] },
            derivedText: { id in
                id == "ch2" ? "![Two](figures/table.csv){#tbl:table}" : ""
            },
            words: { .english }))
        let recorder = Recorder()
        let m = try mount("Text.", labelsElsewhere: { host.labelsDefined(excluding: "ch1") },
                          tableFigureMaker: recordingMaker(recorder))
        XCTAssertEqual(host.index.version, 0, "the premise: no build has published")
        await insertTable(m)
        XCTAssertEqual(recorder.taken, [["table"]], "chapter 2 already has tbl:table")
    }

    func test_insertFootnoteNumbersPastTheLabelsTheDocumentUses() throws {
        let m = try mount("One[^1].\n\n[^2]: Two.\n\nThree.")
        m.textView.setSelectedRange(NSRange(location: (m.textView.string as NSString).length,
                                            length: 0))
        MaughamEvent.post(.maughamInsertFootnote, to: .keyWindow)
        XCTAssertEqual(m.textView.string, "One[^1].\n\n[^2]: Two.\n\nThree.[^3]\n\n[^3]: ")
    }

    // MARK: - The membrane refuses

    func test_aReadOnlyPostureRefusesBothInserts() throws {
        try assertRefused { $0.setLockEditing(true) }
    }

    func test_reviewModeRefusesBothInserts() throws {
        try assertRefused { $0.setReviewMode(true) }
    }

    func test_translationReviewRefusesBothInserts() throws {
        try assertRefused { $0.setTranslationReview(true) }
    }

    private func assertRefused(_ posture: (EditorCoordinator) -> Void,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let text = "A sentence."
        let recorder = Recorder()
        let m = try mount(text, tableFigureMaker: recordingMaker(recorder))
        posture(m.coordinator)
        let writes = m.box.writes
        let undo = try XCTUnwrap(m.textView.undoManager)
        undo.removeAllActions()

        MaughamEvent.post(.maughamInsertTable, to: .keyWindow)
        MaughamEvent.post(.maughamInsertFootnote, to: .keyWindow)

        XCTAssertEqual(m.textView.string, text, "the membrane let an insert through",
                       file: file, line: line)
        XCTAssertEqual(m.box.writes, writes, "a refused insert reached the binding",
                       file: file, line: line)
        XCTAssertFalse(undo.canUndo, "a refused insert left an undo step",
                       file: file, line: line)
        XCTAssertNil(m.coordinator.tableFigureTask, "a refused Insert Table began making a figure",
                     file: file, line: line)
    }

    // MARK: - Only a manuscript surface answers

    /// A research note's surface (`answersInsertCommands` left false, as
    /// `ResearchNoteEditor` builds it) is a primary editor that answers the
    /// window's other commands, and must not answer these. The control is the
    /// same mount saying true, so the refusal is about the flag and not about a
    /// post that reached nobody.
    func test_aSurfaceThatIsNotAManuscriptIgnoresTheInsertCommands() throws {
        let recorder = Recorder()
        let note = try mount("Research note.", answersInsertCommands: false,
                             tableFigureMaker: recordingMaker(recorder))
        XCTAssertNotNil(note.coordinator.receiverContext(.keyWindow),
                        "precondition: the note answers the window's other commands")

        MaughamEvent.post(.maughamInsertTable, to: .keyWindow)
        MaughamEvent.post(.maughamInsertFootnote, to: .keyWindow)
        XCTAssertEqual(note.textView.string, "Research note.",
                       "an Insert command wrote into a research note")
        XCTAssertNil(note.coordinator.tableFigureTask, "Insert Table began a figure for a research note")

        // Control.
        note.window.reportsKey = false
        let manuscript = try mount("Chapter.")
        MaughamEvent.post(.maughamInsertFootnote, to: .keyWindow)
        XCTAssertNotEqual(manuscript.textView.string, "Chapter.",
                          "the manuscript surface did not answer either — the test above proves nothing")
        XCTAssertEqual(note.textView.string, "Research note.")
    }

    // MARK: - Only the focused editor answers (whole-branch review M1)

    /// A statement pane or a research note in the same window holds the focus:
    /// ⌘⇧T is not the manuscript's, so it neither writes there nor takes the
    /// focus over. The control: the manuscript focused, and a non-text view
    /// (the binder) focused, both answer.
    func test_anotherTextInputWithTheFocusKeepsTheInsertOutOfTheManuscript() async throws {
        let recorder = Recorder()
        let m = try mount("Chapter.", tableFigureMaker: recordingMaker(recorder))
        let sibling = NSTextView(frame: NSRect(x: 0, y: 0, width: 80, height: 20))
        m.window.contentView?.addSubview(sibling)
        m.window.makeFirstResponder(sibling)
        XCTAssertTrue(m.window.firstResponder === sibling, "precondition: the sibling has the focus")

        MaughamEvent.post(.maughamInsertTable, to: .keyWindow)
        MaughamEvent.post(.maughamInsertFootnote, to: .keyWindow)
        MaughamEvent.post(.maughamInsertFigure, to: .keyWindow)
        XCTAssertEqual(m.textView.string, "Chapter.", "an insert reached the unfocused manuscript")
        XCTAssertNil(m.coordinator.tableFigureTask, "Insert Table answered for the unfocused manuscript")
        XCTAssertTrue(m.window.firstResponder === sibling, "the insert pulled the focus over")

        m.window.makeFirstResponder(nil)                  // a non-text view: the window itself
        MaughamEvent.post(.maughamInsertFootnote, to: .keyWindow)
        XCTAssertEqual(m.textView.string, "Chapter.[^1]\n\n[^1]: ",
                       "with no text input focused the manuscript still answers")

        m.window.makeFirstResponder(m.textView)
        await insertTable(m)
        XCTAssertEqual(recorder.taken.count, 1, "the focused manuscript answers Insert Table")
    }

    // MARK: - Census: who may say "this surface answers Insert"

    /// The files allowed to name `answersInsertCommands`: its two declarations,
    /// the one forward, and `EditorHost`, the one host that sets it.
    static let answersInsertCommandsFiles: Set<String> = [
        "Maugham/Editor/EditorSurface.swift",
        "Maugham/Editor/EditorCoordinator.swift",
        "Maugham/Editor/EditorCoordinator+Insert.swift",
        // The completion list opens on a manuscript surface only (plan 3b Task 2).
        "Maugham/Editor/EditorCoordinator+Completion.swift",
        "Maugham/Views/EditorHost.swift",
    ]

    static func filesNamingTheFlag(in files: [(path: String, text: String)]) -> Set<String> {
        Set(files.filter { $0.text.contains("answersInsertCommands") }.map(\.path))
    }

    func test_onlyEditorHostSaysASurfaceAnswersInsert() throws {
        var files: [(path: String, text: String)] = []
        for root in SourceTree.productionRoots {
            for path in try SourceTree.swiftFiles(under: root) {
                files.append((path, try SourceTree.read(path)))
            }
        }
        XCTAssertGreaterThan(files.count, 100, "the walk found almost nothing — vacuous")
        let naming = Self.filesNamingTheFlag(in: files)
        XCTAssertEqual(naming, Self.answersInsertCommandsFiles,
            "A file outside the named list names `answersInsertCommands`. Only EditorHost — "
            + "the Markdown manuscript's editor — may make a surface answer the Insert menu; "
            + "a research note or statement saying true would take a table or a footnote.")
        let host = try SourceTree.read("Maugham/Views/EditorHost.swift")
        XCTAssertTrue(host.contains("answersInsertCommands: !DocumentFormat.ofManuscript(path: path).isScreenplay"),
                      "EditorHost no longer sets the flag, so no manuscript answers Insert")
        XCTAssertTrue(host.contains("tableFigureMaker: {"),
                      "EditorHost no longer hands the editor a table-figure maker, so ⌘⇧T does nothing")
        XCTAssertTrue(host.contains("projectLabelsElsewhere: {"),
                      "EditorHost no longer hands the editor the project's other labels, "
                      + "so a table label can repeat another chapter's")
    }

    /// Control: a planted research-note file that sets the flag is reported.
    func test_theSurfaceCensusFiresOnAPlantedOffender() {
        let planted: [(path: String, text: String)] = [
            ("Maugham/Views/EditorHost.swift", "answersInsertCommands: true"),
            ("Maugham/Views/ResearchNoteEditor.swift",
             "EditorSurfaceConfiguration(control: c, answersInsertCommands: true)"),
            ("Maugham/Views/StatementEditorHost.swift", "isSecondEditorInItsWindow: true"),
        ]
        XCTAssertEqual(Self.filesNamingTheFlag(in: planted)
                        .subtracting(Self.answersInsertCommandsFiles),
                       ["Maugham/Views/ResearchNoteEditor.swift"])
    }

    // MARK: - The menu's enabled state

    func test_theMenuIsEnabledOnlyForAWritableMarkdownManuscriptInTheEditor() {
        let author = Posture(.unrestricted)
        let bare = CentreRoute.editor(altitude: false, cover: nil)
        func gate(posture: Posture? = author, format: DocumentFormat? = .markdown,
                  review: Bool = false, share: Bool = false, translation: Bool = false,
                  route: CentreRoute? = bare) -> Bool {
            InsertMenuGate.isEnabled(posture: posture, format: format, manualReview: review,
                                     shareIsReadOnly: share, isTranslationReview: translation,
                                     route: route)
        }
        XCTAssertTrue(gate(), "a writable Markdown chapter in the editor")
        XCTAssertFalse(gate(posture: .settling), "a posture that refuses .writeText")
        XCTAssertFalse(gate(posture: nil), "no manuscript in the editor")
        XCTAssertFalse(gate(review: true), "review mode")
        XCTAssertFalse(gate(translation: true), "translation review")
        XCTAssertFalse(gate(share: true), "a read-only iCloud share")
        XCTAssertFalse(gate(format: .fountain), "a screenplay")
        XCTAssertFalse(gate(format: nil), "no document path")
        XCTAssertFalse(gate(route: nil), "no project store")
    }

    /// Every centre but the bare editor hides the text an insert would land
    /// in — the covers that draw over a CHAPTER (publish problems, a
    /// translation round) included.
    func test_theMenuIsDisabledUnderEveryCoverAndEveryOtherCentre() {
        let problem = TectonicLogParser.Diagnostic(
            level: .error, file: nil, line: nil, message: "a problem",
            contextLines: [], pieceID: "ch-1", paragraphID: "a1b2")
        let reference = StructureItem(id: "piece-ref", title: "Linked", type: .document,
                                      path: "pieces/ref/.maugham-link.json",
                                      pieceKind: .reference)
        let covers: [CentreCover] = [
            .publishProblems([problem]),
            .translationRound(CentreRouteTests.round),
            .designGate(CentreRouteTests.proposal),
            .books([CentreRouteTests.book]),
            .notice(.neverCompiled),
            .reviewBoard,
        ]
        var routes: [CentreRoute] = covers.flatMap {
            [CentreRoute.editor(altitude: false, cover: $0), .editor(altitude: true, cover: $0)]
        }
        routes += [.editor(altitude: true, cover: nil), .canvas, .paletteWall,
                   .research(id: "r1"), .reference(piece: reference)]
        for route in routes {
            XCTAssertFalse(
                InsertMenuGate.isEnabled(posture: Posture(.unrestricted), format: .markdown,
                                         manualReview: false, shareIsReadOnly: false,
                                         isTranslationReview: false, route: route),
                "the Insert menu is enabled under \(route)")
        }
    }

    // MARK: - Shortcut census

    func test_theInsertShortcutsAreBoundOnceAndListed() throws {
        let app = try SourceTree.read("Maugham/MaughamApp.swift")
        let tokens = DocSyncTests.extractShortcutBindings(from: app).map(\.token)
        XCTAssertGreaterThan(tokens.count, 30, "the extractor read almost nothing — vacuous")
        XCTAssertEqual(Self.duplicates(tokens), [],
                       "MaughamApp.swift binds one key to two menu items")
        let cheatsheet = KeyboardShortcuts.all.flatMap(\.items).map(\.shortcut)
        for token in ["⌘⇧T", "⌘⇧N", "⌘⇧I", "⌘⇧C", "⌘⇧X", "⌘⌥⇧T"] {
            XCTAssertEqual(tokens.filter { $0 == token }.count, 1, "\(token) is not bound once")
            XCTAssertTrue(cheatsheet.contains(token), "\(token) is missing from the ⌘/ cheatsheet")
        }
    }

    func test_theDuplicateCheckFiresOnAPlantedOffender() {
        let planted = """
            Button("A") { }.keyboardShortcut("t", modifiers: [.command, .shift])
            Button("B") { }.keyboardShortcut("t", modifiers: [.shift, .command])
            Button("C") { }.keyboardShortcut("n", modifiers: [.command, .shift])
            """
        let tokens = DocSyncTests.extractShortcutBindings(from: planted).map(\.token)
        XCTAssertEqual(Self.duplicates(tokens), ["⌘⇧T"])
    }

    static func duplicates(_ tokens: [String]) -> [String] {
        Dictionary(grouping: tokens, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
    }
}
