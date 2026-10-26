// MaughamTests/Editor/ConvertTableCommandTests.swift
import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **Convert to Table Figure** (report plan 7b Task 5): a pipe table becomes
/// a table figure through the coordinator's verb, the ⌘⌥⇧T window command,
/// or the right-click menu's item. The right-click itself is never synthesised
/// (tripwire 33): the pure offer and the item builder are asked directly. The
/// figure is made in a task, awaited through `tableFigureTask`, never polled.
@MainActor
final class ConvertTableCommandTests: XCTestCase {
    override class func setUp() { FontWarmup.ensure() }

    // MARK: - Fixture

    final class Box {
        var text: String
        var reported: [String] = []
        init(_ text: String) { self.text = text }
    }

    struct Mounted {
        let box: Box
        let window: KeyTestWindow
        let textView: NSTextView
        let coordinator: EditorCoordinator
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

    /// An `EditorSurface` as `EditorHost` builds it for a Markdown manuscript,
    /// in a window that reports itself key.
    private func mount(_ text: String,
                       labelsElsewhere: (() -> Set<ManuscriptLabel>)? = nil,
                       tableFigureMaker: FigureIngest.TableFigureMaker? = nil) throws -> Mounted {
        let box = Box(text)
        let binding = Binding(get: { box.text }, set: { box.text = $0 })
        var configuration = EditorSurfaceConfiguration(
            presentation: .init(theme: .light, typography: .defaults, mode: ProseMode(),
                                typewriterScroll: false, sentenceFocus: false,
                                paragraphFocus: false, showElementGutter: false),
            control: EditorControl())
        configuration.answersInsertCommands = true
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
        let textView = try XCTUnwrap(Self.textView(in: window.contentView))
        let coordinator = try XCTUnwrap(textView.delegate as? EditorCoordinator)
        XCTAssertTrue(window.isKeyWindow, "a .keyWindow post would reach nothing")
        window.makeFirstResponder(textView)
        return Mounted(box: box, window: window, textView: textView, coordinator: coordinator)
    }

    private static func textView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let tv = view as? NSTextView { return tv }
        for sub in view.subviews { if let tv = textView(in: sub) { return tv } }
        return nil
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
        return { request in
            try await FigureIngest.makeTableFigure(documentId: chapter.id, documentPath: path,
                                                   request: request, store: store)
        }
    }

