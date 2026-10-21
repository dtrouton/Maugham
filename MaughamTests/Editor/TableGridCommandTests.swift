// MaughamTests/Editor/TableGridCommandTests.swift
import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// The table grid editor's editor side (report foundations plan 3b Task 5,
/// R-3b-3): Edit Table… and the delimiter-row double-click open the host's
/// grid on the caret's table, and its Save lands as ONE Route A step — refused,
/// writing nothing, when the table changed while the sheet was open or the
/// posture is read-only. The host's sheet is stood in for by a `tableEditor`
/// closure that answers at once (the real one is `TableGridPresenter`,
/// `TableGridModelTests`); no click is synthesised (tripwire 33) — the
/// double-click's wiring is read from the source by
/// `TripwireGrepTests.test_theTableDoubleClickIsADoubleClickOnTheDelimiterRow`.
@MainActor
final class TableGridCommandTests: XCTestCase {
    override class func setUp() { FontWarmup.ensure() }

    // MARK: - Fixture

    final class Box {
        var text: String
        var requests: [TableGridRequest] = []
        var reported: [String] = []
        /// What the stand-in sheet does while it is "open".
        var whileOpen: (() -> Void)?
        /// What the stand-in sheet hands back (nil: Cancel).
        var answer: (TableGridRequest) -> TableText? = { _ in nil }
        init(_ text: String) { self.text = text }
    }

    @MainActor struct Mounted {
        let box: Box
        let window: KeyTestWindow
        let textView: MaughamTextView
        let coordinator: EditorCoordinator
        var undo: UndoManager { textView.undoManager! }
        var string: String { textView.string }
    }

