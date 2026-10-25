// MaughamTests/Editor/FigureCommandTests.swift
import XCTest
import AppKit
import SwiftUI
import MaughamCore
import ImageIO
import UniformTypeIdentifiers
@testable import Maugham

/// Image figures, end to end (plan 3a Task 6; report plan 6a Task 9): the ingest a drop,
/// a paste and Insert Figure… all run, driven directly on a mounted
/// `EditorSurface` over a real temporary project. No synthesised drag and no
/// press: the drop's decision is asked of the text view as a function, and the
/// ingest's task handle is awaited rather than polled.
@MainActor
final class FigureCommandTests: XCTestCase {
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
    }

    private func mount(_ text: String,
                       importer: FigureIngest.Importer?) throws -> Mounted {
        let box = Box(text)
        let binding = Binding(get: { box.text }, set: { box.text = $0 })
        var configuration = EditorSurfaceConfiguration(
            presentation: .init(theme: .light, typography: .defaults, mode: ProseMode(),
                                typewriterScroll: false, sentenceFocus: false,
                                paragraphFocus: false, showElementGutter: false),
            control: EditorControl())
        configuration.answersInsertCommands = true
        configuration.paragraphProviders.figureImporter = importer
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

    /// The app's undo grouping, stated (see `InsertCommandTests.asOneEvent`):
    /// the test host runs no event loop, so each user event is bracketed here.
    private func asOneEvent(_ m: Mounted, _ body: () async -> Void) async throws {
        let undo = try XCTUnwrap(m.textView.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        await body()
        undo.endUndoGrouping()
    }

    private func type(_ s: String, into m: Mounted) async throws {
        m.window.makeFirstResponder(m.textView)
        m.textView.setSelectedRange(NSRange(location: (m.textView.string as NSString).length,
                                            length: 0))
        try await asOneEvent(m) {
            m.textView.insertText(s, replacementRange: m.textView.selectedRange())
        }
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

    private func collectionPiece() async throws -> (ProjectStore, StructureItem) {
        let url = try await ProjectFactory.createCollectionProject(
            named: "Collection-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: store.url)
        store.documentStore = ds
        documentStores.append(ds)
        let piece = try await store.addLoosePiece(title: "One", format: .markdown)
        return (store, piece)
    }

    /// A real PNG on disk, outside the project, named as the writer named it.
    private func pngFile(named name: String) throws -> URL {
        let dir = temp.url.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try ImagePasteHandler.encodePNG(Self.picture()).write(to: url)
        return url
    }

    private static func picture() -> NSImage {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        return image
    }

    private func importer(_ store: ProjectStore, _ item: StructureItem) -> FigureIngest.Importer {
        { url, taken in
            try await FigureIngest.importImage(url, documentId: item.id,
                                               documentPath: item.path ?? "", taken: taken,
                                               store: store)
        }
    }

    /// The one image figure the store holds.
    private func onlyFigure(_ store: ProjectStore) throws -> FigureRecord {
        let figures = store.manifest.figures ?? []
        XCTAssertEqual(figures.count, 1, "\(figures)")
        return try XCTUnwrap(figures.first)
    }

    private func selected(_ m: Mounted) -> String {
        (m.textView.string as NSString).substring(with: m.textView.selectedRange())
    }

    // MARK: - End to end

    /// **A dropped PNG becomes an image figure in `figures/`** (report plan
    /// 6a Task 9): the file lands there, the registry names it with the
    /// chapter as its piece, its stream opens with `figureCreate(.image)` and
    /// `figureImageSet` carrying the file's hash, the line points there with
    /// the figure's name as its label, and the thumbnail's resolver finds it.
    func test_anImageInANovelChapterBecomesAFigureInFiguresWrittenAsOneUndoStep() async throws {
        let (store, chapter) = try await novel()
        let m = try mount("", importer: importer(store, chapter))
        try await type("Intro", into: m)
        let image = try pngFile(named: "Revenue Chart.png")

        try await asOneEvent(m) {
            await m.coordinator.beginFigureIngest([image], at: 5)?.value
        }

        let record = try onlyFigure(store)
        XCTAssertEqual(record.name, "revenue-chart")
        XCTAssertEqual(record.kind, .image)
        XCTAssertEqual(record.piece, chapter.id, "the figure is the chapter's")
        XCTAssertEqual(record.path, "figures/revenue-chart.png")
        let copied = store.url.appendingPathComponent("figures/revenue-chart.png")
        XCTAssertEqual(try Data(contentsOf: copied), try Data(contentsOf: image),
                       "copied byte for byte")
        XCTAssertNil(TreeWalk.first(in: store.manifest.research, where: { $0.title == "Revenue Chart" }),
                     "nothing is filed in research any more")
        let figure = try await FigureDocument.load(
            figureId: record.id, projectURL: store.url, actor: .author, session: "s",
            presenter: nil, documentStore: nil)
        XCTAssertEqual(figure.state.kind, .image)
        XCTAssertEqual(figure.state.image, FigureImageRef(
            filename: "revenue-chart.png",
            contentHash: try FigureImageResolver.contentHash(of: copied)),
            "the op log holds the file's name and hash")
        await figure.close()

        let line = "![Caption](../figures/revenue-chart.png){#fig:revenue-chart}"
        XCTAssertEqual(m.textView.string, "Intro\n\n" + line)
        XCTAssertEqual(m.box.text, m.textView.string, "the figure reached the binding")
        XCTAssertEqual(selected(m), "Caption")
        XCTAssertEqual(m.box.reported, [])
        guard case .file(let resolved) = FigureImageResolver.resolve(
            "../figures/revenue-chart.png", piecePath: try XCTUnwrap(chapter.path),
            projectURL: store.url, allowed: FigureThumbnailStore.triedExtensions) else {
            return XCTFail("the written path does not resolve for the thumbnail")
        }
        XCTAssertEqual(resolved, copied.resolvingSymlinksInPath())

        let undo = try XCTUnwrap(m.textView.undoManager)
        undo.undo()
        XCTAssertEqual(m.textView.string, "Intro", "one ⌘Z takes back the figure line")
        XCTAssertTrue(undo.canUndo, "the writer's typing is still undoable after it")
        XCTAssertEqual(store.manifest.figures?.map(\.id), [record.id],
                       "undoing the insert leaves the figure in place")
        undo.undo()
        XCTAssertEqual(m.textView.string, "")
    }

    /// A Collection piece's picture goes to the project's `figures/` too,
    /// reached from the piece's folder, and the figure is the piece's.
    func test_anImageInACollectionPieceLandsInTheProjectsFigures() async throws {
        let (store, piece) = try await collectionPiece()
        let piecePath = try XCTUnwrap(piece.path)
        let m = try mount("", importer: importer(store, piece))
        let image = try pngFile(named: "map.png")

        await m.coordinator.beginFigureIngest([image], at: 0)?.value

        let record = try onlyFigure(store)
        XCTAssertEqual(record.path, "figures/map.png")
        XCTAssertEqual(record.piece, piece.id)
        XCTAssertEqual(m.textView.string, "![Caption](../../figures/map.png){#fig:map}")
        guard case .file = FigureImageResolver.resolve("../../figures/map.png", piecePath: piecePath,
                                                       projectURL: store.url, allowed: ["png"])
        else { return XCTFail("the written path does not resolve from the piece") }
    }

    /// **The label is the figure's name, clear of the text's labels**: a
    /// legacy research figure already says `fig:map`, and a file the project
    /// already has in `figures/` is never overwritten — the new figure is
    /// `map_2`, its file `figures/map_2.png`, its label `fig:map_2`.
    func test_aNewFigureStepsAroundTheTextsLabelsAndTheFilesAlreadyThere() async throws {
        let (store, chapter) = try await novel()
        let legacy = "![Old](../research/map.png){#fig:map}"
        let m = try mount(legacy, importer: importer(store, chapter))
        let image = try pngFile(named: "map.png")

        await m.coordinator.beginFigureIngest([image], at: (legacy as NSString).length)?.value

        let record = try onlyFigure(store)
        XCTAssertEqual(record.name, "map_2")
        XCTAssertEqual(record.path, "figures/map_2.png")
        XCTAssertTrue(m.textView.string.hasSuffix("![Caption](../figures/map_2.png){#fig:map_2}"),
                      m.textView.string)

        // A stray file already in figures/ is stepped around, never replaced.
        let stray = store.url.appendingPathComponent("figures/chart.png")
        try Data([1, 2, 3]).write(to: stray)
        await m.coordinator.beginFigureIngest(
            [try pngFile(named: "chart.png")], at: (m.textView.string as NSString).length)?.value
        XCTAssertEqual(try Data(contentsOf: stray), Data([1, 2, 3]), "the stray file is untouched")
        XCTAssertEqual(store.manifest.figures?.last?.path, "figures/chart_2.png")
        XCTAssertTrue(m.textView.string.hasSuffix("![Caption](../figures/chart_2.png){#fig:chart_2}"),
                      m.textView.string)
    }

    /// **Figure lines written before keep resolving** (spec §4.4): an old
    /// `../research/x.png` line still finds its picture, beside a new one in
    /// `figures/`.
    func test_anOldResearchFigureLineStillResolves() async throws {
        let (store, chapter) = try await novel()
        let chapterPath = try XCTUnwrap(chapter.path)
        let research = store.url.appendingPathComponent("research/old.png")
        try ImagePasteHandler.encodePNG(Self.picture()).write(to: research)
        guard case .file = FigureImageResolver.resolve(
            "../research/old.png", piecePath: chapterPath, projectURL: store.url,
            allowed: FigureThumbnailStore.triedExtensions)
        else { return XCTFail("an old research figure line no longer resolves") }
    }

    func test_theLabelIsUniqueAgainstThisDocumentsFigures() async throws {
        var handed: Set<String> = []
        let m = try mount("![Caption](research/map.png){#fig:map}",
                          importer: { _, taken in handed = taken; return "research/map-2.png" })
        let image = try pngFile(named: "map.png")
        await m.coordinator.beginFigureIngest([image], at: (m.textView.string as NSString).length)?.value
        XCTAssertTrue(m.textView.string.hasSuffix("![Caption](research/map-2.png){#fig:map-2}"),
                      m.textView.string)
        XCTAssertEqual(handed, ["map"], "the importer is handed the labels the text uses")
    }

    // MARK: - Failure, refusal and the async point

    func test_aFailedCopyWritesNothingAndSaysWhy() async throws {
        struct Refused: Error {}
        let m = try mount("Intro", importer: { _, _ in throw Refused() })
        let image = try pngFile(named: "a.png")
        await m.coordinator.beginFigureIngest([image], at: 5)?.value
        XCTAssertEqual(m.textView.string, "Intro")
        XCTAssertEqual(m.box.reported, [ImagePasteHandler.failureMessage(for: Refused())])
    }

    func test_aReadOnlyPostureRefusesTheDropAndCopiesNothing() async throws {
        var asked = 0
        let m = try mount("Intro", importer: { _, _ in asked += 1; return "research/a.png" })
        let image = try pngFile(named: "a.png")
        XCTAssertEqual(m.textView.figureDragOperation(for: [image]), .copy,
                       "control: a writable manuscript takes the drop")

        m.coordinator.setLockEditing(true)
        XCTAssertEqual(m.textView.figureDragOperation(for: [image]), [],
                       "refused: the no-entry cursor")
        XCTAssertNil(m.coordinator.beginFigureIngest([image], at: 0))
        XCTAssertEqual(asked, 0, "nothing was copied")
        XCTAssertEqual(m.textView.string, "Intro")

        let text = temp.url.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: text)
        XCTAssertNil(m.textView.figureDragOperation(for: [text]),
                     "a drop that is not an image keeps today's behaviour")
    }

    func test_typingDuringTheCopyMovesTheFigureToTheStartOfItsParagraph() async throws {
        var m: Mounted!
        m = try mount("One.\n\nTwo three.", importer: { _, _ in
            // The writer types while the copy runs: above the paragraph, and in it.
            m.textView.insertText("Zero. ", replacementRange: NSRange(location: 0, length: 0))
            m.textView.insertText("!", replacementRange: NSRange(location: 15, length: 0))
            m.textView.setSelectedRange(NSRange(location: 16, length: 0))   // after "Two!"
            return "research/a.png"
        })
        let image = try pngFile(named: "a.png")
        m.window.makeFirstResponder(m.textView)
        await m.coordinator.beginFigureIngest([image], at: 9)?.value
        XCTAssertEqual(m.textView.string,
                       "Zero. One.\n\n![Caption](research/a.png){#fig:a}\n\nTwo! three.")
        // The writer typed on: their caret stays after "Two!" (whole-branch
        // review I2), never yanked to the caption.
        let caret = m.textView.selectedRange()
        XCTAssertEqual(caret.length, 0)
        XCTAssertTrue((m.textView.string as NSString).substring(to: caret.location).hasSuffix("Two!"),
                      "the caret moved to \(caret)")
    }

    // MARK: - A figure landing after the writer moved on (whole-branch review I2)

    /// The writer drops a picture, then focuses something else while it copies
    /// (the inspector, find). The line lands; the focus and the selection stay.
    func test_aFigureLandingWhileTheFocusIsElsewhereTakesNeitherTheFocusNorTheSelection() async throws {
        var m: Mounted!
        let elsewhere = NSTextView(frame: NSRect(x: 0, y: 0, width: 50, height: 20))
        m = try mount("Intro.\n\nBody text.", importer: { _, _ in
            m.window.contentView?.addSubview(elsewhere)
            m.window.makeFirstResponder(elsewhere)
            return "research/a.png"
        })
        m.window.makeFirstResponder(m.textView)
        m.textView.setSelectedRange(NSRange(location: 2, length: 3))
        let image = try pngFile(named: "a.png")
        await m.coordinator.beginFigureIngest([image], at: (m.textView.string as NSString).length)?.value
        XCTAssertEqual(m.textView.string, "Intro.\n\nBody text.\n\n![Caption](research/a.png){#fig:a}",
                       "the line still lands")
        XCTAssertTrue(m.window.firstResponder === elsewhere, "the figure took the focus")
        XCTAssertEqual(m.textView.selectedRange(), NSRange(location: 2, length: 3),
                       "the figure moved the writer's selection")
    }

    /// The writer, still in the manuscript, moves the caret while it copies:
    /// the line lands above, and their caret rides the edit.
    func test_aFigureLandingAfterTheCaretMovedKeepsTheCaretShiftedThroughTheEdit() async throws {
        var m: Mounted!
        m = try mount("Intro.\n\nBody text.", importer: { _, _ in
            m.textView.setSelectedRange(NSRange(location: 12, length: 0))   // "Body|"
            return "research/a.png"
        })
        m.window.makeFirstResponder(m.textView)
        m.textView.setSelectedRange(NSRange(location: 0, length: 0))
        let image = try pngFile(named: "a.png")
        await m.coordinator.beginFigureIngest([image], at: 0)?.value
        let line = "![Caption](research/a.png){#fig:a}\n\n"
        XCTAssertEqual(m.textView.string, line + "Intro.\n\nBody text.")
        XCTAssertEqual(m.textView.selectedRange(),
                       NSRange(location: 12 + (line as NSString).length, length: 0))
        XCTAssertTrue(m.window.firstResponder === m.textView)
    }

    /// The control: a writer still where they were gets the caption selected.
    func test_aFigureLandingWithTheWriterStillThereSelectsTheCaption() async throws {
        let m = try mount("Intro.", importer: { _, _ in "research/a.png" })
        m.window.makeFirstResponder(m.textView)
        m.textView.setSelectedRange(NSRange(location: 6, length: 0))
        await m.coordinator.beginFigureIngest([try pngFile(named: "a.png")], at: 6)?.value
        XCTAssertEqual(selected(m), "Caption")
    }

    /// An input method composing when the copy finishes: the line waits until
    /// the composition ends, then lands without touching it.
    func test_aFigureWaitsOutAComposition() async throws {
        var m: Mounted!
        m = try mount("Intro.\n\nBody", importer: { _, _ in
            m.textView.setSelectedRange(NSRange(location: 12, length: 0))
            m.textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                                     replacementRange: m.textView.selectedRange())
            return "research/a.png"
        })
        m.window.makeFirstResponder(m.textView)
        var waits = 0
        m.coordinator.figureCompositionWait = {
            waits += 1
            XCTAssertFalse(m.textView.string.contains("!["), "the line landed mid-composition")
            XCTAssertTrue(m.textView.hasMarkedText())
            if waits == 2 { m.textView.unmarkText() }
        }
        await m.coordinator.beginFigureIngest([try pngFile(named: "a.png")], at: 0)?.value
        XCTAssertEqual(waits, 2)
        XCTAssertEqual(m.textView.string, "![Caption](research/a.png){#fig:a}\n\nIntro.\n\nBodyか")
        XCTAssertEqual(m.box.reported, [])
    }

    /// A composition that outlasts every wait: nothing lands, the composition
    /// is untouched, and the writer is told.
    func test_aFigureGivesUpOnACompositionThatOutlastsTheWaits() async throws {
        var m: Mounted!
        m = try mount("Intro.", importer: { _, _ in
            m.textView.setSelectedRange(NSRange(location: 6, length: 0))
            m.textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                                     replacementRange: m.textView.selectedRange())
            return "research/a.png"
        })
        m.window.makeFirstResponder(m.textView)
        var waits = 0
        m.coordinator.figureCompositionWait = { waits += 1 }
        m.coordinator.figureCompositionWaitLimit = 3
        await m.coordinator.beginFigureIngest([try pngFile(named: "a.png")], at: 0)?.value
        XCTAssertEqual(waits, 3)
        XCTAssertEqual(m.textView.string, "Intro.か")
        XCTAssertTrue(m.textView.hasMarkedText(), "the composition was disturbed")
        XCTAssertEqual(m.box.reported, [EditorCoordinator.compositionFailureMessage])
    }

    func test_aDocumentThatIsNoLongerOpenGetsNothing() async throws {
        var m: Mounted!
        m = try mount("Intro", importer: { _, _ in
            m.coordinator.detach()     // the writer switched documents mid-copy
            return "research/a.png"
        })
        let image = try pngFile(named: "a.png")
        await m.coordinator.beginFigureIngest([image], at: 5)?.value
        XCTAssertEqual(m.textView.string, "Intro")
        XCTAssertEqual(m.box.reported, [],
                       "a document the writer left is not a failure to tell them about")
    }

    // MARK: - Undo outside an event (fix round 1, I2)

    /// The ingest's write runs in a Task continuation, outside any event. With
    /// `groupsByEvent` at its DEFAULT, an implicit group opened there would
    /// stay open until the next event ended — and the writer's caption typing
    /// would join it. `applyCommandEdit` closes its own group.
    func test_anAsyncFigureIsItsOwnUndoStepWithTheDefaultGrouping() async throws {
        let m = try mount("Intro", importer: { _, _ in "research/a.png" })
        m.window.makeFirstResponder(m.textView)
        let undo = try XCTUnwrap(m.textView.undoManager)
        XCTAssertTrue(undo.groupsByEvent, "the premise: the default grouping")
        let image = try pngFile(named: "a.png")

        await m.coordinator.beginFigureIngest([image], at: 5)?.value
        XCTAssertEqual(undo.groupingLevel, 0, "the figure's group is closed, not left open")

        m.textView.insertText("Map", replacementRange: m.textView.selectedRange())
        XCTAssertEqual(m.textView.string, "Intro\n\n![Map](research/a.png){#fig:a}")
        undo.undo()
        XCTAssertEqual(m.textView.string, "Intro\n\n![Caption](research/a.png){#fig:a}",
                       "the caption typing is its own step")
        undo.undo()
        XCTAssertEqual(m.textView.string, "Intro", "and the figure is the next")
    }

    // MARK: - R-S5 formats

    func test_aTIFFLandsAsAPNGUnderItsOwnName() async throws {
        let (store, chapter) = try await novel()
        let m = try mount("", importer: importer(store, chapter))
        let dir = temp.url.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tiff = dir.appendingPathComponent("Site Plan.tiff")
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(Self.picture().tiffRepresentation)))
        try XCTUnwrap(rep.representation(using: .tiff, properties: [:])).write(to: tiff)
        XCTAssertEqual(m.textView.figureDragOperation(for: [tiff]), .copy)

        await m.coordinator.beginFigureIngest([tiff], at: 0)?.value

        XCTAssertEqual(try onlyFigure(store).path, "figures/site-plan.png")
        let copied = store.url.appendingPathComponent("figures/site-plan.png")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(copied as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier,
                       "the copy really is a PNG")
        XCTAssertEqual(m.textView.string, "![Caption](../figures/site-plan.png){#fig:site-plan}")
    }

    func test_aPDFIsCopiedAsItIs() async throws {
        let (store, chapter) = try await novel()
        let m = try mount("", importer: importer(store, chapter))
        let dir = temp.url.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pdf = dir.appendingPathComponent("chart.pdf")
        var box = CGRect(x: 0, y: 0, width: 20, height: 20)
        let context = try XCTUnwrap(CGContext(pdf as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.fill(box); context.endPDFPage(); context.closePDF()
        XCTAssertEqual(m.textView.figureDragOperation(for: [pdf]), .copy, "a PDF drop is accepted")

        await m.coordinator.beginFigureIngest([pdf], at: 0)?.value

        let copied = store.url.appendingPathComponent("figures/chart.pdf")
        XCTAssertEqual(try Data(contentsOf: copied), try Data(contentsOf: pdf),
                       "copied byte for byte")
        XCTAssertEqual(m.textView.string, "![Caption](../figures/chart.pdf){#fig:chart}")
    }

    // MARK: - Paste

    // MARK: - Paste: what is a picture's (fix round 1, C1)

    private func privatePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init("figure-test-\(UUID().uuidString)"))
        addTeardownBlock { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        return pasteboard
    }

    /// Word, Pages and Excel put a PDF rendering beside copied text. The
    /// writer copied words: the text pastes, and no figure is made.
    func test_textWithAPDFRenderingBesideItPastesTheText() throws {
        var asked = 0
        let m = try mount("", importer: { _, _ in asked += 1; return "research/a.png" })
        let pasteboard = privatePasteboard()
        pasteboard.declareTypes([.string, .rtf, .pdf], owner: nil)
        pasteboard.setString("Hello", forType: .string)
        pasteboard.setData(Data(#"{\rtf1 Hello}"#.utf8), forType: .rtf)
        pasteboard.setData(Data("%PDF-1.4".utf8), forType: .pdf)

        XCTAssertFalse(m.coordinator.pasteFigure(from: pasteboard), "not a picture's paste")
        XCTAssertTrue(m.textView.readSelection(from: pasteboard), "super's paste")
        XCTAssertEqual(m.textView.string, "Hello")
        XCTAssertNil(m.coordinator.figureIngestTask)
        XCTAssertEqual(asked, 0)
    }

    /// A browser's Copy Image (fix round 2): the bitmap beside an `<img>`-only
    /// HTML fragment, and no `.string`. There are no words to paste — `super`
    /// would paste nothing — so the picture is the paste.
    func test_aBrowserImageWithOnlyAnImgTagMakesAFigure() async throws {
        let m = try mount("", importer: { _, _ in "research/web.png" })
        let pasteboard = privatePasteboard()
        pasteboard.declareTypes([.tiff, .html], owner: nil)
        pasteboard.setData(Self.picture().tiffRepresentation, forType: .tiff)
        pasteboard.setString(#"<meta charset="utf-8"><img src="https://example.com/a.png" alt="">"#,
                             forType: .html)

        XCTAssertTrue(m.coordinator.pasteFigure(from: pasteboard))
        await m.coordinator.figureIngestTask?.value
        XCTAssertTrue(m.textView.string.hasPrefix("![Caption](research/web.png)"), m.textView.string)
    }

    /// Safari also offers RTFD whose only content is the image attachment.
    func test_aBrowserImageWithAnAttachmentOnlyRTFDMakesAFigure() async throws {
        let m = try mount("", importer: { _, _ in "research/web.png" })
        let tiff = try XCTUnwrap(Self.picture().tiffRepresentation)
        let attachment = NSAttributedString(attachment: NSTextAttachment(data: tiff, ofType: "public.tiff"))
        let rtfd = try XCTUnwrap(attachment.rtfd(from: NSRange(location: 0, length: attachment.length),
                                                 documentAttributes: [:]))
        let pasteboard = privatePasteboard()
        pasteboard.declareTypes([.tiff, .rtfd], owner: nil)
        pasteboard.setData(tiff, forType: .tiff)
        pasteboard.setData(rtfd, forType: .rtfd)

        XCTAssertTrue(m.coordinator.pasteFigure(from: pasteboard))
        await m.coordinator.figureIngestTask?.value
        XCTAssertTrue(m.textView.string.hasPrefix("![Caption](research/web.png)"), m.textView.string)
    }

    /// HTML with words in it is text, even with no `.string` beside it.
    func test_htmlWithWordsIsTextEvenWithoutAPlainString() throws {
        let pasteboard = privatePasteboard()
        pasteboard.declareTypes([.tiff, .html], owner: nil)
        pasteboard.setData(Self.picture().tiffRepresentation, forType: .tiff)
        pasteboard.setString("<p>Hello&nbsp;<img src=\"a.png\"></p>", forType: .html)
        XCTAssertTrue(FigureIngest.carriesText(pasteboard))
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, .tiff], owner: nil)
        pasteboard.setString(" \n", forType: .string)
        pasteboard.setData(Self.picture().tiffRepresentation, forType: .tiff)
        XCTAssertFalse(FigureIngest.carriesText(pasteboard), "whitespace is not words")
    }

    /// A Finder copy of a non-image file carries its icon as an image too.
    func test_aCopiedTextFileWithItsIconKeepsTodaysBehaviour() throws {
        var asked = 0
        let m = try mount("", importer: { _, _ in asked += 1; return "research/a.png" })
        let notes = temp.url.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: notes)
        let pasteboard = privatePasteboard()
        XCTAssertTrue(pasteboard.writeObjects([notes as NSURL]))
        pasteboard.addTypes([.tiff], owner: nil)
        pasteboard.setData(Self.picture().tiffRepresentation, forType: .tiff)
        XCTAssertTrue(pasteboard.canReadObject(forClasses: [NSImage.self], options: nil),
                      "the premise: an icon image rides along")

        XCTAssertFalse(m.coordinator.pasteFigure(from: pasteboard))
        XCTAssertNil(m.coordinator.figureIngestTask)
        XCTAssertEqual(asked, 0)
    }

    func test_aLonePNGOnThePasteboardStillMakesAFigure() async throws {
        var handed: URL?
        let m = try mount("", importer: { url, _ in
            handed = url
            return "figures/" + url.lastPathComponent
        })
        let pasteboard = privatePasteboard()
        pasteboard.setData(try ImagePasteHandler.encodePNG(Self.picture()), forType: .png)

        XCTAssertTrue(m.coordinator.pasteFigure(from: pasteboard))
        await m.coordinator.figureIngestTask?.value
        XCTAssertTrue(try XCTUnwrap(handed).lastPathComponent.hasPrefix("image-"))
        XCTAssertTrue(m.textView.string.hasPrefix("![Caption](figures/image-"), m.textView.string)
        XCTAssertTrue(m.textView.string.contains("{#fig:image-"),
                      "the label is the name the importer gave the file")
    }

    func test_aPastedImageBecomesAFigureAndNoAttachmentCharacter() async throws {
        var received: URL?
        var existedDuringImport = false
        let m = try mount("Intro", importer: { url, _ in
            received = url
            existedDuringImport = ImagePasteHandler.isIngestableImage(url)
                && FileManager.default.fileExists(atPath: url.path)
            return "research/pasted.png"
        })
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([Self.picture()]))
        m.textView.setSelectedRange(NSRange(location: 5, length: 0))

        m.textView.paste(nil)
        await m.coordinator.figureIngestTask?.value

        XCTAssertFalse(m.textView.string.contains("\u{FFFC}"), m.textView.string.debugDescription)
        XCTAssertFalse(m.box.text.contains("\u{FFFC}"))
        XCTAssertTrue(m.textView.string.hasPrefix("Intro\n\n![Caption](research/pasted.png){#fig:"),
                      m.textView.string)
        let url = try XCTUnwrap(received)
        XCTAssertEqual(url.pathExtension, "png")
        XCTAssertTrue(existedDuringImport, "the importer was handed a real PNG")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "the temporary file is gone once it was copied")
    }
}