    private func convert(_ m: Mounted, at location: Int) async {
        m.coordinator.tableFigureTask = nil
        m.coordinator.convertTableToFigure(at: location)
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

    private func location(of needle: String, in m: Mounted) -> Int {
        (m.textView.string as NSString).range(of: needle).location
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

    /// The number the editor's index gives `label`, over one piece's text.
    private func number(of label: String, in text: String) -> String? {
        let index = ReferenceIndex.build(
            pieces: [(docId: "doc-a", summary: ReferenceIndex.PieceSummary(text: text))], research: [], words: .english)
        return index.target(for: ManuscriptLabel(reference: label)!)?.text
    }

    /// A table before the cash table, so the cash table is Table 2, and a
    /// reference to it after.
    static let document = """
        Intro

        | A | B |
        | --- | --- |
        | 1 | 2 |

        | Item | Cost |
        | --- | --- |
        | Tea | 2.5 |
        | Cake | =B3*2 |
        Table: Cash in hand {#tbl:cash}

        See @tbl:cash.
        """

    static let cashTable = """
        | Item | Cost |
        | --- | --- |
        | Tea | 2.5 |
        | Cake | =B3*2 |
        Table: Cash in hand {#tbl:cash}
        """

    // MARK: - Review Focus 2

    /// **Review Focus 2**: the pipe table with `{#tbl:cash}` that
    /// `@tbl:cash` cites becomes one figure line keeping its caption and
    /// label, so the reference resolves to the same number; the figure is
    /// named after the label, its first row a header row and its `=` cell a
    /// formula. One step, named.
    func test_convertKeepsTheCaptionAndLabelSoTheReferenceKeepsItsNumber() async throws {
        let (store, chapter) = try await novel()
        let m = try mount(Self.document, tableFigureMaker: try maker(store, chapter))
        XCTAssertEqual(number(of: "tbl:cash", in: m.textView.string), "Table 2")

        await convert(m, at: location(of: "Cake", in: m))

        let expected = Self.document.replacingOccurrences(
            of: Self.cashTable, with: "![Cash in hand](../figures/cash.csv){#tbl:cash}")
        XCTAssertEqual(m.textView.string, expected)
        XCTAssertEqual(m.box.text, expected, "the line reached the binding — the op log's door")
        XCTAssertEqual(number(of: "tbl:cash", in: m.textView.string), "Table 2",
                       "@tbl:cash resolves to the same number after the conversion")
        XCTAssertEqual(m.box.reported, [])
        let figure = try XCTUnwrap(store.manifest.figures?.first)
        XCTAssertEqual(figure.kind, .table)
        XCTAssertEqual(figure.name, "cash")
        XCTAssertEqual(figure.piece, chapter.id)
        let ds = try XCTUnwrap(store.documentStore)
        let doc = try await ds.openFigure(figureId: figure.id)
        let table = doc.state.table
        XCTAssertEqual(table.headerRows, 1)
        XCTAssertEqual(table.rows.count, 3)
        XCTAssertEqual(table[CellKey(row: table.rows[0], column: table.columns[1])]?.content,
                       .value(.text("Cost")))
        guard case .formula = table[CellKey(row: table.rows[2], column: table.columns[1])]?.content
        else { await ds.closeFigure(figureId: figure.id); return XCTFail("=B3*2 is a formula") }
        await ds.closeFigure(figureId: figure.id)
        XCTAssertEqual(m.textView.undoManager?.undoActionName, "Convert to Table Figure")
    }

    /// **Review Focus 2, the refusal**: the table's text changes while its
    /// figure is being made (another device's edit arriving): nothing is
    /// written over it, the new figure goes to the Trash, and the writer is
    /// told.
    func test_aTableThatChangedWhileItsFigureWasMadeIsLeftAndTheFigureTrashed() async throws {
        let (store, chapter) = try await novel()
        let real = try maker(store, chapter)
        var m: Mounted!
        m = try mount(Self.document, tableFigureMaker: { request in
            let birth = try await real(request)
            let tea = (m.textView.string as NSString).range(of: "Tea")
            m.textView.textStorage?.replaceCharacters(in: tea, with: "Coffee")
            m.textView.didChangeText()
            return birth
        })

        await convert(m, at: location(of: "Cake", in: m))

        XCTAssertEqual(m.textView.string,
                       Self.document.replacingOccurrences(of: "Tea", with: "Coffee"),
                       "the changed table is left as it is")
        XCTAssertEqual(figureIds(store), [], "the new figure is no longer in the book")
        XCTAssertEqual(trashedFigureIds(store).count, 1, "it is in the Trash")
        XCTAssertEqual(m.box.reported, [
            "The table changed while its figure was being made and was left as it is, "
                + "so the figure went to the Trash.",
        ])
    }

    /// The table's start moved by typing above it is followed, not refused.
    func test_typingAboveTheTableWhileItsFigureIsMadeStillConverts() async throws {
        let (store, chapter) = try await novel()
        let real = try maker(store, chapter)
        var m: Mounted!
        m = try mount(Self.document, tableFigureMaker: { request in
            let birth = try await real(request)
            m.textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0),
                                                      with: "Opening. ")
            m.textView.didChangeText()
            return birth
        })

        await convert(m, at: location(of: "Cake", in: m))

        XCTAssertEqual(m.textView.string, "Opening. " + Self.document.replacingOccurrences(
            of: Self.cashTable, with: "![Cash in hand](../figures/cash.csv){#tbl:cash}"))
        XCTAssertEqual(m.box.reported, [])
    }

    // MARK: - One ⌘Z

    /// One ⌘Z puts the pipe table back and sends the figure to the Trash;
    /// ⇧⌘Z brings the same figure back with its line.
    func test_oneUndoTakesBackTheLineAndTheFigure() async throws {
        let (store, chapter) = try await novel()
        let m = try mount(Self.document, tableFigureMaker: try maker(store, chapter))
        await convert(m, at: location(of: "Cake", in: m))
        let converted = m.textView.string
        let figureId = try XCTUnwrap(figureIds(store).first)

        await undo(m)
        XCTAssertEqual(m.textView.string, Self.document, "⌘Z puts the pipe table back")
        XCTAssertEqual(figureIds(store), [])
        XCTAssertEqual(trashedFigureIds(store), [figureId])

        await redo(m)
        XCTAssertEqual(m.textView.string, converted)
        XCTAssertEqual(figureIds(store), [figureId], "the same figure, id kept")
        XCTAssertEqual(m.box.reported, [])
    }

    // MARK: - Names and labels (R7b-9)

