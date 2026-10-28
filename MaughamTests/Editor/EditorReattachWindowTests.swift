import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The real delivery path of the blank table card** (2026-10-28): a
/// `ProjectWindow` opened onto a selected document with a table figure. Its
/// first layout pass makes the editor's NSView twice on one coordinator
/// (`EditorReattachOverlayTests` pins the seam); the text view the writer
/// edits must carry the coordinator's figure overlay, and the card draws.
@MainActor
final class EditorReattachWindowTests: XCTestCase {
    override class func setUp() { super.setUp(); FontWarmup.ensure() }

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []

    override func setUp() async throws { temp = TempDirectory() }
    override func tearDown() async throws {
        for w in windows { w.close() }
        windows = []
        temp.cleanup()
        temp = nil
    }

    private func textViews(in view: NSView?) -> [MaughamTextView] {
        guard let view else { return [] }
        if let tv = view as? MaughamTextView { return [tv] }
        return view.subviews.flatMap { textViews(in: $0) }
    }

    /// A novel whose first chapter holds a 3×3 table figure's line, selected.
    private func project() async throws -> URL {
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        ds.projectStore = store
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        _ = try await store.createFigure(kind: .table, name: "t", piece: chapter.id, rows: 3, columns: 3)
        let file = url.appendingPathComponent(try XCTUnwrap(chapter.path))
        try "Intro.\n\n![Cash](../figures/t.csv){#tbl:t}\n\nAfter.\n"
            .write(to: file, atomically: true, encoding: .utf8)
        let doc = try await Document.load(url: file, device: "test", session: "s", presenter: nil)
        await doc.close()
        ds.updateUIState { $0.selectedSubject = .item(chapter.id) }
        await ds.close()
        return url
    }

    func test_aWindowOpenedOntoADocumentDrawsItsTableCardOnTheEditedTextView() async throws {
        let url = try await project()
        let registry = ProjectRegistry()
        let frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let hosting = NSHostingView(rootView: AnyView(
            ProjectWindow(url: url)
                .environment(UserPreferences(defaults: UserDefaults(suiteName: "reattach-\(UUID().uuidString)")!))
                .environment(registry)
                .environment(ProjectSessionRegistry(mcp: registry))
                .environment(BackupCoordinator())))
        hosting.frame = frame
        let window = TestWindow.make(SilentTestWindow.self, contentRect: frame,
                                     styleMask: [.titled, .resizable], contentView: hosting)
        windows.append(window)
        await pumpUntil(deadline: 20) { !self.textViews(in: window.contentView).isEmpty }
        let tv = try XCTUnwrap(textViews(in: window.contentView).first, "the editor mounted")
        let c = try XCTUnwrap(tv.delegate as? EditorCoordinator)
        let filled = await pumpUntil(deadline: 10) { c.figureCardModel?("../figures/t.csv")?.kind == .table }
        XCTAssertTrue(filled, "premise: the window's cards filled")

        // The editor the writer sees is the live one: attached, focused, its
        // caret where the document opened (not where `string =` left it).
        await pumpUntil(deadline: 1) { false }
        XCTAssertFalse(c.isDetached, "the live coordinator is not detached")
        XCTAssertTrue(tv.delegate === c)
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 0, length: 0), "the caret at the opened cursor")
        XCTAssertTrue(window.firstResponder === tv, "the editor has the keys")

        let overlay = try XCTUnwrap(c.figureThumbnailOverlay, "the coordinator has a figure overlay")
        XCTAssertTrue(overlay.superview === tv, "on the text view the writer edits")
        XCTAssertEqual(tv.subviews.filter { $0 is FigureThumbnailOverlay }.count, 1)
        tv.scrollRangeToVisible((tv.string as NSString).range(of: "![Cash]"))
        overlay.display()
        XCTAssertEqual(overlay.lastDrawn, [.card(.table)], "and the card draws there")

        // Leave nothing writing when the temp directory goes.
        if let store = registry.lookup(id: ProjectIdentifier.id(for: url))?.store {
            await store.documentStore?.close()
        }
    }
}
