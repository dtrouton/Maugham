import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **Plan's Tab from the binder to the canvas, and ⇧Tab back** (spec §1,
/// "Getting to the canvas from the binder"). Real key events through
/// `NSApp.sendEvent(_:)`, no clicks.
///
/// **The key-view loop does not do this, measured 2026-10-24** on the real
/// `ProjectWindow` in Plan: the binder's outline view had no
/// `nextValidKeyView` and a real Tab left it first responder. So the hand-off
/// is explicit — `TreeCanvasKeyboard` — and these tests drive it end to end.
///
/// Two hosts. The real `ProjectWindow` for the hand-off itself and the
/// binder's own keys; a probe (the production `BinderPaneToggle` beside a
/// production `CanvasView`, joined the way the window joins them) where the
/// test must START a rename, which the window offers only from a menu or a
/// press (tripwire 33), and for Author, whose window mounts no canvas to miss.
/// The probe's research-row rename has a chapter rename's shape (tripwire 16),
/// and the gate asks both.
@MainActor
final class PlanBinderTabTests: XCTestCase {

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []
    private var documentStores: [DocumentStore] = []

    override func setUp() async throws { temp = TempDirectory() }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        documentStores.removeAll()
        temp.cleanup()
        temp = nil
    }

    // MARK: - The decision

    /// Tab goes to the canvas only beside one, and never during either tree's
    /// rename.
    func test_tabGoesToTheCanvasOnlyBesideOneAndNeverDuringARename() {
        for persona in Persona.allCases {
            let keyboard = TreeCanvasKeyboard(tabReachesTheCanvas: persona.centresTheCanvas)
            XCTAssertEqual(keyboard.tabGoesToTheCanvas(renamingRow: nil, renamingInSections: nil),
                           persona.centresTheCanvas, "\(persona)")
            XCTAssertFalse(keyboard.tabGoesToTheCanvas(renamingRow: "d1", renamingInSections: nil),
                           "\(persona): Tab left a chapter's rename")
            XCTAssertFalse(keyboard.tabGoesToTheCanvas(renamingRow: nil, renamingInSections: "r1"),
                           "\(persona): Tab left a research row's rename")
        }
        XCTAssertFalse(TreeCanvasKeyboard().tabReachesTheCanvas,
                       "a tree with no canvas beside it must keep AppKit's Tab")
    }

    // MARK: - The real window

    func test_tabInThePlanBinderGivesTheCanvasTheKeyboard() async throws {
        let window = try await planWindow()
        let binder = try binderOutline(in: window)
        let canvas = try canvasView(in: window)
        XCTAssertTrue(window.makeFirstResponder(binder), "precondition: the binder holds the keyboard")

        NSApp.sendEvent(tab(window))
        _ = await pumpUntil(deadline: 3) { window.firstResponder === canvas }

        XCTAssertTrue(window.firstResponder === canvas,
                      "Tab in Plan's binder left the keyboard at "
                      + String(describing: window.firstResponder))
    }

    /// Twice round, so a focus value that never learned it had lost the
    /// keyboard would show on the second ⇧Tab.
    func test_shiftTabOnTheCanvasGivesTheBinderTheKeyboard() async throws {
        let window = try await planWindow()
        let binder = try binderOutline(in: window)
        let canvas = try canvasView(in: window)
        XCTAssertTrue(window.makeFirstResponder(binder))

        for round in 1...2 {
            NSApp.sendEvent(tab(window))
            _ = await pumpUntil(deadline: 3) { window.firstResponder === canvas }
            XCTAssertTrue(window.firstResponder === canvas, "round \(round): Tab did not reach the canvas")

            NSApp.sendEvent(backtab(window))
            _ = await pumpUntil(deadline: 3) { window.firstResponder === binder }
            XCTAssertTrue(window.firstResponder === binder,
                          "round \(round): ⇧Tab on the canvas left the keyboard at "
                          + String(describing: window.firstResponder))
        }
    }

    /// The binder keeps its own keys: ↓ moves the selection, and Return is not
    /// taken by the hand-off — the binder keeps the keyboard. (Return starts
    /// no rename here today, measured 2026-10-24: rename is a menu verb.)
    func test_theBinderKeepsItsReturnAndArrows() async throws {
        let window = try await planWindow()
        let binder = try binderOutline(in: window)
        let canvas = try canvasView(in: window)
        XCTAssertTrue(window.makeFirstResponder(binder))
        binder.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        pump(0.2)

        NSApp.sendEvent(key("\u{F701}", modifiers: [.numericPad, .function], keyCode: 125, window))
        _ = await pumpUntil(deadline: 3) { binder.selectedRow == 2 }
        XCTAssertEqual(binder.selectedRow, 2, "↓ in the binder did not move the selection")
        XCTAssertTrue(window.firstResponder === binder)

        NSApp.sendEvent(key("\r", modifiers: [], keyCode: 36, window))
        await waitOut(0.4)
        XCTAssertTrue(window.firstResponder === binder,
                      "Return in the binder moved the keyboard to "
                      + String(describing: window.firstResponder))
        XCTAssertFalse(window.firstResponder === canvas)
        XCTAssertEqual(binder.selectedRow, 2, "Return in the binder moved the selection")
    }

    /// Author's centre is the editor: a Tab in its binder asks nothing of a
    /// canvas. Driven in the probe, so a canvas IS beside the tree and could
    /// have been reached; the window passes `persona.centresTheCanvas`
    /// (censused in `PromotionCommandTests`).
    func test_tabInTheAuthorBinderDoesNotReachTheCanvas() async throws {
        let (window, probe) = try await probeWindow(persona: .author)
        let binder = try binderOutline(in: window)
        let canvas = try canvasView(in: window)
        XCTAssertTrue(window.makeFirstResponder(binder))

        NSApp.sendEvent(tab(window))
        await waitOut(0.4)

        XCTAssertEqual(probe.canvasAsks, 0, "Author's binder asked for the canvas")
        XCTAssertFalse(window.firstResponder === canvas, "Tab in Author's binder reached the canvas")

        // The control: the same probe in Plan does hand off, so the negative
        // above is not a harness that cannot.
        let (plan, planProbe) = try await probeWindow(persona: .plan)
        let planCanvas = try canvasView(in: plan)
        XCTAssertTrue(plan.makeFirstResponder(try binderOutline(in: plan)))
        NSApp.sendEvent(tab(plan))
        _ = await pumpUntil(deadline: 3) { plan.firstResponder === planCanvas }
        XCTAssertEqual(planProbe.canvasAsks, 1)
        XCTAssertTrue(plan.firstResponder === planCanvas, "control: Plan's probe did not hand off")
    }

    /// Tab inside a rename belongs to the rename: the field keeps the keyboard
    /// and the canvas is not asked.
    func test_tabDuringABinderRenameStaysInTheRename() async throws {
        let (window, probe) = try await probeWindow(persona: .plan, researchNote: "Tides")
        let canvas = try canvasView(in: window)
        let noteId = try XCTUnwrap(probe.noteId)
        probe.treeState.renamingItemId = noteId
        _ = await pumpUntil(deadline: 3) { self.renameEditor(in: window) != nil }
        let editor = try XCTUnwrap(renameEditor(in: window),
                                   "precondition: the rename field holds the keyboard")

        NSApp.sendEvent(tab(window))
        await waitOut(0.4)

        XCTAssertEqual(probe.canvasAsks, 0, "Tab in a rename asked for the canvas")
        XCTAssertFalse(window.firstResponder === canvas, "Tab in a rename reached the canvas")
        XCTAssertTrue(window.firstResponder === editor,
                      "Tab in a rename left the field; first responder is "
                      + String(describing: window.firstResponder))
    }

    // MARK: - Hosts

    private func planWindow() async throws -> NSWindow {
        let url = try await novel(chapters: 3, persona: .plan)
        let registry = ProjectRegistry()
        let window = TestWindow.mount(
            AnyView(
                ProjectWindow(url: url)
                    .environment(UserPreferences())
                    .environment(registry)
                    .environment(ProjectSessionRegistry(mcp: registry))
                    .environment(BackupCoordinator())),
            size: CGSize(width: 1200, height: 700),
            as: KeyTestWindow.self, styleMask: [.titled, .resizable],
            present: .key)
        windows.append(window)
        _ = await pumpUntil(deadline: 20) {
            self.findCanvas(in: window) != nil
                && (self.findBinder(in: window)?.numberOfRows ?? 0) > 3
        }
        pump(0.6)
        return window
    }

    private func probeWindow(persona: Persona,
                             researchNote: String? = nil) async throws -> (NSWindow, HandOffProbe) {
        let url = try await novel(chapters: 2, persona: persona)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        documentStores.append(ds)
        let probe = HandOffProbe()
        if let researchNote {
            probe.noteId = try await store.addResearchTextNote(parentId: nil, title: researchNote).id
            probe.treeState.researchSectionExpanded = true
        }
        let model = CanvasModel()
        let root = temp.url.appendingPathComponent("canvas-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let window = TestWindow.mount(
            AnyView(HandOffProbeView(store: store, persona: persona, probe: probe,
                                     model: model, canvasRoot: root)),
            size: CGSize(width: 1000, height: 600),
            as: KeyTestWindow.self, present: .key)
        windows.append(window)
        _ = await pumpUntil(deadline: 10) {
            self.findCanvas(in: window) != nil
                && (self.findBinder(in: window)?.numberOfRows ?? 0) > 2
        }
        pump(0.4)
        return (window, probe)
    }

    private func novel(chapters: Int, persona: Persona) async throws -> URL {
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        documentStores.append(ds)
        while store.manifest.structure.count < chapters {
            _ = try await store.addStructureItem(
                parentId: nil,
                title: "Chapter \(store.manifest.structure.count + 1)",
                kind: .document(.markdown))
        }
        await store.wordCountPopulationTask?.value
        ds.updateUIState {
            $0.persona = persona
            $0.selectedSubject = .project
        }
        await waitOut(1.2)   // the 500ms UI-state debounce reaches disk
        return url
    }

    // MARK: - Reading the window

    /// The binder is the leftmost outline in the window. The `find…` forms
    /// record nothing, so a poll can ask them before the window is ready.
    private func findBinder(in window: NSWindow) -> NSOutlineView? {
        guard let root = window.contentView else { return nil }
        return all(NSOutlineView.self, in: root).min {
            $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX
        }
    }

    private func findCanvas(in window: NSWindow) -> CanvasEventNSView? {
        guard let root = window.contentView else { return nil }
        return all(CanvasEventNSView.self, in: root).first
    }

    private func binderOutline(in window: NSWindow) throws -> NSOutlineView {
        try XCTUnwrap(findBinder(in: window), "no binder outline in the window")
    }

    private func canvasView(in window: NSWindow) throws -> CanvasEventNSView {
        try XCTUnwrap(findCanvas(in: window), "no canvas in the window")
    }

    /// The field editor, while it is editing an editable text field.
    private func renameEditor(in window: NSWindow) -> NSTextView? {
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSTextField, field.isEditable else { return nil }
        return editor
    }

    private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var found: [T] = []
        if let hit = view as? T { found.append(hit) }
        for sub in view.subviews { found += all(type, in: sub) }
        return found
    }

    // MARK: - Keys

    private func tab(_ window: NSWindow) -> NSEvent {
        key("\t", modifiers: [], keyCode: 48, window)
    }

    /// ⇧Tab as AppKit delivers it: U+0019 with ⇧ held.
    private func backtab(_ window: NSWindow) -> NSEvent {
        key("\u{19}", modifiers: .shift, keyCode: 48, window)
    }

    private func key(_ characters: String, modifiers: NSEvent.ModifierFlags,
                     keyCode: UInt16, _ window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: keyCode)!
    }
}