    /// A table with no label: the figure is named after its caption, stepped
    /// clear of the `tbl:` names in use, and the line's label is minted from
    /// that name.
    func test_aTableWithNoLabelIsNamedAfterItsCaptionAndGetsALabel() async throws {
        let (store, chapter) = try await novel()
        let text = """
            See @tbl:quarterly-cash.

            | Q | Cash |
            | --- | --- |
            | 1 | 10 |
            Table: Quarterly cash, by region and year
            """
        let m = try mount(text, tableFigureMaker: try maker(store, chapter))

        await convert(m, at: location(of: "| 1", in: m))

        XCTAssertEqual(m.textView.string, """
            See @tbl:quarterly-cash.

            ![Quarterly cash, by region and year](../figures/quarterly-cash-by-region.csv){#tbl:quarterly-cash-by-region}
            """)
        XCTAssertEqual(store.manifest.figures?.map(\.name), ["quarterly-cash-by-region"])
    }

    /// The name steps past a `tbl:` name the text cites; the label follows it.
    func test_aMintedNameStepsPastTheTblNamesInUse() async throws {
        let (store, chapter) = try await novel()
        let text = "See @tbl:costs.\n\n| A |\n| --- |\n| 1 |\nTable: Costs"
        let m = try mount(text, tableFigureMaker: try maker(store, chapter))

        await convert(m, at: location(of: "| 1", in: m))

        XCTAssertEqual(m.textView.string,
                       "See @tbl:costs.\n\n![Costs](../figures/costs_2.csv){#tbl:costs_2}")
    }

    /// A kept label is never stepped: a registry figure already called `cash`
    /// gives the new figure `cash_2`, and the line keeps `{#tbl:cash}`.
    func test_aKeptLabelStaysWhenTheNameTakesASuffix() async throws {
        let (store, chapter) = try await novel()
        _ = try await store.createFigure(kind: .table, name: "cash", piece: chapter.id)
        let m = try mount(Self.cashTable, tableFigureMaker: try maker(store, chapter))

        await convert(m, at: location(of: "Cake", in: m))

        XCTAssertEqual(m.textView.string, "![Cash in hand](../figures/cash_2.csv){#tbl:cash}")
        XCTAssertEqual(store.manifest.figures?.map(\.name), ["cash", "cash_2"])
    }

    func test_theConvertedNameRule() {
        XCTAssertEqual(FigureIngest.convertedTableName(
            caption: "Cash", label: ManuscriptLabel(reference: "fig:money")!), "money")
        XCTAssertEqual(FigureIngest.convertedTableName(caption: nil, label: nil), "table")
        XCTAssertEqual(FigureIngest.convertedTableName(caption: "  ", label: nil), "table")
        XCTAssertEqual(FigureIngest.convertedTableName(caption: "—", label: nil), "table")
        XCTAssertEqual(FigureIngest.convertedTableName(caption: "Café über alles", label: nil),
                       "cafe-uber-alles")
        XCTAssertEqual(FigureIngest.convertedTableName(caption: "One two three four five", label: nil),
                       "one-two-three-four")
    }

    // MARK: - Cells kept as text, failures

    /// A formula that will not read is kept as text, and the writer is told
    /// which cell.
    func test_anUnreadFormulaIsKeptAsTextAndNamed() async throws {
        let (store, chapter) = try await novel()
        let m = try mount("| A | B |\n| --- | --- |\n| 1 | =NOSUCH(( |\nTable: T {#tbl:t}",
                          tableFigureMaker: try maker(store, chapter))

        await convert(m, at: location(of: "| 1", in: m))

        XCTAssertEqual(m.textView.string, "![T](../figures/t.csv){#tbl:t}")
        XCTAssertEqual(m.box.reported.count, 1)
        XCTAssertTrue(m.box.reported.first?.hasPrefix(
            "The table is a figure now. One formula couldn’t be read and was kept as text: "
                + "row 2, column 2 (") == true, "\(m.box.reported)")
    }

    func test_theProblemSentence() {
        XCTAssertNil(FigureIngest.convertedTableProblemsMessage([]))
        let six = (0..<6).map { CSVReadProblem(row: $0, column: 0, message: "bad") }
        XCTAssertEqual(
            FigureIngest.convertedTableProblemsMessage(six),
            "The table is a figure now. 6 formulas couldn’t be read and were kept as text: "
                + "row 1, column 1 (bad); row 2, column 1 (bad); row 3, column 1 (bad); "
                + "row 4, column 1 (bad); row 5, column 1 (bad); and 1 more.")
    }

