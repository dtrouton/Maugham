// MaughamTests/Editor/ExistingFigurePickerTests.swift
import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **Insert ▸ Existing Figure…** (report plan 8b Task 3, D8b-1): the picker's
/// rows from the window's listing (unused first, then reading order, parked
/// figures left out), its filter, and the command end to end — posted as
/// `InsertMenuButtons` posts it, answered by a mounted `EditorSurface` whose
/// sheet opens on the window, the chosen line written at the caret through
/// Route A as one ⌘Z step. The choice is made through the open session
/// (`existingFigurePicker.choose`), never by a click (tripwire 33); delivery
/// is synchronous, so each test acts, then asserts.
@MainActor
final class ExistingFigurePickerTests: XCTestCase {
    override class func setUp() { FontWarmup.ensure() }

    // MARK: - Fixture

    private static let chapterOne = "c1", chapterTwo = "c2"
    private static let cash = FigureRecord(id: "fig-0a0a0a0a", name: "cash", kind: .table,
                                           piece: chapterOne, path: "figures/cash.csv")
    private static let q3 = FigureRecord(id: "fig-1b1b1b1b", name: "q3-revenue", kind: .table,
                                         piece: nil, path: "figures/q3-revenue.csv")
    private static let photo = FigureRecord(id: "fig-2c2c2c2c", name: "harbour", kind: .image,
                                            piece: chapterTwo, path: "figures/harbour.png")
    private static let parked = FigureRecord(id: "fig-3d3d3d3d", name: "debt", kind: .table,
                                             piece: nil, path: "figures/debt.csv")
    private static let alien = FigureRecord(id: "fig-4e4e4e4e", name: "future", kind: .unknown("chart"),
                                            piece: nil, path: "figures/future.xyz")

    /// The listing as `FigureListing.build` orders it: used in reading order,
    /// then unused by name.
    private static let listing: [FigureListing.Row] = [
        row(photo, number: "Figure 1", caption: "The harbour", piece: chapterOne),
        row(cash, number: "Table 1", caption: "Cash flows", piece: chapterOne),
        row(parked, number: "—", caption: "", piece: nil),
        row(alien, number: "—", caption: "", piece: nil),
        row(q3, number: "—", caption: "", piece: nil),
    ]

    private static func row(_ record: FigureRecord, number: String, caption: String,
                            piece: String?) -> FigureListing.Row {
        FigureListing.Row(figureId: record.id, kind: record.kind, name: record.name, caption: caption,
                          number: number,
                          usedIn: piece.map { [FigureListing.Use(docId: $0, lineIndex: 2)] } ?? [],
                          referencedFrom: [], pieceOfLine: piece)
    }

    private static func entries(documentPath: String = "manuscript/02.md") -> [ExistingFigurePicker.Entry] {
        ExistingFigurePicker.entries(
            listing: listing, records: [cash, q3, photo, parked, alien],
            isParked: { $0 == parked.id }, documentPath: documentPath,
            pieceTitle: { $0 == chapterOne ? "Chapter 1" : "Chapter 2" })
    }

    final class Box {
        var text: String
        var writes = 0
        var reported: [String] = []
        init(_ text: String) { self.text = text }
    }

    struct Mounted {
        let box: Box
        let window: KeyTestWindow
        let textView: NSTextView
        let coordinator: EditorCoordinator
    }

