import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The fixture the in-place grid's mounted suites share** (report plan 7c
/// Tasks 6 and 7): a mounted `EditorSurface` over a real novel, its table
/// figure, the window's real figure cards and the production
/// `FigureGridOpening`, wired as `EditorHost` wires them. Declares no tests.
@MainActor
class FigureGridMountedTestCase: XCTestCase {
    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    var temp: TempDirectory!
    var documentStores: [DocumentStore] = []
    var coordinators: [EditorCoordinator] = []

    override func setUp() async throws { temp = TempDirectory() }

    override func tearDown() async throws {
        for c in coordinators {
            if let controller = c.figureGrid?.controller {
                await controller.settleWrites()
                controller.close()
            }
        }
        coordinators = []
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
        let textView: NSTextView
        let coordinator: EditorCoordinator
        let store: ProjectStore
        let cards: FigureCardCache
        let figure: FigureRecord?
        var text: NSString { textView.string as NSString }
    }

    /// Forty paragraphs of prose, the table's line, a paragraph, the SAME
    /// table written on a second line (R7c-4), and an end.
    nonisolated static let document: String = {
        let prose = (1...40).map { "Paragraph \($0) of plain prose before the table." }
        return (prose + ["![Cash](../figures/t.csv){#tbl:t}", "Middle prose.",
                         "![Cash again](../figures/t.csv)", "The end."]).joined(separator: "\n\n")
    }()

    /// A novel, a `rows`×3 table figure `t` in its chapter, the window's
    /// figure cards filled, and a manuscript editor over `text` wired as
    /// `EditorHost` wires it.
    func mount(_ text: String = document, rows: Int = 3, makeFigure: Bool = true,
                       height: CGFloat = 500, presence: FigureGridPresence? = nil,
                       beforeMaking: (@MainActor () -> Void)? = nil) async throws -> Mounted {
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: store.url)
        store.documentStore = ds
        ds.projectStore = store
        documentStores.append(ds)
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let path = try XCTUnwrap(chapter.path)
        let figure = makeFigure
            ? try await store.createFigure(kind: .table, name: "t", piece: chapter.id, rows: rows, columns: 3)
            : nil
        let cards = FigureCardCache()
        ds.attachFigureCardCache(cards)
        cards.attach(FigureCardCache.Source(read: { [weak ds] in await ds?.figureCardInputs() }))
        addTeardownBlock { @MainActor in
            cards.attach(nil)
            ds.detachFigureCardCache(cards)
        }
        await cards.idle()

        let box = Box(text)
        var configuration = EditorSurfaceConfiguration(
            presentation: .init(theme: .light, typography: .defaults,
                                mode: ProseMode(reservesFigureThumbnails: true),
                                typewriterScroll: false, sentenceFocus: false,
                                paragraphFocus: false, showElementGutter: false),
            control: EditorControl())
        configuration.answersInsertCommands = true
        configuration.paragraphProviders.figureImageResolver = { _ in .notLocal }
        configuration.paragraphProviders.figureCardModel = { cards.model(forLinePath: $0, documentPath: path) }
        configuration.paragraphProviders.figureGridOpening = .window(
            store: ds, projectStore: store, documentPath: path, presence: presence)
        configuration.paragraphProviders.tableFigureMaker = { request in
            beforeMaking?()   // the writer, while the figure is being made
            return try await FigureIngest.makeTableFigure(documentId: chapter.id, documentPath: path,
                                                   request: request, store: store)
        }
        configuration.paragraphProviders.commandFailureReporter = { box.reported.append($0) }
        let window = TestWindow.mount(
            EditorSurface(text: Binding(get: { box.text }, set: { box.text = $0 }), configuration: configuration),
            size: CGSize(width: 700, height: height), as: KeyTestWindow.self)
        addTeardownBlock { @MainActor in
            window.reportsKey = false
            window.close()
        }
        let textView = try XCTUnwrap(Self.textView(in: window.contentView))
        let coordinator = try XCTUnwrap(textView.delegate as? EditorCoordinator)
        coordinators.append(coordinator)
        window.makeFirstResponder(textView)
        return Mounted(box: box, window: window, textView: textView, coordinator: coordinator,
                       store: store, cards: cards, figure: figure)
    }

    static func textView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let tv = view as? NSTextView { return tv }
        for sub in view.subviews { if let tv = textView(in: sub) { return tv } }
        return nil
    }

    func location(_ m: Mounted, _ needle: String) -> Int {
        m.text.range(of: needle).location
    }

    func spacing(_ m: Mounted, at location: Int) -> CGFloat {
        (m.textView.textStorage?.attribute(.paragraphStyle, at: location, effectiveRange: nil)
            as? NSParagraphStyle)?.paragraphSpacing ?? -1
    }

    func cardRoom(_ m: Mounted) -> CGFloat {
        FigureCardMetrics.room(for: m.cards.model(forFigureId: m.figure?.id ?? ""), typography: .defaults)
    }

    func scrollOrigin(_ m: Mounted) -> CGPoint {
        m.textView.enclosingScrollView?.contentView.bounds.origin ?? .zero
    }

    /// The bottom of the line holding `location`'s text, in text-view coordinates.
    func lineBottom(_ m: Mounted, at location: Int) -> CGFloat {
        let lm = m.textView.layoutManager!
        var start = 0, end = 0, contentsEnd = 0
        m.text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
        let glyph = lm.glyphIndexForCharacter(at: contentsEnd - 1)
        return lm.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).maxY + m.textView.textContainerOrigin.y
    }

    func lineEnd(_ m: Mounted, at location: Int) -> Int {
        var start = 0, end = 0, contentsEnd = 0
        m.text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
        return contentsEnd
    }

    /// The caret placed and the figure line scrolled into view, as the writer left them.
    func park(_ m: Mounted, caret: Int, showing line: Int) {
        m.textView.setSelectedRange(NSRange(location: caret, length: 0))
        m.textView.scrollRangeToVisible(NSRange(location: line, length: 1))
        m.textView.layoutManager?.ensureLayout(for: m.textView.textContainer!)
    }

    func opened(_ m: Mounted) async throws -> FigureGridExpansion {
        let grid = try XCTUnwrap(m.coordinator.figureGrid, "the card expanded")
        await grid.opening?.value
        XCTAssertNotNil(grid.controller, "the visit opened")
        return grid
    }

    func returnKey(_ m: Mounted) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: m.window.windowNumber, context: nil, characters: "\r",
                         charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    }
}
