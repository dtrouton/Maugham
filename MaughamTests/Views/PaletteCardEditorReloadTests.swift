import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **A palette card open in its editor takes text written behind its back**
/// (note versions plan 2 wave 3, P2), as a note's editor does: a version
/// restored from the card's inspector, or any other writer's save of the
/// card, moves the card's reload signal in the note door, and the editor —
/// with no draft of the writer's waiting — re-seeds from the file. Driven by
/// awaiting the door call; nothing presses a control.
@MainActor
final class PaletteCardEditorReloadTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    private var root: URL!
    private var store: ProjectStore!
    private var documentStore: DocumentStore!
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        root = TestTemp.root.appendingPathComponent("card-reload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let projectURL = try await ProjectFactory.createNovelProject(named: "Reload", in: root)
        store = try await ProjectStore.load(from: projectURL)
        await store.wordCountPopulationTask?.value
        documentStore = try await DocumentStore.open(url: projectURL)
        store.documentStore = documentStore
        documentStore.projectStore = store
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows = []
        await documentStore?.close()
        try? FileManager.default.removeItem(at: root)
    }

    private func withBody(_ card: PaletteCard, _ body: String) -> PaletteCard {
        PaletteCard(researchItemId: card.researchItemId, title: card.title, kind: card.kind,
                    swatches: card.swatches, notes: card.notes, imagePaths: card.imagePaths, body: body)
    }

    private func bodyView(in window: NSWindow) -> NSTextView? {
        guard let root = window.contentView else { return nil }
        var found: [NSTextView] = []
        collect(in: root, into: &found)
        return found.first
    }

    private func collect(in view: NSView, into out: inout [NSTextView]) {
        if let hit = view as? NSTextView, hit.isEditable, !hit.isFieldEditor { out.append(hit) }
        for sub in view.subviews { collect(in: sub, into: &out) }
    }

    /// The card's editor, mounted, showing `expected` in its Notes field.
    private func mount(_ cardId: String, showing expected: String) async throws -> NSWindow {
        let window = TestWindow.mount(PaletteCardEditor(store: store, cardId: cardId),
                                      size: CGSize(width: 600, height: 700))
        windows.append(window)
        await pumpUntil(deadline: 5) { self.bodyView(in: window)?.string == expected }
        XCTAssertEqual(bodyView(in: window)?.string, expected, "premise: the editor shows the card's body")
        return window
    }

    func test_aWriteBehindTheCardIsShownInItsOpenEditor() async throws {
        let item = try await store.addPaletteCard(title: "Harbour", kind: .location)
        let made = try XCTUnwrap(store.loadPaletteCards().first { $0.researchItemId == item.id })
        try await store.updatePaletteCard(withBody(made, "Before."))
        let window = try await mount(item.id, showing: "Before.")

        try await store.updatePaletteCard(withBody(made, "Written behind."))

        await pumpUntil(deadline: 5) { self.bodyView(in: window)?.string == "Written behind." }
        XCTAssertEqual(bodyView(in: window)?.string, "Written behind.",
                       "the open card editor re-seeds from what was written behind it")
    }

    func test_aRestoredVersionIsShownInTheOpenEditor() async throws {
        let item = try await store.addPaletteCard(title: "Harbour", kind: .location)
        let made = try XCTUnwrap(store.loadPaletteCards().first { $0.researchItemId == item.id })
        try await store.updatePaletteCard(withBody(made, "The first draft."))
        try await store.updatePaletteCard(withBody(made, "The second."))
        let window = try await mount(item.id, showing: "The second.")
        let versions = ResearchVersionStore(projectURL: store.url)
        let first = try XCTUnwrap(versions.versions(itemId: item.id).first {
            String(decoding: (try? versions.read($0).0) ?? Data(), as: UTF8.self).contains("The first draft.")
        })

        try await documentStore.restoreResearchNote(itemId: item.id, to: first, shareIsReadOnly: false)

        await pumpUntil(deadline: 5) { self.bodyView(in: window)?.string == "The first draft." }
        XCTAssertEqual(bodyView(in: window)?.string, "The first draft.")
    }
}