    /// An `EditorSurface` in a window that reports itself key, configured as
    /// `EditorHost` configures a Markdown manuscript (`answersInsertCommands`,
    /// the `existingFigures` provider); false is a screenplay's or a note's.
    private func mount(_ text: String, answersInsertCommands: Bool = true,
                       mode: any WritingMode = ProseMode(),
                       entries: [ExistingFigurePicker.Entry]? = nil) throws -> Mounted {
        let box = Box(text)
        let binding = Binding(get: { box.text }, set: { box.text = $0; box.writes += 1 })
        var configuration = EditorSurfaceConfiguration(
            presentation: .init(theme: .light, typography: .defaults, mode: mode,
                                typewriterScroll: false, sentenceFocus: false,
                                paragraphFocus: false, showElementGutter: false),
            control: EditorControl())
        configuration.answersInsertCommands = answersInsertCommands
        let offered = entries ?? Self.entries()
        configuration.paragraphProviders.existingFigures = { offered }
        configuration.paragraphProviders.commandFailureReporter = { box.reported.append($0) }
        let window = TestWindow.mount(EditorSurface(text: binding, configuration: configuration),
                                      size: CGSize(width: 700, height: 500),
                                      as: KeyTestWindow.self)
        let textView = try XCTUnwrap(Self.textView(in: window.contentView),
                                     "the mounted surface has no text view")
        let coordinator = try XCTUnwrap(textView.delegate as? EditorCoordinator)
        addTeardownBlock { @MainActor in
            coordinator.existingFigurePicker?.close()
            window.reportsKey = false
            window.close()
        }
        XCTAssertTrue(window.isKeyWindow,
                      "the window must report key, or a .keyWindow post reaches nothing")
        window.makeFirstResponder(textView)
        return Mounted(box: box, window: window, textView: textView, coordinator: coordinator)
    }

