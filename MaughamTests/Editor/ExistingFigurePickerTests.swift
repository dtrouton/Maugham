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
    private static let documentPath = "manuscript/02.md"
    private static let cash = FigureRecord(id: "fig-0a0a0a0a", name: "cash", kind: .table,
                                           piece: chapterOne, path: "figures/cash.csv")
    private static let q3 = FigureRecord(id: "fig-1b1b1b1b", name: "q3-revenue", kind: .table,
                                         piece: nil, path: "figures/q3-revenue.csv")
    private static let photo = FigureRecord(id: "fig-2c2c2c2c", name: "harbour", kind: .image,
                                            piece: chapterTwo, path: "figures/harbour.png")
    private static let ledger = FigureRecord(id: "fig-6a6a6a6a", name: "ledger", kind: .table,
                                             piece: chapterOne, path: "figures/ledger.csv")
    private static let parked = FigureRecord(id: "fig-3d3d3d3d", name: "debt", kind: .table,
                                             piece: nil, path: "figures/debt.csv")
    private static let alien = FigureRecord(id: "fig-4e4e4e4e", name: "future", kind: .unknown("chart"),
                                            piece: nil, path: "figures/future.xyz")
    private static let records = [cash, q3, photo, ledger, parked, alien]

    /// The listing as `FigureListing.build` orders it: used in reading order,
    /// then unused by name. The ledger's line has no label.
    private static let listing: [FigureListing.Row] = [
        row(photo, number: "Figure 1", caption: "The harbour", piece: chapterOne),
        row(cash, number: "Table 1", caption: "Cash flows", piece: chapterOne),
        row(ledger, number: "Table 2", caption: "Ledger", piece: chapterOne),
        row(parked, number: "—", caption: "", piece: nil),
        row(alien, number: "—", caption: "", piece: nil),
        row(q3, number: "—", caption: "", piece: nil),
    ]

    /// The labels the index registered for each used figure's first line.
    private static let firstLineLabels: [String: ManuscriptLabel] = [
        photo.id: ManuscriptLabel(reference: "fig:harbour")!,
        cash.id: ManuscriptLabel(reference: "tbl:cash")!,
    ]

    private static func row(_ record: FigureRecord, number: String, caption: String,
                            piece: String?) -> FigureListing.Row {
        FigureListing.Row(figureId: record.id, kind: record.kind, name: record.name, caption: caption,
                          number: number,
                          usedIn: piece.map { [FigureListing.Use(docId: $0, lineIndex: 2)] } ?? [],
                          referencedFrom: [], pieceOfLine: piece)
    }

    private static func entries(documentPath: String = documentPath, docId: String = chapterTwo,
                                live: [String: ExistingFigurePicker.LiveUse] = [:])
        -> [ExistingFigurePicker.Entry]
    {
        ExistingFigurePicker.entries(
            listing: listing, records: records,
            isParked: { $0 == parked.id }, documentPath: documentPath, docId: docId, live: live,
            lineLabel: { row, _ in firstLineLabels[row.figureId] },
            pieceTitle: { $0 == chapterOne ? "Chapter 1" : "Chapter 2" })
    }

    private static func label(_ reference: String) -> ManuscriptLabel { ManuscriptLabel(reference: reference)! }

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
    /// the `existingFigures` provider over the fixture's listing and the live
    /// text); false is a screenplay's or a note's. The document is Chapter 2
    /// at `manuscript/02.md`.
    private func mount(_ text: String, answersInsertCommands: Bool = true,
                       mode: any WritingMode = ProseMode(),
                       entries: [ExistingFigurePicker.Entry]? = nil,
                       docId: String = ExistingFigurePickerTests.chapterTwo,
                       isParked: ((String) async -> Bool)? = nil) throws -> Mounted {
        let box = Box(text)
        let binding = Binding(get: { box.text }, set: { box.text = $0; box.writes += 1 })
        var configuration = EditorSurfaceConfiguration(
            presentation: .init(theme: .light, typography: .defaults, mode: mode,
                                typewriterScroll: false, sentenceFocus: false,
                                paragraphFocus: false, showElementGutter: false),
            control: EditorControl())
        configuration.answersInsertCommands = answersInsertCommands
        // As `EditorHost` builds it: the live text read at the command.
        configuration.paragraphProviders.existingFigures = { liveText in
            entries ?? Self.entries(docId: docId, live: ExistingFigurePicker.liveUses(
                in: liveText, records: Self.records, documentPath: Self.documentPath))
        }
        configuration.paragraphProviders.existingFigureIsParked = isParked
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

    func test_unusedFiguresComeFirstThenReadingOrder_usedOnesAreReferences() {
        let entries = Self.entries()
        XCTAssertEqual(entries.map(\.figureId), [Self.q3.id, Self.photo.id, Self.cash.id, Self.ledger.id],
                       "unused first, then the listing's reading order; parked and unknown kinds left out")
        XCTAssertEqual(entries.map(\.title), [
            "— q3-revenue (unused)",
            "Refer to Figure 1 · The harbour · Chapter 1",
            "Refer to Table 1 · Cash flows · Chapter 1",
            "Table 2 · Ledger · Chapter 1",
        ])
        XCTAssertEqual(entries.map(\.action), [
            .place, .refer(Self.label("fig:harbour")), .refer(Self.label("tbl:cash")),
            .unavailable("Give Table 2 a label to refer to it"),
        ], "a placed figure is referred to by its first line's label; no label, no reference")
        XCTAssertEqual(entries.map(\.isEnabled), [true, true, true, false])
        XCTAssertEqual(entries.last?.note, "Give Table 2 a label to refer to it")
    }

    func test_anUnusedEntrysLineIsLabelledWithTheRecordNameAndWrittenFromTheDocument() {
        let entries = Self.entries(documentPath: "manuscript/02.md")
        XCTAssertEqual(entries.first?.line, "![Caption](../figures/q3-revenue.csv){#tbl:q3-revenue}")
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
            isParked: { _ in false }, documentPath: "story.md", docId: "s", live: [:],
            lineLabel: { _, _ in nil }, pieceTitle: { $0 })
        XCTAssertEqual(entries.map(\.line), ["![Caption](figures/q3.csv)"])
    }

    /// Review I1: the listing lags the settle, so the live text's lines say
    /// "used" too — a figure placed a moment ago is offered as a reference.
    func test_liveUsesReadThisDocumentsFigureLines() {
        let text = """
            Prose.

            ![Revenue](../figures/q3-revenue.csv){#tbl:q3-revenue}

            ![Again](../figures/q3-revenue.csv)

            ![Lost](../figures/nothing.csv){#tbl:nothing}
            """
        let live = ExistingFigurePicker.liveUses(in: text, records: Self.records,
                                                 documentPath: Self.documentPath)
        XCTAssertEqual(live, [Self.q3.id: .init(label: Self.label("tbl:q3-revenue"), caption: "Revenue")],
                       "each figure's first live line; a path naming no figure is not a use")
    }

    func test_aFigureOnlyTheLiveTextUsesIsAReference() throws {
        let labelled = Self.entries(live: [Self.q3.id: .init(label: Self.label("tbl:q3-revenue"),
                                                             caption: "Revenue")])
        let q3 = try XCTUnwrap(labelled.first { $0.figureId == Self.q3.id })
        XCTAssertEqual(q3.action, .refer(Self.label("tbl:q3-revenue")))
        XCTAssertEqual(q3.title, "Refer to Revenue · Chapter 2")
        XCTAssertEqual(labelled.last?.figureId, Self.q3.id, "after the listing's used ones")
        XCTAssertFalse(labelled.contains { $0.isUnused }, "nothing left to place")

        let bare = Self.entries(live: [Self.q3.id: .init(label: nil, caption: "Revenue")])
        XCTAssertEqual(bare.first { $0.figureId == Self.q3.id }?.action,
                       .unavailable("Give this figure a label to refer to it"))
    }

    /// **Final review M3 — a figure placed in ANOTHER open piece since the
    /// settle is not offered to place again**: that piece's live text holds its
    /// line, so the picker refers to it there. Control: with no other open
    /// piece holding it, it is to place.
    func test_aFigurePlacedInAnotherOpenPieceSinceTheSettleIsReferredTo() throws {
        let elsewhere = ExistingFigurePicker.liveUsesElsewhere(
            in: [(docId: Self.chapterOne, path: "manuscript/01.md",
                  text: "Prose.\n\n![Revenue](../figures/q3-revenue.csv){#tbl:q3-revenue}\n")],
            records: Self.records)
        XCTAssertEqual(elsewhere, [Self.q3.id: .init(
            docId: Self.chapterOne, use: .init(label: Self.label("tbl:q3-revenue"), caption: "Revenue"))])
        let entries = ExistingFigurePicker.entries(
            listing: Self.listing, records: Self.records, isParked: { $0 == Self.parked.id },
            documentPath: Self.documentPath, docId: Self.chapterTwo, live: [:], elsewhere: elsewhere,
            lineLabel: { row, _ in Self.firstLineLabels[row.figureId] },
            pieceTitle: { $0 == Self.chapterOne ? "Chapter 1" : "Chapter 2" })

        let q3 = try XCTUnwrap(entries.first { $0.figureId == Self.q3.id })
        XCTAssertEqual(q3.action, .refer(Self.label("tbl:q3-revenue")))
        XCTAssertEqual(q3.title, "Refer to Revenue · Chapter 1")
        XCTAssertEqual(Self.entries().first { $0.figureId == Self.q3.id }?.action, .place,
                       "control: no open piece holds it")
    }

    /// When the first line is this document's, the live line's label wins
    /// over the index's (it may have changed since the settle).
    func test_theLiveLabelWinsWhenTheFirstLineIsThisDocuments() {
        let entries = Self.entries(docId: Self.chapterOne,
                                   live: [Self.cash.id: .init(label: Self.label("tbl:cash-flows"),
                                                              caption: "Cash flows")])
        XCTAssertEqual(entries.first { $0.figureId == Self.cash.id }?.action,
                       .refer(Self.label("tbl:cash-flows")))
        XCTAssertEqual(Self.entries(docId: Self.chapterTwo).first { $0.figureId == Self.cash.id }?.action,
                       .refer(Self.label("tbl:cash")), "control: its line is another piece's, the index's label")
    }

    /// Re-review I1: every use the listing knows is this document's and the
    /// live text holds none — its line was cut since the settle — so the
    /// figure is to place again, never a reference to a label that is gone.
    /// A figure also used in another piece stays a reference (its label is there).
    func test_aFigureWhoseOnlyLineWasCutHereIsToPlace() {
        let here = Self.entries(docId: Self.chapterOne)
        XCTAssertEqual(here.first { $0.figureId == Self.cash.id }?.action, .place)
        XCTAssertEqual(here.first { $0.figureId == Self.cash.id }?.title, "— cash (unused)")

        let both = FigureListing.Row(
            figureId: Self.cash.id, kind: .table, name: "cash", caption: "Cash flows", number: "Table 1",
            usedIn: [.init(docId: Self.chapterOne, lineIndex: 2), .init(docId: Self.chapterTwo, lineIndex: 4)],
            referencedFrom: [], pieceOfLine: Self.chapterOne)
        let entries = ExistingFigurePicker.entries(
            listing: [both], records: Self.records, isParked: { _ in false },
            documentPath: Self.documentPath, docId: Self.chapterOne, live: [:],
            lineLabel: { _, _ in Self.label("tbl:cash") }, pieceTitle: { $0 })
        XCTAssertEqual(entries.first?.action, .refer(Self.label("tbl:cash")),
                       "control: a use in another piece keeps it a reference")
    }

    /// Task 3 carried minor: this document's line was cut, but another piece
    /// still has one under a different label — the reference takes the label
    /// of the first use OUTSIDE this document, never the cut line's stale one.
    /// Control: with the line live here, the live label wins.
    func test_aCutLineHereReferencesTheLabelOfTheFirstUseElsewhere() {
        let both = FigureListing.Row(
            figureId: Self.cash.id, kind: .table, name: "cash", caption: "Cash flows", number: "Table 1",
            usedIn: [.init(docId: Self.chapterOne, lineIndex: 2), .init(docId: Self.chapterTwo, lineIndex: 4)],
            referencedFrom: [], pieceOfLine: Self.chapterOne)
        func entries(live: [String: ExistingFigurePicker.LiveUse]) -> [ExistingFigurePicker.Entry] {
            ExistingFigurePicker.entries(
                listing: [both], records: Self.records, isParked: { _ in false },
                documentPath: Self.documentPath, docId: Self.chapterOne, live: live,
                lineLabel: { _, use in
                    use.docId == Self.chapterOne ? Self.label("tbl:old-cash") : Self.label("tbl:cash")
                },
                pieceTitle: { $0 })
        }
        XCTAssertEqual(entries(live: [:]).first?.action, .refer(Self.label("tbl:cash")),
                       "the cut line's stale label is not referred to")
        XCTAssertEqual(entries(live: [Self.cash.id: .init(label: Self.label("tbl:cash-here"), caption: "Cash")])
                        .first?.action, .refer(Self.label("tbl:cash-here")),
                       "control: a live line here gives its own label")
    }

    func test_theFilterMatchesEveryWordInTheRowOrTheName() {
        let entries = Self.entries()
        XCTAssertEqual(ExistingFigurePicker.filter(entries, query: "").count, 4)
        XCTAssertEqual(ExistingFigurePicker.filter(entries, query: "  ").count, 4)
        XCTAssertEqual(ExistingFigurePicker.filter(entries, query: "TABLE 1").map(\.figureId),
                       [Self.cash.id, Self.ledger.id], "every word, anywhere in the row")
        XCTAssertEqual(ExistingFigurePicker.filter(entries, query: "TABLE 2").map(\.figureId), [Self.ledger.id])
        XCTAssertEqual(ExistingFigurePicker.filter(entries, query: "chapter cash").map(\.figureId),
                       [Self.cash.id])
        XCTAssertEqual(ExistingFigurePicker.filter(entries, query: "unused").map(\.figureId), [Self.q3.id])
        XCTAssertEqual(ExistingFigurePicker.filter(entries, query: "harbour 2").map(\.figureId), [])
    }

    // MARK: - The keyboard rules

    func test_theSelectionFollowsTheFilterOverEnabledRows() {
        let all = Self.entries()
        XCTAssertEqual(ExistingFigurePicker.selection(keeping: nil, in: all), Self.q3.id)
        XCTAssertEqual(ExistingFigurePicker.selection(keeping: Self.cash.id, in: all), Self.cash.id,
                       "kept while shown")
        let tables = ExistingFigurePicker.filter(all, query: "table")
        XCTAssertEqual(ExistingFigurePicker.selection(keeping: Self.photo.id, in: tables), Self.cash.id,
                       "filtered away: the first shown")
        let ledger = ExistingFigurePicker.filter(all, query: "ledger")
        XCTAssertNil(ExistingFigurePicker.selection(keeping: nil, in: ledger), "a disabled row is never selected")
        XCTAssertNil(ExistingFigurePicker.selection(keeping: Self.ledger.id, in: ledger))
    }

    func test_arrowsMoveOverEnabledRowsAndStopAtTheEnds() {
        let all = Self.entries()
        XCTAssertEqual(ExistingFigurePicker.selection(moving: Self.q3.id, by: 1, in: all), Self.photo.id)
        XCTAssertEqual(ExistingFigurePicker.selection(moving: Self.cash.id, by: 1, in: all), Self.cash.id,
                       "the disabled ledger is skipped, and ↓ stops at the last enabled row")
        XCTAssertEqual(ExistingFigurePicker.selection(moving: Self.q3.id, by: -1, in: all), Self.q3.id)
        XCTAssertEqual(ExistingFigurePicker.selection(moving: nil, by: 1, in: all), Self.q3.id)
        XCTAssertEqual(ExistingFigurePicker.selection(moving: nil, by: -1, in: all), Self.cash.id)
        XCTAssertNil(ExistingFigurePicker.selection(moving: nil, by: 1, in: []))
    }

    func test_returnChoosesTheSelectedEnabledRowOnly() {
        let all = Self.entries()
        XCTAssertEqual(ExistingFigurePicker.chosen(Self.photo.id, in: all)?.figureId, Self.photo.id)
        XCTAssertNil(ExistingFigurePicker.chosen(Self.ledger.id, in: all), "a disabled row inserts nothing")
        XCTAssertNil(ExistingFigurePicker.chosen(Self.photo.id, in: ExistingFigurePicker.filter(all, query: "cash")),
                     "a row the filter hides is not chosen")
        XCTAssertNil(ExistingFigurePicker.chosen(nil, in: all))
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
        XCTAssertEqual(m.box.reported, [])

        undo.undo()
        XCTAssertEqual(m.textView.string, text, "one ⌘Z removes the line")
        XCTAssertFalse(undo.canUndo, "and it was one step")
    }

    /// The ruling: a figure already placed is not placed twice — choosing it
    /// writes a cross-reference to its line's label, inline at the caret, a
    /// space before it after a word; one ⌘Z.
    func test_aFigureAlreadyPlacedIsReferredToNotPlacedAgain() throws {
        let m = try mount("See")
        m.textView.setSelectedRange(NSRange(location: 3, length: 0))
        let undo = try XCTUnwrap(m.textView.undoManager)
        undo.removeAllActions()
        postTheMenuItem()
        let session = try XCTUnwrap(m.coordinator.existingFigurePicker)
        let cash = try XCTUnwrap(session.entries.first { $0.figureId == Self.cash.id })
        XCTAssertEqual(cash.action, .refer(Self.label("tbl:cash")), "precondition: the picker marks it placed")
        session.choose(cash)

        XCTAssertEqual(m.textView.string, "See @tbl:cash", "a reference, not a second figure line")
        XCTAssertEqual(m.textView.selectedRange(), NSRange(location: 13, length: 0), "the caret after it")
        XCTAssertEqual(undo.undoActionName, ExistingFigurePicker.referenceActionName)
        XCTAssertEqual(m.box.reported, [])
        undo.undo()
        XCTAssertEqual(m.textView.string, "See", "one ⌘Z removes it")
        XCTAssertFalse(undo.canUndo)
    }

    /// After a space no second space is written; inside code nothing is, and
    /// the writer is told.
    func test_aReferenceAfterASpaceAddsNoneAndInsideCodeIsRefused() throws {
        let m = try mount("See ")
        m.textView.setSelectedRange(NSRange(location: 4, length: 0))
        postTheMenuItem()
        let session = try XCTUnwrap(m.coordinator.existingFigurePicker)
        session.choose(try XCTUnwrap(session.entries.first { $0.figureId == Self.photo.id }))
        XCTAssertEqual(m.textView.string, "See @fig:harbour")
        m.window.reportsKey = false

        let code = try mount("Run `code here` now.")
        code.textView.setSelectedRange(NSRange(location: 9, length: 0))
        postTheMenuItem()
        let inCode = try XCTUnwrap(code.coordinator.existingFigurePicker)
        inCode.choose(try XCTUnwrap(inCode.entries.first { $0.figureId == Self.cash.id }))
        XCTAssertEqual(code.textView.string, "Run `code here` now.")
        XCTAssertEqual(code.box.reported, [ExistingFigurePicker.insideCodeMessage])
    }

    /// Review I1: place, then pick the same figure again before any settle —
    /// the live text already holds its line, so it is a reference.
    func test_placeThenPickAgainBeforeTheSettleRefersToIt() throws {
        let m = try mount("Prose.")
        m.textView.setSelectedRange(NSRange(location: 6, length: 0))
        postTheMenuItem()
        let first = try XCTUnwrap(m.coordinator.existingFigurePicker)
        first.choose(try XCTUnwrap(first.entries.first { $0.figureId == Self.q3.id }))
        XCTAssertTrue(m.textView.string.contains("{#tbl:q3-revenue}"), "precondition: placed")

        let end = (m.textView.string as NSString).length
        m.textView.setSelectedRange(NSRange(location: end, length: 0))
        postTheMenuItem()
        let again = try XCTUnwrap(m.coordinator.existingFigurePicker)
        let q3 = try XCTUnwrap(again.entries.first { $0.figureId == Self.q3.id })
        XCTAssertEqual(q3.action, .refer(Self.label("tbl:q3-revenue")))
        again.choose(q3)
        XCTAssertTrue(m.textView.string.hasSuffix(" @tbl:q3-revenue"), m.textView.string)
        XCTAssertEqual(m.textView.string.components(separatedBy: "](../figures/q3-revenue.csv)").count, 2,
                       "one figure line, never two")
    }

    /// Re-review I1, end to end: the writer cuts the figure's only line
    /// from this piece and reopens the picker before any settle — the
    /// figure is placed again, and no `@tbl:cash` points at nothing.
    func test_cuttingTheOnlyLineThenPickingAgainPlacesIt() throws {
        let line = "![Cash flows](../figures/cash.csv){#tbl:cash}"
        let m = try mount("Intro.\n\n" + line + "\n\nAfter.", docId: Self.chapterOne)
        postTheMenuItem()
        let before = try XCTUnwrap(m.coordinator.existingFigurePicker)
        XCTAssertEqual(before.entries.first { $0.figureId == Self.cash.id }?.action,
                       .refer(Self.label("tbl:cash")), "precondition: its live line makes it a reference")
        before.cancel()

        // The writer cuts the line (typing-path delete, no settle).
        let range = (m.textView.string as NSString).range(of: line + "\n\n")
        m.textView.setSelectedRange(range)
        m.textView.insertText("", replacementRange: range)
        XCTAssertFalse(m.textView.string.contains("cash.csv"), "precondition: cut")

        postTheMenuItem()
        let again = try XCTUnwrap(m.coordinator.existingFigurePicker)
        let cash = try XCTUnwrap(again.entries.first { $0.figureId == Self.cash.id })
        XCTAssertEqual(cash.action, .place)
        again.choose(cash)
        XCTAssertTrue(m.textView.string.contains("](../figures/cash.csv){#tbl:cash}"), m.textView.string)
        XCTAssertFalse(m.textView.string.contains("@tbl:cash"), "no reference to a line that was gone")
    }

    /// Re-review M1: before a label character the reference takes a space
    /// after it, so it never joins the next word.
    func test_aReferenceBeforeAWordTakesASpaceAfterIt() throws {
        let m = try mount("SeeTable")
        m.textView.setSelectedRange(NSRange(location: 3, length: 0))
        postTheMenuItem()
        let session = try XCTUnwrap(m.coordinator.existingFigurePicker)
        session.choose(try XCTUnwrap(session.entries.first { $0.figureId == Self.photo.id }))
        XCTAssertEqual(m.textView.string, "See @fig:harbour Table")
        XCTAssertEqual(m.textView.selectedRange(), NSRange(location: 16, length: 0), "the caret right after the label")
        m.window.reportsKey = false

        let control = try mount("See. Then")
        control.textView.setSelectedRange(NSRange(location: 4, length: 0))
        postTheMenuItem()
        let open = try XCTUnwrap(control.coordinator.existingFigurePicker)
        open.choose(try XCTUnwrap(open.entries.first { $0.figureId == Self.photo.id }))
        XCTAssertEqual(control.textView.string, "See. @fig:harbour Then",
                       "control: before a space nothing is added")
    }

    /// Review I2: a placement Route A refuses (the posture turned read-only
    /// while the sheet was up) is told, not silent.
    func test_aRefusedWriteIsTold() throws {
        let m = try mount("Prose.")
        postTheMenuItem()
        let session = try XCTUnwrap(m.coordinator.existingFigurePicker)
        m.coordinator.setLockEditing(true)
        session.choose(try XCTUnwrap(session.entries.first))
        XCTAssertEqual(m.textView.string, "Prose.")
        XCTAssertEqual(m.box.reported, [ExistingFigurePicker.refusedMessage])
    }

    /// A disabled row reaching the coordinator writes nothing and says why.
    func test_anUnavailableRowWritesNothingAndSaysWhy() throws {
        let m = try mount("Prose.")
        postTheMenuItem()
        let session = try XCTUnwrap(m.coordinator.existingFigurePicker)
        session.choose(try XCTUnwrap(session.entries.first { $0.figureId == Self.ledger.id }))
        XCTAssertEqual(m.textView.string, "Prose.")
        XCTAssertEqual(m.box.reported, ["Give Table 2 a label to refer to it"])
    }

    /// Minor 1: the store is asked at the choice; a figure parked meanwhile
    /// is refused and told. The control: not parked, the line lands.
    func test_aFigureParkedMeanwhileIsRefusedAtTheChoice() async throws {
        let m = try mount("Prose.", isParked: { _ in true })
        postTheMenuItem()
        let session = try XCTUnwrap(m.coordinator.existingFigurePicker)
        m.coordinator.existingFigureTask = nil
        session.choose(try XCTUnwrap(session.entries.first))
        await m.coordinator.existingFigureTask?.value
        XCTAssertEqual(m.textView.string, "Prose.")
        XCTAssertEqual(m.box.reported, [ExistingFigurePicker.parkedMessage])
        m.window.reportsKey = false

        let control = try mount("Prose.", isParked: { _ in false })
        control.textView.setSelectedRange(NSRange(location: 6, length: 0))
        postTheMenuItem()
        let open = try XCTUnwrap(control.coordinator.existingFigurePicker)
        control.coordinator.existingFigureTask = nil
        open.choose(try XCTUnwrap(open.entries.first))
        await control.coordinator.existingFigureTask?.value
        XCTAssertTrue(control.textView.string.contains("{#tbl:q3-revenue}"), control.textView.string)
        XCTAssertEqual(control.box.reported, [])
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