    private func mount(_ text: String, elsewhere: Set<ManuscriptLabel> = [],
                       grid: Bool = true,
                       presenter: TableGridPresenter? = nil) throws -> Mounted {
        let box = Box(text)
        let binding = Binding(get: { box.text }, set: { box.text = $0 })
        var configuration = EditorSurfaceConfiguration(
            presentation: .init(theme: .light, typography: .defaults, mode: ProseMode(),
                                typewriterScroll: false, sentenceFocus: false,
                                paragraphFocus: false, showElementGutter: false),
            control: EditorControl())
        configuration.answersInsertCommands = true
        configuration.paragraphProviders.projectLabelsElsewhere = { elsewhere }
        configuration.paragraphProviders.commandFailureReporter = { box.reported.append($0) }
        if let presenter {
            configuration.paragraphProviders.tableEditor = { await presenter.present($0) }
        } else if grid {
            configuration.paragraphProviders.tableEditor = { request in
                box.requests.append(request)
                box.whileOpen?()
                return box.answer(request)
            }
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
        window.makeFirstResponder(textView)
        textView.undoManager?.removeAllActions()
        return Mounted(box: box, window: window, textView: textView, coordinator: coordinator)
    }

    private static func textView(in view: NSView?) -> MaughamTextView? {
        guard let view else { return nil }
        if let tv = view as? MaughamTextView { return tv }
        for sub in view.subviews { if let tv = textView(in: sub) { return tv } }
        return nil
    }

    private func location(of needle: String, in m: Mounted) -> Int {
        (m.string as NSString).range(of: needle).location
    }

    private static let table = """
        | Name | Qty |
        |---|---|
        | Apple | 3 |
        Table: Fruit {#tbl:fruit}
        """
    private static let document = "Intro.\n\n" + table + "\n\nAfter."

    /// The table with a row added and a column right-aligned: what a Save hands back.
    private static func edited(_ request: TableGridRequest) -> TableText {
        var t = request.table
        t.rows.append(["Kiwi", "12"])
        t.alignments[1] = .trailing
        return t
    }

    // MARK: - Save

    func test_saveWritesTheFormattedTableAsOneUndoStepWithTheCaretInTheFirstCell() async throws {
        let m = try mount(Self.document)
        m.box.answer = Self.edited
        XCTAssertTrue(m.undo.groupsByEvent, "the premise: the default grouping, as in the app")
        m.textView.setSelectedRange(NSRange(location: location(of: "Apple", in: m), length: 0))

        await m.coordinator.editTable()?.value

        let request = try XCTUnwrap(m.box.requests.first)
        XCTAssertEqual(request.table, TableText(parsing: Self.table))
        XCTAssertTrue(request.mayWrite)
        let formatted = Self.edited(request).formatted()
        XCTAssertEqual(m.string, "Intro.\n\n" + formatted + "\n\nAfter.")
        XCTAssertTrue(formatted.contains("| Kiwi  | 12  |"), formatted)
        XCTAssertEqual(m.textView.selectedRange(),
                       NSRange(location: location(of: "Name", in: m), length: 0),
                       "the caret lands in the table's first cell")
        XCTAssertEqual(m.undo.groupingLevel, 0, "the save's group is closed, not left open")
        XCTAssertEqual(m.undo.undoActionName, "Edit Table")

        m.undo.undo()
        XCTAssertEqual(m.string, Self.document, "one ⌘Z takes the whole save back")
        XCTAssertFalse(m.undo.canUndo, "and it was one step")
        XCTAssertEqual(m.box.reported, [])
    }

    /// Whole-branch review M4: a Save that hands back the table unchanged,
    /// over a table already in its tidy form, writes nothing and leaves no
    /// "Edit Table" step for ⌘Z to undo invisibly. The caret still lands.
    func test_saveOfAnUnchangedTidyTableWritesNothingAndLeavesNoUndoStep() async throws {
        let tidy = try XCTUnwrap(TableText(parsing: Self.table)).formatted()
        let document = "Intro.\n\n" + tidy + "\n\nAfter."
        let m = try mount(document)
        m.box.answer = { $0.table }
        m.textView.setSelectedRange(NSRange(location: location(of: "Apple", in: m), length: 0))
        await m.coordinator.editTable()?.value
        XCTAssertEqual(m.box.requests.count, 1)
        XCTAssertEqual(m.string, document)
        XCTAssertFalse(m.undo.canUndo, "no step that undoes nothing")
        XCTAssertEqual(m.textView.selectedRange(),
                       NSRange(location: location(of: "Name", in: m), length: 0))
        XCTAssertEqual(m.box.reported, [])
    }

    func test_cancelWritesNothing() async throws {
        let m = try mount(Self.document)
        m.textView.setSelectedRange(NSRange(location: location(of: "Apple", in: m), length: 0))
        await m.coordinator.editTable()?.value
        XCTAssertEqual(m.box.requests.count, 1)
        XCTAssertEqual(m.string, Self.document)
        XCTAssertFalse(m.undo.canUndo)
    }

    /// Review focus 3: the table changed while the sheet was open (a sync
    /// re-render, a tidy) — the save is refused with the sentence and writes
    /// nothing; the change stays as it was.
    func test_aTableThatChangedWhileTheSheetWasOpenIsRefusedWithASentence() async throws {
        let m = try mount(Self.document)
        m.box.answer = Self.edited
        m.box.whileOpen = { [m] in
            let at = (m.textView.string as NSString).range(of: "Apple").location
            m.textView.insertText("Green ", replacementRange: NSRange(location: at, length: 0))
        }
        let changed = Self.document.replacingOccurrences(of: "Apple", with: "Green Apple")
        m.textView.setSelectedRange(NSRange(location: location(of: "Qty", in: m), length: 0))

        await m.coordinator.editTable()?.value

        XCTAssertEqual(m.string, changed, "nothing of the save was written")
        XCTAssertEqual(m.box.reported, ["The table changed while you were editing it"])
        XCTAssertEqual(EditorCoordinator.tableChangedWhileEditingMessage,
                       "The table changed while you were editing it")
    }

    /// A row typed onto the end of the table while the sheet was open: the
    /// text the sheet opened on is still there, but the table is longer — a
    /// save over the old range would leave the new row dangling. Refused.
    func test_aTableThatGrewWhileTheSheetWasOpenIsRefused() async throws {
        let m = try mount(Self.document)
        m.box.answer = Self.edited
        m.box.whileOpen = { [m] in
            let end = NSMaxRange((m.textView.string as NSString).range(of: "{#tbl:fruit}"))
            m.textView.insertText("\n| Pear | 1 |", replacementRange: NSRange(location: end, length: 0))
        }
        m.textView.setSelectedRange(NSRange(location: location(of: "Apple", in: m), length: 0))
        await m.coordinator.editTable()?.value
        XCTAssertTrue(m.string.contains("| Pear | 1 |"))
        XCTAssertFalse(m.string.contains("Kiwi"), "nothing of the save was written")
        XCTAssertEqual(m.box.reported, [EditorCoordinator.tableChangedWhileEditingMessage])
    }

    /// Typing ABOVE the table while the sheet is open moves it; the anchor
    /// rides the edit and the save lands on the table where it now is.
    func test_textTypedBeforeTheTableWhileTheSheetWasOpenDoesNotStopTheSave() async throws {
        let m = try mount(Self.document)
        m.box.answer = Self.edited
        m.box.whileOpen = { [m] in
            m.textView.insertText("New ", replacementRange: NSRange(location: 0, length: 0))
        }
        m.textView.setSelectedRange(NSRange(location: location(of: "Apple", in: m), length: 0))
        await m.coordinator.editTable()?.value
        let request = try XCTUnwrap(m.box.requests.first)
        XCTAssertEqual(m.string, "New Intro.\n\n" + Self.edited(request).formatted() + "\n\nAfter.")
        XCTAssertEqual(m.box.reported, [])
    }

    /// An edit across the table's start (the blank line above and the table
    /// replaced together, as a paste over both would) forgets the anchor:
    /// refused, even though the same text came back.
    func test_aTableWhoseStartWasReplacedIsRefused() async throws {
        let m = try mount(Self.document)
        m.box.answer = Self.edited
        m.box.whileOpen = { [m] in
            let range = (m.textView.string as NSString).range(of: "\n\n" + Self.table)
            m.textView.insertText("\n\n" + Self.table, replacementRange: range)
        }
        m.textView.setSelectedRange(NSRange(location: location(of: "Apple", in: m), length: 0))
        await m.coordinator.editTable()?.value
        XCTAssertEqual(m.string, Self.document)
        XCTAssertEqual(m.box.reported, [EditorCoordinator.tableChangedWhileEditingMessage])
    }

    // MARK: - Read-only

    /// A read-only posture opens the grid to read (Save disabled there,
    /// `TableGridModelTests`), and the coordinator refuses the write even if
    /// a Save arrived.
    func test_aReadOnlyPostureOpensTheGridToReadAndRefusesTheWrite() async throws {
        let m = try mount(Self.document)
        m.box.answer = Self.edited
        m.coordinator.setLockEditing(true)
        m.textView.setSelectedRange(NSRange(location: location(of: "Apple", in: m), length: 0))

        await m.coordinator.editTable()?.value

        XCTAssertEqual(m.box.requests.map(\.mayWrite), [false], "the grid opens, read-only")
        XCTAssertEqual(m.string, Self.document, "the membrane refused the save")
        XCTAssertFalse(m.undo.canUndo)
        XCTAssertEqual(m.box.reported, ["This document can’t be changed here"],
                       "a refusal by posture says so, and is not a changed table (fix round 1, M1)")
        XCTAssertEqual(EditorCoordinator.tableReadOnlyMessage, "This document can’t be changed here")
    }

    // MARK: - Detach (fix round 1, I1)

    /// A document switch detaches the coordinator while the sheet is up: the
    /// grid task is cancelled, the REAL presenter's sheet comes down as
    /// cancelled, and nothing is written — no Save can land nowhere.
    func test_detachingWhileTheSheetIsUpClosesItAndWritesNothing() async throws {
        let presenter = TableGridPresenter()
        let m = try mount(Self.document, presenter: presenter)
        m.textView.setSelectedRange(NSRange(location: location(of: "Apple", in: m), length: 0))

        let task = try XCTUnwrap(m.coordinator.editTable())
        while presenter.session == nil { await Task.yield() }
        XCTAssertNotNil(presenter.session, "the premise: the sheet is up")

        m.coordinator.detach()
        // The cancellation closes the sheet on a main-actor hop; a bounded
        // number of yields, so a regression fails here instead of hanging.
        for _ in 0..<100 where presenter.session != nil { await Task.yield() }
        XCTAssertNil(presenter.session, "the sheet came down with the editor")
        // A Save arriving anyway (the regression) still writes nothing.
        presenter.finish(TableText(header: ["late"], alignments: [.none], rows: []))
        await task.value
        XCTAssertEqual(m.string, Self.document, "nothing was written")
        XCTAssertEqual(m.box.reported, [])
    }

    // MARK: - Where it opens

    func test_outsideATableEditTableDoesNothing() throws {
        let m = try mount(Self.document)
        m.textView.setSelectedRange(NSRange(location: location(of: "After", in: m), length: 0))
        XCTAssertNil(m.coordinator.editTable())
        m.textView.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertNil(m.coordinator.editTable())
        XCTAssertEqual(m.box.requests.count, 0)
    }

    /// The menu's window command reaches the focused manuscript editor.
    func test_theEditTableCommandOpensTheGridOnTheCaretsTable() async throws {
        let m = try mount(Self.document)
        m.textView.setSelectedRange(NSRange(location: location(of: "Apple", in: m), length: 0))
        MaughamEvent.post(.maughamEditTable, to: .keyWindow)
        await m.coordinator.tableGridTask?.value
        XCTAssertEqual(m.box.requests.map(\.table), [TableText(parsing: Self.table)])
    }

    func test_aSurfaceWithoutAGridIgnoresEditTable() throws {
        let m = try mount(Self.document, grid: false)
        m.textView.setSelectedRange(NSRange(location: location(of: "Apple", in: m), length: 0))
        XCTAssertNil(m.coordinator.editTable())
        XCTAssertFalse(m.coordinator.editTableOnDelimiterRow(
            atCharacterIndex: location(of: "|---|", in: m) + 1))
    }

    // MARK: - The double-click (R-3b-3)

    /// Only the delimiter row (`|---|`) opens the grid on a double-click; in
    /// a cell, the header or the caption the double-click stays AppKit's word
    /// selection (false: `mouseDown` falls through to `super`).
    func test_onlyTheDelimiterRowOpensTheGrid() async throws {
        let m = try mount(Self.document)
        let delimiter = location(of: "|---|---|", in: m)
        let tableRange = (m.string as NSString).range(of: Self.table)
        for index in [delimiter, delimiter + 2, delimiter + 9] {
            XCTAssertEqual(m.coordinator.tableDelimiterRowHit(atCharacterIndex: index), tableRange,
                           "index \(index) is on the delimiter row")
        }
        for needle in ["Name", "Apple", "3 |", "Fruit", "Intro", "After"] {
            XCTAssertNil(m.coordinator.tableDelimiterRowHit(atCharacterIndex: location(of: needle, in: m)),
                         "\(needle) is not the delimiter row")
            XCTAssertFalse(m.coordinator.editTableOnDelimiterRow(atCharacterIndex: location(of: needle, in: m)))
        }
        XCTAssertEqual(m.box.requests.count, 0, "no word double-click opened the grid")

        XCTAssertTrue(m.coordinator.editTableOnDelimiterRow(atCharacterIndex: delimiter + 3))
        await m.coordinator.tableGridTask?.value
        XCTAssertEqual(m.box.requests.map(\.table), [TableText(parsing: Self.table)])
    }

    // MARK: - Labels

    /// The labels the grid's label must not repeat: other chapters', and this
    /// document's own — except this table's, which it may keep.
    func test_theTakenLabelsAreTheProjectsAndThisDocumentsButNotThisTables() async throws {
        let other = "| a |\n|---|\n| 1 |\nTable: Other {#tbl:other}"
        let text = Self.document + "\n\n" + other + "\n\n![Map](m.png){#fig:map}"
        let m = try mount(text, elsewhere: [ManuscriptLabel(reference: "sec:far")!])
        m.textView.setSelectedRange(NSRange(location: location(of: "Apple", in: m), length: 0))
        await m.coordinator.editTable()?.value
        let taken = try XCTUnwrap(m.box.requests.first?.takenLabels)
        XCTAssertEqual(taken, Set(["sec:far", "tbl:other", "fig:map"].compactMap(ManuscriptLabel.init(reference:))))
    }

    /// Opening the grid closes the completion list (its keys would otherwise
    /// arrive with the sheet up).
    func test_openingTheGridClosesTheCompletionList() async throws {
        let m = try mount(Self.document)
        m.textView.setSelectedRange(NSRange(location: location(of: "Intro", in: m) + 5, length: 0))
        for c in ["[", "@"] { m.textView.insertText(c, replacementRange: m.textView.selectedRange()) }
        XCTAssertTrue(m.coordinator.isCompletionOpen, "the premise: typing [@ opened the picker")
        var openWhileTheGridWas: Bool?
        m.box.whileOpen = { [m] in openWhileTheGridWas = m.coordinator.isCompletionOpen }
        await m.coordinator.editTable(at: location(of: "Apple", in: m))?.value
        XCTAssertEqual(openWhileTheGridWas, false)
    }
}
