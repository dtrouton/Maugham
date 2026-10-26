// MaughamTests/Editor/EditorIntegrationHarnessTests.swift
import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class EditorIntegrationHarnessTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()   // the figure-card cases style through ProseMode
    }

    func test_singleCharacterTyped_textViewMatchesUserInput() {
        let rig = EditorIntegrationHarness(initialText: "")
        rig.typeCharacter("a")
        XCTAssertEqual(rig.currentText, "a")
        XCTAssertEqual(rig.cursorLocation, 1)
    }

    func test_rapidTyping_preservesCursorAtEnd() async {
        let rig = EditorIntegrationHarness(initialText: "")
        await rig.typeString("The quick brown fox")
        XCTAssertEqual(rig.currentText, "The quick brown fox")
        XCTAssertEqual(rig.cursorLocation, 19,
            "after typing 19 chars at end, cursor must be at 19")
    }

    func test_rapidTyping_inMiddle_preservesInsertionPoint() async {
        let rig = EditorIntegrationHarness(initialText: "Hello world")
        rig.setCursor(to: 5)  // between "Hello" and " world"
        await rig.typeString(", dear")
        XCTAssertEqual(rig.currentText, "Hello, dear world")
        XCTAssertEqual(rig.cursorLocation, 11)  // 5 + 6 typed chars
    }

    func test_trailingSpace_persistsAcrossAutosave() async throws {
        let rig = EditorIntegrationHarness(initialText: "")
        await rig.typeString("hello ")
        // Wait > 750ms for any autosave to complete + onChange to run.
        try await Task.sleep(for: .milliseconds(900))
        await rig.typeString("world")
        // The trailing space we typed should still be present.
        XCTAssertEqual(rig.currentText, "hello world",
            "trailing space typed before autosave must persist")
    }

    func test_pasteMultiCharString_preservesCursorAtPasteEnd() {
        let rig = EditorIntegrationHarness(initialText: "")
        rig.paste("foo bar")
        XCTAssertEqual(rig.currentText, "foo bar")
        XCTAssertEqual(rig.cursorLocation, 7)
    }

    func test_externalEditWithIdsIntact_isDiscarded() async throws {
        let rig = EditorIntegrationHarness(
            initialText: "<!-- ¶a3f9 -->\n\nHello.\n")
        let docStore = try await rig.attachDocumentStore()
        // ADR 0019: the op log is the source of truth — seed it (after
        // attachDocumentStore writes the manifest) so the doc derives its
        // paragraph from the op log. Even an intact-id external edit is NOT
        // honored: external .md edits are discarded (the op-log truth wins).
        try await seedOpLogBootstrap(
            projectURL: rig.projectURL,
            docId: "doc-test",
            paragraphs: ["a3f9": "Hello."],
            sequence: ["a3f9"])
        let doc = try await Document.load(
            url: rig.projectURL.appendingPathComponent(rig.docPath),
            device: "m", session: "s", presenter: docStore.presenter)
        docStore.register(document: doc, for: rig.docPath)

        // Write the external content + drive the presenter callback. In
        // process NSFilePresenter callbacks are unreliable, so we invoke the
        // dispatch directly — this still exercises the T11 routing path
        // (`presenterDidChangeSubitem` → `document(for:)` → Document).
        try await rig.writeExternalMdContent(
            "<!-- ¶a3f9 -->\n\nHello, edited.\n")
        docStore.presenterDidChangeSubitem(
            at: rig.projectURL.appendingPathComponent(rig.docPath))
        // The discard handler backs up the external bytes; wait for that.
        let conflictsDir = rig.projectURL.appendingPathComponent(".maugham/conflicts")
        try await waitFor(timeout: .seconds(2)) {
            (try? FileManager.default.contentsOfDirectory(
                at: conflictsDir, includingPropertiesForKeys: nil))?.isEmpty == false
        }

        // The op-log truth wins: the external edit never enters in-memory state.
        XCTAssertFalse(doc.displayText.contains("edited"),
            "external .md edits are discarded — the op-log truth wins, not the disk bytes")
        XCTAssertTrue(doc.displayText.contains("Hello"))
    }

    func test_externalEditWithIdsStripped_isDiscarded() async throws {
        let rig = EditorIntegrationHarness(
            initialText: "<!-- ¶a3f9 -->\n\nHello.\n")
        let docStore = try await rig.attachDocumentStore()
        let doc = try await Document.load(
            url: rig.projectURL.appendingPathComponent(rig.docPath),
            device: "m", session: "s", presenter: docStore.presenter)
        docStore.register(document: doc, for: rig.docPath)

        try await rig.writeExternalMdContent("Hello, edited (no IDs).\n")
        docStore.presenterDidChangeSubitem(
            at: rig.projectURL.appendingPathComponent(rig.docPath))
        // The discard handler re-materializes the op-log truth over the external
        // bytes (after backing them up). Poll on the actual asserted condition —
        // the re-materialize having landed on disk — not on the backup dir, which
        // is written BEFORE the flush and would race the disk assertion below.
        let docOnDisk = rig.projectURL.appendingPathComponent(rig.docPath)
        try await waitFor(timeout: .seconds(2)) {
            let disk = try? String(contentsOf: docOnDisk, encoding: .utf8)
            return disk != nil && !disk!.contains("Hello, edited (no IDs)")
        }

        // Stripped ¶ids change nothing: external .md edits are discarded, and
        // the op-log truth is re-materialized over them.
        XCTAssertFalse(doc.displayText.contains("edited"),
            "stripped-id external edits are still discarded — no conflict, op-log truth wins")
        let disk = try String(contentsOf: docOnDisk, encoding: .utf8)
        XCTAssertFalse(disk.contains("Hello, edited (no IDs)"),
            "the external edit must be blown away by the op-log re-materialize")
        // The backup is written before the re-materialize, so by now it exists.
        let conflictsDir = rig.projectURL.appendingPathComponent(".maugham/conflicts")
        XCTAssertEqual(
            (try? FileManager.default.contentsOfDirectory(
                at: conflictsDir, includingPropertiesForKeys: nil))?.isEmpty, false,
            "the discarded external bytes must be snapshotted under .maugham/conflicts/")
    }

    /// Polls predicate every 50ms up to `timeout`. Returns when true; no
    /// throw on timeout — caller asserts the actual condition right after.
    private func waitFor(
        timeout: Duration, _ predicate: @escaping () -> Bool
    ) async throws {
        let start = Date()
        let maxSeconds = Double(timeout.components.seconds)
        while !predicate() {
            if Date().timeIntervalSince(start) > maxSeconds { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func test_endOfFileTyping_doesNotFireApplyExternalText() {
        let rig = EditorIntegrationHarness(initialText: "Hello")
        rig.setCursor(to: 5)

        rig.assertNoApplyExternalText {
            rig.typeCharacter(" ")
            rig.typeCharacter("w")
            rig.typeCharacter("o")
            rig.typeCharacter("r")
            rig.typeCharacter("l")
            rig.typeCharacter("d")
        }

        XCTAssertEqual(rig.currentText, "Hello world")
        XCTAssertEqual(rig.cursorLocation, 11)
    }

    func test_documentSwitch_flushesPendingBurst_beforeNewBinding() async throws {
        // Two documents in the same project; type in doc A, close it,
        // assert A's op log received the typing_burst op (i.e. close
        // flushed the pending buffer).
        let tmp = TestTemp.root
            .appendingPathComponent("EIH-T9-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        let docAPath = "manuscript/a.md"
        let docBPath = "manuscript/b.md"
        try "Doc A initial.\n".data(using: .utf8)!.write(
            to: tmp.appendingPathComponent(docAPath), options: .atomic)
        try "Doc B initial.\n".data(using: .utf8)!.write(
            to: tmp.appendingPathComponent(docBPath), options: .atomic)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [
                StructureItem(id: "doc-a", title: "A", type: .document, path: docAPath),
                StructureItem(id: "doc-b", title: "B", type: .document, path: docBPath),
            ],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        let docA = try await Document.load(
            url: tmp.appendingPathComponent(docAPath),
            device: "m", session: "s", presenter: nil)
        docA.setFullText("Doc A edited.")
        // Simulate the doc-switch: close docA before loading docB.
        await docA.close()

        let opStore = OpLogStore(projectURL: tmp)
        let opsA = try await opStore.load(docId: docA.docId)
        let burstCount = opsA.filter { $0.kind == .typingBurst }.count
        XCTAssertGreaterThanOrEqual(burstCount, 1,
            "doc-switch close() must flush the pending typing_burst op")
    }

    func test_typingCaretIntoCharacterCue_doesNotFireApplyExternalText() {
        // Regression net for dual-dialogue cue entry (CLAUDE.md tripwire 7).
        // Typing "^" after a character name produces a dual-dialogue cue; the
        // tokenizer strips the caret from content but must not trigger
        // applyExternalText (which is reserved for cloud-conflict resolution).
        let rig = EditorIntegrationHarness(
            mode: ScreenplayMode(),
            initialText: "BRICK\nHello.\n\n")

        rig.assertNoApplyExternalText {
            for ch in "STEVE ^\nHi." {
                rig.typeCharacter(ch)
            }
        }
    }

    func test_burst_appendOnceAtIdleThreshold() async throws {
        // Short thresholds via the internal Document.load overload so the
        // test doesn't have to wait 30 seconds.
        let tmp = TestTemp.root
            .appendingPathComponent("EIH-T10-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        let docPath = "manuscript/c.md"
        try "Hello.\n".data(using: .utf8)!.write(
            to: tmp.appendingPathComponent(docPath), options: .atomic)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [StructureItem(id: "doc-c", title: "C", type: .document, path: docPath)],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        let doc = try await Document.load(
            url: tmp.appendingPathComponent(docPath),
            device: "m", session: "s", presenter: nil,
            burstIdle: .milliseconds(250),
            burstMax: .seconds(60))

        let opStore = OpLogStore(projectURL: tmp)
        let opsBefore = try await opStore.load(docId: doc.docId)
        let burstsBefore = opsBefore.filter { $0.kind == .typingBurst }.count

        // Type a burst.
        doc.setFullText("Hello world.")

        // Wait > idle threshold so the BurstScheduler fires.
        try await Task.sleep(for: .milliseconds(600))

        let opsAfter = try await opStore.load(docId: doc.docId)
        let burstsAfter = opsAfter.filter { $0.kind == .typingBurst }.count
        XCTAssertEqual(burstsAfter, burstsBefore + 1,
            "exactly one typing_burst op should fire at idle threshold")
    }

    // MARK: - Figure cards end to end (report plan 7a Task 7)
    //
    // The whole chain a window wires: a real `FigureCardCache` filled from a
    // counting source (`FigureCardBook`), its version written into a real
    // `EditorControl` by EditorHost's own closure, the control plane carrying
    // it to the coordinator, the coordinator reading each line's card from the
    // cache. A remote figure change is `cache.invalidate()`, which is what
    // `DocumentStore`'s figure triggers call when another device's ops land.

    private static func room(_ model: FigureCardModel?) -> CGFloat {
        FigureCardMetrics.room(for: model, typography: .defaults)
    }

    /// Review Focus 1: typing a burst in a long document with 30 table
    /// cards while a remote figure change lands mid-burst. No
    /// `applyExternalText`, no caret or scroll move; the keystrokes never
    /// fill the cache or restyle a figure line; the changed figure's line
    /// re-lays out once, after the burst settles.
    func test_figureCards_aRemoteChangeMidBurstReLaysOutItsLineOnceAfterTheSettle() async {
        let rig = EditorIntegrationHarness(
            mode: ProseMode(reservesFigureThumbnails: true),
            initialText: FigureCardBook.manuscript(tables: 30), cursorLocation: 0)
        let book = FigureCardBook(tables: 30, rows: 3)
        let coordinator = rig.coordinator
        await book.wire(coordinator, documentPath: rig.docPath, textView: rig.textView)
        let target = FigureCardBook.line(17), figure17 = FigureCardBook.id(17)
        let body = rig.spacing(at: "Opening")
        let small = Self.room(book.cache.model(forFigureId: figure17))
        XCTAssertEqual(book.reads, 1, "precondition: one fill on open")
        XCTAssertEqual(rig.spacing(at: target), body + small, "precondition: the first fill's room is painted")
        XCTAssertNotEqual(small, FigureThumbnailLayout.reservedHeight, "precondition: a card, not the placeholder")

        let layout = EditRecordingLayoutManager.install(on: rig.textView)
        func figureLines() -> [NSRange] { (0..<30).map { rig.nsText.range(of: FigureCardBook.line($0)) } }
        let clip = rig.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: rig.lineTop(of: "Paragraph 2 of prose")))
        rig.scrollView.reflectScrolledClipView(clip)
        // The origin is read once every pending layout and display pass has
        // run, so none can move it later (final review I5).
        rig.textView.layoutManager!.ensureLayout(for: rig.textView.textContainer!)
        rig.window.displayIfNeeded()
        let origin = clip.bounds.origin
        XCTAssertGreaterThan(origin.y, 0, "precondition: scrolled down")
        let refreshes = coordinator.figureRoomRefreshCount
        let typeAt = NSMaxRange(rig.nsText.range(of: "Paragraph 3 of prose under its table"))
        rig.setCursor(to: typeAt)
        coordinator.restyleSettleDelayMs = 3_600_000   // the burst stays in flight until the test settles it

        rig.assertNoApplyExternalText { rig.type(" and") }
        XCTAssertTrue(coordinator.isInTypingBurst, "precondition: the burst is in flight")
        book.setRows(40, table: 17)
        book.cache.invalidate()                      // the remote change lands mid-burst
        await book.landFill(on: coordinator)
        XCTAssertEqual(book.reads, 2, "the remote change is one fill")
        XCTAssertTrue(coordinator.figureRoomsWaitForTheSettle, "the version waits for the settle")
        rig.assertNoApplyExternalText { rig.type(" more") }

        XCTAssertEqual(rig.spacing(at: target), body + small, "mid-burst the line keeps its painted room")
        XCTAssertEqual(coordinator.figureRoomRefreshCount, refreshes, "no figure line re-laid out mid-burst")
        XCTAssertEqual(layout.styleEdits(touching: figureLines()), [], "no keystroke restyled a figure line")
        XCTAssertEqual(book.reads, 2, "no keystroke filled the cache")
        let caret = typeAt + (" and more" as NSString).length
        XCTAssertEqual(rig.cursorLocation, caret)

        // The settle: one last key with no delay, then its deferred paint.
        coordinator.restyleSettleDelayMs = 0
        rig.assertNoApplyExternalText { rig.type(".") }
        // The settle this key scheduled, held before any await (final review I5).
        guard let settle = coordinator.deferredRestyleTask else {
            return XCTFail("precondition: the last key scheduled the settle")
        }
        await settle.value
        let grown = Self.room(book.cache.model(forFigureId: figure17))
        XCTAssertGreaterThan(grown, small, "precondition: forty rows need more room than three")
        XCTAssertEqual(rig.spacing(at: target), body + grown, "the line takes its new room at the settle")
        XCTAssertEqual(coordinator.figureRoomRefreshCount, refreshes + 1, "once, after the burst")
        XCTAssertFalse(coordinator.figureRoomsWaitForTheSettle)
        XCTAssertEqual(layout.styleEdits(touching: figureLines()).map(\.range), [rig.lineRange(of: target)],
                       "one attribute-only edit, over the changed figure's line alone")
        XCTAssertEqual(book.reads, 2, "the settle fills nothing")
        XCTAssertEqual(rig.cursorLocation, caret + 1, "the settle leaves the caret where the typing put it")
        rig.textView.layoutManager!.ensureLayout(for: rig.textView.textContainer!)
        XCTAssertEqual(clip.bounds.origin, origin, "no scroll snap")
        for i in [0, 3, 16, 18, 29] {
            XCTAssertEqual(rig.spacing(at: FigureCardBook.line(i)), body + small, "table \(i) untouched")
        }
        // The settle's window began at the newline ending table 3's line; the
        // line keeps its room to the last character.
        let three = rig.lineRange(of: FigureCardBook.line(3))
        XCTAssertEqual((rig.storage.attribute(.paragraphStyle, at: NSMaxRange(three) - 1, effectiveRange: nil)
                        as? NSParagraphStyle)?.paragraphSpacing, body + small)
        // And the refreshed, settled text equals a whole-document paint.
        let whole = EditorIntegrationHarness(
            mode: ProseMode(reservesFigureThumbnails: true), initialText: rig.currentText, cursorLocation: 0)
        book.paintWhole(whole.coordinator, documentPath: whole.docPath, textView: whole.textView)
        let settled = rig.paragraphStyles(), painted = whole.paragraphStyles()
        XCTAssertEqual(settled.map(\.0), painted.map(\.0))
        for (a, b) in zip(settled, painted) {
            XCTAssertTrue(a.1?.isEqual(b.1) ?? (b.1 == nil), "paragraph style at \(a.0)")
        }
    }

    /// Review Focus 2: a table grows from 3 to 40 rows on another device.
    /// Its card shows 12 rows and "+ 28 more rows", its room grows, the text
    /// below moves down once, and a windowed paint of the line agrees with a
    /// whole-document paint.
    func test_figureCards_aTableGrowingTo40RowsShows12AndMovesTheTextBelowOnce() async {
        let rig = EditorIntegrationHarness(
            mode: ProseMode(reservesFigureThumbnails: true),
            initialText: FigureCardBook.manuscript(tables: 8), cursorLocation: 0)
        let book = FigureCardBook(tables: 8, rows: 3)
        let coordinator = rig.coordinator
        await book.wire(coordinator, documentPath: rig.docPath, textView: rig.textView)
        let target = FigureCardBook.line(4), id = FigureCardBook.id(4)
        let three = book.cache.model(forFigureId: id)
        XCTAssertEqual(three.map { $0.headerRows.count + $0.bodyRows.count }, 3, "precondition")
        let body = rig.spacing(at: "Opening")
        let layout = EditRecordingLayoutManager.install(on: rig.textView)
        let above = rig.lineTop(of: "Paragraph 3 of prose")
        let below = rig.lineTop(of: "Paragraph 4 of prose")
        let farBelow = rig.lineTop(of: "Closing paragraph")
        let selection = NSRange(location: 3, length: 0)
        rig.textView.setSelectedRange(selection)

        book.setRows(40, table: 4)
        book.cache.invalidate()
        await book.landFill(on: coordinator)   // no burst: the version re-lays out at once

        let forty = book.cache.model(forFigureId: id)
        XCTAssertEqual(forty.map { $0.headerRows.count + $0.bodyRows.count }, FigureCardModel.maxShownRows,
                       "the card shows 12 rows")
        XCTAssertEqual(forty?.moreRows, 28, "and \"+ 28 more rows\"")
        let delta = Self.room(forty) - Self.room(three)
        XCTAssertGreaterThan(delta, 0, "its room grows")
        XCTAssertEqual(rig.spacing(at: target), body + Self.room(forty))
        XCTAssertEqual(layout.edits, [EditRecordingLayoutManager.Edit(
            charactersChanged: false, range: rig.lineRange(of: target))],
            "one attribute-only edit over the line: the text below moves once")
        XCTAssertEqual(rig.lineTop(of: "Paragraph 3 of prose"), above, "text above stays put")
        XCTAssertEqual(rig.lineTop(of: "Paragraph 4 of prose"), below + delta, accuracy: 0.5)
        XCTAssertEqual(rig.lineTop(of: "Closing paragraph"), farBelow + delta, accuracy: 0.5)
        XCTAssertEqual(rig.textView.selectedRange(), selection, "the caret never moves")

        // A windowed paint covering the line (an edit to its caption, settled)
        // reads the same grown card.
        coordinator.restyleSettleDelayMs = 0
        rig.setCursor(to: NSMaxRange(rig.nsText.range(of: "![Table 4")))
        rig.type("b")
        await coordinator.deferredRestyleTask?.value
        let edited = "![Table 4b](../figures/t4.csv)"
        XCTAssertEqual(rig.spacing(at: edited), body + Self.room(forty), "the windowed paint keeps the grown room")
        XCTAssertEqual(book.reads, 2, "an edit to a figure line fills nothing")

        let whole = EditorIntegrationHarness(
            mode: ProseMode(reservesFigureThumbnails: true), initialText: rig.currentText, cursorLocation: 0)
        book.paintWhole(whole.coordinator, documentPath: whole.docPath, textView: whole.textView)
        let windowed = rig.paragraphStyles(), painted = whole.paragraphStyles()
        XCTAssertEqual(windowed.map(\.0), painted.map(\.0), "windowed and whole-document paints agree")
        for (a, b) in zip(windowed, painted) {
            XCTAssertTrue(a.1?.isEqual(b.1) ?? (b.1 == nil), "paragraph style at \(a.0)")
        }
    }

    /// **The in-place grid** (report plan 7c Task 7): expanding a table card
    /// into its grid and folding it back are layout and focus only — no
    /// `applyExternalText`, no typing burst, the text untouched.
    func test_figureGrid_expandAndFoldFireNoApplyExternalTextAndNoBurst() async throws {
        let temp = TempDirectory()
        defer { temp.cleanup() }
        let url = try await ProjectFactory.createNovelProject(named: "Grid", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: store.url)
        store.documentStore = ds
        ds.projectStore = store
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let path = try XCTUnwrap(chapter.path)
        _ = try await store.createFigure(kind: .table, name: "t", piece: chapter.id, rows: 3, columns: 3)
        let cards = FigureCardCache()
        ds.attachFigureCardCache(cards)
        cards.attach(FigureCardCache.Source(read: { [weak ds] in await ds?.figureCardInputs() }))
        await cards.idle()

        let text = "Opening.\n\n![Cash](../figures/t.csv){#tbl:t}\n\nAfter."
        let rig = EditorIntegrationHarness(
            mode: ProseMode(reservesFigureThumbnails: true), initialText: text, cursorLocation: 0)
        let coordinator = rig.coordinator
        coordinator.figureImageResolver = { _ in .notLocal }
        coordinator.figureCardModel = { cards.model(forLinePath: $0, documentPath: path) }
        coordinator.figureGridOpening = .window(store: ds, projectStore: store, documentPath: path)
        coordinator.attach(to: rig.textView)   // a whole-document paint with the cards
        let line = (text as NSString).range(of: "![Cash](").location

        rig.assertNoApplyExternalText { XCTAssertTrue(coordinator.expandFigureGrid(lineAt: line)) }
        let grid = try XCTUnwrap(coordinator.figureGrid)
        await grid.opening?.value
        let controller = try XCTUnwrap(grid.controller, "the visit opened")
        XCTAssertFalse(coordinator.isInTypingBurst, "expanding is no typing")
        XCTAssertNil(coordinator.deferredRestyleTask, "and schedules no settle")

        rig.assertNoApplyExternalText { coordinator.foldFigureGrid(commit: true) }
        XCTAssertNil(coordinator.figureGrid)
        XCTAssertFalse(coordinator.isInTypingBurst, "folding is no typing")
        XCTAssertNil(coordinator.deferredRestyleTask)
        XCTAssertEqual(rig.currentText, text, "the text is untouched")

        await controller.settleWrites()
        controller.close()
        cards.attach(nil)
        ds.detachFigureCardCache(cards)
        await ds.close()
    }
}
