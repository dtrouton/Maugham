import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **⌘Z in read-through never takes back a figure the writer made before
/// it** (shell read-through Task 2, review I1). A command that makes a table
/// figure writes its line through Route A with the figure's birth registered
/// alongside (`FigureBirthUndo`, whose target is the manager itself, not the
/// text storage). The entry into read-through drops both halves, so ⌘Z
/// cannot trash a figure and leave its line. One row per birth route — the
/// two production callers of `figureBirthUndo` — each driven through the
/// coordinator's own verb and awaited through its task handle (tripwire 33).
@MainActor
final class ReadThroughFigureUndoTests: XCTestCase {
    override class func setUp() { FontWarmup.ensure() }

    final class Box {
        var text: String
        init(_ text: String) { self.text = text }
    }

    struct Mounted {
        let window: KeyTestWindow
        let textView: MaughamTextView
        let coordinator: EditorCoordinator
        var undo: UndoManager { textView.undoManager! }
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

    private func novel() async throws -> (ProjectStore, StructureItem) {
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: store.url)
        store.documentStore = ds
        documentStores.append(ds)
        return (store, try XCTUnwrap(store.manifest.structure.first))
    }

    /// An `EditorSurface` as `EditorHost` builds it for a Markdown manuscript
    /// on `chapter`, writing, in a window that reports itself key.
    private func mount(_ text: String, _ store: ProjectStore, _ chapter: StructureItem) throws -> Mounted {
        let box = Box(text)
        let binding = Binding(get: { box.text }, set: { box.text = $0 })
        let path = try XCTUnwrap(chapter.path)
        var configuration = EditorSurfaceConfiguration(
            presentation: .init(theme: .light, typography: .defaults, mode: ProseMode(),
                                typewriterScroll: false, sentenceFocus: false,
                                paragraphFocus: false, showElementGutter: false),
            control: EditorControl())
        configuration.answersInsertCommands = true
        configuration.paragraphProviders.documentId = chapter.id
        configuration.paragraphProviders.tableFigureMaker = { request in
            try await FigureIngest.makeTableFigure(documentId: chapter.id, documentPath: path,
                                                   request: request, store: store)
        }
        let window = TestWindow.mount(EditorSurface(text: binding, configuration: configuration),
                                      size: CGSize(width: 700, height: 500),
                                      as: KeyTestWindow.self)
        addTeardownBlock { @MainActor in
            window.reportsKey = false
            window.close()
        }
        let textView = try XCTUnwrap(Self.textView(in: window.contentView))
        let coordinator = try XCTUnwrap(textView.delegate as? EditorCoordinator)
        XCTAssertTrue(window.isKeyWindow, "premise: the key's post reaches this editor")
        window.makeFirstResponder(textView)
        return Mounted(window: window, textView: textView, coordinator: coordinator)
    }

    private static func textView(in view: NSView?) -> MaughamTextView? {
        guard let view else { return nil }
        if let tv = view as? MaughamTextView { return tv }
        for sub in view.subviews { if let tv = textView(in: sub) { return tv } }
        return nil
    }

    private func figureIds(_ store: ProjectStore) -> [String] {
        (store.manifest.figures ?? []).map(\.id)
    }

    /// The entry, then ⌘Z as Edit ▸ Undo validates it: nothing to take back.
    private func assertTheEntryLeavesNothingToUndo(_ m: Mounted, _ store: ProjectStore,
                                                   _ chapter: StructureItem,
                                                   file: StaticString = #filePath, line: UInt = #line) {
        let text = m.textView.string, figures = figureIds(store)
        ReadThrough.post(.init(docId: chapter.id, on: true))
        XCTAssertTrue(m.coordinator.isInReadThrough, file: file, line: line)
        XCTAssertFalse(m.undo.canUndo, "neither the line nor the figure's birth is left for ⌘Z",
                       file: file, line: line)
        // Edit ▸ Undo, validated where its action lands: off.
        let action = Selector(("undo:"))
        var responder: NSResponder? = m.window.firstResponder
        while let current = responder, !current.responds(to: action) { responder = current.nextResponder }
        // A chain no responder answers would validate nothing: that is a
        // failure of the premise, never a silent pass.
        guard let target = responder else {
            XCTFail("no responder in the chain answers undo:", file: file, line: line)
            return
        }
        let item = NSMenuItem(title: "Undo", action: action, keyEquivalent: "z")
        let enabled = (target as? NSUserInterfaceValidations)?.validateUserInterfaceItem(item)
            ?? (target as? NSMenuItemValidation)?.validateMenuItem(item) ?? true
        XCTAssertFalse(enabled, "Edit ▸ Undo is off at \(target)", file: file, line: line)
        XCTAssertEqual(m.textView.string, text, file: file, line: line)
        XCTAssertEqual(figureIds(store), figures, "the figure stays in the book", file: file, line: line)
    }

    func test_insertTable_thenReadThrough_thenCommandZTrashesNoFigure() async throws {
        let (store, chapter) = try await novel()
        let m = try mount("Intro", store, chapter)
        m.textView.setSelectedRange(NSRange(location: 5, length: 0))
        m.coordinator.tableFigureTask = nil
        XCTAssertNotNil(m.coordinator.insertTableFigure())
        await m.coordinator.tableFigureTask?.value
        XCTAssertEqual(figureIds(store).count, 1, "premise: Insert ▸ Table made the figure")
        XCTAssertTrue(m.undo.canUndo, "premise: its line and birth are one step")
        assertTheEntryLeavesNothingToUndo(m, store, chapter)
    }

    func test_convertToTableFigure_thenReadThrough_thenCommandZTrashesNoFigure() async throws {
        let (store, chapter) = try await novel()
        let m = try mount("Intro\n\n| A | B |\n| --- | --- |\n| 1 | 2 |", store, chapter)
        m.coordinator.tableFigureTask = nil
        m.coordinator.convertTableToFigure(at: (m.textView.string as NSString).range(of: "| A").location)
        await m.coordinator.tableFigureTask?.value
        XCTAssertEqual(figureIds(store).count, 1, "premise: Convert made the figure")
        XCTAssertTrue(m.textView.string.contains("](../figures/"), "premise: the line replaced the table")
        XCTAssertTrue(m.undo.canUndo)
        assertTheEntryLeavesNothingToUndo(m, store, chapter)
    }
}
