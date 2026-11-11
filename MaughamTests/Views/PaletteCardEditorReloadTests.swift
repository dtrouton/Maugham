import XCTest
import AppKit
import SwiftUI
import Observation
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

    /// Type `text` at the end of `field` through AppKit's own
    /// `shouldChangeText` → `didChangeText`, which reaches the binding.
    private func type(_ text: String, into field: NSTextView) {
        field.setSelectedRange(NSRange(location: (field.string as NSString).length, length: 0))
        for character in text {
            let range = field.selectedRange()
            guard field.shouldChangeText(in: range, replacementString: String(character)) else { continue }
            field.textStorage?.replaceCharacters(in: range, with: String(character))
            field.setSelectedRange(NSRange(location: range.location + 1, length: 0))
            field.didChangeText()
        }
    }

    /// A write behind the card that is queued while the editor's own save —
    /// of text typed in its field — is in flight (here, at its keep) lands
    /// after it, and the open editor then shows it; the typed text it
    /// replaced is a version.
    func test_aWriteBehindQueuedDuringTheEditorsOwnSaveIsShownAfterIt() async throws {
        let item = try await store.addPaletteCard(title: "Harbour", kind: .location)
        let made = try XCTUnwrap(store.loadPaletteCards().first { $0.researchItemId == item.id })
        try await store.updatePaletteCard(withBody(made, "Before."))
        let window = try await mount(item.id, showing: "Before.")
        documentStore.researchNoteDoor.saveDelay = .seconds(3600)
        type(" Typed.", into: try XCTUnwrap(bodyView(in: window)))
        final class Behind { var task: Task<Void, Error>? }
        let behind = Behind()
        let projectStore: ProjectStore = store
        let later = withBody(made, "Written behind.")
        documentStore.researchNoteDoor.keepWillRunForTesting = {
            guard behind.task == nil else { return }
            behind.task = Task { @MainActor in try await projectStore.updatePaletteCard(later) }
        }

        try await documentStore.flushPendingSave()
        try await XCTUnwrap(behind.task, "the editor's typing reached the door's flush").value

        await pumpUntil(deadline: 5) { self.bodyView(in: window)?.string == "Written behind." }
        XCTAssertEqual(bodyView(in: window)?.string, "Written behind.",
                       "the reload that arrived behind the editor's own save is applied")
        let versions = ResearchVersionStore(projectURL: store.url)
        XCTAssertTrue(versions.versions(itemId: item.id).contains {
            String(decoding: (try? versions.read($0).0) ?? Data(), as: UTF8.self).contains("Before. Typed.")
        }, "the typed text the write replaced is kept")
    }

    /// Typing in the card's Notes field puts the edit in the door's pending
    /// slot for the card — where every writer's settle, the flush and the
    /// store's close find it — not in a view-local debounce.
    func test_typingInTheCardWaitsInTheDoor_andAFlushSavesIt() async throws {
        let item = try await store.addPaletteCard(title: "Harbour", kind: .location)
        let made = try XCTUnwrap(store.loadPaletteCards().first { $0.researchItemId == item.id })
        try await store.updatePaletteCard(withBody(made, "Before."))
        let window = try await mount(item.id, showing: "Before.")
        documentStore.researchNoteDoor.saveDelay = .seconds(3600)
        type(" Typed.", into: try XCTUnwrap(bodyView(in: window)))

        XCTAssertTrue(documentStore.researchNoteHasPendingSave(itemId: item.id),
                      "the card's edit waits in the door, as a note's does")
        try await documentStore.flushPendingSave()
        XCTAssertEqual(store.loadPaletteCards().first { $0.researchItemId == item.id }?.body, "Before. Typed.")
    }

    /// **A rename typed in the title, then a switch to another card inside
    /// its debounce**: the first card is still renamed (the card and title
    /// are captured when the rename is scheduled), and the second is not.
    func test_aTypedRenameSurvivesASwitchToAnotherCard() async throws {
        let first = try await store.addPaletteCard(title: "Harbour", kind: .location)
        let second = try await store.addPaletteCard(title: "Lighthouse", kind: .location)
        let probe = CardEditorProbe(cardId: first.id)
        let window = TestWindow.mount(CardEditorProbeView(store: store, probe: probe),
                                      size: CGSize(width: 600, height: 700))
        windows.append(window)
        await pumpUntil(deadline: 5) { self.titleField(in: window)?.stringValue == "Harbour" }
        let field = try XCTUnwrap(titleField(in: window), "premise: the title field shows the card")

        field.stringValue = "Quay"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        probe.cardId = second.id

        await pumpUntil(deadline: 5) {
            self.store.findResearchItem(id: first.id, in: self.store.manifest.research)?.title == "Quay"
        }
        XCTAssertEqual(store.findResearchItem(id: first.id, in: store.manifest.research)?.title, "Quay",
                       "the first card's typed rename is not dropped by the switch")
        XCTAssertEqual(store.findResearchItem(id: second.id, in: store.manifest.research)?.title, "Lighthouse")
    }

    private func titleField(in window: NSWindow) -> NSTextField? {
        guard let root = window.contentView else { return nil }
        var found: [NSTextField] = []
        collectFields(in: root, into: &found)
        return found.first { $0.isEditable }
    }

    private func collectFields(in view: NSView, into out: inout [NSTextField]) {
        if let hit = view as? NSTextField { out.append(hit) }
        for sub in view.subviews { collectFields(in: sub, into: &out) }
    }
}

/// Which card the hosted editor shows, settable so a test can switch cards
/// on one live editor as the wall does (`PaletteCardEditor` is not keyed on
/// its card id).
@Observable
@MainActor
final class CardEditorProbe {
    var cardId: String
    init(cardId: String) { self.cardId = cardId }
}

@MainActor
private struct CardEditorProbeView: View {
    let store: ProjectStore
    let probe: CardEditorProbe
    var body: some View { PaletteCardEditor(store: store, cardId: probe.cardId) }
}