    func test_theFailureSentences() {
        XCTAssertEqual(FigureIngest.tableConvertFailureMessage(for: FigureEditRefused(site: "x")),
                       "This Mac may not make a figure here, so the table was not converted.")
        XCTAssertEqual(
            FigureIngest.tableConvertFailureMessage(for: FigureTablePipeError.tooLarge(cells: 10_001)),
            "The table has 10001 cells, more than a table figure holds (10000), so it was not converted.")
        XCTAssertEqual(FigureIngest.tableConvertFailureMessage(for: CancellationError()),
                       "The table figure couldn’t be made, so the table was not converted.")
    }

    /// A store refusal writes nothing and says why.
    func test_aRefusedMakeLeavesTheTableAndSaysWhy() async throws {
        let m = try mount(Self.cashTable, tableFigureMaker: { _ in
            throw FigureEditRefused(site: "createFigure")
        })
        await convert(m, at: location(of: "Cake", in: m))
        XCTAssertEqual(m.textView.string, Self.cashTable)
        XCTAssertEqual(m.box.reported,
                       ["This Mac may not make a figure here, so the table was not converted."])
    }

    // MARK: - The offer, the menu item, the command

    /// Offered anywhere in a pipe table — header, delimiter row, a cell, the
    /// caption line — and nowhere else; never where the editor may not write
    /// or makes no table figures.
    func test_theOfferIsInsideAPipeTableOnly() throws {
        let m = try mount(Self.document, tableFigureMaker: { _ in throw CancellationError() })
        for needle in ["| Item", "| --- | --- |\n| Tea", "Cake", "Table: Cash", "#tbl:cash}"] {
            XCTAssertTrue(m.coordinator.convertOffer(atCharacterIndex: location(of: needle, in: m)),
                          "not offered at \(needle)")
        }
        for needle in ["Intro", "See @tbl"] {
            XCTAssertFalse(m.coordinator.convertOffer(atCharacterIndex: location(of: needle, in: m)),
                           "offered at \(needle)")
        }
        m.coordinator.setLockEditing(true)
        XCTAssertFalse(m.coordinator.convertOffer(atCharacterIndex: location(of: "Cake", in: m)),
                       "offered where the document can't be written")

        let bare = try mount(Self.document)
        XCTAssertFalse(bare.coordinator.convertOffer(atCharacterIndex: location(of: "Cake", in: bare)),
                       "offered on a surface that makes no table figures")
    }

    /// The right-click's item is built only where the offer says so, and
    /// converts the table it was built on.
    func test_theMenuItemIsBuiltOnlyWhereOffered() throws {
        let m = try mount(Self.document, tableFigureMaker: { _ in throw CancellationError() })
        XCTAssertNil(m.coordinator.convertTableMenuItem(atCharacterIndex: location(of: "Intro", in: m)))
        let at = location(of: "Cake", in: m)
        let item = try XCTUnwrap(m.coordinator.convertTableMenuItem(atCharacterIndex: at))
        XCTAssertEqual(item.title, "Convert to Table Figure")
        XCTAssertTrue(item.target === m.coordinator)
        XCTAssertEqual(item.action, #selector(EditorCoordinator.convertTableFromMenu(_:)))
        XCTAssertEqual(item.representedObject as? Int, at)
    }

    /// ⌘⌥⇧T as the menu posts it converts the caret's table; outside a
    /// table it does nothing (R7b-8).
    func test_theConvertCommandConvertsTheCaretsTableAndNothingElsewhere() async throws {
        let (store, chapter) = try await novel()
        let m = try mount(Self.document, tableFigureMaker: try maker(store, chapter))
        m.textView.setSelectedRange(NSRange(location: location(of: "Intro", in: m), length: 0))
        m.coordinator.tableFigureTask = nil
        MaughamEvent.post(.maughamConvertTable, to: .keyWindow)
        XCTAssertNil(m.coordinator.tableFigureTask, "outside a table nothing is begun")

        m.textView.setSelectedRange(NSRange(location: location(of: "Cake", in: m), length: 0))
        MaughamEvent.post(.maughamConvertTable, to: .keyWindow)
        await m.coordinator.tableFigureTask?.value
        XCTAssertTrue(m.textView.string.contains("![Cash in hand](../figures/cash.csv){#tbl:cash}"))
        XCTAssertEqual(figureIds(store).count, 1)
    }
}
