// MaughamTests/Editor/FigureBirthUndoTests.swift
import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **One ⌘Z for a figure line and the figure it made** (report plan 7b Task 3,
/// R7b-5). Driven at the coordinator: a real store makes the figure, Route A
/// (`applyCommandEdit(... alongside:)`) writes its line, and the undo manager
/// is undone and redone directly — no press, no click (tripwire 33). Each
/// store verb's task is awaited through `figureBirthUndoTask`, never polled.
@MainActor
final class FigureBirthUndoTests: XCTestCase {
    override class func setUp() { FontWarmup.ensure() }

    private var temp: TempDirectory!
    private var documentStores: [DocumentStore] = []

    override func setUp() async throws { temp = TempDirectory() }

    override func tearDown() async throws {
        for ds in documentStores { await ds.close() }
        documentStores.removeAll()
        temp.cleanup()
        temp = nil
    }

    // MARK: - Fixture

    final class Box {
        var text: String
        var reported: [String] = []
        init(_ text: String) { self.text = text }
    }

    struct Mounted {
        let box: Box
        let window: KeyTestWindow
        let textView: MaughamTextView
        let coordinator: EditorCoordinator
        var undo: UndoManager { textView.undoManager! }
    }

    private func mount(_ text: String) throws -> Mounted {
        let box = Box(text)
        let binding = Binding(get: { box.text }, set: { box.text = $0 })
        var configuration = EditorSurfaceConfiguration(
            presentation: .init(theme: .light, typography: .defaults, mode: ProseMode(),
                                typewriterScroll: false, sentenceFocus: false,
                                paragraphFocus: false, showElementGutter: false),
            control: EditorControl())
        configuration.answersInsertCommands = true
        configuration.paragraphProviders.commandFailureReporter = { box.reported.append($0) }
        let window = TestWindow.mount(EditorSurface(text: binding, configuration: configuration),
                                      size: CGSize(width: 700, height: 500),
                                      as: KeyTestWindow.self)
        addTeardownBlock { @MainActor in
            window.reportsKey = false
            window.close()
        }
        let textView = try XCTUnwrap(Self.textView(in: window.contentView))
        let coordinator = try XCTUnwrap(textView.delegate as? EditorCoordinator)
        return Mounted(box: box, window: window, textView: textView, coordinator: coordinator)
    }

    private static func textView(in view: NSView?) -> MaughamTextView? {
        guard let view else { return nil }
        if let tv = view as? MaughamTextView { return tv }
        for sub in view.subviews { if let tv = textView(in: sub) { return tv } }
        return nil
    }

    /// The app's undo grouping for a user event, stated (see
    /// `InsertCommandTests.asOneEvent`): the test host runs no event loop.
    private func asOneEvent(_ m: Mounted, _ body: () -> Void) {
        m.undo.groupsByEvent = false
        m.undo.beginUndoGrouping()
        body()
        m.undo.endUndoGrouping()
    }

    /// Typing over the selection, as one event.
    private func type(_ s: String, into m: Mounted) {
        m.window.makeFirstResponder(m.textView)
        asOneEvent(m) {
            m.textView.insertText(s, replacementRange: m.textView.selectedRange())
        }
    }

    private func typeAtEnd(_ s: String, into m: Mounted) {
        m.textView.setSelectedRange(NSRange(location: (m.textView.string as NSString).length,
                                            length: 0))
        type(s, into: m)
    }

    private func novel() async throws -> (ProjectStore, StructureItem) {
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: store.url)
        store.documentStore = ds
        documentStores.append(ds)
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        return (store, chapter)
    }

    private static let line = "![Caption](../figures/table.csv){#tbl:table}"

    /// What Insert ▸ Table will do (Task 4), at the coordinator: make the
    /// figure, then write its line after the text with `Caption` selected and
    /// the figure's birth registered alongside — outside any event, as a Task
    /// continuation lands it.
    private func insertTableFigure(_ m: Mounted, _ store: ProjectStore,
                                   _ chapter: StructureItem) async throws -> FigureRecord {
        let figure = try await store.createFigure(kind: .table, name: "table", piece: chapter.id,
                                                  rows: 3, columns: 3)
        let end = (m.textView.string as NSString).length
        let written = "\n\n" + Self.line
        let caption = NSRange(location: end + 4, length: ("Caption" as NSString).length)
        XCTAssertEqual(m.undo.groupingLevel, 0, "precondition: lands outside an event")
        let wrote = m.coordinator.applyCommandEdit(
            replacing: NSRange(location: end, length: 0), with: written,
            selecting: caption, actionName: "Insert Table",
            alongside: m.coordinator.figureBirthUndo(
                figureId: figure.id, actionName: "Insert Table", store: store))
        XCTAssertTrue(wrote)
        XCTAssertEqual((m.textView.string as NSString).substring(with: m.textView.selectedRange()),
                       "Caption")
        return figure
    }

    private func undo(_ m: Mounted) async {
        m.coordinator.figureBirthUndoTask = nil
        m.undo.undo()
        await m.coordinator.figureBirthUndoTask?.value
    }

    private func redo(_ m: Mounted) async {
        m.coordinator.figureBirthUndoTask = nil
        m.undo.redo()
        await m.coordinator.figureBirthUndoTask?.value
    }

    private func ids(_ store: ProjectStore) -> [String] {
        (store.manifest.figures ?? []).map(\.id)
    }

    private func trashedFigureIds(_ store: ProjectStore) -> [String] {
        store.trashEntries.compactMap { entry in
            guard entry.subject == .figure else { return nil }
            return (try? JSONDecoder().decode(FigureRecord.self, from: entry.itemMetadata))?.id
        }
    }

    // MARK: - Review Focus 1

    /// **Type in the caption, ⌘Z, ⇧⌘Z, ⌘Z**: the first ⌘Z takes back the
    /// typing only; the second takes back the line AND sends the figure to the
    /// Trash; ⇧⌘Z brings the same figure id back with its line; ⌘Z removes it
    /// again. The typing before the insert stays a step of its own.
    func test_oneUndoTakesBackTheLineAndTheFigureAndRedoBringsTheSameFigureBack() async throws {
        let (store, chapter) = try await novel()
        let m = try mount("")
        typeAtEnd("Intro", into: m)
        let figure = try await insertTableFigure(m, store, chapter)
        type("Costs", into: m)
        XCTAssertEqual(m.textView.string, "Intro\n\n![Costs](../figures/table.csv){#tbl:table}")

        await undo(m)
        XCTAssertEqual(m.textView.string, "Intro\n\n" + Self.line, "the first ⌘Z is the typing only")
        XCTAssertEqual(ids(store), [figure.id], "the figure is still in the book")

        XCTAssertEqual(m.undo.undoActionName, "Insert Table")
        await undo(m)
        XCTAssertEqual(m.textView.string, "Intro", "the second ⌘Z takes the line back")
        XCTAssertEqual(ids(store), [], "…and the figure with it")
        XCTAssertEqual(trashedFigureIds(store), [figure.id], "the figure is in the Trash")

        XCTAssertEqual(m.undo.redoActionName, "Insert Table")
        await redo(m)
        XCTAssertEqual(m.textView.string, "Intro\n\n" + Self.line, "⇧⌘Z puts the line back")
        XCTAssertEqual(ids(store), [figure.id], "…and the same figure, id kept")
        XCTAssertEqual(store.manifest.figures?.first?.path, "figures/table.csv")
        XCTAssertEqual(trashedFigureIds(store), [])

        await undo(m)
        XCTAssertEqual(m.textView.string, "Intro", "⌘Z after ⇧⌘Z takes the line back again")
        XCTAssertEqual(ids(store), [], "…and the figure again: the redo re-registered its undo")
        XCTAssertEqual(trashedFigureIds(store), [figure.id])

        await undo(m)
        XCTAssertEqual(m.textView.string, "", "the typing before the insert is its own step")
        XCTAssertEqual(trashedFigureIds(store), [figure.id], "and touches no figure")
        XCTAssertEqual(m.box.reported, [])
    }

    /// **The store verbs chain**: ⇧⌘Z pressed while ⌘Z's removal is still in
    /// flight awaits it, so the figure ends in the book, not the Trash.
    func test_aRedoWaitsForTheRemovalStillInFlight() async throws {
        let (store, chapter) = try await novel()
        let m = try mount("Intro")
        let figure = try await insertTableFigure(m, store, chapter)
        FigureBirthUndo.beforeRemovalForTesting = { await Task.yield() }
        defer { FigureBirthUndo.beforeRemovalForTesting = nil }
        m.undo.undo()
        let removal = m.coordinator.figureBirthUndoTask
        m.undo.redo()
        let restore = m.coordinator.figureBirthUndoTask
        await removal?.value
        await restore?.value
        XCTAssertEqual(m.textView.string, "Intro\n\n" + Self.line)
        XCTAssertEqual(ids(store), [figure.id], "removed, then restored, in order")
        XCTAssertEqual(trashedFigureIds(store), [])
        XCTAssertEqual(m.box.reported, [])
    }

    // MARK: - Refusals still move the text

    /// **A refused removal**: the figure cannot go (here it already went,
    /// out from under the step — the store refuses as it refuses a closed
    /// door, by throwing). The text is still taken back, and the writer is
    /// told why.
    func test_aRefusedRemovalStillTakesTheTextBackAndSaysWhy() async throws {
        let (store, chapter) = try await novel()
        let m = try mount("Intro")
        let figure = try await insertTableFigure(m, store, chapter)
        _ = try await store.removeFigure(id: figure.id)

        await undo(m)
        XCTAssertEqual(m.textView.string, "Intro", "the text undo lands")
        XCTAssertEqual(m.box.reported.count, 1, "\(m.box.reported)")
        XCTAssertTrue(m.box.reported.first?.hasPrefix(
            "The text was taken back, but its figure stays in the book") == true,
                      "\(m.box.reported)")

        // Redo puts the line back; the figure it never trashed is not restored.
        await redo(m)
        XCTAssertEqual(m.textView.string, "Intro\n\n" + Self.line)
        XCTAssertEqual(m.box.reported.count, 1, "nothing to restore, nothing said")
    }

    /// **A refused restore** (another figure took the name while this one was
    /// in the Trash): ⇧⌘Z still puts the line back, the removed figure stays
    /// in the Trash, and the writer is told why. The next ⌘Z takes the line
    /// back without touching the figure that now has the name.
    func test_aRefusedRestoreStillPutsTheLineBackAndLeavesTheFigureInTheTrash() async throws {
        let (store, chapter) = try await novel()
        let m = try mount("Intro")
        let figure = try await insertTableFigure(m, store, chapter)
        await undo(m)
        XCTAssertEqual(ids(store), [])
        let usurper = try await store.createFigure(kind: .table, name: "table", piece: chapter.id)

        await redo(m)
        XCTAssertEqual(m.textView.string, "Intro\n\n" + Self.line, "the text redo lands")
        XCTAssertEqual(ids(store), [usurper.id], "the removed figure did not come back")
        XCTAssertEqual(trashedFigureIds(store), [figure.id], "it stays in the Trash")
        XCTAssertEqual(m.box.reported, [
            "The figure line is back, but its figure stays in the Trash: "
                + "A figure called table already exists; rename it first."
        ])

        await undo(m)
        XCTAssertEqual(m.textView.string, "Intro")
        XCTAssertEqual(ids(store), [usurper.id], "the figure with the name now is not removed")
        XCTAssertEqual(trashedFigureIds(store), [figure.id])
        XCTAssertEqual(m.box.reported.count, 1, "nothing more to say")
    }

    /// **A refused write registers nothing**: the membrane refuses the edit,
    /// so `alongside` is never called and no step is left.
    func test_aRefusedEditRegistersNoFigureBirth() async throws {
        let (store, chapter) = try await novel()
        let m = try mount("Intro")
        let figure = try await store.createFigure(kind: .table, name: "table", piece: chapter.id)
        m.textView.isEditable = false
        var called = false
        let wrote = m.coordinator.applyCommandEdit(
            replacing: NSRange(location: 5, length: 0), with: "\n\n" + Self.line,
            selecting: NSRange(location: 7, length: 0), actionName: "Insert Table",
            alongside: { _ in called = true })
        XCTAssertFalse(wrote)
        XCTAssertFalse(called)
        XCTAssertFalse(m.undo.canUndo)
        XCTAssertEqual(ids(store), [figure.id])
    }
}
