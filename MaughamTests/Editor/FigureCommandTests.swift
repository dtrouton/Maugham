// MaughamTests/Editor/FigureCommandTests.swift
import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// Figures backed by research, end to end (plan 3a Task 6): the ingest a drop,
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
                       importer: ((URL) async throws -> String)?) throws -> Mounted {
        let box = Box(text)
        let binding = Binding(get: { box.text }, set: { box.text = $0 })
        var configuration = EditorSurfaceConfiguration(
            presentation: .init(theme: .light, typography: .defaults, mode: ProseMode(),
                                typewriterScroll: false, sentenceFocus: false,
                                paragraphFocus: false, showElementGutter: false),
            control: EditorControl())
        configuration.answersInsertCommands = true
        configuration.paragraphProviders.figureImporter = importer
        configuration.paragraphProviders.figureFailureReporter = { box.reported.append($0) }
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

    private func importer(_ store: ProjectStore, _ item: StructureItem)
        -> (URL) async throws -> String {
        { url in
            try await FigureIngest.importImage(url, documentId: item.id,
                                               documentPath: item.path ?? "", store: store)
        }
    }

    private func selected(_ m: Mounted) -> String {
        (m.textView.string as NSString).substring(with: m.textView.selectedRange())
    }

    // MARK: - End to end

    func test_anImageInANovelChapterIsCopiedLinkedAndWrittenAsOneUndoStep() async throws {
        let (store, chapter) = try await novel()
        let m = try mount("", importer: importer(store, chapter))
        try await type("Intro", into: m)
        let image = try pngFile(named: "Revenue Chart.png")

        try await asOneEvent(m) {
            await m.coordinator.beginFigureIngest([image], at: 5)?.value
        }

        let item = try XCTUnwrap(TreeWalk.first(in: store.manifest.research,
                                                where: { $0.title == "Revenue Chart" }),
                                 "the research item exists")
        XCTAssertEqual(item.path, "research/revenue-chart.png")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.url.appendingPathComponent("research/revenue-chart.png").path))
        XCTAssertTrue(store.linkedResearchIds(forDocumentId: chapter.id).contains(item.id),
                      "a novel chapter's research is linked to it")
        let line = "![Caption](../research/revenue-chart.png){#fig:revenue-chart}"
        XCTAssertEqual(m.textView.string, "Intro\n\n" + line)
        XCTAssertEqual(m.box.text, m.textView.string, "the figure reached the binding")
        XCTAssertEqual(selected(m), "Caption")
        XCTAssertEqual(m.box.reported, [])
        guard case .file = FigureImageResolver.resolve(
            "../research/revenue-chart.png", piecePath: try XCTUnwrap(chapter.path),
            projectURL: store.url, allowed: ["png"]) else {
            return XCTFail("the written path does not resolve from the chapter")
        }

        let undo = try XCTUnwrap(m.textView.undoManager)
        undo.undo()
        XCTAssertEqual(m.textView.string, "Intro", "one ⌘Z takes back the figure line")
        XCTAssertTrue(undo.canUndo, "the writer's typing is still undoable after it")
        XCTAssertNotNil(TreeWalk.first(in: store.manifest.research, where: { $0.id == item.id }),
                        "undoing the insert leaves the research item in place")
        undo.undo()
        XCTAssertEqual(m.textView.string, "")
    }

    func test_anImageInACollectionPieceLandsInThatPiecesOwnResearch() async throws {
        let (store, piece) = try await collectionPiece()
        let piecePath = try XCTUnwrap(piece.path)
        let m = try mount("", importer: importer(store, piece))
        let image = try pngFile(named: "map.png")

        await m.coordinator.beginFigureIngest([image], at: 0)?.value

        let item = try XCTUnwrap(TreeWalk.first(in: store.manifest.research,
                                                where: { $0.title == "map" }))
        let folder = (piecePath as NSString).deletingLastPathComponent
        XCTAssertEqual(item.path, "\(folder)/research/map.png")
        XCTAssertTrue(store.derivedResearchItems(forDocumentId: piece.id).contains { $0.id == item.id },
                      "the piece holds it by containment, its own research")
        XCTAssertEqual(m.textView.string, "![Caption](research/map.png){#fig:map}")
        guard case .file = FigureImageResolver.resolve("research/map.png", piecePath: piecePath,
                                                       projectURL: store.url, allowed: ["png"])
        else { return XCTFail("the written path does not resolve from the piece") }
    }

    func test_theLabelIsUniqueAgainstThisDocumentsFigures() async throws {
        let m = try mount("![Caption](research/map.png){#fig:map}",
                          importer: { _ in "research/map-2.png" })
        let image = try pngFile(named: "map.png")
        await m.coordinator.beginFigureIngest([image], at: (m.textView.string as NSString).length)?.value
        XCTAssertTrue(m.textView.string.hasSuffix("![Caption](research/map-2.png){#fig:map-2}"),
                      m.textView.string)
    }

    // MARK: - Failure, refusal and the async point

    func test_aFailedCopyWritesNothingAndSaysWhy() async throws {
        struct Refused: Error {}
        let m = try mount("Intro", importer: { _ in throw Refused() })
        let image = try pngFile(named: "a.png")
        await m.coordinator.beginFigureIngest([image], at: 5)?.value
        XCTAssertEqual(m.textView.string, "Intro")
        XCTAssertEqual(m.box.reported, [ImagePasteHandler.failureMessage(for: Refused())])
    }

    func test_aReadOnlyPostureRefusesTheDropAndCopiesNothing() async throws {
        var asked = 0
        let m = try mount("Intro", importer: { _ in asked += 1; return "research/a.png" })
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
        m = try mount("One.\n\nTwo three.", importer: { _ in
            // The writer types while the copy runs: above the paragraph, and in it.
            m.textView.insertText("Zero. ", replacementRange: NSRange(location: 0, length: 0))
            m.textView.insertText("!", replacementRange: NSRange(location: 15, length: 0))
            return "research/a.png"
        })
        let image = try pngFile(named: "a.png")
        await m.coordinator.beginFigureIngest([image], at: 9)?.value
        XCTAssertEqual(m.textView.string,
                       "Zero. One.\n\n![Caption](research/a.png){#fig:a}\n\nTwo! three.")
        XCTAssertEqual(selected(m), "Caption")
    }

    func test_aDocumentThatIsNoLongerOpenGetsNothing() async throws {
        var m: Mounted!
        m = try mount("Intro", importer: { _ in
            m.coordinator.detach()     // the writer switched documents mid-copy
            return "research/a.png"
        })
        let image = try pngFile(named: "a.png")
        await m.coordinator.beginFigureIngest([image], at: 5)?.value
        XCTAssertEqual(m.textView.string, "Intro")
        XCTAssertEqual(m.box.reported, [],
                       "a document the writer left is not a failure to tell them about")
    }

    // MARK: - Paste

    func test_aPastedImageBecomesAFigureAndNoAttachmentCharacter() async throws {
        var received: URL?
        var existedDuringImport = false
        let m = try mount("Intro", importer: { url in
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