    private static func textView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let tv = view as? NSTextView { return tv }
        for sub in view.subviews { if let tv = textView(in: sub) { return tv } }
        return nil
    }

    /// The menu item's post, as `InsertMenuButtons` sends it.
    private func postTheMenuItem() {
        MaughamEvent.post(.maughamInsertExistingFigure, to: .keyWindow)
    }

    // MARK: - The rows

    func test_unusedFiguresComeFirstThenReadingOrder_parkedAndUnknownLeftOut() {
        let entries = Self.entries()
        XCTAssertEqual(entries.map(\.figureId), [Self.q3.id, Self.photo.id, Self.cash.id],
                       "unused first, then the listing's reading order; parked and unknown kinds left out")
        XCTAssertEqual(entries.map(\.title), [
            "— q3-revenue (unused)",
            "Figure 1 · The harbour · Chapter 1",
            "Table 1 · Cash flows · Chapter 1",
        ])
        XCTAssertEqual(entries.map(\.isUnused), [true, false, false])
    }

    func test_eachEntrysLineIsLabelledWithTheRecordNameAndWrittenFromTheDocument() {
        let entries = Self.entries(documentPath: "manuscript/02.md")
        XCTAssertEqual(entries.map(\.line), [
            "![Caption](../figures/q3-revenue.csv){#tbl:q3-revenue}",
            "![The harbour](../figures/harbour.png){#fig:harbour}",
            "![Cash flows](../figures/cash.csv){#tbl:cash}",
        ], "an unused figure takes the placeholder caption; a used one its first line's")
        let root = Self.entries(documentPath: "story.md")
        XCTAssertEqual(root.first?.linePath, "figures/q3-revenue.csv")
        XCTAssertEqual(entries.first.map { ($0.line as NSString).substring(with: $0.captionRange) },
                       "Caption")
    }

    func test_aNameThatCannotBeALabelWritesTheLineWithoutOne() {
        let legacy = FigureRecord(id: "fig-5f5f5f5f", name: "Q3 revenue", kind: .table, piece: nil,
                                  path: "figures/q3.csv")
        let entries = ExistingFigurePicker.entries(
            listing: [Self.row(legacy, number: "—", caption: "", piece: nil)], records: [legacy],
            isParked: { _ in false }, documentPath: "story.md", pieceTitle: { $0 })
        XCTAssertEqual(entries.map(\.line), ["![Caption](figures/q3.csv)"])
    }

    func test_theFilterMatchesEveryWordInTheRowOrTheName() {
        let entries = Self.entries()
        XCTAssertEqual(ExistingFigurePicker.filter(entries, query: "").count, 3)
        XCTAssertEqual(ExistingFigurePicker.filter(entries, query: "  ").count, 3)
        XCTAssertEqual(ExistingFigurePicker.filter(entries, query: "TABLE").map(\.figureId), [Self.cash.id])
        XCTAssertEqual(ExistingFigurePicker.filter(entries, query: "chapter cash").map(\.figureId),
                       [Self.cash.id])
        XCTAssertEqual(ExistingFigurePicker.filter(entries, query: "unused").map(\.figureId), [Self.q3.id])
        XCTAssertEqual(ExistingFigurePicker.filter(entries, query: "harbour 2").map(\.figureId), [])
    }

    // MARK: - The command, end to end

    func test_theMenuItemOpensThePickerAndTheChoiceLandsAtTheCaretAsOneUndoStep() throws {
        let text = "First paragraph.\n\nSecond paragraph."
        let m = try mount(text)
        let caret = ("First paragraph." as NSString).length
        m.textView.setSelectedRange(NSRange(location: caret, length: 0))
        let undo = try XCTUnwrap(m.textView.undoManager)
        undo.removeAllActions()

        postTheMenuItem()

        let session = try XCTUnwrap(m.coordinator.existingFigurePicker, "the menu item opened no picker")
        XCTAssertTrue(session.isOpen)
        XCTAssertNotNil(m.window.attachedSheet, "the picker is a sheet on the editor's window")
        XCTAssertEqual(session.entries.map(\.figureId), Self.entries().map(\.figureId))
        XCTAssertEqual(m.textView.string, text, "opening the picker writes nothing")

        let q3 = try XCTUnwrap(session.entries.first)
        session.choose(q3)

        XCTAssertNil(m.coordinator.existingFigurePicker, "the session ends with the choice")
        XCTAssertFalse(session.isOpen)
        let expected = "First paragraph.\n\n![Caption](../figures/q3-revenue.csv){#tbl:q3-revenue}\n\nSecond paragraph."
        XCTAssertEqual(m.textView.string, expected, "the line on a paragraph of its own after the caret's")
        XCTAssertEqual(m.box.text, expected, "the line reached the binding (the ordinary typing path)")
        let selected = (m.textView.string as NSString).substring(with: m.textView.selectedRange())
        XCTAssertEqual(selected, "Caption", "the caption waits, selected")
        XCTAssertEqual(undo.undoActionName, ExistingFigurePicker.actionName)

        undo.undo()
        XCTAssertEqual(m.textView.string, text, "one ⌘Z removes the line")
        XCTAssertFalse(undo.canUndo, "and it was one step")
    }

    /// A figure used elsewhere is placed again (one figure, two uses): a
    /// second line with the same label and path.
    func test_aFigureAlreadyUsedElsewhereGetsASecondLine() throws {
        let m = try mount("Prose.")
        m.textView.setSelectedRange(NSRange(location: 6, length: 0))
        postTheMenuItem()
        let session = try XCTUnwrap(m.coordinator.existingFigurePicker)
        let cash = try XCTUnwrap(session.entries.first { $0.figureId == Self.cash.id })
        XCTAssertFalse(cash.isUnused, "precondition: the picker marks it used")
        session.choose(cash)
        XCTAssertEqual(m.textView.string, "Prose.\n\n![Cash flows](../figures/cash.csv){#tbl:cash}")
    }

    func test_cancelWritesNothing() throws {
        let m = try mount("Prose.")
        postTheMenuItem()
        let session = try XCTUnwrap(m.coordinator.existingFigurePicker)
        session.cancel()
        XCTAssertNil(m.coordinator.existingFigurePicker)
        XCTAssertNil(m.window.attachedSheet, "the sheet ended")
        XCTAssertEqual(m.textView.string, "Prose.")
        XCTAssertEqual(m.box.writes, 0)
    }

    func test_noFiguresSaysSoAndOpensNothing() throws {
        let m = try mount("Prose.", entries: [])
        postTheMenuItem()
        XCTAssertNil(m.coordinator.existingFigurePicker)
        XCTAssertNil(m.window.attachedSheet)
        XCTAssertEqual(m.box.reported, [ExistingFigurePicker.noFiguresMessage])
    }

    // MARK: - Where it is absent

    func test_aReadOnlyPostureReviewAndTranslationReviewOpenNoPicker() throws {
        let postures: [(String, (EditorCoordinator) -> Void)] = [
            ("read-only", { $0.setLockEditing(true) }),
            ("review", { $0.setReviewMode(true) }),
            ("translation review", { $0.setTranslationReview(true) }),
        ]
        for (name, posture) in postures {
            let m = try mount("Prose.")
            posture(m.coordinator)
            postTheMenuItem()
            XCTAssertNil(m.coordinator.existingFigurePicker, "\(name): the picker opened")
            XCTAssertNil(m.window.attachedSheet, "\(name): a sheet opened")
            XCTAssertEqual(m.textView.string, "Prose.")
            m.window.reportsKey = false
        }
        // Control: the same mount with no posture answers the same post, so
        // the refusals above are the membrane's and not a post that reached nobody.
        let control = try mount("Prose.")
        postTheMenuItem()
        XCTAssertNotNil(control.coordinator.existingFigurePicker, "control: a writable manuscript answers")
    }

    /// A picker already open keeps the post from opening a second.
    func test_aSecondPostWhileThePickerIsOpenOpensNoOther() throws {
        let m = try mount("Prose.")
        postTheMenuItem()
        let first = try XCTUnwrap(m.coordinator.existingFigurePicker)
        postTheMenuItem()
        XCTAssertTrue(m.coordinator.existingFigurePicker === first)
    }

    /// A screenplay (and a research note) is built with
    /// `answersInsertCommands` false (`EditorHost`, pinned by
    /// `InsertCommandTests.test_onlyEditorHostSaysASurfaceAnswersInsert`):
    /// the post reaches it and it does not answer. The control is a prose
    /// manuscript answering the same post.
    func test_aScreenplayDoesNotAnswer() throws {
        let script = try mount("INT. HOUSE - DAY", answersInsertCommands: false, mode: ScreenplayMode())
        postTheMenuItem()
        XCTAssertNil(script.coordinator.existingFigurePicker, "a screenplay opened the picker")
        XCTAssertNil(script.window.attachedSheet)
        script.window.reportsKey = false

        let prose = try mount("Prose.")
        postTheMenuItem()
        XCTAssertNotNil(prose.coordinator.existingFigurePicker,
                        "control: a prose manuscript answers — the refusal above is about the flag")
    }

    /// The menu item posts the command the coordinator observes, gated as
    /// the other Insert items are, with no shortcut of its own.
    func test_theMenuItemPostsTheCommandBehindTheInsertGate() throws {
        let app = try SourceTree.read("Maugham/MaughamApp.swift")
        let item = try XCTUnwrap(app.range(of: "Button(\"Existing Figure\\u{2026}\")"),
                                 "Insert ▸ Existing Figure… is not in the menu")
        let menu = try XCTUnwrap(app.range(of: "private struct InsertMenuButtons: View {"))
        XCTAssertGreaterThan(item.lowerBound, menu.lowerBound, "the item is in InsertMenuButtons")
        let rest = app[item.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "Divider()"), "the item is followed by the menu's divider")
        let declaration = rest[..<end.lowerBound]
        XCTAssertTrue(declaration.contains("MaughamEvent.post(.maughamInsertExistingFigure, to: .keyWindow)"))
        XCTAssertTrue(declaration.contains(".disabled(!enabled)"))
        XCTAssertFalse(declaration.contains("keyboardShortcut"), "no shortcut (none required)")
    }
}
