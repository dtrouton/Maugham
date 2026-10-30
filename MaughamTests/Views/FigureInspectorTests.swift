import XCTest
import AppKit
import SwiftUI
import Observation
@testable import MaughamCore
@testable import Maugham

/// **The figure inspector** (report plan 8a Task 7, spec §7, §4.3): each
/// field read from its source (the window's listing, the registry, the host's
/// pins, the figure's notes), a rename refused and put back, a Used-in link
/// landing the caret on its line through the real navigation receiver,
/// Compare's old and new and Refresh as one step on the open grid's stack,
/// the writing actions absent where the posture or the share forbids, and
/// Send to Research from the inspector removing the line and repairing the
/// subject. Every action is called through its model or helper — no control
/// pressed, no click synthesised (tripwire 33).
@MainActor
final class FigureInspectorTests: FigureGridMountedTestCase {

    override func setUp() async throws {
        try await super.setUp()
        let identities = LocalIdentities.softwareForTesting()
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: temp.url.appendingPathComponent("op-log-state.json"))
        Document.registryCacheForTesting = RegistryCache(
            fileURL: temp.url.appendingPathComponent("registry-cache.json"),
            identity: identities.author.fingerprint)
        Document.admissionMemoryForTesting = AdmissionMemory(
            fileURL: temp.url.appendingPathComponent("admission-memory.json"),
            identity: identities.author.fingerprint)
    }

    override func tearDown() async throws {
        for window in probeWindows { window.contentView = NSView(frame: .zero) }
        probeWindows = []
        try await super.tearDown()
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
    }

    private var probeWindows: [NSWindow] = []

    // MARK: - Fixture

    /// The chapter's text: prose, the figure's line, a paragraph of two lines,
    /// and a cross-reference to the figure's label.
    private static let chapterText =
        "Prose before.\n\n![Cash flow](../figures/t.csv){#tbl:t}\n\nOne line\nand another.\n\nA first line\nAs @tbl:t shows."

    /// The chapter written with `chapterText` and bootstrapped into its op log.
    private func writeChapter(_ m: Mounted) async throws -> (docId: String, path: String) {
        let chapter = try XCTUnwrap(m.store.manifest.structure.first)
        let path = try XCTUnwrap(chapter.path)
        try (Self.chapterText + "\n").write(to: m.store.url.appendingPathComponent(path),
                                            atomically: true, encoding: .utf8)
        let doc = try await Document.load(url: m.store.url.appendingPathComponent(path), actor: .author,
                                          session: "s", presenter: nil)
        await doc.close()
        return (chapter.id, path)
    }

    /// The window's listing over the book, as `ReferenceIndexWiring` feeds it.
    private func listing(_ m: Mounted) async throws -> FigureListingModel {
        let index = ReferenceIndexHost()
        index.attach(.window(store: m.store, documentStore: try XCTUnwrap(m.store.documentStore)))
        await index.idle()
        let listing = FigureListingModel()
        listing.refresh(index: index.index, store: m.store)
        index.attach(nil)
        return listing
    }

    private func actions(_ m: Mounted, windows: FigureWindows? = nil, control: EditorControl = EditorControl(),
                         persona: Persona = .author, model: FigureInspectorModel) -> FigureActions {
        FigureInspector.actions(store: m.store, figureWindows: windows, control: control, persona: persona,
                                model: model)
    }

    /// A Research table `model` and a figure `summary` whose A1 reads
    /// `research:model!B2*2`, entered through its host (the pin taken).
    private func summaryReadingModel(_ m: Mounted) async throws -> (item: ResearchItem, summary: FigureRecord) {
        let ds = try XCTUnwrap(m.store.documentStore)
        let folder = temp.url.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let csv = folder.appendingPathComponent("model.csv")
        try Data("Year,Revenue\n2025,10\n2026,20\n".utf8).write(to: csv)
        let item = try await m.store.addResearchAsset(parentId: nil, fromURL: csv)
        let summary = try await m.store.createFigure(kind: .table, name: "summary", piece: nil)
        try await ds.withFigureHost(summary.id) { host in
            let a1 = CellKey(row: host.state.table.rows[0], column: host.state.table.columns[0])
            let names = FormulaNames(research: [(item.id, item.title)])
            guard case .success(let f) = FormulaParser.parse("research:model!B2*2", in: host.state.table,
                                                              names: names)
            else { throw FigureEditInvalid(reason: "the formula did not parse") }
            try await host.setCell(Cell(content: .formula(f)), at: a1)
        }
        return (item, summary)
    }

    private func rewriteModel(_ m: Mounted, _ item: ResearchItem, _ text: String) throws {
        try Data(text.utf8).write(to: m.store.url.appendingPathComponent(try XCTUnwrap(item.path)))
    }

    /// Sam is admitted as the author of the chapter, so this root yields on
    /// it — and on the figures made in it.
    private func samWritesTheChapter(_ m: Mounted) async throws {
        let ds = try XCTUnwrap(m.store.documentStore)
        let sam = LocalIdentities.softwareForTesting()
        _ = try await ds.admit(device: sam.author.fingerprint, label: "Sam", ownName: "Sam’s Mac",
                               permit: .author(.pieces([try XCTUnwrap(m.store.manifest.structure.first?.id)])))
        await ds.postureSettled()
    }

    // MARK: - Each field's source

    /// **Name, number and section, Used in and its cross-reference** come
    /// from the window's listing and the registry; **Reads from Research**
    /// from the host's `pinStatus` and the pins it holds; the line numbers
    /// count from 1 as the writer reads them.
    func test_eachFieldReadsItsSource() async throws {
        let m = try await mount()
        let (docId, _) = try await writeChapter(m)
        let figure = try XCTUnwrap(m.figure)
        let listing = try await listing(m)
        let row = try XCTUnwrap(listing.row(forFigureId: figure.id))
        let title = try XCTUnwrap(m.store.manifest.structure.first?.title)

        XCTAssertEqual(row.name, "t", "the registry's name")
        XCTAssertEqual(FigureInspector.numberAndSection(row, structure: m.store.manifest.structure),
                       "Table 1 \u{00B7} \(title)", "the book's number and the piece holding the line")
        XCTAssertEqual(row.usedIn, [FigureListing.Use(docId: docId, lineIndex: 2)])
        XCTAssertEqual(row.referencedFrom, [FigureListing.Use(docId: docId, lineIndex: 8)])
        XCTAssertEqual(FigureInspector.useTitle(row.usedIn[0], structure: m.store.manifest.structure),
                       "\(title), line 3")
        let unused = FigureListing.Row(figureId: "fig-x", kind: .table, name: "x", caption: "",
                                       number: FigureListing.unusedNumber, usedIn: [], referencedFrom: [],
                                       pieceOfLine: nil)
        XCTAssertEqual(FigureInspector.numberAndSection(unused, structure: []), "\u{2014} \u{00B7} unused")

        // Reads from Research: the host's answer, never the body's.
        let (item, summary) = try await summaryReadingModel(m)
        let model = FigureInspectorModel(figureId: summary.id)
        let ds = try XCTUnwrap(m.store.documentStore)
        await model.loadPins(store: m.store, documentStore: ds)
        XCTAssertEqual(model.sources.map(\.title), ["model"])
        XCTAssertEqual(model.sources.first?.range, "B2", "the pinned cell, in A1")
        XCTAssertEqual(model.sources.first?.status, .current)
        XCTAssertNil(model.sources.first?.statusText)
        XCTAssertNotNil(model.sources.first?.pinnedAt)

        try rewriteModel(m, item, "Year,Revenue\n2025,15\n2026,20\n")
        await model.loadPins(store: m.store, documentStore: ds)
        XCTAssertEqual(model.sources.first?.statusText, "changed", "the source moved on")

        // A figure with no pins reads from nothing.
        let plain = FigureInspectorModel(figureId: figure.id)
        await plain.loadPins(store: m.store, documentStore: ds)
        XCTAssertEqual(plain.sources, [])
    }

    /// The sources row, pure: every pin on a source spans its rectangle, the
    /// latest pin dates it, and each status names its tag.
    func test_aSourceRowSpansItsPinsAndDatesTheLatest() {
        let cell = CellKey(row: RowID("r1"), column: ColumnID("c1"))
        let early = Date(timeIntervalSince1970: 1_000), late = Date(timeIntervalSince1970: 2_000)
        let pins: [CellKey: [FigureResearchPin]] = [cell: [
            FigureResearchPin(research: "r-1", row: 1, column: 1, value: .number(1), sourceHash: "h", at: early),
            FigureResearchPin(research: "r-1", row: 4, column: 2, value: .number(2), sourceHash: "h", at: late),
        ]]
        let rows = FigurePinSourceRow.build(
            status: ["r-1": .sourceChanged(old: "h", new: "i"), "r-2": .unpinned(new: "j"), "r-3": .sourceMissing],
            pins: pins, title: { ["r-1": "model", "r-2": "budget", "r-3": "costs"][$0] ?? $0 })
        XCTAssertEqual(rows.map(\.title), ["budget", "costs", "model"])
        XCTAssertEqual(rows.map(\.statusText), ["not pinned", "missing", "changed"])
        XCTAssertEqual(rows[2].range, "B2:C5")
        XCTAssertEqual(rows[2].pinnedAt, late)
        XCTAssertNil(rows[0].range, "no pin recorded on it")
    }

    /// **The notes are the figure stream's own**, read off the main actor
    /// (`ProjectStore.figureNotes`), oldest first — and reading them, or
    /// writing the figure, never runs the project's annotation walk (I3).
    func test_theNotesAreTheFiguresStreamOnly_andNoWriteRunsTheProjectWalk() async throws {
        let m = try await mount()
        let figure = try XCTUnwrap(m.figure)
        let ds = try XCTUnwrap(m.store.documentStore)
        for (id, body, at) in [("01FFF2", "second", 1_700_000_100.0), ("01FFF1", "first", 1_700_000_000.0)] {
            try await OpLogStore(projectURL: m.store.url).append(Op(
                opId: id, docId: figure.id, at: Date(timeIntervalSince1970: at),
                device: "mac", session: "s", kind: .claudeComment, changes: [],
                provenance: Op.Provenance(sessionId: "s", annotationBody: body,
                                          figureRowId: "r1", figureColId: "c1")))
        }
        let walks = m.store._debugAnnotationsRebuildCount
        let model = FigureInspectorModel(figureId: figure.id)
        await model.loadNotes(store: m.store)
        XCTAssertEqual(model.notes.map(\.body), ["first", "second"], "the figure's stream, oldest first")
        XCTAssertEqual(FigureInspector.kindTitle(.suggestedChange), "Suggestion")

        // A cell write (the figure revision moves) and both loads: no walk.
        try await ds.withFigureHost(figure.id) { host in
            let a1 = CellKey(row: host.state.table.rows[0], column: host.state.table.columns[0])
            try await host.setCell(Cell(content: .value(.number(7))), at: a1)
        }
        await model.loadPins(store: m.store, documentStore: ds)
        await model.loadNotes(store: m.store)
        XCTAssertEqual(m.store._debugAnnotationsRebuildCount, walks, "no project annotation walk")

        let named = Notification(name: .maughamAnnotationsChanged, object: nil,
                                 userInfo: [MaughamEvent.annotationDocIdKey: figure.id])
        let other = Notification(name: .maughamAnnotationsChanged, object: nil,
                                 userInfo: [MaughamEvent.annotationDocIdKey: "doc-a"])
        XCTAssertTrue(FigureInspectorModel.names(figure.id, named), "a change on its stream reloads the notes")
        XCTAssertFalse(FigureInspectorModel.names(figure.id, other), "another piece's does not")
    }

    // MARK: - Rename

    /// **A refused rename is said, and the field is put back** to the name
    /// the registry holds; an accepted one leaves the new name.
    func test_aRefusedRenameIsSaidAndTheFieldReverts() async throws {
        let m = try await mount()
        let figure = try XCTUnwrap(m.figure)
        _ = try await m.store.createFigure(kind: .table, name: "tax", piece: nil)
        let model = FigureInspectorModel(figureId: figure.id)
        let actions = actions(m, model: model)
        var field = "tax"

        await FigureInspector.rename(to: "tax", actions: actions, model: model,
                                     current: { m.store.manifest.figures?.first { $0.id == figure.id }?.name },
                                     revert: { field = $0 }).value
        XCTAssertNotNil(model.message, "the refusal is said")
        XCTAssertEqual(field, "t", "the field is put back")
        XCTAssertEqual(m.store.manifest.figures?.first { $0.id == figure.id }?.name, "t")

        field = "cashflow"
        await FigureInspector.rename(to: "cashflow", actions: actions, model: model,
                                     current: { m.store.manifest.figures?.first { $0.id == figure.id }?.name },
                                     revert: { field = $0 }).value
        XCTAssertNil(model.message, "control: an accepted rename says nothing")
        XCTAssertEqual(field, "cashflow")
        XCTAssertEqual(m.store.manifest.figures?.first { $0.id == figure.id }?.name, "cashflow")
    }

    // MARK: - Used in

    /// The line → place walk over the op log's paragraphs: a paragraph of
    /// several lines holds each at its offset, the blank between two is the
    /// next one's start.
    func test_aLineIsPlacedInItsParagraphAtItsOffset() {
        let paragraphs = ["a1b2": "Prose.", "c3d4": "![Cash](../figures/t.csv)", "e5f6": "One\ntwo"]
        let sequence = ["a1b2", "c3d4", "e5f6"]
        let at = { FigureUseTravel.place(atLine: $0, paragraphs: paragraphs, sequence: sequence) }
        XCTAssertEqual(at(0), .init(paragraphId: "a1b2", offset: 0))
        XCTAssertEqual(at(1), .init(paragraphId: "c3d4", offset: 0), "the blank is the next one's start")
        XCTAssertEqual(at(2), .init(paragraphId: "c3d4", offset: 0))
        XCTAssertEqual(at(4), .init(paragraphId: "e5f6", offset: 0))
        XCTAssertEqual(at(5), .init(paragraphId: "e5f6", offset: 4), "the second line, after \"One\\n\"")
        XCTAssertNil(at(6))
        XCTAssertNil(at(-1))
    }

    /// **A Used-in link lands the caret on the line**: the listing's use,
    /// placed in the op log's paragraph (open or closed), travels as the
    /// source reveal (`TranslationReveal`, the window's piece-then-scroll
    /// path) and the paragraph's navigation; the editor's own receiver puts
    /// the caret at the figure line. A cross-reference lands on its line too.
    func test_usedInTravelLandsTheCaretOnTheLine() async throws {
        let m = try await mount(Self.chapterText)
        let (docId, path) = try await writeChapter(m)
        let figure = try XCTUnwrap(m.figure)
        let built = try await listing(m)
        let row = try XCTUnwrap(built.row(forFigureId: figure.id))
        let ds = try XCTUnwrap(m.store.documentStore)

        // Closed: the op log's derived paragraphs place it.
        let closed = FigureUseTravel.destination(for: row.usedIn[0], store: m.store, documentStore: ds)
        guard case .paragraph(let reveal) = closed else { return XCTFail("a paragraph: \(closed)") }
        XCTAssertEqual(reveal.docId, docId)
        XCTAssertNil(reveal.language, "the source, never an edition")

        // Open: the live document places it the same, and its text is the editor's.
        let doc = try await Document.load(url: m.store.url.appendingPathComponent(path), actor: .author,
                                          session: "s2", presenter: nil)
        ds.register(document: doc, for: path)
        defer { ds.unregister(path: path) }
        XCTAssertEqual(doc.displayText, m.textView.string, "premise: the editor shows the piece")
        let figureLine = location(m, "![Cash flow]")
        XCTAssertEqual(reveal.paragraphId, doc.paragraphId(at: figureLine))
        XCTAssertEqual(FigureUseTravel.destination(for: row.usedIn[0], store: m.store, documentStore: ds),
                       closed, "open or closed, one paragraph")
        m.coordinator.paragraphRangeProvider = { doc.displayRange(forParagraphId: $0) }

        var posted: [Notification.Name] = []
        FigureUseTravel.perform(closed, select: { _ in XCTFail("a paragraph is not a subject write") },
                                post: { name, payload in
            posted.append(name)
            MaughamEvent.post(name, to: .keyWindow, payload: payload)
        })
        XCTAssertEqual(posted, [.maughamRevealTranslation, .maughamNavigateToParagraph])
        XCTAssertEqual(m.textView.selectedRange(), NSRange(location: figureLine, length: 0),
                       "the caret is on the figure's line")
        XCTAssertTrue(m.window.firstResponder === m.textView)

        // The cross-reference sits on the SECOND line of its paragraph: the
        // reveal carries the line's offset, and it survives the reveal's
        // payload (what `TranslationReviewModifier` decodes) and the reveal's
        // own navigation (`TranslationReveal.perform`, which the window runs
        // once the piece's document is up — production's landing path).
        let reference = FigureUseTravel.destination(for: row.referencedFrom[0], store: m.store, documentStore: ds)
        guard case .paragraph(let referenceReveal) = reference else { return XCTFail("a paragraph: \(reference)") }
        XCTAssertEqual(referenceReveal.offset, ("A first line\n" as NSString).length)
        XCTAssertEqual(TranslationReveal.decode(TranslationReveal.payload(referenceReveal)), referenceReveal,
                       "the offset rides the reveal's payload")
        m.textView.setSelectedRange(NSRange(location: 0, length: 0))
        await TranslationReveal.perform(referenceReveal,
                                        post: { MaughamEvent.post($0, to: .keyWindow, payload: $1) })
        XCTAssertEqual(m.textView.selectedRange(), NSRange(location: location(m, "As @tbl:t"), length: 0),
                       "the caret is on the cross-reference's line, not its paragraph's first")

        // A line the op log cannot place selects the piece alone.
        var selected: BinderSubject?
        let gone = FigureUseTravel.destination(for: FigureListing.Use(docId: docId, lineIndex: 99),
                                               store: m.store, documentStore: ds)
        XCTAssertEqual(gone, .piece(.item(docId)))
        FigureUseTravel.perform(gone, select: { selected = $0 }, post: { _, _ in XCTFail("nothing posted") })
        XCTAssertEqual(selected, .item(docId))
    }

    // MARK: - Compare and Refresh

    /// **Compare shows old and new; Refresh writes one step on the open
    /// grid's stack**: the centre holds the figure (its grid open), Compare
    /// lists the pinned cell with what it shows and what the source holds,
    /// Refresh through the shared helper re-pins it as ONE ⌘Z on the centre
    /// grid's own stack, and that ⌘Z puts the old pin back. With no grid open
    /// Refresh is not offered: nothing is asked, and there is no step.
    func test_compareShowsOldAndNew_andRefreshIsOneStepOnTheGridsStack() async throws {
        let m = try await mount()
        let (item, summary) = try await summaryReadingModel(m)
        let ds = try XCTUnwrap(m.store.documentStore)
        let windows = FigureWindows()
        let centre = FigureCentreMount(
            figureId: summary.id, windows: windows, presence: FigureGridPresence(), store: ds,
            projectStore: m.store, line: ("—", ""), piece: nil, typography: .defaults,
            isReviewMode: false, shareIsReadOnly: false)
        centre.take()
        await centre.grid?.opening?.value
        let grid = try XCTUnwrap(centre.grid?.controller, "the centre's grid opened")
        let model = FigureInspectorModel(figureId: summary.id)
        let actions = actions(m, windows: windows, model: model)
        XCTAssertTrue(actions.openGrid(summary.id) === grid, "the helper finds the centre's grid")

        try rewriteModel(m, item, "Year,Revenue\n2025,15\n2026,20\n")
        await model.loadComparisons(store: m.store, documentStore: ds)
        XCTAssertEqual(model.comparisons?.map { [$0.cell, $0.source, $0.old, $0.new] },
                       [["A1", "model B2", "10", "15"]], "old beside new, per pinned cell")

        let a1 = CellKey(row: grid.host.state.table.rows[0], column: grid.host.state.table.columns[0])
        XCTAssertFalse(grid.gridUndo.canUndo, "premise: the grid's stack is empty")
        await actions.refreshPins(summary.id)?.value
        await grid.settleWrites()
        await ds.awaitOpenFigureRenderForTesting()
        XCTAssertEqual(grid.host.state.pins[a1]?.first?.value, .number(15), "refreshed")
        XCTAssertTrue(grid.gridUndo.canUndo)
        XCTAssertEqual(grid.gridUndo.undoActionName, "Refresh from Research")
        await model.loadComparisons(store: m.store, documentStore: ds)
        XCTAssertEqual(model.comparisons, [], "nothing left to compare")

        grid.gridUndo.undo()
        await grid.host.awaitPendingUndoWork()
        XCTAssertEqual(grid.host.state.pins[a1]?.first?.value, .number(10), "one ⌘Z puts the old pin back")
        XCTAssertFalse(grid.gridUndo.canUndo, "the refresh was ONE step")

        centre.leave()
        await windows.visitEnded(summary.id)
        XCTAssertNil(actions.openGrid(summary.id))
        XCTAssertNil(actions.refreshPins(summary.id), "no grid open: Refresh is not asked")
        XCTAssertNil(model.message)
        XCTAssertFalse(actions.importFromCSV(summary.id), "nor Import")
        XCTAssertEqual(model.message, FigureActions.openTheTableFirst, "an Import with no grid is said, not dropped")
    }

    /// **Whether a grid is open is observed** (I2): the centre's controller
    /// mounts after an await, and a view asking `hasGrid` is told when it
    /// does — and again when the grid goes — so Import and Refresh follow the
    /// grid rather than whatever the inspector last drew.
    func test_aGridOpeningOrGoingIsSeenByAViewAskingHasGrid() async throws {
        let m = try await mount()
        let figure = try XCTUnwrap(m.figure)
        let ds = try XCTUnwrap(m.store.documentStore)
        let windows = FigureWindows()
        let actions = actions(m, windows: windows, model: FigureInspectorModel(figureId: figure.id))
        let centre = FigureCentreMount(
            figureId: figure.id, windows: windows, presence: FigureGridPresence(), store: ds,
            projectStore: m.store, line: ("—", ""), piece: nil, typography: .defaults,
            isReviewMode: false, shareIsReadOnly: false)
        centre.take()
        XCTAssertNil(centre.grid?.controller, "premise: the hold is taken, the visit still opening")

        var told = false
        XCTAssertFalse(withObservationTracking { actions.hasGrid(figure.id) } onChange: { told = true })
        await centre.grid?.opening?.value
        XCTAssertTrue(told, "the visit opening is observed")
        XCTAssertTrue(actions.hasGrid(figure.id))
        XCTAssertNil(FigureInspector.refusal(mayEdit: true, hasGrid: actions.hasGrid(figure.id)))

        told = false
        XCTAssertTrue(withObservationTracking { actions.hasGrid(figure.id) } onChange: { told = true })
        centre.leave()
        XCTAssertTrue(told, "the grid going is observed")
        XCTAssertFalse(actions.hasGrid(figure.id))
        XCTAssertEqual(FigureInspector.refusal(mayEdit: true, hasGrid: false), FigureActions.openTheTableFirst)
        await windows.visitEnded(figure.id)

        // A figure window's grid, once finished, answers no grid.
        let grid = FigureWindowGrid()
        let registration = windows.opened(figure.id, grid: { [weak grid] in
            grid?.isFinished == false ? grid?.controller : nil
        }, close: {})
        grid.open(figureId: figure.id, store: ds, projectStore: m.store, windows: windows, close: {})
        await grid.opening?.value
        XCTAssertTrue(actions.hasGrid(figure.id), "a window's grid is found")
        told = false
        _ = withObservationTracking { actions.hasGrid(figure.id) } onChange: { told = true }
        grid.finish()
        XCTAssertTrue(told)
        XCTAssertFalse(actions.hasGrid(figure.id), "a finished window grid takes no Import")
        windows.closed(registration)
        await grid.finishing?.value
    }

    /// Import from CSV goes to the open grid's import: its panel is asked.
    func test_importFromCSVOpensTheGridsImport() async throws {
        let m = try await mount()
        let figure = try XCTUnwrap(m.figure)
        let ds = try XCTUnwrap(m.store.documentStore)
        let windows = FigureWindows()
        let centre = FigureCentreMount(
            figureId: figure.id, windows: windows, presence: FigureGridPresence(), store: ds,
            projectStore: m.store, line: ("—", ""), piece: nil, typography: .defaults,
            isReviewMode: false, shareIsReadOnly: false)
        centre.take()
        await centre.grid?.opening?.value
        let grid = try XCTUnwrap(centre.grid?.controller)
        var asked = 0
        grid.chooseImportFile = { chosen in
            asked += 1
            chosen(nil)
        }
        let model = FigureInspectorModel(figureId: figure.id)
        XCTAssertTrue(actions(m, windows: windows, model: model).importFromCSV(figure.id))
        XCTAssertEqual(asked, 1, "the grid's own import asked for a file")
        centre.leave()
        await windows.visitEnded(figure.id)
    }

    // MARK: - Review Focus 5: who may write

    /// **The writing actions are absent where the posture or the share
    /// forbids**: another author's piece (the figure is its piece's) and a
    /// view-only share offer Open in Window alone; the book's author is
    /// offered all three, Import only for a table with a grid open.
    func test_theWritingActionsAreHiddenWhenThePostureOrTheShareForbids() async throws {
        let m = try await mount()
        let figure = try XCTUnwrap(m.figure)
        let model = FigureInspectorModel(figureId: figure.id)
        XCTAssertTrue(actions(m, model: model).mayEdit(figure.id), "control: the book's author")
        XCTAssertEqual(FigureInspector.offered(mayEdit: true, kind: .table),
                       [.openInWindow, .sendToResearch, .importCSV])
        XCTAssertEqual(FigureInspector.offered(mayEdit: true, kind: .image), [.openInWindow, .sendToResearch])
        XCTAssertEqual(FigureInspector.offered(mayEdit: false, kind: .table), [.openInWindow])
        XCTAssertEqual(FigureInspector.refusal(mayEdit: false, hasGrid: true), "This figure is read-only here.",
                       "Compare's Refresh says why in Review")

        // The window's own refusal: one answer, for the inspector and the tree.
        let viewOnly = EditorControl()
        viewOnly.shareIsReadOnly = true
        let manualReview = EditorControl()
        manualReview.isManualReviewMode = true
        XCTAssertFalse(actions(m, control: viewOnly, model: model).mayEdit(figure.id), "a view-only share")
        XCTAssertFalse(actions(m, control: manualReview, model: model).mayEdit(figure.id), "⌘⌥⇧R")
        XCTAssertFalse(actions(m, persona: .review, model: model).mayEdit(figure.id), "the Review persona")
        XCTAssertTrue(actions(m, persona: .plan, model: model).mayEdit(figure.id), "control: Plan edits figures")
        let tree = BinderTreeSectionsState()
        tree.figureWritesRefused = FigureActions.windowRefusesWrites(control: viewOnly, persona: .plan)
        XCTAssertFalse(FigureSectionVerbs(store: m.store, state: tree).shared.mayEdit(figure.id),
                       "the tree's row refuses on the same answer")

        try await samWritesTheChapter(m)
        XCTAssertFalse(actions(m, model: model).mayEdit(figure.id), "another author's piece")
        XCTAssertFalse(FigureSectionVerbs(store: m.store, state: BinderTreeSectionsState()).shared.mayEdit(figure.id),
                       "the tree's row asks the same helper")
    }

    @Observable
    @MainActor
    final class WindowBox {
        var control = EditorControl()
        var persona: Persona = .plan
    }

    /// The tree wired as `ProjectWindow` wires it, in a window with no editor.
    private struct TreeWiringProbe: View {
        let box: WindowBox
        let store: ProjectStore
        let documentStore: DocumentStore
        let tree: BinderTreeSectionsState
        var body: some View {
            Color.clear.modifier(FigureSectionWiring(
                store: store, documentStore: documentStore, listing: FigureListingModel(), treeState: tree,
                figureWindows: nil, typography: .defaults, control: box.control, persona: box.persona))
        }
    }

    /// **I1: a Plan window with no editor on a view-only share** — the tree's
    /// row hears the share from the window's control plane, as the inspector
    /// does, so it offers no Send to Research or Rename; the share lifting,
    /// it offers them again. ⌘⌥⇧R and the Review persona the same.
    func test_theTreeHearsTheWindowsShareAndReviewWithNoEditorMounted() async throws {
        let m = try await mount()
        let figure = try XCTUnwrap(m.figure)
        let ds = try XCTUnwrap(m.store.documentStore)
        let tree = BinderTreeSectionsState()
        let box = WindowBox()
        box.control.shareIsReadOnly = true
        probeWindows.append(TestWindow.mount(
            AnyView(TreeWiringProbe(box: box, store: m.store, documentStore: ds, tree: tree)),
            size: CGSize(width: 320, height: 240)))
        let verbs = FigureSectionVerbs(store: m.store, state: tree)
        let refused = await pumpUntil(deadline: 5) { tree.figureWritesRefused }
        XCTAssertTrue(refused, "a view-only share reaches the tree")
        XCTAssertFalse(verbs.actions(for: FigureTreeRow(listing: FigureListing.Row(
            figureId: figure.id, kind: .table, name: "t", caption: "", number: "—", usedIn: [],
            referencedFrom: [], pieceOfLine: nil), readsResearch: false, changed: false)).mayEdit())

        box.control.shareIsReadOnly = false
        let lifted = await pumpUntil(deadline: 5) { !tree.figureWritesRefused }
        XCTAssertTrue(lifted)
        XCTAssertTrue(verbs.shared.mayEdit(figure.id), "control: the share lifted")

        box.control.isManualReviewMode = true
        let reviewing = await pumpUntil(deadline: 5) { tree.figureWritesRefused }
        XCTAssertTrue(reviewing, "⌘⌥⇧R")
        box.control.isManualReviewMode = false
        box.persona = .review
        let review = await pumpUntil(deadline: 5) { tree.figureWritesRefused }
        XCTAssertTrue(review, "the Review persona")
    }

    /// `cards`, cut off from the store's own triggers (a late presenter
    /// pass over the figure's files), its fills counted once idle — so a
    /// later fill can only be the owner's manifest edge.
    static func fillsHearingOnlyTheOwner(_ cards: FigureCardCache, store: DocumentStore) async -> Int {
        store.detachFigureCardCache(cards)
        await cards.idle()
        return cards.fills
    }

    /// A CSV outside the book, added to Research: `manifest.research` moves.
    private func addResearchTable(_ m: Mounted, _ name: String) async throws {
        let folder = temp.url.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let csv = folder.appendingPathComponent("\(name).csv")
        try Data("A,B\n1,2\n".utf8).write(to: csv)
        _ = try await m.store.addResearchAsset(parentId: nil, fromURL: csv)
    }

    /// **I1: Research changing refills the tree's cards** — the edge the
    /// tree's wiring carries (`FigureSectionWiring`), in a window with no
    /// editor, so no other cache's edge can stand in for it. The cards are
    /// cut off from the store's triggers and Research moves in memory only,
    /// as an adopted manifest moves it, so nothing but the edge refills them.
    func test_researchChangingRefillsTheTreesCards() async throws {
        let m = try await mount()
        let ds = try XCTUnwrap(m.store.documentStore)
        try await addResearchTable(m, "budget")
        let tree = BinderTreeSectionsState()
        probeWindows.append(TestWindow.mount(
            AnyView(TreeWiringProbe(box: WindowBox(), store: m.store, documentStore: ds, tree: tree)),
            size: CGSize(width: 320, height: 240)))
        let filled = await pumpUntil(deadline: 5) { tree.figureCards.fills > 0 }
        XCTAssertTrue(filled, "premise: the tree's cards filled")
        let before = await Self.fillsHearingOnlyTheOwner(tree.figureCards, store: ds)
        m.store.manifest.research[0].title = "budget 2"
        let refilled = await pumpUntil(deadline: 5) { tree.figureCards.fills > before }
        XCTAssertTrue(refilled, "a Research change refills the tree's cards")
    }

    /// **I2: the pins reload at the cards' rate, never for a figure reading
    /// nothing from Research, and the latest load wins.** The tree's cards
    /// say which figures read Research; a figure that reads none is shown
    /// none with no read of its host. The load key moves with the cards'
    /// version and with Research, not with an op that changes no card. A load
    /// overtaken while it awaited — by a later load, or its task's
    /// cancellation — lands nothing.
    func test_thePinsReloadAtTheCardsRate_skipAFigureReadingNothing_andTheLatestLoadWins() async throws {
        let m = try await mount()
        let ds = try XCTUnwrap(m.store.documentStore)
        let plain = try XCTUnwrap(m.figure)
        let (item, summary) = try await summaryReadingModel(m)
        let tree = BinderTreeSectionsState()
        FigureSectionWiring.attach(tree, to: ds)
        await tree.figureCards.idle()
        XCTAssertEqual(tree.figureCards.readsFromResearch(figureId: summary.id), true)
        XCTAssertEqual(tree.figureCards.readsFromResearch(figureId: plain.id), false)
        XCTAssertEqual(tree.figureCardsVersion, tree.figureCards.version, "the version is the tree's to observe")

        // A figure reading nothing: no host read.
        let plainModel = FigureInspectorModel(figureId: plain.id)
        await plainModel.loadPins(store: m.store, documentStore: ds,
                                  readsFromResearch: tree.figureCards.readsFromResearch(figureId: plain.id))
        XCTAssertEqual(plainModel.pinReads, 0, "nothing read for a figure reading nothing from Research")
        XCTAssertEqual(plainModel.sources, [])

        // The key: Research moves it; the cards' version moves it.
        let key = { FigureInspector.LoadKey(figureId: summary.id, cards: tree.figureCardsVersion,
                                            research: m.store.manifest.research) }
        let first = key()
        try await addResearchTable(m, "budget")
        XCTAssertNotEqual(key(), first, "Research changing moves the key")

        // The latest load wins.
        let model = FigureInspectorModel(figureId: summary.id)
        await model.loadPins(store: m.store, documentStore: ds, readsFromResearch: true)
        XCTAssertEqual(model.sources.first?.status, .current, "premise")
        var held: CheckedContinuation<Void, Never>?
        var holding = true
        model.beforeLandingForTesting = { kind in
            guard kind == .pins, holding else { return }
            holding = false
            await withCheckedContinuation { held = $0 }
        }
        try rewriteModel(m, item, "Year,Revenue\n2025,15\n2026,20\n")
        // An earlier load reads "changed" and waits; Research is put back; a
        // later load reads "current" and lands first.
        let earlier = Task { await model.loadPins(store: m.store, documentStore: ds, readsFromResearch: true) }
        let waiting = await pumpUntil(deadline: 5) { held != nil }
        XCTAssertTrue(waiting, "premise: the earlier load read and is waiting to land")
        try rewriteModel(m, item, "Year,Revenue\n2025,10\n2026,20\n")
        await model.loadPins(store: m.store, documentStore: ds, readsFromResearch: true)
        XCTAssertEqual(model.sources.first?.status, .current, "the later load landed")
        held?.resume()
        await earlier.value
        XCTAssertEqual(model.sources.first?.status, .current, "the earlier load, overtaken, landed nothing")

        // A cancelled load lands nothing either.
        holding = true
        held = nil
        try rewriteModel(m, item, "Year,Revenue\n2025,15\n2026,20\n")
        let cancelled = Task { await model.loadPins(store: m.store, documentStore: ds, readsFromResearch: true) }
        let parked = await pumpUntil(deadline: 5) { held != nil }
        XCTAssertTrue(parked)
        cancelled.cancel()
        held?.resume()
        await cancelled.value
        XCTAssertEqual(model.sources.first?.status, .current, "a cancelled load landed nothing")
        tree.detachFigureCards()
    }

    /// **M2: the notes' latest load wins** — two annotation changes, the
    /// earlier read finishing last, leave the later read's notes.
    func test_theNotesLatestLoadWins() async throws {
        let m = try await mount()
        let figure = try XCTUnwrap(m.figure)
        func note(_ id: String, _ body: String, _ at: Double) async throws {
            try await OpLogStore(projectURL: m.store.url).append(Op(
                opId: id, docId: figure.id, at: Date(timeIntervalSince1970: at),
                device: "mac", session: "s", kind: .claudeComment, changes: [],
                provenance: Op.Provenance(sessionId: "s", annotationBody: body,
                                          figureRowId: "r1", figureColId: "c1")))
        }
        try await note("01FFF1", "first", 1_700_000_000)
        let model = FigureInspectorModel(figureId: figure.id)
        var held: CheckedContinuation<Void, Never>?
        var holding = true
        model.beforeLandingForTesting = { kind in
            guard kind == .notes, holding else { return }
            holding = false
            await withCheckedContinuation { held = $0 }
        }
        let earlier = Task { await model.loadNotes(store: m.store) }
        let waiting = await pumpUntil(deadline: 5) { held != nil }
        XCTAssertTrue(waiting, "premise: the earlier read is waiting to land")
        try await note("01FFF2", "second", 1_700_000_100)
        await model.loadNotes(store: m.store)
        XCTAssertEqual(model.notes.map(\.body), ["first", "second"])
        held?.resume()
        await earlier.value
        XCTAssertEqual(model.notes.map(\.body), ["first", "second"], "the earlier read, overtaken, landed nothing")
    }

    /// **M1: a refused name can be sent again.** Return then the focus
    /// leaving send it once; the rename's answer (here a refusal: the name
    /// is taken) forgets it, so retyping it sends it again — and so does the
    /// registry's name moving.
    func test_aRefusedNameCanBeSentAgain() async throws {
        let m = try await mount()
        let figure = try XCTUnwrap(m.figure)
        _ = try await m.store.createFigure(kind: .table, name: "tax", piece: nil)
        let model = FigureInspectorModel(figureId: figure.id)
        XCTAssertTrue(model.takesTheName("tax"))
        XCTAssertFalse(model.takesTheName("tax"), "Return, then the focus leaving: sent once")
        await FigureInspector.rename(to: "tax", actions: actions(m, model: model), model: model,
                                     current: { m.store.manifest.figures?.first { $0.id == figure.id }?.name },
                                     revert: { _ in }).value
        XCTAssertNotNil(model.message, "premise: refused")
        XCTAssertTrue(model.takesTheName("tax"), "after the refusal the same name is sent again")
        model.forgetTheCommittedName()   // the registry's name moved
        XCTAssertTrue(model.takesTheName("tax"))
    }

    /// **M7: Import and Refresh act through this window's grid only.** A grid
    /// open on the figure in another window is not acted through: that
    /// window comes front and the line says to do it there; from the grid's
    /// own window, Import reaches it.
    func test_importAndRefreshActThroughThisWindowsGridOnly() async throws {
        let m = try await mount()
        let figure = try XCTUnwrap(m.figure)
        let ds = try XCTUnwrap(m.store.documentStore)
        let windows = FigureWindows()
        let grid = FigureWindowGrid()
        var focused = 0
        let registration = windows.opened(figure.id, focus: { focused += 1 }, grid: { [weak grid] in
            grid?.isFinished == false ? grid?.controller : nil
        }, close: {})
        grid.open(figureId: figure.id, store: ds, projectStore: m.store, windows: windows, close: {})
        await grid.opening?.value
        let controller = try XCTUnwrap(grid.controller)
        let gridsWindow: NSWindow = TestWindow.make(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            contentView: NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300)))
        gridsWindow.contentView?.addSubview(grid.container)
        let thisWindow: NSWindow = TestWindow.make(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            contentView: NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300)))
        probeWindows += [gridsWindow, thisWindow]
        var asked = 0
        controller.chooseImportFile = { chosen in
            asked += 1
            chosen(nil)
        }

        let model = FigureInspectorModel(figureId: figure.id)
        let here = FigureInspector.actions(store: m.store, figureWindows: windows, control: EditorControl(),
                                           persona: .author, model: model, window: thisWindow)
        XCTAssertEqual(here.gridReach(figure.id), .inAnotherWindow)
        XCTAssertEqual(FigureInspector.refusal(mayEdit: true, reach: .inAnotherWindow), FigureActions.openInThatWindow)
        XCTAssertFalse(here.importFromCSV(figure.id), "not acted through from another window")
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(model.message, FigureActions.openInThatWindow, "said")
        XCTAssertEqual(focused, 1, "and that window comes front")
        XCTAssertNil(here.refreshPins(figure.id), "Refresh likewise")
        XCTAssertEqual(focused, 2)

        let there = FigureInspector.actions(store: m.store, figureWindows: windows, control: EditorControl(),
                                            persona: .author, model: model, window: gridsWindow)
        XCTAssertEqual(there.gridReach(figure.id), .here)
        XCTAssertTrue(there.importFromCSV(figure.id), "control: from the grid's own window it acts")
        XCTAssertEqual(asked, 1)
        grid.finish()
        windows.closed(registration)
        await grid.finishing?.value
    }

    // MARK: - Send to Research

    @Observable
    @MainActor
    final class SubjectBox {
        var subject: BinderSubject?
        init(_ subject: BinderSubject?) { self.subject = subject }
    }

    private struct SubjectProbe: View {
        let box: SubjectBox
        let store: ProjectStore
        let documentStore: DocumentStore
        var body: some View {
            Color.clear.modifier(SubjectValidationModifier(
                store: store, documentStore: documentStore,
                selectedSubject: Binding(get: { box.subject }, set: { box.subject = $0 })))
        }
    }

    /// **Send to Research from the inspector** (the helper the tree shares):
    /// the centre's grid folds first, the figure parks, its line leaves the
    /// chapter, and the window's subject repairs to the project row.
    func test_sendToResearchFromTheInspectorRemovesTheLineAndRepairsTheSubject() async throws {
        let m = try await mount()
        let (docId, _) = try await writeChapter(m)
        let figure = try XCTUnwrap(m.figure)
        let ds = try XCTUnwrap(m.store.documentStore)
        let built = try await listing(m)
        let row = try XCTUnwrap(built.row(forFigureId: figure.id))
        let windows = FigureWindows()
        let centre = FigureCentreMount(
            figureId: figure.id, windows: windows, presence: FigureGridPresence(), store: ds,
            projectStore: m.store, line: (row.number, row.caption), piece: docId, typography: .defaults,
            isReviewMode: false, shareIsReadOnly: false)
        centre.take()
        await centre.grid?.opening?.value
        let box = SubjectBox(.figure(figure.id))
        probeWindows.append(TestWindow.mount(AnyView(SubjectProbe(box: box, store: m.store, documentStore: ds)),
                                             size: CGSize(width: 320, height: 240)))
        let model = FigureInspectorModel(figureId: figure.id)
        let actions = actions(m, windows: windows, model: model)
        XCTAssertEqual(actions.sendDestinations(for: row), [.piece, .shared])

        await actions.sendToResearch(row, to: .piece)?.value

        XCTAssertNil(model.message)
        XCTAssertTrue(centre.hasLeft, "the centre's grid folded first")
        let parked = try await ds.figureIsParked(figure.id)
        XCTAssertTrue(parked)
        let text = try m.store.derivedCache.displayText(forDocId: docId, in: m.store.url)
        XCTAssertFalse(text.contains("figures/t.csv"), "the line left the chapter: \(text)")
        XCTAssertTrue(text.contains("Prose before."), "control: the rest stays")
        let repaired = await pumpUntil(deadline: 5) { box.subject == .project }
        XCTAssertTrue(repaired, "the subject repairs to the project row: \(String(describing: box.subject))")
    }
}