/// What the probe's hand-off was asked, and the tree state the test drives.
@MainActor
private final class HandOffProbe {
    var canvasAsks = 0
    var noteId: String?
    let treeState = BinderTreeSectionsState()
}

/// The production tree shell beside a production canvas, joined as
/// `ProjectWindow` joins them: one-way counters both ways.
@MainActor
private struct HandOffProbeView: View {
    let store: ProjectStore
    let persona: Persona
    let probe: HandOffProbe
    let model: CanvasModel
    let canvasRoot: URL
    @State private var subject: BinderSubject? = .project
    @State private var treeFindActive = false
    @State private var canvasKeyboardRequest = 0
    @State private var treeKeyboardRequest = 0

    var body: some View {
        HStack(spacing: 0) {
            BinderPaneToggle(
                store: store, selectedSubject: $subject,
                projectType: store.manifest.type, lastParsedScript: nil,
                treeState: probe.treeState, treeFindActive: $treeFindActive,
                persona: persona,
                canvasKeyboard: TreeCanvasKeyboard(
                    tabReachesTheCanvas: persona.centresTheCanvas,
                    giveTheCanvasTheKeyboard: {
                        probe.canvasAsks += 1
                        canvasKeyboardRequest += 1
                    },
                    treeKeyboardRequest: treeKeyboardRequest))
                .frame(width: 280)
            CanvasView(model: model, projectRoot: canvasRoot,
                       paletteSwatchHexes: { [] },
                       keyboardRequest: canvasKeyboardRequest,
                       returnKeyboardToTree: { treeKeyboardRequest += 1 })
        }
    }
}
